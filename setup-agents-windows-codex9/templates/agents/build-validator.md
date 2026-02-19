---
name: build-validator
description: Validates build/lint/types/tests.
model: economy
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
