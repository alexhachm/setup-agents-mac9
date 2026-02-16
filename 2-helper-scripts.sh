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

# Fingerprint function: includes size for sub-second change detection
file_fingerprint() {
    local f="$1"
    if [ ! -f "$f" ]; then
        echo "0:0"
        return
    fi
    if [[ "$OSTYPE" == darwin* ]]; then
        # macOS: mtime + size
        stat -f "%m:%z" "$f" 2>/dev/null || echo "0:0"
    else
        # Linux: nanosecond mtime + size
        stat -c "%Y.%X:%s" "$f" 2>/dev/null || echo "0:0"
    fi
}

SIGNAL_DIR="$(dirname "$SIGNAL_FILE")"
SIGNAL_NAME="$(basename "$SIGNAL_FILE")"

if command -v fswatch &>/dev/null; then
    # macOS: use fswatch — watch directory with filename filter (handles non-existent files)
    fswatch -1 --event Created --event Updated --event Renamed --include "$SIGNAL_NAME" --exclude '.*' "$SIGNAL_DIR" &
    WATCH_PID=$!

    # Timeout handler with clean exit on TERM
    (trap 'exit 0' TERM; sleep "$TIMEOUT" && kill "$WATCH_PID" 2>/dev/null) &
    TIMER_PID=$!

    wait "$WATCH_PID" 2>/dev/null
    kill "$TIMER_PID" 2>/dev/null || true
    wait "$TIMER_PID" 2>/dev/null || true

elif command -v inotifywait &>/dev/null; then
    # Linux: use inotifywait — watch directory for the specific file
    inotifywait -t "$TIMEOUT" -e modify,create "$SIGNAL_DIR/$SIGNAL_NAME" 2>/dev/null || true

else
    # Fallback: poll with 1s interval using fingerprint for precision
    elapsed=0
    last_fp=$(file_fingerprint "$SIGNAL_FILE")

    while [ "$elapsed" -lt "$TIMEOUT" ]; do
        sleep 1
        elapsed=$((elapsed + 1))

        current_fp=$(file_fingerprint "$SIGNAL_FILE")
        if [ "$current_fp" != "$last_fp" ]; then
            break
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
PID_FILE="${LOCK_DIR}/pid"

# Path validation: only allow state-lock.sh to operate on safe paths
case "$STATE_FILE" in
    */.claude/state/* | */.claude-shared-state/* | */.claude/knowledge/* | */.claude/logs/* )
        ;; # allowed
    *)
        echo "ERROR: state-lock.sh refused to operate on path outside allowed directories: $STATE_FILE" >&2
        exit 1
        ;;
esac

# Stale lock detection with PID checking
if [ -d "$LOCK_DIR" ]; then
    lock_holder=""
    if [ -f "$PID_FILE" ]; then
        lock_holder=$(cat "$PID_FILE" 2>/dev/null || echo "")
    fi

    if [ -n "$lock_holder" ] && ! kill -0 "$lock_holder" 2>/dev/null; then
        # Holding process is dead — break lock immediately
        echo "WARN: Removing lock held by dead PID $lock_holder on $STATE_FILE" >&2
        rm -rf "$LOCK_DIR"
    else
        # Process may be alive — check age
        if [[ "$OSTYPE" == darwin* ]]; then
            lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
        else
            lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
        fi
        if [ "$lock_age" -gt 120 ]; then
            echo "WARN: Removing stale lock on $STATE_FILE (${lock_age}s old, PID=${lock_holder:-unknown})" >&2
            rm -rf "$LOCK_DIR"
        fi
    fi
fi

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
    rm -f "$TMP_FILE" 2>/dev/null || true
}

# Auto-increment _version field after successful JSON write
auto_increment_version() {
    if command -v jq &>/dev/null && [ -f "$STATE_FILE" ] && [[ "$STATE_FILE" == *.json ]]; then
        if jq . "$STATE_FILE" > /dev/null 2>&1; then
            jq '._version = (._version // 0) + 1' "$STATE_FILE" > "${STATE_FILE}.vtmp.$$" 2>/dev/null \
                && mv "${STATE_FILE}.vtmp.$$" "$STATE_FILE" \
                || rm -f "${STATE_FILE}.vtmp.$$"
        else
            echo "WARN: Invalid JSON written to $STATE_FILE" >&2
        fi
    fi
}

if command -v flock &>/dev/null; then
    LOCK_FILE="${STATE_FILE}.lock"
    # Wrap in subshell so FD 200 is automatically closed on exit
    (
        flock -w 10 200 || { echo "ERROR: Could not acquire lock on $STATE_FILE" >&2; exit 1; }
        eval "$@"
        auto_increment_version
    ) 200>"$LOCK_FILE"
else
    attempts=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 1200 ]; then
            echo "ERROR: Could not acquire lock on $STATE_FILE after 120s" >&2
            exit 1
        fi
        sleep 0.1
    done
    # Write PID for stale lock detection
    echo $$ > "$PID_FILE" 2>/dev/null || true
    trap cleanup EXIT INT TERM
    eval "$@"
    auto_increment_version
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null || true
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
    if echo "$file_path" | grep -qiE '\.env$|\.env\.|\.env\.local|secrets|credentials|\.pem$|\.key$|id_rsa|id_ed25519|id_ecdsa|\.secret|\.token|\.apikey|\.password|\.p12$|\.pfx$|\.jks$|\.keystore|/\.aws/|/\.ssh/|/\.gnupg/|/\.config/gh/|kubeconfig|service\.account\.json'; then
        echo "BLOCKED: $file_path is sensitive" >&2
        exit 2
    fi
fi

command_str=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
if [ -n "$command_str" ]; then
    # Block commands that read sensitive files
    if echo "$command_str" | grep -qiE '(cat|less|head|tail|more|cp|mv|scp|base64|openssl|strings)\s+.*\.(env|pem|key|secret|token|apikey|password|p12|pfx|jks|keystore)'; then
        echo "BLOCKED: command accesses sensitive file" >&2
        exit 2
    fi
    # Block access to sensitive directories
    if echo "$command_str" | grep -qiE '/\.ssh/|/\.aws/|/\.gnupg/|/etc/shadow'; then
        echo "BLOCKED: command accesses sensitive path" >&2
        exit 2
    fi
    # Block potential exfiltration patterns
    if echo "$command_str" | grep -qiE 'curl\s+.*-d\s+@|curl\s+.*--data.*@|\bncat?\b|\bnc\s'; then
        echo "BLOCKED: potential data exfiltration detected" >&2
        exit 2
    fi
fi

exit 0


# ==============================================================================
# FILE: scripts/hooks/stop-notify.sh
# ==============================================================================

#!/usr/bin/env bash
osascript -e 'display notification "Done" with title "Claude" sound name "Glass"' 2>/dev/null || true
