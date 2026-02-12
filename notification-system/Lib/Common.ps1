# Common.ps1 - 通用工具函数
# 提供调试日志和编码修复等基础功能

# 加载配置
$CommonDir = Split-Path $MyInvocation.MyCommand.Path
. "$CommonDir\Config.ps1"

# 调试日志路径（从配置读取）
$DebugLog = $Script:CONFIG_DEBUG_LOG_PATH

# 调试模式检测：检查当前作用域链中的 $EnableDebug 参数或环境变量
# dot-source 时 $EnableDebug 在 Scope 0（与调用脚本共享作用域）
if (-not $Script:DebugEnabled) {
    $found = $false
    for ($scope = 0; $scope -le 5; $scope++) {
        try {
            $val = Get-Variable -Name EnableDebug -Scope $scope -ErrorAction Stop
            # 明确检查是否为 $true，避免将 $false 误判为未设置
            if ($null -ne $val -and $val.Value -eq $true) {
                $found = $true
                break
            }
        } catch { }
    }
    $Script:DebugEnabled = $found -or ($env:CLAUDE_HOOK_DEBUG -eq "1")
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
    # Claude Code 使用 Braille 字符(⠐⠑⠒等)、*、·、✻、. 作为动画前缀
    $ClaudePatterns = @(
        '^[*·✻.\s\u2800-\u28FF]*Claude Code$',  # * Claude Code, · Claude Code, ⠐ Claude Code
        '^claude\s+-\s*.+$',                      # claude - hooks (必须有空格在 claude 后)
        '^[\u2800-\u28FF]'                         # 以 Braille 字符开头 = Claude Code 动画前缀
    )

    # Shell 默认标题
    $ShellPatterns = @(
        '^PowerShell$',
        '^Windows PowerShell$',
        '^pwsh$',
        '^cmd$',
        '^Command Prompt$',
        '^Administrator:\s*(PowerShell|Windows PowerShell|pwsh|cmd|Command Prompt)$',
        '\\cmd\.exe',                  # C:\WINDOWS\system32\cmd.exe
        '\\powershell\.exe',           # C:\...\powershell.exe
        '\\pwsh\.exe'                  # C:\...\pwsh.exe
    )

    $AllPatterns = $ClaudePatterns + $ShellPatterns

    foreach ($pattern in $AllPatterns) {
        if ($Title -match $pattern) { return $true }
    }
    return $false
}
