# Multi-Agent Orchestration System (v3)

## Architecture

```
User → Master-1 (Sonnet) → handoff.json + .handoff-signal
         ↕ clarification-queue.json
       Master-2 (Opus) ─── TRIAGE:
         ├─ Tier 1: Execute directly (commit, PR, done)
         ├─ Tier 2: Assign to one worker directly + .worker-signal
         └─ Tier 3: Decompose → task-queue.json + .task-signal
                      ↓
       Master-3 (Sonnet) → TaskCreate(ASSIGNED_TO) + .worker-signal
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

`.claude/state/` is a shared link to `.claude-shared-state/` (junction on Windows, symlink on Unix). Always use the lock helper:
```bash
bash .claude/scripts/state-lock.sh .claude/state/<file> '<write command>'
```

## Signal Files (Instant Waking)

Agents no longer sleep-poll. After writing state, touch a signal file. The downstream agent watches it.

| Signal | Writer | Watcher | Purpose |
|--------|--------|---------|---------|
| `.claude/signals/.handoff-signal` | Master-1 | Master-2 | New request ready |
| `.claude/signals/.task-signal` | Master-2 | Master-3 | Decomposed tasks ready |
| `.claude/signals/.worker-signal` | Master-2/3 | Workers | Task assigned |
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
|------|-----------| --------|
| Tier 1 | Inline build check | Master-2 runs build command. No subagents. |
| Tier 2 | build-validator only | Haiku subagent. No verify-app. |
| Tier 3 | Full validation | Both build-validator + verify-app subagents. |
