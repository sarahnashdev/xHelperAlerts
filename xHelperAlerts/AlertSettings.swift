import Foundation
import SwiftUI
import Combine
import UserNotifications

/// Persistent settings for xHelperAlerts. Backed by
/// `~/.xhelper-alerts/config.json` so the hook scripts can read the same
/// state without round-tripping through the app.
@MainActor
final class AlertSettings: ObservableObject {
    /// Master switch. When OFF, neither sound nor banner ever fires —
    /// the sub-toggles are hidden from the UI until this is re-enabled.
    @Published var notificationsEnabled: Bool  { didSet { save() } }
    @Published var soundEnabled: Bool          { didSet { syncMasterIfAllOff(); save() } }
    @Published var bannerEnabled: Bool         { didSet { syncMasterIfAllOff(); save() } }
    @Published var autoApproveEnabled: Bool    { didSet { save() } }
    /// When auto-approve is on, also chime/banner so the user hears that
    /// Claude ran something. Off = auto-approve is fully silent.
    @Published var notifyOnAutoApprove: Bool   { didSet { save() } }
    /// Name of the macOS system sound (without ".aiff"), e.g. "Hero", "Glass".
    @Published var soundName: String           { didSet { save() } }
    /// Show the active Claude account next to the menu-bar glyph.
    @Published var showAccountLabelInMenuBar: Bool { didSet { save() } }
    /// Which form of the account name to render in the menu bar.
    @Published var accountLabelMode: AccountLabelMode { didSet { save() } }
    /// Keep re-alerting (sound + banner) at a fixed interval until the
    /// user clicks the banner. Off = single alert, the default.
    @Published var ringBackEnabled: Bool       { didSet { save() } }
    /// Minutes between ring-back reminders when `ringBackEnabled` is on.
    @Published var ringBackMinutes: Int        { didSet { save() } }
    /// Alert on every tool Claude runs (each Bash/Edit/Write), not just on
    /// Claude's explicit "waiting for you" event. Essential for Xcode, where
    /// Claude doesn't reliably fire that waiting event. On = more frequent.
    @Published var alertOnEveryTool: Bool      { didSet { save() } }

    init() {
        let loaded = Self.load()
        self.notificationsEnabled       = loaded.notificationsEnabled
        self.soundEnabled               = loaded.soundEnabled
        self.bannerEnabled              = loaded.bannerEnabled
        self.autoApproveEnabled         = loaded.autoApproveEnabled
        self.notifyOnAutoApprove        = loaded.notifyOnAutoApprove
        self.soundName                  = loaded.soundName
        self.showAccountLabelInMenuBar  = loaded.showAccountLabelInMenuBar
        self.accountLabelMode           = loaded.accountLabelMode
        self.ringBackEnabled            = loaded.ringBackEnabled
        self.ringBackMinutes            = loaded.ringBackMinutes
        self.alertOnEveryTool           = loaded.alertOnEveryTool
    }

