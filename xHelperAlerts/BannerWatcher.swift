import Foundation
import AppKit
import UserNotifications

/// Watches `~/.xhelper-alerts/banner-request` for new banner-request
/// lines written by the bash hook scripts. Posts each one via the
/// native `UNUserNotificationCenter` — so we never invoke
/// `osascript -e "display notification"`, which on macOS Tahoe routes
/// the call through Script Editor and pops dialogs at the user.
///
/// File format: each line is `<title>\t<body>`. We consume each line
/// once by truncating the file after reading.
@MainActor
final class BannerWatcher: NSObject, UNUserNotificationCenterDelegate {

    static let shared = BannerWatcher()

    /// Timestamp of the most recent banner tap. AppDelegate reads this in
    /// `applicationShouldHandleReopen` so a notification click doesn't ALSO
    /// open the Settings window — the click is already handled here by
    /// activating the Claude host app.
    static var lastBannerClickAt: Date?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    /// Ring-back: repeats the alert until the user clicks the banner.
    private var ringBackTimer: Timer?
    private var pendingAlert: (title: String, body: String)?

    private static var requestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xhelper-alerts/banner-request")
    }

    func start() {
        // Make sure the file exists so we have something to open.
        let url = Self.requestURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        // Become the notification center delegate so we can force the
        // banner to display even when xHelperAlerts is the foreground
        // app (default UNUserNotificationCenter behaviour suppresses
        // banners while the owning app is active).
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard !granted else { return }
            // If the OS already had us cached as denied, requestAuthorization
            // returns granted=false without showing a prompt. Nudge the user
            // to System Settings so they can flip it on.
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .denied else { return }
                DispatchQueue.main.async { Self.offerToOpenNotificationSettings() }
            }
        }
        attachWatcher()
    }

    private static var didOfferSettingsThisLaunch = false

    private static func offerToOpenNotificationSettings() {
        guard !didOfferSettingsThisLaunch else { return }
        didOfferSettingsThisLaunch = true
        let alert = NSAlert()
        alert.messageText = "Enable notifications for xHelperAlerts"
        alert.informativeText = """
            Banners are turned off for xHelperAlerts in System Settings, so you won't see when Claude needs your attention.

            Open System Settings → Notifications → xHelperAlerts and turn Allow Notifications on.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let bundleID = Bundle.main.bundleIdentifier ?? "ThreeLuckyStars.xHelperAlerts"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Tell macOS to show banners + play sound even when our app is
    /// frontmost. Without this, foreground notifications fall straight
    /// to Notification Center with no UI.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle a click on the banner. The approval request actually lives in
    /// the app that's running Claude (Xcode's Claude panel, or a terminal
    /// running the Claude CLI) — NOT in xHelperAlerts. So instead of opening
    /// our own settings/about window, we bring that host app to the front so
    /// the user lands right where the prompt is.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Only react to a plain tap on the banner body (the default action).
        // Dismiss / custom actions should not yank focus anywhere.
        let isDefaultTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let targetBundleID = userInfo["targetBundleID"] as? String

        Task { @MainActor in
            // Any interaction with the banner — tapping it or dismissing it —
            // counts as acknowledgment, so stop any ring-back reminders.
            BannerWatcher.shared.cancelRingBack()
            if isDefaultTap {
                Self.lastBannerClickAt = Date()
                Self.activateHostApp(preferredBundleID: targetBundleID)
            }
            completionHandler()
        }
    }

    /// Bring the Claude host app forward. Tries the bundle ID captured when the
    /// banner was posted first; otherwise falls back to the first running app
    /// in a sensible priority order. If none are running, does nothing (better
    /// than stealing focus into xHelperAlerts' own window).
    @MainActor
    private static func activateHostApp(preferredBundleID: String?) {
        let priority = [
            preferredBundleID,
            "com.apple.dt.Xcode",          // Xcode in-IDE Claude
            "com.googlecode.iterm2",       // iTerm2 running the CLI
            "com.apple.Terminal",          // Terminal running the CLI
        ].compactMap { $0 }

        let running = NSWorkspace.shared.runningApplications
        for bundleID in priority {
            if let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
        // Nothing matched — leave focus where it is rather than popping our
        // own window (which is what was happening before).
    }

    private func attachWatcher() {
        let url = Self.requestURL
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.drainPendingBanners()
            // Re-arm on atomic replacement.
            self?.restart()
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.watcher = source
    }

    private func restart() {
        watcher?.cancel()
        watcher = nil
        watchedFD = -1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.attachWatcher()
        }
    }

    /// Read every line out of the request file, post each as a banner,
    /// then truncate the file so the same request isn't replayed.
    private func drainPendingBanners() {
        let url = Self.requestURL
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8),
              !raw.isEmpty
        else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)

        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            let title = parts.first ?? "xHelperAlerts"
            let body  = parts.count > 1 ? parts[1] : "Claude needs your attention"
            handleAlert(title: title, body: body)
        }
    }

    /// Apply the user's sound + banner preferences for one alert, then arm
    /// ring-back if it's enabled. This is the single place alert sound is
    /// played, so the tone is consistent and ring-back can replay it.
    private func handleAlert(title: String, body: String) {
        let settings = AppState.shared.settings
        guard settings.notificationsEnabled else { return }
        settings.playConfiguredSoundIfEnabled()
        if settings.bannerEnabled {
            postBanner(title: title, body: body)
        }
        scheduleRingBack(title: title, body: body, settings: settings)
    }

    // MARK: - Ring-back

    /// Start (or restart) the repeating reminder for this alert. A new alert
    /// resets the timer. Requires the banner to be enabled — clicking the
    /// banner is how the user acknowledges and stops the ring-back.
    private func scheduleRingBack(title: String, body: String, settings: AlertSettings) {
        cancelRingBack()
        guard settings.notificationsEnabled,
              settings.ringBackEnabled,
              settings.bannerEnabled else { return }
        pendingAlert = (title, body)
        let interval = TimeInterval(max(1, settings.ringBackMinutes) * 60)
        // Reference the shared singleton inside the MainActor hop rather than
        // capturing `self`, which would be a data-race warning under Swift 6.
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in BannerWatcher.shared.fireRingBack() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ringBackTimer = timer
    }

    private func fireRingBack() {
        guard let pending = pendingAlert else { cancelRingBack(); return }
        let settings = AppState.shared.settings
        guard settings.notificationsEnabled, settings.ringBackEnabled, settings.bannerEnabled else {
            cancelRingBack()
            return
        }
        settings.playConfiguredSoundIfEnabled()
        postBanner(title: pending.title, body: "Still waiting — \(pending.body)")
    }

    /// Stop ring-back. Called when the user clicks/dismisses the banner, or
    /// when a fresh alert supersedes the pending one.
    func cancelRingBack() {
        ringBackTimer?.invalidate()
        ringBackTimer = nil
        pendingAlert = nil
    }

    private func postBanner(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Stamp the most likely Claude host app so a tap can focus it.
        if let host = Self.detectHostBundleID() {
            content.userInfo = ["targetBundleID": host]
        }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Best guess at which running app is hosting Claude right now, recorded
    /// at the moment the banner is posted (which is the moment Claude is
    /// waiting). Xcode wins if it's running, then a terminal.
    @MainActor
    private static func detectHostBundleID() -> String? {
        let candidates = [
            "com.apple.dt.Xcode",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
        ]
        let running = NSWorkspace.shared.runningApplications
        return candidates.first { id in
            running.contains { $0.bundleIdentifier == id }
        }
    }
}
