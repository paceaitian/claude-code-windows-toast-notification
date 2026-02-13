# 端到端流程模拟测试
# 不启动真实 Worker 进程，不发送 Toast，纯逻辑验证

$ScriptDir = Split-Path $MyInvocation.MyCommand.Path
. "$ScriptDir\Lib\Config.ps1"

# ============================================================
# 手动定义被测函数（避免 dot-source 的作用域问题）
# ============================================================

function Test-IsDefaultTitle([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $true }
    $ClaudePatterns = @(
        '^[*·✻.\s\u2800-\u28FF]*Claude Code$',
        '^claude\s+-\s*.+$',
        '^[\u2800-\u28FF]'
    )
    $ShellPatterns = @(
        '^PowerShell$', '^Windows PowerShell$', '^pwsh$',
        '^cmd$', '^Command Prompt$',
        '^Administrator:\s*(PowerShell|Windows PowerShell|pwsh|cmd|Command Prompt)$',
        '\\cmd\.exe', '\\powershell\.exe', '\\pwsh\.exe'
    )
    foreach ($p in ($ClaudePatterns + $ShellPatterns)) {
        if ($Title -match $p) { return $true }
    }
    return $false
}

# ============================================================
# 测试框架
# ============================================================
$Global:Passed = 0; $Global:Failed = 0; $Global:Total = 0

function Assert-Equal($Actual, $Expected, $Desc) {
    $Global:Total++
    if ($Actual -eq $Expected) {
        Write-Host "[PASS] $Desc" -ForegroundColor Green
        $Global:Passed++
    } else {
        Write-Host "[FAIL] $Desc | got=$Actual expected=$Expected" -ForegroundColor Red
        $Global:Failed++
    }
}

# ============================================================
# 1. Test-IsDefaultTitle
# ============================================================
Write-Host "`n=== 1. Test-IsDefaultTitle ===" -ForegroundColor Cyan

# 默认值 → $true
Assert-Equal (Test-IsDefaultTitle '') $true '空字符串'
Assert-Equal (Test-IsDefaultTitle 'Claude Code') $true 'Claude Code'
Assert-Equal (Test-IsDefaultTitle '* Claude Code') $true '* Claude Code (待机)'
Assert-Equal (Test-IsDefaultTitle "`u{00b7} Claude Code") $true '· Claude Code (thinking)'
Assert-Equal (Test-IsDefaultTitle "`u{273b} Claude Code") $true '✻ Claude Code (thinking2)'
Assert-Equal (Test-IsDefaultTitle '. Claude Code') $true '. Claude Code (运行)'
Assert-Equal (Test-IsDefaultTitle "`u{2810} 多智能体审查") $true 'Braille前缀+对话名'
Assert-Equal (Test-IsDefaultTitle "`u{2801} some topic") $true 'Braille前缀+英文话题'
Assert-Equal (Test-IsDefaultTitle 'claude - hooks') $true 'claude - 目录格式'
Assert-Equal (Test-IsDefaultTitle 'PowerShell') $true 'PowerShell'
Assert-Equal (Test-IsDefaultTitle 'Windows PowerShell') $true 'Windows PowerShell'
Assert-Equal (Test-IsDefaultTitle 'pwsh') $true 'pwsh'
Assert-Equal (Test-IsDefaultTitle 'cmd') $true 'cmd'
Assert-Equal (Test-IsDefaultTitle 'Command Prompt') $true 'Command Prompt'
Assert-Equal (Test-IsDefaultTitle 'Administrator: PowerShell') $true 'Admin PowerShell'
Assert-Equal (Test-IsDefaultTitle 'C:\WINDOWS\system32\cmd.exe') $true 'cmd.exe 完整路径'
Assert-Equal (Test-IsDefaultTitle 'C:\Program Files\PowerShell\7\pwsh.exe') $true 'pwsh.exe 完整路径'

