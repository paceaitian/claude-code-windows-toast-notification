<#
.SYNOPSIS
    Windows Toast 通知脚本 - 支持 BurntToast 模块和双进程模式

.DESCRIPTION
    使用 BurntToast PowerShell 模块显示原生 Windows Toast 通知。
    支持协议激活实现点击聚焦功能（通过 claude-runner: URI scheme）。
    支持 Smart Foreground Detection 避免打扰正在查看 Claude 的用户。

.PARAMETER Title
    通知标题

.PARAMETER Message
    通知正文

.PARAMETER AppId
    应用程序 ID（保留用于兼容性）

.PARAMETER AudioPath
    .wav 音频文件路径

.PARAMETER InputObject
    管道输入，通常是 JSON payload

.PARAMETER Worker
    内部参数：启用 Worker 模式（后台进程）

.PARAMETER Base64Title
    内部参数：Base64 编码的标题

.PARAMETER Base64Message
    内部参数：Base64 编码的消息

.PARAMETER TargetPid
    内部参数：目标进程 ID

.PARAMETER TargetHwnd
    内部参数：目标窗口句柄

.PARAMETER BeaconTitle
    内部参数：用于 UIA 搜索的标题

.PARAMETER TabIndex
    内部参数：直接 Tab 索引（多窗口支持）

.PARAMETER NotificationType
    内部参数：通知类型（如 "permission_prompt"）

.PARAMETER Wait
    启用阻塞模式（自动恢复）

.PARAMETER Delay
    延迟通知秒数（避免活跃使用时打扰）

.PARAMETER PollInterval
    轮询检测间隔（秒）

.PARAMETER ModulePath
    BurntToast 模块显式路径

.PARAMETER EnableDebug
    启用调试日志

.EXAMPLE
    .\windows-notification.ps1 -Title "任务完成" -Message "构建成功"

.EXAMPLE
    @{ title = "Build Complete"; message = "Success" } | .\windows-notification.ps1
#>

param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Title = "Claude Code Notification",

    [Parameter(Mandatory=$false, Position=1)]
    [string]$Message = "Task finished.",

    [string]$AppId,
    [string]$AudioPath,

    [Parameter(ValueFromPipeline=$true)]
    [psobject]$InputObject,

    # Worker 模式参数
    [switch]$Worker,
    [string]$Base64Title,
    [string]$Base64Message,
    [string]$ProjectName,
    [string]$NotificationType,
    [switch]$Wait,
    [int]$Delay = 0,
    [int]$PollInterval = 5,
    [string]$ModulePath,
    [switch]$EnableDebug
)

# 导入共享辅助函数
$CommonHelpersPath = Join-Path $PSScriptRoot "common-helpers.ps1"
if (Test-Path $CommonHelpersPath) {
    . $CommonHelpersPath
} else {
    Write-Warning "共享辅助模块未找到: $CommonHelpersPath"
}

