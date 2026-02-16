# Multi-Agent Claude Code Workspace — File Breakdown

This repository contains the multi-agent orchestration system in **5 readable files**, organized by concern, with platform-specific installers.

## Platform Packages

| Directory | Platform | Installer | Launch |
|-----------|----------|-----------|--------|
| `setup-agents-mac9/` | Mac/Linux | `1-setup.sh` | Terminal.app tabs via osascript |
| `setup-agents-windows9/` | Windows | `setup.ps1` | Windows Terminal tabs or PowerShell windows |

Both packages share the same templates, scripts, commands, and GUI — only the installer and launcher generation differs.

## Quick Start

```bash
# Mac/Linux
cd setup-agents-mac9
chmod +x 1-setup.sh && ./1-setup.sh

# Windows (PowerShell)
cd setup-agents-windows9
powershell -ExecutionPolicy Bypass -File setup.ps1
```

## Files (shared across both packages)

| # | File | What's Inside |
|---|------|--------------|
| 1 | `1-setup.sh` / `setup.ps1` | **Main installer script** — preflight, project setup, directories, state init, worktrees, terminal launch |
| 2 | `2-helper-scripts.sh` | **Runtime scripts** — `signal-wait.sh`, `state-lock.sh`, `pre-tool-secret-guard.sh`, `stop-notify.sh` |
| 3 | `3-project-config-and-templates.md` | **Project config** — `root-claude.md`, `worker-claude.md`, subagents, `settings.json`, knowledge templates, state templates |
| 4 | `4-master-role-documents.md` | **Role docs** — Master-1 (Interface), Master-2 (Architect), Master-3 (Allocator) full role specifications |
| 5 | `5-command-loops.md` | **Commands** — `master-loop`, `architect-loop`, `allocate-loop`, `worker-loop`, `scan-codebase`, `scan-codebase-allocator`, `commit-push-pr` |

## Architecture Quick Reference

```
User → Master-1 (Sonnet) → Master-2 (Opus) triage:
         ├─ Tier 1: M2 executes directly     (~2-5 min)
         ├─ Tier 2: M2 → one worker          (~5-15 min)
         └─ Tier 3: M2 → Master-3 → Workers  (~20-60 min)
```

## Archive

Older versions and redundant root-level docs are preserved in `archive/`:

| Path | Description |
|------|-------------|
| `archive/setup-agents-mac7/` | v2 (Mac/Linux only, predecessor) |
| `archive/1-setup.sh` … `archive/5-command-loops.md` | Root-level copies of the doc breakdown (superseded by the per-platform packages) |

Each file in the breakdown clearly marks its original `FILE:` path with headers.
