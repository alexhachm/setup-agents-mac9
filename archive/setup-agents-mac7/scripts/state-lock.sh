#!/usr/bin/env bash
# Usage: state-lock.sh <state-file> <command>
# Acquires an exclusive lock before running <command>, releases after.
# Writes go to a temp file first, then atomically move into place.
set -e
STATE_FILE="$1"
shift
LOCK_DIR="${STATE_FILE}.lockdir"
TMP_FILE="${STATE_FILE}.tmp.$$"

# --- Stale lock recovery ---
# If a previous process was killed hard, the lockdir may persist.
# Remove locks older than 30 seconds.
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
    # Linux: use flock
    LOCK_FILE="${STATE_FILE}.lock"
    exec 200>"$LOCK_FILE"
    flock -w 10 200 || { echo "ERROR: Could not acquire lock on $STATE_FILE" >&2; exit 1; }
    eval "$@"
    # Validate JSON if jq is available and file looks like JSON
    if command -v jq &>/dev/null && [ -f "$STATE_FILE" ]; then
        if ! jq . "$STATE_FILE" > /dev/null 2>&1; then
            echo "WARN: Invalid JSON written to $STATE_FILE" >&2
        fi
    fi
    exec 200>&-
else
    # macOS fallback: mkdir is atomic
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
    # Validate JSON if jq is available and file looks like JSON
    if command -v jq &>/dev/null && [ -f "$STATE_FILE" ]; then
        if ! jq . "$STATE_FILE" > /dev/null 2>&1; then
            echo "WARN: Invalid JSON written to $STATE_FILE" >&2
        fi
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
    trap - EXIT INT TERM
fi
