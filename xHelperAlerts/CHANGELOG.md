# Changelog

## 1.1.0 — 2026-07-08

**Web alerts for claude.ai/code cloud sessions.**

- **New "Web alerts" section** in General settings. Cloud sessions can't reach your Mac, so a relay Worker bridges them: the repo-installed hook posts each notification to the relay and the app polls it, then raises the normal sound / banner / ring-back pipeline.
- **"Enable for a repo…" button** installs the cloud hook into a repository's `.claude/settings.json` (cloud sessions only honor repo-level settings). Commit and push `.claude/`, and web sessions of that repo alert your Mac.
- Device token is generated locally and identifies this Mac to the relay; alerts are drained on first poll and never stored longer than needed.

## 1.0.0 — 2026-06-26

**Initial release.**

- **Menu-bar alerts for Claude in Xcode.** Notification hook plays your chosen tone and posts a banner when Claude needs you. Pre-tool hook can auto-approve common Claude tool calls (CLI only).
- **Six-tab Settings window.** General · Accounts · History · Hooks · About · Updates. Reachable from the menu-bar popover, by clicking the dock icon, or with ⌘,.
- **Per-account customisation.** xHelperAlerts watches `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/.claude.json` and detects your current Claude account in real time. Each account remembers its own menu-bar label, icon colour, and text colour.
- **Coloured menu-bar badge.** When you pick a Toolbar icon colour, the status item becomes a rounded badge in your colour with the white logo inside. The dock icon picks up the same tint automatically.
- **Master notifications switch.** One toggle for notifications; expand to choose sound, banner, or both. A single Test button fires whichever sub-options are enabled.
- **Command-log history.** Every Claude tool call is logged with a decision (Auto / Asked / Silent), shown as a sortable table with column headers.
- **First-run installer.** On launch, hook scripts are copied to `~/.xhelper-alerts/hooks/` and registered in both `~/.claude/settings.json` (CLI) and the Xcode Coding Assistant settings — idempotent.
- **Change Xcode account in one click.** Activates Xcode and sends ⌘, (requires Accessibility permission).
