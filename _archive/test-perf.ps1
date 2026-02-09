$Hook = "$env:USERPROFILE\.claude\hooks\windows-notification.ps1"
$ErrorActionPreference = "Stop"

Write-Host "`n========== NOTIFICATION PERFORMANCE TEST ==========" -ForegroundColor Cyan

# 1. Async Test (Launcher Only)
Write-Host "1. Testing Async Launcher (Fire & Forget)..." -ForegroundColor Yellow
$PayloadAsync = @{
    type = "message"
    project_name = "PerfAsync"
    message = "Async Test: This should appear instantly."
} | ConvertTo-Json -Compress

$TimeAsync = Measure-Command {
    $PayloadAsync | & "pwsh" -File $Hook
}
Write-Host "   Launcher Latency: $($TimeAsync.TotalMilliseconds) ms" -ForegroundColor Green

Start-Sleep -Seconds 2

# 2. Sync Test (Worker Wait)
Write-Host "`n2. Testing Sync Worker (Wait for Completion)..." -ForegroundColor Yellow
$PayloadSync = @{
    type = "message"
    project_name = "PerfSync"
    message = "Sync Test: This waits for the process to exit."
} | ConvertTo-Json -Compress

$TimeSync = Measure-Command {
    $PayloadSync | & "pwsh" -File $Hook -Wait
}
Write-Host "   Total Worker Time: $($TimeSync.TotalMilliseconds) ms" -ForegroundColor Moving
Write-Host "   (Includes PowerShell startup, module load, and toast display)" -ForegroundColor Gray

Write-Host "`n========== TEST COMPLETE ==========" -ForegroundColor Cyan
