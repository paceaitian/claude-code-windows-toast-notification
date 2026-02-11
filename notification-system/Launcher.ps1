# Launcher.ps1 - 通知系统启动器
# 快速入口，负责解析输入、读取窗口标题、启动后台 Worker

param(
    [Parameter(Mandatory=$false, Position=0)] [string]$ProjectName_Or_Title,
    [Parameter(Mandatory=$false, Position=1)] [string]$TranscriptPath_Or_Message,

    [Parameter(ValueFromPipeline=$true)] [psobject]$InputObject,

    # Flags
    [switch]$EnableDebug,
    [switch]$Wait,
    [int]$Delay = 0,
    [string]$AudioPath
)

# 0. Load Libs
$Dir = Split-Path $MyInvocation.MyCommand.Path
. "$Dir\Lib\Common.ps1"
. "$Dir\Lib\Native.ps1"

Write-DebugLog "--- LAUNCHER (MODULAR) ---"

# 1. Parse Input & Arguments
try {
    $Payload = @{}

    # Priority: Pipeline/InputObject > Positional Args
    if ($InputObject) {
        if ($InputObject -is [string]) {
            $Payload = $InputObject | ConvertFrom-Json -ErrorAction SilentlyContinue
        } else {
            $Payload = $InputObject
        }
    } elseif ($input) {
        $Raw = $input | Out-String
        if (-not [string]::IsNullOrWhiteSpace($Raw)) {
            try {
                $Payload = $Raw | ConvertFrom-Json -ErrorAction Stop
            } catch {
                Write-DebugLog "Pipeline JSON Parse Error: $_"
                $Payload = @{}
            }
        }
    }

    # If Payload is empty/null, use Positional Args (Legacy Hook Mode)
    if (-not $Payload -or $Payload.Count -eq 0) {
        $Payload = @{}
        if ($ProjectName_Or_Title) { $Payload['project_name'] = $ProjectName_Or_Title }
        if ($TranscriptPath_Or_Message) {
            # Heuristic: Is it a path?
            if ($TranscriptPath_Or_Message -match "^[a-zA-Z]:\\" -or $TranscriptPath_Or_Message -match "^\\\\") {
                $Payload['transcript_path'] = $TranscriptPath_Or_Message
            } else {
                $Payload['message'] = $TranscriptPath_Or_Message
            }
        }
    }
} catch { Write-DebugLog "Launcher Input Error: $_" }

# 2. Extract Project info
$ProjectName = "Claude"
if ($Payload.project_name) { $ProjectName = $Payload.project_name }
elseif ($Payload.title) { $ProjectName = $Payload.title }
elseif ($Payload.projectPath) { $ProjectName = Split-Path $Payload.projectPath -Leaf }
elseif ($Payload.project_dir) { $ProjectName = Split-Path $Payload.project_dir -Leaf }

if ($ProjectName -eq "Claude" -and $env:CLAUDE_PROJECT_DIR) {
    $ProjectName = Split-Path $env:CLAUDE_PROJECT_DIR -Leaf
}

# 3. Find Interactive Shell (PID)
$TargetPid = 0
$CurrentId = $PID
$FoundClaude = $false

$MaxDepth = $Script:CONFIG_PARENT_PROCESS_MAX_DEPTH
if (-not $MaxDepth) { $MaxDepth = 10 }

for ($i=0; $i -lt $MaxDepth; $i++) {
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
        if ($ParentId -le 0 -or $ParentId -eq $CurrentId) { break }
        $CurrentId = $ParentId
    } catch { break }
}

# 4. Read Window Title (读取当前标题，必要时 fallback 为项目名)
$ActualTitle = $ProjectName

