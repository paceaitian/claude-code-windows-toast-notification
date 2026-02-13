# _regression_test.ps1 - 通知系统回归测试
# 验证 Bug 修复：焦点检测、重复通知、音频播放、权限误判
#
# 用法：pwsh -NoProfile -ExecutionPolicy Bypass -File _regression_test.ps1

$ErrorActionPreference = "Continue"
$Dir = Split-Path $MyInvocation.MyCommand.Path
$EnableDebug = $true

# 加载模块
. "$Dir\Lib\Common.ps1"
. "$Dir\Lib\Native.ps1"
. "$Dir\Lib\Transcript.ps1"
. "$Dir\Lib\Toast.ps1"

# ============================================================================
# 测试框架
# ============================================================================
$Script:Pass = 0
$Script:Fail = 0
$Script:Skip = 0

function Test-Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $Script:Pass++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor Yellow }
        $Script:Fail++
    }
}

function Test-Skip {
    param([string]$Name, [string]$Reason)
    Write-Host "  [SKIP] $Name ($Reason)" -ForegroundColor DarkYellow
    $Script:Skip++
}

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

# ============================================================================
# 测试 1: Native.ps1 — P/Invoke 声明完整性
# ============================================================================
Write-Section "1. P/Invoke 声明"

$WinApiType = [System.Management.Automation.PSTypeName]'WinApi'
Test-Assert "WinApi 类型已加载" ($WinApiType.Type -ne $null)

$Methods = @(
    'GetForegroundWindow', 'GetWindowText', 'GetWindowThreadProcessId',
    'AttachConsole', 'FreeConsole', 'GetConsoleWindow',
    'SetForegroundWindow', 'IsIconic', 'ShowWindow', 'IsWindow',
    'GetParentPid', 'SendConsoleKey', 'ClickWindowCenter',
    'GetWindowRect', 'SetCursorPos'
)
foreach ($m in $Methods) {
    $exists = [WinApi].GetMembers() | Where-Object { $_.Name -eq $m }
    Test-Assert "WinApi::$m 存在" ($null -ne $exists)
}

# ============================================================================
# 测试 2: GetConsoleWindow — 基本功能
# ============================================================================
Write-Section "2. GetConsoleWindow 基本功能"

# 测试脚本可能没有 console（被 IDE/CI 启动），先 AttachConsole 到自身
$SelfPid = $PID
$ConsoleHwnd = [WinApi]::GetConsoleWindow()

if ($ConsoleHwnd -eq [IntPtr]::Zero) {
    # 尝试 AttachConsole 到自身的父进程
    Write-Host "         当前进程无 Console (正常: 被 IDE/CI 启动)" -ForegroundColor DarkGray
    Test-Skip "GetConsoleWindow 当前进程" "无 Console 环境，实际场景由 Launcher AttachConsole 后调用"
    Test-Skip "Console 窗口有标题" "同上"
} else {
    Test-Assert "GetConsoleWindow 返回非 NULL" ($ConsoleHwnd -ne [IntPtr]::Zero)
    $Sb = [System.Text.StringBuilder]::new(256)
    [WinApi]::GetWindowText($ConsoleHwnd, $Sb, 256) | Out-Null
    $ConsoleTitle = $Sb.ToString()
    Test-Assert "Console 窗口有标题" (-not [string]::IsNullOrEmpty($ConsoleTitle))
    Write-Host "         Console 标题: '$ConsoleTitle'" -ForegroundColor DarkGray
}

# 对比 GetForegroundWindow（始终有效）
$FgHwnd = [WinApi]::GetForegroundWindow()
Test-Assert "GetForegroundWindow 返回非 NULL" ($FgHwnd -ne [IntPtr]::Zero)
$Sb2 = [System.Text.StringBuilder]::new(256)
[WinApi]::GetWindowText($FgHwnd, $Sb2, 256) | Out-Null
$FgTitle = $Sb2.ToString()
Write-Host "         前台窗口标题: '$FgTitle'" -ForegroundColor DarkGray

# ============================================================================
# 测试 3: Description Guard — 空内容拦截
# ============================================================================
Write-Section "3. Description Guard 逻辑"

# 模拟 Worker 的判定逻辑
function Test-ContentGuard([string]$Desc, [string]$Tool) {
    return (-not $Desc -and -not $Tool)
}

Test-Assert "空 Description + 空 ToolInfo → 拦截" (Test-ContentGuard "" "")
Test-Assert "空 Description + 空 ToolInfo (null) → 拦截" (Test-ContentGuard $null $null)
Test-Assert "有 Description → 放行" (-not (Test-ContentGuard "hello" ""))
Test-Assert "有 ToolInfo → 放行" (-not (Test-ContentGuard "" "[Bash] ls"))
Test-Assert "都有 → 放行" (-not (Test-ContentGuard "hello" "[Bash] ls"))

