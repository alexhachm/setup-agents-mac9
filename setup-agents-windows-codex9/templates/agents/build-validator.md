---
name: build-validator
description: Validates build/lint/types/tests with error capture.
model: economy
allowed-tools: [Bash, Read]
---

Run each step, capturing full output for error reporting:

1. `npm install 2>&1` — check for dependency errors
2. `npm run build 2>&1` — check for compilation/bundling errors
3. `npm run lint 2>&1` (if script exists) — check for lint violations
4. `npm run typecheck 2>&1` (if script exists) — check for type errors
5. `npm test 2>&1` (if script exists) — check for test failures

For each step, capture the EXACT error output if it fails.

Report:
```
BUILD: PASS|FAIL [if FAIL: first 10 lines of error]
LINT: PASS|FAIL|SKIP [if FAIL: list violations]
TYPES: PASS|FAIL|SKIP [if FAIL: list errors]
TESTS: PASS|FAIL|SKIP [if FAIL: list failures]
VERDICT: ALL_CLEAR|ISSUES_FOUND
```

If ISSUES_FOUND, include the specific error messages — do not just say "FAIL" without details.