    /// When the user turns off both Sound and Banner, the master
    /// Notifications switch collapses too. Deferred to the next
    /// runloop tick so we don't publish state changes inside the
    /// current view update (SwiftUI warns about that).
    private func syncMasterIfAllOff() {
        guard notificationsEnabled, !soundEnabled, !bannerEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.notificationsEnabled, !self.soundEnabled, !self.bannerEnabled {
                self.notificationsEnabled = false
            }
        }
    }

    // MARK: - Storage

    static let configDirName = ".xhelper-alerts"

    private static var configURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(configDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    private struct Persisted: Codable {
        var notifications_enabled: Bool?
        var sound_enabled: Bool
        var banner_enabled: Bool
        var auto_approve_enabled: Bool
        var notify_on_auto_approve: Bool?
        var sound_name: String?
        var show_account_label_in_menu_bar: Bool?
        var account_label_mode: String?
        var ring_back_enabled: Bool?
        var ring_back_minutes: Int?
        var alert_on_every_tool: Bool?
    }

    static let defaultRingBackMinutes = 5

    static let defaultSoundName = "Hero"

    private struct Loaded {
        var notificationsEnabled: Bool
        var soundEnabled: Bool
        var bannerEnabled: Bool
        var autoApproveEnabled: Bool
        var notifyOnAutoApprove: Bool
        var soundName: String
        var showAccountLabelInMenuBar: Bool
        var accountLabelMode: AccountLabelMode
        var ringBackEnabled: Bool
        var ringBackMinutes: Int
        var alertOnEveryTool: Bool
    }

    private static func load() -> Loaded {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data)
        else {
            return Loaded(
                notificationsEnabled: true,
                soundEnabled: true, bannerEnabled: true,
                autoApproveEnabled: false, notifyOnAutoApprove: false,
                soundName: defaultSoundName,
                showAccountLabelInMenuBar: true,
                accountLabelMode: .customLabel,
                ringBackEnabled: false,
                ringBackMinutes: defaultRingBackMinutes,
                alertOnEveryTool: false
            )
        }
        return Loaded(
            notificationsEnabled:      decoded.notifications_enabled ?? true,
            soundEnabled:              decoded.sound_enabled,
            bannerEnabled:             decoded.banner_enabled,
            autoApproveEnabled:        decoded.auto_approve_enabled,
            notifyOnAutoApprove:       decoded.notify_on_auto_approve ?? false,
            soundName:                 decoded.sound_name ?? defaultSoundName,
            showAccountLabelInMenuBar: decoded.show_account_label_in_menu_bar ?? true,
            accountLabelMode:          AccountLabelMode(rawValue: decoded.account_label_mode ?? "") ?? .customLabel,
            ringBackEnabled:           decoded.ring_back_enabled ?? false,
            ringBackMinutes:           decoded.ring_back_minutes ?? defaultRingBackMinutes,
            alertOnEveryTool:          decoded.alert_on_every_tool ?? false
        )
    }

    private func save() {
        let persisted = Persisted(
            notifications_enabled:          notificationsEnabled,
            sound_enabled:                  soundEnabled,
            banner_enabled:                 bannerEnabled,
            auto_approve_enabled:           autoApproveEnabled,
            notify_on_auto_approve:         notifyOnAutoApprove,
            sound_name:                     soundName,
            show_account_label_in_menu_bar: showAccountLabelInMenuBar,
            account_label_mode:             accountLabelMode.rawValue,
            ring_back_enabled:              ringBackEnabled,
            ring_back_minutes:              ringBackMinutes,
            alert_on_every_tool:            alertOnEveryTool
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(persisted) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
    }

    // MARK: - Sound catalog

    /// Available system sounds, detected from `/System/Library/Sounds/` at
    /// runtime. Falls back to a hard-coded list if the directory can't be
    /// enumerated.
    static var availableSounds: [String] {
        let dir = "/System/Library/Sounds"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            let detected = names
                .filter { $0.lowercased().hasSuffix(".aiff") }
                .map { String($0.dropLast(5)) }
                .sorted()
            if !detected.isEmpty { return detected }
        }
        return ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    }

    // MARK: - Manual triggers

    /// Single test action — writes one alert request to the file pipeline.
    /// BannerWatcher then applies the user's sound + banner preferences (and
    /// arms ring-back if enabled), so the test exercises the exact same path
    /// a real Claude notification does.
    func testNotifications() {
        guard notificationsEnabled, soundEnabled || bannerEnabled else { return }
        Self.postBanner(title: "xHelperAlerts", body: "xHelperAlerts is listening")
    }

    /// Play the user's configured alert tone, honoring the master + sound
    /// toggles. Called by BannerWatcher when it shows a banner and on each
    /// ring-back reminder, so there's a single source of alert sound.
    func playConfiguredSoundIfEnabled() {
        guard notificationsEnabled, soundEnabled else { return }
        Self.playSound(named: soundName)
    }

    /// Posts a banner via the native UserNotifications framework — no
    /// osascript, no Script Editor pop-up on macOS Tahoe. Permission is
    /// requested on first call; if the user later turns the app off in
    /// System Settings → Notifications, the request silently no-ops.
    private static func postBanner(title: String, body: String) {
        // Route through BannerWatcher's file pipeline — it's the
        // delegate that forces foreground banners to show, and going
        // through the file keeps a single code path.
        let req = "\(title)\t\(body)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xhelper-alerts/banner-request")
        if let data = req.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? req.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func previewSound(_ name: String) {
        Self.playSound(named: name)
    }

    private static func playSound(named name: String) {
        runShell("/usr/bin/afplay", args: ["/System/Library/Sounds/\(name).aiff"])
    }

    private static func runShell(_ launchPath: String, args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        try? proc.run()
    }

    /// Version string read from the bundle's Info.plist
    /// (`CFBundleShortVersionString`). Defaults to "?" if not set.
    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
}

/// Which form of the active account's name shows next to the menu-bar
/// glyph when `showAccountLabelInMenuBar` is on.
enum AccountLabelMode: String, CaseIterable, Identifiable {
    case customLabel = "label"
    case email
    case organization = "org"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .customLabel:  return "Custom label"
        case .email:        return "Email"
        case .organization: return "Organization"
        }
    }
}
