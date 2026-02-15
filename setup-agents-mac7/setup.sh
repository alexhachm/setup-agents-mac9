#!/usr/bin/env bash
# ============================================================================
# MULTI-AGENT CLAUDE CODE WORKSPACE — MAC/LINUX (THREE-MASTER) v2
# ============================================================================
# Architecture:
#   - Master-1 (Sonnet): Interface (clean context, user comms)
#   - Master-2 (Opus):   Architect (codebase context, triage, decompose, execute Tier 1)
#   - Master-3 (Sonnet): Allocator (domain map, routes tasks, monitors workers)
#   - Workers 1-8 (Opus): Isolated context per domain, strict grouping
#
# v2 improvements:
#   - Tier-based routing: Tier 1 (M2 direct), Tier 2 (single worker), Tier 3 (full pipeline)
#   - Signal-based waking via filesystem signals (replaces sleep polling)
#   - Living knowledge system with curation and instruction patching
#   - Budget/task-based context resets with staggering
#   - Pre-reset distillation protocol
#
# USAGE: chmod +x setup.sh && ./setup.sh
# ============================================================================

set -e

# Parse arguments
LAUNCH_GUI=false
for arg in "$@"; do
    case $arg in
        --gui) LAUNCH_GUI=true; shift ;;
    esac
done

# ── Resolve script directory (where templates/ and scripts/ live) ──────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step()  { echo -e "\n${CYAN}>> $1${NC}"; }
ok()    { echo -e "   ${GREEN}OK:${NC} $1"; }
skip()  { echo -e "   ${YELLOW}SKIP:${NC} $1"; }
fail()  { echo -e "   ${RED}FAIL:${NC} $1"; }

MAX_WORKERS=8

# ============================================================================
# 0. PREFLIGHT
# ============================================================================
step "Checking prerequisites..."

if [ ! -d "$SCRIPT_DIR/templates" ] || [ ! -d "$SCRIPT_DIR/scripts" ]; then
    fail "Missing templates/ or scripts/ directory next to setup.sh"
    exit 1
fi

missing=()
for tool in git node npm gh claude; do
    if ! command -v "$tool" &>/dev/null; then
        missing+=("$tool")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    fail "Missing: ${missing[*]}"
    echo "   brew install git node gh"
    echo "   npm install -g @anthropic-ai/claude-code"
    exit 1
fi

# Check for filesystem watcher (optional but recommended)
HAS_FSWATCH=false
if command -v fswatch &>/dev/null; then
    HAS_FSWATCH=true
    ok "All tools found (fswatch available — signal-based waking enabled)"
elif command -v inotifywait &>/dev/null; then
    HAS_FSWATCH=true
    ok "All tools found (inotifywait available — signal-based waking enabled)"
else
    ok "All tools found"
    skip "fswatch/inotifywait not found — agents will use polling fallback (brew install fswatch recommended)"
fi

# ============================================================================
# 1. PROJECT SETUP
# ============================================================================
step "Project setup..."

config_file="$HOME/.claude-multi-agent-config"
last_url=""
if [ -f "$config_file" ]; then
    last_url=$(grep '^repo_url=' "$config_file" 2>/dev/null | cut -d= -f2-)
fi

if [ -n "$last_url" ]; then
    read -p "GitHub repo URL [$last_url]: " repo_url
    repo_url="${repo_url:-$last_url}"
else
    read -p "GitHub repo URL (leave blank for new project): " repo_url
fi

if [ -n "$repo_url" ]; then
    default_path="$HOME/Desktop/$(basename "$repo_url" .git)"
    read -p "Clone to [$default_path]: " project_path
    project_path="${project_path:-$default_path}"
    
    if [ -d "$project_path/.git" ]; then
        cd "$project_path"
        existing_remote=$(git remote get-url origin 2>/dev/null || echo "")
        if [ "${existing_remote%.git}" = "${repo_url%.git}" ] || [ "$existing_remote" = "$repo_url" ]; then
            git fetch origin
            git pull origin main --no-rebase 2>/dev/null || git pull origin master --no-rebase 2>/dev/null || true
            ok "Updated existing repo"
        else
            read -p "   Different remote exists. Delete and re-clone? [y/N]: " del
            if [[ "$del" =~ ^[Yy]$ ]]; then
                cd /
                rm -rf "$project_path"
                git clone "$repo_url" "$project_path" && cd "$project_path"
            else
                fail "Aborted"; exit 1
            fi
        fi
    elif [ -d "$project_path" ]; then
        read -p "   Directory exists. Delete and clone? [y/N]: " del
        if [[ "$del" =~ ^[Yy]$ ]]; then
            rm -rf "$project_path"
            git clone "$repo_url" "$project_path" && cd "$project_path"
        else
            fail "Aborted"; exit 1
        fi
    else
        git clone "$repo_url" "$project_path" && cd "$project_path"
    fi
    ok "Repo ready: $project_path"
