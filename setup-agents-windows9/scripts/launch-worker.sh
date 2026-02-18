#!/usr/bin/env bash
# Launch a worker terminal on demand (called by Master-3/Master-2)
# Usage: launch-worker.sh <worker-number>
# Returns immediately (non-blocking). The worker terminal runs /worker-loop.
set -euo pipefail

WORKER_NUM="${1:-}"
if [ -z "$WORKER_NUM" ]; then
    echo "Usage: launch-worker.sh <worker-number>" >&2
    exit 1
fi

# Resolve project directory (script lives at .claude/scripts/)
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORKTREE="$PROJECT_DIR/.worktrees/wt-$WORKER_NUM"
LAUNCHER_PS1="$PROJECT_DIR/.claude/launchers/worker-${WORKER_NUM}.ps1"
LAUNCHER_BAT="$PROJECT_DIR/.claude/launchers/worker-${WORKER_NUM}.bat"

# Verify worktree exists
if [ ! -d "$WORKTREE" ]; then
    echo "ERROR: Worktree not found: $WORKTREE" >&2
    exit 1
fi

if [ ! -f "$LAUNCHER_PS1" ] && [ ! -f "$LAUNCHER_BAT" ]; then
    echo "ERROR: Worker launcher not found (.ps1/.bat) for worker-$WORKER_NUM" >&2
    exit 1
fi

# WSL runtime (primary path for windows9 package)
if grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
    if ! command -v wslpath >/dev/null 2>&1; then
        echo "ERROR: wslpath not found; cannot convert launcher paths" >&2
        exit 1
    fi

    WIN_WORKTREE="$(wslpath -w "$WORKTREE")"
    WIN_LAUNCHER_PS1=""
    WIN_LAUNCHER_BAT=""

    if [ -f "$LAUNCHER_PS1" ]; then
        WIN_LAUNCHER_PS1="$(wslpath -w "$LAUNCHER_PS1")"
    fi
    if [ -f "$LAUNCHER_BAT" ]; then
        WIN_LAUNCHER_BAT="$(wslpath -w "$LAUNCHER_BAT")"
    fi

    if command -v wt.exe >/dev/null 2>&1; then
        if [ -n "$WIN_LAUNCHER_PS1" ]; then
            wt.exe -w workers new-tab -d "$WIN_WORKTREE" --title "Worker-$WORKER_NUM" powershell.exe -ExecutionPolicy Bypass -File "$WIN_LAUNCHER_PS1" >/dev/null 2>&1 &
        else
            wt.exe -w workers new-tab -d "$WIN_WORKTREE" --title "Worker-$WORKER_NUM" cmd.exe /c "$WIN_LAUNCHER_BAT" >/dev/null 2>&1 &
        fi
    else
        if [ -n "$WIN_LAUNCHER_PS1" ]; then
            cmd.exe /c start "" powershell.exe -ExecutionPolicy Bypass -File "$WIN_LAUNCHER_PS1" >/dev/null 2>&1 &
        else
            cmd.exe /c start "" "$WIN_LAUNCHER_BAT" >/dev/null 2>&1 &
        fi
    fi

    echo "[LAUNCH_WORKER] worker-$WORKER_NUM terminal opened"
    exit 0
fi

# Native Windows shell fallback (Git Bash / Cygwin)
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    WIN_WORKTREE="$(cygpath -w "$WORKTREE" 2>/dev/null || printf '%s' "$WORKTREE")"
    WIN_LAUNCHER_PS1="$(cygpath -w "$LAUNCHER_PS1" 2>/dev/null || true)"
    WIN_LAUNCHER_BAT="$(cygpath -w "$LAUNCHER_BAT" 2>/dev/null || true)"

    if command -v wt.exe >/dev/null 2>&1; then
        if [ -n "$WIN_LAUNCHER_PS1" ] && [ -f "$LAUNCHER_PS1" ]; then
            wt.exe new-tab -d "$WIN_WORKTREE" --title "Worker-$WORKER_NUM" powershell.exe -ExecutionPolicy Bypass -File "$WIN_LAUNCHER_PS1" >/dev/null 2>&1 &
        else
            wt.exe new-tab -d "$WIN_WORKTREE" --title "Worker-$WORKER_NUM" cmd.exe /c "$WIN_LAUNCHER_BAT" >/dev/null 2>&1 &
        fi
    else
        if [ -n "$WIN_LAUNCHER_PS1" ] && [ -f "$LAUNCHER_PS1" ]; then
            cmd.exe /c start "" powershell.exe -ExecutionPolicy Bypass -File "$WIN_LAUNCHER_PS1" >/dev/null 2>&1 &
        else
            cmd.exe /c start "" "$WIN_LAUNCHER_BAT" >/dev/null 2>&1 &
        fi
    fi

    echo "[LAUNCH_WORKER] worker-$WORKER_NUM terminal opened"
    exit 0
fi

echo "ERROR: launch-worker.sh (windows9) expects WSL or a Windows shell environment." >&2
exit 1
