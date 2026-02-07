$ScriptPath = "$env:USERPROFILE\.claude\hooks\windows-notification.ps1"
if (-not (Test-Path $ScriptPath)) {
    Write-Error "Script not found at $ScriptPath"
    exit
}

Write-Host "Launching Native Toast Test..." -ForegroundColor Cyan
Write-Host "Testing Two Scenarios:"
Write-Host "1. Immediate Click (< 10s): Should switch EXACTLY to this tab (via Beacon)." -ForegroundColor Green
Write-Host "2. Late Click (Action Center): Should switch to this WINDOW (via Heuristic)." -ForegroundColor Yellow
Write-Host "   (Logic: PID -> CreationOrder -> TabIndex)"
Write-Host "DEBUG: Script PID = $PID (Ephemeral)" -ForegroundColor Gray
$ParentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
Write-Host "DEBUG: Parent PID = $ParentPid (Interactive Shell) -> sending this as TargetPid" -ForegroundColor Magenta

# --- PROPOSAL D: Blocking Wait Strategy ---
$BeaconId = [Guid]::NewGuid().ToString().Substring(0, 8)
$TestTitle = "Final Test ($BeaconId)"

# 1. Set the Title manually here (so it stays while we block)
$Host.UI.RawUI.WindowTitle = $TestTitle

Write-Host "Beacon Active: $TestTitle" -ForegroundColor Cyan
Write-Host "Sending Toast..."

# 2. Update windows-notification.ps1 arguments to accept specific BeaconTitle
& $ScriptPath -Title "Final Test" -Message "Click me! I should just work." -BeaconTitle $TestTitle -TargetPid $PID

# 3. BLOCK execution to keep the Title alive
Write-Host "`n--------------------------------------------------" -ForegroundColor Yellow
Write-Host "  SCRIPT BLOCKED (Intentional) " -ForegroundColor Yellow
Write-Host "  Go click the Toast in Action Center NOW." -ForegroundColor Green
Write-Host "  The Tab Title is held active."
Write-Host "  After verify, press ENTER here to finish." -ForegroundColor Gray
Write-Host "--------------------------------------------------"
$null = Read-Host "Waiting..."

# 4. Cleanup (Shell will do this automatically, but good practice)
Write-Host "Test Complete."
