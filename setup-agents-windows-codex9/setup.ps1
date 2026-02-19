# ============================================================================
# MULTI-AGENT CODEX WORKSPACE — WINDOWS (THREE-MASTER) v3
# ============================================================================
# Architecture:
#   - Master-1 (Fast): Interface (clean context, user comms)
#   - Master-2 (Deep):   Architect (codebase context, triage, decompose, execute Tier 1)
#   - Master-3 (Fast): Allocator (domain map, routes tasks, monitors workers)
#   - Workers 1-8 (Deep): Isolated context per domain, strict grouping
#
# Native Windows PowerShell installer (Windows-only package)
#
# USAGE: powershell -ExecutionPolicy Bypass -File setup.ps1
#        powershell -ExecutionPolicy Bypass -File setup.ps1 -Headless -RepoUrl "<url>" -ProjectPath "<path>" -Workers 3 -SessionMode 1 -IfExists abort
# ============================================================================

param(
    [switch]$Gui,
    [switch]$GuiOnly,
    [switch]$Headless,
    [string]$RepoUrl = "",
    [string]$ProjectPath = "",
    [int]$Workers = 0,
    [string]$SessionMode = "",
    [ValidateSet("prompt", "abort", "reclone")]
    [string]$IfExists = "prompt",
    [switch]$ForceReclone
)

$ErrorActionPreference = "Continue"

# ── Resolve script directory (where templates/ and scripts/ live) ──────────
$ScriptDir = $PSScriptRoot

# ── Color helpers ──────────────────────────────────────────────────────────
function Step($msg)  { Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Ok($msg)    { Write-Host "   OK: $msg" -ForegroundColor Green }
function Skip($msg)  { Write-Host "   SKIP: $msg" -ForegroundColor Yellow }
function Fail($msg)  { Write-Host "   FAIL: $msg" -ForegroundColor Red }

function Escape-BashSingleQuoted([string]$Value) {
    if ($null -eq $Value) { return "" }
    return $Value -replace "'", '''"''"'''
}

function Convert-ToWslPath([string]$WindowsPath) {
    if ([string]::IsNullOrWhiteSpace($WindowsPath)) { return "" }
    $resolved = $WindowsPath
    try {
        $resolved = (Resolve-Path -LiteralPath $WindowsPath -ErrorAction Stop).Path
    } catch {
        try {
            $resolved = [System.IO.Path]::GetFullPath($WindowsPath)
        } catch {
            $resolved = $WindowsPath
        }
    }
    $normalized = $resolved -replace '\\', '/'
    if ($normalized -match '^([A-Za-z]):/(.*)$') {
        return "/mnt/$($matches[1].ToLower())/$($matches[2])"
    }
    return $normalized
}

function New-DefaultWorkerStatus([int]$Count) {
    $workerStatus = @{}
    for ($i = 1; $i -le $Count; $i++) {
        $workerStatus["worker-$i"] = @{
            status = "idle"
            domain = $null
            current_task = $null
            tasks_completed = 0
            context_budget = 0
            queued_task = $null
            awaiting_approval = $false
            claimed_by = $null
            last_heartbeat = $null
        }
    }
    return ($workerStatus | ConvertTo-Json -Depth 6)
}

function New-DefaultAgentHealth() {
    return @'
{
  "master-2": { "status": "starting", "last_reset": null, "tier1_count": 0, "decomposition_count": 0 },
  "master-3": { "status": "starting", "last_reset": null, "context_budget": 0, "started_at": null },
  "workers": {}
}
'@
}

function Get-StateFileDefaultContent([string]$FileName, [int]$WorkerCount) {
    switch ($FileName) {
        "clarification-queue.json" { return '{"questions":[],"responses":[]}' }
        "task-queue.json" { return '{"tasks":[]}' }
        "tasks.json" { return '{"next_id":1,"tasks":[],"last_updated_at":null}' }
        "worker-status.json" { return (New-DefaultWorkerStatus $WorkerCount) }
        "agent-health.json" { return (New-DefaultAgentHealth) }
        default { return '{}' }
    }
}

$MAX_WORKERS = 8

# ============================================================================
# GUI-ONLY MODE: Just launch the Electron GUI, skip everything else
# ============================================================================
if ($GuiOnly) {
    Step "Starting Agent Control Center GUI (gui-only mode)..."
    $guiDir = Join-Path $ScriptDir "gui"
    if (Test-Path $guiDir) {
        if (-not (Test-Path (Join-Path $guiDir "node_modules"))) {
            Write-Host "   Installing GUI dependencies..."
            Push-Location $guiDir
            npm install --silent 2>$null
            Pop-Location
        }
        Write-Host "   Starting control center..."
        $env:SETUP_SCRIPT_DIR = $ScriptDir
        Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
        $electronCmd = Join-Path $guiDir "node_modules\.bin\electron.cmd"
        Push-Location $guiDir
        & $electronCmd .
        Pop-Location
    } else {
        Fail "GUI directory not found"
        exit 1
    }
    exit 0
}

# ============================================================================
# 0. PREFLIGHT
# ============================================================================
Step "Checking prerequisites..."

$templatesDir = Join-Path $ScriptDir "templates"
$scriptsDir = Join-Path $ScriptDir "scripts"

if (-not (Test-Path $templatesDir) -or -not (Test-Path $scriptsDir)) {
    Fail "Missing templates/ or scripts/ directory next to setup.ps1"
    Write-Host "   Expected structure:"
    Write-Host "     setup.ps1"
    Write-Host '     templates/  (commands, docs, agents, state)'
    Write-Host '     scripts/    (state-lock.sh, add-worker.sh, hooks/)'
    exit 1
}

$missing = @()
foreach ($tool in @("git", "node", "npm")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $missing += $tool
    }
}

if ($missing.Count -gt 0) {
    Fail "Missing: $($missing -join ', ')"
    Write-Host "   winget install Git.Git"
    Write-Host "   winget install OpenJS.NodeJS"
    exit 1
}

