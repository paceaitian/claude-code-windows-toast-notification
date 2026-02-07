
param([string]$UriArgs)

# Logging
$LogPath = "$env:USERPROFILE\.claude\protocol_debug.log"
"[" + (Get-Date).ToString() + "] Handler Triggered: $UriArgs" | Out-File $LogPath -Append -Encoding UTF8

# UIA Assemblies
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# NEW: 添加 SendKeys 支持
Add-Type -AssemblyName System.Windows.Forms

# Parse URI: claude-runner:focus?hwnd=12345&pid=6789&beacon=uuid
try {
    $TargetHwnd = 0
    $BeaconTitle = $null

    if ($UriArgs -match "hwnd=(\d+)") { $TargetHwnd = [int]$Matches[1] }
    if ($UriArgs -match "beacon=([^&]+)") { 
        $BeaconTitle = [Uri]::UnescapeDataString($Matches[1]) 
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class FocusApi {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
"@
    
    
    # --- UIA Search Logic ---
    $UiaSuccess = $false
    $FocusedTab = $null  # NEW: 保存需要聚焦的 Tab
    
    # 0. Priority: Claude Spinner Search (Multi-Window Fix)
    # Search ALL WT windows for Tab with Claude's spinner "⠐" in name.
    # This always finds the correct Tab regardless of which window is focused.
    "Attempting Claude Spinner Search across all WT windows..." | Out-File $LogPath -Append
    try {
        $propCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty,
            "CASCADIA_HOSTING_WINDOW_CLASS" 
        )
        $desktop = [System.Windows.Automation.AutomationElement]::RootElement
        $terminals = $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $propCondition)
        
        foreach ($terminal in $terminals) {
            $Tabs = $terminal.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::TabItem
                )
            )
            
            for ($i = 0; $i -lt $Tabs.Count; $i++) {
                $TabName = $Tabs[$i].Current.Name
                # Claude Code shows spinner "⠐" or "⠈" or similar braille patterns when running
                if ($TabName -match "⠐|⠈|⠁|⠂|⠄|⠠|⠐|Claude") {
                    "Found Claude Tab: '$TabName' at index $i in HWND $($terminal.Current.NativeWindowHandle)" | Out-File $LogPath -Append
                    
                    $selPattern = $null
                    if ($Tabs[$i].TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selPattern)) {
                        $selPattern.Select()
                        $UiaSuccess = $true
                        $TargetHwnd = [int]$terminal.Current.NativeWindowHandle
                        $FocusedTab = $Tabs[$i]  # 保存 Tab 引用，稍后设置焦点
                    }
                    break
                }
            }
            if ($UiaSuccess) { break }
        }
    } catch {
        "Claude Spinner Search Error: $_" | Out-File $LogPath -Append
    }
    
    # 1. Fallback: Try Beacon (High Precision - for delayed clicks where index might be stale)
    if (-not $UiaSuccess -and -not [string]::IsNullOrWhiteSpace($BeaconTitle)) {
        "Attempting UIA Focus for Beacon: $BeaconTitle" | Out-File $LogPath -Append
        try {
            $propCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ClassNameProperty,
                "CASCADIA_HOSTING_WINDOW_CLASS" 
            )
            $desktop = [System.Windows.Automation.AutomationElement]::RootElement
            $terminals = $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $propCondition)
            
            foreach ($terminal in $terminals) {
                $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty,
                    $BeaconTitle
                )
                $targetTab = $terminal.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)

                if ($targetTab) {
                    "UIA: Found Tab via Beacon! Selecting..." | Out-File $LogPath -Append
                    $selectionPattern = $null
                    if ($targetTab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selectionPattern)) {
                        $selectionPattern.Select()
                        $UiaSuccess = $true
                        $FocusedTab = $targetTab  # 保存 Tab 引用，稍后设置焦点
                    }
                    $TargetHwnd = [int]$terminal.Current.NativeWindowHandle
                    break
                }
            }
        } catch {
            "UIA Beacon Error: $_" | Out-File $LogPath -Append
        }
    }

    if (-not $UiaSuccess -and $UriArgs -match "hwnd=(\d+)") {
        try {
             $StartPid = 0
             if ($UriArgs -match "pid=(\d+)") { $StartPid = [int]$Matches[1] }
             
             if ($StartPid -gt 0) {
                 "Attempting Heuristic Index for PID: $StartPid" | Out-File $LogPath -Append
                 
                 # 1. Walk UP to find the actual Tab shell (parent is WindowsTerminal)
                 $TabShellPid = $null
                 $Current = $StartPid
                 $WalkLog = "$Current"
                 
                 for ($w = 0; $w -lt 10; $w++) {
                     $Proc = Get-CimInstance Win32_Process -Filter "ProcessId=$Current"
                     if (-not $Proc) { break }
                     
                     $Parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($Proc.ParentProcessId)"
                     if (-not $Parent) { break }
                     
                     $WalkLog += " -> $($Proc.ParentProcessId)($($Parent.Name))"
                     
                     # If parent is WindowsTerminal, we found the Tab shell
                     if ($Parent.Name -match "^WindowsTerminal(\.exe)?$") {
                         $TabShellPid = $Current
                         break
                     }
                     
                     $Current = $Proc.ParentProcessId
                 }
                 
                 "Process Walk: $WalkLog" | Out-File $LogPath -Append
                 
                 if ($TabShellPid) {
                     "Found Tab Shell PID: $TabShellPid" | Out-File $LogPath -Append
                     
                     # 2. Get WindowsTerminal PID
                     $WtPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$TabShellPid").ParentProcessId
                     
                     # 3. Get all sibling shells (children of WindowsTerminal)
                     $Siblings = Get-CimInstance Win32_Process -Filter "ParentProcessId=$WtPid" | 
                        Where-Object { $_.Name -match "^(pwsh|powershell|cmd|wsl|bash)(\.exe)?$" } |
                        Sort-Object CreationDate
                     
                     $Index = -1
                     for($i=0; $i -lt $Siblings.Count; $i++) {
                         if ($Siblings[$i].ProcessId -eq $TabShellPid) { $Index = $i; break }
                     }
                     
                     "Calculated Tab Index: $Index (of $($Siblings.Count) siblings)" | Out-File $LogPath -Append
                     
                     # UIA Find Tabs in the target Window
                     # We reuse the previously found HWND logic or search again for the HWND
                     $TargetTerminal = $null
                     $terminals = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, 
                        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, "CASCADIA_HOSTING_WINDOW_CLASS"))

                     foreach ($t in $terminals) {
                         if ($t.Current.NativeWindowHandle -eq $TargetHwnd) { $TargetTerminal = $t; break }
                     }

                     if ($TargetTerminal) {
                         $Tabs = $TargetTerminal.FindAll([System.Windows.Automation.TreeScope]::Descendants, 
                            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem))
                         
                         "Found $($Tabs.Count) Tabs in Target Window:" | Out-File $LogPath -Append
                         for ($t=0; $t -lt $Tabs.Count; $t++) {
                            "  [$t] $($Tabs[$t].Current.Name)" | Out-File $LogPath -Append
                         }

                         if ($Index -lt $Tabs.Count) {
                            "Selecting Tab at Index $Index ($($Tabs[$Index].Current.Name))..." | Out-File $LogPath -Append
                            $TargetTab = $Tabs[$Index]
                            $selectionPattern = $null
                            if ($TargetTab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selectionPattern)) {
                                $selectionPattern.Select()
                                $UiaSuccess = $true
                                $FocusedTab = $TargetTab  # 保存 Tab 引用，稍后设置焦点
                            }
                         }
                     }
                 }
             }
        } catch {
             "UIA Heuristic Error: $_" | Out-File $LogPath -Append
        }
    }

    if ($TargetHwnd -gt 0) {
        "Focusing HWND: $TargetHwnd" | Out-File $LogPath -Append
        
        $IntPtr = [IntPtr]$TargetHwnd
        
        # 1. Restore if Minimized
        if ([FocusApi]::IsIconic($IntPtr)) {
            [FocusApi]::ShowWindow($IntPtr, 9) # SW_RESTORE
        }

        # 3. Nuclear Focus (AttachThreadInput)
        $TargetThreadId = 0
        [FocusApi]::GetWindowThreadProcessId($IntPtr, [ref]$TargetThreadId)
        $MyThreadId = [FocusApi]::GetCurrentThreadId()

        if ($TargetThreadId -gt 0 -and $MyThreadId -ne $TargetThreadId) {
             [FocusApi]::AttachThreadInput($MyThreadId, $TargetThreadId, $true)
             [FocusApi]::SetForegroundWindow($IntPtr)
             [FocusApi]::SwitchToThisWindow($IntPtr, $true)
             [FocusApi]::AttachThreadInput($MyThreadId, $TargetThreadId, $false)
        } else {
             [FocusApi]::SetForegroundWindow($IntPtr)
             [FocusApi]::SwitchToThisWindow($IntPtr, $true)
        }

        # NEW: 主窗口激活后，使用模拟鼠标点击设置焦点（解决 WT 焦点问题）
        if ($FocusedTab) {
            Start-Sleep -Milliseconds 100  # 等待主窗口激活完成
            try {
                "Using mouse click simulation to set keyboard focus..." | Out-File $LogPath -Append

                # 获取 Tab 的屏幕坐标
                $tabBounds = $FocusedTab.Current.BoundingRectangle
                $clickX = [int]($tabBounds.Left + $tabBounds.Width / 2)
                $clickY = [int]($tabBounds.Top + $tabBounds.Height / 2)

                "Tab bounds: X=$($tabBounds.X), Y=$($tabBounds.Y), W=$($tabBounds.Width), H=$($tabBounds.Height)" | Out-File $LogPath -Append
                "Clicking at: X=$clickX, Y=$clickY" | Out-File $LogPath -Append

                # 添加鼠标点击 API
                $MouseApi = @"
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
                Add-Type -TypeDefinition $MouseApi

                # 移动鼠标到 Tab 中心
                [MouseApi]::SetCursorPos($clickX, $clickY)
                Start-Sleep -Milliseconds 20

                # 模拟鼠标点击
                [MouseApi]::mouse_event([MouseApi]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
                Start-Sleep -Milliseconds 20
                [MouseApi]::mouse_event([MouseApi]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)

                "Mouse click completed, focus should be set" | Out-File $LogPath -Append
            } catch {
                "Mouse click error: $_" | Out-File $LogPath -Append
            }
        }
    }
} catch {
    "Error: $_" | Out-File $LogPath -Append
}