# ============================================================================
# WORKER 模式（后台进程）
# ============================================================================
if ($Worker) {
    Set-CHDebugMode -Enabled ($EnableDebug -or ($env:CLAUDE_HOOK_DEBUG -eq "1")) `
                    -LogPath "$env:USERPROFILE\.claude\toast_debug.log"

    Write-CHDebugLog "Worker 启动 (PID: $PID), ProjectName: $ProjectName"

    # 全局错误处理
    trap {
        Write-CHDebugLog "Worker 崩溃: $($_.Exception.Message)"
        exit 1
    }

    # 加载 BurntToast 模块
    try {
        if ($ModulePath -and (Test-Path $ModulePath)) {
            Write-CHDebugLog "导入模块: $ModulePath"
            Import-Module $ModulePath -Force -ErrorAction Stop
        } else {
            Import-Module BurntToast -ErrorAction Stop
        }
    } catch {
        Write-CHDebugLog "标准导入失败: $_"
        # 回退：手动搜索模块路径
        $ModulePaths = $env:PSModulePath -split ';'
        $Found = $false
        foreach ($Path in $ModulePaths) {
            $Possible = Join-Path $Path "BurntToast"
            if (Test-Path $Possible) {
                $Psd1 = Get-ChildItem $Possible -Recurse -Filter "*.psd1" | Select-Object -First 1
                if ($Psd1) {
                    Import-Module $Psd1.FullName -Force -ErrorAction Stop
                    Write-CHDebugLog "已导入: $($Psd1.FullName)"
                    $Found = $true
                    break
                }
            }
        }
        if (-not $Found) {
            Write-CHDebugLog "致命错误: 找不到 BurntToast 模块"
        }
    }

    # 解码参数
    try {
        if ($Base64Title) {
            $Title = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Title))
        }
        if ($Base64Message) {
            $Message = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Message))
        }
        # URL 解码项目名
        if ($ProjectName) {
            $ProjectName = [Uri]::UnescapeDataString($ProjectName)
        }
        Write-CHDebugLog "解码标题: $Title"
        Write-CHDebugLog "解码消息: $Message"
        Write-CHDebugLog "项目名: $ProjectName"
    } catch {
        Write-CHDebugLog "解码错误: $_"
    }

    # 构建协议激活 URI（使用项目名）
    $LaunchUri = "claude-runner:focus?project=$ProjectName"
    if ($NotificationType) {
        $LaunchUri += "&notification_type=$NotificationType"
    }
    if ($EnableDebug) {
        $LaunchUri += "&debug=1"
    }

    # 显示通知
    $IsPermissionPrompt = $LaunchUri -match "notification_type=permission_prompt"
    try {
        $Text1 = New-BTText -Text $Title
        $Text2 = New-BTText -Text $Message

        # Logo
        $LogoPath = "$env:USERPROFILE\.claude\assets\claude-logo.png"
        $Image = if (Test-Path $LogoPath) {
            New-BTImage -Source $LogoPath -AppLogoOverride -Crop Circle
        } else { $null }

        # Binding 和 Visual
        $Binding = if ($Image) {
            New-BTBinding -Children $Text1, $Text2 -AppLogoOverride $Image
        } else {
            New-BTBinding -Children $Text1, $Text2
        }
        $Visual = New-BTVisual -BindingGeneric $Binding

        # 按钮
        $Actions = if ($IsPermissionPrompt) {
            $Btn1 = New-BTButton -Content 'Allow' -Arguments "$LaunchUri&button=1" -ActivationType Protocol
            $BtnDismiss = New-BTButton -Dismiss -Content 'Dismiss'
            New-BTAction -Buttons $Btn1, $BtnDismiss
        } else {
            $BtnDismiss = New-BTButton -Dismiss
            New-BTAction -Buttons $BtnDismiss
        }

        # 静音 + Reminder 场景
        $Audio = New-BTAudio -Silent
        $Content = New-BTContent -Visual $Visual -Actions $Actions -Audio $Audio `
                                -ActivationType Protocol -Launch $LaunchUri -Scenario Reminder

        Submit-BTNotification -Content $Content
        Write-CHDebugLog "通知已显示"
    } catch {
        Write-CHDebugLog "通知失败: $_"
    }

    # 播放自定义音频
    if ($AudioPath -and (Test-Path $AudioPath)) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $Player = New-Object System.Media.SoundPlayer $AudioPath
            $Player.PlaySync()
        } catch {}
    }

    exit
}

# ============================================================================
# LAUNCHER 模式（主入口）
# ============================================================================

