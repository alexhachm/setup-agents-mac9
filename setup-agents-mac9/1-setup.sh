#!/usr/bin/env bash
# ============================================================================
# MULTI-AGENT CLAUDE CODE WORKSPACE — MAC/LINUX (THREE-MASTER) v4
# ============================================================================
# Architecture:
#   - Master-1 (Sonnet): Interface (clean context, user comms)
#   - Master-2 (Opus):   Architect (codebase context, triage, decompose, execute Tier 1)
#   - Master-3 (Sonnet): Allocator (domain map, routes tasks, monitors workers)
#   - Workers 1-8 (Opus): Isolated context per domain, strict grouping
#
# v3 improvements over v2:
#   - Restored v7 content lost in v7→v8 rewrite (see README.md)
#   - Fixed Tier 2 race condition with claim-before-assign protocol
#   - Made Master-3 role doc self-contained (no "Same as v1" stubs)
#   - Cross-platform .ps1 launchers auto-generated on Windows (NTFS/WSL detection)
#   - Restored qualitative self-monitoring alongside counter-based triggers
#   - Restored adaptive polling within signal framework
#   - Restored escalation paths, emergency commands, task protocol quick-ref
#
# v2 features (kept):
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
GUI_ONLY=false
HEADLESS=false
ARG_REPO_URL=""
ARG_PROJECT_PATH=""
ARG_WORKERS=""
ARG_SESSION_MODE=""
for arg in "$@"; do
    case $arg in
        --gui) LAUNCH_GUI=true ;;
        --gui-only) GUI_ONLY=true ;;
        --headless) HEADLESS=true ;;
        --repo-url=*) ARG_REPO_URL="${arg#*=}" ;;
        --project-path=*) ARG_PROJECT_PATH="${arg#*=}" ;;
        --workers=*) ARG_WORKERS="${arg#*=}" ;;
        --session-mode=*) ARG_SESSION_MODE="${arg#*=}" ;;
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

# Cross-platform directory link: uses NTFS junctions on Windows, symlinks elsewhere
# Usage: link_dir <link-path> <target-path>
link_dir() {
    local link_path="$1" target_path="$2"
    rm -rf "$link_path"
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        # Windows: create NTFS junction via PowerShell (cmd mklink /J is unreliable from Git Bash)
        local win_link win_target
        win_link=$(cygpath -w "$link_path" 2>/dev/null || echo "$link_path" | sed 's|/|\\|g')
        win_target=$(cd "$target_path" 2>/dev/null && cygpath -w "$(pwd)" 2>/dev/null || cygpath -w "$target_path" 2>/dev/null || echo "$target_path" | sed 's|/|\\|g')
        powershell.exe -Command "New-Item -ItemType Junction -Path '$win_link' -Target '$win_target'" > /dev/null 2>&1
    else
        ln -sf "$target_path" "$link_path"
    fi
}

MAX_WORKERS=8

# ============================================================================
# GUI-ONLY MODE: Just launch the Electron GUI, skip everything else
# ============================================================================
if [ "$GUI_ONLY" = true ]; then
    step "Starting Agent Control Center GUI (gui-only mode)..."
    GUI_DIR="$SCRIPT_DIR/gui"
    if [ ! -d "$GUI_DIR" ]; then
        GUI_DIR="$SCRIPT_DIR/setup-agents-mac7/gui"
    fi
    if [ -d "$GUI_DIR" ]; then
        if [ ! -d "$GUI_DIR/node_modules" ]; then
            echo "   Installing GUI dependencies..."
            (cd "$GUI_DIR" && npm install --silent 2>/dev/null)
        fi
        echo "   Starting control center..."
        (cd "$GUI_DIR" && unset ELECTRON_RUN_AS_NODE && SETUP_SCRIPT_DIR="$SCRIPT_DIR" npm start &)
        sleep 2
        ok "Agent Control Center GUI launched!"
    else
        fail "GUI directory not found"
        exit 1
    fi
    exit 0
fi

# ============================================================================
# 0. PREFLIGHT
# ============================================================================
step "Checking prerequisites..."

