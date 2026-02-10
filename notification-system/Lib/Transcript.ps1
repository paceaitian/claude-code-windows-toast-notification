# Transcript.ps1 - Claude 转录文件解析模块
# 从转录文件中提取用户问题、助手回复、工具调用等信息

<#
.SYNOPSIS
    检查字符串是否包含敏感信息模式

.PARAMETER str
    要检查的字符串

.OUTPUTS
    如果包含敏感信息返回 $true，否则返回 $false
#>
function Test-SensitiveContent([string]$str) {
    if ([string]::IsNullOrEmpty($str)) { return $false }

    $SensitiveFields = $Script:CONFIG_SENSITIVE_FIELDS
    if (-not $SensitiveFields) {
        $SensitiveFields = @('api_key', 'apikey', 'password', 'token', 'secret', 'credential', 'private_key')
    }

    # 检查是否包含敏感字段名
    foreach ($field in $SensitiveFields) {
        if ($str -match "(?i)$field\s*[=:]") { return $true }
    }

    # 检查常见敏感值模式（如 sk-xxx, ghp_xxx, AWS Key, JWT 等）
    if ($str -match "(sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36,}|gho_[a-zA-Z0-9]{36,}|AKIA[0-9A-Z]{16}|eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,})") { return $true }

    return $false
}

<#
.SYNOPSIS
    将字符串首字母大写

.PARAMETER str
    输入字符串

.OUTPUTS
    首字母大写的字符串，空字符串返回原值
#>
function ConvertTo-TitleCase([string]$str) {
    if ([string]::IsNullOrEmpty($str)) { return $str }
    if ($str.Length -eq 1) { return $str.ToUpper() }
    return $str.Substring(0,1).ToUpper() + $str.Substring(1)
}

<#
.SYNOPSIS
    格式化工具调用信息为可读字符串

.PARAMETER Name
    工具名称（如 Bash, Read, Task, mcp__server__tool）

.PARAMETER InputObj
    工具输入参数对象

.OUTPUTS
    格式化的字符串，如 "[Bash] ls -la" 或 "[Read] config.json"
#>
function Format-ClaudeToolInfo {
    param($Name, $InputObj)

    $DisplayName = $Name
    $Detail = ""

    # 1. Subagent / Task
    if ($Name -eq "Task" -and $InputObj.subagent_type) {
        $SubAgent = ($InputObj.subagent_type -split ":")[-1]
        $DisplayName = ConvertTo-TitleCase $SubAgent
        if ($InputObj.description) { $Detail = $InputObj.description }
    }
    # 2. MCP Tools (mcp__server__tool)
    elseif ($Name -match "^mcp__") {
        $Parts = $Name -split "__"
        if ($Parts.Count -ge 3) {
            $DisplayName = ConvertTo-TitleCase $Parts[-1]
        }

        if ($InputObj.command) { $Detail = $InputObj.command }
        elseif ($InputObj.query) { $Detail = "Search: " + $InputObj.query }
        elseif ($InputObj.path) { $Detail = $InputObj.path }
        elseif ($InputObj.uri) { $Detail = $InputObj.uri }
    }
    # 3. Standard Tools
    else {
        switch -Regex ($Name) {
            "^Bash$" {
                if ($InputObj.command) { $Detail = $InputObj.command }
            }
            "^Grep$" {
                if ($InputObj.pattern) { $Detail = "Search: " + $InputObj.pattern }
            }
            "^(Read|Write|Edit)(_file)?$" {
                $DisplayName = $Matches[1]
                if ($InputObj.file_path) {
                    $Detail = Split-Path $InputObj.file_path -Leaf
                }
            }
            "WebSearch|google_search" {
                if ($InputObj.query) { $Detail = "Search: " + $InputObj.query }
                elseif ($InputObj.q) { $Detail = "Search: " + $InputObj.q }
            }
            default {
                if ($InputObj.description) { $Detail = $InputObj.description }
                elseif ($InputObj.input) { $Detail = $InputObj.input }
                elseif ($InputObj.path) { $Detail = $InputObj.path }
                elseif ($InputObj.url) { $Detail = $InputObj.url }

                # Fallback: 仅显示工具名，不 dump JSON（避免泄露敏感信息）
            }
        }
    }

    $MaxLen = $Script:CONFIG_TOOL_DETAIL_MAX_LENGTH
    if (-not $MaxLen) { $MaxLen = 400 }

    if ($Detail) {
        # 敏感信息过滤：如果检测到敏感内容，仅显示工具名
        if (Test-SensitiveContent $Detail) {
            Write-DebugLog "Sensitive content detected in tool detail, hiding..."
            return "[$DisplayName] [内容已隐藏]"
        }

        if ($Detail.Length -gt $MaxLen) { $Detail = $Detail.Substring(0, $MaxLen - 3) + "..." }
        # XML Escape
        $Detail = $Detail -replace ">", "&gt;" -replace "<", "&lt;"
        return "[$DisplayName] $Detail"
    }
    return "[$DisplayName]"
}

<#
.SYNOPSIS
    从 Payload 数据中提取通知内容

.PARAMETER ToolName
    工具名称

.PARAMETER ToolInput
    工具输入参数对象（可为 $null）

.PARAMETER Message
    原始消息内容

.OUTPUTS
    Hashtable 包含:
    - ToolInfo: 格式化的工具信息字符串（如 "[Bash] ls -la"）
    - Description: 描述文本（清理后的 Message）
