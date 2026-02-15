#!/usr/bin/env bash
# ============================================================================
# CONSOLIDATED CODEBASE - COMPLETE VERBATIM VERSION
# ============================================================================
# This file contains the ENTIRE multi-agent orchestration codebase.
# All code is commented out within a heredoc block.
# ============================================================================

: << 'END_CONSOLIDATED_CODEBASE'

################################################################################
# FILE: setup.sh (825 lines)
################################################################################

#!/usr/bin/env bash
# ============================================================================
# MULTI-AGENT CLAUDE CODE WORKSPACE — MAC/LINUX (THREE-MASTER)
# ============================================================================
# Architecture:
#   - Master-1: Interface (clean context, user comms, surfaces clarifications)
#   - Master-2: Architect (codebase context, decomposes into granular tasks)
#   - Master-3: Allocator (domain map, routes tasks, monitors workers, merges)
#   - Workers 1-8: Isolated context per domain, strict grouping
#
# Key insight: decomposition is creative (needs thought + codebase knowledge),
# allocation is operational (needs speed + reliability). Mixing them in one
# agent means the polling loop interrupts good decomposition and complex
# requests get rushed mid-allocation-cycle.
#
# Data flow (one-directional except async clarifications):
#   Intent:          Master-1 → Master-2 (handoff.json)
#   Decomposed work: Master-2 → Master-3 (task-queue.json)
#   Clarifications:  Master-2 → Master-1 → User → Master-1 → Master-2
#   Status:          Workers → Master-3 (worker-status.json)
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

# Verify templates directory exists
if [ ! -d "$SCRIPT_DIR/templates" ] || [ ! -d "$SCRIPT_DIR/scripts" ]; then
    fail "Missing templates/ or scripts/ directory next to setup.sh"
    echo "   Expected structure:"
    echo "     setup.sh"
    echo "     templates/  (commands, docs, agents, state)"
    echo "     scripts/    (state-lock.sh, add-worker.sh, hooks/)"
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
ok "All tools found"

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

# Ensure .worktrees/ is in .gitignore regardless of how the repo was created
for ignore_entry in '.worktrees/' '.claude-shared-state/' '.claude/logs/'; do
    if ! grep -qF "$ignore_entry" .gitignore 2>/dev/null; then
        echo "$ignore_entry" >> .gitignore
    fi
done

ok "Directories ready"

# ============================================================================
# 4. CLAUDE.md HIERARCHY + ROLE DOCS + LOGGING
# ============================================================================
# File hierarchy:
#   CLAUDE.md                     ← Root: masters read this (architecture, protocols, lessons)
#   .claude/docs/master-1-role.md ← Deep role context for Master-1
#   .claude/docs/master-2-role.md ← Deep role context for Master-2
#   .claude/docs/master-3-role.md ← Deep role context for Master-3
#   .worktrees/wt-N/CLAUDE.md    ← Workers read ONLY this (task protocol, domain rules)
#   .claude/logs/                 ← Structured activity logs (all agents write, Master-3 reads)
# ============================================================================
step "Writing CLAUDE.md hierarchy..."

mkdir -p .claude/docs .claude/logs

# ── ROOT CLAUDE.md (Read by all 3 masters) ────────────────────────────────
cp "$SCRIPT_DIR/templates/root-claude.md" CLAUDE.md
ok "Root CLAUDE.md written"

# ── MASTER ROLE DOCUMENTS ─────────────────────────────────────────────────
cp "$SCRIPT_DIR/templates/docs/master-1-role.md" .claude/docs/master-1-role.md
cp "$SCRIPT_DIR/templates/docs/master-2-role.md" .claude/docs/master-2-role.md
cp "$SCRIPT_DIR/templates/docs/master-3-role.md" .claude/docs/master-3-role.md
ok "Master role documents written"

# ── INITIALIZE ACTIVITY LOG ───────────────────────────────────────────────
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [setup] [INIT] Multi-agent system initialized" > .claude/logs/activity.log
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

cp "$SCRIPT_DIR/templates/state/worker-lessons.md" .claude/state/worker-lessons.md
cp "$SCRIPT_DIR/templates/state/change-summaries.md" .claude/state/change-summaries.md

ok "State files initialized"

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

ok "Helper scripts created"

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

# Also add to global settings — MERGE rather than overwrite to avoid
# clobbering settings from other projects or user customizations.
mkdir -p "$HOME/.claude"

if [ -f "$HOME/.claude/settings.json" ]; then
    # Backup existing
    cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak"

    # Merge: add this project to trustedDirectories if not already present
    if command -v jq &>/dev/null; then
        jq --arg path "$project_path" '
          .trustedDirectories = ((.trustedDirectories // []) + [$path] | unique)
        ' "$HOME/.claude/settings.json" > "$HOME/.claude/settings.json.tmp" \
          && mv "$HOME/.claude/settings.json.tmp" "$HOME/.claude/settings.json"
    else
        # Fallback without jq: only write if file doesn't already reference this project
        if ! grep -qF "$project_path" "$HOME/.claude/settings.json" 2>/dev/null; then
            skip "jq not found — add \"$project_path\" to trustedDirectories in ~/.claude/settings.json manually"
        fi
    fi
else
    # No existing global settings — safe to create fresh (project-scoped only)
    cat > "$HOME/.claude/settings.json" << EOF
{
  "trustedDirectories": ["$project_path"]
}
EOF
fi

ok "Settings written (project + global)"

# ============================================================================
# 13. COMMIT (must happen BEFORE worktree creation so branches get all files)
# ============================================================================
step "Committing orchestration files..."

# Detect the default branch name (main, master, or whatever the repo uses)
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
if [ -z "$default_branch" ]; then
    # No remote HEAD — check local branches
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
git commit -m "feat: three-master architecture (interface/architect/allocator) with strict domain isolation" 2>/dev/null || true

ok "Orchestration files committed to $default_branch"

# ============================================================================
# 14. SHARED STATE (all agents read/write the same state files)
# ============================================================================
step "Setting up shared state directory..."

shared_state_dir="$project_path/.claude-shared-state"
mkdir -p "$shared_state_dir"

# If .claude/state is already a symlink (from a previous run), remove it first
# so we can copy real files before re-linking
if [ -L ".claude/state" ]; then
    rm -f .claude/state
    mkdir -p .claude/state
    # Restore empty state files so the copy below has something to work with
    # (only if the shared dir doesn't already have them)
    for f in handoff.json codebase-map.json worker-status.json fix-queue.json clarification-queue.json task-queue.json worker-lessons.md change-summaries.md; do
        if [ ! -f "$shared_state_dir/$f" ]; then
            echo '{}' > ".claude/state/$f"
        fi
    done
fi

# Copy state files into shared directory (skip if already there)
for f in handoff.json codebase-map.json worker-status.json fix-queue.json clarification-queue.json task-queue.json worker-lessons.md change-summaries.md; do
    if [ -f ".claude/state/$f" ] && [ ! -L ".claude/state/$f" ]; then
        cp ".claude/state/$f" "$shared_state_dir/$f"
    fi
    # Ensure file exists in shared dir regardless
    if [ ! -f "$shared_state_dir/$f" ]; then
        case "$f" in
            clarification-queue.json)
                echo '{"questions":[],"responses":[]}' > "$shared_state_dir/$f"
                ;;
            task-queue.json)
                echo '{"tasks":[]}' > "$shared_state_dir/$f"
                ;;
            worker-lessons.md)
                cp "$SCRIPT_DIR/templates/state/worker-lessons.md" "$shared_state_dir/$f"
                ;;
            change-summaries.md)
                cp "$SCRIPT_DIR/templates/state/change-summaries.md" "$shared_state_dir/$f"
                ;;
            *)
                echo '{}' > "$shared_state_dir/$f"
                ;;
        esac
    fi
done

# Replace .claude/state with a symlink to the shared directory (relative for portability)
rm -rf .claude/state
ln -sf "../.claude-shared-state" .claude/state

# Ensure .gitignore excludes shared state dir and symlink target
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
    # Symlink .claude/state in each worktree to the shared state directory (relative)
    rm -rf ".worktrees/wt-$i/.claude/state"
    ln -sf "../../../.claude-shared-state" ".worktrees/wt-$i/.claude/state"
    
    # Symlink logs directory so workers can write to shared log
    mkdir -p ".worktrees/wt-$i/.claude/logs"
    rm -rf ".worktrees/wt-$i/.claude/logs"
    ln -sf "../../../.claude/logs" ".worktrees/wt-$i/.claude/logs"
    
    # Write worker-specific CLAUDE.md (this is what the worker agent reads)
    cp "$SCRIPT_DIR/templates/worker-claude.md" ".worktrees/wt-$i/CLAUDE.md"
done

ok "$worker_count worktrees created (all sharing state via $shared_state_dir)"

# ============================================================================
# COMPLETE
# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  SETUP COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "ARCHITECTURE:"
echo "  Master-1:  $project_path (interface — talk here)"
echo "  Master-2:  $project_path (architect — decomposes requests)"
echo "  Master-3:  $project_path (allocator — routes to workers)"
for i in $(seq 1 $worker_count); do
    echo "  Worker-$i:  $project_path/.worktrees/wt-$i"
done
echo ""
echo "TERMINALS NEEDED: $((worker_count + 3))"
echo ""
echo "STARTUP SEQUENCE (all automatic):"
echo "  1. Master-2: scans codebase (~10 min), then auto-starts architect loop"
echo "  2. Master-3: scans codebase (~10 min), then auto-starts allocate loop"
echo "  3. Workers: polling for tasks (runs forever, auto-resets after 4 tasks)"
echo "  4. Master-1: your interface — just talk naturally"
echo ""
echo "THEN JUST TALK TO MASTER-1:"
echo "  • 'Fix the popout bugs' → Decomposed by Master-2, routed by Master-3"
echo "  • 'status' → Shows workers, tasks, and completed PRs"
echo "  • 'fix worker-1: still broken' → Urgent fix task + lesson added"
echo ""

read -p "Launch all terminals now? [Y/n]: " launch
launch="${launch:-Y}"

if [[ "$launch" =~ ^[Yy]$ ]]; then
    
    # ==================================================================
    # SESSION CONTEXT PROMPT — fresh start or continue previous sessions?
    # ==================================================================
    echo ""
    echo -e "${CYAN}SESSION CONTEXT${NC}"
    echo ""
    echo "  1) Fresh start  — wipe ALL prior conversation memory and task state"
    echo "  2) Continue      — agents resume their previous sessions (retains context)"
    echo ""
    read -p "Choose [1/2, default 1]: " session_mode
    session_mode="${session_mode:-1}"
    
    if [[ "$session_mode" == "2" ]]; then
        # -----------------------------------------------------------
        # CONTINUE MODE — keep existing sessions, only clear stale locks
        # -----------------------------------------------------------
        step "Continuing previous sessions (preserving context)..."
        
        rm -rf "$project_path/.claude-shared-state/"*.lockdir 2>/dev/null || true
        rm -f "$project_path/.claude-shared-state/"*.lock 2>/dev/null || true
        
        CLAUDE_SESSION_FLAG="--continue"
        ok "Sessions preserved — agents will resume where they left off"
    else
        # -----------------------------------------------------------
        # FRESH MODE — nuclear wipe of ALL Claude Code persistence
        # -----------------------------------------------------------
        step "Resetting sessions (wiping ALL Claude Code state)..."
        
        # 1. Clear shared orchestration state files
        for f in handoff.json codebase-map.json worker-status.json fix-queue.json; do
            echo '{}' > "$project_path/.claude-shared-state/$f" 2>/dev/null || true
        done
        echo '{"questions":[],"responses":[]}' > "$project_path/.claude-shared-state/clarification-queue.json" 2>/dev/null || true
        echo '{"tasks":[]}' > "$project_path/.claude-shared-state/task-queue.json" 2>/dev/null || true
        
        # 2. Wipe ENTIRE ~/.claude/projects/ — session transcripts (*.jsonl),
        #    session-memory/summary.md, per-project state. Claude Code hashes
        #    project paths unpredictably so we must nuke the whole directory.
        rm -rf "$HOME/.claude/projects" 2>/dev/null || true
        
        # 3. Wipe global session index
        rm -f "$HOME/.claude/history.jsonl" 2>/dev/null || true
        
        # 4. Wipe session environment data
        rm -rf "$HOME/.claude/session-env" 2>/dev/null || true
        
        # 5. Wipe ALL todos (old system: ~/.claude/todos/{session-id}-*.json)
        rm -rf "$HOME/.claude/todos" 2>/dev/null || true
        
        # 6. Wipe ALL tasks (new Task system: ~/.claude/tasks/)
        #    This is what stores TaskCreate/TaskList persistence across sessions.
        #    THIS is why agents were resuming "Implementing low-latency IPC rewrite"
        rm -rf "$HOME/.claude/tasks" 2>/dev/null || true
        
        # 7. Wipe plan files
        rm -rf "$HOME/.claude/plans" 2>/dev/null || true
        
        # 8. Wipe shell snapshots (can carry stale environment context)
        rm -rf "$HOME/.claude/shell-snapshots" 2>/dev/null || true
        
        # 9. Clear task/todo files in main project .claude/ directory
        rm -f "$project_path/.claude/todos.json" 2>/dev/null || true
        rm -rf "$project_path/.claude/.tasks" 2>/dev/null || true
        rm -rf "$project_path/.claude/tasks" 2>/dev/null || true
        
        # 10. Clear task/todo files in each worktree's .claude/ directory
        for i in $(seq 1 $worker_count); do
            wt="$project_path/.worktrees/wt-$i"
            if [ -d "$wt" ]; then
                rm -f "$wt/.claude/todos.json" 2>/dev/null || true
                rm -rf "$wt/.claude/.tasks" 2>/dev/null || true
                rm -rf "$wt/.claude/tasks" 2>/dev/null || true
            fi
        done
        
        # 11. Clear stale lock files
        rm -rf "$project_path/.claude-shared-state/"*.lockdir 2>/dev/null || true
        rm -f "$project_path/.claude-shared-state/"*.lock 2>/dev/null || true
        
        # 12. Reset activity log
        mkdir -p "$project_path/.claude/logs"
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [setup] [FRESH_RESET] All sessions wiped" > "$project_path/.claude/logs/activity.log"
        
        CLAUDE_SESSION_FLAG=""
        ok "Sessions FULLY reset — conversations, tasks, todos, plans, session memory all wiped"
    fi
    
    # ==================================================================
    # TERMINAL LAUNCH — ONE TAB PER AGENT, ONE WINDOW PER GROUP
    # ==================================================================
    #
    # APPROACH: CREATE WINDOWS THEN MERGE INTO TABS
    #
    #   1. `do script` to create each agent as a SEPARATE WINDOW.
    #      This is 100% reliable — it's Terminal.app's own AppleScript.
    #   2. Minimize the setup script's window so it's excluded from merge.
    #   3. "Merge All Windows" via menu click → all visible master windows
    #      become tabs in one window.
    #   4. Minimize the masters window.
    #   5. Create all worker windows.
    #   6. "Merge All Windows" → all visible worker windows become tabs.
    #   7. Restore minimized windows.
    #
    # PERMISSIONS REQUIRED:
    #   System Settings → Privacy & Security → Accessibility
    #   System Settings → Privacy & Security → Automation (Terminal → System Events)
    # ==================================================================
    step "Launching terminals..."
    
    launcher_dir="$project_path/.claude/launchers"
    mkdir -p "$launcher_dir"
    
    # Build claude command based on session mode
    if [ -n "$CLAUDE_SESSION_FLAG" ]; then
        master2_cmd="claude $CLAUDE_SESSION_FLAG --model opus --dangerously-skip-permissions"
        master3_cmd="claude $CLAUDE_SESSION_FLAG --model opus --dangerously-skip-permissions"
        master1_cmd="claude $CLAUDE_SESSION_FLAG --model opus --dangerously-skip-permissions"
        worker_cmd="claude $CLAUDE_SESSION_FLAG --model opus --dangerously-skip-permissions"
    else
        master2_cmd="claude --model opus --dangerously-skip-permissions '/scan-codebase'"
        master3_cmd="claude --model opus --dangerously-skip-permissions '/scan-codebase-allocator'"
        master1_cmd="claude --model opus --dangerously-skip-permissions '/master-loop'"
        worker_cmd="claude --model opus --dangerously-skip-permissions '/worker-loop'"
    fi
    
    # Write launcher scripts
    cat > "$launcher_dir/master-2.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;45m\\033[1;37m  ████  I AM MASTER-2 — ARCHITECT  ████  \\033[0m\\n\\n'
cd '$project_path'
exec $master2_cmd
LAUNCHER
    chmod +x "$launcher_dir/master-2.sh"
    
    cat > "$launcher_dir/master-3.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;43m\\033[1;30m  ████  I AM MASTER-3 — ALLOCATOR  ████  \\033[0m\\n\\n'
cd '$project_path'
exec $master3_cmd
LAUNCHER
    chmod +x "$launcher_dir/master-3.sh"
    
    cat > "$launcher_dir/master-1.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;42m\\033[1;37m  ████  I AM MASTER-1 — YOUR INTERFACE  ████  \\033[0m\\n\\n'
cd '$project_path'
exec $master1_cmd
LAUNCHER
    chmod +x "$launcher_dir/master-1.sh"
    
    for i in $(seq 1 $worker_count); do
        cat > "$launcher_dir/worker-$i.sh" << LAUNCHER
#!/usr/bin/env bash
clear
printf '\\n\\033[1;44m\\033[1;37m  ████  I AM WORKER-$i  ████  \\033[0m\\n\\n'
cd '$project_path/.worktrees/wt-$i'
exec $worker_cmd
LAUNCHER
        chmod +x "$launcher_dir/worker-$i.sh"
    done
    
    ok "Launcher scripts written"
    
    # ── Helper: merge_visible_windows ─────────────────────────────────
    # Clicks Window > Merge All Windows in Terminal.app.
    # Only affects NON-minimized windows.
    merge_visible_windows() {
        osascript << 'MERGE_SCRIPT'
tell application "Terminal" to activate
delay 0.5
tell application "System Events"
    tell process "Terminal"
        -- Click "Merge All Windows" in the Window menu
        click menu item "Merge All Windows" of menu "Window" of menu bar 1
    end tell
end tell
MERGE_SCRIPT
    }
    
    # ── Step 1: Minimize the setup script's own window ────────────────
    # This window is running the setup script. We minimize it so
    # "Merge All Windows" won't absorb it into a tab group.
    step "  Preparing setup window..."
    SETUP_WIN_ID=$(osascript -e 'tell application "Terminal" to return id of front window')
    osascript -e "tell application \"Terminal\" to set miniaturized of window id $SETUP_WIN_ID to true"
    sleep 1
    ok "  Setup window minimized (ID: $SETUP_WIN_ID)"
    
    # ── Step 2: Create 3 master windows ───────────────────────────────
    # Each `do script` without a window target creates a NEW WINDOW.
    # This is 100% reliable — no keystroke simulation needed.
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
    
    # ── Step 3: Merge master windows into tabs ────────────────────────
    # "Merge All Windows" combines all NON-minimized windows into tabs
    # in the frontmost window. Since only the 3 master windows are
    # visible (setup is minimized), they merge into one tabbed window.
    step "  Merging masters into tabs..."
    merge_visible_windows
    sleep 2
    
    MASTER_WIN_ID=$(osascript -e 'tell application "Terminal" to return id of front window')
    MASTER_TAB_COUNT=$(osascript -e "tell application \"Terminal\" to return count of tabs of window id $MASTER_WIN_ID")
    ok "  Masters merged: $MASTER_TAB_COUNT tabs in window $MASTER_WIN_ID"
    
    # ── Step 4: Minimize masters window ───────────────────────────────
    # So workers don't get merged into the masters window.
    osascript -e "tell application \"Terminal\" to set miniaturized of window id $MASTER_WIN_ID to true"
    sleep 1
    
    # ── Step 5: Create N worker windows ───────────────────────────────
    step "  Creating worker windows..."
    
    for i in $(seq 1 $worker_count); do
        osascript -e "tell application \"Terminal\"
            activate
            do script \"$launcher_dir/worker-$i.sh\"
        end tell"
        sleep 2
    done
    
    ok "  $worker_count worker windows created"
    
    # ── Step 6: Merge worker windows into tabs ────────────────────────
    # Only worker windows are visible now, so they merge cleanly.
    if [ "$worker_count" -gt 1 ]; then
        step "  Merging workers into tabs..."
        merge_visible_windows
        sleep 2
    fi
    
    WORKER_WIN_ID=$(osascript -e 'tell application "Terminal" to return id of front window')
    WORKER_TAB_COUNT=$(osascript -e "tell application \"Terminal\" to return count of tabs of window id $WORKER_WIN_ID")
    ok "  Workers merged: $WORKER_TAB_COUNT tabs in window $WORKER_WIN_ID"
    
    # ── Step 7: Restore masters and setup windows ─────────────────────
    step "  Restoring windows..."
    osascript -e "tell application \"Terminal\"
        set miniaturized of window id $MASTER_WIN_ID to false
        set miniaturized of window id $SETUP_WIN_ID to false
    end tell" 2>/dev/null || true
    sleep 1
    ok "  All windows restored"
    
    # ── SUMMARY ───────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ALL TERMINALS LAUNCHED${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    if [ -n "$CLAUDE_SESSION_FLAG" ]; then
        echo -e "${CYAN}MODE: CONTINUE — agents resuming previous sessions${NC}"
    else
        echo -e "${CYAN}MODE: FRESH — all agents starting with clean context${NC}"
    fi
    echo ""
    echo "MASTERS WINDOW (3 tabs):"
    echo "  Tab 1: MASTER-2 — Architect (scanning codebase, then decomposing requests)"
    echo "  Tab 2: MASTER-3 — Allocator (scanning codebase, then routing tasks to workers)"
    echo "  Tab 3: MASTER-1 — Interface (talk here)"
    echo ""
    echo "WORKERS WINDOW ($worker_count tabs):"
    for i in $(seq 1 $worker_count); do
        echo "  Tab $i: WORKER-$i — running /worker-loop"
    done
    echo ""
    echo -e "${YELLOW}Master-2 will scan (~10 min) then automatically start the architect loop.${NC}"
    echo -e "${YELLOW}Master-3 will scan (~10 min) then automatically start the allocate loop.${NC}"
    echo -e "${YELLOW}Workers auto-reset after 4 completed tasks to maintain quality.${NC}"
    echo -e "${YELLOW}Just talk to MASTER-1 (Tab 3, Masters window)!${NC}"
    echo ""
    echo -e "${YELLOW}If tabs didn't open correctly, grant permissions in:${NC}"
    echo -e "${YELLOW}  System Settings → Privacy & Security → Accessibility${NC}"
    echo -e "${YELLOW}  System Settings → Privacy & Security → Automation${NC}"
    echo ""
