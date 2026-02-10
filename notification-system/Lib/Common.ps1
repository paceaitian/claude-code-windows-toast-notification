# Common.ps1 - 通用工具函数
# 提供调试日志和编码修复等基础功能

# 加载配置
$Dir = Split-Path $MyInvocation.MyCommand.Path
. "$Dir\Config.ps1"

# 调试日志路径（从配置读取）
$DebugLog = $Script:CONFIG_DEBUG_LOG_PATH

# 调试模式检测：检查调用脚本的 $EnableDebug 参数或环境变量
# 注意：$EnableDebug 来自调用脚本（Launcher/Worker）的参数作用域
if (-not $Script:DebugEnabled) {
    $Script:DebugEnabled = (Get-Variable -Name EnableDebug -Scope 1 -ValueOnly -ErrorAction SilentlyContinue) -or ($env:CLAUDE_HOOK_DEBUG -eq "1")
}

<#
.SYNOPSIS
    写入调试日志

.PARAMETER Msg
    要记录的消息内容

.NOTES
    仅当 $EnableDebug 开关启用或 $env:CLAUDE_HOOK_DEBUG=1 时才写入日志
#>
function Write-DebugLog([string]$Msg) {
    if ($Script:DebugEnabled) {
        "[$((Get-Date).ToString('HH:mm:ss'))] $Msg" | Out-File $DebugLog -Append -Encoding UTF8
    }
}

<#
.SYNOPSIS
    检测窗口标题是否为默认值（未被用户自定义）

.PARAMETER Title
    当前窗口标题

.OUTPUTS
    如果是默认值返回 $true，用户自定义返回 $false

.NOTES
    默认值包括：
    - Claude Code 动态标题（带状态前缀 * · ✻ . 等）
    - claude - <目录> 格式
    - Shell 默认标题（PowerShell、cmd 等）
#>
function Test-IsDefaultTitle([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $true }

    # Claude Code 动态标题模式（包含状态前缀）
    $ClaudePatterns = @(
        '^[*·✻.\s]*Claude Code$',      # * Claude Code, · Claude Code, etc.
        '^claude\s+-\s*.+$'             # claude - hooks (必须有空格在 claude 后)
    )

    # Shell 默认标题
    $ShellPatterns = @(
        '^PowerShell$',
        '^Windows PowerShell$',
        '^pwsh$',
        '^cmd$',
        '^Command Prompt$',
        '^Administrator:\s*(PowerShell|Windows PowerShell|pwsh|cmd|Command Prompt)$'
    )

    $AllPatterns = $ClaudePatterns + $ShellPatterns

    foreach ($pattern in $AllPatterns) {
        if ($Title -match $pattern) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    获取唯一的项目标题（处理冲突）

.PARAMETER ProjectName
    项目名称

.PARAMETER TargetPid
    目标进程 ID

.OUTPUTS
    唯一的项目标题，如有冲突则添加 PID 后 4 位

.NOTES
    检测是否有其他窗口使用相同标题，如有冲突则添加 PID 后缀
#>
function Get-UniqueProjectTitle([string]$ProjectName, [int]$TargetPid) {
    if (-not $ProjectName -or $TargetPid -le 0) { return $ProjectName }

    try {
        # 检查是否有其他窗口使用相同标题
        $Existing = Get-Process | Where-Object {
            $_.MainWindowTitle -eq $ProjectName -and
            $_.Id -ne $TargetPid -and
            $_.ProcessName -ne "explorer"
        }

        if ($Existing) {
            # 添加 PID 后 4 位作为标识
            $PidStr = $TargetPid.ToString()
            $Suffix = $PidStr.Substring([Math]::Max(0, $PidStr.Length - 4))
            $UniqueTitle = "$ProjectName [$Suffix]"
            Write-DebugLog "Title conflict detected. Using unique title: $UniqueTitle"
            return $UniqueTitle
        }
    } catch {
        Write-DebugLog "Get-UniqueProjectTitle Error: $_"
    }

    return $ProjectName
}
