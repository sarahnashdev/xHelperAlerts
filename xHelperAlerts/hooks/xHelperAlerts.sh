#!/bin/bash
# xHelperAlerts — Notification hook.
#
# Wired to Claude Code's `Notification` event. Fires when Claude declares an
# "attention" moment (idle, waiting for user). Plays the user's chosen tone
# and posts a macOS banner that lands in Notification Center.
#
# Reads ~/.xhelper-alerts/config.json — toggle changes are instant, no
# restart needed.

set -e
echo "[$(date +%H:%M:%S)] notification hook fired" >> "$HOME/.xhelper-alerts/hook-trace.log"

CONFIG="$HOME/.xhelper-alerts/config.json"
[ ! -f "$CONFIG" ] && exit 0

read_flag()   { /usr/bin/python3 -c "import json; d=json.load(open('$CONFIG')); print('true' if d.get('$1', True) else 'false')" 2>/dev/null || echo "true"; }
read_string() { /usr/bin/python3 -c "import json; d=json.load(open('$CONFIG')); print(d.get('$1') or '$2')" 2>/dev/null || echo "$2"; }

NOTIFICATIONS_ENABLED=$(read_flag notifications_enabled)
[ "$NOTIFICATIONS_ENABLED" = "false" ] && exit 0

PAYLOAD="$(cat 2>/dev/null || true)"
MESSAGE=$(printf '%s' "$PAYLOAD" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("message") or "Claude needs your attention")
except Exception:
    print("Claude needs your attention")
' 2>/dev/null)
MESSAGE=${MESSAGE:-"Claude needs your attention"}

# Hand the alert off to the Swift app via a file. The app applies the
# user's sound + banner + ring-back preferences (read from config.json) —
# we deliberately do NOT play the tone here, so the sound isn't doubled
# and ring-back can replay it. Avoids `osascript -e "display notification"`,
# which on macOS Tahoe routes through Script Editor.
SAFE=$(printf '%s' "$MESSAGE" | tr '\n\t' '  ')
printf 'xHelperAlerts\t%s\n' "$SAFE" >> "$HOME/.xhelper-alerts/banner-request"

exit 0