else
    default_path="$HOME/Desktop/my-app"
    read -p "Project path [$default_path]: " project_path
    project_path="${project_path:-$default_path}"
    mkdir -p "$project_path" && cd "$project_path"
    if [ ! -d ".git" ]; then
        git init
        echo -e "node_modules/\n.env\n.env.*\ndist/\n.DS_Store\n*.log\n.worktrees/" > .gitignore
        git add -A && git commit -m "Initial commit"
    fi
    ok "Project ready: $project_path"
fi

# ============================================================================
# 2. WORKER COUNT
# ============================================================================
step "Worker configuration..."

read -p "Initial workers [1-$MAX_WORKERS, default 3]: " worker_count
worker_count="${worker_count:-3}"
if ! [[ "$worker_count" =~ ^[0-9]+$ ]] || [ "$worker_count" -lt 1 ] || [ "$worker_count" -gt "$MAX_WORKERS" ]; then
    echo -e "   ${YELLOW}WARN:${NC} Invalid count '$worker_count' — must be 1-$MAX_WORKERS. Using default: 3"
    worker_count=3
fi

cat > "$config_file" << CONF
repo_url=$repo_url
worker_count=$worker_count
project_path=$project_path
CONF

ok "$worker_count workers, can scale to $MAX_WORKERS"

# ============================================================================
# 3. DIRECTORIES
# ============================================================================
step "Creating directories..."

mkdir -p .claude/agents .claude/commands .claude/hooks .claude/scripts .claude/state
mkdir -p .claude/signals
mkdir -p .claude/knowledge/domain

for ignore_entry in '.worktrees/' '.claude-shared-state/' '.claude/logs/' '.claude/signals/'; do
    if ! grep -qF "$ignore_entry" .gitignore 2>/dev/null; then
        echo "$ignore_entry" >> .gitignore
    fi
done

ok "Directories ready (including signals/ and knowledge/)"

# ============================================================================
# 4. CLAUDE.md HIERARCHY + ROLE DOCS + LOGGING + KNOWLEDGE
# ============================================================================
step "Writing CLAUDE.md hierarchy..."

mkdir -p .claude/docs .claude/logs

# ── ROOT CLAUDE.md ────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/templates/root-claude.md" CLAUDE.md
ok "Root CLAUDE.md written"

# ── MASTER ROLE DOCUMENTS ─────────────────────────────────────────────────
cp "$SCRIPT_DIR/templates/docs/master-1-role.md" .claude/docs/master-1-role.md
cp "$SCRIPT_DIR/templates/docs/master-2-role.md" .claude/docs/master-2-role.md
cp "$SCRIPT_DIR/templates/docs/master-3-role.md" .claude/docs/master-3-role.md
ok "Master role documents written"

# ── KNOWLEDGE FILES ───────────────────────────────────────────────────────
cp "$SCRIPT_DIR/templates/knowledge/codebase-insights.md" .claude/knowledge/codebase-insights.md
cp "$SCRIPT_DIR/templates/knowledge/patterns.md" .claude/knowledge/patterns.md
cp "$SCRIPT_DIR/templates/knowledge/mistakes.md" .claude/knowledge/mistakes.md
cp "$SCRIPT_DIR/templates/knowledge/user-preferences.md" .claude/knowledge/user-preferences.md
cp "$SCRIPT_DIR/templates/knowledge/allocation-learnings.md" .claude/knowledge/allocation-learnings.md
cp "$SCRIPT_DIR/templates/knowledge/instruction-patches.md" .claude/knowledge/instruction-patches.md
touch .claude/knowledge/domain/.gitkeep
ok "Knowledge files initialized"

# ── INITIALIZE ACTIVITY LOG ───────────────────────────────────────────────
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [setup] [INIT] Multi-agent system v2 initialized" > .claude/logs/activity.log
ok "Activity log initialized"

