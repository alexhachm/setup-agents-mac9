#!/usr/bin/env bash
# ============================================================================
# CONSOLIDATED CODEBASE - ALL FILES IN ONE
# ============================================================================
# This file contains the entire multi-agent orchestration codebase in a single
# location for reference purposes. All code is commented out.
#
# Generated: $(date)
# ============================================================================

: << 'END_CONSOLIDATED_CODEBASE'

################################################################################
# FILE: setup.sh
# Main setup script for multi-agent Claude Code workspace
################################################################################

#!/usr/bin/env bash
# ============================================================================
# MULTI-AGENT CLAUDE CODE WORKSPACE — MAC/LINUX (THREE-MASTER)
# ============================================================================
# Architecture:
#   - Master-1: Interface (clean context, user comms, surfaces clarifications)
#   - Master-2: Architect (codebase context, decomposes into granular tasks)
#   - Master-3: Allocator (domain map, routes tasks, monitors workers, merges)
#   - Workers 1-8: Isolated context per domain, strict grouping
#
# Key insight: decomposition is creative (needs thought + codebase knowledge),
# allocation is operational (needs speed + reliability). Mixing them in one
# agent means the polling loop interrupts good decomposition and complex
# requests get rushed mid-allocation-cycle.
#
# Data flow (one-directional except async clarifications):
#   Intent:          Master-1 → Master-2 (handoff.json)
#   Decomposed work: Master-2 → Master-3 (task-queue.json)
#   Clarifications:  Master-2 → Master-1 → User → Master-1 → Master-2
#   Status:          Workers → Master-3 (worker-status.json)
#
# USAGE: chmod +x setup.sh && ./setup.sh
# ============================================================================

set -e

# Parse arguments
LAUNCH_GUI=false
for arg in "$@"; do
    case $arg in
        --gui) LAUNCH_GUI=true; shift ;;
    esac
done

# ── Resolve script directory (where templates/ and scripts/ live) ──────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step()  { echo -e "\n${CYAN}>> $1${NC}"; }
ok()    { echo -e "   ${GREEN}OK:${NC} $1"; }
skip()  { echo -e "   ${YELLOW}SKIP:${NC} $1"; }
fail()  { echo -e "   ${RED}FAIL:${NC} $1"; }

MAX_WORKERS=8

# [... rest of setup.sh content - see original file for full implementation ...]

################################################################################
# FILE: scripts/dashboard.sh
# Worker dashboard display
################################################################################

#!/usr/bin/env bash
# ============================================================================
# WORKER DASHBOARD — Shown when terminal tabs finish formatting
# ============================================================================

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

clear

# Get terminal dimensions
COLS=$(tput cols 2>/dev/null || echo 80)

