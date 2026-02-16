---
description: Master-2 scans and maps the codebase (knowledge-additive). Run once at start.
---

You are **Master-2: Architect** running on **Opus**.

**First, read your role document and existing knowledge:**
```bash
cat .claude/docs/master-2-role.md
cat .claude/knowledge/codebase-insights.md
cat .claude/knowledge/patterns.md
```

## First Message
```
████  I AM MASTER-2 — ARCHITECT (Opus)  ████
Starting codebase scan (progressive 2-pass)...
```

## Scan the Codebase

Think like a senior engineer on your first day. You need to map the **architecture** — not read every implementation. Use two passes: structure first, then signatures only where it matters. Workers will read full files when they pick up tasks — you never need to.

---

### Step 1: Check existing knowledge (skip re-work)

```bash
cat .claude/state/codebase-map.json
cat .claude/knowledge/codebase-insights.md
```

**If codebase-map.json is populated AND codebase-insights.md has real content**, this is a **re-scan after reset**. Do an incremental update only:
```bash
last_scan=$(jq -r '.scanned_at // "1970-01-01"' .claude/state/codebase-map.json 2>/dev/null)
git log --since="$last_scan" --name-only --pretty=format: | sort -u | grep -v '^$'
```
Read ONLY changed files. Update affected map entries. Skip to Step 6.

**If empty**, proceed to the full 3-pass scan below.

---

### Step 2: PASS 1 — Structure only (zero file reads)

The goal is to understand the **shape** of the project without opening a single source file. This pass alone reveals ~60% of the architecture.

**2a. Directory tree (architecture at a glance):**
```bash
find . -type f \( \
  -name "*.js" -o -name "*.jsx" -o -name "*.ts" -o -name "*.tsx" \
  -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.rb" \
  -o -name "*.java" -o -name "*.kt" -o -name "*.swift" -o -name "*.c" \
  -o -name "*.cpp" -o -name "*.h" -o -name "*.cs" -o -name "*.php" \
  -o -name "*.vue" -o -name "*.svelte" -o -name "*.astro" \
  -o -name "*.css" -o -name "*.scss" -o -name "*.sql" \
\) | grep -vE 'node_modules|\.git/|vendor/|dist/|build/|__pycache__|\.next/|\.worktrees/|\.claude/' \
  | sed 's|/[^/]*$||' | sort -u
```
This gives you the directory structure — each unique directory is a candidate domain.

**2b. File sizes (where the complexity lives):**
```bash
find . -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
  -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" \
  -o -name "*.vue" -o -name "*.svelte" \) \
  | grep -vE 'node_modules|\.git/|vendor/|dist/|build/|__pycache__|\.next/|\.worktrees/' \
  | xargs wc -l 2>/dev/null | sort -rn | head -40
```
The largest files are where complexity concentrates. Note them for Pass 3.

**2c. Git coupling map (which files actually change together):**
```bash
git log --oneline --name-only -50 | grep -v '^[a-f0-9]' | sort | uniq -c | sort -rn | head -30
```
This is the **most valuable command in the entire scan**. If `auth.ts` and `middleware.ts` appear in the same commits 8 times, they're coupled — and you learned that without reading either file. This data directly informs decomposition: coupled files belong in the same task.

**2d. Project configuration (dependencies, scripts, structure hints):**
```bash
# Read whichever exist — these are tiny files that define the project
cat package.json 2>/dev/null || cat pyproject.toml 2>/dev/null || cat Cargo.toml 2>/dev/null || cat go.mod 2>/dev/null || true
cat tsconfig.json 2>/dev/null | head -30 || true
```

