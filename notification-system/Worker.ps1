param(
    [switch]$Worker,
    [string]$Base64Title,
    [string]$Base64Message,
    [string]$ProjectName,
    [string]$NotificationType,
    [string]$ModulePath,
    [string]$TranscriptPath, 
    [switch]$EnableDebug,
    [int]$Delay = 0,
    [int]$TargetPid = 0,
    [string]$AudioPath,
    [string]$ToolName,
    [string]$Base64ToolInput
)

# 0. Load Libs
$Dir = Split-Path $MyInvocation.MyCommand.Path
. "$Dir\Lib\Common.ps1"
. "$Dir\Lib\Native.ps1"
. "$Dir\Lib\Transcript.ps1"
. "$Dir\Lib\Toast.ps1"

trap { Write-DebugLog "WORKER CRASH: $_"; exit 1 }

# 1. Decode Base64 params
$Title = "Claude Notification"
$Message = "Task finished."

try {
    if ($Base64Title) { $Title = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Title)) }
    if ($Base64Message) { $Message = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Message)) }
    if ($ProjectName) { $ProjectName = [Uri]::UnescapeDataString($ProjectName) }
    if ($TranscriptPath) { $TranscriptPath = [Uri]::UnescapeDataString($TranscriptPath) }
    
    $ToolInput = $null
    if ($Base64ToolInput) {
        $JsonInput = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64ToolInput))
        if ($JsonInput) { $ToolInput = $JsonInput | ConvertFrom-Json }
    }
} catch { Write-DebugLog "Decode Error: $_" }

# 2. Watchdog Logic (Persistent Override)
function Test-IsFocused {
    try {
        $Hwnd = [WinApi]::GetForegroundWindow()
        $Sb = [System.Text.StringBuilder]::new(256)
        [WinApi]::GetWindowText($Hwnd, $Sb, 256) | Out-Null
        $CurrentTitle = $Sb.ToString()
        if ($CurrentTitle -like "*$ProjectName*") { return $true }
    } catch {}
    return $false
}

if ($TargetPid -gt 0 -and $ProjectName) {
    try {
        # Initial Sleep to let Shell start
        Start-Sleep -Milliseconds 300
        
        # Persistent Attachment
        [WinApi]::FreeConsole() | Out-Null
        if ([WinApi]::AttachConsole($TargetPid)) {
            Write-DebugLog "Watchdog: Attached to Console (PID $TargetPid)"
            
            # Loop
            $Max = $Delay
            for ($i = 0; $i -le $Max; $i++) {
                
                # A. Force Title (Every Second)
                try {
                    # Native
                    [System.Console]::Title = $ProjectName
                    # OSC (Direct Flush)
                    $Osc = "$([char]27)]0;$ProjectName$([char]7)"
                    [System.Console]::Out.Write($Osc)
                    [System.Console]::Out.Flush()
                    
                    if ($i -eq 0) { Write-DebugLog "Watchdog: Title Set '$ProjectName'" }
                } catch {}

                # B. Focus Check
                if (Test-IsFocused) {
                        Write-DebugLog "Watchdog: User Focused at T=$i. Exiting."
                        exit 0
                } else {
                        if ($i % 2 -eq 0) { Write-DebugLog "Watchdog: Focus Mismatch (Checking...)" }
                }
                
                # Sleep (unless last iter)
                if ($i -lt $Max) { Start-Sleep -Seconds 1 }
            }
            
            # Cleanup
            [WinApi]::FreeConsole() | Out-Null
            
        } else {
            Write-DebugLog "Watchdog: Failed to attach. Running simple delay."
            Start-Sleep -Seconds $Delay
        }
    } catch { Write-DebugLog "Watchdog Error: $_" }
} else {
    # Fallback (No PID)
    Start-Sleep -Seconds $Delay
}

# 3. Final Safety Focus Check (Post-Loop)
if (Test-IsFocused) {
    Write-DebugLog "Final Check: User is focused. Aborting."
    exit 0
}

# 4. Content Logic (Data Fusion)
$PayloadMessage = $null
if ($ToolName) {
    # A. Payload (Fast & Accurate Tool Info)
    $PayloadInfo = Get-ClaudeContentFromPayload -ToolName $ToolName -ToolInput $ToolInput -Message $Message
    if ($PayloadInfo.Message) { 
        $PayloadMessage = $PayloadInfo.Message 
        $Message = $PayloadMessage # Set as primary
    }
}

if ($TranscriptPath) {
    # B. Transcript (User Question + Fallback Message)
    $Info = Get-ClaudeTranscriptInfo -TranscriptPath $TranscriptPath -ProjectName $ProjectName
    
    # Always take Title (Q: ...) if found, as Payload doesn't have it
    if ($Info.Title) { $Title = $Info.Title }
    
    # Only use Transcript Message if Payload failed to provide one
    if (-not $PayloadMessage -and $Info.Message) { 
        $Message = $Info.Message 
    }
    
    # Allow Transcript to refine NotificationType if missing
    if (-not $NotificationType -and $Info.NotificationType) { 
        $NotificationType = $Info.NotificationType 
    }
    
    # Prepend Transcript time to Payload message (Hybrid Fusion)
    if ($PayloadMessage -and $Info.ResponseTime) {
        $Message = "[$($Info.ResponseTime)] $Message"
    }
}

Write-DebugLog "Title: $Title"
Write-DebugLog "Message: $Message"

# 5. Send Toast
Send-ClaudeToast -Title $Title -Message $Message -ProjectName $ProjectName `
                 -AudioPath $AudioPath -NotificationType $NotificationType `
                 -ModulePath $ModulePath -TargetPid $TargetPid

exit 0
