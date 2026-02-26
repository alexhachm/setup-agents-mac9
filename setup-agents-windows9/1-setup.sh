#!/usr/bin/env bash
# ============================================================================
# MULTI-AGENT CLAUDE CODE WORKSPACE — WSL/LINUX (THREE-MASTER) v3
# ============================================================================
# Architecture:
#   - Master-1 (Sonnet): Interface (clean context, user comms)
#   - Master-2 (Opus):   Architect (codebase context, triage, decompose, execute Tier 1)
#   - Master-3 (Sonnet): Allocator (domain map, routes tasks, monitors workers)
#   - Workers 1-8 (Opus): Isolated context per domain, strict grouping
#
# Native bash installer for WSL/Linux
#
# USAGE: bash 1-setup.sh
#        bash 1-setup.sh --headless --repo-url="<url>" --project-path="<path>" --workers=3 --session-mode=1
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_WORKERS=8

# ── Defaults ────────────────────────────────────────────────────────────────
HEADLESS=false
REPO_URL=""
PROJECT_PATH=""
WORKERS=0
SESSION_MODE=""
IF_EXISTS="prompt"

# ── Parse arguments ─────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --headless)        HEADLESS=true ;;
        --repo-url=*)      REPO_URL="${arg#*=}" ;;
        --project-path=*)  PROJECT_PATH="${arg#*=}" ;;
        --workers=*)       WORKERS="${arg#*=}" ;;
        --session-mode=*)  SESSION_MODE="${arg#*=}" ;;
        --if-exists=*)     IF_EXISTS="${arg#*=}" ;;
        --force-reclone)   IF_EXISTS="reclone" ;;
    esac
done

# ── Color helpers ───────────────────────────────────────────────────────────
step()  { printf '\n>> %s\n' "$1"; }
ok()    { printf '   OK: %s\n' "$1"; }
skip()  { printf '   SKIP: %s\n' "$1"; }
fail()  { printf '   FAIL: %s\n' "$1"; }

# ── WSL detection ───────────────────────────────────────────────────────────
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
    # Ensure Windows interop binaries are in PATH (may be missing in non-login shells)
    for p in /mnt/c/Windows/System32 /mnt/c/Windows; do
        [[ -d "$p" ]] && [[ ":$PATH:" != *":$p:"* ]] && export PATH="$PATH:$p"
    done
fi

# Resolve the Windows %USERPROFILE% as a WSL path (e.g. /mnt/c/Users/Owner)
WIN_HOME=""
if $IS_WSL; then
    WIN_HOME="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n')"
    WIN_HOME="$(wslpath -u "$WIN_HOME" 2>/dev/null || echo "")"
fi

# Convert a WSL /mnt/c/... path to a Windows C:\... path
to_windows_path() {
    if command -v wslpath &>/dev/null; then
        wslpath -w "$1" 2>/dev/null || echo "$1"
    else
        echo "$1"
    fi
}

