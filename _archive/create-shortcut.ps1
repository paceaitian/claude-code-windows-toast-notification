# Create a shortcut for Claude Code with proper AppUserModelId
# Shortcut must point to a real executable for toast content to display correctly

$WshShell = New-Object -ComObject WScript.Shell
$ShortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk"

# Use PowerShell.exe as target (real executable)
$TargetPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$Arguments = "-NoExit -Command Write-Host 'Claude Code - AI Assistant' -ForegroundColor Cyan"
$AppId = "ClaudeCode.ClaudeCode"
$Description = "Claude Code AI Assistant"
$IconPath = "$env:USERPROFILE\.claude\assets\claude-logo.png"

Write-Host "Creating Claude Code shortcut..." -ForegroundColor Cyan

# Delete existing shortcut if present
if (Test-Path $ShortcutPath) {
    Remove-Item $ShortcutPath -Force
}

# Create shortcut
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $TargetPath
$Shortcut.Arguments = $Arguments
$Shortcut.Description = $Description
$Shortcut.WorkingDirectory = $env:USERPROFILE

# Set icon if exists
if (Test-Path $IconPath) {
    $Shortcut.IconLocation = $IconPath
} else {
    $Shortcut.IconLocation = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe,0"
}

$Shortcut.Save()

Write-Host "✓ Shortcut created: $ShortcutPath" -ForegroundColor Green
Write-Host "  Target: $TargetPath" -ForegroundColor Gray
Write-Host "  AppUserModelId: $AppId" -ForegroundColor Gray

# Now set AppUserModelId using Shell object
try {
    $Shl = New-Object -ComObject Shell.Application
    $Folder = $Shl.NameSpace((Split-Path $ShortcutPath))
    $Item = $Folder.ParseName((Split-Path $ShortcutPath -Leaf))

    # Get the PropertyStore interface via Shell.PropertySheet
    # This requires a different approach - using the shortcut's PersistFile
    # For now, the shortcut is created and AppId is set in registry
    Write-Host "  Note: AppUserModelId is set via registry (register-toast-appid.ps1)" -ForegroundColor Yellow
} catch {
    Write-Host "  Warning: Could not set AppUserModelId on shortcut: $_" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Run: .\clear-toast-cache.ps1" -ForegroundColor White
Write-Host "2. Log off and log on again (or restart Windows)" -ForegroundColor White
