#!/bin/bash
set -eu

SRC="/mnt/c/Users/Owner/Desktop/setup-agents-mac8/setup-agents-mac9/templates/commands"
DST="/home/owner/Desktop/my-app/.claude/commands"

# Deploy to main project
cp "$SRC/architect-loop.md" "$DST/architect-loop.md"
cp "$SRC/allocate-loop.md" "$DST/allocate-loop.md"
cp "$SRC/worker-loop.md" "$DST/worker-loop.md"
echo "Main project: deployed"

# Deploy to all worktrees
for i in 1 2 3 4 5 6; do
  WT="/home/owner/Desktop/my-app/.worktrees/wt-${i}/.claude/commands"
  if [ -d "$WT" ]; then
    cp "$SRC/worker-loop.md" "$WT/worker-loop.md"
    cp "$SRC/architect-loop.md" "$WT/architect-loop.md"
    cp "$SRC/allocate-loop.md" "$WT/allocate-loop.md"
    echo "wt-${i}: deployed"
  else
    echo "wt-${i}: SKIPPED (no commands dir)"
  fi
done

# Ensure tasks directory exists
mkdir -p /home/owner/Desktop/my-app/.claude-shared-state/tasks
echo "tasks dir: ready"

# Write test task file for worker-1
cat > /home/owner/Desktop/my-app/.claude-shared-state/tasks/worker-1.json << 'EOF'
{
  "subject": "Add health-check endpoint to server",
  "description": "REQUEST_ID: test-001\nDOMAIN: api\nASSIGNED_TO: worker-1\nFILES: src/server.js\nVALIDATION: tier2\nTIER: 2\n\nAdd a GET /health endpoint that returns { status: 'ok', timestamp: Date.now() }.\n\nSuccess criteria:\n- Endpoint returns 200 with JSON body\n- No existing routes are affected",
  "domain": "api",
  "files": ["src/server.js"],
  "validation": "tier2",
  "tier": 2,
  "request_id": "test-001"
}
EOF
echo "test task file: written"

# Verify
echo ""
echo "=== Verification ==="
cat /home/owner/Desktop/my-app/.claude-shared-state/tasks/worker-1.json
echo ""
echo "Worker can access via symlink:"
ls -la /home/owner/Desktop/my-app/.worktrees/wt-1/.claude/state/tasks/ 2>/dev/null && echo "OK" || echo "FAIL"
