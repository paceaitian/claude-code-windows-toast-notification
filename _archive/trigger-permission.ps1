<#
.SYNOPSIS
    Non-blocking launcher for permission prompt.
    Captures payload, saves to temp, launches the prompt script detached.
#>
param(
    [string]$TargetScript = "C:/Users/Xiao/.claude/hooks/permission-prompt.ps1",
    [string]$AudioPath = "C:/Users/Xiao/OneDrive/Aurora.wav",
    [switch]$AutoInput,
    [int]$Delay = 0
)

# 1. Capture Payload from Stdin
try {
    $PayloadJson = $input | Out-String
    if (-not [string]::IsNullOrWhiteSpace($PayloadJson)) {
        # Save to temp file
        $TempFile = [System.IO.Path]::GetTempFileName()
        $PayloadJson | Out-File $TempFile -Encoding UTF8
    }
} catch {
    $TempFile = ""
}

# 2. Construct Arguments for the Worker Script

# 2. Construct Arguments for the Worker Script

# --- Process Tree Walking to find the Real Terminal Host ---
# Hook -> Claude -> Pwsh -> WindowsTerminal
$DebugLog = "$env:USERPROFILE\.claude\permission_debug.log"
"--- Trigger $(Get-Date) ---" | Out-File $DebugLog -Append -Encoding UTF8

function Get-ParentPid($ProcessId) {
    return (Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId").ParentProcessId
}

$CurrentPid = $PID
$TargetPid = 0
$ChainLog = "$CurrentPid"

# Walk up to 6 levels to find the Window Host
$NextPid = $CurrentPid
for ($i = 0; $i -lt 6; $i++) {
    $NextPid = Get-ParentPid $NextPid
    if ($NextPid -le 0) { break }
    
    try {
        $Proc = Get-Process -Id $NextPid -ErrorAction Stop
        $ProcName = $Proc.ProcessName
        $ChainLog += " -> $NextPid ($ProcName)"
        
        # Priority Targets (Known Hosts)
        if ($ProcName -match "^(WindowsTerminal|Code|idea64|devenv|OpenConsole|conhost)$") {
            $TargetPid = $NextPid
            break
        }
        
        # Secondary Targets (Shells that might own a window if not in WT)
        # But we prefer to keep going up if possible to find the Host.
        # If we hit Explorer, we went too far.
        if ($ProcName -eq "explorer") { break }
        
        # If matches nothing known, keep walking up.
        # BUT capture the last valid PID with a window handle as fallback?
        if ($Proc.MainWindowHandle -ne 0) {
            $FallbackPid = $NextPid
        }
    } catch {
        break
    }
}

"$ChainLog" | Out-File $DebugLog -Append -Encoding UTF8

if ($TargetPid -eq 0 -and $FallbackPid -gt 0) {
    $TargetPid = $FallbackPid
}

if ($TargetPid -eq 0) {
    # Ultimate fallback: Claude itself (Grandparent of script)
    # P1(Hook) -> P2(Claude?) -> P3(Shell?)
    # Adjust based on real chain observation: 38060(pwsh)->34872(cmd)->5140(claude)
    # The chain showed Claude as Grandparent. So Great-Grandparent is shell.
    # The loop should have found it.
    $TargetPid = $CurrentPid 
}

"Selected Target PID: $TargetPid" | Out-File $DebugLog -Append -Encoding UTF8

$ParentHwnd = 12345 # Dummy


# 2. Construct Arguments for the Worker Script
$ArgsList = @()
$ArgsList += "-File", "`"$TargetScript`""
if ($AudioPath) { $ArgsList += "-AudioPath", "`"$AudioPath`"" }
if ($AutoInput) { $ArgsList += "-AutoInput" }
if ($Delay -gt 0) { $ArgsList += "-Delay", "$Delay" }
if ($TargetPid -gt 0) { $ArgsList += "-TargetPid", "$TargetPid" }

# Pass the temp payload path if it exists
if ($TempFile) {
    $ArgsList += "-PayloadPath", "`"$TempFile`""
}

# Pass the parent window handle for focus restoration
if ($ParentHwnd -ne [IntPtr]::Zero) {
    $ArgsList += "-ParentWindow", "$($ParentHwnd)" # Int64 already handled by implicit cast or string interp
}

# 3. Launch Detached Process
# Use Hidden so we don't see a taskbar item for the timer. 
# The Worker script will handle showing the Dialog when needed.
Start-Process powershell -ArgumentList $ArgsList -WindowStyle Hidden

# 4. Exit immediately to unblock Claude CLI
exit 0
