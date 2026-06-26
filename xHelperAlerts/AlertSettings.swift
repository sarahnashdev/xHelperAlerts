import Foundation
import SwiftUI
import Combine

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
    }

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
                accountLabelMode: .customLabel
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
            accountLabelMode:          AccountLabelMode(rawValue: decoded.account_label_mode ?? "") ?? .customLabel
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
            account_label_mode:             accountLabelMode.rawValue
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

    /// Single test action — fires whichever of {sound, banner} the user
    /// has currently enabled. If neither is on (or notifications are
    /// off altogether), does nothing.
    func testNotifications() {
        guard notificationsEnabled else { return }
        if soundEnabled { Self.playSound(named: soundName) }
        if bannerEnabled {
            Self.runShell("/usr/bin/osascript", args: [
                "-e",
                """
                display notification "xHelperAlerts is listening" with title "xHelperAlerts"
                """
            ])
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

    // MARK: - Diagnostics

    var hooksInstalled: Bool {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("\(Self.configDirName)/hooks")
        return fm.fileExists(atPath: dir.appendingPathComponent("xHelperAlerts.sh").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("xhelper-auto-approve.sh").path)
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
