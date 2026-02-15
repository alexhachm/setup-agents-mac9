################################################################################
# HELPER SCRIPTS
# Contains: signal-wait.sh, state-lock.sh, pre-tool-secret-guard.sh, stop-notify.sh
# These go into the scripts/ and scripts/hooks/ directories alongside setup.sh
################################################################################


# ==============================================================================
# FILE: scripts/signal-wait.sh
# ==============================================================================

#!/usr/bin/env bash
# Usage: signal-wait.sh <signal-file> [timeout_seconds]
# Waits for a signal file to be touched/created. Returns immediately when detected.
# Falls back to polling if fswatch/inotifywait unavailable.
set -e

SIGNAL_FILE="$1"
TIMEOUT="${2:-30}"

# Ensure signal directory exists
mkdir -p "$(dirname "$SIGNAL_FILE")"

if command -v fswatch &>/dev/null; then
    # macOS: use fswatch with timeout
    fswatch -1 --event Created --event Updated --event Renamed "$SIGNAL_FILE" &
    WATCH_PID=$!
    
    # Timeout handler
    (sleep "$TIMEOUT" && kill "$WATCH_PID" 2>/dev/null) &
    TIMER_PID=$!
    
    wait "$WATCH_PID" 2>/dev/null
    kill "$TIMER_PID" 2>/dev/null || true
    
elif command -v inotifywait &>/dev/null; then
    # Linux: use inotifywait
    inotifywait -t "$TIMEOUT" -e modify,create "$SIGNAL_FILE" 2>/dev/null || true
    
else
    # Fallback: poll with short sleep
    elapsed=0
    last_mod=""
    if [ -f "$SIGNAL_FILE" ]; then
        if [[ "$OSTYPE" == darwin* ]]; then
            last_mod=$(stat -f %m "$SIGNAL_FILE" 2>/dev/null || echo "0")
        else
            last_mod=$(stat -c %Y "$SIGNAL_FILE" 2>/dev/null || echo "0")
        fi
    fi
    
    while [ "$elapsed" -lt "$TIMEOUT" ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        
        if [ -f "$SIGNAL_FILE" ]; then
            if [[ "$OSTYPE" == darwin* ]]; then
                current_mod=$(stat -f %m "$SIGNAL_FILE" 2>/dev/null || echo "0")
            else
                current_mod=$(stat -c %Y "$SIGNAL_FILE" 2>/dev/null || echo "0")
            fi
            if [ "$current_mod" != "$last_mod" ]; then
                break
            fi
        fi
    done
fi


# ==============================================================================
# FILE: scripts/state-lock.sh
# ==============================================================================

#!/usr/bin/env bash
# Usage: state-lock.sh <state-file> <command>
set -e
STATE_FILE="$1"
shift
LOCK_DIR="${STATE_FILE}.lockdir"
TMP_FILE="${STATE_FILE}.tmp.$$"

if [ -d "$LOCK_DIR" ]; then
    if [[ "$OSTYPE" == darwin* ]]; then
        lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
    else
        lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    fi
    if [ "$lock_age" -gt 30 ]; then
        echo "WARN: Removing stale lock on $STATE_FILE (${lock_age}s old)" >&2
        rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    fi
fi

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
    rm -f "$TMP_FILE" 2>/dev/null || true
}

if command -v flock &>/dev/null; then
    LOCK_FILE="${STATE_FILE}.lock"
    exec 200>"$LOCK_FILE"
    flock -w 10 200 || { echo "ERROR: Could not acquire lock on $STATE_FILE" >&2; exit 1; }
    eval "$@"
    if command -v jq &>/dev/null && [ -f "$STATE_FILE" ]; then
        if ! jq . "$STATE_FILE" > /dev/null 2>&1; then
            echo "WARN: Invalid JSON written to $STATE_FILE" >&2
        fi
    fi
    exec 200>&-
else
    attempts=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 100 ]; then
            echo "ERROR: Could not acquire lock on $STATE_FILE after 10s" >&2
            exit 1
        fi
        sleep 0.1
    done
    trap cleanup EXIT INT TERM
    eval "$@"
    if command -v jq &>/dev/null && [ -f "$STATE_FILE" ]; then
        if ! jq . "$STATE_FILE" > /dev/null 2>&1; then
            echo "WARN: Invalid JSON written to $STATE_FILE" >&2
        fi
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
    trap - EXIT INT TERM
fi


# ==============================================================================
# FILE: scripts/hooks/pre-tool-secret-guard.sh
# ==============================================================================

#!/usr/bin/env bash
set -euo pipefail
input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
if [ -n "$file_path" ]; then
    if echo "$file_path" | grep -qiE '\.env|secrets|credentials|\.pem$|\.key$|id_rsa|\.secret'; then
        echo "BLOCKED: $file_path is sensitive" >&2
        exit 2
    fi
fi

command_str=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
if [ -n "$command_str" ]; then
    if echo "$command_str" | grep -qiE '(cat|less|head|tail|more|cp|mv|scp)\s+.*\.(env|pem|key|secret)'; then
        echo "BLOCKED: command accesses sensitive file" >&2
        exit 2
    fi
fi

exit 0


# ==============================================================================
# FILE: scripts/hooks/stop-notify.sh
# ==============================================================================

#!/usr/bin/env bash
osascript -e 'display notification "Done" with title "Claude" sound name "Glass"' 2>/dev/null || true
