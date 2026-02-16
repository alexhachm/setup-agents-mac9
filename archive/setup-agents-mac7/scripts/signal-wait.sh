#!/usr/bin/env bash
# Usage: signal-wait.sh <signal-file> [timeout_seconds]
# Waits for a signal file to be touched/created. Returns immediately when detected.
# Falls back to polling if fswatch/inotifywait unavailable.
set -e

SIGNAL_FILE="$1"
TIMEOUT="${2:-30}"

# Ensure signal directory exists
mkdir -p "$(dirname "$SIGNAL_FILE")"

if command -v fswatch &>/dev/null; then
    # macOS: use fswatch with timeout
    fswatch -1 --event Created --event Updated --event Renamed "$SIGNAL_FILE" &
    WATCH_PID=$!
    
    # Timeout handler
    (sleep "$TIMEOUT" && kill "$WATCH_PID" 2>/dev/null) &
    TIMER_PID=$!
    
    wait "$WATCH_PID" 2>/dev/null
    kill "$TIMER_PID" 2>/dev/null || true
    
elif command -v inotifywait &>/dev/null; then
    # Linux: use inotifywait
    inotifywait -t "$TIMEOUT" -e modify,create "$SIGNAL_FILE" 2>/dev/null || true

elif command -v powershell.exe &>/dev/null; then
    # Windows: use .NET FileSystemWatcher via PowerShell for instant notification
    SIGNAL_DIR=$(dirname "$SIGNAL_FILE")
    SIGNAL_NAME=$(basename "$SIGNAL_FILE")
    TIMEOUT_MS=$((TIMEOUT * 1000))
    powershell.exe -NoProfile -Command "
        \$w = New-Object System.IO.FileSystemWatcher
        \$w.Path = (Resolve-Path '$SIGNAL_DIR').Path
        \$w.Filter = '$SIGNAL_NAME'
        \$w.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::CreationTime -bor [System.IO.NotifyFilters]::FileName
        \$r = \$w.WaitForChanged([System.IO.WatcherChangeTypes]::All, $TIMEOUT_MS)
        \$w.Dispose()
    " 2>/dev/null || true

else
    # Fallback: poll with short sleep
    elapsed=0
    last_mod=""
    if [ -f "$SIGNAL_FILE" ]; then
        if [[ "$OSTYPE" == darwin* ]]; then
            last_mod=$(stat -f %m "$SIGNAL_FILE" 2>/dev/null || echo "0")
        else
            last_mod=$(stat -c %Y "$SIGNAL_FILE" 2>/dev/null || echo "0")
        fi
    fi
    
    while [ "$elapsed" -lt "$TIMEOUT" ]; do
        sleep 2
        elapsed=$((elapsed + 2))
        
        if [ -f "$SIGNAL_FILE" ]; then
            if [[ "$OSTYPE" == darwin* ]]; then
                current_mod=$(stat -f %m "$SIGNAL_FILE" 2>/dev/null || echo "0")
            else
                current_mod=$(stat -c %Y "$SIGNAL_FILE" 2>/dev/null || echo "0")
            fi
            if [ "$current_mod" != "$last_mod" ]; then
                break
            fi
        fi
    done
fi
