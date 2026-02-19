---
description: Worker loop — launch on demand, do task, exit when idle. No infinite polling.
---

You are a **Worker** running on **Deep**. Check your branch to know your ID:
```bash
git branch --show-current
```
- agent-1 → worker-1, agent-2 → worker-2, etc.

## Phase 1: Startup

1. Determine your worker ID from branch name
2. Set status to "running" in worker-status.json:
```bash
bash .codex/scripts/state-lock.sh .codex/state/worker-status.json 'jq ".\"worker-N\".status = \"running\" | .\"worker-N\".last_heartbeat = \"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'\"" .codex/state/worker-status.json > /tmp/ws.json && mv /tmp/ws.json .codex/state/worker-status.json'
```

3. Announce:
```
████  I AM WORKER-N (Deep)  ████

Domain: none (assigned on first task)
Status: running, checking for assigned task...
```

4. **Read knowledge files (CRITICAL — do this before any work):**
```bash
cat .codex/knowledge/mistakes.md
cat .codex/knowledge/patterns.md
cat .codex/knowledge/instruction-patches.md
```
Apply any pending patches targeted at workers.

Internalize the mistakes — they are hard-won knowledge from this project.

5. **Read legacy lessons (backward compat):**
```bash
cat .codex/state/worker-lessons.md
```

## Internal Budget Tracking
```
context_budget = 0
# Increment after each action:
#   File read: += lines_in_file / 10
#   Tool call: += 5
#   Conversation turn: += 2
# Reset threshold: 8000 (configurable)
# Hard cap: 6 tasks completed
```

## Native Agent Teams Burst Mode (Experimental, Narrow Use)

Use native teammate delegation only when `CODEX_EXPERIMENTAL_AGENT_TEAMS=1` is set.

Allowed use cases:
- Complex debugging with competing root-cause hypotheses
- Tasks touching 5+ files where you need fast parallel reconnaissance
- High-risk validation planning (tests, rollback checks, edge-case sweeps)

Hard limits:
- Max 1 teammate burst per task unless you are still blocked
- First burst should be read-only analysis; apply edits yourself
- Teammates must not run `/commit-push-pr` and must not edit shared state files
- You remain owner of final code changes, validation, and PR

Logging:
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [worker-N] [TEAM_BURST] task=\"[subject]\" purpose=\"[reason]\" teammates=[N]" >> .codex/logs/activity.log
```

## Phase 2: Find and Execute Task

### Step 1: Check for assigned task
```bash
bash .codex/scripts/task-api.sh list
```

Look for tasks where:
- Description contains `ASSIGNED_TO: worker-N` (your ID)
- Status is "pending" or "open"

**If no task found:** Wait 5 seconds, then check once more:
```bash
sleep 5
bash .codex/scripts/task-api.sh list
```
If still no task → go to **Phase 3 (No-Task Exit)**.

**RESET tasks take absolute priority.** If subject starts with "RESET:":
1. **Distill first** (Phase 4)
2. Mark task complete
3. Update worker-status.json: `status: "idle", tasks_completed: 0, domain: null, context_budget: 0`
4. **EXIT** (terminal will close)

Also check for URGENT fix tasks (priority over normal).

### Step 2: Validate domain

**If this is your FIRST task:**
- Extract DOMAIN from task description
- This becomes YOUR domain
- Update worker-status.json
- **Read domain knowledge:**
```bash
domain_file=".codex/knowledge/domain/[DOMAIN].md"
if [ -f "$domain_file" ]; then
    cat "$domain_file"
fi
```

**If you already have a domain:**
- Check domain match. Mismatch = error, skip task, set "idle", **EXIT**.

### Step 3: Claim and work

1. **Heartbeat:** Update `last_heartbeat` in worker-status.json

2. **Claim:** `bash .codex/scripts/task-api.sh claim --id [task-id] --owner worker-N`

3. **Update status** (with lock): status="busy", current_task="[subject]"

4. **Read recent changes:**
```bash
cat .codex/state/change-summaries.md
```
`context_budget += 20`

5. **Announce:** CLAIMED: [task subject], Domain: [domain], Files: [files]

6. Optional teammate burst (only when criteria above are met): run read-only teammate analysis, then synthesize your own plan.

7. **Plan** (Shift+Tab twice for Plan Mode if complex)
`context_budget += 30`

8. **Review** (if 5+ files): Spawn code-architect subagent
`context_budget += 100`

9. **Build:** Implement changes following existing patterns
`context_budget += (files_read × lines / 10) + (edits × 20)`

10. **Verify** (based on VALIDATION tag in task description):
   - If `VALIDATION: tier2` → Spawn build-validator only (Economy)
   - If `VALIDATION: tier3` → Spawn both build-validator + verify-app
   - If no tag → Default to tier3 validation
   `context_budget += 50 per subagent`

11. **Ship:** `/commit-push-pr`

### Step 4: Complete task

1. **Update status:** status="completed_task", last_pr="[URL]", increment tasks_completed

2. **Mark task:** `bash .codex/scripts/task-api.sh complete --id [task-id]`

3. **Signal Master-3:**
```bash
touch .codex/signals/.completion-signal
```

4. **Log completion:**
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [worker-N] [COMPLETE] task=\"[subject]\" pr=[URL] tasks_completed=[N] budget=[context_budget]" >> .codex/logs/activity.log
```

