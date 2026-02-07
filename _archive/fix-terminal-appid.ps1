# Configure Windows Terminal AppId to display custom content
# This overrides the default "Terminal" label for custom toasts

$WtAppId = "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
$RegPath = "HKCU:\Software\Classes\AppUserModelId\$WtAppId"

Write-Host "Configuring Windows Terminal AppId for custom toast content..." -ForegroundColor Cyan

# Create/Update registry key
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force | Out-Null
}

# Set DisplayName to override default "Terminal"
Set-ItemProperty -Path $RegPath -Name "DisplayName" -Value "Claude Code" -Type String -Force

# Set Icon
$IconPath = "$env:USERPROFILE\.claude\assets\claude-logo.png"
if (Test-Path $IconPath) {
    Set-ItemProperty -Path $RegPath -Name "IconUri" -Value $IconPath -Type String -Force
}

Write-Host "✓ Windows Terminal AppId configured" -ForegroundColor Green
Write-Host "  DisplayName: Claude Code" -ForegroundColor Gray
Write-Host "  Registry: $RegPath" -ForegroundColor Gray
Write-Host ""
Write-Host "Now update windows-notification.ps1 to use Windows Terminal AppId." -ForegroundColor Yellow
