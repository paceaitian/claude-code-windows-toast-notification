# Clear Windows Toast Notification Cache
# This is necessary after changing AppUserModelId settings

Write-Host "Clearing Windows Toast Notification Cache..." -ForegroundColor Cyan

# Stop Windows Push Notification service
Write-Host "Stopping Windows Push Notification service..." -ForegroundColor Yellow
try {
    Stop-Service -Name "WpnService" -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    Write-Host "✓ Service stopped" -ForegroundColor Green
} catch {
    Write-Host "✗ Failed to stop service: $_" -ForegroundColor Red
}

# Clear notification cache database
$CachePath = "$env:LOCALAPPDATA\Microsoft\Windows\NotificationCache"
if (Test-Path $CachePath) {
    Write-Host "Clearing notification cache at: $CachePath" -ForegroundColor Yellow
    Remove-Item "$CachePath\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "✓ Cache cleared" -ForegroundColor Green
} else {
    Write-Host "○ Cache path not found (may already be clean)" -ForegroundColor Gray
}

# Also clear ActionCenter cache
$ActionCenterCache = "$env:LOCALAPPDATA\Microsoft\Windows\ActionCenterCache"
if (Test-Path $ActionCenterCache) {
    Remove-Item "$ActionCenterCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "✓ ActionCenter cache cleared" -ForegroundColor Green
}

# Start Windows Push Notification service
Write-Host "Starting Windows Push Notification service..." -ForegroundColor Yellow
try {
    Start-Service -Name "WpnService" -ErrorAction Stop
    Write-Host "✓ Service started" -ForegroundColor Green
} catch {
    Write-Host "✗ Failed to start service: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "Toast cache cleared! You may need to log off and log on again for changes to take full effect." -ForegroundColor Green