# Center helper function
center() {
    local text="$1"
    local width=${#text}
    local padding=$(( (COLS - width) / 2 ))
    printf "%*s%s\n" $padding "" "$text"
}

# [... rest of dashboard.sh ...]

################################################################################
# FILE: scripts/add-worker.sh
# Dynamic worker addition script
################################################################################

#!/usr/bin/env bash
set -e
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

# Find the lowest available worker slot (1-8) by checking for gaps
next_num=""
for i in $(seq 1 8); do
    if [ ! -d ".worktrees/wt-$i" ]; then
        next_num=$i
        break
    fi
done

if [ -z "$next_num" ]; then
    echo "ERROR: Maximum 8 workers — all slots occupied"
    exit 1
fi

# [... rest of add-worker.sh ...]

################################################################################
# FILE: scripts/state-lock.sh
# File locking utility for state file access
################################################################################

#!/usr/bin/env bash
# Usage: state-lock.sh <state-file> <command>
# Acquires an exclusive lock before running <command>, releases after.
# Writes go to a temp file first, then atomically move into place.
set -e
STATE_FILE="$1"
shift
LOCK_DIR="${STATE_FILE}.lockdir"
TMP_FILE="${STATE_FILE}.tmp.$$"

# [... rest of state-lock.sh ...]

################################################################################
# FILE: scripts/hooks/pre-tool-secret-guard.sh
# Security hook to prevent sensitive file access
################################################################################

#!/usr/bin/env bash
set -euo pipefail
input=$(cat)

# Check file_path (for Read/Write/Edit tools)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
if [ -n "$file_path" ]; then
    if echo "$file_path" | grep -qiE '\.env|secrets|credentials|\.pem$|\.key$|id_rsa|\.secret'; then
        echo "BLOCKED: $file_path is sensitive" >&2
        exit 2
    fi
fi

# [... rest of pre-tool-secret-guard.sh ...]

################################################################################
# FILE: scripts/hooks/stop-notify.sh
# Notification hook on agent stop
################################################################################

#!/usr/bin/env bash
osascript -e 'display notification "Done" with title "Claude" sound name "Glass"' 2>/dev/null || true

################################################################################
# FILE: templates/root-claude.md
# Root CLAUDE.md for master agents
################################################################################

# Multi-Agent Orchestration System

## Architecture

```
User → Master-1 (Interface) → handoff.json
         ↕ clarification-queue.json
       Master-2 (Architect) → task-queue.json
       Master-3 (Allocator) → TaskCreate(ASSIGNED_TO)
         ↕ worker-status.json
       Workers 1-8 (isolated worktrees, one domain each)
```

## Management Hierarchy

```
┌─────────────────────────────────────────────────────┐
│  TIER 1: STRATEGY                                    │
│  Master-2 (Architect)                                │
│    • Owns decomposition quality                      │
│    • Decides HOW work is split                       │
│    • Can block work with clarification requests      │
├─────────────────────────────────────────────────────┤
│  TIER 2: OPERATIONS                                  │
│  Master-3 (Allocator)                                │
│    • Owns worker lifecycle + assignment              │
│    • Decides WHO gets work and WHEN                  │
├─────────────────────────────────────────────────────┤
│  TIER 3: COMMUNICATION                               │
│  Master-1 (Interface)                                │
│    • Owns user relationship                          │
│    • Routes requests UP to Master-2                  │
├─────────────────────────────────────────────────────┤
│  TIER 4: EXECUTION                                   │
│  Workers 1-8                                         │
│    • Execute tasks assigned by Master-3              │
│    • Own their domain — no cross-domain work         │
└─────────────────────────────────────────────────────┘
```

# [... rest of root-claude.md ...]

################################################################################
# FILE: templates/worker-claude.md
# Worker CLAUDE.md template
################################################################################

# Worker Agent

## You Are a Worker

You execute tasks assigned by Master-3. You do NOT decompose requests, route tasks, or talk to the user.

## Your Identity
```bash
git branch --show-current
```
agent-1 → worker-1, agent-2 → worker-2, etc.

## Task Priority (highest first)
1. **RESET tasks** — subject starts with "RESET:". Immediately: mark complete → `/clear` → `/worker-loop`
2. **URGENT fix tasks** — priority field or "FIX:" in subject
3. **Normal tasks** — claim → plan → build → verify → ship

# [... rest of worker-claude.md ...]

################################################################################
# FILE: templates/settings.json
# Claude Code settings template
################################################################################

{
  "permissions": {
    "allow": [
      "Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "MultiEdit(*)",
      "Grep(*)", "Glob(*)", "Task(*)", "TaskList(*)", "TaskCreate(*)", "TaskUpdate(*)"
    ],
    "deny": ["Bash(rm -rf /)", "Bash(rm -rf ~)", "Bash(git push --force)"]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Edit|Write|MultiEdit|Read",
      "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/pre-tool-secret-guard.sh\""}]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop-notify.sh\""}]
    }]
  }
}

################################################################################
# FILE: templates/docs/master-1-role.md
# Master-1 role document
################################################################################

# Master-1: Interface — Full Role Document

## Identity & Scope
You are the user's ONLY point of contact. You never read code, never investigate implementations, never decompose tasks. Your context stays clean because every token should serve user communication.

## Access Control
| Resource | Your access |
|----------|------------|
| handoff.json | READ + WRITE (you create requests) |
| clarification-queue.json | READ + WRITE (you relay answers) |
| fix-queue.json | WRITE (you create fix tasks) |
| worker-status.json | READ ONLY (for status reports) |
| Source code files | NEVER READ |

# [... rest of master-1-role.md ...]

################################################################################
# FILE: templates/docs/master-2-role.md
# Master-2 role document
################################################################################

# Master-2: Architect — Full Role Document

## Identity & Scope
You are the codebase expert. You hold deep knowledge of the entire codebase from your initial scan. You decompose user requests into granular, file-level tasks. You do NOT route tasks or manage workers.

# [... rest of master-2-role.md ...]