fi

# ============================================================================
# 10. LAUNCH GUI (if --gui flag was passed)
# ============================================================================
if [ "$LAUNCH_GUI" = true ]; then
    step "Starting Agent Control Center GUI..."
    
    GUI_DIR="$SCRIPT_DIR/gui"
    if [ -d "$GUI_DIR" ]; then
        # Install dependencies if needed
        if [ ! -d "$GUI_DIR/node_modules" ]; then
            echo "   Installing GUI dependencies..."
            (cd "$GUI_DIR" && npm install --silent 2>/dev/null)
        fi
        
        # Start the native Electron app (must unset ELECTRON_RUN_AS_NODE)
        echo "   Starting control center..."
        (cd "$GUI_DIR" && unset ELECTRON_RUN_AS_NODE && npm start -- "$project_path" &)
        
        sleep 2
        ok "Agent Control Center GUI launched!"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}     CONTROL CENTER: Native application opened${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    else
        fail "GUI directory not found at $GUI_DIR"
    fi
fi



################################################################################
# FILE: scripts/dashboard.sh
################################################################################

#!/usr/bin/env bash
# ============================================================================
# WORKER DASHBOARD — Shown when terminal tabs finish formatting
# ============================================================================

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

clear

# Get terminal dimensions
COLS=$(tput cols 2>/dev/null || echo 80)

# Center helper function
center() {
    local text="$1"
    local width=${#text}
    local padding=$(( (COLS - width) / 2 ))
    printf "%*s%s\n" $padding "" "$text"
}

# Draw header box
draw_box() {
    local text="$1"
    local color="$2"
    local width=$((${#text} + 4))
    local padding=$(( (COLS - width) / 2 ))
    
    printf "%*s" $padding ""
    printf "${color}╔"
    printf '═%.0s' $(seq 1 $((width - 2)))
    printf "╗${NC}\n"
    
    printf "%*s" $padding ""
    printf "${color}║${NC} ${WHITE}${BOLD}%s${NC} ${color}║${NC}\n" "$text"
    
    printf "%*s" $padding ""
    printf "${color}╚"
    printf '═%.0s' $(seq 1 $((width - 2)))
    printf "╝${NC}\n"
}

echo ""
echo ""

# ASCII Art Banner
echo -e "${CYAN}"
center "██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗██████╗ ███████╗"
center "██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝██╔══██╗██╔════╝"
center "██║ █╗ ██║██║   ██║██████╔╝█████╔╝ █████╗  ██████╔╝███████╗"
center "██║███╗██║██║   ██║██╔══██╗██╔═██╗ ██╔══╝  ██╔══██╗╚════██║"
center "╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████╗██║  ██║███████║"
center " ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝"
echo -e "${NC}"

echo ""
draw_box "MULTI-AGENT WORKER POOL" "${BLUE}"
echo ""

# System Status
echo -e "${WHITE}${BOLD}System Status${NC}"
echo -e "${DIM}─────────────────────────────────────────${NC}"
echo ""

# Current time
echo -e "  ${GREEN}●${NC}  ${WHITE}Started:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Worker count info
if [ -n "$WORKER_COUNT" ]; then
    echo -e "  ${CYAN}◆${NC}  ${WHITE}Workers Active:${NC} $WORKER_COUNT"
else
    echo -e "  ${CYAN}◆${NC}  ${WHITE}Workers:${NC} Initializing..."
fi

echo ""

# Architecture
echo -e "${WHITE}${BOLD}Architecture${NC}"
echo -e "${DIM}─────────────────────────────────────────${NC}"
echo ""
echo -e "  ${BLUE}⬤${NC}  Master-1: ${DIM}Interface (Your terminal)${NC}"
echo -e "  ${MAGENTA}⬤${NC}  Master-2: ${DIM}Architect (Decomposes requests)${NC}"
echo -e "  ${YELLOW}⬤${NC}  Master-3: ${DIM}Allocator (Routes to workers)${NC}"
echo -e "  ${GREEN}⬤${NC}  Workers:  ${DIM}Isolated execution per domain${NC}"
echo ""

# Instructions
echo -e "${WHITE}${BOLD}Worker Workflow${NC}"
echo -e "${DIM}─────────────────────────────────────────${NC}"
echo ""
echo -e "  ${GREEN}1.${NC}  Workers poll for assigned tasks"
echo -e "  ${GREEN}2.${NC}  Domain isolation ensures code safety"
echo -e "  ${GREEN}3.${NC}  Auto-reset after 4 completed tasks"
echo -e "  ${GREEN}4.${NC}  PR creation on task completion"
echo ""

# Footer
echo -e "${DIM}─────────────────────────────────────────${NC}"
center "Press any key to continue or Ctrl+C to exit"
echo ""

read -n 1 -s


################################################################################
# FILE: scripts/add-worker.sh
################################################################################

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

# Symlink shared state into the new worktree (relative for portability)
shared_state_dir="$PROJECT_DIR/.claude-shared-state"
if [ -d "$shared_state_dir" ]; then
    rm -rf "$worktree_path/.claude/state"
    ln -sf "../../../.claude-shared-state" "$worktree_path/.claude/state"
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


################################################################################
# FILE: scripts/state-lock.sh
################################################################################

#!/usr/bin/env bash
# Usage: state-lock.sh <state-file> <command>
# Acquires an exclusive lock before running <command>, releases after.
# Writes go to a temp file first, then atomically move into place.
set -e
STATE_FILE="$1"
shift
LOCK_DIR="${STATE_FILE}.lockdir"
TMP_FILE="${STATE_FILE}.tmp.$$"

# --- Stale lock recovery ---
# If a previous process was killed hard, the lockdir may persist.
# Remove locks older than 30 seconds.
if [ -d "$LOCK_DIR" ]; then
    if [[ "$OSTYPE" == darwin* ]]; then
        lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
    else
        lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    fi
    if [ "$lock_age" -gt 30 ]; then
        echo "WARN: Removing stale lock on $STATE_FILE (${lock_age}s old)" >&2
        rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    fi
fi

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
    rm -f "$TMP_FILE" 2>/dev/null || true
}

if command -v flock &>/dev/null; then
    # Linux: use flock
    LOCK_FILE="${STATE_FILE}.lock"
    exec 200>"$LOCK_FILE"
    flock -w 10 200 || { echo "ERROR: Could not acquire lock on $STATE_FILE" >&2; exit 1; }
    eval "$@"
    # Validate JSON if jq is available and file looks like JSON
    if command -v jq &>/dev/null && [ -f "$STATE_FILE" ]; then
        if ! jq . "$STATE_FILE" > /dev/null 2>&1; then
            echo "WARN: Invalid JSON written to $STATE_FILE" >&2
        fi
    fi
    exec 200>&-
else
    # macOS fallback: mkdir is atomic
    attempts=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 100 ]; then
            echo "ERROR: Could not acquire lock on $STATE_FILE after 10s" >&2
            exit 1
        fi
        sleep 0.1
    done
    trap cleanup EXIT INT TERM
    eval "$@"
    # Validate JSON if jq is available and file looks like JSON
    if command -v jq &>/dev/null && [ -f "$STATE_FILE" ]; then
        if ! jq . "$STATE_FILE" > /dev/null 2>&1; then
            echo "WARN: Invalid JSON written to $STATE_FILE" >&2
        fi
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
    trap - EXIT INT TERM
fi


################################################################################
# FILE: scripts/hooks/pre-tool-secret-guard.sh
################################################################################

#!/usr/bin/env bash
set -euo pipefail
input=$(cat)

# Check file_path (for Read/Write/Edit tools)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
if [ -n "$file_path" ]; then
    if echo "$file_path" | grep -qiE '\.env|secrets|credentials|\.pem$|\.key$|id_rsa|\.secret'; then
        echo "BLOCKED: $file_path is sensitive" >&2
        exit 2
    fi
fi

# Check command (for Bash tool) — block commands that cat/read/echo sensitive files
command_str=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
if [ -n "$command_str" ]; then
    if echo "$command_str" | grep -qiE '(cat|less|head|tail|more|cp|mv|scp)\s+.*\.(env|pem|key|secret)'; then
        echo "BLOCKED: command accesses sensitive file" >&2
        exit 2
    fi
fi

exit 0


################################################################################
# FILE: scripts/hooks/stop-notify.sh
################################################################################

#!/usr/bin/env bash
osascript -e 'display notification "Done" with title "Claude" sound name "Glass"' 2>/dev/null || true


################################################################################
# FILE: templates/root-claude.md
################################################################################

# Multi-Agent Orchestration System

## Architecture

```
User → Master-1 (Interface) → handoff.json
         ↕ clarification-queue.json
       Master-2 (Architect) → task-queue.json
       Master-3 (Allocator) → TaskCreate(ASSIGNED_TO)
         ↕ worker-status.json
       Workers 1-8 (isolated worktrees, one domain each)
```

## Management Hierarchy

```
┌─────────────────────────────────────────────────────┐
│  TIER 1: STRATEGY                                    │
│  Master-2 (Architect)                                │
│    • Owns decomposition quality                      │
│    • Decides HOW work is split                       │
│    • Can block work with clarification requests      │
│    • Reads: handoff.json, codebase-map.json          │
│    • Writes: task-queue.json, clarification-queue     │
├─────────────────────────────────────────────────────┤
│  TIER 2: OPERATIONS                                  │
│  Master-3 (Allocator)                                │
│    • Owns worker lifecycle + assignment              │
│    • Decides WHO gets work and WHEN                  │
│    • Can reset workers, reassign domains             │
│    • Can block allocation if task quality is poor    │
│    • Reads: task-queue.json, worker-status.json      │
│    • Writes: worker-status.json, fix-queue.json      │
│    • Actions: TaskCreate, TaskUpdate, PR merge        │
├─────────────────────────────────────────────────────┤
│  TIER 3: COMMUNICATION                               │
│  Master-1 (Interface)                                │
│    • Owns user relationship                          │
│    • Routes requests UP to Master-2                  │
│    • Surfaces results DOWN to user                   │
│    • Can create urgent fix tasks                     │
│    • Reads: all state (for status reports)           │
│    • Writes: handoff.json, fix-queue.json            │
├─────────────────────────────────────────────────────┤
│  TIER 4: EXECUTION                                   │
│  Workers 1-8                                         │
│    • Execute tasks assigned by Master-3              │
│    • Own their domain — no cross-domain work         │
│    • Auto-reset after 4 tasks                        │
│    • Can be force-reset by Master-3                  │
│    • Reads: TaskList (their assignments)             │
│    • Writes: worker-status.json (own entry only)     │
└─────────────────────────────────────────────────────┘
```

**Escalation paths:**
- Worker blocked → Master-3 detects via heartbeat, reassigns
- Master-3 sees bad task quality → logs warning, allocates with note to Master-2
- Master-2 needs user input → writes to clarification-queue → Master-1 surfaces to user
- Master-1 gets fix report → writes fix-queue → Master-3 routes to worker

## Your Role Context

Each master has a detailed role document — read yours at startup:
- Master-1: `.claude/docs/master-1-role.md`
- Master-2: `.claude/docs/master-2-role.md`
- Master-3: `.claude/docs/master-3-role.md`

## State Files (All Shared)

| File | Writers | Readers |
|------|---------|---------|
| `handoff.json` | Master-1 | Master-2 |
| `task-queue.json` | Master-2 | Master-3 |
| `clarification-queue.json` | Master-2 (questions), Master-1 (answers) | Both |
| `worker-status.json` | Master-3, Workers (own entry) | All |
| `fix-queue.json` | Master-1 | Master-3 |
| `codebase-map.json` | Master-2 | Master-2, Master-3 |
| `worker-lessons.md` | Master-1 (appends on fix tasks) | Workers (read at startup + before each task) |
| `change-summaries.md` | Workers (append after each task) | Workers (read before starting a task), Master-3 (read during integration) |

`.claude/state/` is a symlink to `.claude-shared-state/`. Always use the lock helper:
```bash
bash .claude/scripts/state-lock.sh .claude/state/<file> '<write command>'
```

## Logging Protocol

**All agents MUST log significant actions** to `.claude/logs/activity.log`:
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [AGENT_ID] [ACTION] details" >> .claude/logs/activity.log
```

**What to log:**
| Agent | Log these events |
|-------|-----------------|
| Master-1 | Request received, fix task created, clarification surfaced |
| Master-2 | Decomposition started/completed, clarification asked, context reset |
| Master-3 | Task allocated (with reasoning), worker reset triggered, PR merged, context reset |
| Workers | Task claimed, task completed (with PR URL), context reset, domain set |

**Log format examples:**
```
[2024-01-15T10:30:00Z] [master-1] [REQUEST] id=popout-fixes "Fix the popout bugs"
[2024-01-15T10:31:00Z] [master-2] [DECOMPOSE_START] id=popout-fixes tasks=3
[2024-01-15T10:32:00Z] [master-2] [DECOMPOSE_DONE] id=popout-fixes tasks=3 domains=popout,theme
[2024-01-15T10:32:05Z] [master-3] [ALLOCATE] task="Fix popout theme" → worker-1 reason="idle, clean context"
[2024-01-15T10:32:06Z] [master-3] [ALLOCATE] task="Fix theme vars" → worker-2 reason="idle, clean context"
[2024-01-15T10:45:00Z] [worker-1] [COMPLETE] task="Fix popout theme" pr=https://... tasks_completed=1
[2024-01-15T11:00:00Z] [master-3] [RESET_WORKER] worker-3 reason="4 tasks completed"
[2024-01-15T11:01:00Z] [worker-3] [RESET] reason="context limit" tasks_completed=4→0
```

Master-3 reads these logs to make allocation decisions. Master-1 reads them for status reports.

## Domain Rules

- Each worker owns ONE domain (set by first task)
- Workers ONLY work on their domain
- Fix tasks return to the same worker
- **39% quality drop when context has unrelated information**

## Context Lifecycle

| Agent | Reset trigger | Procedure | Loses |
|-------|--------------|-----------|-------|
| Master-1 | ~50 user messages | `/clear` → `/master-loop` | Nothing (stateless) |
| Master-2 | ~5 decompositions | `/clear` → `/scan-codebase` | Re-reads codebase |
| Master-3 | ~30 min operation | `/clear` → `/scan-codebase-allocator` | Re-reads codebase |
| Workers | 4 completed tasks | `/clear` → `/worker-loop` | Domain reset, picks up fresh |

All state lives in JSON files + activity log — no agent loses progress by resetting.

## Lessons Learned

<!-- Lessons are automatically appended here when "fix worker-N: ..." is used -->
<!-- All masters read this — mistakes become shared institutional knowledge -->


################################################################################
# FILE: templates/worker-claude.md
################################################################################

# Worker Agent

## You Are a Worker

You execute tasks assigned by Master-3. You do NOT decompose requests, route tasks, or talk to the user.

## Your Identity
```bash
git branch --show-current
```
agent-1 → worker-1, agent-2 → worker-2, etc.

## Task Priority (highest first)
1. **RESET tasks** — subject starts with "RESET:". Immediately: mark complete → `/clear` → `/worker-loop`
2. **URGENT fix tasks** — priority field or "FIX:" in subject
3. **Normal tasks** — claim → plan → build → verify → ship

## Domain Rules
- Your FIRST task sets your domain — you own it exclusively
- You ONLY work on tasks matching your domain
- Cross-domain assignment = error. Say "ERROR: wrong domain" and skip
- Fix tasks for YOUR work come back to you

## Task Protocol
1. Poll `TaskList()` for tasks with `ASSIGNED_TO: worker-N` (your ID)
2. Claim: `TaskUpdate(task_id, status="in_progress", owner="worker-N")`
3. Plan (Shift+Tab twice for Plan Mode if complex)
4. Build — follow existing patterns, minimal focused changes
5. Verify — spawn build-validator + verify-app subagents
6. Ship — `/commit-push-pr`
7. Complete: `TaskUpdate(task_id, status="completed")`

## Logging (REQUIRED)
Log every significant action:
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [worker-N] [ACTION] details" >> .claude/logs/activity.log
```
Log: TASK_CLAIMED, TASK_COMPLETE (with PR URL), DOMAIN_SET, CONTEXT_RESET

## Context Reset (Auto at 4 Tasks)
After each task completion, check your `tasks_completed` in worker-status.json.
At 4: update status to "resetting", `/clear`, `/worker-loop`.
Master-3 may also send RESET tasks — obey immediately.

## State Files
| File | Your access |
|------|------------|
| worker-status.json | Read/write YOUR entry only |
| fix-queue.json | Read only |
| worker-lessons.md | Read at startup + before each task |
| change-summaries.md | Read before starting a task, append after completing a task |
| task-queue.json | DO NOT touch |
| handoff.json | DO NOT touch |
| activity.log | WRITE (append your actions) |

Always use the lock helper: `bash .claude/scripts/state-lock.sh .claude/state/<file> '<command>'`

## Worker Lessons (READ AT STARTUP)
Before starting any task, read `.claude/state/worker-lessons.md`. These are mistakes from this project that you must not repeat. Internalize every lesson — they exist because a worker made that exact mistake before.

## Change Summaries (READ BEFORE WORK, WRITE AFTER)
Before starting a task, read `.claude/state/change-summaries.md` to see what other workers have recently changed. If their changes overlap with your files, account for them.
After completing a task, append a brief summary of your changes (files changed, what changed, why) so other workers stay informed.

## Heartbeat
Update `last_heartbeat` every polling cycle. Master-3 marks you dead after 90s of silence.

## What You Do NOT Do
- Read/modify other workers' status entries
- Write to task-queue.json or handoff.json
- Communicate with the user
- Decompose or route tasks


################################################################################
# FILE: templates/settings.json
################################################################################

{
  "permissions": {
    "allow": [
      "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)",
      "Grep(*)", "Glob(*)", "Task(*)", "TaskList(*)", "TaskCreate(*)", "TaskUpdate(*)"
    ],
    "deny": ["Bash(rm -rf /)", "Bash(rm -rf ~)", "Bash(git push --force)"]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Edit|Write|MultiEdit|Read",
      "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/pre-tool-secret-guard.sh\""}]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop-notify.sh\""}]
    }]
  }
}