$wslCmd = Get-Command "wsl.exe" -ErrorAction SilentlyContinue
if (-not $wslCmd) {
    Fail "WSL not found"
    Write-Host "   Install WSL and a distro: wsl --install -d Ubuntu"
    exit 1
}

& wsl.exe -e bash -lc "echo WSL_OK >/dev/null 2>&1"
if ($LASTEXITCODE -ne 0) {
    Fail "WSL is installed but not ready"
    Write-Host "   Run: wsl --install -d Ubuntu"
    Write-Host "   Then complete initial distro setup"
    exit 1
}

$missingWsl = @()
foreach ($tool in @("codex", "git", "gh", "jq")) {
    & wsl.exe -e bash -lc "command -v $tool >/dev/null 2>&1"
    if ($LASTEXITCODE -ne 0) {
        $missingWsl += $tool
    }
}

if ($missingWsl.Count -gt 0) {
    Fail "Missing inside WSL: $($missingWsl -join ', ')"
    Write-Host "   Open WSL and install:"
    if ($missingWsl -contains "git") { Write-Host "     sudo apt update && sudo apt install -y git" }
    if ($missingWsl -contains "gh") { Write-Host "     sudo apt install -y gh    # or follow GitHub CLI Linux instructions" }
    if ($missingWsl -contains "jq") { Write-Host "     sudo apt install -y jq" }
    if ($missingWsl -contains "codex") { Write-Host "     Install Codex CLI in WSL and ensure 'codex' is on PATH" }
    exit 1
}

Ok "All tools found (Windows + WSL)"

# ============================================================================
# 1. PROJECT SETUP
# ============================================================================
Step "Project setup..."

$configFile = Join-Path $env:USERPROFILE ".codex-multi-agent-config"
$lastUrl = ""
if (Test-Path $configFile) {
    $configContent = Get-Content $configFile -ErrorAction SilentlyContinue
    $urlLine = $configContent | Where-Object { $_ -match "^repo_url=" }
    if ($urlLine) {
        $lastUrl = $urlLine -replace "^repo_url=", ""
    }
}

if ($Headless) {
    $repoUrl = $RepoUrl
} else {
    if ($lastUrl) {
        $repoUrl = Read-Host "GitHub repo URL [$lastUrl]"
        if ([string]::IsNullOrEmpty($repoUrl)) { $repoUrl = $lastUrl }
    } else {
        $repoUrl = Read-Host "GitHub repo URL (leave blank for new project)"
    }
}

if (-not [string]::IsNullOrEmpty($repoUrl)) {
    $repoName = [System.IO.Path]::GetFileNameWithoutExtension($repoUrl.TrimEnd('/').Split('/')[-1])
    $defaultPath = Join-Path ([Environment]::GetFolderPath("Desktop")) $repoName
    if ($Headless) {
        $projectPath = if ($ProjectPath) { $ProjectPath } else { $defaultPath }
    } else {
        $inputPath = Read-Host "Clone to [$defaultPath]"
        $projectPath = if ([string]::IsNullOrEmpty($inputPath)) { $defaultPath } else { $inputPath }
    }

    $ifExistsPolicy = $IfExists
    if ($ForceReclone) { $ifExistsPolicy = "reclone" }
    if ($Headless -and $ifExistsPolicy -eq "prompt") { $ifExistsPolicy = "abort" }

    if (Test-Path (Join-Path $projectPath ".git")) {
        Set-Location $projectPath
        $existingRemote = ""
        try { $existingRemote = git remote get-url origin 2>$null } catch {}
        $normalizedExisting = $existingRemote -replace "\.git$", ""
        $normalizedNew = $repoUrl -replace "\.git$", ""
        if ($normalizedExisting -eq $normalizedNew -and $ifExistsPolicy -ne "reclone") {
            git fetch origin
            try { git pull origin main --no-rebase 2>$null } catch {
                try { git pull origin master --no-rebase 2>$null } catch {}
            }
            Ok "Updated existing repo"
        } elseif ($ifExistsPolicy -eq "reclone") {
            Set-Location $env:USERPROFILE
            Remove-Item -Recurse -Force $projectPath
            git clone $repoUrl $projectPath
            Set-Location $projectPath
            Ok "Re-cloned existing path due to -IfExists reclone"
        } elseif ($ifExistsPolicy -eq "abort") {
            Fail "Existing repository conflict at $projectPath (use -IfExists reclone or -ForceReclone)"
            exit 1
        } else {
            $del = Read-Host "   Different remote exists. Delete and re-clone? [y/N]"
            if ($del -match "^[Yy]$") {
                Set-Location $env:USERPROFILE
                Remove-Item -Recurse -Force $projectPath
                git clone $repoUrl $projectPath
                Set-Location $projectPath
            } else {
                Fail "Aborted"; exit 1
            }
        }
    } elseif (Test-Path $projectPath) {
        if ($ifExistsPolicy -eq "reclone") {
            Remove-Item -Recurse -Force $projectPath
            git clone $repoUrl $projectPath
            Set-Location $projectPath
            Ok "Re-cloned existing directory due to -IfExists reclone"
        } elseif ($ifExistsPolicy -eq "abort") {
            Fail "Directory exists at $projectPath (use -IfExists reclone or -ForceReclone)"
            exit 1
        } else {
            $del = Read-Host "   Directory exists. Delete and clone? [y/N]"
            if ($del -match "^[Yy]$") {
                Remove-Item -Recurse -Force $projectPath
                git clone $repoUrl $projectPath
                Set-Location $projectPath
            } else {
                Fail "Aborted"; exit 1
            }
        }
    } else {
        git clone $repoUrl $projectPath
        Set-Location $projectPath
    }
    Ok "Repo ready: $projectPath"
} else {
    $defaultPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "my-app"
    if ($Headless) {
        $projectPath = if ($ProjectPath) { $ProjectPath } else { $defaultPath }
    } else {
        $inputPath = Read-Host "Project path [$defaultPath]"
        $projectPath = if ([string]::IsNullOrEmpty($inputPath)) { $defaultPath } else { $inputPath }
    }
    if (-not (Test-Path $projectPath)) { New-Item -ItemType Directory -Path $projectPath -Force | Out-Null }
    Set-Location $projectPath
    if (-not (Test-Path ".git")) {
        git init
        @("node_modules/", ".env", ".env.*", "dist/", ".DS_Store", "*.log", ".worktrees/") | Set-Content ".gitignore"
        git add -A
        git commit -m "Initial commit"
    }
    Ok "Project ready: $projectPath"
}

