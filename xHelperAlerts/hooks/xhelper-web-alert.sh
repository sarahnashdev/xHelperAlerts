#!/bin/bash
# xHelperAlerts — Cloud notification hook (claude.ai/code sessions).
#
# Runs INSIDE Anthropic's cloud sandbox, where the Mac is unreachable, so it
# relays the Notification event to the xHelperAlerts Worker; the Mac app
# polls the same endpoint and raises the normal banner/sound/ring-back.
#
# Installed per-repository into .claude/settings.json by the app's
# "Enable web alerts for a repo…" button, which substitutes the device
# token. Local sessions are already covered by xHelperAlerts.sh via
# ~/.claude/settings.json — this hook exits early on the Mac so alerts
# aren't doubled.
#
# Usage (as wired by the installer):
#   xhelper-web-alert.sh <device-token>

set -e

TOKEN="${1:-}"
[ -z "$TOKEN" ] && exit 0

# On the user's own Mac the local hook handles alerting; only relay from
# environments that don't have the app's config dir (i.e. the cloud sandbox).
[ -d "$HOME/.xhelper-alerts" ] && exit 0

RELAY="https://xhelper-alert-relay.sarah-nashdev.workers.dev"

PAYLOAD="$(cat 2>/dev/null || true)"
MESSAGE=$(printf '%s' "$PAYLOAD" | /usr/bin/env python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("message") or "Claude needs your attention")
except Exception:
    print("Claude needs your attention")
' 2>/dev/null)
MESSAGE=${MESSAGE:-"Claude needs your attention"}

# JSON-encode the message safely, then fire-and-forget. --max-time keeps a
# slow network from stalling Claude; failure to deliver must never fail the
# hook (that would surface as a session error).
BODY=$(printf '%s' "$MESSAGE" | /usr/bin/env python3 -c '
import json, sys
print(json.dumps({"title": "Claude (web)", "message": sys.stdin.read()}))
' 2>/dev/null) || BODY='{"title":"Claude (web)","message":"Claude needs your attention"}'

curl -s -o /dev/null --max-time 5 \
  -X POST "$RELAY/alert?token=$TOKEN" \
  -H "Content-Type: application/json" \
  -d "$BODY" || true

exit 0
