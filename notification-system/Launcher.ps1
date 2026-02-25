# Launcher.ps1 - 通知系统启动器
# 快速入口，负责解析输入、注入窗口标题、启动后台 Worker

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

# 通知开关检查（原先在 settings.json 的 inline -Command 中，
# 2.1.51 起 bash 会展开 $env 导致语法错误，移入此处）
if ($env:CLAUDE_NO_NOTIFICATION -eq '1') { exit 0 }
if (Test-Path '.claude/no-notification') { exit 0 }

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
$ChainEntries = @()

$MaxDepth = $Script:CONFIG_PARENT_PROCESS_MAX_DEPTH
if (-not $MaxDepth) { $MaxDepth = 10 }

for ($i=0; $i -lt $MaxDepth; $i++) {
    try {
        $Proc = Get-Process -Id $CurrentId -ErrorAction Stop
        $Name = $Proc.ProcessName
        $ParentId = [WinApi]::GetParentPid($CurrentId)

        # 全层级诊断日志
        Write-DebugLog "Launcher: L$i $Name (PID:$CurrentId ParentPID:$ParentId)"

        # 收集链条，供 fallback 使用
        $ChainEntries += @{ Name=$Name; Pid=$CurrentId; ParentPid=$ParentId; Level=$i }

        # Detect Claude Process in the chain
        if ($Name -match "^(claude|node|claude-code)(\.|$)") {
            $FoundClaude = $true
        }

        # Match common shells
        if ($Name -match "^(cmd|pwsh|powershell|bash)$") {
            if ($FoundClaude) {
                $TargetPid = $Proc.Id
                Write-DebugLog "Launcher: Primary: Interactive Shell L$i '$Name' (PID: $TargetPid)"
                break
            } else {
                Write-DebugLog "Launcher: Skipping Runner Shell L$i '$Name' (PID: $($Proc.Id))"
            }
        }

        # P/Invoke Walk Up (Extremely Fast)
        if ($ParentId -le 0 -or $ParentId -eq $CurrentId) { break }
        $CurrentId = $ParentId
    } catch { break }
}

# Fallback：进程树断链时，反向搜索 shell→WT 直连
if ($TargetPid -eq 0 -and $ChainEntries.Count -gt 0) {
    Write-DebugLog "Launcher: Primary failed, trying terminal-parent fallback..."
    for ($fi = $ChainEntries.Count - 1; $fi -ge 0; $fi--) {
        $entry = $ChainEntries[$fi]
        if ($entry.Name -match "^(cmd|pwsh|powershell|bash)$" -and $entry.ParentPid -gt 0) {
            try {
                $parentProc = Get-Process -Id $entry.ParentPid -ErrorAction Stop
                if ($parentProc.ProcessName -match "^(WindowsTerminal|conhost)$") {
                    $TargetPid = $entry.Pid
                    Write-DebugLog "Launcher: Fallback: L$($entry.Level) $($entry.Name) (PID:$TargetPid) -> parent $($parentProc.ProcessName) (PID:$($entry.ParentPid))"
                    break
                }
            } catch {
                Write-DebugLog "Launcher: Fallback: Cannot verify parent PID $($entry.ParentPid): $_"
            }
        }
    }
    if ($TargetPid -eq 0) {
        Write-DebugLog "Launcher: Fallback: No shell->terminal link found"
    }
}

# 4. Inject Title (注入标题，Watchdog 会持续维护)
$UserCustomTitle = $false
$ActualTitle = $ProjectName

