# Multi-Agent Claude Code Workspace v3 — Windows

This folder contains the multi-agent orchestration system for **Windows**. For Mac/Linux, see `../setup-agents-mac9/`.

## Quick Start

```powershell
# Run from PowerShell
powershell -ExecutionPolicy Bypass -File setup.ps1

# Headless example
powershell -ExecutionPolicy Bypass -File setup.ps1 -Headless -RepoUrl "https://github.com/user/repo" -Workers 3 -SessionMode 1
```

## Prerequisites

```powershell
winget install Git.Git
winget install OpenJS.NodeJS
winget install GitHub.cli
npm install -g @anthropic-ai/claude-code
```

Windows Terminal (`wt`) is recommended for tabbed agent windows but not required — the installer falls back to separate PowerShell windows.

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

### Fixed (architectural issues in v8)
- **Tier 2 race condition** — added claim-before-assign protocol so Master-2 and Master-3 can't assign the same idle worker simultaneously
- **Master-3 independent scan fallback** — strengthened to do real structure+coupling scan when Master-2 is unavailable
- **Context reset thresholds** — documented rationale for each change from v7 values

### Kept from v8
- Modular 5-file structure
- Tier-based routing (Tier 1/2/3)
- Signal-based waking (polling-based on Windows)
- Living knowledge system with curation + instruction patching
- Budget-based context tracking with pre-reset distillation
- Reset staggering via agent-health.json
- Headless mode, GUI-only mode, continue-mode launchers
- Tier-dependent validation (Tier 1: inline, Tier 2: build-validator, Tier 3: full)

## Files

| # | File | What's Inside | Purpose |
|---|------|--------------|---------|
| 1 | `setup.ps1` | **Main installer script (Windows)** — preflight, project setup, directories, state init, worktrees, launchers (`.ps1`/`.bat`), terminal launch via Windows Terminal or PowerShell | Executable installer |
| 2 | `2-helper-scripts.sh` | **Runtime scripts** — `signal-wait.sh`, `state-lock.sh`, `pre-tool-secret-guard.sh`, `stop-notify.sh` (run via Git Bash) | Runtime support |
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

`setup.ps1` expects this directory layout alongside it:

```
├── setup.ps1
├── scripts/
│   ├── signal-wait.sh    (Git Bash)
│   ├── state-lock.sh     (Git Bash)
│   ├── add-worker.sh     (Git Bash)
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
└── gui/  (Electron control center)
```

## Windows-Specific Notes

| Feature | Implementation |
|---------|---------------|
| Shared state links | `New-Item -ItemType Junction` (no admin needed) |
| Terminal tabs | Windows Terminal `wt -w <name> new-tab` |
| Terminal fallback | `Start-Process powershell` (separate windows) |
| Filesystem watcher | Not checked (agents use polling) |
| Argument style | `-RepoUrl VALUE` (PowerShell params) |
| Install hint | `winget install Git.Git` etc. |

Each file in this breakdown marks its original `FILE:` path with headers.
