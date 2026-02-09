<#
.SYNOPSIS
    公共辅助函数模块 - 用于 Windows 通知和协议处理器脚本

.DESCRIPTION
    提供 WinApi 定义、UI Automation helpers、调试日志等共享功能
#>

# --- WinApi P/Invoke Definitions ---
# 定义一次，多处复用
if (-not ([System.Management.Automation.PSTypeName]'WinApi').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinApi {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
"@
}

# --- MouseApi Definitions ---
if (-not ([System.Management.Automation.PSTypeName]'MouseApi').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseApi {
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint cButtons, uint dwExtraInfo);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    public const uint MOUSEEVENTF_LEFTDOWN = 0x02;
    public const uint MOUSEEVENTF_LEFTUP = 0x04;
}
"@
}

# --- UI Automation Setup ---
# 确保 UIA 程序集已加载
Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue

# --- Script-level Variables (可被覆盖) ---
$script:CH_DebugMode = $false
$script:CH_DebugLog = "$env:USERPROFILE\.claude\hooks_debug.log"

<#
.SYNOPSIS
    设置调试模式
#>
function Set-CHDebugMode {
    param([bool]$Enabled, [string]$LogPath)
    $script:CH_DebugMode = $Enabled
    if ($LogPath) {
        $script:CH_DebugLog = $LogPath
    }
}

<#
.SYNOPSIS
    写入调试日志
#>
function Write-CHDebugLog {
    param([string]$Message)
    if ($script:CH_DebugMode) {
        "[$((Get-Date).ToString('HH:mm:ss'))] $Message" | Out-File $script:CH_DebugLog -Append -Encoding UTF8
    }
}

<#
.SYNOPSIS
    获取所有 Windows Terminal 窗口

.OUTPUTS
    System.Windows.Automation.AutomationElement[]
#>
function Get-AllTerminalWindows {
    $propCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty,
        "CASCADIA_HOSTING_WINDOW_CLASS"
    )
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    return $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $propCondition)
}

<#
.SYNOPSIS
    获取终端窗口中的所有 Tab

.PARAMETER Terminal
    终端窗口元素

.OUTPUTS
    System.Windows.Automation.AutomationElement[]
#>
function Get-TerminalTabs {
    param($Terminal)
    return $Terminal.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem
        )
    )
}

<#
.SYNOPSIS
    选中指定的 Tab

.PARAMETER Tab
    Tab 元素

.OUTPUTS
    bool - 是否成功选中
#>
function Select-Tab {
    param($Tab)
    $selPattern = $null
    if ($Tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selPattern)) {
        $selPattern.Select()
        return $true
    }
    return $false
}

<#
.SYNOPSIS
    获取当前选中的 Tab 索引

.PARAMETER Terminal
    终端窗口元素

.OUTPUTS
    int - Tab 索引，未找到返回 -1
#>
function Get-SelectedTabIndex {
    param($Terminal)
    $Tabs = Get-TerminalTabs $Terminal
    for ($i = 0; $i -lt $Tabs.Count; $i++) {
        $selPattern = $null
        if ($Tabs[$i].TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selPattern)) {
            if ($selPattern.Current.IsSelected) {
                return $i
            }
        }
    }
    return -1
}

<#
.SYNOPSIS
    检查指定 Tab 是否包含 Claude 相关内容

.PARAMETER TabName
    Tab 名称

.OUTPUTS
    bool - 是否匹配 Claude Spinner 或名称
#>
function Test-ClaudeTab {
    param([string]$TabName)
    # Claude Code 运行时显示 spinner: ⠐⠈⠁⠂⠄⠠ 或包含 "Claude"
    return $TabName -match "⠐|⠈|⠁|⠂|⠄|⠠|Claude|claude"
}

<#
.SYNOPSIS
    通过 HWND 获取终端窗口

.PARAMETER Hwnd
    窗口句柄

.OUTPUTS
    AutomationElement 或 null
#>
function Get-TerminalByHwnd {
    param([IntPtr]$Hwnd)
    $terminals = Get-AllTerminalWindows
    foreach ($terminal in $terminals) {
        if ($terminal.Current.NativeWindowHandle -eq [int]$Hwnd) {
            return $terminal
        }
    }
    return $null
}

