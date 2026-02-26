#!/usr/bin/env bash
# Launch a worker on demand (called by Master-3/Master-2)
# Usage: launch-worker.sh <worker-number>
# Returns immediately (non-blocking).
#
# v5: Signal-based sentinel architecture.
#   1. Check if sentinel process is alive via PID file
#   2. If alive → touch per-worker wake signal (instant, no new terminal)
#   3. If dead  → launch new sentinel terminal, then touch signal
set -e

export PATH="$HOME/bin:$HOME/.local/bin:$PATH"

WORKER_NUM="$1"
if [ -z "$WORKER_NUM" ]; then
    echo "Usage: launch-worker.sh <worker-number>" >&2
    exit 1
fi

# Resolve project directory (script lives at .claude/scripts/)
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORKTREE="$PROJECT_DIR/.worktrees/wt-$WORKER_NUM"
SIGNAL_FILE="$PROJECT_DIR/.claude/signals/.worker-${WORKER_NUM}-wake"
PID_FILE="$PROJECT_DIR/.claude/state/worker-${WORKER_NUM}.pid"
SENTINEL_SCRIPT="$PROJECT_DIR/.claude/scripts/worker-sentinel.sh"

# Ensure signal directory exists
mkdir -p "$PROJECT_DIR/.claude/signals"

# Verify worktree exists
if [ ! -d "$WORKTREE" ]; then
    echo "ERROR: Worktree not found: $WORKTREE" >&2
    exit 1
fi

# ── Check sentinel liveness ─────────────────────────────────────────
sentinel_alive=false

if [ -f "$PID_FILE" ]; then
    sentinel_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$sentinel_pid" ]; then
        if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
            # Git Bash / MSYS2: check via tasklist.exe
            if tasklist.exe /FI "PID eq $sentinel_pid" 2>/dev/null | grep -q "$sentinel_pid"; then
                sentinel_alive=true
            fi
        else
            # WSL / Linux / macOS: sentinel is a local bash process, use kill -0
            if kill -0 "$sentinel_pid" 2>/dev/null; then
                sentinel_alive=true
            fi
        fi
    fi
fi

# ── If sentinel is alive → just touch the signal ────────────────────
if $sentinel_alive; then
    touch "$SIGNAL_FILE"
    echo "[LAUNCH_WORKER] worker-$WORKER_NUM signaled (sentinel PID $sentinel_pid alive)"
    exit 0
fi

# ── Sentinel is dead → launch new sentinel terminal, then signal ────
echo "[LAUNCH_WORKER] worker-$WORKER_NUM sentinel not running, launching..."

SH_FILE="$PROJECT_DIR/.claude/launchers/worker-${WORKER_NUM}.sh"
PS1_FILE="$PROJECT_DIR/.claude/launchers/worker-${WORKER_NUM}.ps1"

if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    # Windows: prefer .ps1 (delegates to .sh via WSL), fallback to inline
    if [ -f "$PS1_FILE" ]; then
        WIN_PS1=$(cygpath -w "$PS1_FILE" 2>/dev/null || echo "$PS1_FILE" | sed 's|/|\\|g')
        if command -v wt.exe &>/dev/null; then
            powershell.exe -NoProfile -Command "Start-Process wt.exe -ArgumentList 'new-tab --title \"Worker-$WORKER_NUM\" powershell.exe -ExecutionPolicy Bypass -File \"$WIN_PS1\"' -WindowStyle Minimized" &
        else
            start powershell.exe -ExecutionPolicy Bypass -File "$WIN_PS1" &
        fi
    elif [ -f "$SH_FILE" ]; then
        # .sh exists but no .ps1 — run via wsl.exe directly
        WSL_SH=$(echo "$SH_FILE" | sed 's|^/\([a-zA-Z]\)/|/mnt/\1/|')
        if command -v wt.exe &>/dev/null; then
            powershell.exe -NoProfile -Command "Start-Process wt.exe -ArgumentList 'new-tab --title \"Worker-$WORKER_NUM\" wsl.exe bash -l \"$WSL_SH\"' -WindowStyle Minimized" &
        else
            start wsl.exe bash -l "$WSL_SH" &
        fi
    else
        # No launcher files — build inline sentinel command
        WSL_PROJECT=$(echo "$PROJECT_DIR" | sed 's|^/\([a-zA-Z]\)/|/mnt/\1/|')
        SENTINEL_CMD="export PATH=\"\$HOME/bin:\$HOME/.local/bin:\$PATH\"; bash '$WSL_PROJECT/.claude/scripts/worker-sentinel.sh' $WORKER_NUM '$WSL_PROJECT'; exit 0"
        if command -v wt.exe &>/dev/null; then
            powershell.exe -NoProfile -Command "Start-Process wt.exe -ArgumentList 'new-tab --title \"Worker-$WORKER_NUM\" wsl.exe bash -lc \"$SENTINEL_CMD\"' -WindowStyle Minimized" &
        else
            start wsl.exe bash -lc "$SENTINEL_CMD" &
        fi
    fi