# ============================================================================
# 2. WORKER COUNT
# ============================================================================
Step "Worker configuration..."

if ($Headless) {
    $workerCount = if ($Workers -gt 0) { $Workers } else { 3 }
} else {
    $wcInput = Read-Host "Initial workers [1-$MAX_WORKERS, default 3]"
    $workerCount = if ([string]::IsNullOrEmpty($wcInput)) { 3 } else {
        try { [int]$wcInput } catch { 3 }
    }
}
if ($workerCount -lt 1 -or $workerCount -gt $MAX_WORKERS) {
    Write-Host "   WARN: Invalid count '$workerCount' - must be 1-$MAX_WORKERS. Using default: 3" -ForegroundColor Yellow
    $workerCount = 3
}

@(
    "repo_url=$repoUrl",
    "worker_count=$workerCount",
    "project_path=$projectPath"
) | Set-Content $configFile

Ok "$workerCount workers, can scale to $MAX_WORKERS"

# ============================================================================
# 3. DIRECTORIES
# ============================================================================
Step "Creating directories..."

$dirs = @(
    ".codex\agents", ".codex\commands", ".codex\hooks",
    ".codex\scripts", ".codex\state", ".codex\signals",
    ".codex\knowledge\domain"
)
foreach ($d in $dirs) {
    $fullPath = Join-Path $projectPath $d
    if (-not (Test-Path $fullPath)) { New-Item -ItemType Directory -Path $fullPath -Force | Out-Null }
}

$gitignorePath = Join-Path $projectPath ".gitignore"
$gitignoreContent = if (Test-Path $gitignorePath) { Get-Content $gitignorePath -Raw } else { "" }
foreach ($entry in @('.worktrees/', '.codex-shared-state/', '.codex/logs/', '.codex/signals/')) {
    if ($gitignoreContent -notmatch [regex]::Escape($entry)) {
        Add-Content -Path $gitignorePath -Value $entry
    }
}

Ok "Directories ready (including signals/ and knowledge/)"

# ============================================================================
# 4. AGENTS.md HIERARCHY + ROLE DOCS + LOGGING + KNOWLEDGE
# ============================================================================
Step "Writing AGENTS.md hierarchy..."

New-Item -ItemType Directory -Path (Join-Path $projectPath ".codex\docs") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $projectPath ".codex\logs") -Force | Out-Null

# ── ROOT AGENTS.md ────────────────────────────────────────────────────────
Copy-Item (Join-Path $ScriptDir "templates\root-agents.md") (Join-Path $projectPath "AGENTS.md") -Force
Ok "Root AGENTS.md written"

# ── MASTER ROLE DOCUMENTS ─────────────────────────────────────────────────
Copy-Item (Join-Path $ScriptDir "templates\docs\master-1-role.md") (Join-Path $projectPath ".codex\docs\master-1-role.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\docs\master-2-role.md") (Join-Path $projectPath ".codex\docs\master-2-role.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\docs\master-3-role.md") (Join-Path $projectPath ".codex\docs\master-3-role.md") -Force
Ok "Master role documents written"

# ── KNOWLEDGE FILES ───────────────────────────────────────────────────────
$knowledgeDir = Join-Path $projectPath ".codex\knowledge"
Copy-Item (Join-Path $ScriptDir "templates\knowledge\codebase-insights.md") (Join-Path $knowledgeDir "codebase-insights.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\knowledge\patterns.md") (Join-Path $knowledgeDir "patterns.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\knowledge\mistakes.md") (Join-Path $knowledgeDir "mistakes.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\knowledge\user-preferences.md") (Join-Path $knowledgeDir "user-preferences.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\knowledge\allocation-learnings.md") (Join-Path $knowledgeDir "allocation-learnings.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\knowledge\instruction-patches.md") (Join-Path $knowledgeDir "instruction-patches.md") -Force
New-Item -ItemType File -Path (Join-Path $knowledgeDir "domain\.gitkeep") -Force | Out-Null
Ok "Knowledge files initialized"

# ── INITIALIZE ACTIVITY LOG ───────────────────────────────────────────────
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
"[$timestamp] [setup] [INIT] Multi-agent system v3 initialized" | Set-Content (Join-Path $projectPath ".codex\logs\activity.log")
Ok "Activity log initialized"

# ============================================================================
# 5. STATE FILES
# ============================================================================
Step "Initializing state files..."

$stateDir = Join-Path $projectPath ".codex\state"
foreach ($jsonStateFile in @("handoff.json","codebase-map.json","worker-status.json","fix-queue.json","clarification-queue.json","task-queue.json","tasks.json","agent-health.json")) {
    (Get-StateFileDefaultContent $jsonStateFile $workerCount) | Set-Content (Join-Path $stateDir $jsonStateFile)
}

Copy-Item (Join-Path $ScriptDir "templates\state\worker-lessons.md") (Join-Path $stateDir "worker-lessons.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\state\change-summaries.md") (Join-Path $stateDir "change-summaries.md") -Force

Ok "State files initialized (including agent-health.json)"

# ============================================================================
# 6. SUBAGENTS
# ============================================================================
Step "Creating subagents..."

$agentsDir = Join-Path $projectPath ".codex\agents"
Copy-Item (Join-Path $ScriptDir "templates\agents\code-architect.md") (Join-Path $agentsDir "code-architect.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\agents\build-validator.md") (Join-Path $agentsDir "build-validator.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\agents\verify-app.md") (Join-Path $agentsDir "verify-app.md") -Force

Ok "Subagents created"

# ============================================================================
# 7. MASTER-1 COMMANDS
# ============================================================================
Step "Creating Master-1 commands..."