<#
.SYNOPSIS
    通过 Beacon 标题查找 Tab

.PARAMETER BeaconTitle
    Beacon 标题

.OUTPUTS
    PSCustomObject - 包含 Terminal, Tab, Index
#>
function Find-TabByIndex {
    param(
        [int]$Hwnd,
        [int]$Index
    )

    $terminal = Get-TerminalByHwnd -Hwnd $Hwnd
    if (-not $terminal) {
        return $null
    }

    $Tabs = Get-TerminalTabs $terminal
    if ($Index -ge 0 -and $Index -lt $Tabs.Count) {
        return [PSCustomObject]@{
            Terminal = $terminal
            Tab = $Tabs[$Index]
            Index = $Index
            Hwnd = [int]$terminal.Current.NativeWindowHandle
        }
    }

    return $null
}

<#
.SYNOPSIS
    通过 PID 查找对应的 Tab（最可靠的方法，优化版）

.DESCRIPTION
    通过遍历所有 Windows Terminal 窗口，检查哪个窗口包含目标 PID 的进程。
    支持直接匹配和父进程链匹配。

.PARAMETER Pid
    目标 PID（通常是 Tab Shell PID 或 Windows Terminal PID）

.OUTPUTS
    PSCustomObject - 包含 Terminal, Tab, Index, Hwnd
#>
function Find-TabByPid {
    param([int]$ProcessId)

    Write-CHDebugLog "Find-TabByPid: 开始查找 PID $ProcessId"

    try {
        # 获取目标进程对象
        $TargetProc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $TargetProc) {
            Write-CHDebugLog "Find-TabByPid: 进程 $ProcessId 不存在"
            return $null
        }

        # 获取所有 Windows Terminal 窗口
        $terminals = Get-AllTerminalWindows

        # 预先获取所有终端的子进程映射（只查询一次）
        $terminalChildPids = @{}
        foreach ($terminal in $terminals) {
            $terminalHwnd = [int]$terminal.Current.NativeWindowHandle
            $terminalPid = 0
            $null = [WinApi]::GetWindowThreadProcessId([IntPtr]$terminalHwnd, [ref]$terminalPid)
            if ($terminalPid -gt 0) {
                $terminalChildPids[$terminalPid] = @{
                    Hwnd = $terminalHwnd
                    Terminal = $terminal
                    ChildPids = Get-ChildProcessIds -ParentId $terminalPid
                }
            }
        }

        # 验证策略
        foreach ($tpid in $terminalChildPids.Keys) {
            $info = $terminalChildPids[$tpid]

            # 策略 1: 直接匹配
            if ($ProcessId -eq $tpid) {
                Write-CHDebugLog "Find-TabByPid: PID 直接匹配 Windows Terminal (PID=$tpid, HWND=$($info.Hwnd))"
                $selectedIndex = Get-SelectedTabIndex -Terminal $info.Terminal
                if ($selectedIndex -ge 0) {
                    $Tabs = Get-TerminalTabs $info.Terminal
                    return [PSCustomObject]@{
                        Terminal = $info.Terminal
                        Tab = $Tabs[$selectedIndex]
                        Index = $selectedIndex
                        Hwnd = $info.Hwnd
                    }
                }
            }

            # 策略 2: 子进程匹配
            if ($ProcessId -in $info.ChildPids) {
                Write-CHDebugLog "Find-TabByPid: PID $ProcessId 是 Windows Terminal (PID=$tpid) 的子进程"
                $selectedIndex = Get-SelectedTabIndex -Terminal $info.Terminal
                if ($selectedIndex -ge 0) {
                    $Tabs = Get-TerminalTabs $info.Terminal
                    return [PSCustomObject]@{
                        Terminal = $info.Terminal
                        Tab = $Tabs[$selectedIndex]
                        Index = $selectedIndex
                        Hwnd = $info.Hwnd
                    }
                }
            }
        }

        # 策略 3: 父进程链匹配（遍历目标进程的父进程链）
        $currentPid = $ProcessId
        $maxDepth = 10
        for ($i = 0; $i -lt $maxDepth; $i++) {
            $parentPid = Get-ParentPid $currentPid
            if ($parentPid -le 0) { break }

            if ($terminalChildPids.ContainsKey($parentPid)) {
                $info = $terminalChildPids[$parentPid]
                Write-CHDebugLog "Find-TabByPid: PID $ProcessId 的父进程链包含 Windows Terminal (PID=$parentPid)"
                $selectedIndex = Get-SelectedTabIndex -Terminal $info.Terminal
                if ($selectedIndex -ge 0) {
                    $Tabs = Get-TerminalTabs $info.Terminal
                    return [PSCustomObject]@{
                        Terminal = $info.Terminal
                        Tab = $Tabs[$selectedIndex]
                        Index = $selectedIndex
                        Hwnd = $info.Hwnd
                    }
                }
            }
            $currentPid = $parentPid
        }

        Write-CHDebugLog "Find-TabByPid: 未找到 PID $ProcessId 对应的 Tab"
    } catch {
        Write-CHDebugLog "Find-TabByPid 错误: $_"
    }

    return $null
}