# ============================================================================
# 5. STATE FILES
# ============================================================================
step "Initializing state files..."

echo '{}' > .claude/state/handoff.json
echo '{}' > .claude/state/codebase-map.json
echo '{}' > .claude/state/worker-status.json
echo '{}' > .claude/state/fix-queue.json
echo '{"questions":[],"responses":[]}' > .claude/state/clarification-queue.json
echo '{"tasks":[]}' > .claude/state/task-queue.json

# Agent health (for reset staggering)
cat > .claude/state/agent-health.json << 'HEALTH'
{
  "master-2": { "status": "starting", "last_reset": null, "tier1_count": 0, "decomposition_count": 0 },
  "master-3": { "status": "starting", "last_reset": null, "context_budget": 0, "started_at": null },
  "workers": {}
}
HEALTH

cp "$SCRIPT_DIR/templates/state/worker-lessons.md" .claude/state/worker-lessons.md
cp "$SCRIPT_DIR/templates/state/change-summaries.md" .claude/state/change-summaries.md

ok "State files initialized (including agent-health.json)"

# ============================================================================
# 6. SUBAGENTS
# ============================================================================
step "Creating subagents..."

cp "$SCRIPT_DIR/templates/agents/code-architect.md" .claude/agents/code-architect.md
cp "$SCRIPT_DIR/templates/agents/build-validator.md" .claude/agents/build-validator.md
cp "$SCRIPT_DIR/templates/agents/verify-app.md" .claude/agents/verify-app.md

ok "Subagents created"

# ============================================================================
# 7. MASTER-1 COMMANDS
# ============================================================================
step "Creating Master-1 commands..."
cp "$SCRIPT_DIR/templates/commands/master-loop.md" .claude/commands/master-loop.md
ok "Master-1 commands created"

# ============================================================================
# 8. MASTER-2 COMMANDS (ARCHITECT)
# ============================================================================
step "Creating Master-2 (Architect) commands..."
cp "$SCRIPT_DIR/templates/commands/scan-codebase.md" .claude/commands/scan-codebase.md
cp "$SCRIPT_DIR/templates/commands/architect-loop.md" .claude/commands/architect-loop.md
ok "Master-2 (Architect) commands created"

# ============================================================================
# 8b. MASTER-3 COMMANDS (ALLOCATOR)
# ============================================================================
step "Creating Master-3 (Allocator) commands..."
cp "$SCRIPT_DIR/templates/commands/allocate-loop.md" .claude/commands/allocate-loop.md
cp "$SCRIPT_DIR/templates/commands/scan-codebase-allocator.md" .claude/commands/scan-codebase-allocator.md
ok "Master-3 (Allocator) commands created"

# ============================================================================
# 9. WORKER COMMANDS
# ============================================================================
step "Creating Worker commands..."
cp "$SCRIPT_DIR/templates/commands/worker-loop.md" .claude/commands/worker-loop.md
cp "$SCRIPT_DIR/templates/commands/commit-push-pr.md" .claude/commands/commit-push-pr.md
ok "Worker commands created"

# ============================================================================
# 10. HELPER SCRIPTS
# ============================================================================
step "Creating helper scripts..."

cp "$SCRIPT_DIR/scripts/add-worker.sh" .claude/scripts/add-worker.sh
chmod +x .claude/scripts/add-worker.sh

cp "$SCRIPT_DIR/scripts/signal-wait.sh" .claude/scripts/signal-wait.sh
chmod +x .claude/scripts/signal-wait.sh

ok "Helper scripts created (including signal-wait.sh)"

# ============================================================================
# 11. HOOKS
# ============================================================================
step "Creating hooks..."

cp "$SCRIPT_DIR/scripts/hooks/pre-tool-secret-guard.sh" .claude/hooks/pre-tool-secret-guard.sh
chmod +x .claude/hooks/pre-tool-secret-guard.sh

cp "$SCRIPT_DIR/scripts/hooks/stop-notify.sh" .claude/hooks/stop-notify.sh
chmod +x .claude/hooks/stop-notify.sh

cp "$SCRIPT_DIR/scripts/state-lock.sh" .claude/scripts/state-lock.sh
chmod +x .claude/scripts/state-lock.sh

ok "Hooks created"

# ============================================================================
# 12. SETTINGS + GLOBAL PERMISSIONS
# ============================================================================
step "Writing settings and configuring global permissions..."

