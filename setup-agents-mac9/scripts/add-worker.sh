#!/usr/bin/env bash
set -e
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

# Cross-platform directory link helper (NTFS junction on Windows/WSL, symlink on native Linux/macOS)
link_dir() {
    local link_path="$1" target_path="$2"
    rm -rf "$link_path"
    # Detect if we're on NTFS (Git Bash, MSYS2, Cygwin, or WSL with /mnt/c paths)
    local use_junction=false
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        use_junction=true
    elif grep -qi microsoft /proc/version 2>/dev/null && [[ "$link_path" == /mnt/* ]]; then
        # WSL on an NTFS mount — symlinks don't work, use PowerShell junction
        use_junction=true
    fi

    if $use_junction && command -v powershell.exe &>/dev/null; then
        local win_link win_target
        if command -v cygpath &>/dev/null; then
            win_link=$(cygpath -w "$link_path" 2>/dev/null)
            win_target=$(cd "$target_path" 2>/dev/null && cygpath -w "$(pwd)" 2>/dev/null || cygpath -w "$target_path" 2>/dev/null)
        elif command -v wslpath &>/dev/null; then
            win_link=$(wslpath -w "$link_path" 2>/dev/null)
            win_target=$(cd "$target_path" 2>/dev/null && wslpath -w "$(pwd)" 2>/dev/null || wslpath -w "$target_path" 2>/dev/null)
        else
            # Fallback: convert /mnt/c/... to C:\...
            win_link=$(echo "$link_path" | sed 's|^/mnt/\([a-z]\)/|\U\1:\\|; s|/|\\|g')
            win_target=$(cd "$target_path" 2>/dev/null && pwd | sed 's|^/mnt/\([a-z]\)/|\U\1:\\|; s|/|\\|g' || echo "$target_path" | sed 's|^/mnt/\([a-z]\)/|\U\1:\\|; s|/|\\|g')
        fi
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

# Fix gitdir paths to be relative (works in both Git Bash and WSL)
echo "gitdir: ../../.git/worktrees/wt-$next_num" > "$worktree_path/.git"
if [ -f ".git/worktrees/wt-$next_num/gitdir" ]; then
    echo "../../../.worktrees/wt-$next_num/.git" > ".git/worktrees/wt-$next_num/gitdir"
fi

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

# Generate unified .sh + .ps1 launcher for the new worker
launcher_dir="$PROJECT_DIR/.claude/launchers"
if [ -d "$launcher_dir" ]; then
    # ── .sh launcher (all platforms) ──
    sh_file="$launcher_dir/worker-$next_num.sh"
    cat > "$sh_file" << 'WORKER_SH'
#!/usr/bin/env bash
# Unified launcher for __ID__ — delegates to worker-sentinel.sh
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$PROJECT_DIR/.claude/scripts/worker-sentinel.sh" __NUM__ "$PROJECT_DIR"
WORKER_SH
    sed -i "s|__ID__|worker-$next_num|g; s|__NUM__|$next_num|g" "$sh_file"
    sed -i 's/\r$//' "$sh_file"
    chmod +x "$sh_file" 2>/dev/null || true

    # ── .ps1 wrapper (Windows only) ──
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        ps1_file="$launcher_dir/worker-$next_num.ps1"
        cat > "$ps1_file" << 'PS1_TEMPLATE'
# Unified launcher for __ID__
# DO NOT add non-ASCII chars. PowerShell 5.1 reads without UTF-8 BOM.
param([switch]$Continue)

$ProjectDir = (Resolve-Path "$PSScriptRoot\..\..").Path
$WslProject = '/mnt/' + $ProjectDir.Substring(0,1).ToLower() + $ProjectDir.Substring(2).Replace('\','/')
$ShFile = "$WslProject/.claude/launchers/__ID__.sh"

Clear-Host
Write-Host "  __LABEL__ SENTINEL" -ForegroundColor Green
wsl.exe bash -l $ShFile
$ec = $LASTEXITCODE
if ($ec -ne 0) {
    Write-Host ""
    Write-Host "  AGENT EXITED (code $ec)" -ForegroundColor Red
    Write-Host "  Press Enter to close..." -ForegroundColor DarkGray
    Read-Host | Out-Null
}
PS1_TEMPLATE
        id_upper=$(echo "WORKER-$next_num" | tr '[:lower:]' '[:upper:]')
        sed -i \
            -e "s|__ID__|worker-$next_num|g" \
            -e "s|__LABEL__|$id_upper|g" \
            -e 's/$/\r/' \
            "$ps1_file"
    fi

    # Update v4 manifest.json — add new worker entry
    manifest_file="$launcher_dir/manifest.json"
    if [ -f "$manifest_file" ] && command -v jq &>/dev/null; then
        jq --arg id "worker-$next_num" --arg num "$next_num" \
            '.agents += [{"id": $id, "group": "workers", "role": ("Worker " + $num + " (Opus)"), "model": "opus", "command": "/worker-loop", "env": "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1", "worktree": (".worktrees/wt-" + $num)}] | .worker_count = (.agents | map(select(.group == "workers")) | length)' \
            "$manifest_file" > /tmp/manifest_add.json && mv /tmp/manifest_add.json "$manifest_file"
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
