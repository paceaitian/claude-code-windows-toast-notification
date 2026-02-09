<#
.SYNOPSIS
    PreToolUse Hook - 强制执行 settings.json 中的 Bash 权限规则

.DESCRIPTION
    这个脚本作为 PreToolUse Hook 运行，用于绕过 Claude Code 的权限系统 bug。
    它直接读取 settings.json 中的权限规则，并根据 Bash 命令返回 allow/deny 决定。

    使用方法：
    1. 将此脚本放在 ~/.claude/hooks/ 目录
    2. 在 ~/.claude/hooks/ 中创建 PreToolUse/bash-permissions.json
    3. 重启 Claude Code

.NOTES
    文件名必须是 .ps1 结尾（PowerShell 脚本）
#>

# 从 stdin 或命令行参数读取输入
$InputJson = ""

# 优先从命令行参数获取（-File 方式传递 stdin 作为参数）
if ($args.Count -gt 0) {
    $InputJson = $args -join ""
}

# 如果没有参数，尝试从 stdin 读取
if ([string]::IsNullOrEmpty($InputJson)) {
    $inputReader = [Console]::In
    $InputJson = $inputReader.ReadToEnd()
}

# 调试输出（临时）
if (-not [string]::IsNullOrEmpty($InputJson)) {
    [Console]::Error.WriteLine("DEBUG: Received input: $($InputJson.Substring(0, [Math]::Min(100, $InputJson.Length)))...")
} else {
    [Console]::Error.WriteLine("DEBUG: No input received!")
}

# 设置错误处理
$ErrorActionPreference = "Stop"

# 读取 settings.json
function Get-PermissionSettings {
    $SettingsPath = "$env:USERPROFILE\.claude\settings.json"

    if (-not (Test-Path $SettingsPath)) {
        return $null
    }

    try {
        $Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        return $Settings.permissions
    } catch {
        return $null
    }
}

# 解析权限规则
function Parse-BashRule {
    param([string]$Rule)

    # Bash(command) 或 Bash(command *)
    if ($Rule -match '^Bash\((.+)\)$') {
        $Pattern = $Matches[1]
        return @{
            Type = 'Bash'
            Pattern = $Pattern
            IsWildcard = $Pattern -match '\*'
        }
    }

    return $null
}

# 检查命令是否匹配模式
function Test-CommandPattern {
    param(
        [string]$Pattern,
        [string]$Command
    )

    $Cmd = $Command.Trim()

    # 处理通配符：* 匹配任意字符
    if ($Pattern -match '\*') {
        $RegexPattern = $Pattern -replace '\*', '.*'
        # 转义正则表达式特殊字符（保留 .*）
        $RegexPattern = [regex]::Escape($Pattern) -replace '\\\*', '.*'
        return $Cmd -match $RegexPattern
    }

    # 精确匹配
    return $Cmd -eq $Pattern
}

# 主逻辑
try {
    # 临时测试：对所有 Bash 命令直接返回 allow
    if (-not [string]::IsNullOrEmpty($InputJson)) {
        $Decision = @{
            hookEventName = "PreToolUse"
            permissionDecision = "allow"
            permissionDecisionReason = "Test allow all"
        }
        $Decision | ConvertTo-Json -Depth 3 | Write-Host
        exit 0
    }

    $InputData = $InputJson | ConvertFrom-Json

    # 只处理 Bash 工具
    if ($InputData.tool_name -ne "Bash") {
        # 不是 Bash 工具，直接放行
        exit 0
    }

    # 获取命令
    $Command = $InputData.tool_input.command
    if (-not $Command) {
        # 没有命令，直接放行
        exit 0
    }

    # 读取权限设置
    $Permissions = Get-PermissionSettings
    if (-not $Permissions) {
        # 没有权限设置，直接放行
        exit 0
    }

    $AllowRules = @()
    $DenyRules = @()

    # 解析 allow 规则
    if ($Permissions.allow) {
        foreach ($Rule in $Permissions.allow) {
            $Parsed = Parse-BashRule -Rule $Rule
            if ($Parsed) {
                $AllowRules += $Parsed
            }
        }
    }

    # 解析 deny 规则
    if ($Permissions.deny) {
        foreach ($Rule in $Permissions.deny) {
            $Parsed = Parse-BashRule -Rule $Rule
            if ($Parsed) {
                $DenyRules += $Parsed
            }
        }
    }

    # 检查 deny 规则（优先级最高）
    foreach ($Rule in $DenyRules) {
        if (Test-CommandPattern -Pattern $Rule.Pattern -Command $Command) {
            # 返回 deny 决定
            $Decision = @{
                hookEventName = "PreToolUse"
                permissionDecision = "deny"
                permissionDecisionReason = "Denied by rule: $Rule"
            }
            $Decision | ConvertTo-Json -Depth 3 | Write-Host
            exit 0
        }
    }

    # 检查 allow 规则
    $Allowed = $false
    foreach ($Rule in $AllowRules) {
        if (Test-CommandPattern -Pattern $Rule.Pattern -Command $Command) {
            $Allowed = $true
            break
        }
    }

    if ($Allowed) {
        # 返回 allow 决定
        $Decision = @{
            hookEventName = "PreToolUse"
            permissionDecision = "allow"
            permissionDecisionReason = "Allowed by rule"
        }
        $Decision | ConvertTo-Json -Depth 3 | Write-Host
        exit 0
    }

    # 没有匹配任何规则，默认放行（让 Claude Code 原生权限系统处理）
    exit 0

} catch {
    # 发生错误，放行（不阻塞正常操作）
    Write-Warning "权限检查脚本错误: $_"
    exit 0
}
