# Multi-Agent Claude Code Workspace v3 — File Breakdown

This folder breaks the multi-agent orchestration system into **5 readable files**, organized by concern. v3 merges the best of v7 (mac7) and v8 (mac8), restoring content that was lost during the v7→v8 rewrite while keeping all v8 architectural improvements.

## Quick Start

```
# Mac/Linux
chmod +x 1-setup.sh && ./1-setup.sh

# Windows (PowerShell — native, no Git Bash needed)
powershell -ExecutionPolicy Bypass -File setup.ps1

# Windows (headless example)
powershell -ExecutionPolicy Bypass -File setup.ps1 -Headless -RepoUrl "https://github.com/user/repo" -Workers 3 -SessionMode 1
```

## v3 Changelog (vs v8)

### Restored from v7 (lost during v7→v8 rewrite)
- **Master-1 Performance Rules** — "you are a router, not an analyst" guardrails
- **Qualitative self-monitoring** — "list domains from memory" checks alongside counters
- **Adaptive polling** — shorter waits when active, longer when idle (within signal framework)
- **Self-contained Master-3 role doc** — replaced "(Same as v1)" stubs with full allocation rules + worker lifecycle
- **Worker status JSON schema** — explicit example with all fields including `awaiting_approval`
- **Worker emergency commands** — documented escape hatch for stuck workers
- **Worker task protocol quick-reference** — numbered steps in worker CLAUDE.md
- **Escalation paths** — what happens when things break, in root CLAUDE.md
- **Cross-platform launchers** — .bat/.ps1 generation restored

### Fixed (architectural issues in v8)
- **Tier 2 race condition** — added claim-before-assign protocol so Master-2 and Master-3 can't assign the same idle worker simultaneously
- **Master-3 independent scan fallback** — strengthened to do real structure+coupling scan when Master-2 is unavailable
- **Context reset thresholds** — documented rationale for each change from v7 values

### Kept from v8
- Modular 5-file structure
- Tier-based routing (Tier 1/2/3)
- Signal-based waking (fswatch/inotifywait + polling fallback)
- Living knowledge system with curation + instruction patching
- Budget-based context tracking with pre-reset distillation
- Reset staggering via agent-health.json
- Headless mode, GUI-only mode, continue-mode launchers
- Tier-dependent validation (Tier 1: inline, Tier 2: build-validator, Tier 3: full)

## Files

| # | File | What's Inside | Purpose |
|---|------|--------------|---------|
| 1 | `1-setup.sh` | **Main installer script (Mac/Linux)** — preflight, project setup, directories, state init, worktrees, launchers, terminal launch via osascript | Executable installer |
| 1w | `setup.ps1` | **Main installer script (Windows)** — same functionality as `1-setup.sh`, native PowerShell. Uses directory junctions, Windows Terminal tabs (`wt`), PowerShell fallback | Windows installer |
| 2 | `2-helper-scripts.sh` | **Runtime scripts** — `signal-wait.sh`, `state-lock.sh`, `pre-tool-secret-guard.sh`, `stop-notify.sh` | Runtime support |
| 3 | `3-project-config-and-templates.md` | **Project config** — `root-claude.md`, `worker-claude.md`, subagents, `settings.json`, knowledge templates, state templates | Template content |
| 4 | `4-master-role-documents.md` | **Role docs** — Master-1 (Interface), Master-2 (Architect), Master-3 (Allocator) full self-contained specifications | Agent identity |
| 5 | `5-command-loops.md` | **Commands** — `master-loop`, `architect-loop`, `allocate-loop`, `worker-loop`, `scan-codebase`, `scan-codebase-allocator`, `commit-push-pr` | Agent behavior |

## Architecture Quick Reference

```
User → Master-1 (Sonnet) → Master-2 (Opus) triage:
         ├─ Tier 1: M2 executes directly               (~2-5 min)
         ├─ Tier 2: M2 → one worker (claim-lock)       (~5-15 min)
         └─ Tier 3: M2 → Master-3 → Workers            (~20-60 min)
```

## How to Reassemble

Both `1-setup.sh` (Mac/Linux) and `setup.ps1` (Windows) expect this directory layout alongside them:

```
├── 1-setup.sh      (Mac/Linux)
├── setup.ps1       (Windows)
├── scripts/
│   ├── signal-wait.sh
│   ├── state-lock.sh
│   ├── add-worker.sh
│   └── hooks/
│       ├── pre-tool-secret-guard.sh
│       └── stop-notify.sh
├── templates/
│   ├── root-claude.md
│   ├── worker-claude.md
│   ├── settings.json
│   ├── docs/
│   │   ├── master-1-role.md
│   │   ├── master-2-role.md
│   │   └── master-3-role.md
│   ├── commands/
│   │   ├── master-loop.md
│   │   ├── architect-loop.md
│   │   ├── allocate-loop.md
│   │   ├── worker-loop.md
│   │   ├── scan-codebase.md
│   │   ├── scan-codebase-allocator.md
│   │   └── commit-push-pr.md
│   ├── agents/
│   │   ├── build-validator.md
│   │   ├── code-architect.md
│   │   └── verify-app.md
│   ├── knowledge/
│   │   ├── codebase-insights.md
│   │   ├── patterns.md
│   │   ├── mistakes.md
│   │   ├── user-preferences.md
│   │   ├── allocation-learnings.md
│   │   └── instruction-patches.md
│   └── state/
│       ├── worker-lessons.md
│       └── change-summaries.md
└── gui/  (unchanged from v1, not included)
```

Each file in this breakdown marks its original `FILE:` path with headers.

## Windows vs Mac/Linux Differences

| Feature | Mac/Linux (`1-setup.sh`) | Windows (`setup.ps1`) |
|---------|--------------------------|----------------------|
| Shared state links | `ln -sf` (symlinks) | `New-Item -ItemType Junction` (no admin needed) |
| Terminal tabs | osascript + "Merge All Windows" | Windows Terminal `wt -w <name> new-tab` |
| Terminal fallback | Separate Terminal.app windows | `Start-Process powershell` |
| Filesystem watcher | fswatch / inotifywait | Not checked (agents use polling) |
| Argument style | `--repo-url=VALUE` | `-RepoUrl VALUE` (PowerShell params) |
| Install hint | `brew install git node gh` | `winget install Git.Git` etc. |
