import SwiftUI
import AppKit
import Combine

/// xHelperAlerts — menu-bar app that pings you when Claude Code needs
/// approval and (optionally) auto-approves Claude's tool requests.
///
/// Architecture:
///   • A shared `AppState` owns the two ObservableObjects (settings +
///     accounts). Both AppKit (AppDelegate) and SwiftUI (views) read
///     from the same instance.
///   • AppDelegate drives the menu-bar status item with **`NSStatusItem`
///     directly** rather than SwiftUI's `MenuBarExtra` — the latter
///     doesn't reliably re-render its label when state changes, which
///     made dynamic glyph/text/label colours impossible.
///   • The popover is an `NSPopover` hosting `AlertMenuView`. The
///     Settings window is an `NSWindow` hosting `SettingsView`.
@main
struct XHelperAlertsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        FirstRunInstaller.runIfNeeded()
        _ = AppState.shared
    }

    /// SwiftUI requires at least one Scene. We use the standard
    /// `Settings` scene with an empty view — it's a no-op container
    /// that doesn't show automatically. We replace the default
    /// Settings menu item so Cmd+, and "xHelperAlerts → Settings…"
    /// route to AppDelegate's real tabbed window instead of opening
    /// an empty SwiftUI Settings window.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        NotificationCenter.default.post(
                            name: .xhelperShowSettings, object: nil
                        )
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

/// Singleton container for the app's two ObservableObjects so both
/// SwiftUI and AppKit can read from the same instances.
@MainActor
final class AppState {
    static let shared = AppState()
    let settings: AlertSettings
    let accounts: AccountTracker
    let updates: UpdateChecker
    private init() {
        self.settings = AlertSettings()
        self.accounts = AccountTracker()
        self.updates = UpdateChecker()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let xhelperShowSettings = Notification.Name("xhelper.show.settings")
}

// MARK: - AppDelegate

/// Owns: the menu-bar status item, the popover, the Settings window,
/// and a Combine subscription that refreshes the status item whenever
/// settings or accounts publishes a change.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsController: NSWindowController?
    private var cancellables = Set<AnyCancellable>()

    private var state: AppState { AppState.shared }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // First-launch DMG check — if the user launched us straight
        // from the disk image, prompt to install + auto-eject. Returns
        // immediately when the app is already in /Applications.
        MoveToApplications.promptIfRunningFromDMG()