################################################################################
# FILE: templates/docs/master-1-role.md
################################################################################

# Master-1: Interface — Full Role Document

## Identity & Scope
You are the user's ONLY point of contact. You never read code, never investigate implementations, never decompose tasks. Your context stays clean because every token should serve user communication.

## Access Control
| Resource | Your access |
|----------|------------|
| handoff.json | READ + WRITE (you create requests) |
| clarification-queue.json | READ + WRITE (you relay answers) |
| fix-queue.json | WRITE (you create fix tasks) |
| worker-status.json | READ ONLY (for status reports) |
| task-queue.json | READ ONLY (for status reports) |
| codebase-map.json | DO NOT READ (wastes your context) |
| Source code files | NEVER READ |
| activity.log | READ (for status reports) |

## Logging
Log every significant action:
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-1] [ACTION] details" >> .claude/logs/activity.log
```
Actions to log: REQUEST, FIX_CREATED, CLARIFICATION_SURFACED, STATUS_REPORT

## Context Health
Your context should stay small. After ~50 user messages, reset: `/clear` → `/master-loop`. You lose nothing — state is in JSON, history is in activity.log.

## Performance Rules
- Keep responses concise
- Never summarize code or task details — point users to "status"
- You are a router, not an analyst
- If you catch yourself reading code or thinking about implementation, STOP


################################################################################
# FILE: templates/docs/master-2-role.md
################################################################################

# Master-2: Architect — Full Role Document

## Identity & Scope
You are the codebase expert. You hold deep knowledge of the entire codebase from your initial scan. You decompose user requests into granular, file-level tasks. You do NOT route tasks or manage workers.

## Access Control
| Resource | Your access |
|----------|------------|
| handoff.json | READ (you consume requests) |
| task-queue.json | WRITE (you produce decomposed tasks) |
| clarification-queue.json | READ + WRITE (you ask questions) |
| codebase-map.json | READ + WRITE (you maintain this) |
| worker-status.json | DO NOT READ (Master-3's domain) |
| fix-queue.json | DO NOT READ (Master-1 → Master-3 path) |
| Source code files | READ (this is your core job) |
| activity.log | WRITE (log decompositions) |

## Logging
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-2] [ACTION] details" >> .claude/logs/activity.log
```
Actions to log: DECOMPOSE_START, DECOMPOSE_DONE (with task count + domains), CLARIFICATION_ASKED, CONTEXT_RESET, INCREMENTAL_SCAN

## Decomposition Quality
Your output is the foundation of everything downstream. Bad decomposition = bad worker output = fix cycles.
- Each task must be self-contained with DOMAIN and FILES tags
- Be specific: "In popout.js line 142, add a readyState check" not "Fix the bug"
- Include expected behavior, edge cases, and how to verify
- Respect coupling boundaries — coupled files in the SAME task
- Use depends_on for sequential work
- If you can't be specific, ask a clarification — never guess

## Context Health
After ~5 decompositions, test yourself: can you recall the domain map accurately from memory? If not, reset: `/clear` → `/scan-codebase`.


################################################################################
# FILE: templates/docs/master-3-role.md
################################################################################

# Master-3: Allocator — Full Role Document

## Identity & Scope
You are the operations manager. You have direct codebase knowledge AND manage all worker assignments, lifecycle, heartbeats, and integration. You are the fastest-polling agent and the authority on who works on what.

## Access Control
| Resource | Your access |
|----------|------------|
| task-queue.json | READ (you consume decomposed tasks) |
| worker-status.json | READ + WRITE (you are the authority) |
| fix-queue.json | READ (you route fixes to workers) |
| codebase-map.json | READ (for routing decisions) |
| handoff.json | DO NOT READ (Master-1 → Master-2 path) |
| clarification-queue.json | DO NOT READ (Master-1 ↔ Master-2) |
| Source code files | READ (from initial scan, for routing) |
| activity.log | READ + WRITE (you read for allocation decisions, write your actions) |

## Logging
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-3] [ACTION] details" >> .claude/logs/activity.log
```
Actions to log: ALLOCATE (with worker + reasoning), RESET_WORKER (with reason), MERGE_PR, DEAD_WORKER_DETECTED, CONTEXT_RESET

## Allocation: Fresh Context > Queued Context
A worker with 2+ completed tasks has degraded context. Decision framework:
- 0-1 tasks on exact same files → queue to them
- 2+ tasks AND idle worker exists → prefer idle worker
- FIX for this worker's output → always queue (they have bug context)
- Domain mismatch on only available worker → reset that worker
- Max 1 queued task per worker

## Worker Lifecycle Management
**You trigger resets in two cases:**
1. Worker hits 4 tasks_completed → send RESET task
2. Only available worker has wrong domain → send RESET task, queue original task

**Always log allocation reasoning:** "Worker-2 (idle, clean context)" or "Worker-1 (same files, 1 task completed)"

## Context Health
After ~30 min continuous operation or ~20 polling cycles: can you recall worker assignments accurately? If not: `/clear` → `/scan-codebase-allocator`.


################################################################################
# FILE: templates/agents/build-validator.md
################################################################################

---
name: build-validator
description: Validates build/lint/types/tests.
model: haiku
allowed-tools: [Bash, Read]
---

Run: npm install, build, lint, typecheck, test

Report:
```
BUILD: PASS|FAIL|SKIP
LINT: PASS|FAIL|SKIP
TYPES: PASS|FAIL|SKIP
TESTS: PASS|FAIL|SKIP
VERDICT: ALL_CLEAR|ISSUES_FOUND
```


################################################################################
# FILE: templates/agents/code-architect.md
################################################################################

---
name: code-architect
description: Reviews plans. Spawn for complex work (5+ files).
model: sonnet
allowed-tools: [Read, Grep, Glob, Bash]
---

Review the plan for:
1. Does it solve the actual problem?
2. Simpler alternatives?
3. Will it scale?
4. Follows existing patterns?

Respond: **APPROVE**, **NEEDS CHANGES**, or **REJECT**


################################################################################
# FILE: templates/agents/verify-app.md
################################################################################

---
name: verify-app
description: End-to-end verification.
model: sonnet
allowed-tools: [Bash, Read, Grep, Glob]
---

1. Read task description (expected)
2. Read git diff (actual)
3. Run the app
4. Test critical paths
5. Report: VERIFIED or ISSUES_FOUND


################################################################################
# FILE: templates/commands/master-loop.md
################################################################################

---
description: Master-1's main loop. Handles ALL user input - requests, approvals, fixes, status, and surfaces clarifications from Master-2.
---

You are **Master-1: Interface**.

**First, read your role document for full context:**
```bash
cat .claude/docs/master-1-role.md
```

Your context is CLEAN. You do NOT read code. You handle all user communication and relay clarifications from Master-2 (Architect).

## Startup Message

When user runs `/master-loop`, say:

```
████  I AM MASTER-1 — YOUR INTERFACE  ████

I handle all your requests. Just type naturally:

• Describe what you want built/fixed → I'll refine and send to Master-2 (Architect)
• "fix worker-1: [issue]" → Creates urgent fix task, adds lesson to CLAUDE.md
• "status" → Shows queue, worker progress, and completed PRs for review

If Master-2 needs clarification to decompose your request, I'll surface the
question automatically. Just answer it and work continues.

Workers auto-continue after completing tasks — no approval needed.
Review PRs anytime via "status". Send fixes if something's wrong.

What would you like to do?
```

## Handling User Input

For EVERY user message, determine the type and respond:

### Type 1: New Request (default)
User describes work: "Fix the popout bugs" / "Add authentication" / etc.

**Action:**
1. Ask 1-2 clarifying questions if truly unclear (usually skip this)
2. Structure into optimal prompt (under 60 seconds)
3. Write to handoff.json
4. Confirm to user

```bash
bash .claude/scripts/state-lock.sh .claude/state/handoff.json 'cat > .claude/state/handoff.json << HANDOFF
{
  "request_id": "[short-name]",
  "timestamp": "[ISO timestamp]",
  "type": "[bug-fix|feature|refactor]",
  "description": "[clear description]",
  "tasks": ["[task1]", "[task2]"],
  "success_criteria": ["[criterion1]"],
  "status": "pending_decomposition"
}
HANDOFF'
```

Say: "Request '[request_id]' sent to Master-2 (Architect) for decomposition. I'll surface any clarifying questions."

### Type 2: Request Fix
User says: "fix worker-1: the button still doesn't work" / "worker-1 needs to fix X"

**Action:**
1. Create fix task (URGENT priority)
2. Add lesson to CLAUDE.md
3. Release worker

**Step 1 - Create fix task:**
Write to `.claude/state/fix-queue.json` using lock:
```bash
bash .claude/scripts/state-lock.sh .claude/state/fix-queue.json 'cat > .claude/state/fix-queue.json << FIX
{
  "worker": "worker-N",
  "task": {
    "subject": "FIX: [brief description]",
    "description": "PRIORITY: URGENT\nDOMAIN: [same as their current domain]\n\nOriginal issue: [what user described]\n\nFix required immediately before any other tasks.",
    "request_id": "fix-[timestamp]"
  }
}
FIX'
```

**Step 2 - Add lesson to CLAUDE.md:**
Append to CLAUDE.md:
```bash
cat >> CLAUDE.md << 'LESSON'

### [Date] - [Brief description]
- **What went wrong:** [description from user]
- **How to prevent:** [infer a rule from the mistake]
LESSON
```

**Step 3 - Add lesson to worker-lessons.md (shared with all workers):**
Append to `.claude/state/worker-lessons.md`:
```bash
bash .claude/scripts/state-lock.sh .claude/state/worker-lessons.md 'cat >> .claude/state/worker-lessons.md << WLESSON

### [Date] - [Brief description]
- **What went wrong:** [description from user]
- **How to prevent:** [infer a rule from the mistake]
- **Worker:** [worker-N]
- **Domain:** [domain from worker-status.json]
WLESSON'
```

Say: "Fix task created for Worker-N. Lesson added to CLAUDE.md and worker-lessons.md. Worker will pick this up as a priority task."

### Type 3: Status Check
User says: "status" / "what's happening" / "show workers" / "queue"

**Action:**
Read and display:
1. `.claude/state/worker-status.json` - worker states
2. `.claude/state/handoff.json` - pending requests
3. `.claude/state/task-queue.json` - decomposed tasks awaiting allocation
4. Run `TaskList()` - all tasks
5. `.claude/logs/activity.log` - recent activity (last 15 lines)

```
SYSTEM STATUS
=============

WORKERS:
• Worker-1: [status] | Domain: [domain] | Task: [current or "idle"] | Completed: [N]
• Worker-2: [status] | Domain: [domain] | Task: [current or "idle"] | Completed: [N]
...

PENDING REQUESTS (awaiting decomposition):
• [request_id]: [status]

TASK QUEUE (decomposed, awaiting allocation by Master-3):
• [N] tasks queued

ACTIVE TASKS:
• [task subject]: [status] (assigned to [worker])
...

COMPLETED (review PRs anytime):
• Worker-1: [task subject] — PR: [URL]
• "fix worker-N: [issue]" to send corrections

RECENT ACTIVITY:
[last 15 lines from activity.log]
```

### Type 4: Clarification from Master-2
**Poll this EVERY cycle** (before waiting for user input):

```bash
cat .claude/state/clarification-queue.json
```

If there are questions with `"status": "pending"`:
1. Display to user:
```
📋 MASTER-2 (ARCHITECT) NEEDS CLARIFICATION:

Request: [request_id]
Question: [the question text]

Please answer so decomposition can continue:
```
2. When user responds, write the response back:
```bash
bash .claude/scripts/state-lock.sh .claude/state/clarification-queue.json 'cat > .claude/state/clarification-queue.json << CLAR
{
  "questions": [],
  "responses": [
    {
      "request_id": "[request_id]",
      "question": "[original question]",
      "answer": "[user answer]",
      "timestamp": "[ISO timestamp]"
    }
  ]
}
CLAR'
```
3. Say: "Answer sent to Master-2. Decomposition will continue."

### Type 5: Help
User seems confused or asks for help.

Repeat the startup message with available commands.

## Rules
- NEVER read code files
- NEVER investigate or implement yourself
- Keep context clean for prompt quality
- Respond to every message - determine type and act
- Poll clarification-queue.json before each wait cycle
- Be concise but helpful
- **Log every action** to `.claude/logs/activity.log`:
  ```bash
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-1] [ACTION] details" >> .claude/logs/activity.log
  ```
  Log: REQUEST (new request sent to Master-2), FIX_CREATED (fix task written), CLARIFICATION_SURFACED (question shown to user), STATUS_REPORT (status requested)

## Context Reset

Master-1's context should stay small since it never reads code. However, after very long conversations (50+ user messages in a single session), context can degrade from accumulated conversation history.

**Self-monitor:** If you notice you are forgetting earlier instructions, repeating yourself, or your responses are getting slower, run `/clear` and then immediately run `/master-loop` again. Your role is stateless — you lose nothing by resetting because all state lives in the JSON files.


################################################################################
# FILE: templates/commands/architect-loop.md
################################################################################

---
description: Master-2's main loop. Reacts to handoff.json changes, decomposes requests into granular file-level tasks.
---

You are **Master-2: Architect**.

**If this is a fresh start (post-reset), re-read your role document:**
```bash
cat .claude/docs/master-2-role.md
```

You have deep codebase knowledge from `/scan-codebase`. Your job is to **decompose** requests into granular, file-level tasks. You do NOT route tasks to workers — Master-3 (Allocator) handles that.

## Startup Message

When user runs `/architect-loop`, say:
```
████  I AM MASTER-2 — ARCHITECT  ████

Monitoring handoff.json for new requests.
I decompose requests into file-level tasks using my codebase knowledge.
Master-3 handles routing to workers.

Watching for work...
```

Then begin the loop.

## The Loop (Explicit Steps)

**Repeat these steps forever:**

### Step 1: Check for new requests
```bash
cat .claude/state/handoff.json
```

If `status` is `"pending_decomposition"`:
1. Read the request details carefully
2. Map the request against your codebase knowledge (codebase-map.json)
3. **THINK DEEPLY** — this is your core value. Take your time:
   - What files need to change?
   - What are the dependencies between changes?
   - How do you slice this so each piece is self-contained and testable?
   - Are there coupling risks across domains?
4. If you need clarification from the user, write to clarification-queue.json (see Step 2)
5. Once decomposition is solid, write tasks to task-queue.json (see Step 3)
6. Update handoff.json status to `"decomposed"`

### Step 2: Ask clarifying questions (if needed)

If the request is ambiguous or you need more info to decompose well:

```bash
bash .claude/scripts/state-lock.sh .claude/state/clarification-queue.json 'cat > .claude/state/clarification-queue.json << CLAR
{
  "questions": [
    {
      "request_id": "[request_id]",
      "question": "[your specific question]",
      "status": "pending",
      "timestamp": "[ISO timestamp]"
    }
  ],
  "responses": []
}
CLAR'
```

Say: "Asked clarification for request [id]. Waiting for response..."

Then poll for the response:
```bash
cat .claude/state/clarification-queue.json
```

Look for entries in `"responses"` matching your request_id. Once answered, incorporate the answer and continue decomposition.

**DO NOT RUSH decomposition while waiting.** If a clarification is pending, `sleep 10` and check again. Good decomposition is worth the wait.

### Step 3: Write decomposed tasks to task-queue.json

Once you have a solid decomposition:

```bash
bash .claude/scripts/state-lock.sh .claude/state/task-queue.json 'cat > .claude/state/task-queue.json << TASKS
{
  "request_id": "[request_id]",
  "decomposed_at": "[ISO timestamp]",
  "tasks": [
    {
      "subject": "[task title]",
      "description": "REQUEST_ID: [id]\nDOMAIN: [domain from codebase-map]\nFILES: [specific files]\n\n[detailed requirements]\n\n[success criteria]",
      "domain": "[domain]",
      "files": ["file1.js", "file2.js"],
      "priority": "normal",
      "depends_on": []
    },
    {
      "subject": "[task 2 title]",
      "description": "...",
      "domain": "[domain]",
      "files": ["file3.js"],
      "priority": "normal",
      "depends_on": ["[task 1 subject if dependency]"]
    }
  ]
}
TASKS'
```

Say: "Decomposed request [id] into [N] tasks across [M] domains. Master-3 will route to workers."

**Log the decomposition:**
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-2] [DECOMPOSE_DONE] id=[request_id] tasks=[N] domains=[list]" >> .claude/logs/activity.log
```

### Step 4: Check for clarification responses
```bash
cat .claude/state/clarification-queue.json
```

If there are responses you haven't processed yet, incorporate them into your thinking and continue any pending decomposition.

### Step 5: Wait and repeat