# 非默认值 → $false
Assert-Equal (Test-IsDefaultTitle 'hooks-ui') $false '用户自定义 hooks-ui'
Assert-Equal (Test-IsDefaultTitle 'my-project') $false '用户自定义 my-project'
Assert-Equal (Test-IsDefaultTitle 'Claude-Backend') $false '用户自定义 Claude-Backend'
Assert-Equal (Test-IsDefaultTitle 'hooks') $false '项目名 hooks'
Assert-Equal (Test-IsDefaultTitle 'notification-system') $false '项目名 notification-system'

# ============================================================
# 2. Launcher 输入解析模拟
# ============================================================
Write-Host "`n=== 2. Launcher 输入解析 ===" -ForegroundColor Cyan

# 模拟 JSON Payload 解析
$json1 = '{"project_name":"my-app","title":"test","message":"hello"}' | ConvertFrom-Json
Assert-Equal $json1.project_name 'my-app' 'JSON: project_name 提取'
Assert-Equal $json1.message 'hello' 'JSON: message 提取'

# 模拟项目名优先级
function Get-ProjectName($Payload) {
    $ProjectName = "Claude"
    if ($Payload.project_name) { $ProjectName = $Payload.project_name }
    elseif ($Payload.title) { $ProjectName = $Payload.title }
    elseif ($Payload.projectPath) { $ProjectName = Split-Path $Payload.projectPath -Leaf }
    elseif ($Payload.project_dir) { $ProjectName = Split-Path $Payload.project_dir -Leaf }
    return $ProjectName
}

$p1 = @{ project_name = 'explicit-name'; title = 'fallback' }
Assert-Equal (Get-ProjectName $p1) 'explicit-name' '优先级: project_name > title'

$p2 = @{ title = 'from-title' }
Assert-Equal (Get-ProjectName $p2) 'from-title' '优先级: title (无 project_name)'

$p3 = @{ projectPath = 'C:\Users\Xiao\projects\my-app' }
Assert-Equal (Get-ProjectName $p3) 'my-app' '优先级: projectPath leaf'

$p4 = @{}
Assert-Equal (Get-ProjectName $p4) 'Claude' '优先级: 默认值 Claude'

# ============================================================
# 3. Launcher 标题读取逻辑模拟
# ============================================================
Write-Host "`n=== 3. 标题读取逻辑 ===" -ForegroundColor Cyan

function Simulate-TitleLogic($CurrentTitle, $ProjectName) {
    if (Test-IsDefaultTitle $CurrentTitle) {
        return @{ Action = 'fallback'; ActualTitle = $ProjectName }
    } else {
        return @{ Action = 'use-existing'; ActualTitle = $CurrentTitle }
    }
}

$r1 = Simulate-TitleLogic 'PowerShell' 'hooks'
Assert-Equal $r1.Action 'fallback' '默认标题 → fallback'
Assert-Equal $r1.ActualTitle 'hooks' 'fallback 使用项目名'

$r2 = Simulate-TitleLogic "`u{2810} 多智能体审查" 'hooks'
Assert-Equal $r2.Action 'fallback' 'Braille对话标题 → fallback (Braille是Claude Code动画前缀，属于默认标题)'
Assert-Equal $r2.ActualTitle 'hooks' 'Braille标题fallback为项目名'

$r3 = Simulate-TitleLogic 'hooks-ui' 'hooks'
Assert-Equal $r3.Action 'use-existing' '用户自定义 → use-existing'
Assert-Equal $r3.ActualTitle 'hooks-ui' '保留用户自定义标题'

$r4 = Simulate-TitleLogic 'C:\WINDOWS\system32\cmd.exe ' 'hooks'
Assert-Equal $r4.Action 'fallback' 'cmd.exe路径 → fallback'

# ============================================================
# 4. Worker 焦点检测模拟
# ============================================================
Write-Host "`n=== 4. 焦点检测逻辑 ===" -ForegroundColor Cyan