if [ ! -d "$SCRIPT_DIR/templates" ] || [ ! -d "$SCRIPT_DIR/scripts" ]; then
    fail "Missing templates/ or scripts/ directory next to setup.sh"
    echo "   Expected structure:"
    echo "     setup.sh"
    echo "     templates/  (commands, docs, agents, state)"
    echo "     scripts/    (state-lock.sh, add-worker.sh, hooks/)"
    exit 1
fi

missing=()
for tool in git node npm gh claude jq; do
    if ! command -v "$tool" &>/dev/null; then
        missing+=("$tool")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    fail "Missing: ${missing[*]}"
    echo "   brew install git node gh jq"
    echo "   npm install -g @anthropic-ai/claude-code"
    exit 1
fi

# On Windows, ensure jq is also available inside WSL (workers run there)
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]] && command -v wsl.exe &>/dev/null; then
    if ! wsl.exe bash -lc 'command -v jq' &>/dev/null; then
        step "Installing jq inside WSL (workers run there)..."
        if wsl.exe bash -c 'mkdir -p ~/bin && curl -sL -o ~/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 && chmod +x ~/bin/jq && ~/bin/jq --version' 2>/dev/null; then
            ok "jq installed in WSL at ~/bin/jq"
        else
            skip "Could not install jq in WSL — workers may fail on JSON operations"
        fi
    fi
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

# Headless mode: use arguments instead of prompts
if [ "$HEADLESS" = true ]; then
    repo_url="$ARG_REPO_URL"
else
    if [ -n "$last_url" ]; then
        read -p "GitHub repo URL [$last_url]: " repo_url
        repo_url="${repo_url:-$last_url}"
    else
        read -p "GitHub repo URL (leave blank for new project): " repo_url
    fi
fi

if [ -n "$repo_url" ]; then
    default_path="$HOME/Desktop/$(basename "$repo_url" .git)"
    if [ "$HEADLESS" = true ]; then
        project_path="${ARG_PROJECT_PATH:-$default_path}"
    else
        read -p "Clone to [$default_path]: " project_path
        project_path="${project_path:-$default_path}"
    fi

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
    if [ "$HEADLESS" = true ]; then
        project_path="${ARG_PROJECT_PATH:-$default_path}"
    else
        read -p "Project path [$default_path]: " project_path
        project_path="${project_path:-$default_path}"
    fi
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

if [ "$HEADLESS" = true ]; then
    worker_count="${ARG_WORKERS:-3}"
else
    read -p "Initial workers [1-$MAX_WORKERS, default 3]: " worker_count
    worker_count="${worker_count:-3}"
fi
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

mkdir -p .claude/agents .claude/commands .claude/hooks .claude/scripts .claude/signals
mkdir -p .claude/knowledge/domain .claude/state/tasks
# .claude/state may be a stale symlink/file/junction from a prior run — clean it first
if [ -e .claude/state ] && [ ! -d .claude/state ]; then rm -f .claude/state; fi
mkdir -p .claude/state

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
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [setup] [INIT] Multi-agent system v3 initialized" > .claude/logs/activity.log
ok "Activity log initialized"

# ============================================================================
# 5. STATE FILES
# ============================================================================
step "Initializing state files..."

echo '{}' > .claude/state/handoff.json
echo '{}' > .claude/state/codebase-map.json
# Build initial worker-status with all workers idle (launched on demand)
echo "{}" | jq --argjson n "$worker_count" '
  [range(1; $n+1)] | reduce .[] as $i ({};
    .["worker-\($i)"] = {"status":"idle","domain":null,"current_task":null,
      "tasks_completed":0,"context_budget":0,"claimed_by":null,"last_heartbeat":null}
  )' > .claude/state/worker-status.json
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

cp "$SCRIPT_DIR/scripts/launch-worker.sh" .claude/scripts/launch-worker.sh
chmod +x .claude/scripts/launch-worker.sh

cp "$SCRIPT_DIR/scripts/worker-sentinel.sh" .claude/scripts/worker-sentinel.sh
chmod +x .claude/scripts/worker-sentinel.sh

ok "Helper scripts created (including signal-wait.sh, launch-worker.sh, worker-sentinel.sh)"

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