Adjust polling based on activity:
- If you just processed a request → `sleep 5` (stay responsive for follow-ups)
- If nothing happened → `sleep 15` (you're reactive, not operational)

Say: "... (watching for new requests)"
```bash
sleep 15
```
Go back to Step 1.

## Decomposition Quality Rules

**Rule 1: Each task must be self-contained**
- A worker should be able to complete the task with ONLY the files listed
- No implicit dependencies on other tasks completing first (unless in depends_on)

**Rule 2: Tag every task with DOMAIN and FILES**
- DOMAIN: from your codebase-map.json
- FILES: specific files to modify (not directories, not globs)
- Master-3 uses these tags to route — if you get them wrong, the wrong worker gets the task

**Rule 3: Be specific in requirements**
- "Fix the bug" is bad. "In popout.js line 142, the theme sync callback fires before the window is ready — add a readyState check" is good.
- Include expected behavior, edge cases, and how to verify.

**Rule 4: Respect coupling boundaries**
- If files A and B are coupled (from codebase-map), they MUST be in the same task
- Never split coupled files across tasks — that creates merge conflicts

**Rule 5: Order matters**
- Use `depends_on` for tasks that must complete sequentially
- Master-3 will respect this ordering when allocating

## Incremental Map Updates

When Master-3 signals that PRs have been merged, do a quick incremental update:
```bash
last_scan=$(jq -r '.scanned_at // "1970-01-01"' .claude/state/codebase-map.json 2>/dev/null)
git log --since="$last_scan" --name-only --pretty=format: | sort -u | grep -v '^$'
```
Read only changed files, update codebase-map.json. Keep your knowledge fresh.

## Context Reset

Your context window accumulates codebase content, decomposition reasoning, and polling loop history. After prolonged operation, earlier codebase knowledge gets compressed or evicted, degrading your decomposition quality.

**Self-monitor:** After every 3rd decomposition, check your own context health:
- Can you still recall the domain map accurately? Try listing all domains and their key files from memory.
- If you find yourself re-reading files you already scanned, your context is degraded.

**When to reset:** If you notice degradation, or after 5 decompositions in a single session:
1. Say: "Context getting heavy. Resetting and re-scanning."
2. Run `/clear`
3. Run `/scan-codebase` — this will re-read the codebase and auto-start the architect loop again

You lose nothing by resetting because all state lives in JSON files (handoff.json, task-queue.json, codebase-map.json). The re-scan refreshes your codebase knowledge with a clean context window.


################################################################################
# FILE: templates/commands/allocate-loop.md
################################################################################

---
description: Master-3's main loop. Routes decomposed tasks to workers, monitors status, merges PRs.
---

You are **Master-3: Allocator**.

**If this is a fresh start (post-reset), re-read your role document:**
```bash
cat .claude/docs/master-3-role.md
```

You run the fast operational loop. You read decomposed tasks from Master-2 and route them to the right workers. You do NOT decompose requests — Master-2 does that. You just need to be **fast and reliable**.

## Startup Message

When user runs `/allocate-loop`, say:
```
████  I AM MASTER-3 — ALLOCATOR  ████

Monitoring for:
• Decomposed tasks in task-queue.json
• Fix requests in fix-queue.json
• Worker status and heartbeats
• Task completion for integration

Polling every 3-10 seconds...
```

Then begin the loop.

## The Loop (Explicit Steps)

**Repeat these steps forever:**

### Step 1: Check for fix requests (HIGHEST PRIORITY)
```bash
cat .claude/state/fix-queue.json
```

If file contains a fix task:
1. Read the worker and task details
2. Create the task with TaskCreate:
   ```
   TaskCreate({
     subject: "[from fix-queue]",
     description: "[from fix-queue]\n\nASSIGNED_TO: [worker]\nPRIORITY: URGENT",
     activeForm: "Urgent fix..."
   })
   ```
3. Clear the fix-queue.json: `bash .claude/scripts/state-lock.sh .claude/state/fix-queue.json 'echo "{}" > .claude/state/fix-queue.json'`
4. Say: "Fix task created and assigned to [worker]"

### Step 2: Check for decomposed tasks from Master-2
```bash
cat .claude/state/task-queue.json
```

If there are tasks to allocate:
1. Read each task's DOMAIN and FILES tags
2. Check worker-status.json for available workers AND their `tasks_completed` counts
3. **For each task, evaluate:** should this go to an existing worker or a fresh one?
   - Check if any worker has context on the EXACT files (not just domain)
   - Check that worker's `tasks_completed` count
   - If `tasks_completed` >= 2 AND an idle worker exists → prefer the idle worker
   - If no idle worker exists → assign to least-loaded worker
   - If task is a fix → always assign to the original worker regardless of load
4. Create tasks with TaskCreate, assigning to chosen workers
5. Update worker-status.json (including `tasks_completed` and `queued_task`)
6. Clear processed tasks from task-queue.json (or mark as allocated)
7. Say: "Allocated [N] tasks from request [id]. [summary: which worker got what and WHY — e.g. 'Worker-2 (idle, clean context)' or 'Worker-1 (same files, 1 task completed)']"
8. **Log each allocation:**
   ```bash
   echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-3] [ALLOCATE] task=\"[subject]\" → worker-N reason=\"[why]\"" >> .claude/logs/activity.log
   ```

### Step 3: Check worker status
```bash
cat .claude/state/worker-status.json
```

For each worker, note their current status (busy, idle, completed_task).
Log progress: "Worker-N: [status] on [domain]"

### Step 4: Check for completed requests
```bash
TaskList()
```

If ALL tasks for a request_id are "completed":
1. Announce: "Request [id] complete. Starting integration..."
2. Read `.claude/state/change-summaries.md` for a summary of all changes made by workers for this request
3. Pull latest from default branch: `git pull origin $(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)`
4. Merge PRs for this request
5. Spawn build-validator to verify
6. Spawn verify-app to test
7. If issues, create fix tasks
8. If clean, push to main
9. Update handoff.json status to `"integrated"`
10. Say: "Request [id] integrated successfully."

### Step 5: Adaptive wait and repeat

Adjust polling speed based on activity:
- If you processed a task, fix, or allocation this cycle → `sleep 3` (stay responsive)
- If nothing happened this cycle → `sleep 10` (save resources)

Say: "... (checking in Ns)"
```bash
sleep 3   # or sleep 10 if idle
```
Go back to Step 1.

### Step 6: Heartbeat check (dead worker detection)

Every 3rd polling cycle, check for dead workers:
```bash
cat .claude/state/worker-status.json
```
For each worker with `"status": "busy"`:
- Check if their `last_heartbeat` is older than 90 seconds
- If stale: mark them as `"status": "dead"`, log a warning
- Their domain becomes available for reassignment to a new worker
- Say: "WARNING: Worker-N appears dead (no heartbeat for >90s). Domain [X] is now unassigned."

## Allocation Rules (STRICT)

**Rule 1: Domain matching is STRICT**
- STRICTLY SIMILAR = same files OR directly imports/exports
- "Both touch React components" is NOT similar
- "Both in src/" is NOT similar
- Only file-level coupling counts
- Master-2 already tagged each task with DOMAIN and FILES — trust those tags

**Rule 2: Fresh context > queued context (CRITICAL)**

DO NOT default to queuing tasks to a busy worker just because they share a domain. A worker that has completed 3+ tasks or has been running for a while has a degraded context window — earlier instructions, file contents, and reasoning are compressed or evicted. The cost of that degradation often exceeds the cost of giving a fresh worker the task with a clean context.

**Decision framework — queue vs. fresh worker:**

| Factor | Queue to busy worker | Assign to idle/fresh worker |
|--------|--------------------|-----------------------------|
| Worker has completed 0-1 tasks on this exact domain | ✅ Queue — context is still clean | — |
| Worker has completed 2+ tasks already | ❌ Prefer fresh | ✅ Fresh context wins |
| Task touches the EXACT same files worker just edited | ✅ Queue — file context is hot | — |
| Task is in same domain but DIFFERENT files | ❌ Prefer fresh | ✅ Domain context is weak |
| All idle workers are exhausted (none available) | ✅ Queue — no choice | — |
| Task is a FIX for work this worker just did | ✅ Always queue — they have the bug context | — |

**In practice:** If an idle worker exists, prefer it for any task where the busy worker has already completed 2+ tasks — even if the busy worker is on the same domain. The idle worker starts with a perfect context window. The only exceptions are fix tasks (Rule 4) and tasks touching the exact same files the busy worker just modified.

**Rule 3: Allocation order (updated)**
1. Is this a fix for a specific worker's output? → assign to THAT worker (Rule 4)
2. Does task touch the EXACT files a worker just edited (0-1 tasks completed)? → queue to them
3. Is there an idle worker available? → assign to idle worker (PREFER THIS)
4. All workers busy, all with 2+ completed tasks? → assign to least-loaded worker
5. Absolute last resort: queue behind a heavily-loaded worker

**Rule 4: Fix tasks go to the SAME worker**
- Fix tasks always go back to the worker who made the mistake
- They have context, they should fix it
- This is the ONE exception to the fresh-context preference

**Rule 5: Respect depends_on**
- If task B depends_on task A, do NOT allocate B until A is complete
- Check TaskList() status before allocating dependent tasks

**Rule 6: NEVER queue more than 1 task per worker**
- A worker should have at most 1 active task + 1 queued task
- If a worker already has a queued task, the next task MUST go to a different worker or wait
- This prevents deep queues that guarantee context degradation

## Creating Tasks

> **Note:** `TaskCreate`, `TaskList`, and `TaskUpdate` are Claude Code's built-in task management tools.
> They are available to all agents automatically — no imports or setup needed.

Always include in task description:
- REQUEST_ID
- DOMAIN
- ASSIGNED_TO (worker name)
- FILES (specific files to modify)

```
TaskCreate({
  subject: "Fix popout theme sync",
  description: "REQUEST_ID: popout-fixes\nDOMAIN: popout\nASSIGNED_TO: worker-1\nFILES: main.js, popout.js\n\n[detailed requirements from task-queue.json]",
  activeForm: "Working on popout theme..."
})
```

## Tracking Worker Load

When assigning a task, update `.claude/state/worker-status.json` using lock:
```bash
bash .claude/scripts/state-lock.sh .claude/state/worker-status.json '<command to update json>'
```

**You MUST track `tasks_completed`** — this is how you decide queue vs. fresh worker:

Example state:
```json
{
  "worker-1": {
    "status": "assigned",
    "domain": "popout",
    "current_task": "Add readyState guard to popout theme sync callback",
    "tasks_completed": 2,
    "queued_task": null,
    "awaiting_approval": false,
    "last_heartbeat": "2024-01-15T10:30:00Z"
  }
}
```

- Increment `tasks_completed` each time a worker finishes a task
- Use `tasks_completed` to make the queue-vs-fresh decision (see Rule 2)
- Track `queued_task` to enforce Rule 6 (max 1 queued task per worker)

## Worker Context Reset (Master-3 Responsibilities)

You are responsible for triggering worker resets in two cases:

### Case 1: Auto-reset at 4 completed tasks
When a worker's `tasks_completed` reaches 4, their context window is degraded. On their next idle cycle:
1. Create a task for that worker: `TaskCreate({ subject: "RESET: Context limit reached", description: "ASSIGNED_TO: worker-N\n\nYour context window has reached the 4-task limit. Run /clear then /worker-loop to restart with a clean context." })`
2. Reset their worker-status.json entry: `tasks_completed: 0, domain: null, status: "resetting"`
3. Say: "Worker-N reached 4 tasks — triggering context reset. They will rejoin with a clean window."
4. Log: `echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-3] [RESET_WORKER] worker-N reason=\"4 tasks completed\"" >> .claude/logs/activity.log`

### Case 2: Domain mismatch — only available worker has wrong domain
When you need to allocate a task but the ONLY un-queued worker has a different domain than the task requires:
1. Create a reset task for that worker: `TaskCreate({ subject: "RESET: Domain reassignment needed", description: "ASSIGNED_TO: worker-N\n\nNew domain needed. Run /clear then /worker-loop to restart with a clean context for the new domain." })`
2. Reset their worker-status.json entry: `tasks_completed: 0, domain: null, status: "resetting"`
3. Queue the original task — it will be assigned to this worker once they come back idle
4. Say: "Worker-N domain mismatch ([old domain] vs needed [new domain]) — triggering reset for reassignment."
5. Log: `echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-3] [RESET_WORKER] worker-N reason=\"domain mismatch: [old]→[new]\"" >> .claude/logs/activity.log`

**Do NOT queue a task to a worker in the wrong domain.** A fresh context on the correct domain always beats a stale context on the wrong one.

## Master-3 Context Reset (Self)

Your own context accumulates polling loop history, allocation decisions, and worker state. After prolonged operation this degrades your decision quality.

**Self-monitor:** After every 20 polling cycles, check:
- Can you still recall the domain map and worker assignments accurately?
- Are you re-reading worker-status.json and getting confused about which worker has which domain?

**When to reset:** If you notice degradation, or after 30 minutes of continuous operation:
1. Say: "Context getting heavy. Resetting and re-scanning."
2. Run `/clear`
3. Run `/scan-codebase-allocator` — this will re-read the codebase and auto-start the allocate loop again

You lose nothing by resetting because all state lives in JSON files (worker-status.json, task-queue.json, fix-queue.json). The re-scan refreshes your codebase knowledge with a clean context window.


################################################################################
# FILE: templates/commands/scan-codebase.md
################################################################################

---
description: Master-2 scans and maps the entire codebase. Run once at start.
---

You are **Master-2: Architect**.

**First, read your role document for full context:**
```bash
cat .claude/docs/master-2-role.md
```

## First Message

Before doing anything else, say:
```
████  I AM MASTER-2 — ARCHITECT  ████
Starting codebase scan...
```

## Scan the Codebase

Read the entire codebase and create a map. This takes ~10 minutes but only needs to happen once.

**Step 1: Discover structure**

Auto-detect source files (all common languages — not just JS/TS):
```bash
find . -type f \( \
  -name "*.js" -o -name "*.jsx" -o -name "*.ts" -o -name "*.tsx" \
  -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.rb" \
  -o -name "*.java" -o -name "*.kt" -o -name "*.swift" -o -name "*.c" \
  -o -name "*.cpp" -o -name "*.h" -o -name "*.cs" -o -name "*.php" \
  -o -name "*.vue" -o -name "*.svelte" -o -name "*.astro" \
  -o -name "*.css" -o -name "*.scss" -o -name "*.json" -o -name "*.yaml" \
  -o -name "*.yml" -o -name "*.toml" -o -name "*.sql" \
\) | grep -vE 'node_modules|\.git/|vendor/|dist/|build/|__pycache__|\.next/' | head -500
```

If > 500 files, focus on the top-level directory tree first, then deep-read key entrypoints and imports.

**Step 2: Read key files**
Read each file and understand:
- What does this file do?
- What does it import/export?
- What domain does it belong to?

**Step 3: Build domain map**
Group files by domain:
```
domains:
  popout:
    files: [main.js (lines 200-400), popout.js, _popout.css]
    coupled_to: [App.jsx (theme sync), preload.js (IPC)]
  auth:
    files: [auth.js, login.jsx, signup.jsx]
    coupled_to: [api.js, userStore.js]
  theme:
    files: [ThemeContext.js, _variables.css]
    coupled_to: [App.jsx]
```

**Step 4: Save map**
Write to `.claude/state/codebase-map.json`:
```bash
cat > .claude/state/codebase-map.json << 'MAP'
{
  "scanned_at": "2024-...",
  "domains": {
    "popout": {
      "files": ["src/main/main.js", "src/renderer/popout.js"],
      "coupled_to": ["src/renderer/App.jsx"],
      "description": "Popout window functionality"
    }
  },
  "file_to_domain": {
    "src/main/main.js": "popout",
    "src/renderer/popout.js": "popout"
  }
}
MAP
```

**Step 5: Confirm and auto-start architect loop**
Say: "Codebase scanned. Found [N] domains. Ready for decomposition."

Then **immediately** run `/architect-loop` — do NOT wait for user input. The scan is just the setup phase; decomposition is your real job.

## When to Re-scan
- Major refactor
- New feature area added
- User says "rescan"

## Incremental Update (after merging PRs)
Instead of a full re-scan, update the map for changed files only:
```bash
# Find files changed since last scan timestamp
last_scan=$(jq -r '.scanned_at // "1970-01-01"' .claude/state/codebase-map.json 2>/dev/null)
git log --since="$last_scan" --name-only --pretty=format: | sort -u | grep -v '^$'
```
Read only these files and update/add their domain mappings in codebase-map.json.
Mark the updated timestamp. This should take under 1 minute for typical PR merges.


################################################################################
# FILE: templates/commands/scan-codebase-allocator.md
################################################################################

---
description: Master-3 scans the codebase for routing knowledge, then starts the allocate loop.
---

You are **Master-3: Allocator**.

**First, read your role document for full context:**
```bash
cat .claude/docs/master-3-role.md
```

## First Message

Before doing anything else, say:
```
████  I AM MASTER-3 — ALLOCATOR  ████
Starting codebase scan for routing knowledge...
```

## Scan the Codebase

You need direct codebase knowledge to make good routing decisions — not just the domain tags in codebase-map.json, but understanding of file relationships, coupling, and complexity.

**Step 1: Read the existing codebase map (if Master-2 has already scanned)**
```bash
cat .claude/state/codebase-map.json
```

If it's populated, read the key files from each domain to build your own understanding.
If it's empty (`{}`), do a full scan — Master-2 may not have finished yet.

**Step 2: Discover structure**
```bash
find . -type f \( \
  -name "*.js" -o -name "*.jsx" -o -name "*.ts" -o -name "*.tsx" \
  -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.rb" \
  -o -name "*.java" -o -name "*.kt" -o -name "*.swift" -o -name "*.c" \
  -o -name "*.cpp" -o -name "*.h" -o -name "*.cs" -o -name "*.php" \
  -o -name "*.vue" -o -name "*.svelte" -o -name "*.astro" \
  -o -name "*.css" -o -name "*.scss" -o -name "*.json" -o -name "*.yaml" \
  -o -name "*.yml" -o -name "*.toml" -o -name "*.sql" \
\) | grep -vE 'node_modules|\.git/|vendor/|dist/|build/|__pycache__|\.next/' | head -500
```

**Step 3: Read key files**
Read each file and understand:
- What does this file do?
- What are its imports/exports and coupling relationships?
- What domain does it belong to?
- How complex is it? (matters for estimating task duration)

**Step 4: If codebase-map.json was empty, write it**
Use the same format as Master-2's scan. If Master-2 has already written it, do NOT overwrite — your scan is supplementary context for routing decisions.

**Step 5: Start allocate loop**
Say: "Codebase scanned. I have direct knowledge of [N] files across [M] domains. Starting allocation loop."

Then **immediately** run `/allocate-loop` — do NOT wait for user input.


################################################################################
# FILE: templates/commands/worker-loop.md
################################################################################

---
description: Worker loop with explicit polling and auto-continue after task completion.
---

You are a **Worker**. Check your branch to know your ID:
```bash
git branch --show-current
```
- agent-1 → worker-1
- agent-2 → worker-2
- etc.

## Startup

1. Determine your worker ID from branch name
2. Register yourself using the locking helper:
```bash
# Read current status
cat .claude/state/worker-status.json

# Add/update your entry using lock:
# bash .claude/scripts/state-lock.sh .claude/state/worker-status.json '<update command>'
# "worker-N": {"status": "idle", "domain": null, "current_task": null, "tasks_completed": 0, "queued_task": null, "awaiting_approval": false, "last_heartbeat": "<ISO timestamp>"}
```

3. Announce:
```
████  I AM WORKER-N  ████

Domain: none (will be assigned on first task)
Status: idle, polling for tasks...
```

4. Read worker lessons (mistakes from previous tasks across all workers):
```bash
cat .claude/state/worker-lessons.md
```
Internalize these lessons — they are hard-won knowledge from this project. Apply them to every task you work on.

5. Begin the loop

## The Loop (Explicit Steps)

**Repeat these steps forever:**

### Step 0: Heartbeat
Update your `last_heartbeat` timestamp in worker-status.json every cycle:
```bash
# bash .claude/scripts/state-lock.sh .claude/state/worker-status.json '<update your last_heartbeat to current ISO timestamp>'
```
This lets Master-3 detect dead workers. If you skip this, Master-3 will mark you as dead after 90s.

### Step 1: Check for urgent fix tasks
```bash
cat .claude/state/worker-status.json
```

Look at your entry. If there is a fix task pending for you (check fix-queue.json), handle it FIRST before any other work.

### Step 2: Check for assigned tasks
```bash
TaskList()
```

Look for tasks where:
- Description contains `ASSIGNED_TO: worker-N` (your ID)
- Status is "pending" or "open"

**RESET tasks take absolute priority.** If you see a task with subject starting with "RESET:" assigned to you:
1. Mark the task complete: `TaskUpdate(task_id, status="completed")`
2. Update worker-status.json: `status: "resetting", tasks_completed: 0, domain: null`
3. Run `/clear`
4. Run `/worker-loop`
Do NOT finish any current work first — RESET means your context is too degraded to produce quality output.

Also check for URGENT fix tasks (these have priority over normal tasks).

### Step 3: If task found - validate domain

**If this is your FIRST task:**
- Extract DOMAIN from task description
- This becomes YOUR domain
- Update worker-status.json with your domain

**If you already have a domain:**
- Check if task's DOMAIN matches your domain
- If YES: proceed to claim
- If NO: this is an error - Master-3 shouldn't assign cross-domain. Say: "ERROR: Assigned task [X] but my domain is [Y]. Skipping."
- ```bash
  sleep 10
  ```
- Go to Step 1

### Step 4: Claim and work

1. **Claim the task:**
```
TaskUpdate(task_id, status="in_progress", owner="worker-N")
```

2. **Update your status using lock:**
```bash
# bash .claude/scripts/state-lock.sh .claude/state/worker-status.json '<update command>'
# Set: status="busy", current_task="[task subject]"
```

3. **Read recent changes by other workers:**
```bash
cat .claude/state/change-summaries.md
```
Check for changes that overlap with or affect the files you're about to modify. If another worker has recently changed a file you depend on, account for their changes in your approach.

4. **Announce:**
```
CLAIMED: [task subject]
Domain: [domain]
Files: [files from description]

Starting work...
```

5. **Plan** (Enter Plan Mode - Shift+Tab twice):
- Understand the task fully
- List the changes needed
- Identify risks

6. **Review** (if 5+ files):
- Spawn code-architect subagent
- Wait for APPROVE/NEEDS CHANGES/REJECT
- If NEEDS CHANGES: revise plan
- If REJECT: mark task as blocked, go to Step 1

7. **Build:**
- Implement the changes
- Follow existing patterns in the codebase
- Make minimal, focused changes

8. **Verify:**
- Spawn build-validator: check build/lint/types/tests
- Spawn verify-app: check feature works
- If issues found: fix them, re-verify

9. **Ship:**
- Run `/commit-push-pr`
- Note the PR URL

### Step 6: Log completion and continue

1. **Update status using lock:**
```bash
# bash .claude/scripts/state-lock.sh .claude/state/worker-status.json '<update command>'
# Set: status="completed_task", current_task="[task subject]", last_pr="[PR URL]"
# IMPORTANT: Increment tasks_completed by 1 (read current value first)
# Clear queued_task to null if this was the queued task
```

2. **Mark task complete:**
```
TaskUpdate(task_id, status="completed")
```

3. **Log completion for async review:**
```
════════════════════════════════════════
TASK COMPLETE: [task subject]
PR: [PR URL]

Files changed:
• [file1]
• [file2]

Continuing to next task...
(User can review via "status" in Master-1)
(User can send "fix worker-N: [issue]" if something's wrong)
════════════════════════════════════════
```

**Log to activity log:**
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [worker-N] [COMPLETE] task=\"[task subject]\" pr=[PR URL] tasks_completed=[count]" >> .claude/logs/activity.log
```

4. **Write change summary (so other workers know what you changed):**
```bash
bash .claude/scripts/state-lock.sh .claude/state/change-summaries.md 'cat >> .claude/state/change-summaries.md << SUMMARY

## [ISO timestamp] worker-N | domain: [domain] | task: "[task subject]"
**Files changed:** [list of files you modified]
**What changed:** [2-3 sentence summary of what you did and why — focus on interface changes, shared state changes, or anything another worker touching nearby code would need to know]
**PR:** [PR URL]
---
SUMMARY'
```

5. **Check task count — self-reset at 4:**
```bash
cat .claude/state/worker-status.json
```
Read your `tasks_completed` value. If it is now 4 or higher:
- Say: "Reached 4 completed tasks — resetting context for quality."
- Log: `echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [worker-N] [RESET] reason=\"context limit\" tasks_completed=4→0" >> .claude/logs/activity.log`
- Update worker-status.json: `status: "resetting", tasks_completed: 0, domain: null`
- Run `/clear`
- Run `/worker-loop`

If under 4, **immediately go back to Step 0** (heartbeat) to pick up the next task. Do NOT wait for approval.

### Step 7: If no task found
- Say: "No tasks assigned. Polling... (checking in 10s)"
- ```bash
  sleep 10
  ```
- If you just completed a task in the previous cycle, use `sleep 3` instead (next task may be queued)
- Go back to Step 0 (heartbeat)

## Domain Rules Summary

- You get ONE domain, set by your first task
- You ONLY work on tasks in your domain
- Fix tasks for your work come back to YOU (same domain)

## Context Reset

Your context window degrades after sustained work. The system handles this automatically:

**At 4 completed tasks:** Master-3 will send you a task with subject starting with "RESET:". When you receive a RESET task:
1. Update worker-status.json: `status: "resetting", tasks_completed: 0, domain: null`
2. Run `/clear`
3. Run `/worker-loop` — you will restart with a clean context and get assigned a new domain on your next task

**Domain reassignment:** Master-3 may also send a RESET task when your current domain doesn't match available work. Same process — clear and restart.

**Self-check:** If you notice yourself forgetting file contents you read earlier in the session, struggling with tasks that should be straightforward, or re-reading files you already read — proactively reset:
1. Finish your current task first (if any)
2. Update worker-status.json: `status: "resetting", tasks_completed: 0, domain: null`
3. Run `/clear`
4. Run `/worker-loop`

## Emergency Commands

If something goes wrong:
- `/clear` then `/worker-loop` - Full context reset and restart
- Manually update worker-status.json to reset your state


################################################################################
# FILE: templates/commands/commit-push-pr.md
################################################################################

---
description: Ship completed work with error handling.
---

1. `git add -A`
2. `git diff --cached --stat`
3. **Secret check:** `git diff --cached` — ABORT if you see API keys, tokens, passwords, .env values, or private keys in the diff. Say "BLOCKED: secrets detected in diff" and do NOT proceed.
4. `git commit -m "type(scope): description"`
5. Push with retry:
   ```bash
   git push origin HEAD || (git pull --rebase origin HEAD && git push origin HEAD)
   ```
   If push still fails, say "ERROR: push failed — may need manual conflict resolution" and report the error.
6. Create PR with retry:
   ```bash
   gh pr create --base $(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main) --fill 2>&1
   ```
   If `gh pr create` fails (e.g., PR already exists), try: `gh pr view --web 2>/dev/null` to get the existing PR URL.
   If that also fails, report the error and the branch name so the user can create the PR manually.
7. Report PR URL


################################################################################
# FILE: templates/state/worker-lessons.md
################################################################################

# Worker Lessons Learned

<!-- Mistakes from worker tasks — all workers read this before starting any task -->
<!-- Masters append lessons here when fix tasks are created -->



################################################################################
# FILE: templates/state/change-summaries.md
################################################################################

# Change Summaries

<!-- Workers append a brief summary here after completing each task -->
<!-- Read this before starting work to see what other workers have changed -->



################################################################################
# FILE: gui/package.json
################################################################################

{
  "name": "agent-control-center",
  "version": "1.0.0",
  "description": "Multi-Agent Orchestration Control Center",
  "main": "src/main/main.js",
  "scripts": {
    "start": "unset ELECTRON_RUN_AS_NODE && electron ."
  },
  "devDependencies": {
    "electron": "^28.0.0"
  },
  "dependencies": {
    "chokidar": "^3.5.3"
  }
}

################################################################################
# FILE: gui/start.sh
################################################################################

#!/bin/bash
# Agent Control Center - Unified Launcher
# Runs both the terminal agents AND the Electron GUI

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source shell config for npm access
source ~/.zshrc 2>/dev/null || source ~/.bashrc 2>/dev/null || true

echo "🚀 Starting Agent Control Center..."
echo ""

# Check if GUI dependencies are installed
if [ ! -d "$SCRIPT_DIR/node_modules" ]; then
    echo "📦 Installing GUI dependencies..."
    cd "$SCRIPT_DIR"
    npm install
    cd "$PROJECT_ROOT"
fi

# Start the Electron GUI in background
echo "🖥️  Launching Control Center GUI..."
cd "$SCRIPT_DIR"
npm start &
GUI_PID=$!
cd "$PROJECT_ROOT"

echo "   GUI started (PID: $GUI_PID)"
echo ""

# Give GUI time to start
sleep 2

echo "✅ Agent Control Center is running!"
echo ""
echo "📍 In the GUI:"
echo "   1. Click 'Select Project' and choose this project directory"
echo "   2. The GUI will connect and show real-time updates"
echo ""
echo "⌨️  Quick Commands (type in GUI command bar):"
echo "   • Natural language request → Sent to Master-1"
echo "   • 'fix worker-1: description' → Send urgent fix"
echo ""
echo "Press Ctrl+C to stop the GUI"
echo ""

# Wait for GUI to exit
wait $GUI_PID 2>/dev/null || true


################################################################################
# FILE: gui/src/backend.js
################################################################################

// NW.js Backend - Runs in Node.js context
const fs = require('fs');
const path = require('path');
const chokidar = require('chokidar');

// Get project path from args or use parent directory
let projectPath = process.argv.find(a => a.startsWith('--project='))?.split('=')[1]
    || path.resolve(__dirname, '../../..');

const stateDir = path.join(projectPath, '.claude-shared-state');
const logPath = path.join(projectPath, '.claude', 'logs', 'activity.log');

// Export functions for renderer
global.backend = {
    projectPath,
    stateDir,

    getState: (filename) => {
        try {
            return JSON.parse(fs.readFileSync(path.join(stateDir, filename), 'utf-8'));
        } catch (e) {
            return null;
        }
    },

    getActivityLog: (lines = 100) => {
        try {
            const content = fs.readFileSync(logPath, 'utf-8');
            return content.split('\n').filter(l => l.trim()).slice(-lines);
        } catch (e) {
            return [];
        }
    },

    writeState: (filename, data) => {
        try {
            fs.writeFileSync(path.join(stateDir, filename), JSON.stringify(data, null, 2));
            return { success: true };
        } catch (e) {
            return { success: false, error: e.message };
        }
    },

    selectProject: () => {
        // Will be handled via file dialog in renderer
        return null;
    },

    stateWatcher: null,
    logWatcher: null,

    startWatching: (onStateChange, onLogLines) => {
        // Watch state files
        global.backend.stateWatcher = chokidar.watch(stateDir, {
            persistent: true,
            ignoreInitial: true,
            awaitWriteFinish: { stabilityThreshold: 100 }
        });

        global.backend.stateWatcher.on('change', (filePath) => {
            const filename = path.basename(filePath);
            onStateChange(filename);
        });

        // Watch log
        if (fs.existsSync(logPath)) {
            let lastSize = fs.statSync(logPath).size;

            global.backend.logWatcher = chokidar.watch(logPath, {
                persistent: true,
                ignoreInitial: true
            });

            global.backend.logWatcher.on('change', () => {
                try {
                    const newSize = fs.statSync(logPath).size;
                    if (newSize > lastSize) {
                        const fd = fs.openSync(logPath, 'r');
                        const buffer = Buffer.alloc(newSize - lastSize);
                        fs.readSync(fd, buffer, 0, buffer.length, lastSize);
                        fs.closeSync(fd);

                        const newLines = buffer.toString('utf-8').split('\n').filter(l => l.trim());
                        if (newLines.length > 0) {
                            onLogLines(newLines);
                        }
                    }
                    lastSize = newSize;
                } catch (e) { }
            });
        }

        console.log('Started watching:', stateDir);
    }
};

console.log('Backend initialized for project:', projectPath);


################################################################################
# FILE: gui/src/server.js
################################################################################

const http = require('http');
const fs = require('fs');
const path = require('path');
const chokidar = require('chokidar');
const { execSync } = require('child_process');

const PORT = 3847;
let projectPath = process.argv[2] || process.cwd();

// Validate project path
const stateDir = path.join(projectPath, '.claude-shared-state');
if (!fs.existsSync(stateDir)) {
    console.error('❌ Error: .claude-shared-state directory not found');
    console.error(`   Looking in: ${projectPath}`);
    console.error('');
    console.error('Usage: node server.js [project-path]');
    process.exit(1);
}

// SSE clients
const clients = [];

// File paths
const getStatePath = (file) => path.join(projectPath, '.claude-shared-state', file);
const getLogPath = () => path.join(projectPath, '.claude', 'logs', 'activity.log');

// Start file watchers
function startWatching() {
    const watcher = chokidar.watch(stateDir, {
        persistent: true,
        ignoreInitial: true,
        awaitWriteFinish: { stabilityThreshold: 100 }
    });

    watcher.on('change', (filePath) => {
        const filename = path.basename(filePath);
        broadcast({ type: 'state-changed', filename });
    });

    // Watch activity log
    const logPath = getLogPath();
    if (fs.existsSync(logPath)) {
        let lastSize = fs.statSync(logPath).size;

        chokidar.watch(logPath, { persistent: true, ignoreInitial: true })
            .on('change', () => {
                try {
                    const newSize = fs.statSync(logPath).size;
                    if (newSize > lastSize) {
                        const buffer = Buffer.alloc(newSize - lastSize);
                        const fd = fs.openSync(logPath, 'r');
                        fs.readSync(fd, buffer, 0, buffer.length, lastSize);
                        fs.closeSync(fd);

                        const newLines = buffer.toString('utf-8').split('\n').filter(l => l.trim());
                        if (newLines.length > 0) {
                            broadcast({ type: 'new-log-lines', lines: newLines });
                        }
                    }
                    lastSize = newSize;
                } catch (e) { }
            });
    }

    console.log('👁️  Watching:', stateDir);
}

function broadcast(data) {
    const msg = `data: ${JSON.stringify(data)}\n\n`;
    clients.forEach(res => res.write(msg));
}

// MIME types
const mimeTypes = {
    '.html': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.json': 'application/json'
};

// HTTP Server
const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${PORT}`);

    // CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    // API routes
    if (url.pathname === '/api/events') {
        // SSE endpoint
        res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive'
        });
        res.write('data: {"type":"connected"}\n\n');
        clients.push(res);
        req.on('close', () => {
            const idx = clients.indexOf(res);
            if (idx > -1) clients.splice(idx, 1);
        });
        return;
    }

    if (url.pathname === '/api/state' && req.method === 'GET') {
        const filename = url.searchParams.get('file');
        try {
            const content = fs.readFileSync(getStatePath(filename), 'utf-8');
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(content);
        } catch (e) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end('{}');
        }
        return;
    }

    if (url.pathname === '/api/log' && req.method === 'GET') {
        try {
            const content = fs.readFileSync(getLogPath(), 'utf-8');
            const lines = content.split('\n').filter(l => l.trim()).slice(-100);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(lines));
        } catch (e) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end('[]');
        }
        return;
    }

    if (url.pathname === '/api/write' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            try {
                const { file, data } = JSON.parse(body);
                fs.writeFileSync(getStatePath(file), JSON.stringify(data, null, 2));
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end('{"success":true}');
            } catch (e) {
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(`{"error":"${e.message}"}`);
            }
        });
        return;
    }

    if (url.pathname === '/api/project') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ path: projectPath, name: path.basename(projectPath) }));
        return;
    }

    // Static files
    let filePath = url.pathname === '/' ? '/index.html' : url.pathname;
    filePath = path.join(__dirname, 'renderer', filePath);

    const ext = path.extname(filePath);
    const contentType = mimeTypes[ext] || 'text/plain';

    try {
        const content = fs.readFileSync(filePath);
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(content);
    } catch (e) {
        res.writeHead(404);
        res.end('Not found');
    }
});

