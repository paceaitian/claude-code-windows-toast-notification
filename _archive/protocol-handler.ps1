<#
.SYNOPSIS
    claude-runner: 协议处理器 - 处理 Toast 通知点击后的操作

.DESCRIPTION
    解析 claude-runner:focus URI 协议，实现点击通知后聚焦到正确终端窗口。
    支持多窗口环境下的精确 Tab 定位（通过 Beacon 或 Spinner 检测）。

.PARAMETER UriArgs
    URI 参数字符串（如 "hwnd=12345&pid=6789&beacon=uuid&button=1"）

.EXAMPLE
    .\protocol-handler.ps1 "hwnd=12345&pid=6789&beacon=abc123&button=1"
#>

param([string]$UriArgs)

# 导入共享辅助函数
$CommonHelpersPath = Join-Path $PSScriptRoot "common-helpers.ps1"
if (Test-Path $CommonHelpersPath) {
    . $CommonHelpersPath
} else {
    Write-Warning "共享辅助模块未找到: $CommonHelpersPath"
    # 紧急回退：定义必要的类型
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
}

# 调试模式设置
$DebugMode = ($UriArgs -match "debug=1") -or ($env:CLAUDE_HOOK_DEBUG -eq "1")
Set-CHDebugMode -Enabled $DebugMode -LogPath "$env:USERPROFILE\.claude\protocol_debug.log"

Write-CHDebugLog "Handler 触发: $UriArgs"

try {
    # 解析 URI 参数
    $ProjectName = $null
    $TargetHwnd = 0
    $TargetPid = 0
    $BeaconTitle = $null
    $ButtonNumber = $null
    $TabIndex = -1

    if ($UriArgs -match "project=([^&]+)") {
        $ProjectName = [Uri]::UnescapeDataString($Matches[1])
        Write-CHDebugLog "项目名: $ProjectName"
    }
    if ($UriArgs -match "hwnd=(\d+)") {
        $TargetHwnd = [int]$Matches[1]
    }
    if ($UriArgs -match "pid=(\d+)") {
        $TargetPid = [int]$Matches[1]
        Write-CHDebugLog "目标 PID: $TargetPid"
    }
    if ($UriArgs -match "beacon=([^&]+)") {
        $BeaconTitle = [Uri]::UnescapeDataString($Matches[1])
    }
    if ($UriArgs -match "button=(\d+)") {
        $ButtonNumber = [int]$Matches[1]
        Write-CHDebugLog "按钮点击: $ButtonNumber"
    }
    if ($UriArgs -match "tabindex=(-?\d+)") {
        $TabIndex = [int]$Matches[1]
        Write-CHDebugLog "TabIndex: $TabIndex"
    }

    # Tab 定位策略（优先级：项目名 > PID > Beacon > TabIndex > Spinner）
    $FocusedTab = $null

    # 策略 1: 通过项目名查找 Tab（最简单可靠）
    if ($ProjectName) {
        Write-CHDebugLog "尝试通过项目名查找: $ProjectName"
        $ProjectResult = Find-TabByProjectName -ProjectName $ProjectName
        if ($ProjectResult) {
            Write-CHDebugLog "项目名查找成功: '$($ProjectResult.Tab.Current.Name)'"
            if (Select-Tab -Tab $ProjectResult.Tab) {
                $TargetHwnd = $ProjectResult.Hwnd
                $FocusedTab = $ProjectResult.Tab
            }
        }
    }

    # 策略 2: 通过 PID 定位（回退）
    if (-not $FocusedTab -and $TargetPid -gt 0) {
        Write-CHDebugLog "尝试 PID 定位: $TargetPid"
        $PidResult = Find-TabByPid -ProcessId $TargetPid
        if ($PidResult) {
            Write-CHDebugLog "PID 定位成功: HWND=$($PidResult.Hwnd), Tab=$($PidResult.Tab.Current.Name)"
            if (Select-Tab -Tab $PidResult.Tab) {
                $TargetHwnd = $PidResult.Hwnd
                $FocusedTab = $PidResult.Tab
            }
        }
    }

    # 策略 3: Beacon 搜索（回退）
    if (-not $FocusedTab -and -not [string]::IsNullOrWhiteSpace($BeaconTitle)) {
        Write-CHDebugLog "尝试 Beacon 搜索: $BeaconTitle"
        $BeaconResult = Find-TabByBeacon -BeaconTitle $BeaconTitle
        if ($BeaconResult) {
            Write-CHDebugLog "Beacon 搜索成功"
            if (Select-Tab -Tab $BeaconResult.Tab) {
                $TargetHwnd = $BeaconResult.Hwnd
                $FocusedTab = $BeaconResult.Tab
            }
        }
    }

    # 策略 4: TabIndex 定位（配合 HWND 使用）
    if (-not $FocusedTab -and $TabIndex -ge 0 -and $TargetHwnd -gt 0) {
        Write-CHDebugLog "使用 TabIndex 定位: $TabIndex (HWND: $TargetHwnd)"
        $IndexResult = Find-TabByIndex -Hwnd $TargetHwnd -Index $TabIndex
        if ($IndexResult) {
            Write-CHDebugLog "TabIndex 定位成功"
            if (Select-Tab -Tab $IndexResult.Tab) {
                $FocusedTab = $IndexResult.Tab
            }
        }
    }

    # 策略 5: Claude Spinner 搜索（最后回退）
    if (-not $FocusedTab) {
        Write-CHDebugLog "尝试 Claude Spinner 搜索..."
        $ClaudeTabResult = Find-ClaudeTabBySpinner -TargetPid $TargetPid
        if ($ClaudeTabResult) {
            Write-CHDebugLog "找到 Claude Tab: '$($ClaudeTabResult.Tab.Current.Name)'"
            if (Select-Tab -Tab $ClaudeTabResult.Tab) {
                $TargetHwnd = $ClaudeTabResult.Hwnd
                $FocusedTab = $ClaudeTabResult.Tab
                Write-CHDebugLog "Spinner 搜索成功"
            }
        }
    }

    # 聚焦窗口
    if ($TargetHwnd -gt 0) {
        Write-CHDebugLog "聚焦 HWND: $TargetHwnd"
        $IntPtr = [IntPtr]$TargetHwnd
        Set-ForegroundWindowForce -Hwnd $IntPtr

        # 使用鼠标点击设置键盘焦点（解决 Windows Terminal 问题）
        if ($FocusedTab) {
            Start-Sleep -Milliseconds 100
            Invoke-ElementClick -Element $FocusedTab

            # 发送按钮编号
            if ($ButtonNumber) {
                Start-Sleep -Milliseconds 100
                Send-KeyPress -Key $ButtonNumber
            }
        }
    } else {
        Write-CHDebugLog "无效的 HWND: $TargetHwnd"
    }
} catch {
    Write-CHDebugLog "错误: $_"
}