# 进程树缓存（脚本级变量）
$script:CH_ProcessTreeCache = $null
$script:CH_ProcessTreeCacheTime = 0

<#
.SYNOPSIS
    获取进程的所有子进程 ID（优化版，使用缓存）

.DESCRIPTION
    递归获取指定进程的所有子进程 ID，使用缓存避免重复查询

.PARAMETER ParentId
    父进程 ID

.PARAMETER RefreshCache
    强制刷新缓存

.OUTPUTS
    int[] - 子进程 ID 数组
#>
function Get-ChildProcessIds {
    param(
        [int]$ParentId,
        [switch]$RefreshCache
    )

    $childIds = @()

    try {
        # 检查缓存是否过期（5 秒过期）
        $now = [DateTime]::TickCount
        if ($RefreshCache -or $null -eq $script:CH_ProcessTreeCache -or ($now - $script:CH_ProcessTreeCacheTime) -gt 5000) {
            Write-CHDebugLog "Get-ChildProcessIds: 刷新进程树缓存"
            $allProcesses = Get-CimInstance Win32_Process
            $script:CH_ProcessTreeCache = $allProcesses
            $script:CH_ProcessTreeCacheTime = $now
        }

        # 从缓存获取进程
        $allProcesses = $script:CH_ProcessTreeCache

        # 构建子进程映射（一次性构建）
        $childMap = @{}
        foreach ($proc in $allProcesses) {
            $ppid = [int]$proc.ParentProcessId
            if ($ppid -gt 0) {
                if (-not $childMap.ContainsKey($ppid)) {
                    $childMap[$ppid] = @()
                }
                $childMap[$ppid] += [int]$proc.ProcessId
            }
        }

        # 递归获取子进程（使用栈避免递归深度限制）
        $stack = [System.Collections.Generic.Stack[int]]::new()
        $stack.Push($ParentId)

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()

            if ($childMap.ContainsKey($current)) {
                foreach ($childId in $childMap[$current]) {
                    $childIds += $childId
                    $stack.Push($childId)
                }
            }
        }
    } catch {
        Write-CHDebugLog "Get-ChildProcessIds 错误: $_"
    }

    return $childIds
}

<#
.SYNOPSIS
    通过 Beacon 标题查找 Tab

.DESCRIPTION
    搜索包含 Beacon ID 的 Tab。支持精确匹配和部分匹配（Beacon 可能被截断）。

.PARAMETER BeaconTitle
    Beacon 标题（格式：原始标题 (BeaconId)）

.OUTPUTS
    PSCustomObject - 包含 Terminal, Tab, Index, Hwnd
