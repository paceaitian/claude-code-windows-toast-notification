param(
    [Parameter(Mandatory=$false, Position=0)] [string]$Title = "Claude Notification",
    [Parameter(Mandatory=$false, Position=1)] [string]$Message = "Task finished.",
    [string]$AudioPath,
    [Parameter(ValueFromPipeline=$true)] [psobject]$InputObject,
    
    # Flags
    [switch]$EnableDebug,
    [switch]$Wait,
    [int]$Delay = 0
)

# 0. Load Libs
$Dir = Split-Path $MyInvocation.MyCommand.Path
. "$Dir\Lib\Common.ps1"
. "$Dir\Lib\Native.ps1"

Write-DebugLog "--- LAUNCHER (MODULAR) ---"

# 1. Parse Input
try {
    $Payload = $null
    if ($InputObject) {
        if ($InputObject -is [string]) { $Payload = $InputObject | ConvertFrom-Json -ErrorAction SilentlyContinue } else { $Payload = $InputObject }
    } elseif ($input) {
        $Raw = $input | Out-String; if (-not [string]::IsNullOrWhiteSpace($Raw)) { $Payload = $Raw | ConvertFrom-Json -ErrorAction SilentlyContinue }
    }
} catch {}

# 2. Extract Project info
$ProjectName = "Claude"
if ($Payload.project_name) { $ProjectName = $Payload.project_name }
elseif ($Payload.projectPath) { $ProjectName = Split-Path $Payload.projectPath -Leaf }
elseif ($Payload.project_dir) { $ProjectName = Split-Path $Payload.project_dir -Leaf }
if ($ProjectName -eq "Claude" -and $env:CLAUDE_PROJECT_DIR) { $ProjectName = Split-Path $env:CLAUDE_PROJECT_DIR -Leaf }

# 3. Find Interactive Shell (PID)
$TargetPid = 0
$CurrentId = $PID
$FoundClaude = $false

for ($i=0; $i -lt 10; $i++) {
    try {
        $Proc = Get-Process -Id $CurrentId -ErrorAction Stop
        $Name = $Proc.ProcessName
        
        # Detect Claude Process in the chain
        if ($Name -match "^(claude|node|claude-code)$") {
            $FoundClaude = $true
        }
        
        # Match common shells
        if ($Name -match "^(cmd|pwsh|powershell|bash)$") {
            if ($FoundClaude) {
                $TargetPid = $Proc.Id
                Write-DebugLog "Launcher: Found Interactive Shell L$i '$Name' (PID: $TargetPid)"
                break
            } else {
                Write-DebugLog "Launcher: Skipping Runner Shell L$i '$Name' (PID: $($Proc.Id))"
            }
        }
        
        # P/Invoke Walk Up (Extremely Fast)
        $ParentId = [WinApi]::GetParentPid($CurrentId)
        if ($ParentId -le 0) { break }
        $CurrentId = $ParentId
    } catch { break }
}

# 4. Inject Title (Immediate)
if ($TargetPid -gt 0) {
    [WinApi]::FreeConsole() | Out-Null
    if ([WinApi]::AttachConsole($TargetPid)) {
        try { [Console]::Title = $ProjectName } catch {}
        $Osc = "$([char]27)]0;$ProjectName$([char]7)"
        [Console]::Write($Osc)
        try { [Console]::Out.Flush() } catch {}
        Write-DebugLog "Launcher: Injected Title '$ProjectName' (Method A+B) into PID $TargetPid"
        [WinApi]::FreeConsole() | Out-Null
    }
} else {
    Write-DebugLog "Launcher: No suitable Interactive Shell found."
}

# 5. Prepare Worker Arguments
if ($Payload.notification_type) { $NotificationType = $Payload.notification_type }
if ($Payload.title) { $Title = $Payload.title }
if ($Payload.message) { $Message = $Payload.message }

$B64Title = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Title))
$B64Message = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Message))
$EncProject = [Uri]::EscapeDataString($ProjectName)

$TranscriptArg = ""
if ($Payload.transcript_path) {
    $EncTranscript = [Uri]::EscapeDataString($Payload.transcript_path)
    $TranscriptArg = "-TranscriptPath `"$EncTranscript`""
}

$DebugArg = ""
if ($EnableDebug) { $DebugArg = "-EnableDebug" }

$DelayArg = ""
if ($Delay -gt 0) { $DelayArg = "-Delay $Delay" }

$TargetPidArg = ""
if ($TargetPid -gt 0) { $TargetPidArg = "-TargetPid $TargetPid" }

# 6. Launch Worker
$WorkerScript = "$Dir\Worker.ps1"
$WorkerProc = Start-Process "pwsh" -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$WorkerScript`" -Worker -Base64Title `"$B64Title`" -Base64Message `"$B64Message`" -ProjectName `"$EncProject`" -NotificationType `"$NotificationType`" -AudioPath `"$AudioPath`" $TranscriptArg $DebugArg $DelayArg $TargetPidArg"

if ($Wait) {
    if ($WorkerProc) {
        $Timeout = if ($Delay -gt 0) { ($Delay * 1000) + 10000 } else { 30000 }
        $Exited = $WorkerProc.WaitForExit($Timeout)
        if (-not $Exited) { Write-Warning "Worker process timed out." }
    }
}