cp "$SCRIPT_DIR/templates/settings.json" .claude/settings.json

mkdir -p "$HOME/.claude"

if [ -f "$HOME/.claude/settings.json" ]; then
    cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak"
    if command -v jq &>/dev/null; then
        jq --arg path "$project_path" '
          .trustedDirectories = ((.trustedDirectories // []) + [$path] | unique)
        ' "$HOME/.claude/settings.json" > "$HOME/.claude/settings.json.tmp" \
          && mv "$HOME/.claude/settings.json.tmp" "$HOME/.claude/settings.json"
    else
        if ! grep -qF "$project_path" "$HOME/.claude/settings.json" 2>/dev/null; then
            skip "jq not found — add \"$project_path\" to trustedDirectories in ~/.claude/settings.json manually"
        fi
    fi
else
    cat > "$HOME/.claude/settings.json" << EOF
{
  "trustedDirectories": ["$project_path"]
}
EOF
fi

ok "Settings written (project + global)"

# ============================================================================
# 13. COMMIT
# ============================================================================
step "Committing orchestration files..."

default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
if [ -z "$default_branch" ]; then
    if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
        default_branch="main"
    elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
        default_branch="master"
    else
        default_branch="main"
    fi
fi

git checkout -b "$default_branch" 2>/dev/null || git checkout "$default_branch" 2>/dev/null || true

git add CLAUDE.md .claude/ .gitignore 2>/dev/null || true
git commit -m "feat: v2 three-master architecture with tier routing, knowledge system, signal waking" 2>/dev/null || true

ok "Orchestration files committed to $default_branch"

# ============================================================================
# 14. SHARED STATE
# ============================================================================
step "Setting up shared state directory..."

shared_state_dir="$project_path/.claude-shared-state"
mkdir -p "$shared_state_dir"

if [ -L ".claude/state" ]; then
    rm -f .claude/state
    mkdir -p .claude/state
    for f in handoff.json codebase-map.json worker-status.json fix-queue.json clarification-queue.json task-queue.json agent-health.json worker-lessons.md change-summaries.md; do
        if [ ! -f "$shared_state_dir/$f" ]; then
            echo '{}' > ".claude/state/$f"
        fi
    done
fi

for f in handoff.json codebase-map.json worker-status.json fix-queue.json clarification-queue.json task-queue.json agent-health.json worker-lessons.md change-summaries.md; do
    if [ -f ".claude/state/$f" ] && [ ! -L ".claude/state/$f" ]; then
        cp ".claude/state/$f" "$shared_state_dir/$f"
    fi
    if [ ! -f "$shared_state_dir/$f" ]; then
        case "$f" in
            clarification-queue.json) echo '{"questions":[],"responses":[]}' > "$shared_state_dir/$f" ;;
            task-queue.json) echo '{"tasks":[]}' > "$shared_state_dir/$f" ;;
            agent-health.json) cp .claude/state/agent-health.json "$shared_state_dir/$f" ;;
            worker-lessons.md) cp "$SCRIPT_DIR/templates/state/worker-lessons.md" "$shared_state_dir/$f" ;;
            change-summaries.md) cp "$SCRIPT_DIR/templates/state/change-summaries.md" "$shared_state_dir/$f" ;;
            *) echo '{}' > "$shared_state_dir/$f" ;;
        esac
    fi
done

rm -rf .claude/state
ln -sf "../.claude-shared-state" .claude/state

if ! grep -qF '.claude-shared-state/' .gitignore 2>/dev/null; then
    echo '.claude-shared-state/' >> .gitignore
fi

git add .gitignore 2>/dev/null || true
git commit -m "chore: ignore shared state directory" 2>/dev/null || true

ok "Shared state at $shared_state_dir"

# ============================================================================
# 15. WORKTREES
# ============================================================================
step "Setting up worktrees..."

for i in $(seq 1 8); do
    [ -d ".worktrees/wt-$i" ] && git worktree remove ".worktrees/wt-$i" --force 2>/dev/null || true
done
git worktree prune 2>/dev/null || true
for i in $(seq 1 $worker_count); do
    git branch -D "agent-$i" 2>/dev/null || true
done
rm -rf .worktrees 2>/dev/null || true

