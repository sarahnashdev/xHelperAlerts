import Foundation
import SwiftUI
import AppKit
import Combine

/// Tracks which Claude account Xcode's Coding Assistant is currently
/// signed into, plus a history of accounts ever seen on this Mac so the
/// user can give each one a custom label and tint.
///
/// Source of truth for the *active* account is
/// `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/.claude.json`.
/// We watch that file via DispatchSource so a sign-in/out in Xcode shows
/// up in our UI without polling.
///
/// Our own history (label + color per account) lives in
/// `~/.xhelper-alerts/accounts.json`.
@MainActor
final class AccountTracker: ObservableObject {
    @Published private(set) var accounts: [RememberedAccount] = []
    @Published private(set) var activeUuid: String?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var pollTimer: Timer?
    private var lastSeenContentHash: Int?

    init() {
        load()
        refreshFromXcode()
        startWatching()
        // Don't touch NSApp here — it may not be ready during App.init().
        // AppDelegate.applicationDidFinishLaunching applies the dock icon
        // once the application is alive.
    }

    deinit {
        watcher?.cancel()
    }

    // MARK: - Public API

    var active: RememberedAccount? {
        accounts.first { $0.id == activeUuid }
    }

    var inactive: [RememberedAccount] {
        accounts.filter { $0.id != activeUuid }
    }