if ($TargetPid -gt 0) {
    [WinApi]::FreeConsole() | Out-Null
    if ([WinApi]::AttachConsole($TargetPid)) {
        try {
            # 读取当前窗口标题（Claude Code 已设置为对话摘要）
            $Hwnd = [WinApi]::GetForegroundWindow()
            $Sb = [System.Text.StringBuilder]::new(256)
            [WinApi]::GetWindowText($Hwnd, $Sb, 256) | Out-Null
            $CurrentTitle = $Sb.ToString()

            if (Test-IsDefaultTitle $CurrentTitle) {
                # 默认值（Claude Code / PowerShell / cmd）→ 设置为项目名作为 fallback
                [Console]::Title = $ProjectName
                $Osc = "$([char]27)]0;$ProjectName$([char]7)"
                [Console]::Write($Osc)
                [Console]::Out.Flush()
                $ActualTitle = $ProjectName
                Write-DebugLog "Launcher: Fallback title '$ProjectName' into PID $TargetPid"
            } else {
                # Claude Code 已设置对话摘要（如 "⠐ 多智能体审查"）→ 直接使用
                $ActualTitle = $CurrentTitle
                Write-DebugLog "Launcher: Using existing title '$CurrentTitle'"
            }
        } finally {
            [WinApi]::FreeConsole() | Out-Null
        }
    }
} else {
    Write-DebugLog "Launcher: No suitable Interactive Shell found."
}

# 5. Prepare Worker Arguments
$NotificationType = ""
if ($Payload.notification_type) { $NotificationType = $Payload.notification_type }

$Title = "Claude Notification"
$Message = "Task finished."
if ($Payload.title) { $Title = $Payload.title }
if ($Payload.message) { $Message = $Payload.message }

# Audio Path: 命令行参数优先，其次 Payload
if (-not $AudioPath -and $Payload.audio_path) { $AudioPath = $Payload.audio_path }

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

# 实际窗口标题（用于焦点检测 + Toast URI）
$EncActualTitle = [Uri]::EscapeDataString($ActualTitle)
$ActualTitleArg = "-ActualTitle `"$EncActualTitle`""

$AudioArg = ""
if ($AudioPath) {
    $EncAudio = [Uri]::EscapeDataString($AudioPath)
    $AudioArg = "-AudioPath `"$EncAudio`""
}

# 6. Encode Tool Info (if present)
$ToolNameArg = ""
$ToolInputArg = ""

if ($Payload.tool_name) {
    $ToolNameArg = "-ToolName `"$($Payload.tool_name)`""
}
if ($Payload.tool_input) {
    try {
        $JsonInput = $Payload.tool_input | ConvertTo-Json -Depth 10 -Compress
        $B64Input = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($JsonInput))
        $ToolInputArg = "-Base64ToolInput `"$B64Input`""
    } catch { Write-DebugLog "ToolInput Encode Error: $_" }
}

# 7. Launch Worker
$WorkerScript = "$Dir\Worker.ps1"

$WorkerProc = Start-Process "pwsh" -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$WorkerScript`" -Worker -Base64Title `"$B64Title`" -Base64Message `"$B64Message`" -ProjectName `"$EncProject`" -NotificationType `"$NotificationType`" $AudioArg $TranscriptArg $DebugArg $DelayArg $TargetPidArg $ActualTitleArg $ToolNameArg $ToolInputArg"

# 8. Wait Mode
if ($Wait) {
    if ($WorkerProc) {
        $TimeoutMs = $Script:CONFIG_WORKER_TIMEOUT_MS
        $TimeoutBuffer = $Script:CONFIG_WORKER_TIMEOUT_BUFFER_MS
        if (-not $TimeoutMs) { $TimeoutMs = 30000 }
        if (-not $TimeoutBuffer) { $TimeoutBuffer = 10000 }

        $Timeout = if ($Delay -gt 0) { ($Delay * 1000) + $TimeoutBuffer } else { $TimeoutMs }
        $Exited = $WorkerProc.WaitForExit($Timeout)
        if (-not $Exited) {
            Write-Warning "Worker process timed out. Terminating..."
            try { $WorkerProc.Kill() } catch {}
        }
    }
}
