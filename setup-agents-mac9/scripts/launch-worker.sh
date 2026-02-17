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
    # Windows: prefer Windows Terminal, fall back to start bash
    if command -v wt.exe &>/dev/null; then
        wt.exe new-tab --title "Worker-$WORKER_NUM" bash "$LAUNCHER" &
    else
        start bash "$LAUNCHER" &
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