// Start
startWatching();
server.listen(PORT, () => {
    console.log('');
    console.log('🧠 Agent Control Center');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log(`📂 Project: ${projectPath}`);
    console.log(`🌐 Open: http://localhost:${PORT}`);
    console.log('');
    console.log('Press Ctrl+C to stop');
    console.log('');

    // Auto-open browser
    try {
        execSync(`open http://localhost:${PORT}`);
    } catch (e) { }
});


################################################################################
# FILE: gui/src/main/main.js
################################################################################

// Electron Main Process - Agent Control Center
// WITH EXTENSIVE DEBUG LOGGING
'use strict';

const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const chokidar = require('chokidar');

let mainWindow = null;
let stateWatcher = null;
let logWatcher = null;
let projectPath = null;

// ═══════════════════════════════════════════════════════════════════════════
// DEBUG LOGGING SYSTEM
// ═══════════════════════════════════════════════════════════════════════════
const DEBUG = true;
let debugLog = [];
const MAX_DEBUG_ENTRIES = 500;

function debug(category, message, data = null) {
    if (!DEBUG) return;

    const entry = {
        timestamp: new Date().toISOString(),
        category,
        message,
        data: data ? JSON.stringify(data).slice(0, 500) : null
    };

    debugLog.push(entry);
    if (debugLog.length > MAX_DEBUG_ENTRIES) {
        debugLog = debugLog.slice(-MAX_DEBUG_ENTRIES);
    }

    const logStr = `[MAIN:${category}] ${message}${data ? ' | ' + JSON.stringify(data).slice(0, 200) : ''}`;
    console.log(logStr);

    // Send to renderer if window exists
    mainWindow?.webContents.send('debug-log', entry);
}

// Get project path from command line or default to parent
const args = process.argv.slice(2);
debug('INIT', 'Starting with args', args);

const projectArg = args.find(a => !a.startsWith('-'));
if (projectArg && fs.existsSync(path.join(projectArg, '.claude-shared-state'))) {
    projectPath = projectArg;
    debug('INIT', 'Project path from args', { projectPath });
} else {
    debug('INIT', 'No valid project path in args');
}

const getStatePath = (file) => projectPath ? path.join(projectPath, '.claude-shared-state', file) : null;
const getLogPath = () => projectPath ? path.join(projectPath, '.claude', 'logs', 'activity.log') : null;

function createWindow() {
    debug('WINDOW', 'Creating main window');

    mainWindow = new BrowserWindow({
        width: 1400,
        height: 900,
        minWidth: 900,
        minHeight: 600,
        titleBarStyle: 'hiddenInset',
        backgroundColor: '#0d1117',
        show: false,
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            preload: path.join(__dirname, 'preload.js')
        }
    });

    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));

    mainWindow.once('ready-to-show', () => {
        debug('WINDOW', 'Window ready to show');
        mainWindow.show();
    });

    // Always open DevTools for debugging
    if (args.includes('--dev') || DEBUG) {
        mainWindow.webContents.openDevTools();
        debug('WINDOW', 'DevTools opened');
    }

    mainWindow.on('closed', () => {
        debug('WINDOW', 'Window closed');
        mainWindow = null;
        stopWatching();
    });

    debug('WINDOW', 'Window creation complete');
}

// === IPC Handlers ===

ipcMain.handle('select-project', async () => {
    debug('IPC', 'select-project called');

    const result = await dialog.showOpenDialog(mainWindow, {
        properties: ['openDirectory'],
        title: 'Select Project Directory'
    });

    debug('IPC', 'Dialog result', { canceled: result.canceled, paths: result.filePaths });

    if (!result.canceled && result.filePaths.length > 0) {
        const selectedPath = result.filePaths[0];
        const statePath = path.join(selectedPath, '.claude-shared-state');

        if (fs.existsSync(statePath)) {
            projectPath = selectedPath;
            debug('IPC', 'Project selected successfully', { projectPath });
            startWatching();
            return { success: true, path: selectedPath };
        } else {
            debug('IPC', 'Missing .claude-shared-state directory', { selectedPath });
            return { success: false, error: 'Missing .claude-shared-state directory' };
        }
    }
    return { success: false, error: 'No directory selected' };
});

ipcMain.handle('get-project', () => {
    debug('IPC', 'get-project called', { projectPath });
    if (projectPath) {
        return { path: projectPath, name: path.basename(projectPath) };
    }
    return null;
});

ipcMain.handle('get-state', async (event, filename) => {
    debug('IPC', 'get-state called', { filename });
    const filePath = getStatePath(filename);
    if (!filePath) {
        debug('IPC', 'get-state: no project path');
        return null;
    }
    try {
        const content = fs.readFileSync(filePath, 'utf-8');
        const data = JSON.parse(content);
        debug('IPC', 'get-state success', { filename, dataKeys: Object.keys(data || {}) });
        return data;
    } catch (e) {
        debug('IPC', 'get-state error', { filename, error: e.message });
        return null;
    }
});

ipcMain.handle('get-activity-log', async (event, lines = 100) => {
    debug('IPC', 'get-activity-log called', { lines });
    const logPath = getLogPath();
    if (!logPath) {
        debug('IPC', 'get-activity-log: no log path');
        return [];
    }
    try {
        const content = fs.readFileSync(logPath, 'utf-8');
        const logLines = content.split('\n').filter(l => l.trim()).slice(-lines);
        debug('IPC', 'get-activity-log success', { lineCount: logLines.length });
        return logLines;
    } catch (e) {
        debug('IPC', 'get-activity-log error', { error: e.message });
        return [];
    }
});

ipcMain.handle('write-state', async (event, { filename, data }) => {
    debug('IPC', 'write-state called', { filename, dataKeys: Object.keys(data || {}) });
    const filePath = getStatePath(filename);
    if (!filePath) {
        debug('IPC', 'write-state: no project selected');
        return { success: false, error: 'No project selected' };
    }
    try {
        fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
        debug('IPC', 'write-state success', { filename });
        return { success: true };
    } catch (e) {
        debug('IPC', 'write-state error', { filename, error: e.message });
        return { success: false, error: e.message };
    }
});

ipcMain.handle('get-debug-log', () => {
    return debugLog;
});

ipcMain.handle('check-files', async () => {
    debug('IPC', 'check-files called');

    if (!projectPath) {
        return { error: 'No project selected' };
    }

    const stateDir = path.join(projectPath, '.claude-shared-state');
    const logDir = path.join(projectPath, '.claude', 'logs');

    const result = {
        projectPath,
        stateDir: {
            exists: fs.existsSync(stateDir),
            files: []
        },
        logDir: {
            exists: fs.existsSync(logDir),
            files: []
        }
    };

    if (result.stateDir.exists) {
        try {
            result.stateDir.files = fs.readdirSync(stateDir).map(f => {
                const fp = path.join(stateDir, f);
                const stat = fs.statSync(fp);
                let preview = null;
                try {
                    const content = fs.readFileSync(fp, 'utf-8');
                    preview = content.slice(0, 200);
                } catch (e) { }
                return {
                    name: f,
                    size: stat.size,
                    modified: stat.mtime.toISOString(),
                    preview
                };
            });
        } catch (e) {
            result.stateDir.error = e.message;
        }
    }

    if (result.logDir.exists) {
        try {
            result.logDir.files = fs.readdirSync(logDir).map(f => {
                const fp = path.join(logDir, f);
                const stat = fs.statSync(fp);
                return {
                    name: f,
                    size: stat.size,
                    modified: stat.mtime.toISOString()
                };
            });
        } catch (e) {
            result.logDir.error = e.message;
        }
    }

    debug('IPC', 'check-files result', result);
    return result;
});

