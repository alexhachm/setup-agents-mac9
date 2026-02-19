# Stop notification: shows a toast or falls back to console beep
try {
    # Try BurntToast module for rich toast notifications
    if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
        Import-Module BurntToast
        New-BurntToastNotification -Text "Codex", "Done" -Sound Default
    } else {
        # Fallback: console beep + colored message
        [System.Console]::Beep(800, 300)
        [System.Console]::Beep(1000, 300)
        Write-Host "`n  [DONE] Codex has stopped.`n" -ForegroundColor Green
    }
} catch {
    # Last resort: simple beep
    [char]7 | Write-Host -NoNewline
    Write-Host "`n  [DONE] Codex has stopped.`n" -ForegroundColor Green
}