#>
function Find-TabByBeacon {
    param([string]$BeaconTitle)

    Write-CHDebugLog "Find-TabByBeacon: 搜索 Beacon '$BeaconTitle'"

    # 提取 Beacon ID（格式：原始标题 (BeaconId)）
    $beaconId = $null
    if ($BeaconTitle -match '\(([a-f0-9]{8})\)') {
        $beaconId = $Matches[1]
        Write-CHDebugLog "Find-TabByBeacon: 提取 Beacon ID: $beaconId"
    }

    $terminals = Get-AllTerminalWindows
    foreach ($terminal in $terminals) {
        $Tabs = Get-TerminalTabs $terminal
        for ($i = 0; $i -lt $Tabs.Count; $i++) {
            $tabName = $Tabs[$i].Current.Name

            # 策略 1: 精确匹配
            if ($tabName -eq $BeaconTitle) {
                Write-CHDebugLog "Find-TabByBeacon: 精确匹配 Tab: '$tabName'"
                return [PSCustomObject]@{
                    Terminal = $terminal
                    Tab = $Tabs[$i]
                    Index = $i
                    Hwnd = [int]$terminal.Current.NativeWindowHandle
                }
            }

            # 策略 2: 部分 Beacon ID 匹配（如果 Beacon 被截断）
            if ($beaconId -and $tabName -match "\([a-f0-9]{$($beaconId.Length - 2),$($beaconId.Length + 2)}\)") {
                # 检查提取的 ID 是否匹配
                if ($tabName -match $beaconId.Substring(0, 6)) {
                    Write-CHDebugLog "Find-TabByBeacon: 部分匹配 Tab: '$tabName'"
                    return [PSCustomObject]@{
                        Terminal = $terminal
                        Tab = $Tabs[$i]
                        Index = $i
                        Hwnd = [int]$terminal.Current.NativeWindowHandle
                    }
                }
            }
        }
    }

    Write-CHDebugLog "Find-TabByBeacon: 未找到匹配的 Tab"
    return $null
}

<#
.SYNOPSIS
    通过 Tab 标记查找 Tab

.DESCRIPTION
    搜索包含指定标记的 Tab。这是最可靠的 Tab 定位方法。

.PARAMETER TabMarker
    Tab 标记（8 字符的 GUID 片段）

.OUTPUTS
    PSCustomObject - 包含 Terminal, Tab, Index, Hwnd
#>
function Find-TabByMarker {
    param([string]$TabMarker)

    Write-CHDebugLog "Find-TabByMarker: 搜索标记 [$TabMarker]"

    if ([string]::IsNullOrWhiteSpace($TabMarker)) {
        return $null
    }

    $terminals = Get-AllTerminalWindows
    foreach ($terminal in $terminals) {
        $Tabs = Get-TerminalTabs $terminal
        for ($i = 0; $i -lt $Tabs.Count; $i++) {
            $tabName = $Tabs[$i].Current.Name

            # 检查 Tab 名称是否包含标记
            if ($tabName -match "\[$TabMarker\]") {
                Write-CHDebugLog "Find-TabByMarker: 找到匹配 Tab: '$tabName'"
                return [PSCustomObject]@{
                    Terminal = $terminal
                    Tab = $Tabs[$i]
                    Index = $i
                    Hwnd = [int]$terminal.Current.NativeWindowHandle
                }
            }
        }
    }

    Write-CHDebugLog "Find-TabByMarker: 未找到包含标记 [$TabMarker] 的 Tab"
    return $null
}

<#
.SYNOPSIS
    通过项目名查找 Tab

.DESCRIPTION
    查找 Tab 名称完全匹配项目名的 Tab。

.PARAMETER ProjectName
    项目名称

.OUTPUTS
    PSCustomObject - 包含 Terminal, Tab, Index, Hwnd
#>
function Find-TabByProjectName {
    param([string]$ProjectName)

    Write-CHDebugLog "Find-TabByProjectName: 搜索项目名 '$ProjectName'"

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        return $null
    }

    $terminals = Get-AllTerminalWindows
    foreach ($terminal in $terminals) {
        $Tabs = Get-TerminalTabs $terminal
        for ($i = 0; $i -lt $Tabs.Count; $i++) {
            $tabName = $Tabs[$i].Current.Name

            # 完全匹配 Tab 名称
            if ($tabName -eq $ProjectName) {
                Write-CHDebugLog "Find-TabByProjectName: 找到匹配 Tab: '$tabName'"
                return [PSCustomObject]@{
                    Terminal = $terminal
                    Tab = $Tabs[$i]
                    Index = $i
                    Hwnd = [int]$terminal.Current.NativeWindowHandle
                }
            }
        }
    }

    Write-CHDebugLog "Find-TabByProjectName: 未找到项目名 '$ProjectName' 的 Tab"
    return $null
}

<#
.SYNOPSIS
    查找 Claude 活动的 Tab（通过 Spinner 检测）

.DESCRIPTION
    查找包含 Claude Spinner 或 "Claude" 字样的 Tab。
    可选验证 PID，确保找到的是包含目标进程的窗口。

