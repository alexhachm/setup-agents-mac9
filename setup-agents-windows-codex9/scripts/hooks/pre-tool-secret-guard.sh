#!/usr/bin/env bash
# Pre-tool hook: blocks access to sensitive files (.env, secrets, credentials, keys)
# Reads JSON from stdin, checks file_path and command fields.
# MUST never crash — a crashing hook blocks ALL tool usage.
# Exit 0 = allow, Exit 2 = block.

input=$(cat 2>/dev/null || true)

# If no input or empty input, allow
if [ -z "$input" ]; then
    exit 0
fi

# Extract file_path using bash-native parsing (no jq dependency)
file_path=""
if echo "$input" | grep -q '"file_path"'; then
    file_path=$(echo "$input" | grep -o '"file_path"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
fi

if [ -n "$file_path" ]; then
    if echo "$file_path" | grep -qiE '\.env($|[^a-z])|secrets|credentials|\.pem$|\.key$|id_rsa|\.secret'; then
        echo "BLOCKED: $file_path is sensitive" >&2
        exit 2
    fi
fi

# Extract command using bash-native parsing
command_str=""
if echo "$input" | grep -q '"command"'; then
    command_str=$(echo "$input" | grep -o '"command"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
fi

if [ -n "$command_str" ]; then
    if echo "$command_str" | grep -qiE '(cat|less|head|tail|more|cp|mv|scp|type|Get-Content)\s+.*\.(env|pem|key|secret)'; then
        echo "BLOCKED: command accesses sensitive file" >&2
        exit 2
    fi
fi

exit 0
