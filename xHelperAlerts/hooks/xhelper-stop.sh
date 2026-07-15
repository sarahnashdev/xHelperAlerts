#!/bin/bash
# xHelperAlerts — Stop hook.
#
# Wired to Claude Code's `Stop` event, which fires when Claude finishes its
# turn and hands control back to you. This is the clearest "Claude stopped,
# it's your move" signal — more reliable than the Notification event, which
# Claude only emits for permission prompts / long idles.
#
# Reads ~/.xhelper-alerts/config.json — toggle changes are instant.

set -e
echo "[$(date +%H:%M:%S)] stop hook fired" >> "$HOME/.xhelper-alerts/hook-trace.log"

CONFIG="$HOME/.xhelper-alerts/config.json"
[ ! -f "$CONFIG" ] && exit 0

read_flag() { /usr/bin/python3 -c "import json; d=json.load(open('$CONFIG')); print('true' if d.get('$1', True) else 'false')" 2>/dev/null || echo "true"; }

NOTIFICATIONS_ENABLED=$(read_flag notifications_enabled)
[ "$NOTIFICATIONS_ENABLED" = "false" ] && exit 0

# Hand the alert off to the app (it applies sound + banner + ring-back prefs).
# Format is "<title>\t<body>".
printf '%s\t%s\n' "✅ Your turn" "Claude finished — waiting for your input" \
    >> "$HOME/.xhelper-alerts/banner-request"

exit 0
