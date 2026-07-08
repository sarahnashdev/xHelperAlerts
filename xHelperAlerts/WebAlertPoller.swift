import Foundation
import AppKit

/// Polls the xHelperAlerts relay Worker for alerts pushed by Claude Code
/// **cloud** sessions (claude.ai/code). Cloud sandboxes can't reach this
/// Mac, so the repo-installed hook (`xhelper-web-alert.sh`) POSTs each
/// Notification event to the relay and we fetch it here.
///
/// Received alerts are appended to `~/.xhelper-alerts/banner-request`,
/// the same file the local bash hooks write — so BannerWatcher applies
/// the identical sound / banner / ring-back pipeline with no special
/// casing.
@MainActor
final class WebAlertPoller {

    static let shared = WebAlertPoller()

    /// Single place the relay endpoint is defined on the Swift side.
    /// (The bundled `xhelper-web-alert.sh` hook embeds the same URL.)
    static let relayBase = URL(string: "https://xhelper-alert-relay.sarah-nashdev.workers.dev")!

    private static let pollInterval: TimeInterval = 5

    private var timer: Timer?
    private var inFlight = false

    /// Begin honoring the `webAlertsEnabled` setting. Call once at launch;
    /// safe to call `syncWithSettings()` again whenever the toggle changes.
    func start() {
        syncWithSettings()
    }

    /// Start or stop the poll timer to match the current setting.
    func syncWithSettings() {
        let enabled = AppState.shared.settings.webAlertsEnabled
        if enabled, timer == nil {
            let t = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
                Task { @MainActor in WebAlertPoller.shared.pollOnce() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            pollOnce() // immediate first poll so a pending alert isn't delayed
        } else if !enabled, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func pollOnce() {
        guard !inFlight else { return }
        let settings = AppState.shared.settings
        guard settings.webAlertsEnabled else { return }
        let token = settings.ensureWebAlertToken()

        var comps = URLComponents(url: Self.relayBase.appendingPathComponent("poll"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { return }

        inFlight = true
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, response, _ in
            Task { @MainActor in
                WebAlertPoller.shared.inFlight = false
                guard let data,
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                Self.deliver(pollResponse: data)
            }
        }.resume()
    }

    /// Hand each fetched alert to BannerWatcher via the banner-request file.
    private static func deliver(pollResponse data: Data) {
        struct PollResponse: Decodable {
            struct Alert: Decodable { let title: String?; let message: String? }
            let alerts: [Alert]
        }
        guard let decoded = try? JSONDecoder().decode(PollResponse.self, from: data),
              !decoded.alerts.isEmpty else { return }

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xhelper-alerts/banner-request")
        var lines = ""
        for alert in decoded.alerts {
            let title = (alert.title?.isEmpty == false ? alert.title! : "Claude (web)")
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let body = (alert.message?.isEmpty == false ? alert.message! : "Claude needs your attention")
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            lines += "\(title)\t\(body)\n"
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(lines.utf8))
        } else {
            try? lines.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Per-repo hook installer

/// Writes the cloud-alert hook into a chosen repository so claude.ai/code
/// sessions of that repo relay their Notification events to this Mac.
/// Cloud sessions only honor the repo's own `.claude/settings.json` —
/// user-level `~/.claude/settings.json` is ignored there — hence per-repo
/// installation.
enum WebAlertRepoInstaller {

    /// Copies `xhelper-web-alert.sh` into `<repo>/.claude/hooks/` and
    /// registers it (with the device token as argv[1]) under the
    /// Notification hook in `<repo>/.claude/settings.json`. Idempotent.
    @MainActor
    static func install(into repo: URL, token: String) throws {
        let fm = FileManager.default

        guard let bundled = Bundle.main.resourceURL.flatMap({ res -> URL? in
            let flat = res.appendingPathComponent("xhelper-web-alert.sh")
            let nested = res.appendingPathComponent("hooks/xhelper-web-alert.sh")
            if fm.fileExists(atPath: nested.path) { return nested }
            if fm.fileExists(atPath: flat.path) { return flat }
            return nil
        }) else {
            throw NSError(domain: "xHelperAlerts", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled xhelper-web-alert.sh not found"])
        }

        let hooksDir = repo.appendingPathComponent(".claude/hooks", isDirectory: true)
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let dstScript = hooksDir.appendingPathComponent("xhelper-web-alert.sh")
        if fm.fileExists(atPath: dstScript.path) { try? fm.removeItem(at: dstScript) }
        try fm.copyItem(at: bundled, to: dstScript)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstScript.path)

        // The command must resolve inside the cloud sandbox, so reference the
        // script through $CLAUDE_PROJECT_DIR rather than an absolute Mac path.
        let command = "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/xhelper-web-alert.sh\" \(token)"

        let settingsURL = repo.appendingPathComponent(".claude/settings.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        hooks["Notification"] = merged(into: hooks["Notification"], command: command)
        root["hooks"] = hooks

        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: settingsURL, options: .atomic)
    }

    /// Same merge shape as FirstRunInstaller.mergedHook — append the command
    /// once, tolerating an existing entry. Stale entries with an *old* token
    /// for the same script are replaced rather than accumulated.
    private static func merged(into existing: Any?, command: String) -> [[String: Any]] {
        var bucket = (existing as? [[String: Any]]) ?? []
        bucket.removeAll { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { h in
                guard let c = h["command"] as? String else { return false }
                return c.contains("xhelper-web-alert.sh") && c != command
            }
        }
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
}
