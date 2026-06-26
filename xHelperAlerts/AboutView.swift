import SwiftUI
import AppKit

/// Concise About panel embedded as a Settings tab. App identity, the
/// two essential actions (reinstall hooks, copy uninstall command), and
/// a couple of troubleshooting bullets — nothing more.
struct AboutView: View {
    @State private var copiedUninstall = false
    @State private var lastReinstall: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                Text("xHelperAlerts pings you the moment Claude Code (Xcode's in-IDE AI) needs your approval, and can auto-approve common tool calls when you want it to.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                actions

                troubleshooting
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("xHelperAlerts")
                    .font(.system(size: 22, weight: .bold))
                Text("Menu-bar alerts for Claude in Xcode")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("v\(AlertSettings.appVersion)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            Spacer()
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions")
                .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 10) {
                Button {
                    FirstRunInstaller.runIfNeeded()
                    lastReinstall = Date()
                } label: {
                    Label("Reinstall hooks", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(uninstallCommand, forType: .string)
                    withAnimation(.easeOut(duration: 0.2)) { copiedUninstall = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation { copiedUninstall = false }
                    }
                } label: {
                    Label(copiedUninstall ? "Copied" : "Copy uninstall command",
                          systemImage: copiedUninstall ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            if let d = lastReinstall {
                Text("Reinstalled \(d.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("The uninstall command quits the app, removes /Applications/xHelperAlerts.app, clears ~/.xhelper-alerts/, and unhooks Claude.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Troubleshooting")
                .font(.system(size: 16, weight: .semibold))
            bullet("**No icon in the menu bar?** Check menu-bar managers (Ice, Bartender) — they may be hiding it.")
            bullet("**No banner?** System Settings → Notifications → xHelperAlerts → Allow Notifications.")
            bullet("**Change-account button does nothing?** Grant Accessibility permission in System Settings → Privacy & Security → Accessibility.")
        }
    }

    @ViewBuilder
    private func bullet(_ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(.init(markdown)).fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
    }

    // MARK: - Uninstall command

    private let uninstallCommand = #"""
osascript -e 'tell application "xHelperAlerts" to quit' 2>/dev/null
rm -rf ~/.xhelper-alerts "/Applications/xHelperAlerts.app"
/usr/bin/python3 - <<'PY'
import json, os
for p in [
    "~/.claude/settings.json",
    "~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/settings.json",
]:
    p = os.path.expanduser(p)
    if not os.path.exists(p): continue
    with open(p) as f: d = json.load(f)
    for evt in ("Notification", "PreToolUse"):
        if evt in d.get("hooks", {}):
            d["hooks"][evt] = [e for e in d["hooks"][evt]
                if not any("xhelper" in (h.get("command","")) for h in e.get("hooks", []))]
            if not d["hooks"][evt]: del d["hooks"][evt]
    if not d.get("hooks"): d.pop("hooks", None)
    with open(p, "w") as f: json.dump(d, f, indent=2, sort_keys=True); f.write("\n")
print("xHelperAlerts uninstalled.")
PY
"""#
}