elif [[ "$OSTYPE" == darwin* ]]; then
    # macOS: prefer .sh launcher, fallback to inline
    if [ -f "$SH_FILE" ]; then
        osascript -e "tell application \"Terminal\"
            activate
            do script \"bash '$SH_FILE'\"
        end tell" &
    else
        SENTINEL_CMD="export PATH=\"\$HOME/bin:\$HOME/.local/bin:\$PATH\"; bash '$SENTINEL_SCRIPT' $WORKER_NUM '$PROJECT_DIR'"
        osascript -e "tell application \"Terminal\"
            activate
            do script \"$SENTINEL_CMD\"
        end tell" &
    fi

elif grep -qi microsoft /proc/version 2>/dev/null; then
    # WSL: launch via Windows Terminal or cmd.exe into WSL bash
    if [ -f "$SH_FILE" ]; then
        LAUNCH_CMD="bash '$SH_FILE'"
    else
        LAUNCH_CMD="export PATH=\"\$HOME/bin:\$HOME/.local/bin:\$PATH\"; bash '$SENTINEL_SCRIPT' $WORKER_NUM '$PROJECT_DIR'"
    fi
    # Ensure clean exit so WT tab auto-closes (closeOnExit: "graceful" keeps tabs on non-zero)
    LAUNCH_CMD="$LAUNCH_CMD; exit 0"
    if command -v wt.exe &>/dev/null; then
        wt.exe -w workers new-tab --title "Worker-$WORKER_NUM" wsl.exe bash -lc "$LAUNCH_CMD" &
    elif command -v cmd.exe &>/dev/null; then
        cmd.exe /c start "" wsl.exe bash -lc "$LAUNCH_CMD" &
    else
        echo "WARN: No Windows terminal found from WSL. Run manually:" >&2
        echo "  $LAUNCH_CMD" >&2
        exit 1
    fi

else
    # Linux: prefer .sh launcher, fallback to inline
    if [ -f "$SH_FILE" ]; then
        LAUNCH_CMD="bash '$SH_FILE'"
    else
        LAUNCH_CMD="export PATH=\"\$HOME/bin:\$HOME/.local/bin:\$PATH\"; bash '$SENTINEL_SCRIPT' $WORKER_NUM '$PROJECT_DIR'"
    fi
    if command -v gnome-terminal &>/dev/null; then
        gnome-terminal --title="Worker-$WORKER_NUM" -- bash -lc "$LAUNCH_CMD" &
    elif command -v konsole &>/dev/null; then
        konsole --new-tab -e bash -lc "$LAUNCH_CMD" &
    elif command -v xterm &>/dev/null; then
        xterm -title "Worker-$WORKER_NUM" -e bash -lc "$LAUNCH_CMD" &
    else
        echo "WARN: No supported terminal emulator found. Run manually:" >&2
        echo "  bash '$SH_FILE'" >&2
        exit 1
    fi
fi

# Give sentinel a moment to start and write PID file, then signal it
sleep 2
touch "$SIGNAL_FILE"
echo "[LAUNCH_WORKER] worker-$WORKER_NUM sentinel launched + signaled"
