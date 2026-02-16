# Pre-tool hook: blocks access to sensitive files (.env, secrets, credentials, keys)
# Reads JSON from stdin, checks file_path and command fields.
$ErrorActionPreference = "SilentlyContinue"

$input = $Input | Out-String

try {
    $json = $input | ConvertFrom-Json
} catch {
    # If we can't parse, allow
    exit 0
}

# Check file_path (for Read/Write/Edit tools)
$filePath = $json.tool_input.file_path
if ($filePath) {
    if ($filePath -match '(?i)\.env|secrets|credentials|\.pem$|\.key$|id_rsa|\.secret') {
        Write-Error "BLOCKED: $filePath is sensitive"
        exit 2
    }
}

# Check command (for Bash tool) — block commands that read sensitive files
$commandStr = $json.tool_input.command
if ($commandStr) {
    if ($commandStr -match '(?i)(cat|less|head|tail|more|cp|mv|scp|type|Get-Content)\s+.*\.(env|pem|key|secret)') {
        Write-Error "BLOCKED: command accesses sensitive file"
        exit 2
    }
}

exit 0