# Create a directory junction (Windows) or symlink (Linux) for shared dirs.
# WSL symlinks on NTFS (/mnt/c/) do NOT resolve from Windows processes,
# so we use cmd.exe mklink /J (NTFS junction) when on /mnt/c/ paths.
create_link() {
    local target="$1" link_path="$2"
    rm -rf "$link_path"
    if $IS_WSL && [[ "$link_path" == /mnt/* ]]; then
        local win_link win_target
        win_link="$(to_windows_path "$link_path")"
        win_target="$(to_windows_path "$target")"
        cmd.exe /c "mklink /J \"$win_link\" \"$win_target\"" > /dev/null 2>&1
    else
        ln -s "$target" "$link_path"
    fi
}

# ── JSON helpers ────────────────────────────────────────────────────────────
new_default_worker_status() {
    local count=$1
    local json="{"
    for ((i=1; i<=count; i++)); do
        [[ $i -gt 1 ]] && json+=","
        json+="\"worker-$i\":{\"status\":\"idle\",\"domain\":null,\"current_task\":null,\"tasks_completed\":0,\"context_budget\":0,\"queued_task\":null,\"awaiting_approval\":false,\"claimed_by\":null,\"last_heartbeat\":null}"
    done
    json+="}"
    echo "$json"
}

new_default_agent_health() {
    cat <<'HEALTH_EOF'
{
  "master-2": { "status": "starting", "last_reset": null, "tier1_count": 0, "decomposition_count": 0 },
  "master-3": { "status": "starting", "last_reset": null, "context_budget": 0, "started_at": null },
  "workers": {}
}
HEALTH_EOF
}

get_state_file_default() {
    local filename=$1 worker_count=$2
    case "$filename" in
        clarification-queue.json) echo '{"questions":[],"responses":[]}' ;;
        task-queue.json)          echo '{"tasks":[]}' ;;
        worker-status.json)       new_default_worker_status "$worker_count" ;;
        agent-health.json)        new_default_agent_health ;;
        *)                        echo '{}' ;;
    esac
}

# ============================================================================
# 0. PREFLIGHT
# ============================================================================
step "Checking prerequisites..."

TEMPLATES_DIR="$SCRIPT_DIR/templates"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

if [[ ! -d "$TEMPLATES_DIR" ]] || [[ ! -d "$SCRIPTS_DIR" ]]; then
    fail "Missing templates/ or scripts/ directory next to 1-setup.sh"
    echo "   Expected structure:"
    echo "     1-setup.sh"
    echo "     templates/  (commands, docs, agents, state)"
    echo "     scripts/    (state-lock.sh, add-worker.sh, hooks/)"
    exit 1
fi

missing=()
for tool in git node npm claude jq; do
    if ! command -v "$tool" &>/dev/null; then
        missing+=("$tool")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing: ${missing[*]}"
    for m in "${missing[@]}"; do
        case "$m" in
            git)    echo "   sudo apt install -y git" ;;
            node)   echo "   Install Node.js: https://nodejs.org/" ;;
            npm)    echo "   Comes with Node.js" ;;
            jq)     echo "   sudo apt install -y jq" ;;
            claude) echo "   npm install -g @anthropic-ai/claude-code" ;;
        esac
    done
    exit 1
fi

# gh is optional but recommended
if ! command -v gh &>/dev/null; then
    skip "gh (GitHub CLI) not found — optional but recommended: sudo apt install -y gh"
fi

ok "All tools found"

# ============================================================================
# 1. PROJECT SETUP
# ============================================================================
step "Project setup..."

# Store config in Windows home on WSL so setup.ps1 and add-worker.sh can find it
if $IS_WSL && [[ -n "$WIN_HOME" ]]; then
    CONFIG_FILE="$WIN_HOME/.claude-multi-agent-config"
else
    CONFIG_FILE="$HOME/.claude-multi-agent-config"
fi
LAST_URL=""
if [[ -f "$CONFIG_FILE" ]]; then
    LAST_URL=$(grep '^repo_url=' "$CONFIG_FILE" 2>/dev/null | sed 's/^repo_url=//' || true)
fi

if $HEADLESS; then
    repoUrl="$REPO_URL"
else
    if [[ -n "$LAST_URL" ]]; then
        read -rp "GitHub repo URL [$LAST_URL]: " repoUrl
        [[ -z "$repoUrl" ]] && repoUrl="$LAST_URL"
    else
        read -rp "GitHub repo URL (leave blank for new project): " repoUrl
    fi
fi

if [[ -n "$repoUrl" ]]; then
    repoName=$(basename "${repoUrl%.git}")
    if $IS_WSL && [[ -n "$WIN_HOME" ]]; then
        defaultPath="$WIN_HOME/Desktop/$repoName"
        [[ ! -d "$WIN_HOME/Desktop" ]] && defaultPath="$WIN_HOME/$repoName"
    else
        defaultPath="$HOME/Desktop/$repoName"
        [[ ! -d "$HOME/Desktop" ]] && defaultPath="$HOME/$repoName"
    fi

    if $HEADLESS; then
        projectPath="${PROJECT_PATH:-$defaultPath}"
    else
        read -rp "Clone to [$defaultPath]: " inputPath
        projectPath="${inputPath:-$defaultPath}"
    fi

    ifExistsPolicy="$IF_EXISTS"
    $HEADLESS && [[ "$ifExistsPolicy" == "prompt" ]] && ifExistsPolicy="abort"

    if [[ -d "$projectPath/.git" ]]; then
        existingRemote=$(cd "$projectPath" && git remote get-url origin 2>/dev/null || true)
        normalizedExisting="${existingRemote%.git}"
        normalizedNew="${repoUrl%.git}"

        if [[ "$normalizedExisting" == "$normalizedNew" ]] && [[ "$ifExistsPolicy" != "reclone" ]]; then
            cd "$projectPath"
            git fetch origin
            git pull origin main --no-rebase 2>/dev/null || git pull origin master --no-rebase 2>/dev/null || true
            ok "Updated existing repo"
        elif [[ "$ifExistsPolicy" == "reclone" ]]; then
            rm -rf "$projectPath"
            git clone "$repoUrl" "$projectPath"
            cd "$projectPath"
            ok "Re-cloned existing path"
        elif [[ "$ifExistsPolicy" == "abort" ]]; then
            fail "Existing repository conflict at $projectPath (use --if-exists=reclone)"
            exit 1
        else
            read -rp "   Different remote exists. Delete and re-clone? [y/N]: " del
            if [[ "$del" =~ ^[Yy]$ ]]; then
                rm -rf "$projectPath"
                git clone "$repoUrl" "$projectPath"
                cd "$projectPath"
            else
                fail "Aborted"; exit 1
            fi
        fi
    elif [[ -d "$projectPath" ]]; then
        if [[ "$ifExistsPolicy" == "reclone" ]]; then
            rm -rf "$projectPath"
            git clone "$repoUrl" "$projectPath"
            cd "$projectPath"
            ok "Re-cloned existing directory"
        elif [[ "$ifExistsPolicy" == "abort" ]]; then
            fail "Directory exists at $projectPath (use --if-exists=reclone)"
            exit 1
        else
            read -rp "   Directory exists. Delete and clone? [y/N]: " del
            if [[ "$del" =~ ^[Yy]$ ]]; then
                rm -rf "$projectPath"
                git clone "$repoUrl" "$projectPath"
                cd "$projectPath"
            else
                fail "Aborted"; exit 1
            fi
        fi
    else
        git clone "$repoUrl" "$projectPath"
        cd "$projectPath"
    fi
    ok "Repo ready: $projectPath"
else
    if $IS_WSL && [[ -n "$WIN_HOME" ]]; then
        defaultPath="$WIN_HOME/Desktop/my-app"
        [[ ! -d "$WIN_HOME/Desktop" ]] && defaultPath="$WIN_HOME/my-app"
    else
        defaultPath="$HOME/Desktop/my-app"
        [[ ! -d "$HOME/Desktop" ]] && defaultPath="$HOME/my-app"
    fi

    if $HEADLESS; then
        projectPath="${PROJECT_PATH:-$defaultPath}"
    else
        read -rp "Project path [$defaultPath]: " inputPath
        projectPath="${inputPath:-$defaultPath}"
    fi

    mkdir -p "$projectPath"
    cd "$projectPath"
    if [[ ! -d ".git" ]]; then
        git init
        git config core.longpaths true
        printf 'node_modules/\n.env\n.env.*\ndist/\n.DS_Store\n*.log\n.worktrees/\n' > .gitignore
        git add -A
        git commit -m "Initial commit"
    fi
    ok "Project ready: $projectPath"
fi

# ============================================================================
# 2. WORKER COUNT
# ============================================================================
step "Worker configuration..."

if $HEADLESS; then
    workerCount=$([[ "$WORKERS" -gt 0 ]] 2>/dev/null && echo "$WORKERS" || echo 3)
else
    read -rp "Initial workers [1-$MAX_WORKERS, default 3]: " wcInput
    workerCount="${wcInput:-3}"
fi

if [[ "$workerCount" -lt 1 ]] || [[ "$workerCount" -gt "$MAX_WORKERS" ]] 2>/dev/null; then
    echo "   WARN: Invalid count '$workerCount' - using default: 3"
    workerCount=3
fi

cat > "$CONFIG_FILE" <<EOF
repo_url=$repoUrl
worker_count=$workerCount
project_path=$projectPath
EOF

ok "$workerCount workers, can scale to $MAX_WORKERS"

# ============================================================================
# 3. DIRECTORIES
# ============================================================================
step "Creating directories..."

for d in .claude/agents .claude/commands .claude/hooks .claude/scripts .claude/state .claude/signals .claude/knowledge/domain; do
    mkdir -p "$projectPath/$d"
done

gitignorePath="$projectPath/.gitignore"
for entry in '.worktrees/' '.claude-shared-state/' '.claude/logs/' '.claude/signals/'; do
    grep -qF "$entry" "$gitignorePath" 2>/dev/null || echo "$entry" >> "$gitignorePath"
done

ok "Directories ready (including signals/ and knowledge/)"

# ============================================================================
# 4. CLAUDE.md HIERARCHY + ROLE DOCS + LOGGING + KNOWLEDGE
# ============================================================================
step "Writing CLAUDE.md hierarchy..."

mkdir -p "$projectPath/.claude/docs" "$projectPath/.claude/logs"

cp "$TEMPLATES_DIR/root-claude.md" "$projectPath/CLAUDE.md"
ok "Root CLAUDE.md written"

cp "$TEMPLATES_DIR/docs/master-1-role.md" "$projectPath/.claude/docs/master-1-role.md"
cp "$TEMPLATES_DIR/docs/master-2-role.md" "$projectPath/.claude/docs/master-2-role.md"
cp "$TEMPLATES_DIR/docs/master-3-role.md" "$projectPath/.claude/docs/master-3-role.md"
ok "Master role documents written"

knowledgeDir="$projectPath/.claude/knowledge"
cp "$TEMPLATES_DIR/knowledge/codebase-insights.md" "$knowledgeDir/codebase-insights.md"
cp "$TEMPLATES_DIR/knowledge/patterns.md" "$knowledgeDir/patterns.md"
cp "$TEMPLATES_DIR/knowledge/mistakes.md" "$knowledgeDir/mistakes.md"
cp "$TEMPLATES_DIR/knowledge/user-preferences.md" "$knowledgeDir/user-preferences.md"
cp "$TEMPLATES_DIR/knowledge/allocation-learnings.md" "$knowledgeDir/allocation-learnings.md"
cp "$TEMPLATES_DIR/knowledge/instruction-patches.md" "$knowledgeDir/instruction-patches.md"
touch "$knowledgeDir/domain/.gitkeep"
ok "Knowledge files initialized"

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "[$timestamp] [setup] [INIT] Multi-agent system v3 initialized" > "$projectPath/.claude/logs/activity.log"
ok "Activity log initialized"

# ============================================================================
# 5. STATE FILES
# ============================================================================
step "Initializing state files..."

stateDir="$projectPath/.claude/state"
for f in handoff.json codebase-map.json worker-status.json fix-queue.json clarification-queue.json task-queue.json agent-health.json; do
    get_state_file_default "$f" "$workerCount" > "$stateDir/$f"
done

cp "$TEMPLATES_DIR/state/worker-lessons.md" "$stateDir/worker-lessons.md"
cp "$TEMPLATES_DIR/state/change-summaries.md" "$stateDir/change-summaries.md"

ok "State files initialized (including agent-health.json)"

# ============================================================================
# 6. SUBAGENTS
# ============================================================================
step "Creating subagents..."

agentsDir="$projectPath/.claude/agents"
cp "$TEMPLATES_DIR/agents/code-architect.md" "$agentsDir/code-architect.md"
cp "$TEMPLATES_DIR/agents/build-validator.md" "$agentsDir/build-validator.md"
cp "$TEMPLATES_DIR/agents/verify-app.md" "$agentsDir/verify-app.md"

ok "Subagents created"

# ============================================================================
# 7. MASTER-1 COMMANDS
# ============================================================================
step "Creating Master-1 commands..."

commandsDir="$projectPath/.claude/commands"
cp "$TEMPLATES_DIR/commands/master-loop.md" "$commandsDir/master-loop.md"
ok "Master-1 commands created"

# ============================================================================
# 8. MASTER-2 COMMANDS (ARCHITECT)
# ============================================================================
step "Creating Master-2 (Architect) commands..."

cp "$TEMPLATES_DIR/commands/scan-codebase.md" "$commandsDir/scan-codebase.md"
cp "$TEMPLATES_DIR/commands/architect-loop.md" "$commandsDir/architect-loop.md"
ok "Master-2 (Architect) commands created"

# ============================================================================
# 8b. MASTER-3 COMMANDS (ALLOCATOR)
# ============================================================================
step "Creating Master-3 (Allocator) commands..."

cp "$TEMPLATES_DIR/commands/allocate-loop.md" "$commandsDir/allocate-loop.md"
cp "$TEMPLATES_DIR/commands/scan-codebase-allocator.md" "$commandsDir/scan-codebase-allocator.md"
ok "Master-3 (Allocator) commands created"

# ============================================================================
# 9. WORKER COMMANDS
# ============================================================================
step "Creating Worker commands..."

cp "$TEMPLATES_DIR/commands/worker-loop.md" "$commandsDir/worker-loop.md"
cp "$TEMPLATES_DIR/commands/commit-push-pr.md" "$commandsDir/commit-push-pr.md"
ok "Worker commands created"

# ============================================================================
# 10. HELPER SCRIPTS
# ============================================================================
step "Creating helper scripts..."

projectScriptsDir="$projectPath/.claude/scripts"
cp "$SCRIPTS_DIR/add-worker.sh" "$projectScriptsDir/add-worker.sh"
cp "$SCRIPTS_DIR/signal-wait.sh" "$projectScriptsDir/signal-wait.sh"
cp "$SCRIPTS_DIR/launch-worker.sh" "$projectScriptsDir/launch-worker.sh"

ok "Helper scripts created (including signal-wait.sh, launch-worker.sh)"

# ============================================================================
# 11. HOOKS
# ============================================================================
step "Creating hooks..."

hooksDir="$projectPath/.claude/hooks"
cp "$SCRIPTS_DIR/hooks/pre-tool-secret-guard.sh" "$hooksDir/pre-tool-secret-guard.sh"
cp "$SCRIPTS_DIR/hooks/stop-notify.sh" "$hooksDir/stop-notify.sh"
cp "$SCRIPTS_DIR/state-lock.sh" "$projectScriptsDir/state-lock.sh"

chmod +x "$projectScriptsDir/add-worker.sh" "$projectScriptsDir/signal-wait.sh" \
         "$projectScriptsDir/launch-worker.sh" "$projectScriptsDir/state-lock.sh" \
         "$hooksDir/pre-tool-secret-guard.sh" "$hooksDir/stop-notify.sh"

ok "Hooks created"

# ============================================================================
# 12. SETTINGS + GLOBAL PERMISSIONS
# ============================================================================
step "Writing settings and configuring global permissions..."

cp "$TEMPLATES_DIR/settings.json" "$projectPath/.claude/settings.json"

globalClaudeDir="$HOME/.claude"
mkdir -p "$globalClaudeDir"

globalSettingsPath="$globalClaudeDir/settings.json"
if [[ -f "$globalSettingsPath" ]]; then
    cp "$globalSettingsPath" "$globalSettingsPath.bak"
    if command -v jq &>/dev/null; then
        # Add project path to trustedDirectories if not already present
        updated=$(jq --arg pp "$projectPath" '
            if .trustedDirectories then
                if (.trustedDirectories | index($pp)) then .
                else .trustedDirectories += [$pp]
                end
            else . + {trustedDirectories: [$pp]}
            end
        ' "$globalSettingsPath" 2>/dev/null) && echo "$updated" > "$globalSettingsPath"
    else
        skip "jq not available — add \"$projectPath\" to trustedDirectories in ~/.claude/settings.json manually"
    fi
else
    echo "{\"trustedDirectories\":[\"$projectPath\"]}" > "$globalSettingsPath"
fi

ok "Settings written (project + global)"

# ============================================================================
# 13. COMMIT
# ============================================================================
step "Committing orchestration files..."

cd "$projectPath"

defaultBranch=""
defaultBranch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || true)
[[ -z "$defaultBranch" ]] && git show-ref --verify --quiet refs/heads/main 2>/dev/null && defaultBranch="main"
[[ -z "$defaultBranch" ]] && git show-ref --verify --quiet refs/heads/master 2>/dev/null && defaultBranch="master"
[[ -z "$defaultBranch" ]] && defaultBranch="main"

git checkout -b "$defaultBranch" 2>/dev/null || git checkout "$defaultBranch" 2>/dev/null || true

# Ensure git identity is configured and enable long paths for NTFS
git config core.longpaths true 2>/dev/null || true
if [[ -z "$(git config user.email 2>/dev/null)" ]]; then
    git config user.email "setup@local"
    git config user.name "Setup"
fi

git add CLAUDE.md .claude/ .gitignore 2>/dev/null || true
git commit -m "feat: v3 three-master architecture with tier routing, knowledge system, signal waking, claim-lock coordination" 2>/dev/null || true

# Verify the commit includes .claude/commands
if ! git ls-tree -r HEAD --name-only 2>/dev/null | grep -q ".claude/commands/worker-loop.md"; then
    echo "   WARN: Retrying commit..."
    git add -A .claude/ 2>/dev/null || true
    git commit -m "feat: v3 three-master orchestration files" 2>/dev/null || true
fi

ok "Orchestration files committed to $defaultBranch"

# ============================================================================
# 14. SHARED STATE
# ============================================================================
step "Setting up shared state directory..."

sharedStateDir="$projectPath/.claude-shared-state"
mkdir -p "$sharedStateDir"

stateDir="$projectPath/.claude/state"

# If state is already a symlink or junction, recreate as real dir first
if [[ -L "$stateDir" ]] || { $IS_WSL && cmd.exe /c "fsutil reparsepoint query \"$(to_windows_path "$stateDir")\"" &>/dev/null; }; then
    rm -rf "$stateDir" 2>/dev/null
    $IS_WSL && cmd.exe /c "rmdir \"$(to_windows_path "$stateDir")\"" &>/dev/null || true
    mkdir -p "$stateDir"
    for f in handoff.json codebase-map.json worker-status.json fix-queue.json clarification-queue.json task-queue.json agent-health.json; do
        [[ ! -f "$sharedStateDir/$f" ]] && get_state_file_default "$f" "$workerCount" > "$stateDir/$f"
    done
fi

stateFiles=(handoff.json codebase-map.json worker-status.json fix-queue.json clarification-queue.json task-queue.json agent-health.json worker-lessons.md change-summaries.md)
for f in "${stateFiles[@]}"; do
    src="$stateDir/$f"
    dst="$sharedStateDir/$f"
    # Copy from state dir to shared if real file exists (not symlink)
    if [[ -f "$src" ]] && [[ ! -L "$src" ]]; then
        cp "$src" "$dst"
    fi
    # Initialize shared file if missing
    if [[ ! -f "$dst" ]]; then
        case "$f" in
            worker-lessons.md)   cp "$TEMPLATES_DIR/state/worker-lessons.md" "$dst" ;;
            change-summaries.md) cp "$TEMPLATES_DIR/state/change-summaries.md" "$dst" ;;
            *.json)              get_state_file_default "$f" "$workerCount" > "$dst" ;;
        esac
    fi
done

# Replace .claude/state with a junction (Windows) or symlink (Linux) to shared state
rm -rf "$stateDir"
create_link "$sharedStateDir" "$stateDir"

# Ensure .claude-shared-state/ is in .gitignore
grep -qF '.claude-shared-state/' "$gitignorePath" 2>/dev/null || echo '.claude-shared-state/' >> "$gitignorePath"

git add .gitignore 2>/dev/null || true
git commit -m "chore: ignore shared state directory" 2>/dev/null || true

ok "Shared state at $sharedStateDir"

# ============================================================================
# 15. WORKTREES
# ============================================================================
step "Setting up worktrees..."

# Clean up old worktrees
for ((i=1; i<=8; i++)); do
    wtPath="$projectPath/.worktrees/wt-$i"
    [[ -d "$wtPath" ]] && git worktree remove "$wtPath" --force 2>/dev/null || true
done
git worktree prune 2>/dev/null || true
for ((i=1; i<=workerCount; i++)); do
    git branch -D "agent-$i" 2>/dev/null || true
done

worktreesDir="$projectPath/.worktrees"
rm -rf "$worktreesDir"
mkdir -p "$worktreesDir"

for ((i=1; i<=workerCount; i++)); do
    wtPath="$worktreesDir/wt-$i"
    git worktree add "$wtPath" -b "agent-$i"

    # Shared state via junction (Windows) or symlink (Linux)
    rm -rf "$wtPath/.claude/state"
    create_link "$sharedStateDir" "$wtPath/.claude/state"

    # Shared logs
    mkdir -p "$wtPath/.claude"
    rm -rf "$wtPath/.claude/logs"
    create_link "$projectPath/.claude/logs" "$wtPath/.claude/logs"

    # Shared knowledge
    rm -rf "$wtPath/.claude/knowledge"
    create_link "$projectPath/.claude/knowledge" "$wtPath/.claude/knowledge"

    # Shared signals
    rm -rf "$wtPath/.claude/signals"
    create_link "$projectPath/.claude/signals" "$wtPath/.claude/signals"

    # Worker CLAUDE.md
    cp "$TEMPLATES_DIR/worker-claude.md" "$wtPath/CLAUDE.md"
done

ok "$workerCount worktrees created (sharing state, knowledge, signals, and logs)"

# ============================================================================
# 16. LAUNCHER SCRIPTS + MANIFEST
# ============================================================================
step "Generating launcher scripts and manifest..."

launcherDir="$projectPath/.claude/launchers"
mkdir -p "$launcherDir"

# Agent definitions
declare -a AGENT_IDS=()
declare -a AGENT_GROUPS=()
declare -a AGENT_ROLES=()
declare -a AGENT_MODELS=()
declare -a AGENT_CWDS=()
declare -a AGENT_SLASHES=()

# Masters
AGENT_IDS+=(master-1); AGENT_GROUPS+=(masters); AGENT_ROLES+=("Interface (Sonnet)"); AGENT_MODELS+=(sonnet); AGENT_CWDS+=("$projectPath"); AGENT_SLASHES+=("/master-loop")
AGENT_IDS+=(master-2); AGENT_GROUPS+=(masters); AGENT_ROLES+=("Architect (Opus)"); AGENT_MODELS+=(opus); AGENT_CWDS+=("$projectPath"); AGENT_SLASHES+=("/scan-codebase")
AGENT_IDS+=(master-3); AGENT_GROUPS+=(masters); AGENT_ROLES+=("Allocator (Sonnet)"); AGENT_MODELS+=(sonnet); AGENT_CWDS+=("$projectPath"); AGENT_SLASHES+=("/scan-codebase-allocator")

# Workers
for ((i=1; i<=workerCount; i++)); do
    AGENT_IDS+=("worker-$i"); AGENT_GROUPS+=(workers); AGENT_ROLES+=("Worker $i (Opus)"); AGENT_MODELS+=(opus)
    AGENT_CWDS+=("$projectPath/.worktrees/wt-$i"); AGENT_SLASHES+=("/worker-loop")
done

get_banner() {
    local id=$1 continue=$2
    local base
    case "$id" in
        master-1) base="I AM MASTER-1 — YOUR INTERFACE (Sonnet)" ;;
        master-2) base="I AM MASTER-2 — ARCHITECT (Opus)" ;;
        master-3) base="I AM MASTER-3 — ALLOCATOR (Sonnet)" ;;
        *)        base="I AM ${id^^}" ;;
    esac
    [[ "$continue" == "true" ]] && base="$base [CONTINUE]"
    echo "$base"
}

get_claude_command() {
    local id=$1 cwd=$2 model=$3 slash=$4 continue=$5
    local teamExport=""
    [[ "$id" != "master-1" ]] && teamExport="export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 && "
    if [[ "$continue" == "true" ]]; then
        echo "cd '$cwd' && ${teamExport}exec claude --continue --model $model --dangerously-skip-permissions"
    else
        echo "cd '$cwd' && ${teamExport}exec claude --model $model --dangerously-skip-permissions '$slash'"
    fi
}

# Write launcher scripts (.sh for Linux, .ps1 and .bat for Windows Terminal)
for idx in "${!AGENT_IDS[@]}"; do
    id="${AGENT_IDS[$idx]}"
    cwd="${AGENT_CWDS[$idx]}"
    model="${AGENT_MODELS[$idx]}"
    slash="${AGENT_SLASHES[$idx]}"

    for cont in false true; do
        suffix=""
        [[ "$cont" == "true" ]] && suffix="-continue"

        banner=$(get_banner "$id" "$cont")
        cmd=$(get_claude_command "$id" "$cwd" "$model" "$slash" "$cont")

        # Bash launcher
        cat > "$launcherDir/${id}${suffix}.sh" <<LAUNCHER_EOF
#!/usr/bin/env bash
clear
echo ""
echo "  ████  $banner  ████"
echo ""
$cmd
LAUNCHER_EOF
        chmod +x "$launcherDir/${id}${suffix}.sh"

        # PowerShell launcher (for Windows Terminal via wsl.exe)
        cmdEscaped="${cmd//\"/\\\"}"
        cat > "$launcherDir/${id}${suffix}.ps1" <<LAUNCHER_EOF
Clear-Host
Write-Host "\`n  ████  $banner  ████\`n" -ForegroundColor Cyan
& wsl.exe -e bash -lc "$cmdEscaped"
LAUNCHER_EOF

        # Batch launcher
        cat > "$launcherDir/${id}${suffix}.bat" <<LAUNCHER_EOF
@echo off
cls
echo.
echo   ████  $banner  ████
echo.
wsl.exe -e bash -lc "$cmdEscaped"
LAUNCHER_EOF
    done
done

ok "Launcher scripts written (.sh, .ps1, .bat)"

# ── Generate manifest.json for GUI (using jq for proper escaping) ───────────
manifestTimestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build manifest with jq to ensure proper JSON escaping
manifest=$(jq -n \
    --arg version "3" \
    --arg project_path "$projectPath" \
    --arg worker_count "$workerCount" \
    --arg created_at "$manifestTimestamp" \
    '{version: ($version | tonumber), project_path: $project_path, worker_count: ($worker_count | tonumber), created_at: $created_at, agents: []}')

for idx in "${!AGENT_IDS[@]}"; do
    id="${AGENT_IDS[$idx]}"
    group="${AGENT_GROUPS[$idx]}"
    role="${AGENT_ROLES[$idx]}"
    model="${AGENT_MODELS[$idx]}"
    cwd="${AGENT_CWDS[$idx]}"
    cmdFresh=$(get_claude_command "$id" "$cwd" "$model" "${AGENT_SLASHES[$idx]}" "false")
    cmdContinue=$(get_claude_command "$id" "$cwd" "$model" "${AGENT_SLASHES[$idx]}" "true")

    manifest=$(echo "$manifest" | jq \
        --arg id "$id" \
        --arg group "$group" \
        --arg role "$role" \
        --arg model "$model" \
        --arg cwd "$cwd" \
        --arg launcher_sh ".claude/launchers/${id}.sh" \
        --arg launcher_sh_continue ".claude/launchers/${id}-continue.sh" \
        --arg launcher_ps1 ".claude/launchers/${id}.ps1" \
        --arg launcher_ps1_continue ".claude/launchers/${id}-continue.ps1" \
        --arg launcher_win ".claude/launchers/${id}.bat" \
        --arg launcher_win_continue ".claude/launchers/${id}-continue.bat" \
        --arg command_fresh "$cmdFresh" \
        --arg command_continue "$cmdContinue" \
        '.agents += [{id: $id, group: $group, role: $role, model: $model, cwd: $cwd, launcher_sh: $launcher_sh, launcher_sh_continue: $launcher_sh_continue, launcher_ps1: $launcher_ps1, launcher_ps1_continue: $launcher_ps1_continue, launcher_win: $launcher_win, launcher_win_continue: $launcher_win_continue, command_fresh: $command_fresh, command_continue: $command_continue}]')
done

echo "$manifest" > "$launcherDir/manifest.json"

ok "Launcher manifest.json generated"

# ============================================================================
# COMPLETE
# ============================================================================
echo ""
echo "========================================"
echo "  SETUP COMPLETE (v3)"
echo "========================================"
echo ""
echo "ARCHITECTURE:"
echo "  Master-1 (Sonnet):  $projectPath (interface - talk here)"
echo "  Master-2 (Opus):    $projectPath (architect - triage + decompose)"
echo "  Master-3 (Sonnet):  $projectPath (allocator - routes to workers)"
for ((i=1; i<=workerCount; i++)); do
    echo "  Worker-$i (Opus):   $projectPath/.worktrees/wt-$i"
done
echo ""
echo "TIER ROUTING:"
echo "  Tier 1: Trivial -> Master-2 executes directly (~2-5 min)"
echo "  Tier 2: Single domain -> Master-2 assigns to one worker (~5-15 min)"
echo "  Tier 3: Multi-domain -> Full decomposition pipeline (~20-60 min)"
echo ""
echo "TERMINALS AT STARTUP: 3 (masters only — workers launch on demand)"
echo ""

# In headless mode, launching depends on session-mode argument
if $HEADLESS; then
    [[ -n "$SESSION_MODE" ]] && launch="Y" || launch="N"
else
    read -rp "Launch master terminals now? [Y/n]: " launch
    [[ -z "$launch" ]] && launch="Y"
fi

if [[ "$launch" =~ ^[Yy]$ ]]; then
    echo ""
    echo "SESSION CONTEXT"
    echo ""
    echo "  1) Fresh start  - wipe ALL prior conversation memory and task state"
    echo "  2) Continue      - agents resume their previous sessions (retains context)"
    echo ""

    if $HEADLESS; then
        sessionModeChoice="${SESSION_MODE:-1}"
    else
        read -rp "Choose [1/2, default 1]: " sessionModeChoice
        [[ -z "$sessionModeChoice" ]] && sessionModeChoice="1"
    fi

    claudeSessionFlag=""

    if [[ "$sessionModeChoice" == "2" ]]; then
        step "Continuing previous sessions (preserving context)..."
        # Clean up stale locks
        find "$sharedStateDir" -name "*.lockdir" -type d -exec rm -rf {} + 2>/dev/null || true
        find "$sharedStateDir" -name "*.lock" -type f -delete 2>/dev/null || true
        claudeSessionFlag="--continue"
        ok "Sessions preserved - agents will resume where they left off"
    else
        step "Resetting sessions (wiping ALL Claude Code state)..."

        for f in handoff.json codebase-map.json fix-queue.json; do
            echo '{}' > "$sharedStateDir/$f"
        done
        new_default_worker_status "$workerCount" > "$sharedStateDir/worker-status.json"
        echo '{"questions":[],"responses":[]}' > "$sharedStateDir/clarification-queue.json"
        echo '{"tasks":[]}' > "$sharedStateDir/task-queue.json"
        new_default_agent_health > "$sharedStateDir/agent-health.json"

        # Wipe Claude Code session state
        rm -rf "$HOME/.claude/projects" "$HOME/.claude/session-env" "$HOME/.claude/todos" \
               "$HOME/.claude/tasks" "$HOME/.claude/plans" "$HOME/.claude/shell-snapshots" 2>/dev/null || true
        rm -f "$HOME/.claude/history.jsonl" 2>/dev/null || true

        rm -f "$projectPath/.claude/todos.json" 2>/dev/null || true
        rm -rf "$projectPath/.claude/.tasks" "$projectPath/.claude/tasks" 2>/dev/null || true

        for ((i=1; i<=workerCount; i++)); do
            wt="$projectPath/.worktrees/wt-$i"
            if [[ -d "$wt" ]]; then
                rm -f "$wt/.claude/todos.json" 2>/dev/null || true
                rm -rf "$wt/.claude/.tasks" "$wt/.claude/tasks" 2>/dev/null || true
            fi
        done

        # Clean up stale locks and signals
        find "$sharedStateDir" -name "*.lockdir" -type d -exec rm -rf {} + 2>/dev/null || true
        find "$sharedStateDir" -name "*.lock" -type f -delete 2>/dev/null || true
        signalsDir="$projectPath/.claude/signals"
        [[ -d "$signalsDir" ]] && find "$signalsDir" -type f -delete 2>/dev/null || true

        mkdir -p "$projectPath/.claude/logs"
        resetTimestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "[$resetTimestamp] [setup] [FRESH_RESET] All sessions wiped (knowledge preserved)" > "$projectPath/.claude/logs/activity.log"

        claudeSessionFlag=""
        ok "Sessions FULLY reset - knowledge files PRESERVED across reset"
    fi

    # ==================================================================
    # TERMINAL LAUNCH
    # ==================================================================
    step "Launching terminals..."

    if [[ "$claudeSessionFlag" == "--continue" ]]; then
        launcherSuffix="-continue"
    else
        launcherSuffix=""
    fi

    # Check if Windows Terminal is available (wt.exe accessible from WSL)
    if command -v wt.exe &>/dev/null; then
        step "  Launching masters in Windows Terminal (WSL sessions)..."

        # wt.exe is a Windows process — use .ps1 launchers with Windows paths
        m1Ps1="$(to_windows_path "$launcherDir/master-1${launcherSuffix}.ps1")"
        m2Ps1="$(to_windows_path "$launcherDir/master-2${launcherSuffix}.ps1")"
        m3Ps1="$(to_windows_path "$launcherDir/master-3${launcherSuffix}.ps1")"

        wt.exe -w masters \
            new-tab --title Master-2-Architect powershell.exe -ExecutionPolicy Bypass -File "$m2Ps1" \; \
            new-tab --title Master-3-Allocator powershell.exe -ExecutionPolicy Bypass -File "$m3Ps1" \; \
            new-tab --title Master-1-Interface powershell.exe -ExecutionPolicy Bypass -File "$m1Ps1" &
        sleep 2
        ok "  3 master tabs created in Windows Terminal"
        ok "  Workers launch on demand via .claude/scripts/launch-worker.sh"
    else
        step "  Launching in separate terminals..."
        for master in master-2 master-3 master-1; do
            launcher="$launcherDir/${master}${launcherSuffix}.sh"
            if command -v gnome-terminal &>/dev/null; then
                gnome-terminal -- bash -l "$launcher" &
            elif command -v xterm &>/dev/null; then
                xterm -e bash -l "$launcher" &
            else
                echo "   Start manually: bash $launcher"
            fi
            sleep 1
        done
        ok "  3 master terminals launched"
    fi

    echo ""
    echo "========================================"
    echo "  MASTERS LAUNCHED (v3)"
    echo "========================================"
    echo ""
    if [[ "$claudeSessionFlag" == "--continue" ]]; then
        echo "MODE: CONTINUE - agents resuming previous sessions"
    else
        echo "MODE: FRESH - clean sessions, persistent knowledge preserved"
    fi
    echo ""
    echo "MASTERS WINDOW (3 tabs):"
    echo "  Tab 1: MASTER-2 (Opus) - Architect (scanning, then triage + decompose)"
    echo "  Tab 2: MASTER-3 (Sonnet) - Allocator (scanning, then routing)"
    echo "  Tab 3: MASTER-1 (Sonnet) - Interface (talk here)"
    echo ""
    echo "WORKERS (on-demand launch, $workerCount worktrees ready):"
    for ((i=1; i<=workerCount; i++)); do
        echo "  Worker-$i (Opus): .worktrees/wt-$i"
    done
    echo ""
    echo "Tier 1 tasks (trivial): Master-2 executes directly (~2-5 min)"
    echo "Tier 2 tasks (single domain): Assigned to one worker via claim-lock (~5-15 min)"
    echo "Tier 3 tasks (multi-domain): Full decomposition pipeline (~20-60 min)"
    echo ""
    echo "Workers launch ON DEMAND — no idle polling, lower cost."
    echo "Knowledge persists across resets - system improves over time."
    echo "Just talk to MASTER-1 (Tab 3, Masters window)!"
    echo ""
fi
