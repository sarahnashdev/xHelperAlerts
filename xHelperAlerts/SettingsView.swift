import SwiftUI
import AppKit

/// The main Settings window. Six tabs, each with short single-word
/// labels so macOS's tab bar never collapses to an overflow chevron.
struct SettingsView: View {
    @EnvironmentObject var settings: AlertSettings
    @EnvironmentObject var accounts: AccountTracker

    @State private var selectedTab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general, accounts, history, hooks, about, updates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:  return "General"
            case .accounts: return "Accounts"
            case .history:  return "History"
            case .hooks:    return "Hooks"
            case .about:    return "About"
            case .updates:  return "Updates"
            }
        }
        var icon: String {
            switch self {
            case .general:  return "gearshape"
            case .accounts: return "person.crop.circle"
            case .history:  return "list.bullet.rectangle"
            case .hooks:    return "link.circle"
            case .about:    return "info.circle"
            case .updates:  return "sparkles"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                GeneralSettingsTab()
                    .tabItem { Label(Tab.general.title, systemImage: Tab.general.icon) }
                    .tag(Tab.general)

                AccountsSettingsTab()
                    .tabItem { Label(Tab.accounts.title, systemImage: Tab.accounts.icon) }
                    .tag(Tab.accounts)

                CommandLogView()
                    .tabItem { Label(Tab.history.title, systemImage: Tab.history.icon) }
                    .tag(Tab.history)

                HooksSettingsTab()
                    .tabItem { Label(Tab.hooks.title, systemImage: Tab.hooks.icon) }
                    .tag(Tab.hooks)

                AboutView()
                    .tabItem { Label(Tab.about.title, systemImage: Tab.about.icon) }
                    .tag(Tab.about)

                VersionHistoryView()
                    .tabItem { Label(Tab.updates.title, systemImage: Tab.updates.icon) }
                    .tag(Tab.updates)
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit xHelperAlerts") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 580)
        .onChange(of: selectedTab) { _, _ in
            AppDelegate.dismissColorPanel()
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AlertSettings
    @EnvironmentObject var accounts: AccountTracker

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Notifications", isOn: $settings.notificationsEnabled)

                if settings.notificationsEnabled {
                    Toggle("Sound", isOn: $settings.soundEnabled)
                    Picker("Tone", selection: $settings.soundName) {
                        ForEach(AlertSettings.availableSounds, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .disabled(!settings.soundEnabled)
                    .onChange(of: settings.soundName) { _, new in
                        settings.previewSound(new)
                    }

                    Toggle("Banner", isOn: $settings.bannerEnabled)

                    Toggle("Alert on every tool Claude runs", isOn: $settings.alertOnEveryTool)
                        .help("On: sound/banner on each Bash, Edit, or Write — recommended for Xcode, where Claude doesn't signal when it's waiting. Off: only alert when Claude is explicitly waiting for you.")
                    Text(settings.alertOnEveryTool
                         ? "Alerts on every file edit or command Claude runs (best for Xcode)."
                         : "Only alerts when Claude is explicitly waiting for you (quieter; can miss Xcode prompts).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.bannerEnabled {
                        Toggle("Remind me until I click the banner", isOn: $settings.ringBackEnabled)
                            .help("Repeats the alert at the interval below until you click the banner to acknowledge it.")
                        if settings.ringBackEnabled {
                            Stepper(value: $settings.ringBackMinutes, in: 1...120) {
                                Text("Remind every ^[\(settings.ringBackMinutes) minute](inflect: true)")
                            }
                        }
                    }

                    HStack {
                        Button("Test notifications") {
                            settings.testNotifications()
                        }
                        .disabled(!(settings.soundEnabled || settings.bannerEnabled))
                        Spacer()
                    }
                }
            }

            Section("Auto-approve") {
                Toggle("Auto-approve Claude tool calls (CLI only)", isOn: $settings.autoApproveEnabled)
                    .help("Doesn't bypass Xcode's permission prompts — Xcode shows its own approval UI regardless of this toggle.")
                Toggle("Still notify me when Claude runs", isOn: $settings.notifyOnAutoApprove)
                    .disabled(!settings.autoApproveEnabled)
                if settings.autoApproveEnabled {
                    Text("⚠️ Claude can run code without asking (CLI only). Turn this off when you're not at the keyboard.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Accounts

private struct AccountsSettingsTab: View {
    @EnvironmentObject var accounts: AccountTracker
    @EnvironmentObject var settings: AlertSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let active = accounts.active {
                    CustomizationCard(account: active)
                    AccountPreviewCard(account: active)
                } else {
                    noAccount
                }
                remembered
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private var noAccount: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Claude account detected in Xcode.")
                .font(.subheadline)
            Text("Open Xcode → Settings → Coding Assistant to sign in. xHelperAlerts will detect the change automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Xcode") { accounts.openXcodeForAccountSwitch() }
                .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var remembered: some View {
        let inactive = accounts.inactive
        if !inactive.isEmpty {
            Text("Remembered (signed out)")
                .font(.headline)
                .padding(.top, 4)
            VStack(spacing: 8) {
                ForEach(inactive) { account in
                    InactiveAccountCard(account: account)
                }
            }
        }
    }
}

/// Top-of-tab customisation — label settings + colour controls. Uses
/// direct bindings into the AccountTracker so there's no @State / onChange
/// loop (which triggers SwiftUI's "publishing changes within view
/// updates" warning and silently drops updates).
private struct CustomizationCard: View {
    let account: RememberedAccount
    @EnvironmentObject var accounts: AccountTracker
    @EnvironmentObject var settings: AlertSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Customization")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show account in menu bar", isOn: $settings.showAccountLabelInMenuBar)
                if settings.showAccountLabelInMenuBar {
                    Picker("Show", selection: $settings.accountLabelMode) {
                        ForEach(AccountLabelMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if settings.accountLabelMode == .customLabel {
                        TextField("Custom label (e.g. \"Work\")", text: labelBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Colors")
                    .font(.subheadline.weight(.semibold))
                colorRow("Toolbar icon", binding: colorBinding(\.glyphColor, set: accounts.setGlyphColor), hasValue: account.glyphColor != nil)
                colorRow("Text", binding: colorBinding(\.textColor, set: accounts.setTextColor), hasValue: account.textColor != nil)
                Text("The Toolbar icon colour also tints the dock icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Bindings

    private var labelBinding: Binding<String> {
        Binding(
            get: { account.label },
            set: { accounts.setLabel($0, for: account.id) }
        )
    }

    /// Generic Color binding that reads a colour off the account via
    /// the given key path and writes through the tracker's setter.
    private func colorBinding(_ keyPath: KeyPath<RememberedAccount, ColorRGBA?>,
                              set setter: @escaping (ColorRGBA?, String) -> Void)
                              -> Binding<Color> {
        Binding(
            get: { account[keyPath: keyPath].map { Color($0) } ?? .clear },
            set: { new in
                if new == .clear {
                    setter(nil, account.id)
                } else if let rgba = ColorRGBA(new) {
                    setter(rgba, account.id)
                }
            }
        )
    }

    private func colorRow(_ title: String,
                          binding: Binding<Color>,
                          hasValue: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 110, alignment: .leading)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
            Button("Reset") { binding.wrappedValue = .clear }
                .buttonStyle(.borderless)
                .disabled(!hasValue)
            Spacer()
        }
    }
}

/// Identity card for the active account, with a live preview of what
/// the menu-bar entry will look like given the current customisation.
private struct AccountPreviewCard: View {
    let account: RememberedAccount
    @EnvironmentObject var accounts: AccountTracker
    @EnvironmentObject var settings: AlertSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.emailAddress)
                        .font(.headline)
                    if let org = account.organizationUuid {
                        Text("Org: \(org)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Text("Signed in")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.15), in: Capsule())
            }

            Divider()

            HStack(spacing: 6) {
                Text("Menu-bar preview:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                glyphPreview
                if settings.showAccountLabelInMenuBar, let text = labelPreview {
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(textTint ?? AnyShapeStyle(.primary))
                }
                Spacer()
            }

            HStack {
                Button("Change Xcode account") {
                    accounts.openXcodeForAccountSwitch()
                }
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var glyphPreview: some View {
        if let rgba = account.glyphColor {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(rgba))
                Image("DockGlyph")
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
            .frame(width: 22, height: 22)
        } else {
            Image("MenuBarIcon")
        }
    }

    private var textTint: AnyShapeStyle? {
        guard let rgba = account.textColor else { return nil }
        return AnyShapeStyle(Color(rgba).adjustedForAppearance(colorScheme))
    }

    private var labelPreview: String? {
        switch settings.accountLabelMode {
        case .customLabel:
            return account.label.isEmpty ? account.menuBarLabel : account.label
        case .email:
            return account.emailAddress
        case .organization:
            return account.organizationUuid.map { String($0.prefix(8)) } ?? account.menuBarLabel
        }
    }
}

/// Compact card for accounts that aren't currently signed in. Just
/// identity + a Forget button — full customisation is reserved for the
/// active account.
private struct InactiveAccountCard: View {
    let account: RememberedAccount
    @EnvironmentObject var accounts: AccountTracker

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.emailAddress)
                    .font(.subheadline.weight(.semibold))
                Text("Last used \(prettyDate(account.lastSeenISO))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Signed out")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            Button("Forget", role: .destructive) {
                accounts.forget(account.id)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func prettyDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: d)
    }
}

// MARK: - Hooks

private struct HooksSettingsTab: View {
    @State private var lastReinstall: Date?

    var body: some View {
        Form {
            Section("Installed scripts") {
                hookRow("Notification", file: "xHelperAlerts.sh")
                hookRow("Pre-tool-use", file: "xhelper-auto-approve.sh")
            }

            Section("Wired into") {
                Text("~/.claude/settings.json")
                    .font(.system(size: 12, design: .monospaced))
                Text("~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json")
                    .font(.system(size: 12, design: .monospaced))
            }

            Section {
                HStack {
                    Button("Reinstall hooks") {
                        FirstRunInstaller.runIfNeeded()
                        lastReinstall = Date()
                    }
                    if let d = lastReinstall {
                        Text("Reinstalled \(d.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func hookRow(_ title: String, file: String) -> some View {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xhelper-alerts/hooks/\(file)").path
        let installed = FileManager.default.fileExists(atPath: path)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(installed ? "Installed" : "Missing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(installed ? .green : .red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((installed ? Color.green : Color.red).opacity(0.15), in: Capsule())
        }
    }
}