# Build list of all paths to trust: project root + all possible worktree paths (wt-1..wt-8)
# Include BOTH Windows and WSL (/mnt/c/...) formats — Claude Code running in WSL sees /mnt/c paths
trust_paths=("$project_path")
for i in $(seq 1 8); do
    trust_paths+=("$project_path/.worktrees/wt-$i")
done
# Add WSL-format paths on Windows (workers run via WSL and see /mnt/c/... paths)
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    wsl_project_path=$(echo "$project_path" | sed 's|^/\([a-zA-Z]\)/|/mnt/\L\1/|; s|^\([A-Z]\):|/mnt/\L\1|; s|\\|/|g')
    trust_paths+=("$wsl_project_path")
    for i in $(seq 1 8); do
        trust_paths+=("$wsl_project_path/.worktrees/wt-$i")
    done
fi

if [ -f "$HOME/.claude/settings.json" ]; then
    cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak"
    if command -v jq &>/dev/null; then
        # Build jq args for all paths
        jq_args=()
        for p in "${trust_paths[@]}"; do
            jq_args+=(--arg "p_${#jq_args[@]}" "$p")
        done
        jq "${jq_args[@]}" '
          .trustedDirectories = ((.trustedDirectories // []) + [$ARGS.positional[]] | unique)
          | .skipDangerousModePermissionPrompt = true
        ' --args "${trust_paths[@]}" "$HOME/.claude/settings.json" > "$HOME/.claude/settings.json.tmp" \
          && mv "$HOME/.claude/settings.json.tmp" "$HOME/.claude/settings.json"
    else
        if ! grep -qF "$project_path" "$HOME/.claude/settings.json" 2>/dev/null; then
            skip "jq not found — add \"$project_path\" to trustedDirectories in ~/.claude/settings.json manually"
        fi
    fi
else
    # Generate initial settings with all trust paths
    printf '{\n  "skipDangerousModePermissionPrompt": true,\n  "trustedDirectories": [\n' > "$HOME/.claude/settings.json"
    for i in "${!trust_paths[@]}"; do
        if [ "$i" -lt $((${#trust_paths[@]} - 1)) ]; then
            printf '    "%s",\n' "${trust_paths[$i]}" >> "$HOME/.claude/settings.json"
        else
            printf '    "%s"\n' "${trust_paths[$i]}" >> "$HOME/.claude/settings.json"
        fi
    done
    printf '  ]\n}\n' >> "$HOME/.claude/settings.json"
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
git commit -m "feat: v3 three-master architecture with tier routing, knowledge system, signal waking, claim-lock coordination" 2>/dev/null || true

ok "Orchestration files committed to $default_branch"

# ============================================================================
# 14. SHARED STATE
# ============================================================================
step "Setting up shared state directory..."

shared_state_dir="$project_path/.claude-shared-state"
mkdir -p "$shared_state_dir" "$shared_state_dir/tasks"

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

# Link .claude/state → .claude-shared-state (junction on Windows, symlink elsewhere)
link_dir .claude/state "$project_path/.claude-shared-state"

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

    # Fix gitdir paths to be relative (works in both Git Bash and WSL)
    echo "gitdir: ../../.git/worktrees/wt-$i" > ".worktrees/wt-$i/.git"
    if [ -f ".git/worktrees/wt-$i/gitdir" ]; then
        echo "../../../.worktrees/wt-$i/.git" > ".git/worktrees/wt-$i/gitdir"
    fi

    link_dir ".worktrees/wt-$i/.claude/state" "$project_path/.claude-shared-state"

    mkdir -p ".worktrees/wt-$i/.claude/logs"
    link_dir ".worktrees/wt-$i/.claude/logs" "$project_path/.claude/logs"

    # Shared knowledge directory so workers read shared knowledge
    link_dir ".worktrees/wt-$i/.claude/knowledge" "$project_path/.claude/knowledge"

    # Shared signals directory
    link_dir ".worktrees/wt-$i/.claude/signals" "$project_path/.claude/signals"

    cp "$SCRIPT_DIR/templates/worker-claude.md" ".worktrees/wt-$i/CLAUDE.md"
done

ok "$worker_count worktrees created (sharing state, knowledge, signals, and logs)"

# ============================================================================
# 16. LAUNCHER SCRIPTS + MANIFEST (v4 — zero baked-in paths)
# ============================================================================
step "Generating launcher scripts and manifest..."

launcher_dir="$project_path/.claude/launchers"
mkdir -p "$launcher_dir"

# ── Helper: generate a self-contained .ps1 launcher (Windows only) ────
# Each .ps1 derives all paths at runtime from $PSScriptRoot (the launchers/ dir).
# No baked-in paths — works regardless of which shell ran setup.
generate_ps1() {
    local id="$1" label="$2" color="$3" model="$4" command="$5" env_prefix="$6" worktree_rel="$7"
    local ps1_file="$launcher_dir/${id}.ps1"

    # Build the cd target: project root, or project root + worktree relative path
    local cd_expr='$WslProject'
    if [ -n "$worktree_rel" ]; then
        cd_expr='$WslProject/'"$worktree_rel"
    fi

    # Build the claude invocation for fresh mode
    local fresh_cmd=""
    if [ -n "$env_prefix" ]; then
        fresh_cmd="env ${env_prefix} claude --model ${model} --dangerously-skip-permissions '${command}'"
    else
        fresh_cmd="claude --model ${model} --dangerously-skip-permissions '${command}'"
    fi

    # Build the claude invocation for continue mode
    local continue_cmd=""
    if [ -n "$env_prefix" ]; then
        continue_cmd="env ${env_prefix} claude --continue --model ${model} --dangerously-skip-permissions"
    else
        continue_cmd="claude --continue --model ${model} --dangerously-skip-permissions"
    fi

    # Write the .ps1 using a QUOTED heredoc (no shell expansion — avoids backtick/dollar conflicts).
    # Then replace __PLACEHOLDERS__ with actual values via sed.
    # PowerShell backtick-dollar (`$) passes literal $ to bash (not expanded by PS).
    # PowerShell $WslProject IS expanded (defined earlier in the script).
    cat > "$ps1_file" << 'PS1_TEMPLATE'
# v4 self-contained launcher for __ID__
# DO NOT add non-ASCII chars. PowerShell 5.1 reads without UTF-8 BOM.
param([switch]$Continue)

# Derive project root from this script location (launchers/ is inside .claude/)
$ProjectDir = (Resolve-Path "$PSScriptRoot\..\..").Path
# Convert Windows path to WSL path in pure PowerShell (avoids wsl.exe backslash-eating bug)
$WslProject = '/mnt/' + $ProjectDir.Substring(0,1).ToLower() + $ProjectDir.Substring(2).Replace('\','/')

Clear-Host
if ($Continue) {
    Write-Host "  __LABEL__ [CONTINUE]" -ForegroundColor __COLOR__
    wsl.exe bash -lc "cd '__CD_EXPR__' && __CONTINUE_CMD__"
} else {
    Write-Host "  __LABEL__" -ForegroundColor __COLOR__
    wsl.exe bash -lc "cd '__CD_EXPR__' && __FRESH_CMD__"
}
$ec = $LASTEXITCODE
if ($ec -ne 0) {
    Write-Host ""
    Write-Host "  AGENT EXITED (code $ec)" -ForegroundColor Red
    Write-Host "  Press Enter to close..." -ForegroundColor DarkGray
    Read-Host | Out-Null
}
PS1_TEMPLATE
    # Replace placeholders with actual values + convert to CRLF
    sed -i \
        -e "s|__ID__|${id}|g" \
        -e "s|__LABEL__|${label}|g" \
        -e "s|__COLOR__|${color}|g" \
        -e "s|__CD_EXPR__|${cd_expr}|g" \
        -e "s|__CONTINUE_CMD__|${continue_cmd}|g" \
        -e "s|__FRESH_CMD__|${fresh_cmd}|g" \
        -e 's/$/\r/' \
        "$ps1_file"
}

# ── Helper: generate a sentinel .ps1 for workers (persistent loop) ────
# Unlike master .ps1 (one-shot), worker .ps1 delegates to worker-sentinel.sh
# which loops forever: idle-wait → run claude → loop back. One terminal, reused.
generate_sentinel_ps1() {
    local worker_num="$1"
    local ps1_file="$launcher_dir/worker-${worker_num}.ps1"

    cat > "$ps1_file" << 'PS1_SENTINEL'
# v5 sentinel launcher for __ID__
# DO NOT add non-ASCII chars. PowerShell 5.1 reads without UTF-8 BOM.
# Persistent loop: idle-wait -> run claude -> loop back. One terminal, reused forever.

$ProjectDir = (Resolve-Path "$PSScriptRoot\..\..").Path
$WslProject = '/mnt/' + $ProjectDir.Substring(0,1).ToLower() + $ProjectDir.Substring(2).Replace('\','/')

Clear-Host
Write-Host "  __ID_UPPER__ SENTINEL" -ForegroundColor Green
# Delegate to bash sentinel script (cross-platform logic lives there)
wsl.exe bash -lc "export PATH=`"`$HOME/bin:`$HOME/.local/bin:`$PATH`"; bash '$WslProject/.claude/scripts/worker-sentinel.sh' __NUM__ '$WslProject'"
$ec = $LASTEXITCODE
if ($ec -ne 0) {
    Write-Host ""
    Write-Host "  SENTINEL EXITED (code $ec)" -ForegroundColor Red
    Write-Host "  Press Enter to close..." -ForegroundColor DarkGray
    Read-Host | Out-Null
}
PS1_SENTINEL

    local id_upper
    id_upper=$(echo "WORKER-${worker_num}" | tr '[:lower:]' '[:upper:]')
    sed -i \
        -e "s|__ID__|worker-${worker_num}|g" \
        -e "s|__ID_UPPER__|${id_upper}|g" \
        -e "s|__NUM__|${worker_num}|g" \
        -e 's/$/\r/' \
        "$ps1_file"
}

# ── Generate .ps1 launchers (Windows only) ────────────────────────────
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    step "Generating .ps1 launchers (v5 — masters one-shot, workers sentinel)..."

    # Masters: one-shot .ps1 (unchanged from v4)
    generate_ps1 "master-1" "I AM MASTER-1 -- YOUR INTERFACE (Sonnet)" "Cyan" \
        "sonnet" "/master-loop" "" ""

    generate_ps1 "master-2" "I AM MASTER-2 -- ARCHITECT (Opus)" "Cyan" \
        "opus" "/scan-codebase" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1" ""

    generate_ps1 "master-3" "I AM MASTER-3 -- ALLOCATOR (Sonnet)" "Yellow" \
        "sonnet" "/scan-codebase-allocator" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1" ""

    # Workers: sentinel .ps1 (persistent loop — one terminal, reused forever)
    for i in $(seq 1 $worker_count); do
        generate_sentinel_ps1 "$i"
    done

    ok ".ps1 launchers generated (v5 — sentinel workers, zero baked paths)"
fi

# ── Generate v4 manifest.json for GUI ─────────────────────────────────
# v4 manifest has NO filesystem paths — only agent identity, model, command, worktree relative dir.
# The GUI and launch scripts derive paths at runtime.
worker_entries=""
for i in $(seq 1 $worker_count); do
    worker_entries="${worker_entries},
    {
      \"id\": \"worker-$i\",
      \"group\": \"workers\",
      \"role\": \"Worker $i (Opus)\",
      \"model\": \"opus\",
      \"command\": \"/worker-loop\",
      \"env\": \"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1\",
      \"worktree\": \".worktrees/wt-$i\"
    }"
done

cat > "$launcher_dir/manifest.json" << MANIFEST
{
  "version": 4,
  "worker_count": $worker_count,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "agents": [
    {
      "id": "master-1",
      "group": "masters",
      "role": "Interface (Sonnet)",
      "model": "sonnet",
      "command": "/master-loop",
      "env": null,
      "worktree": null
    },
    {
      "id": "master-2",
      "group": "masters",
      "role": "Architect (Opus)",
      "model": "opus",
      "command": "/scan-codebase",
      "env": "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1",
      "worktree": null
    },
    {
      "id": "master-3",
      "group": "masters",
      "role": "Allocator (Sonnet)",
      "model": "sonnet",
      "command": "/scan-codebase-allocator",
      "env": "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1",
      "worktree": null
    }${worker_entries}
  ]
}
MANIFEST
ok "v4 manifest.json generated (zero filesystem paths)"

# ============================================================================
# COMPLETE
# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  SETUP COMPLETE (v4)${NC}"
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
echo "TERMINALS AT STARTUP: 3 (masters only — workers launch on demand)"
echo ""

# In headless mode, launching depends on session-mode argument
if [ "$HEADLESS" = true ]; then
    if [ -n "$ARG_SESSION_MODE" ]; then
        launch="Y"
    else
        launch="N"
    fi
else
    read -p "Launch all terminals now? [Y/n]: " launch
    launch="${launch:-Y}"
fi

if [[ "$launch" =~ ^[Yy]$ ]]; then

    echo ""
    echo -e "${CYAN}SESSION CONTEXT${NC}"
    echo ""
    echo "  1) Fresh start  — wipe ALL prior conversation memory and task state"
    echo "  2) Continue      — agents resume their previous sessions (retains context)"
    echo ""
    if [ "$HEADLESS" = true ]; then
        session_mode="${ARG_SESSION_MODE:-1}"
    else
        read -p "Choose [1/2, default 1]: " session_mode
        session_mode="${session_mode:-1}"
    fi

    if [[ "$session_mode" == "2" ]]; then
        step "Continuing previous sessions (preserving context)..."
        rm -rf "$project_path/.claude-shared-state/"*.lockdir 2>/dev/null || true
        rm -f "$project_path/.claude-shared-state/"*.lock 2>/dev/null || true
        CLAUDE_SESSION_FLAG="--continue"
        ok "Sessions preserved — agents will resume where they left off"
    else
        step "Resetting sessions (wiping ALL Claude Code state)..."

        for f in handoff.json codebase-map.json fix-queue.json; do
            echo '{}' > "$project_path/.claude-shared-state/$f" 2>/dev/null || true
        done
        # Pre-populate worker-status with idle entries
        echo "{}" | jq --argjson n "$worker_count" '
          [range(1; $n+1)] | reduce .[] as $i ({};
            .["worker-\($i)"] = {"status":"idle","domain":null,"current_task":null,
              "tasks_completed":0,"context_budget":0,"claimed_by":null,"last_heartbeat":null}
          )' > "$project_path/.claude-shared-state/worker-status.json" 2>/dev/null || true
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
    # TERMINAL LAUNCH (v4 — .ps1 on Windows, inline commands elsewhere)
    # ==================================================================
    step "Launching terminals..."

    launcher_dir="$project_path/.claude/launchers"
    continue_flag=""
    if [ -n "$CLAUDE_SESSION_FLAG" ]; then
        continue_flag="-Continue"
    fi

    # Helper: build a claude command string from manifest-style args
    # Usage: build_claude_cmd <model> <command|""> <env|""> <continue:0|1>
    build_claude_cmd() {
        local model="$1" cmd="$2" env_prefix="$3" is_continue="$4"
        local parts=""
        [ -n "$env_prefix" ] && parts="env $env_prefix "
        if [ "$is_continue" = "1" ]; then
            parts="${parts}claude --continue --model $model --dangerously-skip-permissions"
        else
            parts="${parts}claude --model $model --dangerously-skip-permissions '$cmd'"
        fi
        echo "$parts"
    }

    # ── Platform-specific terminal creation ───────────────────────────
    if [[ "$OSTYPE" == darwin* ]]; then
        # ── macOS: build inline commands from manifest data ──────────
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

        is_cont=0; [ -n "$CLAUDE_SESSION_FLAG" ] && is_cont=1

        m2_cmd="cd '$project_path' && $(build_claude_cmd opus /scan-codebase CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 $is_cont)"
        m3_cmd="cd '$project_path' && $(build_claude_cmd sonnet /scan-codebase-allocator CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 $is_cont)"
        m1_cmd="cd '$project_path' && $(build_claude_cmd sonnet /master-loop '' $is_cont)"

        step "  Preparing setup window..."
        SETUP_WIN_ID=$(osascript -e 'tell application "Terminal" to return id of front window')
        osascript -e "tell application \"Terminal\" to set miniaturized of window id $SETUP_WIN_ID to true"
        sleep 1
        ok "  Setup window minimized (ID: $SETUP_WIN_ID)"

        step "  Creating master windows..."

        osascript -e "tell application \"Terminal\"
            activate
            do script \"$m2_cmd\"
        end tell"
        sleep 2

        osascript -e "tell application \"Terminal\"
            do script \"$m3_cmd\"
        end tell"
        sleep 2

        osascript -e "tell application \"Terminal\"
            do script \"$m1_cmd\"
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

        # ── Launch worker sentinels (minimized) ──
        step "  Launching worker sentinels (minimized)..."
        sentinel_script="$project_path/.claude/scripts/worker-sentinel.sh"
        for i in $(seq 1 $worker_count); do
            sentinel_cmd="export PATH=\"\$HOME/bin:\$HOME/.local/bin:\$PATH\"; bash '$sentinel_script' $i '$project_path'"
            osascript -e "tell application \"Terminal\"
                do script \"$sentinel_cmd\"
            end tell"
            sleep 1
        done
        # Minimize worker windows
        osascript -e "tell application \"Terminal\"
            set wCount to count of windows
            repeat with i from 1 to wCount
                set w to window i
                if name of w contains \"worker-sentinel\" or name of w contains \"IDLE\" then
                    set miniaturized of w to true
                end if
            end repeat
        end tell" 2>/dev/null || true
        ok "  $worker_count worker sentinels launched (minimized, persistent)"

        step "  Restoring windows..."
        osascript -e "tell application \"Terminal\"
            set miniaturized of window id $MASTER_WIN_ID to false
            set miniaturized of window id $SETUP_WIN_ID to false
        end tell" 2>/dev/null || true
        sleep 1
        ok "  All windows restored"

    elif [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        # ── Windows: use .ps1 launchers with optional -Continue flag ──
        step "  Launching master terminals..."

        win_launcher_dir=$(cygpath -w "$launcher_dir" 2>/dev/null || echo "$launcher_dir" | sed 's|/|\\|g')

        if command -v wt.exe &>/dev/null; then
            # Windows Terminal: open all masters as tabs in one window via .ps1
            wt.exe new-tab --title "Master-2 Architect" powershell.exe -ExecutionPolicy Bypass -File "$win_launcher_dir\\master-2.ps1" $continue_flag \; \
                   new-tab --title "Master-3 Allocator" powershell.exe -ExecutionPolicy Bypass -File "$win_launcher_dir\\master-3.ps1" $continue_flag \; \
                   new-tab --title "Master-1 Interface" powershell.exe -ExecutionPolicy Bypass -File "$win_launcher_dir\\master-1.ps1" $continue_flag &
            sleep 3
            ok "  3 master tabs opened in Windows Terminal (v5 .ps1)"

            # ── Launch worker sentinels in a SEPARATE MINIMIZED WT window ──
            # Each worker gets a persistent sentinel tab. Masters wake them via
            # touch .claude/signals/.worker-N-wake (no new terminals ever spawned).
            step "  Launching worker sentinels (minimized)..."
            worker_tabs=""
            for i in $(seq 1 $worker_count); do
                if [ -n "$worker_tabs" ]; then
                    worker_tabs="$worker_tabs \\; "
                fi
                worker_tabs="${worker_tabs}new-tab --title Worker-$i powershell.exe -ExecutionPolicy Bypass -File ${win_launcher_dir}\\worker-${i}.ps1"
            done
            # Start-Process with -WindowStyle Minimized keeps the WT window in the taskbar
            powershell.exe -NoProfile -Command "Start-Process wt.exe -ArgumentList '$worker_tabs' -WindowStyle Minimized"
            sleep 2
            ok "  $worker_count worker sentinels launched (minimized, persistent)"
        else
            # Fallback: use start to open separate PowerShell windows
            start powershell.exe -ExecutionPolicy Bypass -File "$win_launcher_dir\\master-2.ps1" $continue_flag &
            sleep 1
            start powershell.exe -ExecutionPolicy Bypass -File "$win_launcher_dir\\master-3.ps1" $continue_flag &
            sleep 1
            start powershell.exe -ExecutionPolicy Bypass -File "$win_launcher_dir\\master-1.ps1" $continue_flag &
            sleep 1
            ok "  3 master windows opened (separate PowerShell windows)"

            # Launch worker sentinels (separate windows, no WT minimized support)
            step "  Launching worker sentinels..."
            for i in $(seq 1 $worker_count); do
                start powershell.exe -ExecutionPolicy Bypass -File "$win_launcher_dir\\worker-${i}.ps1" &
                sleep 1
            done
            ok "  $worker_count worker sentinels launched"
        fi

    else
        # ── Linux: build inline commands from manifest data ──────────
        step "  Launching master terminals..."

        is_cont=0; [ -n "$CLAUDE_SESSION_FLAG" ] && is_cont=1

        m2_cmd="cd '$project_path' && $(build_claude_cmd opus /scan-codebase CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 $is_cont)"
        m3_cmd="cd '$project_path' && $(build_claude_cmd sonnet /scan-codebase-allocator CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 $is_cont)"
        m1_cmd="cd '$project_path' && $(build_claude_cmd sonnet /master-loop '' $is_cont)"

        launch_in_terminal() {
            local title="$1" cmd="$2"
            if command -v gnome-terminal &>/dev/null; then
                gnome-terminal --title="$title" -- bash -lc "$cmd; exec bash" &
            elif command -v konsole &>/dev/null; then
                konsole --new-tab -e bash -lc "$cmd; exec bash" &
            elif command -v xterm &>/dev/null; then
                xterm -title "$title" -e bash -lc "$cmd; exec bash" &
            elif command -v xfce4-terminal &>/dev/null; then
                xfce4-terminal --title="$title" -e "bash -lc '$cmd; exec bash'" &
            else
                echo "   WARN: No supported terminal emulator found. Run manually: $cmd" >&2
            fi
        }

        launch_in_terminal "Master-2 Architect" "$m2_cmd"
        sleep 1
        launch_in_terminal "Master-3 Allocator" "$m3_cmd"
        sleep 1
        launch_in_terminal "Master-1 Interface" "$m1_cmd"
        sleep 1

        ok "  3 master terminals launched"

        # ── Launch worker sentinels ──
        step "  Launching worker sentinels..."
        sentinel_script="$project_path/.claude/scripts/worker-sentinel.sh"
        for i in $(seq 1 $worker_count); do
            sentinel_cmd="export PATH=\"\$HOME/bin:\$HOME/.local/bin:\$PATH\"; bash '$sentinel_script' $i '$project_path'"
            launch_in_terminal "Worker-$i Sentinel" "$sentinel_cmd"
            sleep 1
        done
        ok "  $worker_count worker sentinels launched (persistent)"
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ALL TERMINALS LAUNCHED (v5)${NC}"
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
    echo "WORKERS ($worker_count worktrees ready — launch ON DEMAND):"
    for i in $(seq 1 $worker_count); do
        echo "  Worker-$i (Opus): .worktrees/wt-$i — launches when task assigned"
    done
    echo ""
    echo -e "${YELLOW}Tier 1 tasks (trivial): Master-2 executes directly (~2-5 min)${NC}"
    echo -e "${YELLOW}Tier 2 tasks (single domain): Assigned to one worker (~5-15 min)${NC}"
    echo -e "${YELLOW}Tier 3 tasks (multi-domain): Full decomposition pipeline (~20-60 min)${NC}"
    echo ""
    echo -e "${YELLOW}Workers launch ON DEMAND — no idle polling, no wasted API credits.${NC}"
    echo -e "${YELLOW}Knowledge persists across resets — system improves over time.${NC}"
    echo -e "${YELLOW}Just talk to MASTER-1 (Tab 3, Masters window)!${NC}"
    echo ""
fi

if [ "$LAUNCH_GUI" = true ]; then
    step "Starting Agent Control Center GUI..."
    GUI_DIR="$SCRIPT_DIR/gui"
    if [ ! -d "$GUI_DIR" ]; then
        GUI_DIR="$SCRIPT_DIR/setup-agents-mac7/gui"
    fi
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
        fail "GUI directory not found"
    fi
fi
