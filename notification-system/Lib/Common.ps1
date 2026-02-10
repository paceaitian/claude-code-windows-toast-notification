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