.PARAMETER TargetPid
    可选的目标 PID，用于验证窗口是否包含该进程

.OUTPUTS
    PSCustomObject - 包含 Terminal, Tab, Index, Hwnd
#>
function Find-ClaudeTabBySpinner {
    param([int]$TargetPid = 0)

    Write-CHDebugLog "Find-ClaudeTabBySpinner: 开始查找 (TargetPid: $TargetPid)"

    $matchedTabs = @()
    $terminals = Get-AllTerminalWindows

    # 如果需要验证 PID，预先获取所有子进程映射（只查询一次）
    $allChildPids = @{}
    if ($TargetPid -gt 0) {
        foreach ($terminal in $terminals) {
            $terminalHwnd = [int]$terminal.Current.NativeWindowHandle
            $terminalPid = 0
            $null = [WinApi]::GetWindowThreadProcessId([IntPtr]$terminalHwnd, [ref]$terminalPid)
            if ($terminalPid -gt 0) {
                $allChildPids[$terminalPid] = Get-ChildProcessIds -ParentId $terminalPid
            }
        }
    }

    # 第一轮：收集所有包含 Claude Spinner 的 Tab
    foreach ($terminal in $terminals) {
        $Tabs = Get-TerminalTabs $terminal
        for ($i = 0; $i -lt $Tabs.Count; $i++) {
            $TabName = $Tabs[$i].Current.Name
            if (Test-ClaudeTab -TabName $TabName) {
                $matchedTabs += [PSCustomObject]@{
                    Terminal = $terminal
                    Tab = $Tabs[$i]
                    Index = $i
                    Hwnd = [int]$terminal.Current.NativeWindowHandle
                    TabName = $TabName
                }
                Write-CHDebugLog "Find-ClaudeTabBySpinner: 找到匹配 Tab: '$TabName' (HWND: $($terminal.Current.NativeWindowHandle))"
            }
        }
    }

    if ($matchedTabs.Count -eq 0) {
        Write-CHDebugLog "Find-ClaudeTabBySpinner: 未找到任何 Claude Tab"
        return $null
    }

    # 如果只有一个匹配，直接返回
    if ($matchedTabs.Count -eq 1) {
        Write-CHDebugLog "Find-ClaudeTabBySpinner: 找到唯一匹配 Tab"
        return $matchedTabs[0]
    }

    # 如果有多个匹配且有 TargetPid，验证哪个窗口包含目标进程
    if ($TargetPid -gt 0) {
        Write-CHDebugLog "Find-ClaudeTabBySpinner: 多个匹配，验证 TargetPid $TargetPid"
        foreach ($match in $matchedTabs) {
            $terminalHwnd = [int]$match.Terminal.Current.NativeWindowHandle
            $terminalPid = 0
            $null = [WinApi]::GetWindowThreadProcessId([IntPtr]$terminalHwnd, [ref]$terminalPid)

            if ($terminalPid -gt 0 -and $allChildPids.ContainsKey($terminalPid)) {
                $childPids = $allChildPids[$terminalPid]

                # 策略 1: 直接匹配（目标进程就是终端进程）
                if ($TargetPid -eq $terminalPid) {
                    Write-CHDebugLog "Find-ClaudeTabBySpinner: PID 直接匹配，选择此 Tab"
                    return $match
                }

                # 策略 2: 子进程匹配
                if ($TargetPid -in $childPids) {
                    Write-CHDebugLog "Find-ClaudeTabBySpinner: PID 在子进程树中，选择此 Tab"
                    return $match
                }

                # 策略 3: 父进程链匹配
                $currentPid = $TargetPid
                $maxDepth = 10
                for ($i = 0; $i -lt $maxDepth; $i++) {
                    $parentPid = Get-ParentPid $currentPid
                    if ($parentPid -le 0) { break }

                    if ($parentPid -eq $terminalPid) {
                        Write-CHDebugLog "Find-ClaudeTabBySpinner: PID 父进程链匹配，选择此 Tab"
                        return $match
                    }
                    $currentPid = $parentPid
                }
            }
        }

        # 如果 PID 验证失败，使用第一个匹配（回退）
        Write-CHDebugLog "Find-ClaudeTabBySpinner: PID 验证失败，使用第一个匹配"
    }

    return $matchedTabs[0]
}

