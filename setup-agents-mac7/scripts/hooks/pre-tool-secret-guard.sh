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

# Check command (for Bash tool) — block commands that cat/read/echo sensitive files
command_str=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
if [ -n "$command_str" ]; then
    if echo "$command_str" | grep -qiE '(cat|less|head|tail|more|cp|mv|scp)\s+.*\.(env|pem|key|secret)'; then
        echo "BLOCKED: command accesses sensitive file" >&2
        exit 2
    fi
fi

exit 0
