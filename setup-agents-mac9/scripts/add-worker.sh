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

# Link shared state into the new worktree (junction on Windows, symlink elsewhere)
shared_state_dir="$PROJECT_DIR/.claude-shared-state"
if [ -d "$shared_state_dir" ]; then
    rm -rf "$worktree_path/.claude/state"
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        win_link=$(cygpath -w "$worktree_path/.claude/state")
        win_target=$(cygpath -w "$shared_state_dir")
        cmd //c "mklink /J \"$win_link\" \"$win_target\"" > /dev/null 2>&1
    else
        ln -sf "../../../.claude-shared-state" "$worktree_path/.claude/state"
    fi
fi

# Link logs directory so new worker can write to shared log
mkdir -p "$worktree_path/.claude/logs"
rm -rf "$worktree_path/.claude/logs"
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    win_link=$(cygpath -w "$worktree_path/.claude/logs")
    win_target=$(cygpath -w "$PROJECT_DIR/.claude/logs")
    cmd //c "mklink /J \"$win_link\" \"$win_target\"" > /dev/null 2>&1
else
    ln -sf "../../../.claude/logs" "$worktree_path/.claude/logs"
fi

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

# Workers are launched on demand by Masters via launch-worker.sh
echo "Worker $next_num worktree created in slot $next_num (launch on demand)"
