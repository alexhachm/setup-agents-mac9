---
description: Ship completed work with error handling.
---

1. `git add -A`
2. `git diff --cached --stat`
3. **Secret check:** `git diff --cached` — ABORT if you see API keys, tokens, passwords, .env values, or private keys. Say "BLOCKED: secrets detected" and do NOT proceed.
4. `git commit -m "type(scope): description"`
5. Push (workers own their branch exclusively — force-push if behind):
   ```bash
   git push origin HEAD || git push --force-with-lease origin HEAD
   ```
6. Create PR:
   ```bash
   gh pr create --base $(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main) --fill 2>&1
   ```
   If fails, try `gh pr view --web 2>/dev/null` for existing PR.
7. Report PR URL