function Simulate-FocusCheck($ForegroundTitle, $TitleForCheck) {
    return $ForegroundTitle -like "*$TitleForCheck*"
}

Assert-Equal (Simulate-FocusCheck "`u{2810} 多智能体审查" '多智能体审查') $true '焦点匹配: Braille标题包含关键词'
Assert-Equal (Simulate-FocusCheck 'hooks' 'hooks') $true '焦点匹配: 完全匹配'
Assert-Equal (Simulate-FocusCheck 'Visual Studio Code' 'hooks') $false '焦点不匹配: 不同窗口'
Assert-Equal (Simulate-FocusCheck '' 'hooks') $false '焦点不匹配: 空标题'

# 模拟 Delay 循环中的焦点检测
function Simulate-FocusWatch($Delay, $FocusAtSecond, $TitleForCheck) {
    # FocusAtSecond: 第几秒用户聚焦（-1 = 始终未聚焦）
    for ($i = 0; $i -lt $Delay; $i++) {
        if ($i -eq $FocusAtSecond) { return @{ Exited = $true; AtSecond = $i + 1 } }
    }
    # 最终检查
    if ($FocusAtSecond -eq $Delay) { return @{ Exited = $true; AtSecond = 'final' } }
    return @{ Exited = $false; AtSecond = -1 }
}

$fw1 = Simulate-FocusWatch -Delay 5 -FocusAtSecond 2 -TitleForCheck 'hooks'
Assert-Equal $fw1.Exited $true 'FocusWatch: 第3秒聚焦 → 退出'
Assert-Equal $fw1.AtSecond 3 'FocusWatch: 在T=3退出'

$fw2 = Simulate-FocusWatch -Delay 5 -FocusAtSecond -1 -TitleForCheck 'hooks'
Assert-Equal $fw2.Exited $false 'FocusWatch: 始终未聚焦 → 发送通知'

$fw3 = Simulate-FocusWatch -Delay 0 -FocusAtSecond -1 -TitleForCheck 'hooks'
Assert-Equal $fw3.Exited $false 'FocusWatch: Delay=0 → 直接发送'

# ============================================================
# 5. Toast URI 构建模拟
# ============================================================
Write-Host "`n=== 5. Toast URI 构建 ===" -ForegroundColor Cyan

function Simulate-ToastUri($WindowTitle, $TargetPid, $NotificationType) {
    $Uri = "claude-runner:focus?windowtitle=$([Uri]::EscapeDataString($WindowTitle))"
    if ($TargetPid -gt 0) { $Uri += "&pid=$TargetPid" }
    if ($NotificationType) { $Uri += "&notification_type=$NotificationType" }
    return $Uri
}

$uri1 = Simulate-ToastUri "`u{2810} 多智能体审查" 12345 ''
Assert-Equal ($uri1 -like '*windowtitle=*') $true 'URI 包含 windowtitle'
Assert-Equal ($uri1 -like '*pid=12345*') $true 'URI 包含 PID'

$uri2 = Simulate-ToastUri 'hooks' 0 'permission_prompt'
Assert-Equal ($uri2 -like '*notification_type=permission_prompt*') $true 'URI 包含 notification_type'
Assert-Equal ($uri2 -notlike '*pid=*') $true 'URI 无 PID (PID=0)'

# ============================================================
# 6. ProtocolHandler 参数解析模拟
# ============================================================
Write-Host "`n=== 6. ProtocolHandler 参数解析 ===" -ForegroundColor Cyan

function Simulate-ParseUri($UriArgs) {
    $Result = @{ Hwnd = 0; Pid = 0; WindowTitle = $null; Action = $null }
    if ($UriArgs -match 'hwnd=(\d+)') { $Result.Hwnd = [int]$Matches[1] }
    if ($UriArgs -match 'pid=(\d+)') { $Result.Pid = [int]$Matches[1] }
    if ($UriArgs -match 'windowtitle=([^&]+)') { $Result.WindowTitle = [Uri]::UnescapeDataString($Matches[1]) }
    if ($UriArgs -match 'action=(\w+)') { $Result.Action = $Matches[1] }
    return $Result
}

