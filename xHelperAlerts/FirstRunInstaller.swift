import Foundation

/// Installs xHelperAlerts's hooks on the very first launch. Idempotent —
/// re-launching the app re-copies the (potentially updated) hook scripts and
/// re-checks the Claude Code settings, but never duplicates entries.
///
/// The hook scripts ship inside the app bundle's `Contents/Resources/`. We
/// copy them to `~/.xhelper-alerts/hooks/` so they survive the user moving /
/// replacing the app, and so Claude Code can reference a stable path that
/// doesn't change when the bundle moves.
enum FirstRunInstaller {

    private static let configDirName = ".xhelper-alerts"
    private static let hookScripts = ["xHelperAlerts.sh", "xhelper-auto-approve.sh", "xhelper-stop.sh"]

    static func runIfNeeded() {
        do {
            let bundledHooks = try locateBundledHooks()
            try copyHooks(from: bundledHooks)
            try registerClaudeHooks()
            try writeDefaultConfigIfMissing()
        } catch {
            // Surface failures via stderr — visible if launched from Terminal.
            // Silent if launched via Finder; the menu shows a "Hooks not
            // installed" hint in that case.
            FileHandle.standardError.write(Data("xHelperAlerts: first-run install failed — \(error)\n".utf8))
        }
    }

    // MARK: - Steps

    /// Returns the directory inside the app bundle that contains the hook
    /// scripts. Xcode's synchronized file groups flatten folder structure,
    /// so the scripts end up directly under `Contents/Resources/` rather
    /// than in a `hooks/` subdirectory — but we tolerate either layout.
    private static func locateBundledHooks() throws -> URL {
        guard let res = Bundle.main.resourceURL else {
            throw NSError(domain: "xHelperAlerts", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Resource URL missing"])
        }
        let candidates = [res.appendingPathComponent("hooks", isDirectory: true), res]
        for dir in candidates {
            let allPresent = hookScripts.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            if allPresent { return dir }
        }
        throw NSError(domain: "xHelperAlerts", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Bundled hook scripts not found in \(res.path)"])
    }

    private static func copyHooks(from bundled: URL) throws {
        let fm = FileManager.default
        let dst = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("\(configDirName)/hooks", isDirectory: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        for name in hookScripts {
            let srcURL = bundled.appendingPathComponent(name)
            let dstURL = dst.appendingPathComponent(name)
            if fm.fileExists(atPath: dstURL.path) { try? fm.removeItem(at: dstURL) }
            try fm.copyItem(at: srcURL, to: dstURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstURL.path)
        }
    }

    private static func registerClaudeHooks() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let hooksDir = home.appendingPathComponent("\(configDirName)/hooks")
        let notify   = hooksDir.appendingPathComponent("xHelperAlerts.sh").path
        let approve  = hooksDir.appendingPathComponent("xhelper-auto-approve.sh").path
        let stop     = hooksDir.appendingPathComponent("xhelper-stop.sh").path

        // Claude Code lives in two homes on the same Mac. Wire xHelperAlerts
        // into both so notifications fire regardless of which entry point
        // the user uses:
        //   • ~/.claude/settings.json                                ← Claude CLI
        //   • ~/Library/Developer/Xcode/CodingAssistant/             ← Xcode in-IDE assistant
        //     ClaudeAgentConfig/settings.json
        let targets: [URL] = [
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json"),
        ]

        for url in targets {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)

            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            }
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            hooks["Notification"] = mergedHook(into: hooks["Notification"], command: notify)
            hooks["PreToolUse"]   = mergedHook(into: hooks["PreToolUse"],   command: approve)
            hooks["Stop"]         = mergedHook(into: hooks["Stop"],         command: stop)
            root["hooks"] = hooks

            let out = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
        }
    }

    /// Merge a single hook command into the bucket without duplicating it.
    /// Bucket shape: `[ { "matcher": "", "hooks": [ { "type": "command", "command": "..." } ] } ]`
    private static func mergedHook(into existing: Any?, command: String) -> [[String: Any]] {
        var bucket = (existing as? [[String: Any]]) ?? []
        for entry in bucket {
            if let inner = entry["hooks"] as? [[String: Any]] {
                for h in inner where (h["command"] as? String) == command {
                    return bucket
                }
            }
        }
        bucket.append([
            "matcher": "",
            "hooks": [["type": "command", "command": command]]
        ])
        return bucket
    }

    private static func writeDefaultConfigIfMissing() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("\(configDirName)/config.json")
        if FileManager.default.fileExists(atPath: url.path) { return }
        let defaults: [String: Any] = [
            "sound_enabled": true,
            "banner_enabled": true,
            "auto_approve_enabled": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: defaults,
                                               options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