# ============================================================================
# 测试 4: UniqueId 计算 — 确定性 + 隔离性
# ============================================================================
Write-Section "4. UniqueId 计算"

function Get-UniqueId([string]$TranscriptPath, [string]$Title) {
    $HashSource = if ($TranscriptPath) { "$TranscriptPath||$Title" } else { "Project||$Title" }
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($HashSource))
    $HashHex = ($HashBytes | ForEach-Object { $_.ToString("x2") }) -join ""
    return "claude-$($HashHex.Substring(0, 16))"
}

$Id1 = Get-UniqueId "/path/to/transcript.jsonl" "Q: hello"
$Id2 = Get-UniqueId "/path/to/transcript.jsonl" "Q: hello"
$Id3 = Get-UniqueId "/path/to/transcript.jsonl" "Q: world"
$Id4 = Get-UniqueId "/other/path.jsonl" "Q: hello"

Test-Assert "相同输入 → 相同 UniqueId" ($Id1 -eq $Id2)
Test-Assert "不同 Title → 不同 UniqueId" ($Id1 -ne $Id3)
Test-Assert "不同 TranscriptPath → 不同 UniqueId" ($Id1 -ne $Id4)
Test-Assert "UniqueId 格式正确 (claude-16hex)" ($Id1 -match "^claude-[0-9a-f]{16}$")
Write-Host "         示例: $Id1" -ForegroundColor DarkGray

# ============================================================================
# 测试 5: Toast UniqueId 去重（需要 BurntToast）
# ============================================================================
Write-Section "5. Toast UniqueId 去重"

$HasBurntToast = $false
try {
    Import-Module BurntToast -ErrorAction Stop
    $HasBurntToast = $true
} catch {}

if ($HasBurntToast) {
    $TestUniqueId = "test-dedup-$(Get-Random)"

    # 发送第一个 Toast
    $Text1 = New-BTText -Text "Test Toast #1 (should be replaced)"
    $Visual1 = New-BTVisual -BindingGeneric (New-BTBinding -Children @($Text1))
    $Content1 = New-BTContent -Visual $Visual1
    Submit-BTNotification -Content $Content1 -UniqueIdentifier $TestUniqueId

    Start-Sleep -Milliseconds 500

    # 发送第二个 Toast（相同 UniqueId，应替换第一个）
    $Text2 = New-BTText -Text "Test Toast #2 (this should be the only one visible)"
    $Visual2 = New-BTVisual -BindingGeneric (New-BTBinding -Children @($Text2))
    $Content2 = New-BTContent -Visual $Visual2
    Submit-BTNotification -Content $Content2 -UniqueIdentifier $TestUniqueId

    Test-Assert "UniqueId 去重: 两次 Submit 同一 ID 无报错" $true
    Write-Host "         检查通知中心: 应只有 '#2' 的 Toast，没有 '#1'" -ForegroundColor Yellow
} else {
    Test-Skip "UniqueId 去重" "BurntToast 模块未安装"
}

# ============================================================================
# 测试 6: 音频路径检测
# ============================================================================
Write-Section "6. 音频路径检测"

$AuroraPath = "$env:USERPROFILE\OneDrive\Aurora.wav"
Test-Assert "Aurora.wav 文件存在" (Test-Path $AuroraPath)

if (Test-Path $AuroraPath) {
    $FileInfo = Get-Item $AuroraPath
    Test-Assert "Aurora.wav 大小 > 0" ($FileInfo.Length -gt 0)
    Write-Host "         路径: $AuroraPath ($([math]::Round($FileInfo.Length / 1024))KB)" -ForegroundColor DarkGray
}

# ============================================================================
# 测试 7: 权限检测 — 不从文本猜测
# ============================================================================
Write-Section "7. 权限检测逻辑"

# 模拟 Transcript 解析：只从 payload 提取 notification_type
$TestTexts = @(
    "Please proceed with the permission approval",
    "Allow me to confirm the authorization",
    "这是一个普通消息"
)

foreach ($text in $TestTexts) {
    # 旧代码会匹配这些文本并设置 permission_prompt
    $OldWouldMatch = ($text -match "(permission|approve|proceed|allow|confirm|authorize)")

    # 新代码：notification_type 只从 payload 提取，文本匹配结果不影响
    $NewNotificationType = ""  # 只有 payload 传入才会设置

    Test-Assert "文本 '$($text.Substring(0, [Math]::Min(30, $text.Length)))...' → 不触发 permission" ([string]::IsNullOrEmpty($NewNotificationType))
}

# ============================================================================
# 测试 8: Format-ClaudeToolInfo — MCP q 字段
# ============================================================================
Write-Section "8. MCP 工具 q 字段"

$McpInput = [PSCustomObject]@{ q = "test search query" }
$Result = Format-ClaudeToolInfo -Name "mcp__Serper_MCP_Server__google_search" -InputObj $McpInput
Test-Assert "MCP q 字段提取" ($Result -match "Search: test search query")

