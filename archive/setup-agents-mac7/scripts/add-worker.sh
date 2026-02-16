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

# Update config file worker count (key=value format)
config_file="$HOME/.claude-multi-agent-config"
if [ -f "$config_file" ]; then
    new_count=$(ls -d .worktrees/wt-* 2>/dev/null | wc -l | tr -d ' ')
    sed -i.bak "s/^worker_count=.*/worker_count=$new_count/" "$config_file" 2>/dev/null || \
        sed -i '' "s/^worker_count=.*/worker_count=$new_count/" "$config_file" 2>/dev/null || true
    rm -f "$config_file.bak" 2>/dev/null
fi

# Open a new tab in the front Terminal window (the workers window)
# Step 1: Cmd+T keystroke (separate osascript)
osascript -e 'tell application "System Events" to keystroke "t" using {command down}'
sleep 2
# Step 2: Run command in the new tab (separate osascript)
osascript -e "tell application \"Terminal\" to do script \"clear && printf '\\n\\033[1;44m\\033[1;37m  ████  I AM WORKER-$next_num  ████  \\033[0m\\n\\n' && cd '$PROJECT_DIR/$worktree_path' && claude --model opus --dangerously-skip-permissions\" in front window"

echo "Worker $next_num launched in slot $next_num"
