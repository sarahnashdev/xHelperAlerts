import Foundation
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

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        attachWatcher()
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
            postBanner(title: title, body: body)
        }
    }

    private func postBanner(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
