# Multi-Agent Claude Code Workspace v2 — File Breakdown

This folder breaks the consolidated `setup-agents-8cons.sh` into **5 readable files**, organized by concern.

## Files

| # | File | What's Inside | Original ~Lines |
|---|------|--------------|-----------------|
| 1 | `1-setup.sh` | **Main installer script** — preflight, project setup, directories, state init, worktrees, terminal launch (macOS) | 1–759 |
| 2 | `2-helper-scripts.sh` | **Runtime scripts** — `signal-wait.sh`, `state-lock.sh`, `pre-tool-secret-guard.sh`, `stop-notify.sh` | 762–701 |
| 3 | `3-project-config-and-templates.md` | **Project config** — `root-claude.md` (architecture doc), `worker-claude.md`, subagents (`build-validator`, `code-architect`, `verify-app`), `settings.json`, all knowledge templates, state templates | 942–1116, 2404–2540 |
| 4 | `4-master-role-documents.md` | **Role docs** — Master-1 (Interface), Master-2 (Architect), Master-3 (Allocator) full role specifications | 1117–1367 |
| 5 | `5-command-loops.md` | **Command definitions** — `master-loop`, `architect-loop`, `allocate-loop`, `worker-loop`, `scan-codebase`, `scan-codebase-allocator`, `commit-push-pr` | 1370–2402 |

## Architecture Quick Reference

```
User → Master-1 (Sonnet) → Master-2 (Opus) triage:
         ├─ Tier 1: M2 executes directly     (~2-5 min)
         ├─ Tier 2: M2 → one worker          (~5-15 min)
         └─ Tier 3: M2 → Master-3 → Workers  (~20-60 min)
```

## How to Reassemble

The original file is a heredoc-wrapped reference. To actually use this system, the `setup.sh` script (file 1) expects this directory layout alongside it:

```
├── setup.sh
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

Each file in this breakdown clearly marks its original `FILE:` path with headers.