mkdir -p .worktrees
for i in $(seq 1 $worker_count); do
    git worktree add ".worktrees/wt-$i" -b "agent-$i"
    rm -rf ".worktrees/wt-$i/.claude/state"
    ln -sf "../../../.claude-shared-state" ".worktrees/wt-$i/.claude/state"
    
    mkdir -p ".worktrees/wt-$i/.claude/logs"
    rm -rf ".worktrees/wt-$i/.claude/logs"
    ln -sf "../../../.claude/logs" ".worktrees/wt-$i/.claude/logs"
    
    # Symlink knowledge directory so workers read shared knowledge
    rm -rf ".worktrees/wt-$i/.claude/knowledge"
    ln -sf "../../../.claude/knowledge" ".worktrees/wt-$i/.claude/knowledge"
    
    # Symlink signals directory
    rm -rf ".worktrees/wt-$i/.claude/signals"
    ln -sf "../../../.claude/signals" ".worktrees/wt-$i/.claude/signals"
    
    cp "$SCRIPT_DIR/templates/worker-claude.md" ".worktrees/wt-$i/CLAUDE.md"
done

ok "$worker_count worktrees created (sharing state, knowledge, signals, and logs)"

# ============================================================================
# COMPLETE
# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  SETUP COMPLETE (v2)${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "ARCHITECTURE:"
echo "  Master-1 (Sonnet):  $project_path (interface — talk here)"
echo "  Master-2 (Opus):    $project_path (architect — triage + decompose)"
echo "  Master-3 (Sonnet):  $project_path (allocator — routes to workers)"
for i in $(seq 1 $worker_count); do
    echo "  Worker-$i (Opus):   $project_path/.worktrees/wt-$i"
done
echo ""
echo "TIER ROUTING:"
echo "  Tier 1: Trivial → Master-2 executes directly (~2-5 min)"
echo "  Tier 2: Single domain → Master-2 assigns to one worker (~5-15 min)"
echo "  Tier 3: Multi-domain → Full decomposition pipeline (~20-60 min)"
echo ""
echo "TERMINALS NEEDED: $((worker_count + 3))"
echo ""

read -p "Launch all terminals now? [Y/n]: " launch
launch="${launch:-Y}"