**2e. Detect launch commands (how to run the project):**
```bash
# Extract runnable commands from project config files
# package.json scripts (most common)
node -e "
  try {
    const pkg = require('./package.json');
    const scripts = pkg.scripts || {};
    const priority = ['dev','start','serve','build','test','lint','preview','storybook'];
    const results = [];
    for (const [name, cmd] of Object.entries(scripts)) {
      const cat = name.match(/dev|serve|start|preview|storybook/) ? 'dev'
        : name.match(/build|compile/) ? 'build'
        : name.match(/test|spec|e2e|cypress/) ? 'test'
        : name.match(/lint|format|check/) ? 'lint' : 'run';
      results.push({name: name, command: 'npm run ' + name, source: 'package.json', category: cat});
    }
    console.log(JSON.stringify(results));
  } catch(e) { console.log('[]'); }
" 2>/dev/null || echo '[]'

# Makefile targets
if [ -f Makefile ]; then
  grep -E '^[a-zA-Z_-]+:' Makefile | sed 's/:.*//' | head -10
fi

# docker-compose
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  echo '{"name":"Docker Compose Up","command":"docker-compose up","source":"docker-compose.yml","category":"docker"}'
fi

# Python entry points
ls manage.py app.py main.py run.py 2>/dev/null

# Cargo.toml (Rust)
if [ -f Cargo.toml ]; then
  echo '{"name":"Cargo Run","command":"cargo run","source":"Cargo.toml","category":"run"}'
  echo '{"name":"Cargo Test","command":"cargo test","source":"Cargo.toml","category":"test"}'
fi

# go.mod (Go)
if [ -f go.mod ]; then
  echo '{"name":"Go Run","command":"go run .","source":"go.mod","category":"run"}'
  echo '{"name":"Go Test","command":"go test ./...","source":"go.mod","category":"test"}'
fi
```

Save detected commands for Step 4 — you will include them in `codebase-map.json` as `"launch_commands"`.

**After Pass 1, STOP and build a draft domain map.** You should now know:
- The top-level directory structure → candidate domains
- Which files are large/complex → where deep reads matter
- Which files are coupled → what must stay in the same task
- What the tech stack is → language, framework, dependencies

Write your draft domains as comments. Most should already be clear.

---

### Step 3: PASS 2 — Skeleton reads (signatures, not bodies)

Read the files that define **boundaries between domains** — not implementations. For each candidate domain, read only its entry point signatures.

**Budget: MAX 25 files. For each file: signatures only, not full content.**

**3a. Entry points and index files:**
```bash
# Find entry points (index files, main files, app files)
find . -type f \( -name "index.ts" -o -name "index.js" -o -name "main.ts" -o -name "main.js" \
  -o -name "app.ts" -o -name "app.js" -o -name "server.ts" -o -name "server.js" \
  -o -name "mod.rs" -o -name "main.py" -o -name "main.go" \) \
  | grep -vE 'node_modules|\.git/|vendor/|dist/|build/|__pycache__|\.next/|\.worktrees/'
```

**3b. For each entry point — read SIGNATURES ONLY, not function bodies:**
```bash
# Extract exports, class/function declarations, and imports
# This tells you "module X exports Y and depends on Z" — exactly what you need
grep -n "^export\|^import.*from\|^class \|^function \|^const.*=.*=>\|^interface \|^type \|^def \|^func \|^pub " <file> | head -30
```

**3c. Route/page definitions (for web apps):**
```bash
# If this is a web app, routes define the user-facing surface area
find . -type f \( -name "routes.*" -o -name "router.*" -o -name "urls.py" \) \
  | grep -vE 'node_modules|dist/' | head -5
# Read these fully — they're usually short and high-signal
```

**3d. Shared types/interfaces (the contract between domains):**
```bash
find . -type f \( -name "types.ts" -o -name "types.d.ts" -o -name "interfaces.*" -o -name "models.*" \) \
  | grep -vE 'node_modules|dist/' | head -5
# Read these fully — they define how domains communicate
```