Set-CHDebugMode -Enabled ($EnableDebug -or ($env:CLAUDE_HOOK_DEBUG -eq "1")) `
                -LogPath "$env:USERPROFILE\.claude\toast_debug.log"

Write-CHDebugLog "--- LAUNCHER 启动 ---"

# 处理输入
try {
    $Payload = $null
    if ($InputObject) {
        if ($InputObject -is [string]) {
            $Payload = $InputObject | ConvertFrom-Json -ErrorAction SilentlyContinue
        } else {
            $Payload = $InputObject
        }
    } elseif ($input) {
        $RawInput = $input | Out-String
        if (-not [string]::IsNullOrWhiteSpace($RawInput)) {
            $Payload = $RawInput | ConvertFrom-Json -ErrorAction SilentlyContinue
        }
    }

    if ($Payload) {
        Write-CHDebugLog "Payload: $($Payload | ConvertTo-Json -Depth 5 -Compress)"
        # 调试：打印所有 payload 属性
        Write-CHDebugLog "Payload 属性: $($Payload.PSObject.Properties.Name -join ', ')"
        if ($Payload.notification_type) {
            $NotificationType = $Payload.notification_type
        }
        # 从 payload 中提取项目名
        if (-not $ProjectName -and $Payload.project_name) {
            $ProjectName = $Payload.project_name
            Write-CHDebugLog "从 payload.project_name 获取项目名: $ProjectName"
        }
        if (-not $ProjectName -and $Payload.project_dir) {
            $ProjectName = Split-Path $Payload.project_dir -Leaf
            Write-CHDebugLog "从 payload.project_dir 获取项目名: $ProjectName"
        }
    }
} catch {}

# Smart Foreground Detection: 用户正在看目标项目 Tab 则不打扰
if ($Delay -gt 0) {
    Write-CHDebugLog "智能等待 $Delay 秒..."
    $Elapsed = 0
    $CheckInterval = 1

    while ($Elapsed -lt $Delay) {
        # 如果有项目名，检查特定项目；否则检查任意 Claude Tab
        if ($ProjectName) {
            if (Test-ClaudeTabFocused -ProjectName $ProjectName) {
                Write-CHDebugLog "用户正在查看目标项目 Tab！取消通知"
                exit 0
            }
        } else {
            if (Test-ClaudeTabFocused) {
                Write-CHDebugLog "用户正在查看 Claude Tab！取消通知"
                exit 0
            }
        }
        Start-Sleep -Seconds $CheckInterval
        $Elapsed += $CheckInterval
    }
    Write-CHDebugLog "超时到达 ($Delay 秒)，显示通知"
} else {
    if ($ProjectName) {
        if (Test-ClaudeTabFocused -ProjectName $ProjectName) {
            Write-CHDebugLog "目标项目 Tab 可见，退出"
            exit 0
        }
    } else {
        if (Test-ClaudeTabFocused) {
            Write-CHDebugLog "Claude Tab 可见，退出"
            exit 0
        }
    }
}

Write-CHDebugLog "继续显示通知..."

# Transcript 解析
try {
    if ($Payload -and $Payload.transcript_path -and (Test-Path $Payload.transcript_path)) {
        $TranscriptLines = Get-Content $Payload.transcript_path -Tail 50 -Encoding UTF8 -ErrorAction Stop
        $ResponseTime = ""
        $ToolUseInfo = $null
        $TextMessage = $null

        # 提取最后一条助手消息
        for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
            $Line = $TranscriptLines[$i]
            if ([string]::IsNullOrWhiteSpace($Line)) { continue }

            try {
                $Entry = $Line | ConvertFrom-Json

                # 停止条件：遇到用户消息（避免使用上一轮的过期内容）
                if ($Entry.type -eq 'user' -and $Entry.message) { break }

                # 获取内容
                if ($Entry.type -eq 'assistant' -and $Entry.message) {
                    $Content = $Entry.message.content
                } elseif ($Entry.type -eq 'message' -and $Entry.role -eq 'assistant') {
                    $Content = $Entry.content
                } else {
                    $Content = $null
                }

                if ($Content) {
                    # 提取时间戳
                    if ($Entry.timestamp -and -not $ResponseTime) {
                        try {
                            $UtcTime = [DateTime]::Parse($Entry.timestamp)
                            $LocalTime = $UtcTime.ToLocalTime()
                            $ResponseTime = $LocalTime.ToString("HH:mm")
                        } catch {}
                    }

                    # 提取 tool_use 信息
                    $ToolUse = $Content | Where-Object { $_.type -eq 'tool_use' } | Select-Object -First 1
                    if ($ToolUse) {
                        $ToolName = $ToolUse.name
                        $ToolInput = $ToolUse.input
                        Write-CHDebugLog "找到 tool_use: $ToolName"
                        Write-CHDebugLog "ToolInput: $($ToolInput | ConvertTo-Json -Compress -Depth 1)"

                        $Detail, $Description = Get-ToolDetail -ToolName $ToolName -ToolInput $ToolInput
                        Write-CHDebugLog "Get-ToolDetail 返回 - Detail: $Detail, Description: $Description"

                        if ($Detail -or $Description) {
                            $Combined = ""
                            if ($Detail) {
                                $Combined = Escape-XmlText -Text $Detail
                            }
                            if ($Description) {
                                if ($Combined) { $Combined += " - " }
                                $Combined += $Description
                            }
                            if ($Combined.Length -gt 200) {
                                $Combined = $Combined.Substring(0, 197) + "..."
                            }
                            $ToolUseInfo = "[$ToolName] $Combined"
                            Write-CHDebugLog "ToolUseInfo: $ToolUseInfo"
                        } else {
                            Write-CHDebugLog "Get-ToolDetail 未返回任何信息"
                        }
                    }

                    # 提取 text 内容
                    $LastText = $Content | Where-Object { $_.type -eq 'text' } |
                                Select-Object -ExpandProperty text -Last 1
                    if ($LastText) {
                        $CleanText = Remove-MarkdownFormat -Text $LastText -MaxLength 800
                        $TextMessage = if ($ResponseTime) {
                            "A: [$ResponseTime] $CleanText"
                        } else {
                            "A: $CleanText"
                        }
                    }

                    # 决定最终消息
                    if ($TextMessage -and $ToolUseInfo) {
                        if ($Payload.notification_type -eq 'permission_prompt') {
                            $Message = $ToolUseInfo  # 忽略 TextMessage，避免显示过期文本
                            Write-CHDebugLog "Permission Prompt 使用 ToolUseInfo: $Message"
                        } else {
                            $Message = "$TextMessage  $ToolUseInfo"
                        }
                    } elseif ($TextMessage) {
                        $Message = $TextMessage
                        Write-CHDebugLog "使用 TextMessage: $Message"
                    } elseif ($ToolUseInfo) {
                        $Message = $ToolUseInfo
                        Write-CHDebugLog "使用 ToolUseInfo: $Message"
                    }

                    if ($Message -ne "Task finished.") {
                        # 找到有效内容，停止搜索
                        break
                    }
                }
            } catch {}
        }

        # 提取用户问题
        for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
            $Line = $TranscriptLines[$i]
            if ([string]::IsNullOrWhiteSpace($Line)) { continue }

            try {
                $Entry = $Line | ConvertFrom-Json
                if ($Entry.type -eq 'user' -and $Entry.message -and -not $Entry.isMeta) {
                    $UserContent = $Entry.message.content
                    if ($UserContent -is [string] -and $UserContent -notmatch '^\s*<') {
                        $UserText = $UserContent.Trim()
                        if ($UserText.Length -gt 60) {
                            $UserText = $UserText.Substring(0, 57) + "..."
                        }
                        if ($UserText) {
                            $Title = "Q: $UserText"
                            break
                        }
                    }
                }
            } catch {}
        }
    }
} catch {}

# Payload 回退处理
if ($Payload) {
    # 注意：Permission Prompt 的详细信息已从 Transcript 中提取（$ToolUseInfo）
    # Payload 中通常只有 message 和 notification_type，没有 tool_name/tool_input

    if ($Payload.title -and $Title -eq "Claude Code Notification") {
        $Title = $Payload.title
    }

    # 只有当 Message 还是默认值时才使用 Payload.message
    # （Transcript 解析已经设置了正确的 Message）
    if ($Payload.message -and $Message -eq "Task finished.") {
        $Message = $Payload.message
    }
}

# 默认标题处理
if ($Title -eq "Claude Code Notification" -and $env:CLAUDE_PROJECT_DIR) {
    $ProjectName = Split-Path $env:CLAUDE_PROJECT_DIR -Leaf
    $Title = "Task Done [$ProjectName]"
}

# 修复编码
$Title = Repair-Encoding -str $Title
$Message = Repair-Encoding -str $Message

# 获取项目文件夹名作为 Tab 标识符
$ProjectTabName = $null
if ($env:CLAUDE_PROJECT_DIR) {
    $ProjectTabName = Split-Path $env:CLAUDE_PROJECT_DIR -Leaf
} elseif ($Payload -and $Payload.project_dir) {
    $ProjectTabName = Split-Path $Payload.project_dir -Leaf
} elseif ($Payload -and $Payload.project_name) {
    $ProjectTabName = $Payload.project_name
}

# 自动修改 Tab 名称为项目名（如果当前不是项目名）
if ($ProjectTabName) {
    try {
        $FgHwnd = [WinApi]::GetForegroundWindow()
        $FgPid = 0
        [WinApi]::GetWindowThreadProcessId($FgHwnd, [ref]$FgPid)

        if ($FgPid -gt 0) {
            $FgProc = Get-Process -Id $FgPid -ErrorAction SilentlyContinue
            if ($FgProc -and $FgProc.ProcessName -eq "WindowsTerminal") {
                $terminal = Get-TerminalByHwnd -Hwnd [int]$FgHwnd
                if ($terminal) {
                    $selectedIndex = Get-SelectedTabIndex -Terminal $terminal
                    if ($selectedIndex -ge 0) {
                        $Tabs = Get-TerminalTabs $terminal
                        $currentTabName = $Tabs[$selectedIndex].Current.Name

                        # 只有当当前 Tab 名称不是项目名时才修改
                        if ($currentTabName -ne $ProjectTabName) {
                            # 使用 ANSI escape sequence 修改 Tab 名称
                            $ansiSequence = "$([char]0x1b)]0;$ProjectTabName$([char]0x07)"
                            Write-Host -NoNewline $ansiSequence
                            Write-CHDebugLog "Tab 名称修改: '$currentTabName' -> '$ProjectTabName'"
                        } else {
                            Write-CHDebugLog "Tab 名称已是项目名: '$ProjectTabName'，无需修改"
                        }
                    }
                }
            }
        }
    } catch {
        Write-CHDebugLog "修改 Tab 名称失败: $_"
    }
}

# 编码参数
$B64Title = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Title))
$B64Message = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Message))
$SelfPath = $MyInvocation.MyCommand.Path

# URL 编码项目名
$EncodedProjectName = if ($ProjectTabName) { [Uri]::EscapeDataString($ProjectTabName) } else { "" }

# 构建参数列表
$ArgumentList = @(
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$SelfPath`"",
    "-Worker",
    "-Base64Title", "`"$B64Title`"",
    "-Base64Message", "`"$B64Message`"",
    "-AudioPath", "`"$AudioPath`"",
    "-ProjectName", "`"$EncodedProjectName`""
)