<#
.SYNOPSIS
    修复编码问题（处理 UTF-8/GBK 混合）

.PARAMETER str
    输入字符串

.OUTPUTS
    修复后的字符串
#>
function Repair-Encoding {
    param([string]$str)
    if ([string]::IsNullOrEmpty($str)) { return $str }
    try {
        $bytes = [System.Text.Encoding]::Default.GetBytes($str)
        return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    } catch {
        return $str
    }
}

<#
.SYNOPSIS
    获取进程的父进程 ID

.PARAMETER ProcessId
    进程 ID

.OUTPUTS
    父进程 ID，失败返回 0
#>
function Get-ParentPid {
    param([int]$ProcessId)
    try {
        return (Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId").ParentProcessId
    } catch {
        return 0
    }
}

<#
.SYNOPSIS
    从子进程向上查找宿主进程（如 WindowsTerminal）

.PARAMETER ProcessId
    起始进程 ID

.PARAMETER MaxDepth
    最大向上遍历层数

.OUTPUTS
    宿主进程对象，未找到返回 null
#>
function Find-HostProcess {
    param(
        [int]$ProcessId,
        [int]$MaxDepth = 6
    )
    $Next = $ProcessId
    for ($i = 0; $i -lt $MaxDepth; $i++) {
        try {
            $P = Get-Process -Id $Next -ErrorAction Stop
            # 检查是否为宿主进程
            if ($P.MainWindowHandle -ne 0 -and ($P.ProcessName -match "^(WindowsTerminal|Code|devenv|idea64)$")) {
                return $P
            }
            $Next = Get-ParentPid $Next
            if ($Next -le 0) { break }
        } catch {
            break
        }
    }
    return $null
}

<#
.SYNOPSIS
    获取宿主窗口句柄

.PARAMETER ProcessId
    进程 ID

.OUTPUTS
    窗口句柄，失败返回 0
#>
function Get-HostHwnd {
    param([int]$ProcessId)
    $HostProc = Find-HostProcess -ProcessId $ProcessId
    if ($HostProc) {
        return $HostProc.MainWindowHandle
    }
    # 回退：返回 shell 自己的窗口
    try {
        return (Get-Process -Id $ProcessId).MainWindowHandle
    } catch {
        return 0
    }
}

<#
.SYNOPSIS
    检查前台窗口是否是 Claude 终端

.DESCRIPTION
    检查前台窗口是否是 Claude Code 终端。
    可选验证是否是特定的目标窗口（用于多窗口场景）。

.PARAMETER TargetHwnd
    可选的目标窗口 HWND。如果提供，将验证前台窗口是否是这个特定窗口。

.PARAMETER TargetPid
    可选的目标进程 PID。如果 TargetHwnd 为 0，将使用此 PID 来验证窗口。

.PARAMETER TabMarker
    可选的 Tab 标记。如果提供，将检查当前激活的 Tab 名称是否包含此标记。

.PARAMETER ProjectName
    可选的项目名称。如果提供，将检查当前激活的 Tab 名称是否是此项目名。

.OUTPUTS
    bool - 如果前台是 Claude Tab 返回 true
#>
function Test-ClaudeTabFocused {
    param(
        [IntPtr]$TargetHwnd = [IntPtr]::Zero,
        [int]$TargetPid = 0,
        [string]$TabMarker = "",
        [string]$ProjectName = ""
    )

    try {
        $CurrentFgHwnd = [WinApi]::GetForegroundWindow()
        if ($CurrentFgHwnd -eq [IntPtr]::Zero) { return $false }

        # 确保 Hwnd 是 IntPtr 类型
        if ($CurrentFgHwnd -isnot [IntPtr]) {
            Write-CHDebugLog "前台检测: Hwnd 类型异常: $($CurrentFgHwnd.GetType())"
            return $false
        }

        # 优先级 1: 使用项目名验证（最简单可靠）
        if ($ProjectName) {
            $FgPid = 0
            $null = [WinApi]::GetWindowThreadProcessId($CurrentFgHwnd, [ref]$FgPid)
            if ($FgPid -le 0) { return $false }

            $FgProc = Get-Process -Id $FgPid -ErrorAction SilentlyContinue
            if ($FgProc -and $FgProc.ProcessName -eq "WindowsTerminal") {
                $terminal = Get-TerminalByHwnd -Hwnd $CurrentFgHwnd
                if ($terminal) {
                    $selectedIndex = Get-SelectedTabIndex -Terminal $terminal
                    if ($selectedIndex -ge 0) {
                        $Tabs = Get-TerminalTabs $terminal
                        $TabName = $Tabs[$selectedIndex].Current.Name
                        # 检查 Tab 名称是否是项目名（完全匹配）
                        $isMatch = ($TabName -eq $ProjectName)
                        Write-CHDebugLog "前台检测: Tab='$TabName', 项目名='$ProjectName', 匹配=$isMatch"
                        return $isMatch
                    }
                }
            }
            return $false
        }

        # 优先级 2: 使用 Tab 标记验证
        if ($TabMarker) {
            $FgPid = 0
            $null = [WinApi]::GetWindowThreadProcessId($CurrentFgHwnd, [ref]$FgPid)
            if ($FgPid -le 0) { return $false }

            $FgProc = Get-Process -Id $FgPid -ErrorAction SilentlyContinue
            if ($FgProc -and $FgProc.ProcessName -eq "WindowsTerminal") {
                $terminal = Get-TerminalByHwnd -Hwnd $CurrentFgHwnd
                if ($terminal) {
                    $selectedIndex = Get-SelectedTabIndex -Terminal $terminal
                    if ($selectedIndex -ge 0) {
                        $Tabs = Get-TerminalTabs $terminal
                        $TabName = $Tabs[$selectedIndex].Current.Name
                        $hasMarker = $TabName -match "\[$TabMarker\]"
                        Write-CHDebugLog "前台检测: Tab='$TabName', 标记=[$TabMarker], 匹配=$hasMarker"
                        return $hasMarker
                    }
                }
            }
            return $false
        }

        # 回退：使用 HWND 验证
        if ($TargetHwnd -ne [IntPtr]::Zero) {
            $isSameWindow = ($CurrentFgHwnd -eq $TargetHwnd)
            Write-CHDebugLog "前台检测: 比较窗口 (前台: $CurrentFgHwnd, 目标: $TargetHwnd, 匹配: $isSameWindow)"
            if (-not $isSameWindow) {
                return $false
            }
        } elseif ($TargetPid -gt 0) {
            # 回退：使用进程关系验证
            $fgPid = 0
            $null = [WinApi]::GetWindowThreadProcessId($CurrentFgHwnd, [ref]$fgPid)
            if ($fgPid -le 0) { return $false }

            $currentPid = $TargetPid
            $maxDepth = 10
            $isRelatedProcess = $false

            for ($i = 0; $i -lt $maxDepth; $i++) {
                $parentPid = Get-ParentPid $currentPid
                if ($parentPid -le 0) { break }
                if ($parentPid -eq $fgPid) {
                    $isRelatedProcess = $true
                    break
                }
                $currentPid = $parentPid
            }

            if (-not $isRelatedProcess) {
                $childPids = Get-ChildProcessIds -ParentId $fgPid
                if ($TargetPid -in $childPids) {
                    $isRelatedProcess = $true
                }
            }

            if (-not $isRelatedProcess) {
                Write-CHDebugLog "前台检测: 前台窗口 (PID: $fgPid) 与目标进程 (PID: $TargetPid) 无关联"
                return $false
            }
        }

        # 最终检查：确认是 Windows Terminal 中的 Claude Tab
        $FgPid = 0
        $null = [WinApi]::GetWindowThreadProcessId($CurrentFgHwnd, [ref]$FgPid)
        if ($FgPid -le 0) { return $false }

        $FgProc = Get-Process -Id $FgPid -ErrorAction SilentlyContinue
        Write-CHDebugLog "前台进程: $($FgProc.ProcessName) (PID: $FgPid, HWND: $CurrentFgHwnd)"

        if ($FgProc -and $FgProc.ProcessName -eq "WindowsTerminal") {
            $terminal = Get-TerminalByHwnd -Hwnd $CurrentFgHwnd
            if ($terminal) {
                $selectedIndex = Get-SelectedTabIndex -Terminal $terminal
                if ($selectedIndex -ge 0) {
                    $Tabs = Get-TerminalTabs $terminal
                    $TabName = $Tabs[$selectedIndex].Current.Name
                    Write-CHDebugLog "选中 Tab: $TabName"
                    return Test-ClaudeTab -TabName $TabName
                }
            }
        }
    } catch {
        Write-CHDebugLog "前台检测错误: $_"
    }
    return $false
}

<#
.SYNOPSIS
    强制聚焦窗口（使用多种方法）

.PARAMETER Hwnd
    目标窗口句柄
#>
function Set-ForegroundWindowForce {
    param([IntPtr]$Hwnd)
    # 1. 如果最小化则还原
    if ([WinApi]::IsIconic($Hwnd)) {
        [WinApi]::ShowWindow($Hwnd, 9)  # SW_RESTORE
    }

    # 2. 使用 AttachThreadInput 强制聚焦
    $TargetThreadId = 0
    [WinApi]::GetWindowThreadProcessId($Hwnd, [ref]$TargetThreadId)
    $MyThreadId = [WinApi]::GetCurrentThreadId()

    if ($TargetThreadId -gt 0 -and $MyThreadId -ne $TargetThreadId) {
        [WinApi]::AttachThreadInput($MyThreadId, $TargetThreadId, $true)
        [WinApi]::SetForegroundWindow($Hwnd)
        [WinApi]::SwitchToThisWindow($Hwnd, $true)
        [WinApi]::AttachThreadInput($MyThreadId, $TargetThreadId, $false)
    } else {
        [WinApi]::SetForegroundWindow($Hwnd)
        [WinApi]::SwitchToThisWindow($Hwnd, $true)
    }
}

<#
.SYNOPSIS
    模拟鼠标点击（用于设置键盘焦点）

.PARAMETER Element
    UI Automation 元素
#>
function Invoke-ElementClick {
    param($Element)
    try {
        $bounds = $Element.Current.BoundingRectangle
        $clickX = [int]($bounds.Left + $bounds.Width / 2)
        $clickY = [int]($bounds.Top + $bounds.Height / 2)

        Write-CHDebugLog "点击位置: X=$clickX, Y=$clickY"

        [MouseApi]::SetCursorPos($clickX, $clickY)
        Start-Sleep -Milliseconds 20

        [MouseApi]::mouse_event([MouseApi]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
        Start-Sleep -Milliseconds 20
        [MouseApi]::mouse_event([MouseApi]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)

        Write-CHDebugLog "鼠标点击完成"
    } catch {
        Write-CHDebugLog "鼠标点击错误: $_"
    }
}

<#
.SYNOPSIS
    发送按键到前台窗口

.PARAMETER Key
    要发送的按键字符串
#>
function Send-KeyPress {
    param([string]$Key)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.SendKeys]::SendWait($Key)
        Write-CHDebugLog "按键已发送: $Key"
    } catch {
        Write-CHDebugLog "发送按键错误: $_"
    }
}

