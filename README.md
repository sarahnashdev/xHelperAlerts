# xHelperAlerts

Menu-bar alerts for Claude in Xcode. Pings you the moment Claude Code needs your approval, and can auto-approve common tool calls when you want it to.

## Features

- **Notification hook** plays your chosen tone and posts a macOS banner when Claude needs you.
- **Per-account customisation** — labels, glyph colour, and text colour are remembered for each Claude account you sign into.
- **Live account detection** — switches as soon as you log in/out of a Claude account in Xcode.
- **Coloured menu-bar badge** — rounded badge in your colour with the white logo inside; dock icon picks up the same tint automatically.
- **Master notifications switch** with separate Sound and Banner sub-toggles. One **Test** button fires whatever you have enabled.
- **Command log** of every Claude tool call with sortable columns and decision (Auto / Asked / Silent).
- **First-run installer** wires hooks into both `~/.claude/settings.json` (CLI) and Xcode's Coding Assistant settings — idempotent.
- **Web alerts** — get pinged by Claude Code **cloud** sessions (claude.ai/code) too: a relay Worker bridges the cloud sandbox to your Mac. Enable per-repo from Settings → General.

## Install

1. Download **[xHelperAlerts-1.0.0.dmg](https://github.com/sarahnashdev/xHelperAlerts/releases/latest)**.
2. Open the DMG and drag **xHelperAlerts** to **Applications**.
3. Launch it. Settings opens automatically on first run.

The app is signed with Apple Developer ID and notarized — Gatekeeper opens it cleanly with no warnings.

## Requirements

- macOS 14 or later
- Xcode with Claude Code (Coding Assistant) for the real workflow; the CLI hooks work even if you only use Claude in Terminal.

## Uninstall

Use the **Copy uninstall command** button in About inside the app, then paste into Terminal. It quits the app, removes `/Applications/xHelperAlerts.app`, clears `~/.xhelper-alerts/`, and unhooks Claude.

## License

MIT