// === File Watching ===

function startWatching() {
    debug('WATCH', 'Starting file watchers');
    stopWatching();

    const stateDir = path.join(projectPath, '.claude-shared-state');
    debug('WATCH', 'Watching state directory', { stateDir, exists: fs.existsSync(stateDir) });

    stateWatcher = chokidar.watch(stateDir, {
        persistent: true,
        ignoreInitial: true,
        awaitWriteFinish: { stabilityThreshold: 100 }
    });

    stateWatcher.on('change', (filePath) => {
        const filename = path.basename(filePath);
        debug('WATCH', 'State file changed', { filename, filePath });
        mainWindow?.webContents.send('state-changed', filename);
    });

    stateWatcher.on('add', (filePath) => {
        const filename = path.basename(filePath);
        debug('WATCH', 'State file added', { filename });
    });

    stateWatcher.on('error', (error) => {
        debug('WATCH', 'State watcher error', { error: error.message });
    });

    stateWatcher.on('ready', () => {
        debug('WATCH', 'State watcher ready');
    });

    const logPath = getLogPath();
    debug('WATCH', 'Checking log path', { logPath, exists: logPath ? fs.existsSync(logPath) : false });

    if (logPath && fs.existsSync(logPath)) {
        let lastSize = fs.statSync(logPath).size;
        debug('WATCH', 'Log file initial size', { lastSize });

        logWatcher = chokidar.watch(logPath, { persistent: true, ignoreInitial: true });

        logWatcher.on('change', () => {
            try {
                const newSize = fs.statSync(logPath).size;
                debug('WATCH', 'Log file changed', { lastSize, newSize, delta: newSize - lastSize });

                if (newSize > lastSize) {
                    const fd = fs.openSync(logPath, 'r');
                    const buffer = Buffer.alloc(newSize - lastSize);
                    fs.readSync(fd, buffer, 0, buffer.length, lastSize);
                    fs.closeSync(fd);

                    const newLines = buffer.toString('utf-8').split('\n').filter(l => l.trim());
                    if (newLines.length > 0) {
                        debug('WATCH', 'Sending new log lines', { count: newLines.length });
                        mainWindow?.webContents.send('new-log-lines', newLines);
                    }
                }
                lastSize = newSize;
            } catch (e) {
                debug('WATCH', 'Log watch error', { error: e.message });
            }
        });

        logWatcher.on('ready', () => {
            debug('WATCH', 'Log watcher ready');
        });
    } else {
        debug('WATCH', 'Log file does not exist, skipping log watcher');
    }

    debug('WATCH', 'Watchers started successfully');
}

function stopWatching() {
    debug('WATCH', 'Stopping watchers');
    stateWatcher?.close();
    logWatcher?.close();
    stateWatcher = null;
    logWatcher = null;
}

// === App Lifecycle ===

app.whenReady().then(() => {
    debug('LIFECYCLE', 'App ready');
    createWindow();

    // Auto-start watching if project was passed
    if (projectPath) {
        debug('LIFECYCLE', 'Auto-starting watchers for project', { projectPath });
        startWatching();
    }
});

app.on('window-all-closed', () => {
    debug('LIFECYCLE', 'All windows closed');
    stopWatching();
    if (process.platform !== 'darwin') {
        app.quit();
    }
});

app.on('activate', () => {
    debug('LIFECYCLE', 'App activated');
    if (BrowserWindow.getAllWindows().length === 0) {
        createWindow();
    }
});

debug('INIT', 'Main process initialization complete');


################################################################################
# FILE: gui/src/main/preload.js
################################################################################

const { contextBridge, ipcRenderer } = require('electron');

// Debug logging bridge
const debugListeners = [];

contextBridge.exposeInMainWorld('electron', {
    // Original APIs
    selectProject: () => ipcRenderer.invoke('select-project'),
    getProject: () => ipcRenderer.invoke('get-project'),
    getState: (filename) => ipcRenderer.invoke('get-state', filename),
    getActivityLog: (lines) => ipcRenderer.invoke('get-activity-log', lines),
    writeState: (filename, data) => ipcRenderer.invoke('write-state', { filename, data }),

    onStateChanged: (callback) => {
        ipcRenderer.on('state-changed', (event, filename) => callback(filename));
    },
    onNewLogLines: (callback) => {
        ipcRenderer.on('new-log-lines', (event, lines) => callback(lines));
    },

    // Debug APIs
    getDebugLog: () => ipcRenderer.invoke('get-debug-log'),
    checkFiles: () => ipcRenderer.invoke('check-files'),
    onDebugLog: (callback) => {
        ipcRenderer.on('debug-log', (event, entry) => callback(entry));
    }
});

console.log('[PRELOAD] Bridge initialized');


################################################################################
# FILE: gui/src/renderer/index.html
################################################################################

<!DOCTYPE html>
<html lang="en">

<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Agent Control Center</title>
    <link rel="stylesheet" href="styles.css">
</head>

<body>
    <div id="app">
        <!-- Connection Screen -->
        <div id="connection-screen" class="screen active">
            <div class="connection-content">
                <div class="logo">🧠</div>
                <h1>Agent Control Center</h1>
                <p>Select a project directory to connect</p>
                <button id="select-project-btn" class="primary-btn">
                    📁 Select Project
                </button>
                <div id="connection-error" class="error-message"></div>
                <div class="requirements">
                    <h4>Requirements:</h4>
                    <ul>
                        <li>Project must be set up with setup.sh</li>
                        <li>.claude-shared-state/ directory must exist</li>
                    </ul>
                </div>
            </div>
        </div>

        <!-- Main Dashboard -->
        <div id="dashboard-screen" class="screen">
            <!-- Header -->
            <header class="header">
                <div class="header-left">
                    <span class="header-icon">🧠</span>
                    <div class="header-text">
                        <h1>Agent Control Center</h1>
                        <span id="project-name" class="project-name"></span>
                    </div>
                </div>
                <div class="header-right">
                    <div class="connection-status">
                        <span class="status-dot connected"></span>
                        <span>Connected</span>
                    </div>
                    <button id="debug-toggle-btn" class="debug-btn">🐛</button>
                    <button id="change-project-btn" class="secondary-btn">Change</button>
                </div>
            </header>

            <!-- Command Bar -->
            <div class="command-bar-wrapper">
                <div id="clarification-banner" class="clarification-banner hidden">
                    <span class="clarification-icon">❓</span>
                    <div class="clarification-content">
                        <span class="clarification-label">Master-2 needs clarification:</span>
                        <span id="clarification-question"></span>
                    </div>
                </div>
                <div class="command-bar">
                    <span class="command-icon">⌨️</span>
                    <input type="text" id="command-input" placeholder="Tell Master-1 what you want..." />
                    <button id="send-btn" class="send-btn">↑</button>
                </div>
            </div>

            <!-- Main Content -->
            <main class="main-content">
                <!-- Master Agents Row -->
                <section class="masters-section">
                    <div class="master-cards">
                        <div class="master-card master-1" data-master="1">
                            <div class="master-header">
                                <span class="master-icon">💬</span>
                                <div class="master-info">
                                    <strong>Master-1</strong>
                                    <small>Interface</small>
                                </div>
                                <span class="master-status-dot ready" title="Always ready"></span>
                            </div>
                            <p id="m1-status">Ready for input</p>
                        </div>
                        <div class="master-card master-2" data-master="2">
                            <div class="master-header">
                                <span class="master-icon">🔨</span>
                                <div class="master-info">
                                    <strong>Master-2</strong>
                                    <small>Architect</small>
                                </div>
                                <span id="m2-ready-dot" class="master-status-dot scanning"
                                    title="Scanning codebase..."></span>
                            </div>
                            <p id="m2-status">Scanning codebase...</p>
                        </div>
                        <div class="master-card master-3" data-master="3">
                            <div class="master-header">
                                <span class="master-icon">📋</span>
                                <div class="master-info">
                                    <strong>Master-3</strong>
                                    <small>Allocator</small>
                                </div>
                                <span id="m3-ready-dot" class="master-status-dot scanning"
                                    title="Scanning codebase..."></span>
                            </div>
                            <p id="m3-status">Scanning codebase...</p>
                        </div>
                    </div>
                </section>

                <!-- Workflow Pipeline -->
                <section class="pipeline-section">
                    <h2>📊 Workflow Pipeline</h2>
                    <div class="pipeline">
                        <!-- Stage 1: Input from User -->
                        <div class="pipeline-stage" id="stage-input" data-stage="input">
                            <div class="stage-header">
                                <span class="stage-icon">📝</span>
                                <span>Your Request</span>
                                <span class="stage-count" id="input-count">0</span>
                            </div>
                            <div class="stage-desc">Master-1 receives</div>
                            <div class="stage-items" id="input-items"></div>
                        </div>

                        <div class="pipeline-arrow">→</div>

                        <!-- Stage 2: Decomposition by M2 -->
                        <div class="pipeline-stage" id="stage-decomp" data-stage="decomp">
                            <div class="stage-header">
                                <span class="stage-icon">🔨</span>
                                <span>Decomposing</span>
                                <span class="stage-count" id="decomp-count">0</span>
                            </div>
                            <div class="stage-desc">Master-2 breaks down</div>
                            <div class="stage-items" id="decomp-items"></div>
                        </div>

                        <div class="pipeline-arrow">→</div>

                        <!-- Stage 3: Task Queue from M3 -->
                        <div class="pipeline-stage" id="stage-queue" data-stage="queue">
                            <div class="stage-header">
                                <span class="stage-icon">📋</span>
                                <span>Task Queue</span>
                                <span class="stage-count" id="queue-count">0</span>
                            </div>
                            <div class="stage-desc">Master-3 assigns</div>
                            <div class="stage-items" id="queue-items"></div>
                        </div>

                        <div class="pipeline-arrow">→</div>

                        <!-- Stage 4: Active Work -->
                        <div class="pipeline-stage" id="stage-active" data-stage="active">
                            <div class="stage-header">
                                <span class="stage-icon">⚙️</span>
                                <span>Active</span>
                                <span class="stage-count" id="active-count">0</span>
                            </div>
                            <div class="stage-desc">Workers executing</div>
                            <div class="stage-items" id="active-items"></div>
                        </div>
                    </div>
                </section>

                <!-- Bottom: Workers + Activity -->
                <div class="bottom-row">
                    <!-- Worker Pool -->
                    <section class="worker-pool">
                        <div class="section-header">
                            <h2>👥 Workers <span id="worker-summary"></span></h2>
                            <button class="collapse-btn" data-target="worker-grid">−</button>
                        </div>
                        <div id="worker-grid" class="worker-grid"></div>
                    </section>

                    <!-- Activity Feed -->
                    <section class="activity-feed">
                        <div class="section-header">
                            <h2>📜 Activity</h2>
                            <label class="autoscroll-toggle">
                                <input type="checkbox" id="autoscroll" checked />
                                Auto
                            </label>
                        </div>
                        <div id="activity-log" class="activity-log"></div>
                    </section>
                </div>
            </main>

            <!-- Detail Panel (slide-out) -->
            <div id="detail-panel" class="detail-panel hidden">
                <div class="detail-header">
                    <h3 id="detail-title">Details</h3>
                    <button id="close-detail-btn" class="close-btn">×</button>
                </div>
                <div id="detail-content" class="detail-content"></div>
            </div>

            <!-- Debug Panel (collapsible) -->
            <div id="debug-panel" class="debug-panel hidden">
                <div class="debug-header">
                    <h2>🐛 Debug</h2>
                    <div class="debug-controls">
                        <button id="refresh-files-btn" class="debug-ctrl-btn">🔄</button>
                        <label class="debug-autoscroll">
                            <input type="checkbox" id="debug-autoscroll" checked />
                            Auto
                        </label>
                    </div>
                </div>

                <div class="debug-content">
                    <div class="debug-section">
                        <h3>📁 Files</h3>
                        <div id="files-list" class="files-list-container"></div>
                    </div>
                    <div class="debug-section">
                        <h3>📊 State</h3>
                        <pre id="raw-state-display" class="raw-state"></pre>
                    </div>
                    <div class="debug-section debug-log-section">
                        <h3>📝 Log</h3>
                        <div id="debug-log-list" class="debug-log-list"></div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script src="app.js"></script>
</body>

</html>

################################################################################
# FILE: gui/src/renderer/styles.css
################################################################################

/* === CSS Variables === */
:root {
    --bg-primary: #0d1117;
    --bg-secondary: #161b22;
    --bg-tertiary: #21262d;
    --bg-card: #1c2128;

    --text-primary: #e6edf3;
    --text-secondary: #8b949e;
    --text-muted: #6e7681;

    --accent-green: #3fb950;
    --accent-blue: #58a6ff;
    --accent-purple: #a371f7;
    --accent-orange: #d29922;
    --accent-red: #f85149;
    --accent-yellow: #e3b341;

    --border-color: #30363d;
    --border-radius: 6px;

    --master-1: #3fb950;
    --master-2: #a371f7;
    --master-3: #d29922;

    --shadow: 0 4px 12px rgba(0, 0, 0, 0.4);
}

/* === Reset & Base === */
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg-primary);
    color: var(--text-primary);
    line-height: 1.4;
    overflow: hidden;
    font-size: 13px;
}

#app {
    height: 100vh;
    display: flex;
    flex-direction: column;
}

.screen {
    display: none;
    height: 100%;
}

.screen.active {
    display: flex;
    flex-direction: column;
}

/* === Connection Screen === */
#connection-screen {
    align-items: center;
    justify-content: center;
    background: linear-gradient(135deg, var(--bg-primary) 0%, #1a1a2e 100%);
}

.connection-content {
    text-align: center;
    padding: 32px;
}

.logo {
    font-size: 48px;
    margin-bottom: 12px;
}

.connection-content h1 {
    font-size: 24px;
    margin-bottom: 6px;
}

.connection-content p {
    color: var(--text-secondary);
    margin-bottom: 20px;
    font-size: 13px;
}

.primary-btn {
    background: linear-gradient(135deg, var(--accent-blue), var(--accent-purple));
    color: white;
    border: none;
    padding: 12px 24px;
    font-size: 14px;
    border-radius: var(--border-radius);
    cursor: pointer;
    transition: transform 0.2s, box-shadow 0.2s;
}

.primary-btn:hover {
    transform: translateY(-2px);
    box-shadow: 0 6px 20px rgba(88, 166, 255, 0.3);
}

.secondary-btn {
    background: var(--bg-tertiary);
    color: var(--text-primary);
    border: 1px solid var(--border-color);
    padding: 6px 12px;
    font-size: 12px;
    border-radius: var(--border-radius);
    cursor: pointer;
}

.error-message {
    color: var(--accent-red);
    margin-top: 12px;
    font-size: 12px;
}

.requirements {
    margin-top: 24px;
    padding: 12px;
    background: var(--bg-secondary);
    border-radius: var(--border-radius);
    text-align: left;
    font-size: 12px;
}

.requirements h4 {
    color: var(--text-secondary);
    font-size: 10px;
    text-transform: uppercase;
    margin-bottom: 6px;
}

.requirements ul {
    list-style: none;
    color: var(--text-muted);
}

.requirements li::before {
    content: "• ";
}

/* === Header === */
.header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 16px;
    background: var(--bg-secondary);
    border-bottom: 1px solid var(--border-color);
    -webkit-app-region: drag;
    flex-shrink: 0;
}

.header button {
    -webkit-app-region: no-drag;
}

.header-left {
    display: flex;
    align-items: center;
    gap: 10px;
}

.header-icon {
    font-size: 20px;
}

.header-text h1 {
    font-size: 14px;
    font-weight: 600;
}

.project-name {
    font-size: 11px;
    color: var(--text-secondary);
}

.header-right {
    display: flex;
    align-items: center;
    gap: 10px;
}

.connection-status {
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: 11px;
    color: var(--text-secondary);
}

.status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--accent-red);
}

.status-dot.connected {
    background: var(--accent-green);
    animation: pulse 2s infinite;
}

@keyframes pulse {

    0%,
    100% {
        opacity: 1;
    }

    50% {
        opacity: 0.5;
    }
}

/* === Command Bar === */
.command-bar-wrapper {
    padding: 10px 16px;
    background: var(--bg-secondary);
    flex-shrink: 0;
}

.clarification-banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    background: rgba(210, 153, 34, 0.15);
    border: 1px solid rgba(210, 153, 34, 0.3);
    border-radius: var(--border-radius);
    margin-bottom: 8px;
    font-size: 12px;
}

.clarification-banner.hidden {
    display: none;
}

.clarification-icon {
    font-size: 16px;
}

.clarification-label {
    color: var(--accent-orange);
    font-size: 11px;
}

#clarification-question {
    font-weight: 500;
}

.command-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 8px;
}

.command-icon {
    font-size: 14px;
    opacity: 0.6;
}

#command-input {
    flex: 1;
    background: none;
    border: none;
    color: var(--text-primary);
    font-size: 13px;
    outline: none;
}

#command-input::placeholder {
    color: var(--text-muted);
}

.send-btn {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    border: none;
    background: var(--accent-blue);
    color: white;
    font-size: 14px;
    font-weight: bold;
    cursor: pointer;
}

.send-btn:disabled {
    background: var(--bg-tertiary);
    color: var(--text-muted);
}

/* === Main Content === */
.main-content {
    flex: 1;
    overflow-y: auto;
    padding: 12px 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    min-height: 0;
}

section h2 {
    font-size: 12px;
    font-weight: 600;
    margin-bottom: 8px;
    color: var(--text-secondary);
}

.section-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 8px;
}

.section-header h2 {
    margin-bottom: 0;
}

.collapse-btn {
    background: none;
    border: none;
    color: var(--text-muted);
    font-size: 14px;
    cursor: pointer;
    padding: 2px 6px;
}

.collapsed {
    display: none !important;
}

/* === Master Cards === */
.masters-section {
    flex-shrink: 0;
}

.master-cards {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 10px;
}

.master-card {
    padding: 10px 12px;
    background: var(--bg-card);
    border-radius: var(--border-radius);
    border-left: 3px solid transparent;
    cursor: pointer;
    transition: background 0.2s;
}

.master-card:hover {
    background: var(--bg-tertiary);
}

.master-card.master-1 {
    border-left-color: var(--master-1);
}

.master-card.master-2 {
    border-left-color: var(--master-2);
}

.master-card.master-3 {
    border-left-color: var(--master-3);
}

.master-header {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 4px;
}

.master-icon {
    font-size: 16px;
}

.master-info {
    flex: 1;
}

.master-info strong {
    font-size: 12px;
}

.master-info small {
    display: block;
    font-size: 10px;
    color: var(--text-muted);
}

.master-status-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    flex-shrink: 0;
}

.master-status-dot.ready {
    background: var(--accent-green);
    box-shadow: 0 0 6px var(--accent-green);
}

.master-status-dot.scanning {
    background: var(--text-muted);
    animation: scan-pulse 1.5s infinite;
}

@keyframes scan-pulse {

    0%,
    100% {
        opacity: 0.4;
    }

    50% {
        opacity: 1;
    }
}