if ($NotificationType) {
    $ArgumentList += "-NotificationType", "`"$NotificationType`""
}

# 解析 BurntToast 模块路径
$BTModule = Get-Module -ListAvailable BurntToast | Select-Object -First 1
if (-not $BTModule) {
    $Docs = [Environment]::GetFolderPath('MyDocuments')
    $LegacyPath = Join-Path $Docs "WindowsPowerShell\Modules\BurntToast"
    if (Test-Path $LegacyPath) {
        $Psd1 = Get-ChildItem $LegacyPath -Filter "*.psd1" -Recurse | Select-Object -First 1
        if ($Psd1) {
            $ArgumentList += "-ModulePath", "`"$($Psd1.FullName)`""
        }
    }
} elseif ($BTModule.Path -or $BTModule.ModuleBase) {
    $BTPath = if ($BTModule.Path) { $BTModule.Path } else { $BTModule.ModuleBase }
    $ArgumentList += "-ModulePath", "`"$BTPath`""
}

if ($EnableDebug) {
    $ArgumentList += "-EnableDebug"
}

# 启动 Worker
try {
    $CurrentShell = (Get-Process -Id $PID).Path
    Start-Process $CurrentShell -WindowStyle Hidden -ArgumentList $ArgumentList
} catch {
    Write-Warning "无法启动 Worker: $_"
}

# 阻塞模式（自动恢复）
if ($Wait -and $TargetHwnd -gt 0) {
    Write-Host "`n[阻塞模式] 保持 Beacon '$BeaconTitle'..." -ForegroundColor DarkGray
    Write-Host "等待焦点返回..." -ForegroundColor DarkGray

    Start-Sleep -Seconds 2  # 宽限期

    # 焦点循环（10秒超时）
    $TimeoutSeconds = 10
    $ElapsedMs = 0
    while ($ElapsedMs -lt ($TimeoutSeconds * 1000)) {
        $CurrentFg = [WinApi]::GetForegroundWindow()
        $CurrentFgPid = 0
        [WinApi]::GetWindowThreadProcessId($CurrentFg, [ref]$CurrentFgPid)

        $IsFocusedOnIDE = $false
        if ($CurrentFgPid -gt 0) {
            try {
                $FgProc = Get-Process -Id $CurrentFgPid -ErrorAction Stop
                if ($FgProc.ProcessName -eq "WindowsTerminal") {
                    $IsFocusedOnIDE = $true
                }
            } catch {}
        }

        if ($IsFocusedOnIDE) {
            Write-Host "检测到焦点，恢复..." -ForegroundColor Green
            break
        }
        Start-Sleep -Milliseconds 100
        $ElapsedMs += 100
    }

    if ($ElapsedMs -ge ($TimeoutSeconds * 1000)) {
        Write-Host "超时，自动恢复..." -ForegroundColor Yellow
    }
} elseif ($Wait) {
    Write-Warning "无法确定 TargetHwnd"
    Write-Host "按 ENTER 继续..."
    $null = Read-Host
} else {
    Write-CHDebugLog "Launcher: 等待 10 秒..."
    Start-Sleep -Seconds 10
}

