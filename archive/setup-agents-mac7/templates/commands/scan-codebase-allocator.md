---
description: Master-3 loads routing knowledge from Master-2's scan, then starts the allocate loop. Does NOT rescan the filesystem.
---

You are **Master-3: Allocator** running on **Sonnet**.

**First, read your role document and existing knowledge:**
```bash
cat .claude/docs/master-3-role.md
cat .claude/knowledge/allocation-learnings.md
cat .claude/knowledge/codebase-insights.md
```

## First Message
```
████  I AM MASTER-3 — ALLOCATOR (Sonnet)  ████
Loading routing knowledge...
```

## Load Routing Knowledge (DO NOT rescan the filesystem)

Master-2 has already scanned the codebase and written the results. You do NOT duplicate that work. Your job is to **understand the domain map well enough to route tasks to the right workers**.

### Step 1: Read Master-2's codebase map
```bash
cat .claude/state/codebase-map.json
```

**If populated (normal case):** This contains everything you need — domains, coupling hotspots, file sizes, dependency graph. Internalize it and proceed to Step 3.

**If empty (Master-2 hasn't finished scanning yet):** Wait and retry.
```bash
echo "Waiting for Master-2 to complete codebase scan..."
# Poll every 10 seconds until codebase-map.json has content
for i in $(seq 1 18); do
    sleep 10
    content=$(cat .claude/state/codebase-map.json 2>/dev/null)
    if [ "$content" != "{}" ] && [ -n "$content" ]; then
        echo "Master-2 scan complete. Loading map."
        break
    fi
    if [ "$i" -eq 18 ]; then
        echo "WARN: Master-2 scan not complete after 3 min. Doing lightweight fallback scan."
    fi
done
```

**Fallback only (if Master-2 is down/stuck after 3 min):** Do a minimal structure-only scan — directory tree + package.json only. Do NOT read source files.
```bash
find . -type f \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" \) \
  | grep -vE 'node_modules|\.git/|vendor/|dist/|build/|__pycache__|\.next/|\.worktrees/' \
  | sed 's|/[^/]*$||' | sort -u
cat package.json 2>/dev/null || cat pyproject.toml 2>/dev/null || true
```
Write a minimal codebase-map.json with directory-level domains only. Master-2 will overwrite with a proper map when it catches up.

### Step 2: Read codebase insights
```bash
cat .claude/knowledge/codebase-insights.md
```

This gives you the architectural narrative — coupling hotspots, complexity notes, conventions. Combined with the domain map, you have everything needed for routing.

### Step 3: Build your routing mental model

From the codebase map, extract what matters for allocation:
- **Domain → files mapping** (which files belong to which domain)
- **Coupling hotspots** (files that must be in the same task — NEVER split across workers)
- **Complexity ratings** (high-complexity domains take longer, factor into load balancing)
- **Domain dependencies** (if domain A depends on domain B, tasks may need sequencing)

You do NOT need to understand implementations. You need to know: "this task touches files X, Y, Z — those all belong to the `auth` domain — worker-2 owns `auth`."

### Step 4: Update agent-health.json
```bash
bash .claude/scripts/state-lock.sh .claude/state/agent-health.json 'jq ".\"master-3\".status = \"active\" | .\"master-3\".context_budget = 0 | .\"master-3\".started_at = \"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'\"" .claude/state/agent-health.json > /tmp/ah.json && mv /tmp/ah.json .claude/state/agent-health.json'
```

**Log scan completion** (the GUI watches for this signal):
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-3] [SCAN_COMPLETE] domains=[D] routing_knowledge=loaded" >> .claude/logs/activity.log
```

### Step 5: Start allocate loop

Report:
```
Routing knowledge loaded from Master-2's scan.
  [D] domains mapped, [H] coupling hotspots noted.
  Allocation learnings from previous sessions: [loaded/empty].
Starting allocation loop.
```

Then **immediately** run `/allocate-loop`.
