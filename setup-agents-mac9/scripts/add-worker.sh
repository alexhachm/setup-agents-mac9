#!/usr/bin/env bash
set -e
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

# Cross-platform directory link helper (NTFS junction on Windows, symlink elsewhere)
link_dir() {
    local link_path="$1" target_path="$2"
    rm -rf "$link_path"
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        local win_link win_target
        win_link=$(cygpath -w "$link_path" 2>/dev/null || echo "$link_path" | sed 's|/|\\|g')
        win_target=$(cd "$target_path" 2>/dev/null && cygpath -w "$(pwd)" 2>/dev/null || cygpath -w "$target_path" 2>/dev/null || echo "$target_path" | sed 's|/|\\|g')
        powershell.exe -Command "New-Item -ItemType Junction -Path '$win_link' -Target '$win_target'" > /dev/null 2>&1
    else
        ln -sf "$target_path" "$link_path"
    fi
}

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

# Link shared state into the new worktree
shared_state_dir="$PROJECT_DIR/.claude-shared-state"
if [ -d "$shared_state_dir" ]; then
    link_dir "$worktree_path/.claude/state" "$shared_state_dir"
fi

# Link logs directory so new worker can write to shared log
mkdir -p "$worktree_path/.claude/logs"
link_dir "$worktree_path/.claude/logs" "$PROJECT_DIR/.claude/logs"

# Link knowledge directory (shared across all agents)
link_dir "$worktree_path/.claude/knowledge" "$PROJECT_DIR/.claude/knowledge"

# Link signals directory (shared for cross-agent signaling)
link_dir "$worktree_path/.claude/signals" "$PROJECT_DIR/.claude/signals"

# Copy commands, hooks, scripts so worker has /worker-loop, /commit-push-pr, etc.
for dir in commands hooks scripts; do
    if [ -d "$PROJECT_DIR/.claude/$dir" ]; then
        mkdir -p "$worktree_path/.claude/$dir"
        cp -r "$PROJECT_DIR/.claude/$dir/"* "$worktree_path/.claude/$dir/" 2>/dev/null || true
    fi
done

# Copy settings.json
if [ -f "$PROJECT_DIR/.claude/settings.json" ]; then
    cp "$PROJECT_DIR/.claude/settings.json" "$worktree_path/.claude/settings.json"
fi

# Copy worker CLAUDE.md (try wt-1 first, fall back to project root)
if [ -f "$PROJECT_DIR/.worktrees/wt-1/CLAUDE.md" ]; then
    cp "$PROJECT_DIR/.worktrees/wt-1/CLAUDE.md" "$worktree_path/CLAUDE.md"
elif [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
    cp "$PROJECT_DIR/CLAUDE.md" "$worktree_path/CLAUDE.md"
fi

# Generate launcher script for the new worker
launcher_dir="$PROJECT_DIR/.claude/launchers"
if [ -d "$launcher_dir" ]; then
    cat > "$launcher_dir/worker-$next_num.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;44m\\033[1;37m  ████  I AM WORKER-$next_num (Opus)  ████  \\033[0m\\n\\n'
cd '$PROJECT_DIR/.worktrees/wt-$next_num'
exec env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --model opus --dangerously-skip-permissions '/worker-loop'
LAUNCHER
    chmod +x "$launcher_dir/worker-$next_num.sh"

    cat > "$launcher_dir/worker-$next_num-continue.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;44m\\033[1;37m  ████  I AM WORKER-$next_num (Opus) [CONTINUE]  ████  \\033[0m\\n\\n'
cd '$PROJECT_DIR/.worktrees/wt-$next_num'
exec env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --continue --model opus --dangerously-skip-permissions
LAUNCHER
    chmod +x "$launcher_dir/worker-$next_num-continue.sh"

    # Generate Windows .ps1 wrappers if on Windows
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        wsl_launcher_dir=$(wsl.exe wslpath -u "$(cygpath -w "$launcher_dir")" 2>/dev/null | tr -d '\r' || echo "$launcher_dir")
        printf '%s\r\n' \
            "# DO NOT add non-ASCII chars. PowerShell 5.1 reads without UTF-8 BOM." \
            "Clear-Host" \
            "Write-Host \"  I AM WORKER-$next_num (Opus)\" -ForegroundColor Green" \
            "wsl.exe bash -l $wsl_launcher_dir/worker-$next_num.sh" \
            > "$launcher_dir/worker-$next_num.ps1"
        printf '%s\r\n' \
            "# DO NOT add non-ASCII chars. PowerShell 5.1 reads without UTF-8 BOM." \
            "Clear-Host" \
            "Write-Host \"  I AM WORKER-$next_num (Opus) [CONTINUE]\" -ForegroundColor Green" \
            "wsl.exe bash -l $wsl_launcher_dir/worker-$next_num-continue.sh" \
            > "$launcher_dir/worker-$next_num-continue.ps1"
    fi
fi

# Add new worker to worker-status.json (if jq available)
if command -v jq &>/dev/null; then
    ws_file="$PROJECT_DIR/.claude/state/worker-status.json"
    if [ -f "$ws_file" ]; then
        jq ".\"worker-$next_num\" = {\"status\":\"idle\",\"domain\":null,\"current_task\":null,\"tasks_completed\":0,\"context_budget\":0,\"claimed_by\":null,\"last_heartbeat\":null}" "$ws_file" > /tmp/ws_add.json && mv /tmp/ws_add.json "$ws_file"
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

# Workers are launched on demand by Masters via launch-worker.sh
echo "Worker $next_num worktree created in slot $next_num (launch on demand)"