#>
function Get-ClaudeContentFromPayload {
    param(
        [string]$ToolName,
        [object]$ToolInput,
        [string]$Message
    )

    $Result = @{
        ToolInfo = $null
        Description = $null
    }

    if ($ToolName) {
        $Result.ToolInfo = Format-ClaudeToolInfo -Name $ToolName -InputObj $ToolInput

        # 处理描述文本
        if ($Message -and $Message -ne "Task finished.") {
            $MaxLen = $Script:CONFIG_MESSAGE_MAX_LENGTH
            if (-not $MaxLen) { $MaxLen = 800 }
            if ($Message.Length -gt $MaxLen) { $Message = $Message.Substring(0, $MaxLen - 3) + "..." }
            $Result.Description = $Message
        }
    }
    return $Result
}

<#
.SYNOPSIS
    从 Claude 转录文件中提取通知信息

.PARAMETER TranscriptPath
    转录文件路径

.PARAMETER ProjectName
    项目名称（用于 Fallback 标题）

.OUTPUTS
    Hashtable 包含:
    - Title: 用户问题（格式: "Q: ..."）或 Fallback 标题
    - ToolInfo: 工具调用信息（如 "[Bash] ls -la"）
    - Description: 助手回复文本
    - NotificationType: 通知类型（如 'permission_prompt'）
    - ResponseTime: 响应时间戳（格式: "HH:mm"）
#>
function Get-ClaudeTranscriptInfo {
    param(
        [string]$TranscriptPath,
        [string]$ProjectName
    )

    $Result = @{
        Title = $null
        ToolInfo = $null
        Description = $null
        NotificationType = $null
        ResponseTime = $null
    }

    if (-not ($TranscriptPath -and (Test-Path $TranscriptPath))) { return $Result }

    try {
        $TranscriptLines = Get-Content $TranscriptPath -Tail 50 -Encoding UTF8 -ErrorAction Stop

        $ResponseTime = ""

        # 1. Extract Last Assistant Message
        for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
            $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
            try {
                $Entry = $Line | ConvertFrom-Json

                if ($Entry.type -eq 'user' -and $Entry.message) { break }

                $Content = $null
                if ($Entry.type -eq 'assistant' -and $Entry.message) {
                    $Content = $Entry.message.content
                } elseif ($Entry.type -eq 'message' -and $Entry.role -eq 'assistant') {
                    $Content = $Entry.content
                }

                if ($Content) {
                    if ($Entry.timestamp -and -not $ResponseTime) {
                        try {
                            $ResponseTime = [DateTime]::Parse($Entry.timestamp).ToLocalTime().ToString("HH:mm")
                            $Result.ResponseTime = $ResponseTime
                        } catch {}
                    }

                    # --- TOOL EXTRACTION ---
                    $ToolUse = $Content | Where-Object { $_.type -eq 'tool_use' } | Select-Object -First 1

                    if ($ToolUse) {
                        $Result.ToolInfo = Format-ClaudeToolInfo -Name $ToolUse.name -InputObj $ToolUse.input
                    }

                    # --- TEXT EXTRACTION ---
                    $TextString = ""
                    $LastText = $Content | Where-Object { $_.type -eq 'text' } | Select-Object -ExpandProperty text -Last 1
                    if ($LastText) {
                        # 清理 Markdown 格式
                        $CleanText = $LastText `
                            -replace '#{1,6}\s*', '' `
                            -replace '\*{1,2}([^*]+)\*{1,2}', '$1' `
                            -replace '```[a-z]*\r?\n?', '' `
                            -replace '`([^`]+)`', '$1' `
                            -replace '\[([^\]]+)\]\([^)]+\)', '$1' `
                            -replace '^\s*[-*]\s+', '' `
                            -replace '\r?\n', ' '
                        $CleanText = $CleanText.Trim()

                        $MaxLen = $Script:CONFIG_MESSAGE_MAX_LENGTH
                        if (-not $MaxLen) { $MaxLen = 800 }
                        if ($CleanText.Length -gt $MaxLen) { $CleanText = $CleanText.Substring(0, $MaxLen - 3) + "..." }
                        $TextString = $CleanText
                    }

                    # --- DETECT PERMISSION ---
                    $IsPermission = ($TextString -match "(permission|approve|proceed|allow|confirm|authorize)")

                    if ($Result.NotificationType -eq 'permission_prompt' -or $IsPermission) {
                        if (-not $Result.NotificationType) { $Result.NotificationType = 'permission_prompt' }
                    }

                    $Result.Description = $TextString

                    if ($Result.ToolInfo -or $Result.Description) { break }
                }
            } catch { Write-DebugLog "Transcript JSON Parse Error: $_" }
        }

        # 2. Extract User Question
        $MaxTitleLen = $Script:CONFIG_TITLE_MAX_LENGTH
        if (-not $MaxTitleLen) { $MaxTitleLen = 60 }

        for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
            $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
            try {
                $Entry = $Line | ConvertFrom-Json
                if ($Entry.type -eq 'user' -and $Entry.message -and -not $Entry.isMeta) {
                    $UserContent = $Entry.message.content
                    if ($UserContent -is [string] -and $UserContent -notmatch '^\s*<') {
                        $UserText = $UserContent.Trim()
                        if ($UserText.Length -gt $MaxTitleLen) { $UserText = $UserText.Substring(0, $MaxTitleLen - 3) + "..." }
                        if ($UserText) { $Result.Title = "Q: $UserText"; break }
                    }
                }
            } catch { Write-DebugLog "Transcript User Parse Error: $_" }
        }
    } catch { Write-DebugLog "Transcript Parse Error: $_" }

    # Fallback Title
    if (-not $Result.Title) {
        if ($ProjectName) { $Result.Title = "Task Done [$ProjectName]" }
        else { $Result.Title = "Claude Notification" }
    }

    return $Result
}