if ($TargetPid -gt 0) {
    [WinApi]::FreeConsole() | Out-Null
    if ([WinApi]::AttachConsole($TargetPid)) {
        try {
            # 读取 Console 窗口标题（AttachConsole 后 GetConsoleWindow 返回目标 Shell 的 Console HWND）
            $Hwnd = [WinApi]::GetConsoleWindow()
            if ($Hwnd -eq [IntPtr]::Zero) {
                Write-DebugLog "Launcher: GetConsoleWindow returned NULL, fallback to GetForegroundWindow"
                $Hwnd = [WinApi]::GetForegroundWindow()
            }
            $Sb = [System.Text.StringBuilder]::new(256)
            [WinApi]::GetWindowText($Hwnd, $Sb, 256) | Out-Null
            $CurrentTitle = $Sb.ToString()
            Write-DebugLog "Launcher: Raw title read='$CurrentTitle'"

            if (Test-IsDefaultTitle $CurrentTitle) {
                # 默认值（空 / Claude Code / PowerShell / cmd）→ 注入项目名，Watchdog 持续维护
                $ActualTitle = $ProjectName

                # 4a. 重复标题检测：同名项目在其他 WT tab → 附加 #PID 区分
                try {
                    $wtProcs = Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue
                    if ($wtProcs) {
                        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
                        $uiaRoot = [System.Windows.Automation.AutomationElement]::RootElement
                        $tabTypeCond = New-Object System.Windows.Automation.PropertyCondition(
                            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                            [System.Windows.Automation.ControlType]::TabItem)
                        $DuplicateFound = $false
                        foreach ($wtp in $wtProcs) {
                            $wtPidCond = New-Object System.Windows.Automation.PropertyCondition(
                                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $wtp.Id)
                            $wtWins = $uiaRoot.FindAll(
                                [System.Windows.Automation.TreeScope]::Children, $wtPidCond)
                            foreach ($w in $wtWins) {
                                $uiaTabs = $w.FindAll(
                                    [System.Windows.Automation.TreeScope]::Descendants, $tabTypeCond)
                                foreach ($ut in $uiaTabs) {
                                    if ($ut.Current.Name -like "*$ProjectName*") {
                                        $DuplicateFound = $true
                                        Write-DebugLog "Launcher: Duplicate tab '$($ut.Current.Name)'"
                                        break
                                    }
                                }
                                if ($DuplicateFound) { break }
                            }
                            if ($DuplicateFound) { break }
                        }
                        if ($DuplicateFound) {
                            $ActualTitle = "${ProjectName}#${TargetPid}"
                            Write-DebugLog "Launcher: PID-suffixed title '$ActualTitle'"
                        }
                    }
                } catch {
                    Write-DebugLog "Launcher: Duplicate check error: $_"
                }

                [Console]::Title = $ActualTitle
                $Osc = "$([char]27)]0;$ActualTitle$([char]7)"
                [Console]::Write($Osc)
                [Console]::Out.Flush()
                Write-DebugLog "Launcher: Injected title '$ActualTitle' into PID $TargetPid"
            } else {
                # 非默认标题（用户自定义或 Claude Code 对话摘要）→ 保持不变
                $UserCustomTitle = $true
                $ActualTitle = $CurrentTitle
                Write-DebugLog "Launcher: User custom title detected '$CurrentTitle'. Keeping unchanged."
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

# 用户自定义标题 → 跳过 Watchdog 标题注入
$SkipTitleArg = ""
if ($UserCustomTitle) { $SkipTitleArg = "-SkipTitleInjection" }

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

# 7. PACE Stop 阻止检测
# stop.js 阻止退出(exit 2)时递增 counter，通过时重置为 0
# counter > 0 且无 degraded 文件 → 正在阻止中，跳过通知
# counter > 0 但有 degraded 文件 → 降级放行(exit 0)，会话结束，正常通知
$PaceBlockFile = Join-Path $PWD ".pace" "stop-block-count"
$PaceDegradedFile = Join-Path $PWD ".pace" "degraded"
if ((Test-Path $PaceBlockFile) -and -not (Test-Path $PaceDegradedFile)) {
    $BlockRaw = (Get-Content $PaceBlockFile -Raw -ErrorAction SilentlyContinue)
    if ($BlockRaw) {
        $BlockRaw = $BlockRaw.Trim()
        if ($BlockRaw -match '^\d+$' -and [int]$BlockRaw -gt 0) {
            Write-DebugLog "Launcher: PACE Stop blocked (count=$BlockRaw). Skipping notification."
            exit 0
        }
    }
}

# 8. Launch Worker
$WorkerScript = "$Dir\Worker.ps1"

$WorkerProc = Start-Process "pwsh" -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$WorkerScript`" -Worker -Base64Title `"$B64Title`" -Base64Message `"$B64Message`" -ProjectName `"$EncProject`" -NotificationType `"$NotificationType`" $AudioArg $TranscriptArg $DebugArg $DelayArg $TargetPidArg $SkipTitleArg $ActualTitleArg $ToolNameArg $ToolInputArg"

# 9. Wait Mode
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