.master-card p {
    font-size: 11px;
    color: var(--text-secondary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

/* === Pipeline === */
.pipeline-section {
    flex-shrink: 0;
}

.pipeline {
    display: flex;
    align-items: stretch;
    gap: 6px;
    overflow-x: auto;
}

.pipeline-stage {
    flex: 1;
    min-width: 120px;
    background: var(--bg-card);
    border-radius: var(--border-radius);
    padding: 10px;
    display: flex;
    flex-direction: column;
}

.stage-header {
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: 11px;
    color: var(--text-primary);
    margin-bottom: 4px;
    font-weight: 600;
}

.stage-icon {
    font-size: 12px;
}

.stage-count {
    margin-left: auto;
    background: var(--bg-tertiary);
    padding: 1px 5px;
    border-radius: 8px;
    font-size: 10px;
}

.stage-desc {
    font-size: 9px;
    color: var(--text-muted);
    margin-bottom: 6px;
}

.stage-items {
    display: flex;
    flex-direction: column;
    gap: 4px;
    flex: 1;
    min-height: 30px;
}

.stage-item {
    padding: 6px 8px;
    background: var(--bg-tertiary);
    border-radius: 4px;
    font-size: 10px;
}

.stage-item.clickable {
    cursor: pointer;
    transition: background 0.2s;
}

.stage-item.clickable:hover {
    background: var(--border-color);
}

.stage-item.empty {
    color: var(--text-muted);
    font-style: italic;
}

.stage-item.more {
    color: var(--text-muted);
    text-align: center;
}

.stage-item-title {
    font-weight: 500;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.stage-item-subtitle {
    color: var(--text-muted);
    font-size: 9px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.stage-item.request {
    border-left: 2px solid var(--master-1);
}

.stage-item.task {
    border-left: 2px solid var(--accent-blue);
}

.stage-item.worker {
    border-left: 2px solid var(--accent-purple);
}

.pipeline-arrow {
    color: var(--text-muted);
    font-size: 16px;
    display: flex;
    align-items: center;
    flex-shrink: 0;
}

/* === Bottom Row === */
.bottom-row {
    display: grid;
    grid-template-columns: 1.5fr 1fr;
    gap: 12px;
    flex: 1;
    min-height: 0;
}

/* === Worker Pool === */
.worker-pool {
    display: flex;
    flex-direction: column;
    min-height: 0;
}

.worker-pool h2 span {
    font-weight: normal;
    font-size: 11px;
    color: var(--text-muted);
}

.worker-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
    gap: 8px;
    overflow-y: auto;
    flex: 1;
}

.no-workers {
    color: var(--text-muted);
    font-style: italic;
    padding: 12px;
}

.worker-card {
    padding: 10px;
    background: var(--bg-card);
    border-radius: var(--border-radius);
    border: 1px solid var(--border-color);
    cursor: pointer;
    transition: border-color 0.2s, background 0.2s;
}

.worker-card:hover {
    background: var(--bg-tertiary);
}

.worker-card.busy {
    border-color: var(--accent-blue);
}

.worker-card.dead {
    border-color: var(--accent-red);
    background: rgba(248, 81, 73, 0.1);
}

.worker-card.completed {
    border-color: var(--accent-green);
}

.worker-card.resetting {
    border-color: var(--accent-orange);
}

.worker-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 6px;
}

.worker-id {
    display: flex;
    align-items: center;
    gap: 5px;
    font-size: 11px;
    font-weight: 600;
    font-family: monospace;
}

.worker-status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
}

.worker-status-dot.idle {
    background: var(--text-muted);
}

.worker-status-dot.busy {
    background: var(--accent-blue);
}

.worker-status-dot.dead {
    background: var(--accent-red);
}

.worker-status-dot.completed,
.worker-status-dot.completed_task {
    background: var(--accent-green);
}

.worker-status-dot.resetting {
    background: var(--accent-orange);
}

.worker-heartbeat {
    font-size: 9px;
    animation: heartbeat 1s infinite;
}

@keyframes heartbeat {

    0%,
    100% {
        transform: scale(1);
    }

    50% {
        transform: scale(1.15);
    }
}

.worker-heartbeat.stale {
    opacity: 0.3;
    animation: none;
}

.worker-domain {
    display: inline-block;
    padding: 1px 6px;
    background: var(--bg-tertiary);
    border-radius: 8px;
    font-size: 9px;
    color: var(--text-secondary);
    margin-bottom: 4px;
}

.worker-task {
    font-size: 10px;
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    margin-bottom: 6px;
}

.worker-progress {
    height: 3px;
    background: var(--bg-tertiary);
    border-radius: 2px;
    overflow: hidden;
}

.worker-progress-bar {
    height: 100%;
    background: linear-gradient(90deg, var(--accent-green), var(--accent-yellow), var(--accent-orange), var(--accent-red));
    background-size: 400% 100%;
    transition: width 0.3s;
}

.worker-progress-label {
    font-size: 9px;
    color: var(--text-muted);
    margin-top: 3px;
    text-align: right;
}

/* === Activity Feed === */
.activity-feed {
    display: flex;
    flex-direction: column;
    min-height: 0;
}

.autoscroll-toggle {
    font-size: 10px;
    color: var(--text-muted);
    display: flex;
    align-items: center;
    gap: 4px;
}

.activity-log {
    flex: 1;
    overflow-y: auto;
    background: var(--bg-card);
    border-radius: var(--border-radius);
    padding: 6px;
    font-family: 'SF Mono', Consolas, monospace;
    font-size: 10px;
}

.log-entry {
    display: flex;
    gap: 6px;
    padding: 3px 4px;
    border-radius: 3px;
}

.log-entry:hover {
    background: var(--bg-tertiary);
}

.log-time {
    color: var(--text-muted);
    min-width: 36px;
}

.log-agent {
    padding: 0px 4px;
    border-radius: 2px;
    font-size: 9px;
    font-weight: 600;
    min-width: 24px;
    text-align: center;
}

.log-agent.m-1 {
    background: var(--master-1);
    color: black;
}

.log-agent.m-2 {
    background: var(--master-2);
    color: black;
}

.log-agent.m-3 {
    background: var(--master-3);
    color: black;
}

.log-agent.worker {
    background: var(--accent-blue);
    color: black;
}

.log-action {
    font-weight: 600;
    min-width: 50px;
}

.log-action.complete {
    color: var(--accent-green);
}

.log-action.allocate {
    color: var(--accent-blue);
}

.log-action.reset {
    color: var(--accent-orange);
}

.log-action.error {
    color: var(--accent-red);
}

.log-details {
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
}

/* === Detail Panel === */
.detail-panel {
    position: fixed;
    top: 0;
    right: 0;
    width: 320px;
    height: 100%;
    background: var(--bg-secondary);
    border-left: 1px solid var(--border-color);
    display: flex;
    flex-direction: column;
    z-index: 900;
    box-shadow: -4px 0 20px rgba(0, 0, 0, 0.4);
}

.detail-panel.hidden {
    display: none;
}

.detail-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-color);
}

.detail-header h3 {
    font-size: 14px;
    margin: 0;
}

.close-btn {
    background: none;
    border: none;
    color: var(--text-secondary);
    font-size: 20px;
    cursor: pointer;
    padding: 0 4px;
}

.close-btn:hover {
    color: var(--text-primary);
}

.detail-content {
    flex: 1;
    overflow-y: auto;
    padding: 12px 16px;
}

.detail-section {
    margin-bottom: 16px;
}

.detail-section label {
    display: block;
    font-size: 10px;
    color: var(--text-muted);
    text-transform: uppercase;
    margin-bottom: 4px;
}

.detail-value {
    font-size: 12px;
    color: var(--text-primary);
    word-break: break-word;
}

.detail-value.status-pending_decomposition {
    color: var(--accent-orange);
}

.detail-value.status-busy {
    color: var(--accent-blue);
}

.detail-value.status-idle {
    color: var(--text-muted);
}

.detail-value.status-completed_task {
    color: var(--accent-green);
}

.detail-value.status-dead {
    color: var(--accent-red);
}

.detail-json {
    background: var(--bg-card);
    padding: 8px;
    border-radius: 4px;
    font-family: 'SF Mono', Consolas, monospace;
    font-size: 9px;
    overflow-x: auto;
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 200px;
    overflow-y: auto;
}

/* === Debug Button === */
.debug-btn {
    background: rgba(248, 81, 73, 0.2);
    color: var(--accent-red);
    border: 1px solid var(--accent-red);
    padding: 6px 10px;
    font-size: 12px;
    border-radius: var(--border-radius);
    cursor: pointer;
}

.debug-btn:hover {
    background: rgba(248, 81, 73, 0.4);
}

/* === Debug Panel === */
.debug-panel {
    position: fixed;
    bottom: 0;
    left: 0;
    right: 0;
    height: 35vh;
    background: var(--bg-primary);
    border-top: 2px solid var(--accent-red);
    display: flex;
    flex-direction: column;
    z-index: 1000;
    box-shadow: 0 -4px 20px rgba(0, 0, 0, 0.5);
}

.debug-panel.hidden {
    display: none;
}

.debug-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 16px;
    background: var(--bg-secondary);
    border-bottom: 1px solid var(--border-color);
}

.debug-header h2 {
    font-size: 12px;
    color: var(--accent-red);
    margin: 0;
}

.debug-controls {
    display: flex;
    gap: 12px;
    align-items: center;
}

.debug-ctrl-btn {
    background: var(--bg-tertiary);
    color: var(--text-primary);
    border: 1px solid var(--border-color);
    padding: 4px 8px;
    font-size: 11px;
    border-radius: 4px;
    cursor: pointer;
}

.debug-autoscroll {
    font-size: 10px;
    color: var(--text-muted);
    display: flex;
    align-items: center;
    gap: 4px;
}

.debug-content {
    flex: 1;
    display: grid;
    grid-template-columns: 1fr 1fr 2fr;
    gap: 1px;
    background: var(--border-color);
    overflow: hidden;
}

.debug-section {
    background: var(--bg-secondary);
    padding: 8px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
}

.debug-section h3 {
    font-size: 10px;
    color: var(--text-secondary);
    margin-bottom: 6px;
}

.files-list-container {
    flex: 1;
    overflow-y: auto;
    font-size: 10px;
}

.files-section {
    padding: 4px 0;
    border-bottom: 1px solid var(--border-color);
}

.files-list {
    margin-top: 4px;
}

.file-item {
    display: flex;
    gap: 6px;
    padding: 2px 4px;
    border-radius: 2px;
}

.file-name {
    flex: 1;
    color: var(--accent-blue);
}

.file-size {
    color: var(--text-muted);
    font-size: 9px;
}

.debug-error {
    color: var(--accent-red);
    padding: 8px;
    font-size: 10px;
}

.raw-state {
    flex: 1;
    overflow: auto;
    font-family: 'SF Mono', Consolas, monospace;
    font-size: 9px;
    background: var(--bg-card);
    padding: 8px;
    border-radius: 4px;
    white-space: pre-wrap;
    word-break: break-all;
}

.debug-log-list {
    flex: 1;
    overflow-y: auto;
    background: var(--bg-card);
    border-radius: 4px;
    font-family: 'SF Mono', Consolas, monospace;
    font-size: 9px;
}

.debug-entry {
    display: flex;
    gap: 4px;
    padding: 2px 6px;
    border-bottom: 1px solid var(--bg-tertiary);
}

.debug-entry.main-source {
    border-left: 2px solid var(--accent-purple);
}

.debug-entry.renderer-source {
    border-left: 2px solid var(--accent-blue);
}

.debug-time {
    color: var(--text-muted);
    min-width: 50px;
}

.debug-source {
    padding: 0 3px;
    border-radius: 2px;
    font-size: 8px;
    font-weight: 600;
    min-width: 50px;
    text-align: center;
}

.main-source .debug-source {
    background: var(--accent-purple);
    color: black;
}

.renderer-source .debug-source {
    background: var(--accent-blue);
    color: black;
}

.debug-cat {
    color: var(--accent-orange);
    min-width: 40px;
}

.debug-msg {
    color: var(--text-primary);
    flex: 1;
}

/* === Responsive Half-Window === */
@media (max-width: 700px) {
    .master-cards {
        grid-template-columns: 1fr;
        gap: 6px;
    }

    .master-card {
        display: flex;
        align-items: center;
        gap: 8px;
    }

    .master-card p {
        flex: 1;
        margin: 0;
    }

    .pipeline {
        flex-direction: column;
    }

    .pipeline-arrow {
        transform: rotate(90deg);
        justify-content: center;
        padding: 4px 0;
    }

    .pipeline-stage {
        min-width: 100%;
    }

    .bottom-row {
        grid-template-columns: 1fr;
    }

    .worker-grid {
        grid-template-columns: repeat(auto-fill, minmax(100px, 1fr));
    }

    .detail-panel {
        width: 100%;
    }

    .debug-content {
        grid-template-columns: 1fr;
    }
}

/* === Utilities === */
.hidden {
    display: none !important;
}

::-webkit-scrollbar {
    width: 6px;
    height: 6px;
}

::-webkit-scrollbar-track {
    background: var(--bg-secondary);
}

::-webkit-scrollbar-thumb {
    background: var(--bg-tertiary);
    border-radius: 3px;
}

::-webkit-scrollbar-thumb:hover {
    background: var(--border-color);
}

################################################################################
# FILE: gui/src/renderer/app.js
################################################################################

// Agent Control Center - Redesigned UI
// With workflow pipeline, master status indicators, and detail panel

// ═══════════════════════════════════════════════════════════════════════════
// DEBUG LOGGING
// ═══════════════════════════════════════════════════════════════════════════
const DEBUG_LOG = [];
const MAX_DEBUG = 500;

function debugLog(category, message, data = null) {
    const entry = {
        timestamp: new Date().toISOString(),
        source: 'RENDERER',
        category,
        message,
        data: data ? JSON.stringify(data).slice(0, 500) : null
    };
    DEBUG_LOG.push(entry);
    if (DEBUG_LOG.length > MAX_DEBUG) DEBUG_LOG.splice(0, DEBUG_LOG.length - MAX_DEBUG);
    console.log(`[${category}] ${message}`, data || '');
    if (elements.debugPanel && !elements.debugPanel.classList.contains('hidden')) {
        appendDebugEntry(entry);
    }
}

function appendDebugEntry(entry) {
    const debugList = document.getElementById('debug-log-list');
    if (!debugList) return;
    const sourceClass = entry.source === 'MAIN' ? 'main-source' : 'renderer-source';
    debugList.insertAdjacentHTML('beforeend', `
        <div class="debug-entry ${sourceClass}">
            <span class="debug-time">${entry.timestamp.split('T')[1]?.slice(0, 8) || ''}</span>
            <span class="debug-source">${entry.source}</span>
            <span class="debug-cat">${entry.category}</span>
            <span class="debug-msg">${entry.message}</span>
        </div>
    `);
    if (document.getElementById('debug-autoscroll')?.checked) {
        debugList.scrollTop = debugList.scrollHeight;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// STATE
// ═══════════════════════════════════════════════════════════════════════════
let state = {
    workers: {},
    taskQueue: null,
    handoff: null,
    clarifications: { questions: [], responses: [] },
    fixQueue: null,
    codebaseMap: null,
    activityLog: [],
    pendingClarification: null,
    projectName: '',
    master2Ready: false,
    master3Ready: false,
    selectedDetail: null
};

// ═══════════════════════════════════════════════════════════════════════════
// DOM ELEMENTS
// ═══════════════════════════════════════════════════════════════════════════
const elements = {
    connectionScreen: document.getElementById('connection-screen'),
    dashboardScreen: document.getElementById('dashboard-screen'),
    selectProjectBtn: document.getElementById('select-project-btn'),
    changeProjectBtn: document.getElementById('change-project-btn'),
    connectionError: document.getElementById('connection-error'),
    projectName: document.getElementById('project-name'),
    commandInput: document.getElementById('command-input'),
    sendBtn: document.getElementById('send-btn'),
    clarificationBanner: document.getElementById('clarification-banner'),
    clarificationQuestion: document.getElementById('clarification-question'),
    m1Status: document.getElementById('m1-status'),
    m2Status: document.getElementById('m2-status'),
    m3Status: document.getElementById('m3-status'),
    m2ReadyDot: document.getElementById('m2-ready-dot'),
    m3ReadyDot: document.getElementById('m3-ready-dot'),
    workerGrid: document.getElementById('worker-grid'),
    workerSummary: document.getElementById('worker-summary'),
    activityLog: document.getElementById('activity-log'),
    autoscroll: document.getElementById('autoscroll'),
    // Pipeline stages
    inputCount: document.getElementById('input-count'),
    decompCount: document.getElementById('decomp-count'),
    queueCount: document.getElementById('queue-count'),
    activeCount: document.getElementById('active-count'),
    inputItems: document.getElementById('input-items'),
    decompItems: document.getElementById('decomp-items'),
    queueItems: document.getElementById('queue-items'),
    activeItems: document.getElementById('active-items'),
    // Detail panel
    detailPanel: document.getElementById('detail-panel'),
    detailTitle: document.getElementById('detail-title'),
    detailContent: document.getElementById('detail-content'),
    closeDetailBtn: document.getElementById('close-detail-btn'),
    // Debug
    debugPanel: document.getElementById('debug-panel'),
    debugToggleBtn: document.getElementById('debug-toggle-btn'),
    refreshFilesBtn: document.getElementById('refresh-files-btn'),
    filesList: document.getElementById('files-list'),
    rawStateDisplay: document.getElementById('raw-state-display')
};

// ═══════════════════════════════════════════════════════════════════════════
// INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════
async function init() {
    debugLog('INIT', 'Starting initialization');
    setupEventListeners();
    await checkConnection();
}

function setupEventListeners() {
    elements.selectProjectBtn?.addEventListener('click', selectProject);
    elements.changeProjectBtn?.addEventListener('click', selectProject);
    elements.sendBtn?.addEventListener('click', sendCommand);
    elements.commandInput?.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendCommand();
        }
    });

    elements.debugToggleBtn?.addEventListener('click', toggleDebugPanel);
    elements.refreshFilesBtn?.addEventListener('click', refreshFiles);
    elements.closeDetailBtn?.addEventListener('click', closeDetailPanel);

    // Collapse buttons
    document.querySelectorAll('.collapse-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const targetId = btn.dataset.target;
            const target = document.getElementById(targetId);
            if (target) {
                target.classList.toggle('collapsed');
                btn.textContent = target.classList.contains('collapsed') ? '+' : '−';
            }
        });
    });

    // Real-time listeners
    window.electron.onStateChanged(handleStateChanged);
    window.electron.onNewLogLines(handleNewLogLines);
    window.electron.onDebugLog((entry) => {
        entry.source = 'MAIN';
        DEBUG_LOG.push(entry);
        if (elements.debugPanel && !elements.debugPanel.classList.contains('hidden')) {
            appendDebugEntry(entry);
        }
    });
}

async function checkConnection() {
    try {
        const project = await window.electron.getProject();
        if (project) {
            state.projectName = project.name;
            elements.projectName.textContent = project.name;
            showDashboard();
            await loadAllState();
        }
    } catch (e) {
        debugLog('CONN', 'Connection check error', { error: e.message });
    }
}

async function selectProject() {
    elements.connectionError.textContent = '';
    try {
        const result = await window.electron.selectProject();
        if (result.success) {
            state.projectName = result.path.split('/').pop();
            elements.projectName.textContent = state.projectName;
            showDashboard();
            await loadAllState();
        } else {
            elements.connectionError.textContent = result.error;
        }
    } catch (e) {
        elements.connectionError.textContent = e.message;
    }
}

function showDashboard() {
    elements.connectionScreen.classList.remove('active');
    elements.dashboardScreen.classList.add('active');
}

// ═══════════════════════════════════════════════════════════════════════════
// STATE LOADING
// ═══════════════════════════════════════════════════════════════════════════
async function loadAllState() {
    debugLog('STATE', 'Loading all state');

    state.workers = await window.electron.getState('worker-status.json') || {};
    state.taskQueue = await window.electron.getState('task-queue.json');
    state.handoff = await window.electron.getState('handoff.json');
    state.clarifications = await window.electron.getState('clarification-queue.json') || { questions: [], responses: [] };
    state.fixQueue = await window.electron.getState('fix-queue.json');
    state.codebaseMap = await window.electron.getState('codebase-map.json');

    const logLines = await window.electron.getActivityLog(100);
    state.activityLog = logLines.map(parseLogLine).filter(Boolean);

    // Check if masters have completed scanning
    checkMasterReadiness();

    renderAll();
    debugLog('STATE', 'State loading complete');
}

