
param([string]$UriArgs)

# 调试开关：从 URI 参数 debug=1 或环境变量 CLAUDE_HOOK_DEBUG=1 启用
$DebugMode = ($UriArgs -match "debug=1") -or ($env:CLAUDE_HOOK_DEBUG -eq "1")
$LogPath = "$env:USERPROFILE\.claude\protocol_debug.log"

function Write-DebugLog([string]$Message) {
    if ($script:DebugMode) {
        "[$((Get-Date).ToString('HH:mm:ss'))] $Message" | Out-File $script:LogPath -Append -Encoding UTF8
    }
}

Write-DebugLog "Handler Triggered: $UriArgs"

# UIA Assemblies
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# NEW: 添加 SendKeys 支持
Add-Type -AssemblyName System.Windows.Forms

# Parse URI: claude-runner:focus?hwnd=12345&pid=6789&beacon=uuid&button=1
try {
    $TargetHwnd = 0
    $BeaconTitle = $null
    $ButtonNumber = $null

    if ($UriArgs -match "hwnd=(\d+)") { $TargetHwnd = [int]$Matches[1] }
    if ($UriArgs -match "beacon=([^&]+)") {
        $BeaconTitle = [Uri]::UnescapeDataString($Matches[1])
    }
    if ($UriArgs -match "button=(\d+)") {
        $ButtonNumber = [int]$Matches[1]
        Write-DebugLog "Button clicked: $ButtonNumber"
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
    
    
    # --- UIA Helper Functions ---
    # 获取所有 Windows Terminal 窗口
    function Get-AllTerminalWindows {
        $propCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty,
            "CASCADIA_HOSTING_WINDOW_CLASS"
        )
        $desktop = [System.Windows.Automation.AutomationElement]::RootElement
        return $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $propCondition)
    }
    
    # 获取终端窗口中的所有 Tab
    function Get-TerminalTabs($Terminal) {
        return $Terminal.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::TabItem
            )
        )
    }
    
    # 选中指定的 Tab 并返回是否成功
    function Select-Tab($Tab) {
        $selPattern = $null
        if ($Tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selPattern)) {
            $selPattern.Select()
            return $true
        }
        return $false
    }
    
    # --- UIA Search Logic ---
    $UiaSuccess = $false
    $FocusedTab = $null  # 保存需要聚焦的 Tab
    
    # 0. Priority: Claude Spinner Search (Multi-Window Fix)
    Write-DebugLog "Attempting Claude Spinner Search across all WT windows..."
    try {
        $terminals = Get-AllTerminalWindows
        foreach ($terminal in $terminals) {
            $Tabs = Get-TerminalTabs $terminal
            for ($i = 0; $i -lt $Tabs.Count; $i++) {
                $TabName = $Tabs[$i].Current.Name
                # Claude Code shows spinner "⠐" or similar braille patterns when running
                if ($TabName -match "⠐|⠈|⠁|⠂|⠄|⠠|Claude") {
                    Write-DebugLog "Found Claude Tab: '$TabName' at index $i in HWND $($terminal.Current.NativeWindowHandle)"
                    if (Select-Tab $Tabs[$i]) {
                        $UiaSuccess = $true
                        $TargetHwnd = [int]$terminal.Current.NativeWindowHandle
                        $FocusedTab = $Tabs[$i]
                    }
                    break
                }
            }
            if ($UiaSuccess) { break }
        }
    } catch {
        Write-DebugLog "Claude Spinner Search Error: $_"
    }
    
    # 1. Fallback: Try Beacon (High Precision)
    if (-not $UiaSuccess -and -not [string]::IsNullOrWhiteSpace($BeaconTitle)) {
        Write-DebugLog "Attempting UIA Focus for Beacon: $BeaconTitle"
        try {
            $terminals = Get-AllTerminalWindows
            foreach ($terminal in $terminals) {
                $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty,
                    $BeaconTitle
                )
                $targetTab = $terminal.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)
                if ($targetTab) {
                    Write-DebugLog "UIA: Found Tab via Beacon! Selecting..."
                    if (Select-Tab $targetTab) {
                        $UiaSuccess = $true
                        $FocusedTab = $targetTab
                    }
                    $TargetHwnd = [int]$terminal.Current.NativeWindowHandle
                    break
                }
            }
        } catch {
            Write-DebugLog "UIA Beacon Error: $_"
        }
    }

    if ($TargetHwnd -gt 0) {
        Write-DebugLog "Focusing HWND: $TargetHwnd"
        
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
                Write-DebugLog "Using mouse click simulation to set keyboard focus..."

                # 获取 Tab 的屏幕坐标
                $tabBounds = $FocusedTab.Current.BoundingRectangle
                $clickX = [int]($tabBounds.Left + $tabBounds.Width / 2)
                $clickY = [int]($tabBounds.Top + $tabBounds.Height / 2)

                Write-DebugLog "Tab bounds: X=$($tabBounds.X), Y=$($tabBounds.Y), W=$($tabBounds.Width), H=$($tabBounds.Height)"
                Write-DebugLog "Clicking at: X=$clickX, Y=$clickY"

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

                Write-DebugLog "Mouse click completed, focus should be set"
            } catch {
                Write-DebugLog "Mouse click error: $_"
            }

            # NEW: 如果点击了 Toast 按钮，模拟输入对应的数字
            if ($ButtonNumber) {
                Start-Sleep -Milliseconds 100  # 等待焦点设置完成
                try {
                    Write-DebugLog "Simulating keypress: $ButtonNumber"
                    [System.Windows.Forms.SendKeys]::SendWait("$ButtonNumber")
                    Write-DebugLog "Keypress sent"
                } catch {
                    Write-DebugLog "SendKeys error: $_"
                }
            }
        }
    }
} catch {
    Write-DebugLog "Error: $_"
}