if [[ "$launch" =~ ^[Yy]$ ]]; then
    
    echo ""
    echo -e "${CYAN}SESSION CONTEXT${NC}"
    echo ""
    echo "  1) Fresh start  — wipe ALL prior conversation memory and task state"
    echo "  2) Continue      — agents resume their previous sessions (retains context)"
    echo ""
    read -p "Choose [1/2, default 1]: " session_mode
    session_mode="${session_mode:-1}"
    
    if [[ "$session_mode" == "2" ]]; then
        step "Continuing previous sessions (preserving context)..."
        rm -rf "$project_path/.claude-shared-state/"*.lockdir 2>/dev/null || true
        rm -f "$project_path/.claude-shared-state/"*.lock 2>/dev/null || true
        CLAUDE_SESSION_FLAG="--continue"
        ok "Sessions preserved — agents will resume where they left off"
    else
        step "Resetting sessions (wiping ALL Claude Code state)..."
        
        for f in handoff.json codebase-map.json worker-status.json fix-queue.json; do
            echo '{}' > "$project_path/.claude-shared-state/$f" 2>/dev/null || true
        done
        echo '{"questions":[],"responses":[]}' > "$project_path/.claude-shared-state/clarification-queue.json" 2>/dev/null || true
        echo '{"tasks":[]}' > "$project_path/.claude-shared-state/task-queue.json" 2>/dev/null || true
        cat > "$project_path/.claude-shared-state/agent-health.json" << 'HEALTH'
{
  "master-2": { "status": "starting", "last_reset": null, "tier1_count": 0, "decomposition_count": 0 },
  "master-3": { "status": "starting", "last_reset": null, "context_budget": 0, "started_at": null },
  "workers": {}
}
HEALTH
        
        # NOTE: Knowledge files are NOT wiped on fresh start — they are persistent learnings
        # Only wipe them manually if you want to start from zero knowledge
        
        rm -rf "$HOME/.claude/projects" 2>/dev/null || true
        rm -f "$HOME/.claude/history.jsonl" 2>/dev/null || true
        rm -rf "$HOME/.claude/session-env" 2>/dev/null || true
        rm -rf "$HOME/.claude/todos" 2>/dev/null || true
        rm -rf "$HOME/.claude/tasks" 2>/dev/null || true
        rm -rf "$HOME/.claude/plans" 2>/dev/null || true
        rm -rf "$HOME/.claude/shell-snapshots" 2>/dev/null || true
        
        rm -f "$project_path/.claude/todos.json" 2>/dev/null || true
        rm -rf "$project_path/.claude/.tasks" 2>/dev/null || true
        rm -rf "$project_path/.claude/tasks" 2>/dev/null || true
        
        for i in $(seq 1 $worker_count); do
            wt="$project_path/.worktrees/wt-$i"
            if [ -d "$wt" ]; then
                rm -f "$wt/.claude/todos.json" 2>/dev/null || true
                rm -rf "$wt/.claude/.tasks" 2>/dev/null || true
                rm -rf "$wt/.claude/tasks" 2>/dev/null || true
            fi
        done
        
        rm -rf "$project_path/.claude-shared-state/"*.lockdir 2>/dev/null || true
        rm -f "$project_path/.claude-shared-state/"*.lock 2>/dev/null || true
        rm -f "$project_path/.claude/signals/"* 2>/dev/null || true
        
        mkdir -p "$project_path/.claude/logs"
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [setup] [FRESH_RESET] All sessions wiped (knowledge preserved)" > "$project_path/.claude/logs/activity.log"
        
        CLAUDE_SESSION_FLAG=""
        ok "Sessions FULLY reset — knowledge files PRESERVED across reset"
    fi
    
    # ==================================================================
    # TERMINAL LAUNCH
    # ==================================================================
    step "Launching terminals..."
    
    launcher_dir="$project_path/.claude/launchers"
    mkdir -p "$launcher_dir"
    
    # ── MODEL SELECTION (v2) ──────────────────────────────────────────
    # Master-1: Sonnet (routing, no code analysis)
    # Master-2: Opus (decomposition quality is highest-leverage reasoning)
    # Master-3: Sonnet (operational decisions, fast polling)
    # Workers:  Opus (code implementation quality)
    
    if [ -n "$CLAUDE_SESSION_FLAG" ]; then
        master1_cmd="claude $CLAUDE_SESSION_FLAG --model sonnet --dangerously-skip-permissions"
        master2_cmd="claude $CLAUDE_SESSION_FLAG --model opus --dangerously-skip-permissions"
        master3_cmd="claude $CLAUDE_SESSION_FLAG --model sonnet --dangerously-skip-permissions"
        worker_cmd="claude $CLAUDE_SESSION_FLAG --model opus --dangerously-skip-permissions"
    else
        master1_cmd="claude --model sonnet --dangerously-skip-permissions '/master-loop'"
        master2_cmd="claude --model opus --dangerously-skip-permissions '/scan-codebase'"
        master3_cmd="claude --model sonnet --dangerously-skip-permissions '/scan-codebase-allocator'"
        worker_cmd="claude --model opus --dangerously-skip-permissions '/worker-loop'"
    fi
    
    cat > "$launcher_dir/master-2.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;45m\\033[1;37m  ████  I AM MASTER-2 — ARCHITECT (Opus)  ████  \\033[0m\\n\\n'
cd '$project_path'
exec $master2_cmd
LAUNCHER
    chmod +x "$launcher_dir/master-2.sh"
    
    cat > "$launcher_dir/master-3.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;43m\\033[1;30m  ████  I AM MASTER-3 — ALLOCATOR (Sonnet)  ████  \\033[0m\\n\\n'
cd '$project_path'
exec $master3_cmd
LAUNCHER
    chmod +x "$launcher_dir/master-3.sh"
    
    cat > "$launcher_dir/master-1.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;42m\\033[1;37m  ████  I AM MASTER-1 — YOUR INTERFACE (Sonnet)  ████  \\033[0m\\n\\n'
cd '$project_path'
exec $master1_cmd
LAUNCHER
    chmod +x "$launcher_dir/master-1.sh"
    
    for i in $(seq 1 $worker_count); do
        cat > "$launcher_dir/worker-$i.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;44m\\033[1;37m  ████  I AM WORKER-$i (Opus)  ████  \\033[0m\\n\\n'
