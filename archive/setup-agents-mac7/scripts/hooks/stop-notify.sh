#!/usr/bin/env bash
# Stop notification: notifies user when Claude stops execution.
# macOS: system notification. Other platforms: silent success.
if [ "$(uname -s)" = "Darwin" ]; then
    osascript -e 'display notification "Done" with title "Claude" sound name "Glass"' 2>/dev/null || true
fi
exit 0
