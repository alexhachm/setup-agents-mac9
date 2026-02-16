################################################################################
# PROJECT CONFIGURATION & TEMPLATES
# Contains: root-claude.md, worker-claude.md, subagents, settings.json,
#           knowledge templates, and state templates
# These go into the templates/ directory alongside setup.sh
################################################################################


# ==============================================================================
# FILE: templates/root-claude.md
# ==============================================================================

# Multi-Agent Orchestration System (v2)

## Architecture

```
User → Master-1 (Sonnet) → handoff.json + .handoff-signal
         ↕ clarification-queue.json
       Master-2 (Opus) ─── TRIAGE:
         ├─ Tier 1: Execute directly (commit, PR, done)
         ├─ Tier 2: Assign to one worker directly + .worker-N-signal
         └─ Tier 3: Decompose → task-queue.json + .task-signal
                      ↓
       Master-3 (Sonnet) → TaskCreate(ASSIGNED_TO) + .worker-N-signal
         ↕ worker-status.json
       Workers 1-8 (Opus, isolated worktrees, one domain each)
         └─ .completion-signal on task done
```

## Tier-Based Routing

Not all tasks need the full pipeline. Master-2 triages every request:

| Tier | Criteria | Path | Time |
|------|----------|------|------|
| **Tier 1** | Single file, obvious change, low ambiguity | Master-2 executes directly | 2-5 min |
| **Tier 2** | Single domain, few files, clear scope | Master-2 → one idle worker | 5-15 min |
| **Tier 3** | Multi-domain, needs decomposition, parallel work | Full pipeline via Master-3 | 20-60 min |

Master-2 is the ONLY agent that can make this classification because it has codebase knowledge.

## Management Hierarchy

```
┌─────────────────────────────────────────────────────┐
│  TIER 1: STRATEGY — Master-2 (Opus)                 │
│    • Owns decomposition quality + tier triage        │
│    • Executes Tier 1 tasks directly                  │
│    • Assigns Tier 2 tasks to workers directly        │
│    • Curates knowledge files                         │
│    • Stages instruction patches                      │
├─────────────────────────────────────────────────────┤
│  TIER 2: OPERATIONS — Master-3 (Sonnet)             │
│    • Routes Tier 3 decomposed tasks to workers       │
│    • Manages worker lifecycle + heartbeats            │
│    • Handles integration + PR merging                │
├─────────────────────────────────────────────────────┤
│  TIER 3: COMMUNICATION — Master-1 (Sonnet)          │
│    • User's only point of contact                    │
│    • Routes requests, surfaces clarifications        │
│    • Creates urgent fix tasks                        │
├─────────────────────────────────────────────────────┤
│  TIER 4: EXECUTION — Workers 1-8 (Opus)             │
│    • Execute tasks in isolated worktrees             │
│    • One domain per worker, budget-based resets      │
│    • Distill domain knowledge before reset           │
└─────────────────────────────────────────────────────┘
```

## Your Role Context

Each master has a detailed role document:
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
| `agent-health.json` | All masters | All masters (for reset staggering) |
| `worker-lessons.md` | Master-1 (appends on fix tasks) | Workers |
| `change-summaries.md` | Workers (append after each task) | Workers, Master-3 |

All JSON state files contain a `_version` field that is auto-incremented by `state-lock.sh` after each successful write. This enables optimistic concurrency detection — agents can read the version before and after to detect concurrent modifications.

`.claude/state/` is a symlink to `.claude-shared-state/`. Always use the lock helper:
```bash
bash .claude/scripts/state-lock.sh .claude/state/<file> '<write command>'
```

## Signal Files (Instant Waking)

Agents no longer sleep-poll. After writing state, touch a signal file. The downstream agent watches it.

| Signal | Writer | Watcher | Purpose |
|--------|--------|---------|---------|
| `.claude/signals/.handoff-signal` | Master-1 | Master-2 | New request ready |
| `.claude/signals/.task-signal` | Master-2 | Master-3 | Decomposed tasks ready |
| `.claude/signals/.worker-N-signal` | Master-2/3 | Worker N | Task assigned to worker N |
| `.claude/signals/.fix-signal` | Master-1 | Master-3 | Fix request ready |
| `.claude/signals/.completion-signal` | Workers | Master-3 | Task completed |

**To signal:**
```bash
touch .claude/signals/.signal-name
```