async function handleStateChanged(filename) {
    debugLog('STATE', 'File changed', { filename });

    switch (filename) {
        case 'worker-status.json':
            state.workers = await window.electron.getState(filename) || {};
            break;
        case 'task-queue.json':
            state.taskQueue = await window.electron.getState(filename);
            break;
        case 'handoff.json':
            state.handoff = await window.electron.getState(filename);
            break;
        case 'clarification-queue.json':
            state.clarifications = await window.electron.getState(filename) || { questions: [], responses: [] };
            break;
        case 'fix-queue.json':
            state.fixQueue = await window.electron.getState(filename);
            break;
        case 'codebase-map.json':
            state.codebaseMap = await window.electron.getState(filename);
            checkMasterReadiness();
            break;
    }

    renderAll();
    refreshRawState();
}

function handleNewLogLines(lines) {
    const entries = lines.map(parseLogLine).filter(Boolean);
    state.activityLog.push(...entries);
    if (state.activityLog.length > 500) state.activityLog = state.activityLog.slice(-500);

    // Check for master readiness from log entries
    entries.forEach(entry => {
        if (entry.agent.includes('master-2') && entry.action === 'SCAN_COMPLETE') {
            state.master2Ready = true;
        }
        if (entry.agent.includes('master-3') && entry.action === 'SCAN_COMPLETE') {
            state.master3Ready = true;
        }
        // Also check for loop start as indicator
        if (entry.agent.includes('master-2') && entry.details.includes('loop')) {
            state.master2Ready = true;
        }
        if (entry.agent.includes('master-3') && (entry.details.includes('loop') || entry.details.includes('allocat'))) {
            state.master3Ready = true;
        }
    });

    renderActivityLog(entries);
    updateMasterStatus();
}

function checkMasterReadiness() {
    // Master-2 is ready if codebase-map exists and has content
    if (state.codebaseMap && Object.keys(state.codebaseMap).length > 0) {
        state.master2Ready = true;
    }

    // Also check activity log for scan completion
    state.activityLog.forEach(entry => {
        if (entry.agent.includes('master-2') &&
            (entry.action === 'SCAN_COMPLETE' || entry.details.toLowerCase().includes('architect'))) {
            state.master2Ready = true;
        }
        if (entry.agent.includes('master-3') &&
            (entry.action === 'SCAN_COMPLETE' || entry.details.toLowerCase().includes('allocat'))) {
            state.master3Ready = true;
        }
    });
}

// ═══════════════════════════════════════════════════════════════════════════
// COMMAND INPUT
// ═══════════════════════════════════════════════════════════════════════════
async function sendCommand() {
    const text = elements.commandInput.value.trim();
    if (!text) return;

    debugLog('CMD', 'Sending command', { text });
    elements.commandInput.value = '';
    elements.sendBtn.disabled = true;

    try {
        if (state.pendingClarification) {
            const q = { ...state.clarifications };
            q.questions = q.questions.map(qu =>
                qu.request_id === state.pendingClarification.request_id && qu.question === state.pendingClarification.question
                    ? { ...qu, status: 'answered' }
                    : qu
            );
            q.responses = [...q.responses, {
                request_id: state.pendingClarification.request_id,
                question: state.pendingClarification.question,
                answer: text,
                timestamp: new Date().toISOString()
            }];
            await window.electron.writeState('clarification-queue.json', q);
            state.pendingClarification = null;
        } else if (text.toLowerCase().startsWith('fix worker-')) {
            const match = text.match(/fix\s+(worker-\d+):\s*(.+)/i);
            if (match) {
                const [, worker, issue] = match;
                await window.electron.writeState('fix-queue.json', {
                    worker,
                    task: {
                        subject: `FIX: ${issue.slice(0, 50)}`,
                        description: `PRIORITY: URGENT\nDOMAIN: ${state.workers[worker]?.domain || 'unknown'}\n\n${issue}`,
                        request_id: `fix-${Date.now()}`
                    }
                });
            }
        } else {
            const requestId = text.toLowerCase().split(/\s+/).filter(w => w.length > 2).slice(0, 3).join('-') || `request-${Date.now()}`;
            await window.electron.writeState('handoff.json', {
                request_id: requestId,
                timestamp: new Date().toISOString(),
                type: 'feature',
                description: text,
                tasks: [],
                success_criteria: [],
                status: 'pending_decomposition'
            });
        }
    } catch (e) {
        debugLog('CMD', 'Error', { error: e.message });
    }

    elements.sendBtn.disabled = false;
    elements.commandInput.focus();
}

// ═══════════════════════════════════════════════════════════════════════════
// RENDERING
// ═══════════════════════════════════════════════════════════════════════════
function renderAll() {
    renderPipeline();
    renderWorkers();
    renderActivityLogFull();
    updateMasterStatus();
    updateClarificationBanner();
}

function updateMasterStatus() {
    // Master-1 is always ready
    const pendingClars = (state.clarifications.questions || []).filter(q => q.status === 'pending');
    elements.m1Status.textContent = pendingClars.length > 0 ? 'Awaiting clarification'
        : state.handoff?.status === 'pending_decomposition' ? 'Request sent' : 'Ready';

    // Master-2 status
    if (state.master2Ready) {
        elements.m2ReadyDot.classList.remove('scanning');
        elements.m2ReadyDot.classList.add('ready');
        elements.m2ReadyDot.title = 'Ready';
        elements.m2Status.textContent = state.handoff?.status === 'pending_decomposition'
            ? 'Decomposing...'
            : (state.taskQueue?.tasks?.length || 0) > 0
                ? `${state.taskQueue.tasks.length} tasks created`
                : 'Watching';
    } else {
        elements.m2ReadyDot.classList.add('scanning');
        elements.m2ReadyDot.classList.remove('ready');
        elements.m2ReadyDot.title = 'Scanning codebase...';
        elements.m2Status.textContent = 'Scanning codebase...';
    }

    // Master-3 status
    if (state.master3Ready) {
        elements.m3ReadyDot.classList.remove('scanning');
        elements.m3ReadyDot.classList.add('ready');
        elements.m3ReadyDot.title = 'Ready';
        const busyCount = Object.values(state.workers).filter(w => w.status === 'busy').length;
        elements.m3Status.textContent = busyCount > 0 ? `${busyCount} worker${busyCount > 1 ? 's' : ''} active`
            : (state.taskQueue?.tasks?.length || 0) > 0 ? 'Allocating...' : 'Monitoring';
    } else {
        elements.m3ReadyDot.classList.add('scanning');
        elements.m3ReadyDot.classList.remove('ready');
        elements.m3ReadyDot.title = 'Scanning codebase...';
        elements.m3Status.textContent = 'Scanning codebase...';
    }
}

function renderPipeline() {
    // Stage 1: Input (from handoff.json)
    const inputItems = [];
    if (state.handoff?.status === 'pending_decomposition' || state.handoff?.description) {
        inputItems.push({
            id: state.handoff.request_id,
            title: state.handoff.request_id || 'Request',
            subtitle: state.handoff.description?.slice(0, 50) || '',
            type: 'request',
            data: state.handoff
        });
    }
    elements.inputCount.textContent = inputItems.length;
    elements.inputItems.innerHTML = inputItems.length === 0
        ? '<div class="stage-item empty">No pending requests</div>'
        : inputItems.map(item => renderStageItem(item)).join('');

    // Stage 2: Decomposition (show when decomposing)
    const decompItems = [];
    if (state.handoff?.status === 'pending_decomposition') {
        decompItems.push({
            id: 'decomp-' + state.handoff.request_id,
            title: 'Breaking down...',
            subtitle: state.handoff.request_id,
            type: 'decomp',
            data: state.handoff
        });
    }
    elements.decompCount.textContent = decompItems.length;
    elements.decompItems.innerHTML = decompItems.length === 0
        ? '<div class="stage-item empty">—</div>'
        : decompItems.map(item => renderStageItem(item)).join('');

    // Stage 3: Queue (from task-queue.json)
    const queueTasks = (state.taskQueue?.tasks || []).map(t => ({
        id: t.subject,
        title: t.subject || 'Task',
        subtitle: t.domain || t.assigned_to || '',
        type: 'task',
        data: t
    }));
    elements.queueCount.textContent = queueTasks.length;
    elements.queueItems.innerHTML = queueTasks.length === 0
        ? '<div class="stage-item empty">—</div>'
        : queueTasks.slice(0, 5).map(item => renderStageItem(item)).join('') +
        (queueTasks.length > 5 ? `<div class="stage-item more">+${queueTasks.length - 5} more</div>` : '');

    // Stage 4: Active workers
    const activeItems = Object.entries(state.workers)
        .filter(([, w]) => w.status === 'busy')
        .map(([id, w]) => ({
            id: id,
            title: w.current_task || 'Working...',
            subtitle: id.toUpperCase(),
            type: 'worker',
            data: { id, ...w }
        }));
    elements.activeCount.textContent = activeItems.length;
    elements.activeItems.innerHTML = activeItems.length === 0
        ? '<div class="stage-item empty">—</div>'
        : activeItems.map(item => renderStageItem(item)).join('');
}

function renderStageItem(item) {
    const typeClass = item.type === 'request' ? 'request' : item.type === 'task' ? 'task' : item.type === 'worker' ? 'worker' : '';
    return `
        <div class="stage-item clickable ${typeClass}" onclick="showDetail('${item.type}', '${escapeHtml(item.id)}')">
            <div class="stage-item-title">${escapeHtml(item.title)}</div>
            <div class="stage-item-subtitle">${escapeHtml(item.subtitle)}</div>
        </div>
    `;
}

function renderWorkers() {
    const workers = Object.entries(state.workers).sort(([a], [b]) => a.localeCompare(b));
    const active = workers.filter(([, w]) => w.status === 'busy').length;
    elements.workerSummary.textContent = `(${active}/${workers.length})`;

    elements.workerGrid.innerHTML = workers.length === 0
        ? '<div class="no-workers">No workers registered</div>'
        : workers.map(([id, worker]) => {
            const statusClass = worker.status === 'dead' ? 'dead'
                : worker.status === 'busy' ? 'busy'
                    : worker.status === 'completed_task' ? 'completed'
                        : worker.status === 'resetting' ? 'resetting'
                            : 'idle';
            const heartbeatAge = worker.last_heartbeat ? (Date.now() - new Date(worker.last_heartbeat).getTime()) / 1000 : 999;
            const heartbeatClass = heartbeatAge > 90 ? 'stale' : '';
            const progress = Math.min((worker.tasks_completed || 0) / 4 * 100, 100);

            return `
                <div class="worker-card ${statusClass}" onclick="showDetail('worker', '${id}')">
                    <div class="worker-header">
                        <div class="worker-id">
                            <span class="worker-status-dot ${worker.status || 'idle'}"></span>
                            ${id.replace('worker-', 'W')}
                        </div>
                        <span class="worker-heartbeat ${heartbeatClass}">❤️</span>
                    </div>
                    ${worker.domain ? `<span class="worker-domain">${worker.domain}</span>` : ''}
                    <div class="worker-task">${worker.current_task || 'Idle'}</div>
                    <div class="worker-progress">
                        <div class="worker-progress-bar" style="width: ${progress}%"></div>
                    </div>
                    <div class="worker-progress-label">${worker.tasks_completed || 0}/4 tasks</div>
                </div>
            `;
        }).join('');
}

function renderActivityLogFull() {
    elements.activityLog.innerHTML = state.activityLog.map(renderLogEntry).join('');
    if (elements.autoscroll?.checked) {
        elements.activityLog.scrollTop = elements.activityLog.scrollHeight;
    }
}

function renderActivityLog(newEntries) {
    newEntries.forEach(entry => {
        elements.activityLog.insertAdjacentHTML('beforeend', renderLogEntry(entry));
    });
    if (elements.autoscroll?.checked) {
        elements.activityLog.scrollTop = elements.activityLog.scrollHeight;
    }
}

function renderLogEntry(entry) {
    const agentClass = entry.agent.includes('master-1') ? 'm-1'
        : entry.agent.includes('master-2') ? 'm-2'
            : entry.agent.includes('master-3') ? 'm-3'
                : entry.agent.includes('worker') ? 'worker' : '';

    const actionClass = ['COMPLETE', 'DECOMPOSE_DONE', 'MERGE_PR'].includes(entry.action) ? 'complete'
        : ['ALLOCATE', 'REQUEST'].includes(entry.action) ? 'allocate'
            : ['RESET', 'RESET_WORKER', 'CONTEXT_RESET', 'SCAN_COMPLETE'].includes(entry.action) ? 'reset'
                : entry.action.includes('ERROR') || entry.action.includes('DEAD') ? 'error' : '';

    return `
        <div class="log-entry">
            <span class="log-time">${entry.time}</span>
            <span class="log-agent ${agentClass}">${entry.agentShort}</span>
            <span class="log-action ${actionClass}">${entry.action}</span>
            <span class="log-details">${escapeHtml(entry.details)}</span>
        </div>
    `;
}

function updateClarificationBanner() {
    const pending = (state.clarifications.questions || []).find(q => q.status === 'pending');
    if (pending) {
        state.pendingClarification = pending;
        elements.clarificationQuestion.textContent = pending.question;
        elements.clarificationBanner.classList.remove('hidden');
        elements.commandInput.placeholder = 'Type your answer...';
    } else {
        state.pendingClarification = null;
        elements.clarificationBanner.classList.add('hidden');
        elements.commandInput.placeholder = 'Tell Master-1 what you want...';
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// DETAIL PANEL
// ═══════════════════════════════════════════════════════════════════════════
window.showDetail = function (type, id) {
    debugLog('UI', 'Show detail', { type, id });

    let title = '';
    let content = '';

    if (type === 'request') {
        title = '📝 Request Details';
        const data = state.handoff || {};
        content = `
            <div class="detail-section">
                <label>Request ID</label>
                <div class="detail-value">${data.request_id || 'N/A'}</div>
            </div>
            <div class="detail-section">
                <label>Status</label>
                <div class="detail-value status-${data.status}">${data.status || 'N/A'}</div>
            </div>
            <div class="detail-section">
                <label>Description</label>
                <div class="detail-value">${data.description || 'N/A'}</div>
            </div>
            <div class="detail-section">
                <label>Type</label>
                <div class="detail-value">${data.type || 'N/A'}</div>
            </div>
            <div class="detail-section">
                <label>Timestamp</label>
                <div class="detail-value">${data.timestamp || 'N/A'}</div>
            </div>
            <div class="detail-section">
                <label>Raw JSON</label>
                <pre class="detail-json">${JSON.stringify(data, null, 2)}</pre>
            </div>
        `;
    } else if (type === 'task') {
        title = '📋 Task Details';
        const task = (state.taskQueue?.tasks || []).find(t => t.subject === id) || {};
        content = `
            <div class="detail-section">
                <label>Subject</label>
                <div class="detail-value">${task.subject || id}</div>
            </div>
            <div class="detail-section">
                <label>Domain</label>
                <div class="detail-value">${task.domain || 'N/A'}</div>
            </div>
            <div class="detail-section">
                <label>Assigned To</label>
                <div class="detail-value">${task.assigned_to || 'Unassigned'}</div>
            </div>
            <div class="detail-section">
                <label>Description</label>
                <div class="detail-value">${task.description || 'N/A'}</div>
            </div>
            <div class="detail-section">
                <label>Raw JSON</label>
                <pre class="detail-json">${JSON.stringify(task, null, 2)}</pre>
            </div>
        `;
    } else if (type === 'worker') {
        title = `👷 ${id.toUpperCase()} Details`;
        const worker = state.workers[id] || {};
        content = `
            <div class="detail-section">
                <label>Status</label>
                <div class="detail-value status-${worker.status}">${worker.status || 'unknown'}</div>
            </div>
            <div class="detail-section">
                <label>Domain</label>
                <div class="detail-value">${worker.domain || 'None'}</div>
            </div>
            <div class="detail-section">
                <label>Current Task</label>
                <div class="detail-value">${worker.current_task || 'None'}</div>
            </div>
            <div class="detail-section">
                <label>Tasks Completed</label>
                <div class="detail-value">${worker.tasks_completed || 0}/4</div>
            </div>
            <div class="detail-section">
                <label>Last Heartbeat</label>
                <div class="detail-value">${worker.last_heartbeat || 'N/A'}</div>
            </div>
            <div class="detail-section">
                <label>Last PR</label>
                <div class="detail-value">${worker.last_pr ? `<a href="${worker.last_pr}" target="_blank">${worker.last_pr}</a>` : 'None'}</div>
            </div>
            <div class="detail-section">
                <label>Raw JSON</label>
                <pre class="detail-json">${JSON.stringify(worker, null, 2)}</pre>
            </div>
        `;
    } else if (type === 'decomp') {
        title = '🔨 Decomposition In Progress';
        content = `
            <div class="detail-section">
                <label>Request</label>
                <div class="detail-value">${state.handoff?.request_id || 'N/A'}</div>
            </div>
            <div class="detail-section">
                <label>Status</label>
                <div class="detail-value">Master-2 is analyzing the request and breaking it into tasks...</div>
            </div>
            <div class="detail-section">
                <label>Description</label>
                <div class="detail-value">${state.handoff?.description || 'N/A'}</div>
            </div>
        `;
    }

    elements.detailTitle.textContent = title;
    elements.detailContent.innerHTML = content;
    elements.detailPanel.classList.remove('hidden');
    state.selectedDetail = { type, id };
};

function closeDetailPanel() {
    elements.detailPanel.classList.add('hidden');
    state.selectedDetail = null;
}

// ═══════════════════════════════════════════════════════════════════════════
// DEBUG PANEL
// ═══════════════════════════════════════════════════════════════════════════
function toggleDebugPanel() {
    const isHidden = elements.debugPanel.classList.toggle('hidden');
    if (!isHidden) {
        renderDebugLog();
        refreshFiles();
        refreshRawState();
    }
}

function renderDebugLog() {
    const debugList = document.getElementById('debug-log-list');
    if (!debugList) return;
    debugList.innerHTML = DEBUG_LOG.map(entry => {
        const sourceClass = entry.source === 'MAIN' ? 'main-source' : 'renderer-source';
        return `
            <div class="debug-entry ${sourceClass}">
                <span class="debug-time">${entry.timestamp.split('T')[1]?.slice(0, 8) || ''}</span>
                <span class="debug-source">${entry.source || 'RENDERER'}</span>
                <span class="debug-cat">${entry.category}</span>
                <span class="debug-msg">${entry.message}</span>
            </div>
        `;
    }).join('');
    debugList.scrollTop = debugList.scrollHeight;
}

async function refreshFiles() {
    try {
        const result = await window.electron.checkFiles();
        if (result.error) {
            elements.filesList.innerHTML = `<div class="debug-error">${result.error}</div>`;
            return;
        }
        let html = `<div class="files-section"><strong>Project:</strong> ${result.projectPath?.split('/').pop() || 'N/A'}</div>`;
        html += `<div class="files-section"><strong>State:</strong> ${result.stateDir?.exists ? '✅' : '❌'}</div>`;
        if (result.stateDir?.files) {
            html += '<div class="files-list">';
            for (const f of result.stateDir.files) {
                html += `<div class="file-item"><span class="file-name">${f.name}</span><span class="file-size">${f.size}b</span></div>`;
            }
            html += '</div>';
        }
        elements.filesList.innerHTML = html;
    } catch (e) {
        elements.filesList.innerHTML = `<div class="debug-error">${e.message}</div>`;
    }
}

async function refreshRawState() {
    if (elements.rawStateDisplay) {
        elements.rawStateDisplay.textContent = JSON.stringify({
            workers: state.workers,
            taskQueue: state.taskQueue,
            handoff: state.handoff,
            master2Ready: state.master2Ready,
            master3Ready: state.master3Ready
        }, null, 2);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// UTILITIES
// ═══════════════════════════════════════════════════════════════════════════
function parseLogLine(line) {
    const match = line.match(/\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?)\]\s+\[([^\]]+)\]\s+\[([^\]]+)\]\s*(.*)/);
    if (!match) return null;
    const [, timestamp, agent, action, details] = match;
    const date = new Date(timestamp);
    const time = `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}`;
    const agentShort = agent.replace('master-', 'M').replace('worker-', 'W').toUpperCase();
    return { time, agent, agentShort, action, details: details.trim() };
}

function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Initialize
init();


################################################################################
# END OF CONSOLIDATED CODEBASE
################################################################################

END_CONSOLIDATED_CODEBASE

echo "This file contains the complete verbatim codebase."
echo "All code is commented out within a heredoc block."

