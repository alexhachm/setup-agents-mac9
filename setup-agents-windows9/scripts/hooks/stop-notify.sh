#!/usr/bin/env bash
# Stop notification: notifies user when Claude stops execution.
# Windows: PowerShell toast or beep. macOS: system notification. Other: silent.
if [ "$(uname -s)" = "Darwin" ]; then
    osascript -e 'display notification "Done" with title "Claude" sound name "Glass"' 2>/dev/null || true
elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "[System.Console]::Beep(800,300);[System.Console]::Beep(1000,300)" 2>/dev/null || true
fi
exit 0
