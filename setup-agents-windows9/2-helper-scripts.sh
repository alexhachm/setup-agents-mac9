################################################################################
# HELPER SCRIPTS (v3)
# Contains: signal-wait.sh, state-lock.sh, add-worker.sh,
#           pre-tool-secret-guard.sh, stop-notify.sh
# These go into the scripts/ and scripts/hooks/ directories alongside setup.sh
#
# v3 changes vs v8:
#   - Restored add-worker.sh from v7 (lost during v7→v8 modular split)
#   - All other scripts unchanged from v8
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

elif command -v powershell.exe &>/dev/null; then
    # Windows: use .NET FileSystemWatcher via PowerShell for instant notification
    SIGNAL_DIR=$(dirname "$SIGNAL_FILE")
    SIGNAL_NAME=$(basename "$SIGNAL_FILE")
    TIMEOUT_MS=$((TIMEOUT * 1000))
    powershell.exe -NoProfile -Command "
        \$w = New-Object System.IO.FileSystemWatcher
        \$w.Path = (Resolve-Path '$SIGNAL_DIR').Path
        \$w.Filter = '$SIGNAL_NAME'
        \$w.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::CreationTime -bor [System.IO.NotifyFilters]::FileName
        \$r = \$w.WaitForChanged([System.IO.WatcherChangeTypes]::All, $TIMEOUT_MS)
        \$w.Dispose()
    " 2>/dev/null || true

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
# FILE: scripts/add-worker.sh
# (Restored from v7 — lost during v7→v8 modular split)
# ==============================================================================

#!/usr/bin/env bash
set -e
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

# Find the lowest available worker slot (1-8) by checking for gaps
next_num=""
for i in $(seq 1 8); do
    if [ ! -d ".worktrees/wt-$i" ]; then
        next_num=$i
        break
    fi
done

if [ -z "$next_num" ]; then
    echo "ERROR: Maximum 8 workers — all slots occupied"
    exit 1
fi

branch_name="agent-$next_num"
worktree_path=".worktrees/wt-$next_num"

git branch -D "$branch_name" 2>/dev/null || true
git worktree add "$worktree_path" -b "$branch_name"

# Symlink shared state into the new worktree (relative for portability)
shared_state_dir="$PROJECT_DIR/.claude-shared-state"
if [ -d "$shared_state_dir" ]; then
    rm -rf "$worktree_path/.claude/state"
    ln -sf "../../../.claude-shared-state" "$worktree_path/.claude/state"
fi

# Symlink logs directory so new worker can write to shared log
mkdir -p "$worktree_path/.claude/logs"
rm -rf "$worktree_path/.claude/logs"
ln -sf "../../../.claude/logs" "$worktree_path/.claude/logs"

# Copy worker CLAUDE.md
if [ -f "$PROJECT_DIR/.worktrees/wt-1/CLAUDE.md" ]; then
    cp "$PROJECT_DIR/.worktrees/wt-1/CLAUDE.md" "$worktree_path/CLAUDE.md"
fi

# Update config file worker count (key=value format)
config_file="$HOME/.claude-multi-agent-config"
if [ -f "$config_file" ]; then
    new_count=$(ls -d .worktrees/wt-* 2>/dev/null | wc -l | tr -d ' ')
    sed -i.bak "s/^worker_count=.*/worker_count=$new_count/" "$config_file" 2>/dev/null || \
        sed -i '' "s/^worker_count=.*/worker_count=$new_count/" "$config_file" 2>/dev/null || true
    rm -f "$config_file.bak" 2>/dev/null
fi

# Open a new tab in the front Terminal window (macOS only)
if [[ "$OSTYPE" == darwin* ]]; then
    osascript -e 'tell application "System Events" to keystroke "t" using {command down}'
    sleep 2
    osascript -e "tell application \"Terminal\" to do script \"clear && printf '\\n\\033[1;44m\\033[1;37m  ████  I AM WORKER-$next_num  ████  \\033[0m\\n\\n' && cd '$PROJECT_DIR/$worktree_path' && claude --model opus --dangerously-skip-permissions '/worker-loop'\" in front window"
fi

echo "Worker $next_num launched in slot $next_num"


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
