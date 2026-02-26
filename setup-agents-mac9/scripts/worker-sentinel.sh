#!/usr/bin/env bash
# worker-sentinel.sh — Persistent sentinel loop for a worker terminal.
# Runs inside the worker terminal forever: idle-wait → run claude → loop back.
# Usage: worker-sentinel.sh <worker-number> <project-dir>
#
# The sentinel is launched ONCE per worker (at setup time). Masters wake it by
# touching .claude/signals/.worker-N-wake instead of spawning new terminals.
set -e

export PATH="$HOME/bin:$HOME/.local/bin:$PATH"

WORKER_NUM="$1"
PROJECT_DIR="$2"

if [ -z "$WORKER_NUM" ] || [ -z "$PROJECT_DIR" ]; then
    echo "Usage: worker-sentinel.sh <worker-number> <project-dir>" >&2
    exit 1
fi

WORKTREE="$PROJECT_DIR/.worktrees/wt-$WORKER_NUM"
SIGNAL_FILE="$PROJECT_DIR/.claude/signals/.worker-${WORKER_NUM}-wake"
PID_FILE="$PROJECT_DIR/.claude/state/worker-${WORKER_NUM}.pid"
STATUS_FILE="$PROJECT_DIR/.claude/state/worker-status.json"

if [ ! -d "$WORKTREE" ]; then
    echo "ERROR: Worktree not found: $WORKTREE" >&2
    exit 1
fi

# Ensure directories exist
mkdir -p "$PROJECT_DIR/.claude/signals"
mkdir -p "$PROJECT_DIR/.claude/state"

# Write PID file for liveness checks
echo $$ > "$PID_FILE"

# Cleanup on exit: remove PID file, set worker status to idle
cleanup() {
    rm -f "$PID_FILE" 2>/dev/null
    # Best-effort status reset
    if [ -f "$STATUS_FILE" ] && command -v jq &>/dev/null; then
        jq ".\"worker-$WORKER_NUM\".status = \"idle\" | .\"worker-$WORKER_NUM\".current_task = null" \
            "$STATUS_FILE" > /tmp/ws_sentinel_$WORKER_NUM.json 2>/dev/null && \
            mv /tmp/ws_sentinel_$WORKER_NUM.json "$STATUS_FILE" 2>/dev/null || true
    fi
    echo "[SENTINEL] worker-$WORKER_NUM sentinel exiting (PID $$)"
}
trap cleanup EXIT

echo ""
echo "================================================================"
echo "  WORKER-$WORKER_NUM SENTINEL (PID $$)"
echo "  Worktree: $WORKTREE"
echo "  Signal:   $SIGNAL_FILE"
echo "================================================================"
echo ""

# ── Main sentinel loop ─────────────────────────────────────────────
while true; do
    # ── IDLE phase ──────────────────────────────────────────────────
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  WORKER-$WORKER_NUM  ·  IDLE  ·  WAITING  ║"
    echo "╚══════════════════════════════════════╝"
    echo ""
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sentinel idle, waiting for signal: $SIGNAL_FILE"

    # Refresh PID file (in case it was cleaned up by something else)
    echo $$ > "$PID_FILE"

    # Remove stale signal so we don't immediately re-trigger
    rm -f "$SIGNAL_FILE" 2>/dev/null || true

    # ── Wait for wake signal (blocking, long timeout) ───────────────
    # Use signal-wait.sh with a long timeout, loop to keep waiting
    while true; do
        bash "$PROJECT_DIR/.claude/scripts/signal-wait.sh" "$SIGNAL_FILE" 300
        # Check if signal file was actually touched/created
        if [ -f "$SIGNAL_FILE" ]; then
            break
        fi
        # No signal yet — keep waiting (signal-wait timed out)
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Still waiting..."
        echo $$ > "$PID_FILE"  # refresh PID
    done

    # ── WAKE phase ──────────────────────────────────────────────────
    echo ""
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SIGNAL RECEIVED — launching Claude for worker-$WORKER_NUM"
    echo ""

    # Consume the signal file
    rm -f "$SIGNAL_FILE" 2>/dev/null || true

    # ── RUN CLAUDE ──────────────────────────────────────────────────
    cd "$WORKTREE"
    env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --model opus --dangerously-skip-permissions '/worker-loop' || true

    # ── Claude exited — reset status to idle ────────────────────────
    echo ""
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Claude exited for worker-$WORKER_NUM, resetting to idle"

    if [ -f "$STATUS_FILE" ] && command -v jq &>/dev/null; then
        jq ".\"worker-$WORKER_NUM\".status = \"idle\" | .\"worker-$WORKER_NUM\".current_task = null" \
            "$STATUS_FILE" > /tmp/ws_sentinel_$WORKER_NUM.json 2>/dev/null && \
            mv /tmp/ws_sentinel_$WORKER_NUM.json "$STATUS_FILE" 2>/dev/null || true
    fi

    # Loop back to IDLE
done