cd '$project_path/.worktrees/wt-$i'
exec $worker_cmd
LAUNCHER
        chmod +x "$launcher_dir/worker-$i.sh"
    done
    
    ok "Launcher scripts written"
    
    # ── Launcher Manifest (for GUI consumption) ──────────────────────
    step "Writing launcher manifest..."

    cat > "$launcher_dir/manifest.json" << MANIFEST
{
  "project_path": "$project_path",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "session_mode": "${session_mode:-1}",
  "agents": [
MANIFEST

    # Masters
    for agent in "master-1:Interface:sonnet:$project_path" "master-2:Architect:opus:$project_path" "master-3:Allocator:sonnet:$project_path"; do
        IFS=: read -r id role model cwd <<< "$agent"
        if [ "$id" = "master-2" ]; then
            cmd_fresh="/scan-codebase"
        elif [ "$id" = "master-3" ]; then
            cmd_fresh="/scan-codebase-allocator"
        else
            cmd_fresh="/master-loop"
        fi
        
        cat >> "$launcher_dir/manifest.json" << ENTRY
    {
      "id": "$id",
      "role": "$role",
      "model": "$model",
      "cwd": "$cwd",
      "command_fresh": "claude --model $model --dangerously-skip-permissions '$cmd_fresh'",
      "command_continue": "claude --continue --model $model --dangerously-skip-permissions",
      "launcher_unix": ".claude/launchers/$id.sh",
      "launcher_win": ".claude/launchers/$id.bat",
      "group": "masters"
    },
ENTRY
    done

    # Workers
    for i in $(seq 1 $worker_count); do
        cat >> "$launcher_dir/manifest.json" << ENTRY
    {
      "id": "worker-$i",
      "role": "Worker",
      "model": "opus",
      "cwd": "$project_path/.worktrees/wt-$i",
      "command_fresh": "claude --model opus --dangerously-skip-permissions '/worker-loop'",
      "command_continue": "claude --continue --model opus --dangerously-skip-permissions",
      "launcher_unix": ".claude/launchers/worker-$i.sh",
      "launcher_win": ".claude/launchers/worker-$i.bat",
      "group": "workers"
    },
ENTRY
    done

    # Close JSON (strip trailing comma with sed)
    sed -i.bak '$ s/,$//' "$launcher_dir/manifest.json" 2>/dev/null || \
        sed -i '' '$ s/,$//' "$launcher_dir/manifest.json" 2>/dev/null
    cat >> "$launcher_dir/manifest.json" << 'MANIFEST'
  ]
}
MANIFEST
    rm -f "$launcher_dir/manifest.json.bak"

    ok "Launcher manifest written"

    # ── Windows Launchers (.bat + .ps1) ──────────────────────────────
    step "Generating cross-platform launcher scripts..."

    for agent_sh in "$launcher_dir"/*.sh; do
        agent_name=$(basename "$agent_sh" .sh)
        # Extract the cd path and claude command from the sh file
        agent_cwd=$(grep "^cd " "$agent_sh" | sed "s/^cd '//;s/'$//")
        agent_cmd=$(grep "^exec " "$agent_sh" | sed "s/^exec //")
        agent_upper=$(echo "$agent_name" | tr '[:lower:]' '[:upper:]' | tr '-' ' ')

        cat > "$launcher_dir/$agent_name.bat" << BATCH
@echo off
cls
echo.
echo   ████  I AM ${agent_upper}  ████
echo.
cd /d "$agent_cwd"
$agent_cmd
BATCH

        cat > "$launcher_dir/$agent_name.ps1" << PWSH
Clear-Host
Write-Host "\`n  ████  I AM ${agent_upper}  ████\`n" -ForegroundColor Cyan
Set-Location "$agent_cwd"
& $agent_cmd
PWSH
    done

    ok "Cross-platform launcher scripts written (.sh, .bat, .ps1)"

    # ── Terminal creation (macOS) ─────────────────────────────────────
    merge_visible_windows() {
        osascript << 'MERGE_SCRIPT'
tell application "Terminal" to activate
delay 0.5
tell application "System Events"
    tell process "Terminal"
        click menu item "Merge All Windows" of menu "Window" of menu bar 1
    end tell
end tell
MERGE_SCRIPT
    }
    
    step "  Preparing setup window..."
    SETUP_WIN_ID=$(osascript -e 'tell application "Terminal" to return id of front window')
    osascript -e "tell application \"Terminal\" to set miniaturized of window id $SETUP_WIN_ID to true"
    sleep 1
    ok "  Setup window minimized (ID: $SETUP_WIN_ID)"
    
    step "  Creating master windows..."
    
    osascript -e "tell application \"Terminal\"
        activate
        do script \"$launcher_dir/master-2.sh\"
    end tell"
    sleep 2
    
    osascript -e "tell application \"Terminal\"
        do script \"$launcher_dir/master-3.sh\"
    end tell"
    sleep 2
    
    osascript -e "tell application \"Terminal\"
        do script \"$launcher_dir/master-1.sh\"
    end tell"
    sleep 2
    
    ok "  3 master windows created"
    
    step "  Merging masters into tabs..."
    merge_visible_windows
    sleep 2
    
    MASTER_WIN_ID=$(osascript -e 'tell application "Terminal" to return id of front window')
    MASTER_TAB_COUNT=$(osascript -e "tell application \"Terminal\" to return count of tabs of window id $MASTER_WIN_ID")
    ok "  Masters merged: $MASTER_TAB_COUNT tabs in window $MASTER_WIN_ID"
    
    osascript -e "tell application \"Terminal\" to set miniaturized of window id $MASTER_WIN_ID to true"
    sleep 1
    
    step "  Creating worker windows..."
    
    for i in $(seq 1 $worker_count); do
        osascript -e "tell application \"Terminal\"
            activate
            do script \"$launcher_dir/worker-$i.sh\"
        end tell"
        sleep 2
    done
    
    ok "  $worker_count worker windows created"
    
    if [ "$worker_count" -gt 1 ]; then
        step "  Merging workers into tabs..."
        merge_visible_windows
        sleep 2
    fi
    
    WORKER_WIN_ID=$(osascript -e 'tell application "Terminal" to return id of front window')
    WORKER_TAB_COUNT=$(osascript -e "tell application \"Terminal\" to return count of tabs of window id $WORKER_WIN_ID")
    ok "  Workers merged: $WORKER_TAB_COUNT tabs in window $WORKER_WIN_ID"
    
    step "  Restoring windows..."
    osascript -e "tell application \"Terminal\"
        set miniaturized of window id $MASTER_WIN_ID to false
        set miniaturized of window id $SETUP_WIN_ID to false
    end tell" 2>/dev/null || true
    sleep 1
    ok "  All windows restored"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ALL TERMINALS LAUNCHED (v2)${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    if [ -n "$CLAUDE_SESSION_FLAG" ]; then
        echo -e "${CYAN}MODE: CONTINUE — agents resuming previous sessions${NC}"
    else
        echo -e "${CYAN}MODE: FRESH — clean sessions, persistent knowledge preserved${NC}"
    fi
    echo ""
    echo "MASTERS WINDOW (3 tabs):"
    echo "  Tab 1: MASTER-2 (Opus) — Architect (scanning, then triage + decompose)"
    echo "  Tab 2: MASTER-3 (Sonnet) — Allocator (scanning, then routing)"
    echo "  Tab 3: MASTER-1 (Sonnet) — Interface (talk here)"
    echo ""
    echo "WORKERS WINDOW ($worker_count tabs):"
    for i in $(seq 1 $worker_count); do
        echo "  Tab $i: WORKER-$i (Opus)"
    done
    echo ""
    echo -e "${YELLOW}Tier 1 tasks (trivial): Master-2 executes directly (~2-5 min)${NC}"
    echo -e "${YELLOW}Tier 2 tasks (single domain): Assigned to one worker (~5-15 min)${NC}"
    echo -e "${YELLOW}Tier 3 tasks (multi-domain): Full decomposition pipeline (~20-60 min)${NC}"
    echo ""
    echo -e "${YELLOW}Knowledge persists across resets — system improves over time.${NC}"
    echo -e "${YELLOW}Just talk to MASTER-1 (Tab 3, Masters window)!${NC}"
    echo ""
fi

if [ "$LAUNCH_GUI" = true ]; then
    step "Starting Agent Control Center GUI..."
    GUI_DIR="$SCRIPT_DIR/gui"
    if [ -d "$GUI_DIR" ]; then
        if [ ! -d "$GUI_DIR/node_modules" ]; then
            echo "   Installing GUI dependencies..."
            (cd "$GUI_DIR" && npm install --silent 2>/dev/null)
        fi
        echo "   Starting control center..."
        (cd "$GUI_DIR" && unset ELECTRON_RUN_AS_NODE && npm start -- "$project_path" &)
        sleep 2
        ok "Agent Control Center GUI launched!"
    else
        fail "GUI directory not found at $GUI_DIR"
    fi
fi