    func setLabel(_ label: String, for id: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].label = label
        save()
    }

    func setGlyphColor(_ color: ColorRGBA?, for id: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].glyphColor = color
        save()
    }

    func setTextColor(_ color: ColorRGBA?, for id: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].textColor = color
        save()
    }

    func forget(_ id: String) {
        accounts.removeAll { $0.id == id }
        if activeUuid == id { activeUuid = nil }
        save()
    }

    /// Activates Xcode and (best-effort) sends Cmd+, to open its
    /// Settings window. The keystroke needs Accessibility permission
    /// for xHelperAlerts; if it's not granted, Xcode still comes
    /// forward and the user is shown a one-click path into the
    /// Accessibility settings pane.
    ///
    /// We deliberately don't try to mutate Xcode's keychain entries —
    /// that schema is undocumented and would break on each Claude
    /// update.
    func openXcodeForAccountSwitch() {
        // Step 1: bring Xcode forward. `open -a` never needs special
        // permission, so this always works.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Xcode"]
        try? open.run()
        open.waitUntilExit()

        // Step 2: try Cmd+, via osascript. Fails (exit 1) if the user
        // hasn't granted Accessibility permission. Don't surface the
        // raw error — show a friendly prompt instead.
        let script = "tell application \"System Events\" to tell process \"Xcode\" to keystroke \",\" using command down"
        let keystroke = Process()
        keystroke.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        keystroke.arguments = ["-e", script]
        keystroke.standardError = Pipe()
        try? keystroke.run()
        keystroke.waitUntilExit()
        if keystroke.terminationStatus != 0 {
            DispatchQueue.main.async { Self.promptForAccessibility() }
        }
    }

    /// Opens System Settings directly to Privacy & Security →
    /// Accessibility, so the user can flip xHelperAlerts on.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Let xHelperAlerts open Xcode Settings for you"
        alert.informativeText = """
        Xcode is open. To skip the manual Cmd+, step next time, allow xHelperAlerts in System Settings → Privacy & Security → Accessibility, then try again.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not now")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    // MARK: - Persistence (our own remembered list)

    private static let configDir = ".xhelper-alerts"
    private static let accountsFile = "accounts.json"

    private static var accountsURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(configDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(accountsFile)
    }

    private struct Persisted: Codable {
        var accounts: [RememberedAccount]
        var active_uuid: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.accountsURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        self.accounts = p.accounts
        self.activeUuid = p.active_uuid
    }

    private func save() {
        let p = Persisted(accounts: accounts, active_uuid: activeUuid)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(p) else { return }
        try? data.write(to: Self.accountsURL, options: .atomic)
        // One colour drives both dock and menu-bar badge.
        let color = active?.glyphColor
        DispatchQueue.main.async {
            IconRenderer.apply(activeColor: color)
        }
    }

    // MARK: - Reading Xcode's .claude.json

    private static var xcodeClaudeJSON: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/.claude.json")
    }

    private struct XcodeClaude: Decodable {
        struct OAuth: Decodable {
            let accountUuid: String?
            let emailAddress: String?
            let organizationUuid: String?
        }
        let oauthAccount: OAuth?
    }

    func refreshFromXcode() {
        guard let data = try? Data(contentsOf: Self.xcodeClaudeJSON),
              let parsed = try? JSONDecoder().decode(XcodeClaude.self, from: data),
              let oauth = parsed.oauthAccount,
              let uuid = oauth.accountUuid,
              let email = oauth.emailAddress
        else {
            if activeUuid != nil {
                activeUuid = nil
                save()
            }
            return
        }
        let now = ISO8601DateFormatter().string(from: Date())
        if let idx = accounts.firstIndex(where: { $0.id == uuid }) {
            accounts[idx].emailAddress = email
            accounts[idx].organizationUuid = oauth.organizationUuid
            accounts[idx].lastSeenISO = now
        } else {
            accounts.append(RememberedAccount(
                id: uuid,
                emailAddress: email,
                organizationUuid: oauth.organizationUuid,
                label: "",
                glyphColor: nil,
                textColor: nil,
                firstSeenISO: now,
                lastSeenISO: now
            ))
        }
        if activeUuid != uuid {
            activeUuid = uuid
        }
        save()
    }

    // MARK: - File watcher
    //
    // Xcode rewrites `.claude.json` atomically — it writes a temp file
    // then renames it over the original. A watch on the file's own
    // descriptor is held on the old inode and silently misses the
    // replacement. So we watch the *parent directory* instead (its
    // inode doesn't go away) and a 2s polling timer is a belt-and-
    // braces backup for any platform edge case.

    private func startWatching() {
        let url = Self.xcodeClaudeJSON
        let parent = url.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let fd = open(parent, O_EVTONLY)
        if fd >= 0 {
            self.watchedFD = fd
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete, .attrib],
                queue: DispatchQueue.main
            )
            source.setEventHandler { [weak self] in
                // Small delay lets atomic-rename complete before we read.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.refreshIfChanged()
                }
            }
            source.setCancelHandler { [fd] in close(fd) }
            source.resume()
            self.watcher = source
        }

        // Backup poller for cases where the dir-event misses (network
        // FS, sandboxing quirks, etc.). 2-second tick is barely
        // perceptible and basically free.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshIfChanged() }
        }
    }

    /// Read `.claude.json`, compute a quick content hash, and only call
    /// `refreshFromXcode()` when the bytes actually changed. Avoids
    /// firing publisher updates from the 2s poll on every tick.
    private func refreshIfChanged() {
        let data = (try? Data(contentsOf: Self.xcodeClaudeJSON)) ?? Data()
        let hash = data.hashValue
        if hash == lastSeenContentHash { return }
        lastSeenContentHash = hash
        refreshFromXcode()
    }
}

// MARK: - Model

struct RememberedAccount: Codable, Identifiable, Equatable {
    /// The Claude oauthAccount UUID. Stable across logins.
    var id: String
    var emailAddress: String
    var organizationUuid: String?
    /// User-defined short name shown in the menu bar (if enabled). Empty
    /// string means "no custom label — fall back to email or org".
    var label: String
    /// Single tint applied to both the menu-bar badge and dock icon.
    /// Falls back to the default MenuBarIcon asset if nil.
    var glyphColor: ColorRGBA?
    /// Menu-bar label text colour. Falls back to system primary if nil.
    var textColor: ColorRGBA?
    var firstSeenISO: String
    var lastSeenISO: String

    /// Short label suitable for the menu bar. Prefers the custom label,
    /// then the email's local-part, then the first 6 chars of the UUID.
    var menuBarLabel: String {
        if !label.isEmpty { return label }
        if let at = emailAddress.firstIndex(of: "@") {
            return String(emailAddress[..<at])
        }
        return String(id.prefix(6))
    }
}

struct ColorRGBA: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
}

extension Color {
    init(_ rgba: ColorRGBA) {
        self = Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

extension ColorRGBA {
    init?(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let c = ns else { return nil }
        self.r = Double(c.redComponent)
        self.g = Double(c.greenComponent)
        self.b = Double(c.blueComponent)
        self.a = Double(c.alphaComponent)
    }
}