$commandsDir = Join-Path $projectPath ".codex\commands"
Copy-Item (Join-Path $ScriptDir "templates\commands\master-loop.md") (Join-Path $commandsDir "master-loop.md") -Force
Ok "Master-1 commands created"

# ============================================================================
# 8. MASTER-2 COMMANDS (ARCHITECT)
# ============================================================================
Step "Creating Master-2 (Architect) commands..."

Copy-Item (Join-Path $ScriptDir "templates\commands\scan-codebase.md") (Join-Path $commandsDir "scan-codebase.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\commands\architect-loop.md") (Join-Path $commandsDir "architect-loop.md") -Force
Ok "Master-2 (Architect) commands created"

# ============================================================================
# 8b. MASTER-3 COMMANDS (ALLOCATOR)
# ============================================================================
Step "Creating Master-3 (Allocator) commands..."

Copy-Item (Join-Path $ScriptDir "templates\commands\allocate-loop.md") (Join-Path $commandsDir "allocate-loop.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\commands\scan-codebase-allocator.md") (Join-Path $commandsDir "scan-codebase-allocator.md") -Force
Ok "Master-3 (Allocator) commands created"

# ============================================================================
# 9. WORKER COMMANDS
# ============================================================================
Step "Creating Worker commands..."

Copy-Item (Join-Path $ScriptDir "templates\commands\worker-loop.md") (Join-Path $commandsDir "worker-loop.md") -Force
Copy-Item (Join-Path $ScriptDir "templates\commands\commit-push-pr.md") (Join-Path $commandsDir "commit-push-pr.md") -Force
Ok "Worker commands created"

# ============================================================================
# 10. HELPER SCRIPTS
# ============================================================================
Step "Creating helper scripts..."

$projectScriptsDir = Join-Path $projectPath ".codex\scripts"
Copy-Item (Join-Path $ScriptDir "scripts\add-worker.sh") (Join-Path $projectScriptsDir "add-worker.sh") -Force
Copy-Item (Join-Path $ScriptDir "scripts\signal-wait.sh") (Join-Path $projectScriptsDir "signal-wait.sh") -Force
Copy-Item (Join-Path $ScriptDir "scripts\launch-worker.sh") (Join-Path $projectScriptsDir "launch-worker.sh") -Force
Copy-Item (Join-Path $ScriptDir "scripts\task-api.sh") (Join-Path $projectScriptsDir "task-api.sh") -Force
Copy-Item (Join-Path $ScriptDir "scripts\codex-runner.sh") (Join-Path $projectScriptsDir "codex-runner.sh") -Force
Copy-Item (Join-Path $ScriptDir "scripts\state-lock.sh") (Join-Path $projectScriptsDir "state-lock.sh") -Force

Ok "Helper scripts created (including launch-worker.sh, task-api.sh, codex-runner.sh)"

# ============================================================================
# 11. HOOKS
# ============================================================================
Step "Creating hooks..."

$hooksDir = Join-Path $projectPath ".codex\hooks"
Copy-Item (Join-Path $ScriptDir "scripts\hooks\pre-tool-secret-guard.sh") (Join-Path $hooksDir "pre-tool-secret-guard.sh") -Force
Copy-Item (Join-Path $ScriptDir "scripts\hooks\stop-notify.sh") (Join-Path $hooksDir "stop-notify.sh") -Force

# Ensure WSL shell scripts are executable
$projectPathWsl = Escape-BashSingleQuoted (Convert-ToWslPath $projectPath)
& wsl.exe -e bash -lc "chmod +x '$projectPathWsl/.codex/scripts/add-worker.sh' '$projectPathWsl/.codex/scripts/signal-wait.sh' '$projectPathWsl/.codex/scripts/launch-worker.sh' '$projectPathWsl/.codex/scripts/state-lock.sh' '$projectPathWsl/.codex/scripts/task-api.sh' '$projectPathWsl/.codex/scripts/codex-runner.sh' '$projectPathWsl/.codex/hooks/pre-tool-secret-guard.sh' '$projectPathWsl/.codex/hooks/stop-notify.sh'" 2>$null

Ok "Hooks created"

# ============================================================================
# 12. SETTINGS + GLOBAL PERMISSIONS
# ============================================================================
Step "Writing settings and configuring global permissions..."

Copy-Item (Join-Path $ScriptDir "templates\settings.json") (Join-Path $projectPath ".codex\settings.json") -Force
Copy-Item (Join-Path $ScriptDir "templates\provider-codex.json") (Join-Path $projectPath ".codex\provider-codex.json") -Force

$globalCodexDir = Join-Path $env:USERPROFILE ".codex"
if (-not (Test-Path $globalCodexDir)) { New-Item -ItemType Directory -Path $globalCodexDir -Force | Out-Null }

$globalSettingsPath = Join-Path $globalCodexDir "settings.json"
if (Test-Path $globalSettingsPath) {
    Copy-Item $globalSettingsPath "$globalSettingsPath.bak" -Force
    try {
        $settings = Get-Content $globalSettingsPath -Raw | ConvertFrom-Json
        if (-not $settings.trustedDirectories) {
            $settings | Add-Member -NotePropertyName "trustedDirectories" -NotePropertyValue @() -Force
        }
        $trusted = @($settings.trustedDirectories)
        if ($trusted -notcontains $projectPath) {
            $trusted += $projectPath
            $settings.trustedDirectories = $trusted
        }
        $settings | ConvertTo-Json -Depth 10 | Set-Content $globalSettingsPath
    } catch {
        $skipMsg = 'Could not parse settings.json - add "' + $projectPath + '" to trustedDirectories in ~/.codex/settings.json manually'
        Skip $skipMsg
    }
} else {
    @{
        trustedDirectories = @($projectPath)
    } | ConvertTo-Json -Depth 10 | Set-Content $globalSettingsPath
}

Ok "Settings written (project + global)"

# ============================================================================
# 13. COMMIT
# ============================================================================
Step "Committing orchestration files..."