<#
.SYNOPSIS
    清理文本中的 Markdown 格式

.PARAMETER Text
    输入文本

.PARAMETER MaxLength
    最大长度，超出则截断

.OUTPUTS
    清理后的文本
#>
function Remove-MarkdownFormat {
    param(
        [string]$Text,
        [int]$MaxLength = 800
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    $CleanText = $Text -replace '#{1,6}\s*', '' `
                       -replace '\*{1,2}([^*]+)\*{1,2}', '$1' `
                       -replace '```[a-z]*\r?\n?', '' `
                       -replace '`([^`]+)`', '$1' `
                       -replace '\[([^\]]+)\]\([^)]+\)', '$1' `
                       -replace '^\s*[-*]\s+', '' `
                       -replace '\r?\n', ' '
    $CleanText = $CleanText.Trim()

    if ($CleanText.Length -gt $MaxLength) {
        $CleanText = $CleanText.Substring(0, $MaxLength - 3) + "..."
    }
    return $CleanText
}

<#
.SYNOPSIS
    清理 XML 特殊字符

.PARAMETER Text
    输入文本

.OUTPUTS
    转义后的文本
#>
function Escape-XmlText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return $Text -replace '>', '&gt;' -replace '<', '&lt;' -replace '"', '&quot;'
}
