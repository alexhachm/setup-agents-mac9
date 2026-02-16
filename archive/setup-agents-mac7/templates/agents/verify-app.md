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
