<#
.SYNOPSIS
    PreToolUse Hook - 强制执行 settings.json 中的 Bash 权限规则

.DESCRIPTION
    绕过 Claude Code 的权限匹配 bug（通配符不匹配多行命令、重定向符号等）。
    直接读取 settings.json 中的 allow/deny 规则，对 Bash 命令返回 allow/deny 决定。
    未匹配任何规则时不返回决定，交由 Claude Code 原生权限系统处理。
#>

# 从 stdin 读取 hook 输入
$InputJson = [Console]::In.ReadToEnd()
if ([string]::IsNullOrEmpty($InputJson)) { exit 0 }

$ErrorActionPreference = "Stop"

# 读取 settings.json 权限配置
function Get-PermissionSettings {
    $SettingsPath = "$env:USERPROFILE\.claude\settings.json"
    if (-not (Test-Path $SettingsPath)) { return $null }
    try {
        $Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        return $Settings.permissions
    } catch { return $null }
}

# 解析 Bash 权限规则
function Parse-BashRule {
    param([string]$Rule)

    # "Bash" — 匹配所有 Bash 命令
    if ($Rule -eq 'Bash') {
        return @{ Type = 'Bash'; Pattern = '*'; IsWildcard = $true }
    }

    # "Bash(command)" 或 "Bash(command *)"
    if ($Rule -match '^Bash\((.+)\)$') {
        $Pattern = $Matches[1]
        return @{ Type = 'Bash'; Pattern = $Pattern; IsWildcard = $Pattern -match '\*' }
    }

    return $null
}

# 检查命令是否匹配模式（支持通配符和多行命令）
function Test-CommandPattern {
    param([string]$Pattern, [string]$Command)

    # 将多行命令折叠为单行（修复 Claude Code 多行匹配 bug）
    $Cmd = ($Command -replace '\r?\n', ' ' -replace '\\\s+', ' ').Trim()

    if ($Pattern -eq '*') { return $true }

    # 先转义正则特殊字符，再将 \* 替换为 .*
    $RegexPattern = '^' + ([regex]::Escape($Pattern) -replace '\\\*', '.*') + '$'
    return $Cmd -match $RegexPattern
}

# 主逻辑
try {
    $InputData = $InputJson | ConvertFrom-Json

    # 只处理 Bash 工具
    if ($InputData.tool_name -ne "Bash") { exit 0 }

    $Command = $InputData.tool_input.command
    if (-not $Command) { exit 0 }

    $Permissions = Get-PermissionSettings
    if (-not $Permissions) { exit 0 }

    $AllowRules = @()
    $DenyRules = @()

    # 解析 allow 规则
    if ($Permissions.allow) {
        foreach ($Rule in $Permissions.allow) {
            $Parsed = Parse-BashRule -Rule $Rule
            if ($Parsed) { $AllowRules += $Parsed }
        }
    }

    # 解析 deny 规则
    if ($Permissions.deny) {
        foreach ($Rule in $Permissions.deny) {
            $Parsed = Parse-BashRule -Rule $Rule
            if ($Parsed) { $DenyRules += $Parsed }
        }
    }

    # 检查 deny 规则（优先级最高）
    foreach ($Rule in $DenyRules) {
        if (Test-CommandPattern -Pattern $Rule.Pattern -Command $Command) {
            @{
                hookEventName = "PreToolUse"
                permissionDecision = "deny"
                permissionDecisionReason = "Denied by rule: Bash($($Rule.Pattern))"
            } | ConvertTo-Json -Depth 3 | Write-Host
            exit 0
        }
    }

    # B1 修复：检测链式命令（&&, ||, ;），防止 "echo x && rm -rf /" 整体匹配 "echo *" 被自动批准
    # 管道（|）不算链式命令，属于同一管道的正常用法
    $CmdFlat = ($Command -replace '\r?\n', ' ' -replace '\\\s+', ' ').Trim()
    $HasChaining = $CmdFlat -match '(&&|\|\||;)'

    # 检查 allow 规则
    foreach ($Rule in $AllowRules) {
        if (Test-CommandPattern -Pattern $Rule.Pattern -Command $Command) {
            # 链式命令且非全匹配规则 → 跳过自动批准，交由原生权限系统处理
            if ($HasChaining -and $Rule.Pattern -ne '*') { continue }
            @{
                hookEventName = "PreToolUse"
                permissionDecision = "allow"
                permissionDecisionReason = "Allowed by rule: Bash($($Rule.Pattern))"
            } | ConvertTo-Json -Depth 3 | Write-Host
            exit 0
        }
    }

    # 未匹配任何规则 → 不返回决定，交由 Claude Code 原生权限系统处理
    exit 0

} catch {
    # 出错时不阻塞正常操作
    exit 0
}