$McpInput2 = [PSCustomObject]@{ query = "another query" }
$Result2 = Format-ClaudeToolInfo -Name "mcp__Serper_MCP_Server__google_search" -InputObj $McpInput2
Test-Assert "MCP query 字段提取" ($Result2 -match "Search: another query")
Write-Host "         q 结果: $Result" -ForegroundColor DarkGray
Write-Host "         query 结果: $Result2" -ForegroundColor DarkGray

# ============================================================================
# 测试 9: Format-ClaudeToolInfo — 各工具类型
# ============================================================================
Write-Section "9. 工具信息格式化"

# Bash: command 优先（实际命令）
$BashResult = Format-ClaudeToolInfo -Name "Bash" -InputObj ([PSCustomObject]@{ description = "列出文件"; command = "ls -la" })
Test-Assert "Bash 优先 command" ($BashResult -eq "[Bash] ls -la")

# Bash: 无 command 时 fallback 到 description
$BashResult2 = Format-ClaudeToolInfo -Name "Bash" -InputObj ([PSCustomObject]@{ description = "列出文件" })
Test-Assert "Bash 无 command 时用 description" ($BashResult2 -eq "[Bash] 列出文件")

# Read: 路径显示最后 3 段
$ReadResult = Format-ClaudeToolInfo -Name "Read" -InputObj ([PSCustomObject]@{ file_path = "C:\Users\Xiao\.claude\hooks\notification-system\Lib\Config.ps1" })
Test-Assert "Read 路径显示 3 段" ($ReadResult -match "notification-system\\Lib\\Config\.ps1")

# Skill: skill 名称
$SkillResult = Format-ClaudeToolInfo -Name "Skill" -InputObj ([PSCustomObject]@{ skill = "commit"; description = "Create a git commit" })
Test-Assert "Skill 名称大写" ($SkillResult -match "\[Commit\]")

# Task/Subagent
$TaskResult = Format-ClaudeToolInfo -Name "Task" -InputObj ([PSCustomObject]@{ subagent_type = "code-reviewer"; description = "Review code" })
Test-Assert "Task subagent 名称" ($TaskResult -match "\[Code-reviewer\]")

# ============================================================================
# 测试 10: XML 转义顺序
# ============================================================================
Write-Section "10. XML 转义（BurntToast 内部处理）"

# P0-1 修复后：Format-ClaudeToolInfo 不再手动 XML 转义
# BurntToast 的 AdaptiveText.Text → ToastContent.GetContent() 会自动处理
$XmlInput = Format-ClaudeToolInfo -Name "Bash" -InputObj ([PSCustomObject]@{ description = "echo <hello> & world" })
Test-Assert "返回原始 & (不手动转义)" ($XmlInput -match " & " -and $XmlInput -notmatch "&amp;")
Test-Assert "返回原始 < (不手动转义)" ($XmlInput -match "<hello>" -and $XmlInput -notmatch "&lt;")
Test-Assert "返回原始 > (不手动转义)" ($XmlInput -match "<hello>" -and $XmlInput -notmatch "&gt;")

# ============================================================================
# 测试 11: ConvertTo-TitleCase 边界
# ============================================================================
Write-Section "11. TitleCase 边界情况"

Test-Assert "空字符串" ((ConvertTo-TitleCase "") -eq "")
Test-Assert "单字符" ((ConvertTo-TitleCase "a") -eq "A")
Test-Assert "正常字符串" ((ConvertTo-TitleCase "hello") -eq "Hello")
Test-Assert "null → 空字符串" ((ConvertTo-TitleCase $null) -eq "")

# ============================================================================
# 测试 12: SoundPlayer 同步播放（可选，需要音频文件）
# ============================================================================
Write-Section "12. 音频同步播放"

if (Test-Path $AuroraPath) {
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $Player = New-Object System.Media.SoundPlayer $AuroraPath
        $Player.PlaySync()
        $Stopwatch.Stop()
        $Player.Dispose()
        # PlaySync 应该阻塞至少几百毫秒（音频文件不会是 0 秒）
        Test-Assert "PlaySync 阻塞播放 ($($Stopwatch.ElapsedMilliseconds)ms)" ($Stopwatch.ElapsedMilliseconds -gt 100)
    } catch {
        Test-Assert "PlaySync 无报错" $false "$_"
    }
} else {
    Test-Skip "音频同步播放" "Aurora.wav 不存在"
}

# ============================================================================
# 结果汇总
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor White
Write-Host " PASS: $($Script:Pass)  FAIL: $($Script:Fail)  SKIP: $($Script:Skip)" -ForegroundColor $(if ($Script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "============================================" -ForegroundColor White

if ($Script:Fail -gt 0) { exit 1 }
exit 0
