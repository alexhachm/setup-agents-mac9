#!/usr/bin/env bash
# Launch a worker terminal on demand (called by Master-3/Master-2)
# Usage: launch-worker.sh <worker-number>
# Returns immediately (non-blocking). The worker terminal runs /worker-loop.
set -e

WORKER_NUM="$1"
if [ -z "$WORKER_NUM" ]; then
    echo "Usage: launch-worker.sh <worker-number>" >&2
    exit 1
fi

# Resolve project directory (script lives at .claude/scripts/)
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORKTREE="$PROJECT_DIR/.worktrees/wt-$WORKER_NUM"
LAUNCHER="$PROJECT_DIR/.claude/launchers/worker-${WORKER_NUM}.sh"

# Verify worktree exists
if [ ! -d "$WORKTREE" ]; then
    echo "ERROR: Worktree not found: $WORKTREE" >&2
    exit 1
fi

# Verify launcher exists
if [ ! -f "$LAUNCHER" ]; then
    echo "ERROR: Launcher not found: $LAUNCHER" >&2
    exit 1
fi

# Platform-specific terminal launch (non-blocking)
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    # Windows: convert Unix paths to Windows paths for native executables
    WIN_LAUNCHER=$(cygpath -w "$LAUNCHER" 2>/dev/null || echo "$LAUNCHER" | sed 's|/|\\|g')
    WIN_WORKTREE=$(cygpath -w "$WORKTREE" 2>/dev/null || echo "$WORKTREE" | sed 's|/|\\|g')

    if command -v wt.exe &>/dev/null; then
        # Windows Terminal: pass Windows path and use bash to execute
        wt.exe new-tab --title "Worker-$WORKER_NUM" --startingDirectory "$WIN_WORKTREE" bash -l "$LAUNCHER" &
    else
        # Fallback: use cmd start with Git Bash
        start bash -l "$LAUNCHER" &
    fi
elif [[ "$OSTYPE" == darwin* ]]; then
    # macOS: open new Terminal window
    osascript -e "tell application \"Terminal\"
        activate
        do script \"$LAUNCHER\"
    end tell" &
else
    # Linux: try common terminal emulators
    if command -v gnome-terminal &>/dev/null; then
        gnome-terminal --title="Worker-$WORKER_NUM" -- bash "$LAUNCHER" &
    elif command -v konsole &>/dev/null; then
        konsole --new-tab -e bash "$LAUNCHER" &
    elif command -v xterm &>/dev/null; then
        xterm -title "Worker-$WORKER_NUM" -e bash "$LAUNCHER" &
    else
        echo "WARN: No supported terminal emulator found. Run manually: $LAUNCHER" >&2
        exit 1
    fi
fi

echo "[LAUNCH_WORKER] worker-$WORKER_NUM terminal opened"
