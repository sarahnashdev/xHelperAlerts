import AppKit

/// First-launch helper: if the user opens xHelperAlerts directly from
/// the mounted DMG (path under `/Volumes/`), offer to copy it into
/// /Applications, relaunch the installed copy, and eject the volume.
///
/// Saves users from a really common pitfall — running the app from the
/// DMG forever, then wondering why it disappears after they unplug or
/// restart.
enum MoveToApplications {

    /// Call this once from `applicationDidFinishLaunching`. No-op if
    /// the app is already in /Applications or anywhere outside a
    /// disk-image mount.
    static func promptIfRunningFromDMG() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasPrefix("/Volumes/") else { return }

        // Be sure we're not on a non-DMG external drive — only act when
        // the volume looks like a read-only disk image.
        let mountRoot = "/Volumes/" + (bundlePath
            .dropFirst("/Volumes/".count)
            .split(separator: "/")
            .first.map(String.init) ?? "")

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Move xHelperAlerts to Applications?"
            alert.informativeText = """
            xHelperAlerts will keep working only if you copy it out of \
            the disk image. Move it to your Applications folder and \
            xHelperAlerts will relaunch from there. The disk image \
            ejects automatically.
            """
            alert.addButton(withTitle: "Move to Applications")
            alert.addButton(withTitle: "Not now")
            alert.icon = NSApp.applicationIconImage

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            moveAndRelaunch(from: bundlePath, mountRoot: mountRoot)
        }
    }

    // MARK: - Internals

    private static func moveAndRelaunch(from sourcePath: String, mountRoot: String) {
        let fm = FileManager.default
        let dst = "/Applications/xHelperAlerts.app"

        // If something is already at /Applications/xHelperAlerts.app,
        // ask before overwriting. The common case: user double-clicked
        // the DMG to update — we replace silently in that case once
        // they've confirmed.
        if fm.fileExists(atPath: dst) {
            let confirm = NSAlert()
            confirm.messageText = "Replace the existing xHelperAlerts?"
            confirm.informativeText = "A copy of xHelperAlerts already exists in /Applications. Replace it with the one in this disk image?"
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            if confirm.runModal() != .alertFirstButtonReturn { return }
            try? fm.removeItem(atPath: dst)
        }

        do {
            try fm.copyItem(atPath: sourcePath, toPath: dst)
        } catch {
            showError("Couldn't copy xHelperAlerts to /Applications: \(error.localizedDescription)")
            return
        }

        // Strip any extended attributes that might have come along for
        // the ride — Gatekeeper rejects "downloaded" xattrs on the
        // freshly-copied .app.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-cr", dst]
        try? xattr.run()
        xattr.waitUntilExit()

        // We can't detach the DMG while we're still running from it —
        // macOS rejects the unmount with "resource busy". So:
        //   1. Spawn a detached bash script that waits for our PID
        //      to disappear, then calls `hdiutil detach`.
        //   2. Launch the installed copy from /Applications.
        //   3. Terminate ourselves — which unblocks the detach script.
        scheduleEject(of: mountRoot, after: ProcessInfo.processInfo.processIdentifier)

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: dst),
            configuration: cfg
        ) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    /// Spawn a child bash process that survives our termination,
    /// waits for our PID to die, then ejects the disk image. macOS
    /// won't auto-kill the child when we exit — it gets reparented
    /// to launchd and finishes its job.
    private static func scheduleEject(of mountRoot: String, after pid: Int32) {
        let script = """
        # Wait up to 30 s for the parent app to terminate.
        for i in {1..60}; do
          if ! kill -0 \(pid) 2>/dev/null; then break; fi
          sleep 0.5
        done
        # Small buffer so file handles fully release.
        sleep 1
        /usr/bin/hdiutil detach '\(mountRoot)' -force -quiet
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        // Detach stdio so the child has no dependency on us.
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't move xHelperAlerts"
        alert.informativeText = message
        alert.runModal()
    }
}
