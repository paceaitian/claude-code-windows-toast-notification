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
    [string]$Base64ToolInput,
    [string]$ActualTitle
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
    if ($Base64Title) {
        $DecodedTitle = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Title))
        if (-not [string]::IsNullOrWhiteSpace($DecodedTitle)) { $Title = $DecodedTitle }
    }
    if ($Base64Message) {
        $DecodedMessage = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Message))
        if (-not [string]::IsNullOrWhiteSpace($DecodedMessage)) { $Message = $DecodedMessage }
    }
    if ($ProjectName) { $ProjectName = [Uri]::UnescapeDataString($ProjectName) }
    if ($TranscriptPath) { $TranscriptPath = [Uri]::UnescapeDataString($TranscriptPath) }
    if ($AudioPath) { $AudioPath = [Uri]::UnescapeDataString($AudioPath) }
    if ($ActualTitle) { $ActualTitle = [Uri]::UnescapeDataString($ActualTitle) }

    $ToolInput = $null
    if ($Base64ToolInput) {
        try {
            $JsonInput = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64ToolInput))
            if ($JsonInput) { $ToolInput = $JsonInput | ConvertFrom-Json }
        } catch { Write-DebugLog "ToolInput Decode Error: $_" }
    }
} catch { Write-DebugLog "Decode Error: $_" }

# 2. Focus Watch (焦点检测，不修改标题)
# Claude Code 已管理窗口标题，我们只需检测用户是否聚焦
$TitleForFocusCheck = if ($ActualTitle) { $ActualTitle } else { $ProjectName }

function Test-IsFocused {
    try {
        $Hwnd = [WinApi]::GetForegroundWindow()
        $Sb = [System.Text.StringBuilder]::new(256)
        [WinApi]::GetWindowText($Hwnd, $Sb, 256) | Out-Null
        $CurrentTitle = $Sb.ToString()
        if ($CurrentTitle -like "*$TitleForFocusCheck*") { return $true }
    } catch {}
    return $false
}

Write-DebugLog "FocusWatch: Delay=$Delay TitleMatch='$TitleForFocusCheck' PID=$TargetPid"

if ($Delay -gt 0) {
    for ($i = 0; $i -lt $Delay; $i++) {
        Start-Sleep -Seconds 1
        if (Test-IsFocused) {
            Write-DebugLog "FocusWatch: User Focused at T=$($i+1). Exiting."
            exit 0
        }
    }
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

# 4.5 Description Guard: AI 尚未回复时跳过残缺 Toast
if (-not $Description -and -not $ToolInfo) {
    Write-DebugLog "ContentGuard: No Description or ToolInfo. Skipping empty toast."
    exit 0
}

# 4.6 UniqueId 计算（同一对话 turn 的多次 Stop 触发只保留最后一个 Toast）
$UniqueId = $null
try {
    $HashSource = if ($TranscriptPath) { "$TranscriptPath||$Title" } else { "$ProjectName||$Title" }
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($HashSource))
    $HashHex = ($HashBytes | ForEach-Object { $_.ToString("x2") }) -join ""
    $UniqueId = "claude-$($HashHex.Substring(0, 16))"
    Write-DebugLog "UniqueId: $UniqueId"
} catch {
    Write-DebugLog "UniqueId compute failed: $_"
}

# 5. Send Toast
# 使用 ActualTitle（实际窗口标题）用于 Toast URI，确保点击能正确激活窗口
$WindowTitleForToast = if ($ActualTitle) { $ActualTitle } else { $ProjectName }

Send-ClaudeToast -Title $Title -ToolInfo $ToolInfo -Description $Description `
                 -ProjectName $WindowTitleForToast -AudioPath $AudioPath `
                 -NotificationType $NotificationType -ModulePath $ModulePath `
                 -TargetPid $TargetPid -UniqueId $UniqueId

exit 0