5. **Write change summary:**
```bash
bash .codex/scripts/state-lock.sh .codex/state/change-summaries.md 'cat >> .codex/state/change-summaries.md << SUMMARY

## [ISO timestamp] worker-N | domain: [domain] | task: "[subject]"
**Files changed:** [list]
**What changed:** [2-3 sentences — focus on interface changes, shared state, anything other workers need to know]
**PR:** [URL]
---
SUMMARY'
```

6. **Check reset triggers:**
   - If `context_budget >= 8000` → go to **Phase 4 (Budget/Reset Exit)**
   - If `tasks_completed >= 6` → go to **Phase 4 (Budget/Reset Exit)**
   - Otherwise → go to **Phase 3 (Follow-Up Check)**

## Phase 3: After Task / Follow-Up Check

### If coming from Phase 2 (just completed a task):

Wait ONCE for a follow-up task assignment (15 seconds):
```bash
bash .codex/scripts/signal-wait.sh .codex/signals/.worker-signal 15
bash .codex/scripts/task-api.sh list
```

Look for tasks where:
- Description contains `ASSIGNED_TO: worker-N` (your ID)
- Status is "pending" or "open"

**If new task found:** → go back to **Phase 2, Step 2** (validate domain).

**If no task found:**
1. Distill knowledge (lightweight — domain knowledge file only, skip mistakes.md unless you hit problems):
```bash
domain_file=".codex/knowledge/domain/[YOUR_DOMAIN].md"
bash .codex/scripts/state-lock.sh "$domain_file" 'cat > "$domain_file" << DOMAIN
# Domain: [YOUR_DOMAIN]
<!-- Updated [ISO timestamp] by worker-N. Max ~800 tokens. -->

## Key Files
[list the important files and what they do]

## Gotchas & Undocumented Behavior
[things that surprised you, race conditions, non-obvious dependencies]

## Patterns That Work
[implementation approaches that produced good results in this domain]

## Testing Strategy
[how to verify changes in this domain]

## Recent State
[current state of the code — what was just changed, what might still need work]
DOMAIN'
```
2. Update worker-status.json: `status: "idle", current_task: null`
3. Log: `[IDLE_EXIT] domain=[domain] budget=[context_budget] tasks=[tasks_completed]`
4. **EXIT** (terminal will close — Masters will relaunch when needed)

### If arriving at Phase 3 from Phase 2 Step 1 (no task on startup):

1. Update worker-status.json: `status: "idle"`
2. Log: `[NO_TASK_EXIT] worker-N found no assigned task`
3. **EXIT** (terminal will close — Masters will relaunch when needed)

## Phase 4: Budget/Reset Exit

**This is the most important step. You have rich context you're about to lose.**

1. **Write domain knowledge:**
```bash
domain_file=".codex/knowledge/domain/[YOUR_DOMAIN].md"
bash .codex/scripts/state-lock.sh "$domain_file" 'cat > "$domain_file" << DOMAIN
# Domain: [YOUR_DOMAIN]
<!-- Updated [ISO timestamp] by worker-N. Max ~800 tokens. -->

## Key Files
[list the important files and what they do]

## Gotchas & Undocumented Behavior
[things that surprised you, race conditions, non-obvious dependencies]

## Patterns That Work
[implementation approaches that produced good results in this domain]

## Testing Strategy
[how to verify changes in this domain]

## Recent State
[current state of the code — what was just changed, what might still need work]
DOMAIN'
```

2. **Write to mistakes.md if you encountered issues:**
```bash
# Only if you hit problems during this session
bash .codex/scripts/state-lock.sh .codex/knowledge/mistakes.md 'cat >> .codex/knowledge/mistakes.md << MISTAKE

### [Date] - [Brief description of issue]
- **What went wrong:** [what happened]
- **Root cause:** [why it happened]
- **Prevention rule:** [how to avoid it]
- **Domain:** [domain]
MISTAKE'
```

3. **Log distillation:**
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [worker-N] [DISTILL] domain=[domain] budget=[context_budget] tasks=[tasks_completed]" >> .codex/logs/activity.log
```

4. **Reset status and EXIT:**
- Update worker-status.json: `status: "idle", tasks_completed: 0, domain: null, context_budget: 0`
- **EXIT** (terminal will close — Masters will relaunch when needed)

## Domain Rules Summary
- ONE domain, set by first task
- ONLY work on tasks in your domain
- Fix tasks for your work come back to YOU

## Self-Check

After every 2nd completed task, check your own context health:
- Can you recall the files you modified and why?
- Are you re-reading files you already read earlier in this session?
- Are your responses getting slower or less focused?

If you notice degradation, finish your current task and then go to Phase 4 (Budget/Reset Exit) — don't wait for the budget threshold. Proactive resets are always better than degraded output.

## Emergency Commands

If something goes wrong:
- Update worker-status.json to `status: "idle"`, then **EXIT**
- If task is impossible: mark task as blocked with a note, set "idle", **EXIT**

## What You Do NOT Do
- Read/modify other workers' status entries
- Write to task-queue.json or handoff.json
- Communicate with the user
- Decompose or route tasks
- Run in an infinite loop — you EXIT when idle