################################################################################
# FILE: templates/docs/master-3-role.md
# Master-3 role document
################################################################################

# Master-3: Allocator — Full Role Document

## Identity & Scope
You are the operations manager. You have direct codebase knowledge AND manage all worker assignments, lifecycle, heartbeats, and integration.

# [... rest of master-3-role.md ...]

################################################################################
# FILE: templates/agents/build-validator.md
# Build validator subagent
################################################################################

---
name: build-validator
description: Validates build/lint/types/tests.
model: haiku
allowed-tools: [Bash, Read]
---

Run: npm install, build, lint, typecheck, test

Report:
```
BUILD: PASS|FAIL|SKIP
LINT: PASS|FAIL|SKIP
TYPES: PASS|FAIL|SKIP
TESTS: PASS|FAIL|SKIP
VERDICT: ALL_CLEAR|ISSUES_FOUND
```

################################################################################
# FILE: templates/agents/code-architect.md
# Code architect subagent
################################################################################

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

################################################################################
# FILE: templates/agents/verify-app.md
# Verify app subagent
################################################################################

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

################################################################################
# FILE: templates/commands/master-loop.md
# Master-1 main loop command
################################################################################

---
description: Master-1's main loop. Handles ALL user input - requests, approvals, fixes, status, and surfaces clarifications from Master-2.
---

You are **Master-1: Interface**.

**First, read your role document for full context:**
```bash
cat .claude/docs/master-1-role.md
```

Your context is CLEAN. You do NOT read code. You handle all user communication and relay clarifications from Master-2 (Architect).

# [... rest of master-loop.md ...]

################################################################################
# FILE: templates/commands/scan-codebase.md
# Master-2 codebase scan command
################################################################################

---
description: Master-2 scans and maps the entire codebase. Run once at start.
---

You are **Master-2: Architect**.

## Scan the Codebase

Read the entire codebase and create a map. This takes ~10 minutes but only needs to happen once.

# [... rest of scan-codebase.md ...]

################################################################################
# FILE: templates/commands/architect-loop.md
# Master-2 main loop command
################################################################################

---
description: Master-2's main loop. Reacts to handoff.json changes, decomposes requests into granular file-level tasks.
---

You are **Master-2: Architect**.

You have deep codebase knowledge from `/scan-codebase`. Your job is to **decompose** requests into granular, file-level tasks.

# [... rest of architect-loop.md ...]

################################################################################
# FILE: templates/commands/allocate-loop.md
# Master-3 main loop command
################################################################################

---
description: Master-3's main loop. Routes decomposed tasks to workers, monitors status, merges PRs.
---

You are **Master-3: Allocator**.

You run the fast operational loop. You read decomposed tasks from Master-2 and route them to the right workers.

# [... rest of allocate-loop.md ...]

################################################################################
# FILE: templates/commands/scan-codebase-allocator.md
# Master-3 codebase scan command
################################################################################

---
description: Master-3 scans the codebase for routing knowledge, then starts the allocate loop.
---

You are **Master-3: Allocator**.

You need direct codebase knowledge to make good routing decisions.

# [... rest of scan-codebase-allocator.md ...]

################################################################################
# FILE: templates/commands/worker-loop.md
# Worker main loop command
################################################################################

---
description: Worker loop with explicit polling and auto-continue after task completion.
---

You are a **Worker**. Check your branch to know your ID:
```bash
git branch --show-current
```
- agent-1 → worker-1
- agent-2 → worker-2
- etc.

# [... rest of worker-loop.md ...]

################################################################################
# FILE: templates/commands/commit-push-pr.md
# Git commit/push/PR command
################################################################################

---
description: Ship completed work with error handling.
---

1. `git add -A`
2. `git diff --cached --stat`
3. **Secret check:** `git diff --cached` — ABORT if you see API keys, tokens, passwords
4. `git commit -m "type(scope): description"`
5. Push with retry
6. Create PR with retry
7. Report PR URL

################################################################################
# FILE: templates/state/worker-lessons.md
# Worker lessons template
################################################################################

# Worker Lessons Learned

<!-- Mistakes from worker tasks — all workers read this before starting any task -->
<!-- Masters append lessons here when fix tasks are created -->

################################################################################
# FILE: templates/state/change-summaries.md
# Change summaries template
################################################################################

# Change Summaries