exit

# ============================================================================
# 辅助函数
# ============================================================================

<#
.SYNOPSIS
    从工具输入提取详情和描述

.PARAMETER ToolName
    工具名称

.PARAMETER ToolInput
    工具输入参数

.OUTPUTS
    [string]$Detail, [string]$Description
#>
function Get-ToolDetail {
    param(
        [string]$ToolName,
        [hashtable]$ToolInput
    )

    $Detail = ""
    $Description = ""

    if (-not $ToolInput) {
        return $Detail, $Description
    }

    switch -Regex ($ToolName) {
        "^Bash$" {
            if ($ToolInput.command) { $Detail = $ToolInput.command }
            if ($ToolInput.description) { $Description = $ToolInput.description }
        }
        "^Read$" {
            if ($ToolInput.file_path) { $Detail = $ToolInput.file_path }
            if ($ToolInput.description) { $Description = $ToolInput.description }
        }
        "^Write$" {
            if ($ToolInput.file_path) { $Detail = "Write: " + $ToolInput.file_path }
            if ($ToolInput.description) { $Description = $ToolInput.description }
        }
        "^Edit$" {
            if ($ToolInput.file_path) { $Detail = "Edit: " + $ToolInput.file_path }
            if ($ToolInput.description) { $Description = $ToolInput.description }
        }
        "^Grep$" {
            if ($ToolInput.pattern) { $Detail = "Search: " + $ToolInput.pattern }
            if ($ToolInput.description) { $Description = $ToolInput.description }
        }
        "WebSearch|google_search" {
            if ($ToolInput.query) { $Detail = "Search: " + $ToolInput.query }
            elseif ($ToolInput.q) { $Detail = "Search: " + $ToolInput.q }
        }
        default {
            # 通用回退
            if ($ToolInput.description) {
                $Detail = $ToolInput.description
            } elseif ($ToolInput.file_path) {
                $Detail = $ToolInput.file_path
            } elseif ($ToolInput.path) {
                $Detail = $ToolInput.path
            } elseif ($ToolInput.url) {
                $Detail = $ToolInput.url
            } elseif ($ToolInput.input) {
                $Detail = $ToolInput.input
            } elseif ($ToolInput.content) {
                $c = $ToolInput.content
                if ($c.Length -lt 50) {
                    $Detail = $c
                } else {
                    $Detail = "Content..."
                }
            } else {
                # 最后手段：JSON
                try {
                    $Json = $ToolInput | ConvertTo-Json -Depth 1 -Compress
                    if ($Json.Length -gt 50) {
                        $Json = $Json.Substring(0, 47) + "..."
                    }
                    $Detail = $Json
                } catch {
                    $Detail = "Complex Input"
                }
            }
        }
    }

    return $Detail, $Description
}