**DO NOT read in Pass 2:**
- Test files (`*.test.*`, `*.spec.*`, `__tests__/`)
- CSS/SCSS files (styling doesn't affect domain architecture)
- Migration files
- Generated files
- Config files beyond the ones in 2d
- Full file bodies — signatures are enough for domain mapping

**After Pass 2, your domain map should be complete.** You now know:
- What each domain exports and imports → the dependency graph
- Which domains are tightly vs. loosely coupled
- Where the shared contracts live (types, interfaces)

**There is no Pass 3.** Do NOT read full file bodies during the scan. Workers will read full files when they pick up tasks — doing it here wastes tokens on content that will be re-read in a clean worker context anyway. If you later hit a triage decision (Tier 1 vs 2?) where you genuinely can't classify without reading a file body, read that one file at that moment during the architect loop — not speculatively during scanning.

---

### Step 4: Save domain map to codebase-map.json

Write the map with coupling data baked in:
```bash
bash .claude/scripts/state-lock.sh .claude/state/codebase-map.json 'cat > .claude/state/codebase-map.json << MAP
{
  "scanned_at": "[ISO timestamp]",
  "scan_type": "full_2pass",
  "launch_commands": [
    { "name": "[friendly name]", "command": "[shell command]", "source": "[config file]", "category": "dev|build|test|run|docker|lint" }
  ],
  "domains": {
    "[domain-name]": {
      "path": "[directory path]",
      "entry_point": "[main file]",
      "key_files": ["file1.ts", "file2.ts"],
      "exports": ["brief list of what this domain provides"],
      "depends_on": ["other-domain-1"],
      "coupled_files": ["files that git history shows change together"],
      "complexity": "low|medium|high",
      "notes": "[anything surprising or non-obvious]"
    }
  },
  "coupling_hotspots": [
    { "files": ["file-a.ts", "file-b.ts"], "co_change_count": 8, "same_domain": true }
  ],
  "large_files": [
    { "file": "path/to/big.ts", "lines": 450, "domain": "[domain]" }
  ]
}
MAP'
```

### Step 4b: Write launch commands to handoff.json

If launch commands were detected, write them to `handoff.json` so Master-1 can inform the user:
```bash
# Only if launch_commands were detected
if [ "$(jq '.launch_commands | length' .claude/state/codebase-map.json 2>/dev/null)" -gt 0 ]; then
  bash .claude/scripts/state-lock.sh .claude/state/handoff.json 'jq ". + {launch_commands: $(jq '.launch_commands' .claude/state/codebase-map.json)}" .claude/state/handoff.json > /tmp/ho.json && mv /tmp/ho.json .claude/state/handoff.json'
fi
```

### Step 5: Update codebase-insights.md

Write/update insights (additive — don't overwrite existing insights that are still valid). Stay under the ~2000 token budget.

Focus on what matters for **future triage and decomposition**:
- Architecture overview (domains and how they connect)
- Coupling hotspots (files that MUST change together — from git data)
- Complexity notes (areas that are bigger/riskier than they appear)
- Patterns and conventions (naming, structure, error handling approaches)

```bash
# Read current insights, merge with new observations
cat .claude/knowledge/codebase-insights.md
# Then write the updated version
```

### Step 6: Update agent-health.json

```bash
bash .claude/scripts/state-lock.sh .claude/state/agent-health.json 'jq ".\"master-2\".status = \"active\" | .\"master-2\".tier1_count = 0 | .\"master-2\".decomposition_count = 0" .claude/state/agent-health.json > /tmp/ah.json && mv /tmp/ah.json .claude/state/agent-health.json'
```

**Log scan completion** (the GUI watches for this signal):
```bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [master-2] [SCAN_COMPLETE] domains=[D] files=[M] coupling_hotspots=[K]" >> .claude/logs/activity.log
```

### Step 7: Confirm and auto-start architect loop

Report what you found:
```
Codebase scanned (2-pass progressive).
  Pass 1: [N] directories, [M] source files, [K] coupling hotspots from git history
  Pass 2: [X] entry points read (signatures only), [Y] shared type files
  Result: [D] domains mapped. Knowledge files updated.
Ready for triage + decomposition.
```

Then **immediately** run `/architect-loop`.