$defaultBranch = ""
try {
    $defaultBranch = git symbolic-ref refs/remotes/origin/HEAD 2>$null
    $defaultBranch = $defaultBranch -replace "^refs/remotes/origin/", ""
} catch {}

if ([string]::IsNullOrEmpty($defaultBranch)) {
    try {
        git show-ref --verify --quiet refs/heads/main 2>$null
        if ($LASTEXITCODE -eq 0) { $defaultBranch = "main" }
    } catch {}
}
if ([string]::IsNullOrEmpty($defaultBranch)) {
    try {
        git show-ref --verify --quiet refs/heads/master 2>$null
        if ($LASTEXITCODE -eq 0) { $defaultBranch = "master" }
    } catch {}
}
if ([string]::IsNullOrEmpty($defaultBranch)) { $defaultBranch = "main" }

try { git checkout -b $defaultBranch 2>$null } catch {
    try { git checkout $defaultBranch 2>$null } catch {}
}

# Ensure git identity is configured (required for commit)
$gitEmail = git config user.email 2>$null
if ([string]::IsNullOrEmpty($gitEmail)) {
    git config user.email "setup@local"
    git config user.name "Setup"
}

git add AGENTS.md .codex/ .gitignore 2>$null
git commit -m "feat: v3 three-master architecture with tier routing, knowledge system, signal waking, claim-lock coordination" 2>$null

# Verify the commit includes .codex/commands (critical for worktrees)
$hasCommands = git ls-tree -r HEAD --name-only 2>$null | Select-String ".codex/commands/worker-loop.md"
if (-not $hasCommands) {
    Write-Host "   WARN: Retrying commit..." -ForegroundColor Yellow
    git add -A .codex/ 2>$null
    git commit -m "feat: v3 three-master orchestration files" 2>$null
}

Ok "Orchestration files committed to $defaultBranch"

# ============================================================================
# 14. SHARED STATE
# ============================================================================
Step "Setting up shared state directory..."

$sharedStateDir = Join-Path $projectPath ".codex-shared-state"
if (-not (Test-Path $sharedStateDir)) { New-Item -ItemType Directory -Path $sharedStateDir -Force | Out-Null }

$stateDir = Join-Path $projectPath ".codex\state"

# If state is already a junction, recreate it as a real directory first
$stateItem = Get-Item $stateDir -ErrorAction SilentlyContinue
if ($stateItem -and $stateItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    Remove-Item $stateDir -Recurse -Force
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    foreach ($f in @("handoff.json","codebase-map.json","worker-status.json","fix-queue.json","clarification-queue.json","task-queue.json","agent-health.json")) {
        if (-not (Test-Path (Join-Path $sharedStateDir $f))) {
            (Get-StateFileDefaultContent $f $workerCount) | Set-Content (Join-Path $stateDir $f)
        }
    }
}