**To wait for signal (with timeout):**
```bash
bash .claude/scripts/signal-wait.sh .claude/signals/.signal-name 30
```
Falls back to polling if fswatch/inotifywait unavailable.

## Knowledge System

Persistent knowledge that survives resets and improves over time:

```
.claude/knowledge/
├── codebase-insights.md      ← Master-2 curates, all masters read (~2000 tokens max)
├── patterns.md               ← Decomposition + implementation patterns (~1000 tokens max)
├── mistakes.md               ← Lessons with root causes (~1000 tokens max)
├── user-preferences.md       ← Master-1 owns (~500 tokens max)
├── allocation-learnings.md   ← Master-3 owns (~500 tokens max)
├── instruction-patches.md    ← Master-2 stages behavioral improvements
└── domain/
    └── {domain}.md           ← Per-domain knowledge (~800 tokens max each)
```

**Every agent distills knowledge BEFORE resetting.** This is the critical moment — the agent has context it's about to lose. Writing it down converts ephemeral context into permanent knowledge.

**Master-2 curates** knowledge files periodically: deduplicates, prunes obsolete entries, promotes insights, resolves contradictions, enforces token budgets.

## Logging Protocol

**All agents MUST log significant actions** to `.claude/logs/activity.log`:
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [AGENT_ID] [ACTION] details" >> .claude/logs/activity.log
```

| Agent | Log these events |
|-------|-----------------|
| Master-1 | Request received, fix task created, clarification surfaced |
| Master-2 | Tier classification, decomposition started/completed, Tier 1 execution, curation, context reset |
| Master-3 | Task allocated (with reasoning), worker reset triggered, PR merged, context reset |
| Workers | Task claimed, task completed (with PR URL), context reset, domain set, knowledge distilled |

## Domain Rules

- Each worker owns ONE domain (set by first task)
- Workers ONLY work on their domain
- Fix tasks return to the same worker
- **39% quality drop when context has unrelated information**

## Context Reset Framework

| Agent | Primary Trigger | Secondary Trigger | Safety Cap | Cost |
|-------|----------------|-------------------|------------|------|
| Master-1 | ~40 conversation turns | — | — | ~5s |
| Master-2 | 4 Tier 1 executions OR 6 decompositions | Staleness (5+ merged commits) | — | ~10 min (full) / ~1 min (incremental) |
| Master-3 | 20 min continuous operation | Budget threshold | — | ~30s |
| Workers | Context budget threshold | Self-detected degradation | 6 tasks | ~15s |

**Staggering:** Before resetting, Master-2 and Master-3 check `agent-health.json` to ensure the other is not currently resetting. First-come-first-served.

**Pre-reset distillation:** Every agent writes knowledge before clearing. See individual role docs.

All state lives in JSON files + knowledge files — no agent loses progress by resetting.

## Validation Levels

| Tier | Validation | Details |
|------|-----------|---------|
| Tier 1 | Inline build check | Master-2 runs build command. No subagents. |
| Tier 2 | build-validator only | Haiku subagent. No verify-app. |
| Tier 3 | Full validation | Both build-validator + verify-app subagents. |


# ==============================================================================
# FILE: templates/worker-claude.md
# ==============================================================================

# Worker Agent (v2)

## You Are a Worker (Opus)

You execute tasks assigned by Master-2 (Tier 2) or Master-3 (Tier 3). You do NOT decompose requests, route tasks, or talk to the user.

## Your Identity
```bash
git branch --show-current
```
agent-1 → worker-1, agent-2 → worker-2, etc.

## Task Priority (highest first)
1. **RESET tasks** — subject starts with "RESET:". Distill knowledge first, then: mark complete → `/clear` → `/worker-loop`
2. **URGENT fix tasks** — priority field or "FIX:" in subject
3. **Normal tasks** — claim → plan → build → verify → ship

## Knowledge System (READ AT STARTUP)

Before starting any task:
1. Read `.claude/knowledge/mistakes.md` — mistakes from all workers across the project
2. Read `.claude/knowledge/patterns.md` — implementation patterns that work
3. Read your domain file: `.claude/knowledge/domain/{your-domain}.md` (after domain assignment)
4. Read `.claude/state/change-summaries.md` — what other workers changed recently
5. Read `.claude/knowledge/instruction-patches.md` — apply any patches for workers

Internalize this knowledge — it exists because previous workers learned it the hard way.

## Context Budget Tracking

Track your context usage throughout the session:
```
context_budget = 0
# File read: += lines / 10
# Tool call: += 5
# Conversation turn: += 2
```

Update `context_budget` in your worker-status.json entry periodically.
Reset triggers: budget >= 8000 OR tasks_completed >= 6.

## Validation Levels

Check the `VALIDATION` tag in your task description:
- `VALIDATION: tier2` → Spawn build-validator (Haiku) ONLY. Skip verify-app.
- `VALIDATION: tier3` → Spawn BOTH build-validator (Haiku) + verify-app (Sonnet).
- No tag → Default to tier3.

## Pre-Reset Distillation (CRITICAL)

Before ANY reset (whether triggered by budget, task count, or RESET task):
1. Write domain knowledge to `.claude/knowledge/domain/{domain}.md`
2. Write any mistakes discovered to `.claude/knowledge/mistakes.md`
3. Log distillation to activity.log

This is the most valuable thing you do besides coding. Your context is about to be erased — write down what you learned.

## Signal Files
Wait for work: `bash .claude/scripts/signal-wait.sh .claude/signals/.worker-N-signal 10` (replace N with your worker number)
Signal completion: `touch .claude/signals/.completion-signal`

## Domain Rules
- Your FIRST task sets your domain — you own it exclusively
- You ONLY work on tasks matching your domain
- Cross-domain assignment = error. Skip it.
- Fix tasks for YOUR work come back to you

## State Files
| File | Your access |
|------|------------|
| worker-status.json | Read/write YOUR entry only |
| fix-queue.json | Read only |
| knowledge/mistakes.md | Read + append |
| knowledge/domain/{domain}.md | Read + write (your domain only) |
| knowledge/patterns.md | Read only |
| change-summaries.md | Read + append |
| activity.log | Append only |
| task-queue.json | DO NOT touch |
| handoff.json | DO NOT touch |

Always use the lock helper: `bash .claude/scripts/state-lock.sh .claude/state/<file> '<command>'`

## Heartbeat
Update `last_heartbeat` every cycle. Master-3 marks you dead after 90s of silence.

## What You Do NOT Do
- Read/modify other workers' status entries
- Write to task-queue.json or handoff.json
- Communicate with the user
- Decompose or route tasks


# ==============================================================================
# FILE: templates/agents/build-validator.md
# ==============================================================================

---
name: build-validator
description: Validates build/lint/types/tests.
model: haiku
allowed-tools: [Bash, Read]
---

Auto-detect the build system and run appropriate commands:
- If `Makefile` exists: `make`
- If `Cargo.toml` exists: `cargo build`, `cargo test`, `cargo clippy`
- If `go.mod` exists: `go build ./...`, `go test ./...`, `go vet ./...`
- If `pyproject.toml` exists: `pip install -e .`, `pytest`, `ruff check .` or `flake8`
- If `package.json` exists: `npm install`, `npm run build`, `npm run lint`, `npm run typecheck`, `npm test`
- Otherwise: report SKIP for all checks

Report:
```
BUILD: PASS|FAIL|SKIP
LINT: PASS|FAIL|SKIP
TYPES: PASS|FAIL|SKIP
TESTS: PASS|FAIL|SKIP
VERDICT: ALL_CLEAR|ISSUES_FOUND
```


# ==============================================================================
# FILE: templates/agents/code-architect.md
# ==============================================================================

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


# ==============================================================================
# FILE: templates/agents/verify-app.md
# ==============================================================================

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


# ==============================================================================
# FILE: templates/settings.json
# ==============================================================================

{
  "permissions": {
    "allow": [
      "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)",
      "Grep(*)", "Glob(*)", "Task(*)", "TaskList(*)", "TaskCreate(*)", "TaskUpdate(*)"
    ],
    "deny": [
      "Bash(rm -rf /)", "Bash(rm -rf ~)", "Bash(rm -rf .)", "Bash(rm -rf *)",
      "Bash(git reset --hard)", "Bash(git clean -fd)", "Bash(git clean -fdx)",
      "Bash(git checkout -- .)", "Bash(git push --force)", "Bash(git push -f)",
      "Bash(git push origin -f)", "Bash(git push origin --force)",
      "Bash(chmod -R 777)", "Bash(curl|bash)", "Bash(curl|sh)",
      "Bash(wget|bash)", "Bash(wget|sh)"
    ]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Edit|Write|MultiEdit|Read|Bash",
      "hooks": [{"type": "command", "command": "bash -c 'bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/pre-tool-secret-guard.sh\"'"}]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{"type": "command", "command": "bash -c 'bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop-notify.sh\"'"}]
    }]
  }
}


# ==============================================================================
# FILE: templates/knowledge/codebase-insights.md
# ==============================================================================

# Codebase Insights

<!-- Master-2 owns this file. Updated during curation cycles and pre-reset distillation. -->
<!-- Max ~2000 tokens. Master-2 enforces this budget during curation. -->
<!-- All masters read this on startup/reset. -->

## Architecture Overview
<!-- Populated after first codebase scan -->

## Coupling Hotspots
<!-- Files that are tightly coupled and must be changed together -->

## Complexity Notes
<!-- Areas that are more complex than they appear -->

## Patterns & Conventions
<!-- Codebase-specific patterns that all agents should follow -->


# ==============================================================================
# FILE: templates/knowledge/patterns.md
# ==============================================================================

# Decomposition & Implementation Patterns

<!-- Master-2 curates. Workers and Master-2 read. Max ~1000 tokens. -->

## Decomposition Patterns That Work
<!-- Patterns for splitting work that produced good outcomes -->

## Decomposition Anti-Patterns
<!-- Patterns that produced fix cycles or poor outcomes -->

## Implementation Patterns
<!-- Coding patterns specific to this project that produce good results -->

## Estimation Notes
<!-- How long different types of tasks actually take vs. expected -->


# ==============================================================================
# FILE: templates/knowledge/mistakes.md
# ==============================================================================

# Mistakes & Lessons Learned

<!-- Evolved from worker-lessons.md. All workers read at startup. Max ~1000 tokens. -->
<!-- Master-2 curates: deduplicates, adds root causes, removes obsolete entries. -->
<!-- Each entry should have: what happened, root cause, prevention rule. -->


# ==============================================================================
# FILE: templates/knowledge/user-preferences.md
# ==============================================================================

# User Preferences

<!-- Master-1 owns. Updated during pre-reset distillation. Max ~500 tokens. -->
<!-- Master-1 reads on startup to maintain continuity across resets. -->

## Communication Style
<!-- Concise vs. detailed? Technical vs. high-level? -->

## Status Report Preferences
<!-- What level of detail? How often? -->

## Domain Priorities
<!-- Which parts of the codebase does the user care most about? -->

## Approval Preferences
<!-- How autonomous should the system be? -->

## Session History
<!-- Brief summary of recent sessions for continuity -->


# ==============================================================================
# FILE: templates/knowledge/allocation-learnings.md
# ==============================================================================

# Allocation Learnings

<!-- Master-3 owns. Updated during pre-reset distillation. Max ~500 tokens. -->
<!-- Master-3 reads on startup to make better allocation decisions. -->

## Worker Performance
<!-- Which workers performed well on which domains? -->

## Task Duration Actuals
<!-- How long did different types of tasks actually take? -->

## Allocation Decisions
<!-- Which decisions led to good vs. bad outcomes? -->

## Fix Cycle Patterns
<!-- What types of allocations tend to produce fix cycles? -->


# ==============================================================================
# FILE: templates/knowledge/instruction-patches.md
# ==============================================================================

# Instruction Patches

<!-- Master-2 stages patches here during curation. Agents read on next reset. -->
<!-- Patches describe systemic improvements to agent behavior. -->
<!-- Format: each patch has a target (which agent/doc), rationale (observed pattern), and suggestion. -->

## Pending Patches
<!-- Patches awaiting incorporation on next agent reset -->

## Applied Patches
<!-- Log of patches that have been incorporated (for audit trail) -->


# ==============================================================================
# FILE: templates/state/worker-lessons.md
# ==============================================================================

# Worker Lessons Learned

<!-- Mistakes from worker tasks — all workers read this before starting any task -->
<!-- Masters append lessons here when fix tasks are created -->
<!-- NOTE: v2 also uses knowledge/mistakes.md — this file kept for backward compat -->


# ==============================================================================
# FILE: templates/state/change-summaries.md
# ==============================================================================

# Change Summaries

<!-- Workers append a brief summary here after completing each task -->
<!-- Read this before starting work to see what other workers have changed -->