        installStatusItem()
        installPopover()
        subscribeToStateChanges()
        BannerWatcher.shared.start()
        WebAlertPoller.shared.start()
        refreshStatusItem()
        IconRenderer.apply(activeColor: state.accounts.active?.glyphColor)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowSettings),
            name: .xhelperShowSettings, object: nil
        )

        let key = "xhelper_didShowSettings_v1"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showSettingsWindow()
            }
        }
    }

    @objc private func handleShowSettings() { showSettingsWindow() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If this reopen was triggered by tapping a notification banner, the
        // BannerWatcher already handled it by focusing the Claude host app —
        // don't ALSO pop the Settings window and steal focus back.
        if let clicked = BannerWatcher.lastBannerClickAt,
           Date().timeIntervalSince(clicked) < 2.0 {
            return true
        }
        showSettingsWindow()
        return true
    }

    // MARK: - Status item

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        // Without this, the action only fires on left click. We want
        // either left or right to toggle.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Read current state and update the status item's image + title.
    /// This is the single source of truth for what the menu bar shows.
    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let active = state.accounts.active
        let updateAvailable = state.updates.updateAvailable

        // Glyph — when a colour is set, draw a rounded colored badge
        // with the white DockGlyph centred inside it. Otherwise fall
        // back to the bundled MenuBarIcon (template, system-tinted).
        var glyphImage: NSImage
        if let rgba = active?.glyphColor {
            glyphImage = Self.menuBarBadge(tint: Self.nsColor(rgba))
            glyphImage.isTemplate = false
        } else if let plain = NSImage(named: "MenuBarIcon") {
            glyphImage = plain
        } else {
            glyphImage = NSImage()
        }
        if updateAvailable {
            glyphImage = Self.overlayUpdateDot(on: glyphImage)
            glyphImage.isTemplate = false
        }
        button.image = glyphImage
        button.imagePosition = .imageLeading

        // Label text
        if state.settings.showAccountLabelInMenuBar, let text = labelText(for: active) {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: active?.textColor.map { Self.nsColor($0) } ?? NSColor.labelColor,
                .font: NSFont.menuBarFont(ofSize: 0)
            ]
            button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
        } else {
            button.attributedTitle = NSAttributedString()
            button.title = ""
        }
    }

    /// Subscribe to objectWillChange on both ObservableObjects so any
    /// state mutation triggers a status-item refresh on the next
    /// runloop tick.
    private func subscribeToStateChanges() {
        state.accounts.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshStatusItem() }
            .store(in: &cancellables)
        state.settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshStatusItem() }
            .store(in: &cancellables)
        state.updates.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshStatusItem() }
            .store(in: &cancellables)
    }

    private func labelText(for account: RememberedAccount?) -> String? {
        guard let a = account else { return nil }
        switch state.settings.accountLabelMode {
        case .customLabel:
            return a.label.isEmpty ? a.menuBarLabel : a.label
        case .email:
            return a.emailAddress
        case .organization:
            return a.organizationUuid.map { String($0.prefix(8)) } ?? a.menuBarLabel
        }
    }

    // MARK: - Popover

    private func installPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView:
            AlertMenuView()
                .environmentObject(state.settings)
                .environmentObject(state.accounts)
                .environmentObject(state.updates)
        )
        popover.contentViewController = hosting
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Settings window

    func showSettingsWindow() {
        if popover.isShown { popover.performClose(nil) }

        if let existing = settingsController?.window {
            bringToFront(existing)
            return
        }
        let view = SettingsView()
            .environmentObject(state.settings)
            .environmentObject(state.accounts)
            .environmentObject(state.updates)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "xHelperAlerts Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(NSSize(width: 700, height: 580))
        window.center()
        window.delegate = self
        settingsController = NSWindowController(window: window)
        bringToFront(window)
    }

    private func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        Self.dismissColorPanel()
    }

    func windowWillClose(_ notification: Notification) {
        Self.dismissColorPanel()
    }

    static func dismissColorPanel() {
        if NSColorPanel.sharedColorPanelExists {
            NSColorPanel.shared.orderOut(nil)
        }
    }

    func dismissColorPanel() { Self.dismissColorPanel() }

    // MARK: - Image helpers

    /// Place a small red "update available" dot to the **right** of
    /// the glyph (not on top of it), in the upper portion of the
    /// status-item area so it sits visually above where the label
    /// text appears.
    private static func overlayUpdateDot(on base: NSImage) -> NSImage {
        let glyphSize = base.size == .zero ? NSSize(width: 18, height: 18) : base.size
        let dotDiameter: CGFloat = 7
        let gap: CGFloat = 3
        let canvas = NSSize(width: glyphSize.width + gap + dotDiameter,
                            height: glyphSize.height)
        let composed = NSImage(size: canvas)
        composed.lockFocus()
        defer { composed.unlockFocus() }
        // Glyph on the left, vertically centred.
        base.draw(in: NSRect(origin: .zero, size: glyphSize),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        // Dot to the right of the glyph, top-aligned so it floats
        // above where the label text would sit.
        let dot = NSRect(x: glyphSize.width + gap,
                         y: canvas.height - dotDiameter - 1,
                         width: dotDiameter, height: dotDiameter)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dot).fill()
        return composed
    }

    /// Render the rounded coloured badge with the white DockGlyph in
    /// the centre — same look as the dock icon, just at menu-bar size.
    private static func menuBarBadge(tint: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.addClip()
        tint.setFill()
        path.fill()
        if let glyph = NSImage(named: "DockGlyph") {
            // Minimal inset so the spark + stars dominate the badge.
            let inset: CGFloat = 2
            let glyphRect = rect.insetBy(dx: inset, dy: inset)
            glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        return image
    }

    fileprivate static func nsColor(_ rgba: ColorRGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(rgba.r),
                green: CGFloat(rgba.g),
                blue: CGFloat(rgba.b),
                alpha: CGFloat(rgba.a))
    }
}
