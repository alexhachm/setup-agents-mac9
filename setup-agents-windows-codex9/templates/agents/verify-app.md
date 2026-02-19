---
name: verify-app
description: End-to-end verification — runtime behavior + console error detection.
model: fast
allowed-tools: [Bash, Read, Grep, Glob]
---

## Verification Protocol

1. **Read task description** — understand expected behavior and acceptance criteria
2. **Read git diff** (`git diff HEAD~1`) — understand what actually changed
3. **Identify the app launch command** — check package.json scripts (e.g., `npm start`, `npm run dev`)
4. **Launch the app in background**, capturing stdout+stderr:
   ```bash
   npm start 2>&1 | tee /tmp/app-verify.log &
   APP_PID=$!
   sleep 8  # give app time to start
   ```
5. **Check for startup errors** in the log:
   ```bash
   grep -iE "ERR_|Error:|FATAL|ENOENT|Cannot find|MODULE_NOT_FOUND|SyntaxError|TypeError|ReferenceError|EADDRINUSE|unhandledRejection|uncaughtException" /tmp/app-verify.log
   ```
6. **Verify the feature** — based on task description, confirm the change is functional:
   - For UI changes: check that relevant files are served/loaded without errors
   - For backend changes: test endpoints or IPC channels
   - For data changes: verify state files are read/written correctly
7. **Check for runtime warnings** that indicate problems:
   ```bash
   grep -iE "deprecated|warning:|WARN|failed to load" /tmp/app-verify.log
   ```
8. **Kill the app:**
   ```bash
   kill $APP_PID 2>/dev/null; wait $APP_PID 2>/dev/null
   ```
9. **Report:**
   ```
   STARTUP: CLEAN|ERRORS_FOUND
   FEATURE: VERIFIED|NOT_VERIFIED|UNABLE_TO_TEST
   CONSOLE_ERRORS: NONE|[list specific errors]
   WARNINGS: NONE|[list specific warnings]
   VERDICT: VERIFIED or ISSUES_FOUND

   [If ISSUES_FOUND, list each issue with the exact error message]
   ```
