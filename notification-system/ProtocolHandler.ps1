# ProtocolHandler.ps1 - URI 协议处理器
# 响应 claude-runner:// 协议，激活窗口并处理按钮动作

param(
    [string]$UriArgs,
    [switch]$EnableDebug
)

# 0. Load Libs
$Dir = Split-Path $MyInvocation.MyCommand.Path
. "$Dir\Lib\Common.ps1"
. "$Dir\Lib\Native.ps1"

Write-DebugLog "PROTOCOL: Triggered with '$UriArgs'"

try {
    # 1. Parse Arguments
    $HwndArg = 0
    if ($UriArgs -match "hwnd=(\d+)") {
        try { $HwndArg = [IntPtr]::new([long]$Matches[1]) } catch {}
    }

    $PidArg = 0
    if ($UriArgs -match "pid=(\d+)") {
        try { $PidArg = [int]$Matches[1] } catch {}
    }

    $WindowTitle = $null
    if ($UriArgs -match "windowtitle=([^&]+)") {
        $WindowTitle = [Uri]::UnescapeDataString($Matches[1])
    }

    # 2. Activation Logic
    $Success = $false

    # Strategy A: HWND (Direct)
    if ($HwndArg -ne 0) {
        Write-DebugLog "PROTOCOL: Target HWND $HwndArg"
        # 验证 HWND 有效性
        if ([WinApi]::IsWindow($HwndArg)) {
            if ([WinApi]::IsIconic($HwndArg)) {
                [WinApi]::ShowWindow($HwndArg, 9) # SW_RESTORE
            }
            $Success = [WinApi]::SetForegroundWindow($HwndArg)
            Write-DebugLog "PROTOCOL: SetForegroundWindow(HWND) -> $Success"
        } else {
            Write-DebugLog "PROTOCOL: HWND $HwndArg is no longer valid"
        }
    }

    # Strategy B: PID (Process) - 先拉起 WT 窗口，再用 UI Automation 切换 tab
    elseif ($PidArg -ne 0) {
        Write-DebugLog "PROTOCOL: Target PID $PidArg"

        # B1: 沿进程树向上找到 WindowsTerminal 进程 ID
        $WtPid = 0
        $ClimbPid = $PidArg
        for ($i = 0; $i -lt 10; $i++) {
            $p = Get-Process -Id $ClimbPid -ErrorAction SilentlyContinue
            if (-not $p) { break }
            if ($p.ProcessName -eq 'WindowsTerminal') {
                $WtPid = $ClimbPid
                Write-DebugLog "PROTOCOL: Found WT process PID $WtPid"
                break
            }
            $ParentPid = [WinApi]::GetParentPid($ClimbPid)
            if ($ParentPid -eq 0 -or $ParentPid -eq $ClimbPid) { break }
            $ClimbPid = $ParentPid
        }

        # B2: UI Automation 搜索 WT 窗口切换 tab
        # Launcher 已在重复时附加 #PID 后缀确保标题唯一，直接用 WindowTitle 搜索
        $TabSwitchedByUIA = $false
        if (-not [string]::IsNullOrWhiteSpace($WindowTitle)) {
            # B2a: 标题重注入（Watchdog 退出后 OSC 覆盖，恢复自定义标题）
            if ($PidArg -gt 0) {
                try {
                    [WinApi]::FreeConsole() | Out-Null
                    if ([WinApi]::AttachConsole([uint32]$PidArg)) {
                        [Console]::Title = $WindowTitle
                        $Osc = "$([char]27)]0;$WindowTitle$([char]7)"
                        [Console]::Write($Osc)
                        [Console]::Out.Flush()
                        Write-DebugLog "PROTOCOL: Re-injected title '$WindowTitle' into PID $PidArg"
                    } else {
                        Write-DebugLog "PROTOCOL: AttachConsole($PidArg) failed for title re-injection"
                    }
                } catch {
                    Write-DebugLog "PROTOCOL: Title re-injection error: $_"
                } finally {
                    [WinApi]::FreeConsole() | Out-Null
                }
                Start-Sleep -Milliseconds 200
            }

            # B2b: 搜索 WT 进程的所有窗口，找到包含目标 tab 的窗口并切换
            try {
                Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
                $desktopRoot = [System.Windows.Automation.AutomationElement]::RootElement

                # 找到 WT 进程拥有的所有顶层窗口
                $pidCondition = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $WtPid)
                $wtWindows = $desktopRoot.FindAll(
                    [System.Windows.Automation.TreeScope]::Children, $pidCondition)
                Write-DebugLog "PROTOCOL: UIA found $($wtWindows.Count) WT window(s) for PID $WtPid"

                $targetTab = $null
                $targetWindow = $null
                $tabTypeCondition = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::TabItem)

                foreach ($wt in $wtWindows) {
                    $tabs = $wt.FindAll(
                        [System.Windows.Automation.TreeScope]::Descendants, $tabTypeCondition)
                    foreach ($t in $tabs) {
                        if ($t.Current.Name -like "*$WindowTitle*") {
                            $targetTab = $t
                            $targetWindow = $wt
                            break
                        }
                    }
                    if ($targetTab) { break }
                }

                if ($targetTab) {
                    # 先激活正确的 WT 窗口
                    $correctHwnd = [IntPtr]::new($targetWindow.Current.NativeWindowHandle)
                    if ([WinApi]::IsIconic($correctHwnd)) { [WinApi]::ShowWindow($correctHwnd, 9) }
                    [WinApi]::SetForegroundWindow($correctHwnd) | Out-Null
                    Write-DebugLog "PROTOCOL: Activated correct WT window (HWND $correctHwnd)"
                    Start-Sleep -Milliseconds 50

                    # 切换 tab
                    $selPattern = $targetTab.GetCurrentPattern(
                        [System.Windows.Automation.SelectionItemPattern]::Pattern)
                    $selPattern.Select()
                    $TabSwitchedByUIA = $true
                    $Success = $true
                    Write-DebugLog "PROTOCOL: UIA Selected tab '$($targetTab.Current.Name)'"

                    # 点击终端内容区激活输入焦点（UIA Select 后焦点留在 tab 栏）
                    Start-Sleep -Milliseconds 100
                    [WinApi]::ClickWindowCenter($correctHwnd)
                    Write-DebugLog "PROTOCOL: Clicked window center to focus terminal pane"
                } else {
                    Write-DebugLog "PROTOCOL: UIA tab '$WindowTitle' not found in any WT window"
                }
            } catch {
                Write-DebugLog "PROTOCOL: UIA failed: $_"
            }
        }

        # B3: 降级 — UIA 失败时用 PID 拉起窗口
        if (-not $Success -and $WtPid -ne 0) {
            $wtProc = Get-Process -Id $WtPid -ErrorAction SilentlyContinue
            if ($wtProc -and $wtProc.MainWindowHandle -ne [IntPtr]::Zero) {
                $h = $wtProc.MainWindowHandle
                if ([WinApi]::IsIconic($h)) { [WinApi]::ShowWindow($h, 9) }
                $Success = [WinApi]::SetForegroundWindow($h)
                Write-DebugLog "PROTOCOL: Fallback SetForegroundWindow(WT) -> $Success"
            }
            if (-not $Success) {
                $wshell = New-Object -ComObject WScript.Shell
                if ($wshell.AppActivate($PidArg)) {
                    $Success = $true
                    Write-DebugLog "PROTOCOL: Fallback AppActivate(PID) Success."
                }
            }
        }
    }

    # Strategy C: Window Title (Search)
    elseif (-not [string]::IsNullOrWhiteSpace($WindowTitle)) {
        Write-DebugLog "PROTOCOL: Searching Title '$WindowTitle'"

        # C1: Get-Process.MainWindowTitle（仅能匹配当前活跃 tab）
        $Proc = Get-Process | Where-Object { $_.MainWindowTitle -eq $WindowTitle -and $_.ProcessName -ne "explorer" } | Select-Object -First 1
        if (-not $Proc) {
            $Proc = Get-Process | Where-Object { $_.MainWindowTitle -like "*$WindowTitle*" -and $_.ProcessName -ne "explorer" } | Select-Object -First 1
        }

        if ($Proc) {
            Write-DebugLog "PROTOCOL: C1 Found $($Proc.ProcessName) ($($Proc.Id))"
            $Handle = $Proc.MainWindowHandle

            if ([WinApi]::IsIconic($Handle)) {
                [WinApi]::ShowWindow($Handle, 9)
            }
            $Success = [WinApi]::SetForegroundWindow($Handle)
            if (-not $Success) {
                $wshell = New-Object -ComObject WScript.Shell
                $wshell.AppActivate($Proc.Id)
            }
        }

        # C2: UIA tab 搜索（Get-Process 只看活跃 tab，非活跃 tab 需要 UIA）
        if (-not $Success) {
            Write-DebugLog "PROTOCOL: C1 failed, trying C2 UIA tab search..."
            try {
                Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
                $desktopRoot = [System.Windows.Automation.AutomationElement]::RootElement
                $tabTypeCondition = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::TabItem)

                $allWtProcs = Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue
                foreach ($wtp in $allWtProcs) {
                    $pidCond = New-Object System.Windows.Automation.PropertyCondition(
                        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $wtp.Id)
                    $wtWins = $desktopRoot.FindAll(
                        [System.Windows.Automation.TreeScope]::Children, $pidCond)

                    foreach ($w in $wtWins) {
                        $tabs = $w.FindAll(
                            [System.Windows.Automation.TreeScope]::Descendants, $tabTypeCondition)
                        foreach ($t in $tabs) {
                            if ($t.Current.Name -like "*$WindowTitle*") {
                                # 激活窗口
                                $wtHwnd = [IntPtr]::new($w.Current.NativeWindowHandle)
                                if ([WinApi]::IsIconic($wtHwnd)) { [WinApi]::ShowWindow($wtHwnd, 9) }
                                [WinApi]::SetForegroundWindow($wtHwnd) | Out-Null
                                Start-Sleep -Milliseconds 50

                                # 切换 tab
                                $selPat = $t.GetCurrentPattern(
                                    [System.Windows.Automation.SelectionItemPattern]::Pattern)
                                $selPat.Select()
                                $TabSwitchedByUIA = $true
                                $Success = $true
                                Write-DebugLog "PROTOCOL: C2 UIA Selected tab '$($t.Current.Name)' in WT PID $($wtp.Id)"

                                # 点击终端内容区激活输入焦点
                                Start-Sleep -Milliseconds 100
                                [WinApi]::ClickWindowCenter($wtHwnd)
                                break
                            }
                        }
                        if ($Success) { break }
                    }
                    if ($Success) { break }
                }
                if (-not $Success) {
                    Write-DebugLog "PROTOCOL: C2 UIA tab '$WindowTitle' not found in any WT"
                }
            } catch {
                Write-DebugLog "PROTOCOL: C2 UIA failed: $_"
            }
        }
    }

    # 3. Action Logic (Button Click)
    if ($UriArgs -match "action=approve") {
        Write-DebugLog "PROTOCOL: Action 'Approve' detected."

        $SendKeysDelay = $Script:CONFIG_SENDKEYS_DELAY_MS
        if (-not $SendKeysDelay) { $SendKeysDelay = 250 }
        Start-Sleep -Milliseconds $SendKeysDelay

        if ($TabSwitchedByUIA -and $PidArg -gt 0) {
            # UIA 已精确切换到目标 tab，用 WriteConsoleInput 直接写入控制台（绕过窗口焦点）
            $Sent = [WinApi]::SendConsoleKey([uint32]$PidArg, [char]'1')
            Write-DebugLog "PROTOCOL: Tab switched by UIA. SendConsoleKey(PID $PidArg) -> $Sent"
            if (-not $Sent) {
                # 降级：用 SendKeys（需要窗口焦点正确）
                Write-DebugLog "PROTOCOL: Fallback to SendKeys..."
                $wshell = New-Object -ComObject WScript.Shell
                $wshell.SendKeys("1")
            }
        } elseif ($WindowTitle) {
            $Hwnd = [WinApi]::GetForegroundWindow()
            $Sb = [System.Text.StringBuilder]::new(256)
            [WinApi]::GetWindowText($Hwnd, $Sb, 256) | Out-Null
            $CurrentTitle = $Sb.ToString()

            if ($CurrentTitle -like "*$WindowTitle*") {
                # 发送前再次验证（减少竞态条件窗口）
                Start-Sleep -Milliseconds 50
                $Hwnd2 = [WinApi]::GetForegroundWindow()
                $Sb2 = [System.Text.StringBuilder]::new(256)
                [WinApi]::GetWindowText($Hwnd2, $Sb2, 256) | Out-Null
                $CurrentTitle2 = $Sb2.ToString()

                if ($CurrentTitle2 -like "*$WindowTitle*") {
                    Write-DebugLog "PROTOCOL: Window verified (double-check). Sending '1'..."
                    $wshell = New-Object -ComObject WScript.Shell
                    $wshell.SendKeys("1")
                } else {
                    Write-DebugLog "PROTOCOL: Window changed during verification. Expected '$WindowTitle', got '$CurrentTitle2'. Aborting."
                }
            } else {
                Write-DebugLog "PROTOCOL: Window mismatch. Expected '$WindowTitle', got '$CurrentTitle'. Aborting SendKeys."
            }
        } else {
            # 安全措施：无 WindowTitle 时禁止发送按键，防止误操作
            Write-DebugLog "PROTOCOL: No WindowTitle provided. Aborting SendKeys for security."
        }
    }

} catch {
    Write-DebugLog "PROTOCOL ERROR: $_"
}