$stateFiles = @("handoff.json","codebase-map.json","worker-status.json","fix-queue.json","clarification-queue.json","task-queue.json","agent-health.json","worker-lessons.md","change-summaries.md")
foreach ($f in $stateFiles) {
    $src = Join-Path $stateDir $f
    $dst = Join-Path $sharedStateDir $f
    # Copy from state dir to shared if real file exists
    if ((Test-Path $src) -and -not ((Get-Item $src -ErrorAction SilentlyContinue).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Copy-Item $src $dst -Force
    }
    # Initialize shared file if missing
    if (-not (Test-Path $dst)) {
        switch ($f) {
            "worker-lessons.md" { Copy-Item (Join-Path $ScriptDir "templates\state\worker-lessons.md") $dst -Force }
            "change-summaries.md" { Copy-Item (Join-Path $ScriptDir "templates\state\change-summaries.md") $dst -Force }
            default {
                if ($f -like "*.json") {
                    (Get-StateFileDefaultContent $f $workerCount) | Set-Content $dst
                }
            }
        }
    }
}

# Replace .codex/state with a directory junction to shared state
Remove-Item $stateDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Junction -Path $stateDir -Target $sharedStateDir | Out-Null

# Ensure .codex-shared-state/ is in .gitignore
$gitignoreContent = if (Test-Path $gitignorePath) { Get-Content $gitignorePath -Raw } else { "" }
if ($gitignoreContent -notmatch [regex]::Escape('.codex-shared-state/')) {
    Add-Content -Path $gitignorePath -Value '.codex-shared-state/'
}

git add .gitignore 2>$null
try { git commit -m "chore: ignore shared state directory" 2>$null } catch {}

Ok "Shared state at $sharedStateDir"

# ============================================================================
# 15. WORKTREES
# ============================================================================
Step "Setting up worktrees..."

# Clean up old worktrees
for ($i = 1; $i -le 8; $i++) {
    $wtPath = Join-Path $projectPath ".worktrees\wt-$i"
    if (Test-Path $wtPath) {
        try { git worktree remove $wtPath --force 2>$null } catch {}
    }
}
try { git worktree prune 2>$null } catch {}
for ($i = 1; $i -le $workerCount; $i++) {
    try { git branch -D "agent-$i" 2>$null } catch {}
}
$worktreesDir = Join-Path $projectPath ".worktrees"
if (Test-Path $worktreesDir) { Remove-Item -Recurse -Force $worktreesDir -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Path $worktreesDir -Force | Out-Null
for ($i = 1; $i -le $workerCount; $i++) {
    $wtPath = Join-Path $worktreesDir "wt-$i"
    git worktree add $wtPath -b "agent-$i"

    # Shared state via directory junction
    $wtStateDir = Join-Path $wtPath ".codex\state"
    Remove-Item $wtStateDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Junction -Path $wtStateDir -Target $sharedStateDir | Out-Null

    # Shared logs via directory junction
    $wtLogsDir = Join-Path $wtPath ".codex\logs"
    New-Item -ItemType Directory -Path (Join-Path $wtPath ".codex") -Force | Out-Null
    Remove-Item $wtLogsDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Junction -Path $wtLogsDir -Target (Join-Path $projectPath ".codex\logs") | Out-Null

    # Shared knowledge via directory junction
    $wtKnowledgeDir = Join-Path $wtPath ".codex\knowledge"
    Remove-Item $wtKnowledgeDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Junction -Path $wtKnowledgeDir -Target (Join-Path $projectPath ".codex\knowledge") | Out-Null

    # Shared signals via directory junction
    $wtSignalsDir = Join-Path $wtPath ".codex\signals"
    Remove-Item $wtSignalsDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Junction -Path $wtSignalsDir -Target (Join-Path $projectPath ".codex\signals") | Out-Null

    # Worker AGENTS.md
    Copy-Item (Join-Path $ScriptDir "templates\worker-agents.md") (Join-Path $wtPath "AGENTS.md") -Force
}

Ok "$workerCount worktrees created (sharing state, knowledge, signals, and logs)"

# ============================================================================
# 16. LAUNCHER SCRIPTS + MANIFEST (always generated for GUI)
# ============================================================================
Step "Generating launcher scripts and manifest..."

$launcherDir = Join-Path $projectPath ".codex\launchers"
if (-not (Test-Path $launcherDir)) { New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null }

Step "Generating WSL launcher scripts..."

function Resolve-ModelId([string]$Alias) {
    switch ($Alias) {
        "fast" { return "codex-5.3-high" }
        "deep" { return "codex-5.3-high" }
        "economy" { return "gpt-5.2-pro" }
        "highest" { return "codex-5.3-xhigh" }
        default { return $Alias }
    }
}

function Get-AgentBanner([hashtable]$Agent, [bool]$ContinueMode) {
    $base = switch ($Agent.id) {
        "master-1" { "I AM MASTER-1 — YOUR INTERFACE (Fast)" }
        "master-2" { "I AM MASTER-2 — ARCHITECT (Deep)" }
        "master-3" { "I AM MASTER-3 — ALLOCATOR (Fast)" }
        default { "I AM $($Agent.id.ToUpper()) ($($Agent.model_alias))" }
    }
    if ($ContinueMode) { return "$base [CONTINUE]" }
    return $base
}

function Get-WslRunnerCommand([hashtable]$Agent, [bool]$ContinueMode) {
    $projectWsl = Escape-BashSingleQuoted (Convert-ToWslPath $projectPath)
    $cwdWsl = Escape-BashSingleQuoted (Convert-ToWslPath $Agent.cwd)
    $roleDocWsl = Escape-BashSingleQuoted (Convert-ToWslPath $Agent.role_doc)
    $loopDocWsl = Escape-BashSingleQuoted (Convert-ToWslPath $Agent.loop_doc)
    $mode = if ($ContinueMode) { "continue" } else { "fresh" }
    return "cd '$cwdWsl' && bash '$projectWsl/.codex/scripts/codex-runner.sh' --agent-id '$($Agent.id)' --mode '$mode' --model-alias '$($Agent.model_alias)' --cwd '$cwdWsl' --role-doc '$roleDocWsl' --loop-doc '$loopDocWsl'"
}

function Write-WslLauncherPair([hashtable]$Agent, [bool]$ContinueMode) {
    $suffix = if ($ContinueMode) { "-continue" } else { "" }
    $banner = Get-AgentBanner $Agent $ContinueMode
    $wslCommand = Get-WslRunnerCommand $Agent $ContinueMode
    $wslCommandEscaped = $wslCommand -replace '"', '\"'

    @"
Clear-Host
Write-Host "`n  ████  $banner  ████`n" -ForegroundColor Cyan
& wsl.exe -e bash -lc "$wslCommandEscaped"
"@ | Set-Content (Join-Path $launcherDir "$($Agent.id)$suffix.ps1")

    @"
@echo off
cls
echo.
echo   ████  $banner  ████
echo.
wsl.exe -e bash -lc "$wslCommandEscaped"
"@ | Set-Content (Join-Path $launcherDir "$($Agent.id)$suffix.bat")
}

$agentDefinitions = @(
    @{
        id = "master-1"; group = "masters"; role = "Interface (Fast)";
        model_alias = "fast"; model_resolved = (Resolve-ModelId "fast");
        cwd = $projectPath;
        role_doc = (Join-Path $projectPath ".codex\docs\master-1-role.md");
        loop_doc = (Join-Path $projectPath ".codex\commands\master-loop.md")
    },
    @{
        id = "master-2"; group = "masters"; role = "Architect (Deep)";
        model_alias = "deep"; model_resolved = (Resolve-ModelId "deep");
        cwd = $projectPath;
        role_doc = (Join-Path $projectPath ".codex\docs\master-2-role.md");
        loop_doc = (Join-Path $projectPath ".codex\commands\scan-codebase.md")
    },
    @{
        id = "master-3"; group = "masters"; role = "Allocator (Fast)";
        model_alias = "fast"; model_resolved = (Resolve-ModelId "fast");
        cwd = $projectPath;
        role_doc = (Join-Path $projectPath ".codex\docs\master-3-role.md");
        loop_doc = (Join-Path $projectPath ".codex\commands\scan-codebase-allocator.md")
    }
)

for ($i = 1; $i -le $workerCount; $i++) {
    $workerCwd = Join-Path $projectPath ".worktrees\wt-$i"
    $agentDefinitions += @{
        id = "worker-$i"; group = "workers"; role = "Worker $i (Deep)";
        model_alias = "deep"; model_resolved = (Resolve-ModelId "deep");
        cwd = $workerCwd;
        role_doc = (Join-Path $workerCwd "AGENTS.md");
        loop_doc = (Join-Path $workerCwd ".codex\commands\worker-loop.md")
    }
}

foreach ($agent in $agentDefinitions) {
    Write-WslLauncherPair $agent $false
    Write-WslLauncherPair $agent $true
}

Ok "Launcher scripts written (.bat, .ps1 via WSL)"

# ── Generate manifest.json for GUI ───────────────────────────────────
$manifestTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$manifestAgents = @()
foreach ($agent in $agentDefinitions) {
    $manifestAgents += @{
        id                    = $agent.id
        group                 = $agent.group
        role                  = $agent.role
        model                 = $agent.model_alias
        model_alias           = $agent.model_alias
        model_resolved        = $agent.model_resolved
        cwd                   = $agent.cwd
        launcher_win          = ".codex/launchers/$($agent.id).bat"
        launcher_win_continue = ".codex/launchers/$($agent.id)-continue.bat"
        launcher_ps1          = ".codex/launchers/$($agent.id).ps1"
        launcher_ps1_continue = ".codex/launchers/$($agent.id)-continue.ps1"
        command_fresh         = (Get-WslRunnerCommand $agent $false)
        command_continue      = (Get-WslRunnerCommand $agent $true)
    }
}

$manifest = @{
    version      = 4
    provider     = "codex"
    project_path = $projectPath
    worker_count = $workerCount
    created_at   = $manifestTimestamp
    agents       = $manifestAgents
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $launcherDir "manifest.json")
Ok "Launcher manifest.json generated"

# ============================================================================
# COMPLETE
# ============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host '  SETUP COMPLETE (v3)' -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "ARCHITECTURE:"
Write-Host "  Master-1 `(Fast`):  $projectPath `(interface - talk here`)"
Write-Host "  Master-2 `(Deep`):    $projectPath `(architect - triage + decompose`)"
Write-Host "  Master-3 `(Fast`):  $projectPath `(allocator - routes to workers`)"
for ($i = 1; $i -le $workerCount; $i++) {
    Write-Host "  Worker-$i `(Deep`):   $projectPath\.worktrees\wt-$i"
}
Write-Host ""
Write-Host "TIER ROUTING:"
Write-Host '  Tier 1: Trivial -> Master-2 executes directly (~2-5 min)'
Write-Host '  Tier 2: Single domain -> Master-2 assigns to one worker (~5-15 min)'
Write-Host '  Tier 3: Multi-domain -> Full decomposition pipeline (~20-60 min)'
Write-Host ""
Write-Host "TERMINALS AT STARTUP: 3 (masters only — workers launch on demand)"
Write-Host ""

# In headless mode, launching depends on session-mode argument
if ($Headless) {
    $launch = if ($SessionMode) { "Y" } else { "N" }
} else {
    $launch = Read-Host "Launch master terminals now? [Y/n]"
    if ([string]::IsNullOrEmpty($launch)) { $launch = "Y" }
}

if ($launch -match "^[Yy]$") {

    Write-Host ""
    Write-Host "SESSION CONTEXT" -ForegroundColor Cyan
    Write-Host ""
    Write-Host '  1) Fresh start  - wipe ALL prior conversation memory and task state'
    Write-Host '  2) Continue      - agents resume their previous sessions (retains context)'
    Write-Host ""

    if ($Headless) {
        $sessionModeChoice = if ($SessionMode) { $SessionMode } else { "1" }
    } else {
        $sessionModeChoice = Read-Host "Choose [1/2, default 1]"
        if ([string]::IsNullOrEmpty($sessionModeChoice)) { $sessionModeChoice = "1" }
    }

    $sessionFlag = ""

    if ($sessionModeChoice -eq "2") {
        Step "Continuing previous sessions (preserving context)..."
        # Clean up stale locks
        Get-ChildItem -Path $sharedStateDir -Filter "*.lockdir" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $sharedStateDir -Filter "*.lock" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $sessionFlag = "--continue"
        Ok "Sessions preserved - agents will resume where they left off"
    } else {
        Step "Resetting sessions (wiping ALL Codex CLI state)..."

        foreach ($f in @("handoff.json","codebase-map.json","fix-queue.json")) {
            '{}' | Set-Content (Join-Path $sharedStateDir $f) -ErrorAction SilentlyContinue
        }
        (New-DefaultWorkerStatus $workerCount) | Set-Content (Join-Path $sharedStateDir "worker-status.json") -ErrorAction SilentlyContinue
        '{"questions":[],"responses":[]}' | Set-Content (Join-Path $sharedStateDir "clarification-queue.json") -ErrorAction SilentlyContinue
        '{"tasks":[]}' | Set-Content (Join-Path $sharedStateDir "task-queue.json") -ErrorAction SilentlyContinue
        '{"next_id":1,"tasks":[],"last_updated_at":null}' | Set-Content (Join-Path $sharedStateDir "tasks.json") -ErrorAction SilentlyContinue
        (New-DefaultAgentHealth) | Set-Content (Join-Path $sharedStateDir "agent-health.json") -ErrorAction SilentlyContinue

        # NOTE: Knowledge files are NOT wiped on fresh start — they are persistent learnings

        $codexHome = Join-Path $env:USERPROFILE ".codex"
        Remove-Item (Join-Path $codexHome "projects") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $codexHome "history.jsonl") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $codexHome "session-env") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $codexHome "todos") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $codexHome "tasks") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $codexHome "plans") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $codexHome "shell-snapshots") -Recurse -Force -ErrorAction SilentlyContinue

        # Agents run inside WSL; wipe Linux Codex state too for a true fresh reset.
        $wslCodexReset = @'