$parsed1 = Simulate-ParseUri 'claude-runner:focus?windowtitle=hooks&pid=12345'
Assert-Equal $parsed1.WindowTitle 'hooks' 'URI解析: windowtitle'
Assert-Equal $parsed1.Pid 12345 'URI解析: pid'

$parsed2 = Simulate-ParseUri 'claude-runner:focus?windowtitle=%E2%A0%90%20%E5%A4%9A%E6%99%BA%E8%83%BD%E4%BD%93&action=approve&pid=999'
Assert-Equal $parsed2.Action 'approve' 'URI解析: action'
Assert-Equal $parsed2.Pid 999 'URI解析: pid (approve)'
Assert-Equal ($parsed2.WindowTitle -like '*多智能体*') $true 'URI解析: 中文标题解码'

# ============================================================
# 7. 完整流程模拟
# ============================================================
Write-Host "`n=== 7. 完整流程模拟 ===" -ForegroundColor Cyan

function Simulate-FullFlow($CurrentWindowTitle, $ProjectName, $Delay, $UserFocusAtSecond) {
    # Step 1: Launcher 读取标题
    $titleResult = Simulate-TitleLogic $CurrentWindowTitle $ProjectName
    $actualTitle = $titleResult.ActualTitle

    # Step 2: Worker 焦点检测
    $focusResult = Simulate-FocusWatch -Delay $Delay -FocusAtSecond $UserFocusAtSecond -TitleForCheck $actualTitle

    # Step 3: 决定是否发送通知
    return @{
        ActualTitle = $actualTitle
        TitleAction = $titleResult.Action
        ShouldNotify = -not $focusResult.Exited
        FocusExitAt = $focusResult.AtSecond
    }
}

# 场景 A: Claude Code Braille标题（默认标题），用户未聚焦 → fallback到项目名，发送通知
$flowA = Simulate-FullFlow "`u{2810} 代码审查" 'hooks' 10 -1
Assert-Equal $flowA.TitleAction 'fallback' '流程A: Braille标题 → fallback为项目名'
Assert-Equal $flowA.ShouldNotify $true '流程A: 用户未聚焦 → 发送通知'

# 场景 B: 默认标题，用户第5秒聚焦 → 不发送通知
$flowB = Simulate-FullFlow 'PowerShell' 'hooks' 10 4
Assert-Equal $flowB.TitleAction 'fallback' '流程B: fallback 为项目名'
Assert-Equal $flowB.ActualTitle 'hooks' '流程B: ActualTitle = hooks'
Assert-Equal $flowB.ShouldNotify $false '流程B: 用户聚焦 → 不发送'

# 场景 C: 权限提示，Delay=0 → 立即发送
$flowC = Simulate-FullFlow "`u{2810} 权限请求" 'hooks' 0 -1
Assert-Equal $flowC.ShouldNotify $true '流程C: Delay=0 → 立即发送'

# 场景 D: 用户自定义标题 → 保留
$flowD = Simulate-FullFlow 'hooks-backend' 'hooks' 20 -1
Assert-Equal $flowD.TitleAction 'use-existing' '流程D: 保留用户自定义标题'
Assert-Equal $flowD.ActualTitle 'hooks-backend' '流程D: ActualTitle = hooks-backend'

# ============================================================
# 结果总结
# ============================================================
Write-Host "`n========================================" -ForegroundColor White
$color = if ($Global:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "Results: $($Global:Passed)/$($Global:Total) passed, $($Global:Failed) failed" -ForegroundColor $color
Write-Host "========================================`n" -ForegroundColor White

if ($Global:Failed -gt 0) { exit 1 }
