# Register Claude Code AppUserModelId for Toast Notifications
# This allows us to use a custom AppId for toast notifications

$AppId = "ClaudeCode.ClaudeCode"
$DisplayName = "Claude Code"
$IconPath = "$env:USERPROFILE\.claude\assets\claude-logo.png"

# Main AppUserModelId key
$RegPath = "HKCU:\Software\Classes\AppUserModelId\$AppId"

Write-Host "Registering Claude Code AppId for Toast Notifications..." -ForegroundColor Cyan

# Create the AppUserModelId key
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force | Out-Null
}

# Set DisplayName
Set-ItemProperty -Path $RegPath -Name "DisplayName" -Value $DisplayName -Type String

# Set IconUri (if icon exists)
if (Test-Path $IconPath) {
    Set-ItemProperty -Path $RegPath -Name "IconUri" -Value $IconPath -Type String
}

# Set BackgroundColor (dark theme compatible)
Set-ItemProperty -Path $RegPath -Name "BackgroundColor" -Value "1F1F1F" -Type String

# NEW: Set Toast-capable property (critical for Windows 10/11)
Set-ItemProperty -Path $RegPath -Name "ToastActivatorCLSID" -Value "{00000000-0000-0000-0000-000000000000}" -Type String

# NEW: Create Settings key for additional configuration
$SettingsPath = "$RegPath\Settings"
if (-not (Test-Path $SettingsPath)) {
    New-Item -Path $SettingsPath -Force | Out-Null
}

Write-Host "✅ AppId Registered: $AppId" -ForegroundColor Green
Write-Host "   DisplayName: $DisplayName" -ForegroundColor Gray
Write-Host "   Icon: $IconPath" -ForegroundColor Gray
Write-Host ""
Write-Host "You can now use this AppId in windows-notification.ps1:" -ForegroundColor Yellow
Write-Host "   `$AppId = `"$AppId`"" -ForegroundColor White
