import SwiftUI
import AppKit

/// The popover that drops from the menu-bar icon. Intentionally minimal:
/// the two notification toggles, plus quick actions for the heavyweight
/// flows (open Settings, switch Xcode account, quit).
struct AlertMenuView: View {
    @EnvironmentObject var settings: AlertSettings
    @EnvironmentObject var accounts: AccountTracker
    @EnvironmentObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if updates.updateAvailable, let v = updates.latestVersion {
                Button {
                    dismissPopover()
                    updates.openDownloadPage()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Update available")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Version \(v) — click to download")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                Divider()
            }

            toggleRow(isOn: $settings.notificationsEnabled,
                      icon: "bell.badge.fill",
                      label: "Notifications")

            if settings.notificationsEnabled {
                toggleRow(isOn: $settings.soundEnabled,
                          icon: "speaker.wave.2.fill",
                          label: "Sound")
                    .padding(.leading, 24)
                toggleRow(isOn: $settings.bannerEnabled,
                          icon: "bell.fill",
                          label: "Banner")
                    .padding(.leading, 24)
            }

            Divider()

            actionButton("Open settings…", icon: "gearshape", shortcut: ",") {
                dismissPopover()
                NotificationCenter.default.post(name: .xhelperShowSettings, object: nil)
            }

            actionButton("Change Xcode account", icon: "person.crop.circle.badge.plus") {
                dismissPopover()
                accounts.openXcodeForAccountSwitch()
            }

            Divider()

            actionButton("Quit xHelperAlerts", icon: "power", shortcut: "q") {
                NSApp.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Row helpers

    /// Switch on the left, label on the right.
    private func toggleRow(isOn: Binding<Bool>, icon: String, label: String) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
            Spacer()
        }
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String, shortcut: KeyEquivalent? = nil, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    /// Close the MenuBarExtra popover by ordering out any visible
    /// window that floats above normal level. Avoids `cancelOperation:`,
    /// which beeps when no responder in the chain handles it.
    private func dismissPopover() {
        for window in NSApp.windows
            where window.isVisible
                && window.level.rawValue > NSWindow.Level.normal.rawValue
                && !(window is NSColorPanel)
                && !(window is NSPanel && window.title == "Settings") {
            window.orderOut(nil)
        }
    }
}
