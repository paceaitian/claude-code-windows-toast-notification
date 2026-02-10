# Worker.ps1 - 后台通知工作进程
# 负责解析内容、监控焦点、发送 Toast 通知

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
    if ($AudioPath) { $AudioPath = [Uri]::UnescapeDataString($AudioPath) }

    $ToolInput = $null
    if ($Base64ToolInput) {
        try {
            $JsonInput = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64ToolInput))
            if ($JsonInput) { $ToolInput = $JsonInput | ConvertFrom-Json }
        } catch { Write-DebugLog "ToolInput Decode Error: $_" }
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

$InitDelay = $Script:CONFIG_WATCHDOG_INIT_DELAY_MS
if (-not $InitDelay) { $InitDelay = 300 }

if ($TargetPid -gt 0 -and $ProjectName) {
    try {
        # Initial Sleep to let Shell start
        Start-Sleep -Milliseconds $InitDelay

        # Persistent Attachment
        [WinApi]::FreeConsole() | Out-Null
        if ([WinApi]::AttachConsole($TargetPid)) {
            Write-DebugLog "Watchdog: Attached to Console (PID $TargetPid)"

            try {
                # Loop
                $Max = $Delay
                for ($i = 0; $i -le $Max; $i++) {

                    # A. Force Title (Every Second)
                    try {
                        [System.Console]::Title = $ProjectName
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
            } finally {
                # Cleanup - 确保 FreeConsole 始终执行
                [WinApi]::FreeConsole() | Out-Null
            }

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
$ToolInfo = $null
$Description = $null

if ($ToolName) {
    # A. Payload (Fast & Accurate Tool Info)
    $PayloadInfo = Get-ClaudeContentFromPayload -ToolName $ToolName -ToolInput $ToolInput -Message $Message
    if ($PayloadInfo.ToolInfo) { $ToolInfo = $PayloadInfo.ToolInfo }
    if ($PayloadInfo.Description) { $Description = $PayloadInfo.Description }
}

if ($TranscriptPath) {
    # B. Transcript (User Question + Fallback)
    $Info = Get-ClaudeTranscriptInfo -TranscriptPath $TranscriptPath -ProjectName $ProjectName

    # Always take Title (Q: ...) if found
    if ($Info.Title) { $Title = $Info.Title }

    # Use Transcript ToolInfo/Description if Payload didn't provide
    if (-not $ToolInfo -and $Info.ToolInfo) { $ToolInfo = $Info.ToolInfo }
    if (-not $Description -and $Info.Description) { $Description = $Info.Description }

    # Allow Transcript to refine NotificationType
    if (-not $NotificationType -and $Info.NotificationType) {
        $NotificationType = $Info.NotificationType
    }

    # Prepend Transcript time to ToolInfo (Hybrid Fusion)
    if ($ToolInfo -and $Info.ResponseTime) {
        $ToolInfo = "[$($Info.ResponseTime)] $ToolInfo"
    }
}

Write-DebugLog "Title: $Title"
Write-DebugLog "ToolInfo: $ToolInfo"
Write-DebugLog "Description: $Description"

# 5. Send Toast
Send-ClaudeToast -Title $Title -ToolInfo $ToolInfo -Description $Description `
                 -ProjectName $ProjectName -AudioPath $AudioPath `
                 -NotificationType $NotificationType -ModulePath $ModulePath `
                 -TargetPid $TargetPid

exit 0
