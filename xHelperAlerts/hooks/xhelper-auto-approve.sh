#!/bin/bash
# xHelperAlerts — PreToolUse hook.
#
# Three jobs, in order:
#   1. Log every tool call to ~/.xhelper-alerts/command-log.jsonl with its
#      decision so the user can review history later (Menu → History).
#   2. When auto-approve is ON, emit "approve" JSON so Claude runs silently.
#      Also play sound/banner if notify_on_auto_approve is on.
#   3. When auto-approve is OFF and the tool is one Claude commonly prompts
#      for (Bash / Write / Edit / MultiEdit / NotebookEdit), play the user's
#      chosen tone so they hear that Claude is about to ask.

set -e
echo "[$(date +%H:%M:%S)] pre-tool hook fired" >> "$HOME/.xhelper-alerts/hook-trace.log"

CONFIG="$HOME/.xhelper-alerts/config.json"
LOG="$HOME/.xhelper-alerts/command-log.jsonl"
[ ! -f "$CONFIG" ] && exit 0

PAYLOAD="$(cat 2>/dev/null || true)"

# Diagnostic: capture last raw payload so we can iterate on parser schema.
# Trimmed to 4 KB to keep the file small.
DEBUG_PAYLOAD="$HOME/.xhelper-alerts/last-payload.json"
{
    printf '=== %s ===\n' "$(date -u +%FT%TZ)"
    printf '%s' "$PAYLOAD" | head -c 4096
    printf '\n'
} > "$DEBUG_PAYLOAD" 2>/dev/null || true

read_flag()   { /usr/bin/python3 -c "import json; d=json.load(open('$CONFIG')); print('true' if d.get('$1', False) else 'false')" 2>/dev/null || echo "false"; }
read_string() { /usr/bin/python3 -c "import json; d=json.load(open('$CONFIG')); print(d.get('$1') or '$2')" 2>/dev/null || echo "$2"; }

AUTO=$(read_flag auto_approve_enabled)
NOTIFY_AUTO=$(read_flag notify_on_auto_approve)
NOTIFICATIONS_ENABLED=$(/usr/bin/python3 -c "import json; d=json.load(open('$CONFIG')); print('true' if d.get('notifications_enabled', True) else 'false')" 2>/dev/null || echo "true")
SOUND_ENABLED=$(read_flag sound_enabled)
BANNER_ENABLED=$(read_flag banner_enabled)
SOUND_NAME=$(read_string sound_name Hero)

play_sound() {
    [ "$NOTIFICATIONS_ENABLED" = "true" ] || return 0
    [ "$SOUND_ENABLED" = "true" ] || return 0
    local path="/System/Library/Sounds/$SOUND_NAME.aiff"
    [ -f "$path" ] || path="/System/Library/Sounds/Hero.aiff"
    ( /usr/bin/afplay "$path" >/dev/null 2>&1 & disown 2>/dev/null )
}

post_banner() {
    [ "$NOTIFICATIONS_ENABLED" = "true" ] || return 0
    [ "$BANNER_ENABLED" = "true" ] || return 0
    local message="${1:-Claude ran a tool}"
    # Hand the banner off to the Swift app via a file. Avoids
    # `osascript -e "display notification"` (Script Editor on Tahoe).
    local safe=$(printf '%s' "$message" | tr '\n\t' '  ')
    printf 'xHelperAlerts\t%s\n' "$safe" >> "$HOME/.xhelper-alerts/banner-request"
}

# Pull tool name + a short command snippet out of the JSON payload for logging.
# Claude Code's payload format varies by version — try every documented field
# name so we get useful log entries on each one.
#
# PAYLOAD is exported so the inline Python can read it from the env; piping
# PAYLOAD on stdin would conflict with the heredoc that supplies the script.
export PAYLOAD
TOOL_INFO=$(/usr/bin/python3 <<'PY' 2>/dev/null
import json, os
payload = os.environ.get("PAYLOAD", "")
try:
    d = json.loads(payload)
except Exception:
    print("\t")
    raise SystemExit

name = (d.get("tool_name") or d.get("toolName")
        or d.get("tool") or d.get("name") or "")

inp = (d.get("tool_input") or d.get("toolInput")
       or d.get("input") or d.get("arguments") or {})
if not isinstance(inp, dict):
    inp = {}

snippet = (inp.get("command") or inp.get("file_path") or inp.get("filePath")
           or inp.get("path") or inp.get("url") or inp.get("pattern")
           or inp.get("description") or "")
if isinstance(snippet, str):
    snippet = snippet.replace("\n", " ").strip()[:200]
else:
    snippet = ""

print((name or "?") + "\t" + snippet)
PY
)
TOOL_NAME=$(printf '%s' "$TOOL_INFO" | cut -f1)
SNIPPET=$(printf '%s' "$TOOL_INFO" | cut -f2-)

write_log_entry() {
    local decision="$1"
    /usr/bin/python3 - "$LOG" "$TOOL_NAME" "$SNIPPET" "$decision" <<'PY' 2>/dev/null
import json, os, sys
from datetime import datetime
log_path, tool, snippet, decision = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
os.makedirs(os.path.dirname(log_path), exist_ok=True)
entry = {
    "timestamp": datetime.now().isoformat(timespec="seconds"),
    "tool": tool,
    "snippet": snippet,
    "decision": decision,
}
with open(log_path, "a") as f:
    f.write(json.dumps(entry) + "\n")
PY
}

# --- Auto-approve path ---
if [ "$AUTO" = "true" ]; then
    write_log_entry "auto_approved"
    if [ "$NOTIFY_AUTO" = "true" ]; then
        play_sound
        post_banner "${TOOL_NAME:-tool} ${SNIPPET:0:60}"
    fi
    cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "xHelperAlerts auto-approve is on"
  }
}
JSON
    exit 0
fi

# --- Manual path: chime + log "pending" for tools that commonly need approval ---
case "$TOOL_NAME" in
    Bash|Write|Edit|MultiEdit|NotebookEdit)
        write_log_entry "pending_user_decision"
        play_sound
        ;;
    *)
        write_log_entry "no_chime"
        ;;
esac

exit 0