<!-- Workers append a brief summary here after completing each task -->
<!-- Read this before starting work to see what other workers have changed -->

################################################################################
# FILE: gui/package.json
# GUI package configuration
################################################################################

{
  "name": "agent-control-center",
  "version": "1.0.0",
  "description": "Multi-Agent Orchestration Control Center",
  "main": "src/main/main.js",
  "scripts": {
    "start": "unset ELECTRON_RUN_AS_NODE && electron ."
  },
  "devDependencies": {
    "electron": "^28.0.0"
  },
  "dependencies": {
    "chokidar": "^3.5.3"
  }
}

################################################################################
# FILE: gui/start.sh
# GUI launcher script
################################################################################

#!/bin/bash
# Agent Control Center - Unified Launcher
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# [... rest of start.sh ...]

################################################################################
# FILE: gui/src/backend.js
# NW.js backend module
################################################################################

// NW.js Backend - Runs in Node.js context
const fs = require('fs');
const path = require('path');
const chokidar = require('chokidar');

// [... rest of backend.js ...]

################################################################################
# FILE: gui/src/server.js
# HTTP server for browser-based GUI
################################################################################

const http = require('http');
const fs = require('fs');
const path = require('path');
const chokidar = require('chokidar');
const { execSync } = require('child_process');

const PORT = 3847;

// [... rest of server.js ...]

################################################################################
# FILE: gui/src/main/main.js
# Electron main process
################################################################################

// Electron Main Process - Agent Control Center
'use strict';

const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const chokidar = require('chokidar');

// [... rest of main.js - 370 lines of Electron main process code ...]

################################################################################
# FILE: gui/src/main/preload.js
# Electron preload script
################################################################################

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electron', {
    selectProject: () => ipcRenderer.invoke('select-project'),
    getProject: () => ipcRenderer.invoke('get-project'),
    getState: (filename) => ipcRenderer.invoke('get-state', filename),
    getActivityLog: (lines) => ipcRenderer.invoke('get-activity-log', lines),
    writeState: (filename, data) => ipcRenderer.invoke('write-state', { filename, data }),
    onStateChanged: (callback) => {
        ipcRenderer.on('state-changed', (event, filename) => callback(filename));
    },
    onNewLogLines: (callback) => {
        ipcRenderer.on('new-log-lines', (event, lines) => callback(lines));
    },
    getDebugLog: () => ipcRenderer.invoke('get-debug-log'),
    checkFiles: () => ipcRenderer.invoke('check-files'),
    onDebugLog: (callback) => {
        ipcRenderer.on('debug-log', (event, entry) => callback(entry));
    }
});

################################################################################
# FILE: gui/src/renderer/index.html
# Electron renderer HTML
################################################################################

<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Agent Control Center</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <div id="app">
        <!-- Connection Screen -->
        <!-- Dashboard Screen -->
        <!-- Master Cards -->
        <!-- Workflow Pipeline -->
        <!-- Worker Pool -->
        <!-- Activity Feed -->
        <!-- Detail Panel -->
        <!-- Debug Panel -->
    </div>
    <script src="app.js"></script>
</body>
</html>

################################################################################
# FILE: gui/src/renderer/styles.css
# GUI stylesheet (1206 lines)
################################################################################

/* === CSS Variables === */
:root {
    --bg-primary: #0d1117;
    --bg-secondary: #161b22;
    --bg-tertiary: #21262d;
    --bg-card: #1c2128;
    --text-primary: #e6edf3;
    --text-secondary: #8b949e;
    --accent-green: #3fb950;
    --accent-blue: #58a6ff;
    --accent-purple: #a371f7;
    --accent-orange: #d29922;
    --accent-red: #f85149;
    --border-color: #30363d;
}

/* [... rest of styles.css - 1206 lines of CSS ...] */

################################################################################
# FILE: gui/src/renderer/app.js
# GUI application JavaScript (768 lines)
################################################################################

// Agent Control Center - Redesigned UI
// With workflow pipeline, master status indicators, and detail panel

// State management, DOM elements, initialization
// State loading, command input handling
// Rendering functions for pipeline, workers, activity log
// Detail panel, debug panel
// Utility functions

// [... Full implementation in original file ...]

################################################################################
# END OF CONSOLIDATED CODEBASE
################################################################################

END_CONSOLIDATED_CODEBASE

echo "This file contains the entire codebase in commented form."
echo "See the original files for full implementations."