rm -rf "$HOME/.codex/projects" "$HOME/.codex/session-env" "$HOME/.codex/todos" "$HOME/.codex/tasks" "$HOME/.codex/plans" "$HOME/.codex/shell-snapshots" 2>/dev/null || true
rm -f "$HOME/.codex/history.jsonl" 2>/dev/null || true
'@
        & wsl.exe -e bash -lc $wslCodexReset 2>$null

        Remove-Item (Join-Path $projectPath ".codex\todos.json") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $projectPath ".codex\.tasks") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $projectPath ".codex\tasks") -Recurse -Force -ErrorAction SilentlyContinue

        for ($i = 1; $i -le $workerCount; $i++) {
            $wt = Join-Path $projectPath ".worktrees\wt-$i"
            if (Test-Path $wt) {
                Remove-Item (Join-Path $wt ".codex\todos.json") -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $wt ".codex\.tasks") -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $wt ".codex\tasks") -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Clean up stale locks and signals
        Get-ChildItem -Path $sharedStateDir -Filter "*.lockdir" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $sharedStateDir -Filter "*.lock" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $signalsDir = Join-Path $projectPath ".codex\signals"
        if (Test-Path $signalsDir) {
            Get-ChildItem -Path $signalsDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }

        New-Item -ItemType Directory -Path (Join-Path $projectPath ".codex\logs") -Force | Out-Null
        $resetTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        "[$resetTimestamp] [setup] [FRESH_RESET] All sessions wiped (knowledge preserved)" | Set-Content (Join-Path $projectPath ".codex\logs\activity.log")

        $sessionFlag = ""
        Ok "Sessions FULLY reset - knowledge files PRESERVED across reset"
    }

    # ==================================================================
    # TERMINAL LAUNCH
    # ==================================================================
    Step "Launching terminals..."

    # Choose launcher scripts based on session mode
    if ($sessionFlag -eq "--continue") {
        $m1Launcher = Join-Path $launcherDir "master-1-continue.ps1"
        $m2Launcher = Join-Path $launcherDir "master-2-continue.ps1"
        $m3Launcher = Join-Path $launcherDir "master-3-continue.ps1"
    } else {
        $m1Launcher = Join-Path $launcherDir "master-1.ps1"
        $m2Launcher = Join-Path $launcherDir "master-2.ps1"
        $m3Launcher = Join-Path $launcherDir "master-3.ps1"
    }

    # Detect Windows Terminal
    $hasWt = $null -ne (Get-Command "wt" -ErrorAction SilentlyContinue)

    if ($hasWt) {
        # ── Windows Terminal: tabbed launch ─────────────────────────────
        Step "  Launching masters in Windows Terminal (WSL sessions)..."

        # Build wt command as a single string (wt requires this for semicolon-separated subcommands)
        # Titles must not contain spaces — wt splits on spaces and treats the rest as the command
        $wtMasterCmd = "-w masters" +
            " new-tab -d `"$projectPath`" --title Master-2-Architect powershell.exe -ExecutionPolicy Bypass -File `"$m2Launcher`"" +
            " `; new-tab -d `"$projectPath`" --title Master-3-Allocator powershell.exe -ExecutionPolicy Bypass -File `"$m3Launcher`"" +
            " `; new-tab -d `"$projectPath`" --title Master-1-Interface powershell.exe -ExecutionPolicy Bypass -File `"$m1Launcher`""
        Start-Process "wt.exe" -ArgumentList $wtMasterCmd
        Start-Sleep -Seconds 2
        Ok "  3 master tabs created in Windows Terminal"
        Ok "  Workers launch on demand via .codex/scripts/launch-worker.sh"

    } else {
        # ── Fallback: separate PowerShell windows ───────────────────────
        Step "  Windows Terminal not found — launching separate PowerShell windows (WSL sessions)..."

        $psArgs = '-ExecutionPolicy Bypass -File "' + $m2Launcher + '"'
        Start-Process "powershell" -ArgumentList $psArgs
        Start-Sleep -Seconds 1
        $psArgs = '-ExecutionPolicy Bypass -File "' + $m3Launcher + '"'
        Start-Process "powershell" -ArgumentList $psArgs
        Start-Sleep -Seconds 1
        $psArgs = '-ExecutionPolicy Bypass -File "' + $m1Launcher + '"'
        Start-Process "powershell" -ArgumentList $psArgs
        Start-Sleep -Seconds 1
        Ok "  3 master windows created"
        Ok "  Workers launch on demand in separate windows if needed"
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host '  MASTERS LAUNCHED (v3)' -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    if ($sessionFlag -eq "--continue") {
        Write-Host "MODE: CONTINUE - agents resuming previous sessions" -ForegroundColor Cyan
    } else {
        Write-Host "MODE: FRESH - clean sessions, persistent knowledge preserved" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host 'MASTERS WINDOW (3 tabs):'
    Write-Host '  Tab 1: MASTER-2 (Deep) - Architect (scanning, then triage + decompose)'
    Write-Host '  Tab 2: MASTER-3 (Fast) - Allocator (scanning, then routing)'
    Write-Host '  Tab 3: MASTER-1 (Fast) - Interface (talk here)'
    Write-Host ""
    Write-Host "WORKERS (on-demand launch, $workerCount worktrees ready):"
    for ($i = 1; $i -le $workerCount; $i++) {
        Write-Host "  Worker-$i (Deep): .worktrees\\wt-$i"
    }
    Write-Host ""
    Write-Host 'Tier 1 tasks (trivial): Master-2 executes directly (~2-5 min)' -ForegroundColor Yellow
    Write-Host 'Tier 2 tasks (single domain): Assigned to one worker via claim-lock (~5-15 min)' -ForegroundColor Yellow
    Write-Host 'Tier 3 tasks (multi-domain): Full decomposition pipeline (~20-60 min)' -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Workers launch ON DEMAND — no idle polling, lower cost." -ForegroundColor Yellow
    Write-Host "Knowledge persists across resets - system improves over time." -ForegroundColor Yellow
    Write-Host 'Just talk to MASTER-1 (Tab 3, Masters window)!' -ForegroundColor Yellow
    Write-Host ""
}

if ($Gui) {
    Step "Starting Agent Control Center GUI..."
    $guiDir = Join-Path $ScriptDir "gui"
    if (Test-Path $guiDir) {
        if (-not (Test-Path (Join-Path $guiDir "node_modules"))) {
            Write-Host "   Installing GUI dependencies..."
            Push-Location $guiDir
            npm install --silent 2>$null
            Pop-Location
        }
        Write-Host "   Starting control center..."
        Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
        $electronCmd = Join-Path $guiDir "node_modules\.bin\electron.cmd"
        $electronArgs = '. "' + $projectPath + '"'
        Start-Process -FilePath $electronCmd -ArgumentList $electronArgs -WorkingDirectory $guiDir -WindowStyle Normal
        Start-Sleep -Seconds 2
        Ok "Agent Control Center GUI launched!"
    } else {
        Fail "GUI directory not found"
    }
}
