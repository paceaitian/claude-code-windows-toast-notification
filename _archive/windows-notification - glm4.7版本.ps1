<#
.SYNOPSIS
    Sends a Custom Notification on Windows (WinForms-based).
    Replaces Native Toasts to guarantee Click-to-Focus reliability.

.DESCRIPTION
    Uses WinForms to show a custom notification.
    Automatically switches to Windows PowerShell (5.1) if running in Core to ensure WinRT API compatibility.
    This version uses a custom WinForms UI instead of native Windows Toast Notifications
    to provide more reliable "click-to-focus" behavior for the originating application.

.PARAMETER Title
    The title of the notification.

.PARAMETER Message
    The body text of the notification.

.PARAMETER AppId
    The Application ID. Unused in the WinForms version, kept for compatibility.

.PARAMETER AudioPath
    Path to a .wav file to play when the notification appears.

.PARAMETER InputObject
    Allows receiving input from the pipeline, typically JSON payload.

.EXAMPLE
    .\Send-Toast.ps1 -Title "Task Done" -Message "Your process finished."

.EXAMPLE
    @{ title = "Build Complete"; message = "Project X built successfully." } | .\Send-Toast.ps1
#>
param(
    [Parameter(Mandatory=$false, Position=0)]
    [string]$Title = "Claude Code Notification",

    [Parameter(Mandatory=$false, Position=1)]
    [string]$Message = "Task finished.",

    [string]$AppId, # Unused in WinForms version, kept for compatibility
    
    [string]$AudioPath,

    [Parameter(ValueFromPipeline=$true)]
    [psobject]$InputObject,


    # Internal parameters for detached worker mode
    [switch]$Worker,
    [string]$Base64Title,
    [string]$Base64Message,
    [int]$TargetPid = 0,
    [int]$TargetHwnd = 0, # NEW: Explicit HWND
    [string]$BeaconTitle, # NEW: Title to search for via UIA
    [int]$TabIndex = -1,  # NEW: Direct Tab Index for multi-window support
    [switch]$Wait, # NEW: Blocking Mode (The "Proposal D" Fix)
    [int]$Delay = 0,       # NEW: 延迟通知秒数（用于避免活跃使用时打扰）
    [int]$PollInterval = 5 # NEW: 轮询检测间隔（秒）
)

    # --- WORKER MODE (Background Process) ----------------------------------------
    if ($Worker) {
        # Global Trap for unhandled exceptions in Worker
        trap {
            $ErrorMsg = $_.Exception.Message
            "WORKER CRASH: $ErrorMsg" | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8
            exit 1
        }
    
        "Worker Started with PID $PID. Received TargetPid: $TargetPid" | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8
    
        # Load WinRT Assemblies for Native Toasts
        $WinMdPath = "C:\Windows\System32\WinMetadata\Windows.UI.Notifications.winmd"
        $XmlMdPath = "C:\Windows\System32\WinMetadata\Windows.Data.Xml.Dom.winmd"
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime]
    
        # Decode arguments
        try {
            if ($Base64Title) { $Title = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Title)) }
            if ($Base64Message) { $Message = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Message)) }
            "Decoded Title: $Title" | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8
            "Decoded Message: $Message" | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8
        } catch {
            "Decode Error: $_" | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8
        }
    
        # Get Target HWND from arguments (TargetPid -> Hwnd)
        # Note: We rely on the Launcher passing the HWND or us finding it from PID again.
        # But Launcher already found TargetPid. Let's find HWND here.
        # Get Target HWND from arguments (TargetPid -> Hwnd)
        # We need the HOST process (WindowsTerminal), not the shell process (pwsh)
        function Get-HostHwnd($TargetProcessId) {
            $Next = $TargetProcessId
            for ($i=0; $i -lt 6; $i++) {
                try {
                    $P = Get-Process -Id $Next -ErrorAction Stop
                    # Check if this process has a window and looks like a Host
                    if ($P.MainWindowHandle -ne 0 -and ($P.ProcessName -match "^(WindowsTerminal|Code|devenv|idea64)$")) {
                        return $P.MainWindowHandle
                    }
                    # Traverse Up
                    $Next = (Get-CimInstance Win32_Process -Filter "ProcessId=$Next").ParentProcessId
                    if (-not $Next) { break }
                } catch { break }
            }
            # Fallback: Just return the shell's window if no host found (e.g. conhost legacy)
            try { return (Get-Process -Id $TargetProcessId).MainWindowHandle } catch { return 0 }
        }

        $TargetHwnd = 0
        if ($TargetHwnd -eq 0 -and $TargetPid -gt 0) {
            $TargetHwnd = Get-HostHwnd $TargetPid
        }
        
        "Target HWND (Host): $TargetHwnd" | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8

        # Construct Protocol Activation URI
        # Construct Protocol Activation URI
        "Pre-URI TargetPid: $TargetPid" | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8
        $LaunchUri = "claude-runner:focus?hwnd=$TargetHwnd&pid=$TargetPid" # Pass PID for Heuristic Indexing
        if ($BeaconTitle) { 
             # URI Encode the beacon title to handle spaces and special chars
             $EncodedBeacon = [Uri]::EscapeDataString($BeaconTitle)
             $LaunchUri += "&beacon=$EncodedBeacon"
        }
        # NEW: Add TabIndex for multi-window support (direct index bypass)
        if ($TabIndex -ge 0) {
             $LaunchUri += "&tabindex=$TabIndex"
        }

        # XML Escaping Helper
        function Escape-Xml([string]$str) {
            if ([string]::IsNullOrEmpty($str)) { return "" }
            return $str.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("`"", "&quot;").Replace("'", "&apos;")
        }

        $SafeTitle = Escape-Xml $Title
        $SafeMessage = Escape-Xml $Message
        $SafeLaunchUri = Escape-Xml $LaunchUri

        # --- Construct XML Toast ---
        $Template = @"
<toast launch="$SafeLaunchUri" activationType="protocol" duration="long">
  <visual>
    <binding template="ToastGeneric">
      <text>$SafeTitle</text>
      <text>$SafeMessage</text>
      <image placement="appLogoOverride" hint-crop="circle" src="$env:USERPROFILE\.claude\assets\claude-logo.png"/>
    </binding>
  </visual>
  <audio silent="true" />
</toast>
"@
    
        $Xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $Xml.LoadXml($Template)
    
        $Toast = [Windows.UI.Notifications.ToastNotification]::new($Xml)
        
        # Spoofing AppId as Windows Terminal to ensure it appears contextually relevant
        # Note: Protocol launch works regardless of AppId if protocol is registered system-wide.
        $AppId = "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
    
        try {
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($Toast)
            "Toast Shown!" | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8
        } catch {
            "Toast Failed: $_" | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8
        }
        
        # --- Play Custom Audio AFTER Toast (for sync) ---
        if ($AudioPath -and (Test-Path $AudioPath)) {
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $Player = New-Object System.Media.SoundPlayer $AudioPath
                $Player.PlaySync()  # Sync play - ensures audio finishes before Worker exits
            } catch {}
        }
        
        # Worker can exit after audio finishes
        exit
    }


# --- LAUNCHER MODE (Main Entry Point) ----------------------------------------

# 1. Process Input
$DebugLog = "$env:USERPROFILE\.claude\toast_debug.log"
"--- LAUNCHER $(Get-Date) ---" | Out-File $DebugLog -Append -Encoding UTF8
$TranscriptPath = $null
try {
    $Payload = $null
    if ($InputObject) { if ($InputObject -is [string]) { $Payload = $InputObject | ConvertFrom-Json -ErrorAction SilentlyContinue } else { $Payload = $InputObject } }
    elseif ($input) { $RawInput = $input | Out-String; if (-not [string]::IsNullOrWhiteSpace($RawInput)) { $Payload = $RawInput | ConvertFrom-Json -ErrorAction SilentlyContinue } }

    # DEBUG: 记录 Payload 完整内容
    if ($Payload) {
        "Payload: $($Payload | ConvertTo-Json -Depth 5 -Compress)" | Out-File $DebugLog -Append -Encoding UTF8
    }

    # 保存 transcript_path 供后续使用
    if ($Payload -and $Payload.transcript_path) { $TranscriptPath = $Payload.transcript_path }
} catch {}

# 1.5 Smart Foreground Detection: 如果用户正在看屏幕，不打扰
# - 后台 → 继续通知
# - 前台 → 静默退出（用户正在看屏幕不需要通知）

# 先定义 WinApi 类型（用于前台窗口检测）
if (-not ([System.Management.Automation.PSTypeName]'WinApi').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinApi {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
}
"@
}

if ($Delay -gt 0) {
    "Delay > 0, checking if Claude tab is visible..." | Out-File $DebugLog -Append -Encoding UTF8
    try {
        # 1. 先检查前台窗口是否是 Windows Terminal
        $CurrentFgHwnd = [WinApi]::GetForegroundWindow()
        $FgPid = 0
        [WinApi]::GetWindowThreadProcessId($CurrentFgHwnd, [ref]$FgPid)
        
        $IsClaudeTabVisible = $false
        
        if ($FgPid -gt 0) {
            $FgProc = Get-Process -Id $FgPid -ErrorAction SilentlyContinue
            "FgProc: $($FgProc.ProcessName)" | Out-File $DebugLog -Append -Encoding UTF8
            
            if ($FgProc -and $FgProc.ProcessName -eq "WindowsTerminal") {
                # 2. 前台是终端，使用 UI Automation 检查当前选中的 tab
                Add-Type -AssemblyName UIAutomationClient
                Add-Type -AssemblyName UIAutomationTypes
                
                $propCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ClassNameProperty,
                    "CASCADIA_HOSTING_WINDOW_CLASS"
                )
                $desktop = [System.Windows.Automation.AutomationElement]::RootElement
                $terminals = $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $propCondition)
                
                foreach ($terminal in $terminals) {
                    if ($terminal.Current.NativeWindowHandle -eq $CurrentFgHwnd) {
                        # 找到当前前台的终端窗口，查找选中的 Tab
                        $Tabs = $terminal.FindAll(
                            [System.Windows.Automation.TreeScope]::Descendants,
                            [System.Windows.Automation.PropertyCondition]::new(
                                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                                [System.Windows.Automation.ControlType]::TabItem
                            )
                        )
                        
                        foreach ($Tab in $Tabs) {
                            $selPattern = $null
                            if ($Tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selPattern)) {
                                if ($selPattern.Current.IsSelected) {
                                    $TabName = $Tab.Current.Name
                                    "Selected Tab: $TabName" | Out-File $DebugLog -Append -Encoding UTF8
                                    # 检查 tab 名称是否包含 Claude 特征
                                    if ($TabName -match "⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|⠐|Claude|claude") {
                                        $IsClaudeTabVisible = $true
                                    }
                                    break
                                }
                            }
                        }
                        break
                    }
                }
            }
        }
        
        if ($IsClaudeTabVisible) {
            "Claude tab is visible, exiting..." | Out-File $DebugLog -Append -Encoding UTF8
            exit 0
        }
    } catch {
        "FG Check Error: $_" | Out-File $DebugLog -Append -Encoding UTF8
    }
}
"Continuing to show notification..." | Out-File $DebugLog -Append -Encoding UTF8
# 如果是后台，继续执行通知流程

# 2. Continue Processing
try {
    if ($Payload) {
        # Transcript Extraction...
        if ($Payload.transcript_path -and (Test-Path $Payload.transcript_path)) {
            try {
                $TranscriptLines = Get-Content $Payload.transcript_path -Tail 50 -Encoding UTF8 -ErrorAction Stop
                
                # 注意：turn_duration 在 stop hook 之后才写入 transcript，因此 hook 运行时无法读取当前 turn 的 duration
                # Duration 提取逻辑已移除
                
                # 2. Extract Last Assistant Message - 优先提取 tool_use，回退到 text
                $ResponseTime = ""
                $ToolUseInfo = $null  # NEW: 存储 tool_use 信息
                for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
                    $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
                    try {
                        $Entry = $Line | ConvertFrom-Json
                        if ($Entry.type -eq 'assistant' -and $Entry.message) { $Content = $Entry.message.content } elseif ($Entry.type -eq 'message' -and $Entry.role -eq 'assistant') { $Content = $Entry.content } else { $Content = $null }
                        if ($Content) {
                            # 提取回答时间
                            if ($Entry.timestamp -and -not $ResponseTime) {
                                try {
                                    $UtcTime = [DateTime]::Parse($Entry.timestamp)
                                    $LocalTime = $UtcTime.ToLocalTime()
                                    $ResponseTime = $LocalTime.ToString("HH:mm")
                                } catch {}
                            }

                            # 优先提取 tool_use 信息
                            $ToolUse = $Content | Where-Object { $_.type -eq 'tool_use' } | Select-Object -First 1
                            if ($ToolUse) {
                                $ToolName = $ToolUse.name
                                $ToolInput = $ToolUse.input

                                # DEBUG: 记录找到的 tool_use
                                "Found tool_use: $ToolName" | Out-File $DebugLog -Append -Encoding UTF8
                                if ($ToolInput.command) { "ToolInput.command: $($ToolInput.command)" | Out-File $DebugLog -Append -Encoding UTF8 }

                                # 根据工具类型提取详细信息
                                $Detail = ""
                                $Description = ""
                                switch ($ToolName) {
                                    "Bash" {
                                        if ($ToolInput.command) { $Detail = $ToolInput.command }
                                        if ($ToolInput.description) { $Description = $ToolInput.description }
                                    }
                                    "Read" {
                                        if ($ToolInput.file_path) { $Detail = $ToolInput.file_path }
                                    }
                                    "Write" {
                                        if ($ToolInput.file_path) { $Detail = "Write: " + $ToolInput.file_path }
                                    }
                                    "Edit" {
                                        if ($ToolInput.file_path) { $Detail = "Edit: " + $ToolInput.file_path }
                                    }
                                    "Grep" {
                                        if ($ToolInput.pattern) { $Detail = "Search: " + $ToolInput.pattern }
                                    }
                                    "WebSearch" {
                                        if ($ToolInput.query) { $Detail = "Search: " + $ToolInput.query }
                                    }
                                    "mcp__Serper_MCP_Server__google_search" {
                                        if ($ToolInput.q) { $Detail = "Search: " + $ToolInput.q }
                                    }
                                    default {
                                        if ($ToolInput.description) { $Detail = $ToolInput.description }
                                        elseif ($ToolInput.file_path) { $Detail = $ToolInput.file_path }
                                        elseif ($ToolInput.path) { $Detail = $ToolInput.path }
                                        elseif ($ToolInput.url) { $Detail = $ToolInput.url }
                                    }
                                }

                                # 组合 Detail 和 Description
                                if ($Detail -or $Description) {
                                    $Combined = ""
                                    if ($Detail) { $Combined = $Detail }
                                    if ($Description) {
                                        if ($Combined) { $Combined += " - " }
                                        $Combined += $Description
                                    }
                                    if ($Combined.Length -gt 200) { $Combined = $Combined.Substring(0, 197) + "..." }
                                    $ToolUseInfo = "[$ToolName] $Combined"
                                    "ToolUseInfo set to: $ToolUseInfo" | Out-File $DebugLog -Append -Encoding UTF8
                                }

                                # 找到 tool_use 后立即跳出，不需要继续查找 text
                                break
                            }

                            # 回退：提取 text 内容（如果没有 tool_use）
                            $LastText = $Content | Where-Object { $_.type -eq 'text' } | Select-Object -ExpandProperty text -Last 1
                            if ($LastText) {
                                # Clean Markdown formatting (保留代码块内容，只删除格式标记)
                                $CleanText = $LastText -replace '#{1,6}\s*', '' -replace '\*{1,2}([^*]+)\*{1,2}', '$1' -replace '```[a-z]*\r?\n?', '' -replace '`([^`]+)`', '$1' -replace '\[([^\]]+)\]\([^)]+\)', '$1' -replace '^\s*[-*]\s+', '' -replace '\r?\n', ' '
                                $CleanText = $CleanText.Trim()
                                if ($CleanText.Length -gt 500) { $CleanText = $CleanText.Substring(0, 497) + "..." }
                                if ($CleanText) { $Message = "A: [$ResponseTime] $CleanText" }
                                break
                            }
                        }
                    } catch {}
                }

                # 如果找到 tool_use 信息，优先使用
                if ($ToolUseInfo) {
                    $Message = $ToolUseInfo
                    "Final Message set from ToolUseInfo: $Message" | Out-File $DebugLog -Append -Encoding UTF8
                }
                
                # 3. Extract Last User Message (用于 Title)
                for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
                    $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
                    try {
                        $Entry = $Line | ConvertFrom-Json
                        # 匹配 user 类型消息（跳过 tool_result 和 meta 消息）
                        if ($Entry.type -eq 'user' -and $Entry.message -and -not $Entry.isMeta) {
                            $UserContent = $Entry.message.content
                            # 跳过 tool_result 类型的消息
                            if ($UserContent -is [string] -and $UserContent -notmatch '^\s*<') {
                                $UserText = $UserContent.Trim()
                                if ($UserText.Length -gt 60) { $UserText = $UserText.Substring(0, 57) + "..." }
                                if ($UserText) { 
                                    $Title = "Q: $UserText"
                                    break 
                                }
                            }
                        }
                    } catch {}
                }
            } catch {}
        }

        # Payload 处理：只有当 transcript 没有提取到有效内容时才使用 Payload
        # 注意：如果 transcript 中已提取到 tool_use 信息，不要用 Payload.message 覆盖
        if ($Payload.title -and $Title -eq "Claude Code Notification") { $Title = $Payload.title }
        if ($Payload.message -and $Message -eq "Task finished.") { $Message = $Payload.message }
        
        # 增强 permission 信息：提取 tool_name 和 tool_input
        if ($Payload.tool_name) {
            $ToolName = $Payload.tool_name
            $ToolDetail = ""
            
            # 根据不同工具类型提取详细信息
            if ($Payload.tool_input) {
                if ($Payload.tool_input.command) {
                    # Bash/Shell 命令
                    $ToolDetail = $Payload.tool_input.command
                } elseif ($Payload.tool_input.file_path) {
                    # 文件操作
                    $ToolDetail = $Payload.tool_input.file_path
                } elseif ($Payload.tool_input.path) {
                    # 路径操作
                    $ToolDetail = $Payload.tool_input.path
                } elseif ($Payload.tool_input.url) {
                    # Web 请求
                    $ToolDetail = $Payload.tool_input.url
                }
            }
            
            # 构建详细 Message
            if ($ToolDetail) {
                # 截断过长的命令
                if ($ToolDetail.Length -gt 200) { $ToolDetail = $ToolDetail.Substring(0, 197) + "..." }
                $Message = "[$ToolName] $ToolDetail"
            } elseif (-not $Payload.message) {
                $Message = "Permission: $ToolName"
            }
        }
    }
} catch {}

# 只有在 transcript 没有提取到 user 消息且 payload 没有自定义 title 时才使用默认标题
if ($Title -eq "Claude Code Notification" -and $env:CLAUDE_PROJECT_DIR) { 
    $ProjectName = Split-Path $env:CLAUDE_PROJECT_DIR -Leaf
    $Title = "Task Done [$ProjectName]" 
}


function Repair-Encoding([string]$str) {
    if ([string]::IsNullOrEmpty($str)) { return $str }
    try { $bytes = [System.Text.Encoding]::Default.GetBytes($str); return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { return $str }
}
$Title = Repair-Encoding $Title; $Message = Repair-Encoding $Message

# 4. Prepare Launch
$CapturedPid = $PID
try {
    # ----------------------------------------------------
    # NEW: Foreground Window Capture (Fix for Multi-Window)
    # ----------------------------------------------------
    # WinApi 类型已在前面定义，这里跳过重复定义
    if (-not ([System.Management.Automation.PSTypeName]'WinApi').Type) {
        Add-Type -TypeDefinition @"
            using System;
            using System.Runtime.InteropServices;
            public class WinApi {
                [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
                [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
            }
"@
    }
    $FgHwnd = [WinApi]::GetForegroundWindow()
    $FgPid = 0
    [WinApi]::GetWindowThreadProcessId($FgHwnd, [ref]$FgPid)

    # NEW: Beacon Setup (The Trick)
    # ----------------------------------------------------
    $BeaconId = [Guid]::NewGuid().ToString().Substring(0, 8) # Short GUID
    try {
        if ($Host.Name -like "*ConsoleHost*") {
            $OriginalTitle = $Host.UI.RawUI.WindowTitle
            $BeaconTitle = "$OriginalTitle ($BeaconId)"
            $Host.UI.RawUI.WindowTitle = $BeaconTitle
            # We do NOT restore title here, as the beacon must be active when user clicks.
        }
    } catch {}

    function Get-ParentPid($ProcessId) { return (Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId").ParentProcessId }
    
    # --- HWND-based Tab Shell Discovery ---
    # Since hook process may not be in WT tree directly (Claude spawns via different mechanism),
    # we use FgHwnd to identify the correct WT, then search for the Tab shell that contains us.
    
    $TabShellPid = 0
    $TargetWtPid = 0
    $CapturedTabIndex = -1  # -1 means "not captured, use fallback"
    
    # 1. Verify FgHwnd belongs to WindowsTerminal
    if ($FgPid -gt 0) {
        try {
            $FgProc = Get-Process -Id $FgPid -ErrorAction Stop
            if ($FgProc.ProcessName -eq "WindowsTerminal") {
                $TargetWtPid = $FgPid
                $TargetHwnd = [int]$FgHwnd
                
                # --- NEW: UIA-based Tab Index Capture (Multi-Window Fix) ---
                try {
                    Add-Type -AssemblyName UIAutomationClient
                    Add-Type -AssemblyName UIAutomationTypes
                    
                    $propCondition = [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ClassNameProperty,
                        "CASCADIA_HOSTING_WINDOW_CLASS"
                    )
                    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
                    $terminals = $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, $propCondition)
                    
                    foreach ($terminal in $terminals) {
                        if ($terminal.Current.NativeWindowHandle -eq $TargetHwnd) {
                            # Found the correct window! Now find Tabs.
                            $Tabs = $terminal.FindAll(
                                [System.Windows.Automation.TreeScope]::Descendants,
                                [System.Windows.Automation.PropertyCondition]::new(
                                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                                    [System.Windows.Automation.ControlType]::TabItem
                                )
                            )
                            
                            # Find currently selected Tab
                            for ($i = 0; $i -lt $Tabs.Count; $i++) {
                                $selPattern = $null
                                if ($Tabs[$i].TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selPattern)) {
                                    if ($selPattern.Current.IsSelected) {
                                        $CapturedTabIndex = $i
                                        break
                                    }
                                }
                            }
                            break
                        }
                    }
                } catch {}
            }
        } catch {}
    }
    
    # 2. If foreground wasn't WT, try walking up from hook's $PID (legacy fallback)
    if ($TargetWtPid -eq 0) {
        $NextPid = $PID
        for ($i = 0; $i -lt 8; $i++) {
            $NextPid = Get-ParentPid $NextPid; if ($NextPid -le 0) { break }
            try {
                $Proc = Get-Process -Id $NextPid -ErrorAction Stop
                if ($Proc.ProcessName -eq "WindowsTerminal") { 
                    $TargetWtPid = $NextPid
                    if ($Proc.MainWindowHandle -ne 0) { $TargetHwnd = [int]$Proc.MainWindowHandle }
                    break
                }
            } catch { break }
        }
    }
    
    # 3. Find which Tab shell contains us (walk UP from $PID until hitting a direct WT child)
    if ($TargetWtPid -gt 0) {
        $NextPid = $PID
        for ($i = 0; $i -lt 10; $i++) {
            $ParentOfNext = Get-ParentPid $NextPid
            if ($ParentOfNext -le 0) { break }
            
            # If parent is WT, then NextPid is the Tab shell!
            if ($ParentOfNext -eq $TargetWtPid) {
                $TabShellPid = $NextPid
                break
            }
            $NextPid = $ParentOfNext
        }
    }
    
    # 4. Use TabShellPid for the Handler (this is what we need for correct Tab Index)
    if ($TabShellPid -gt 0) {
        $CapturedPid = $TabShellPid
    } elseif ($TargetWtPid -gt 0) {
        $CapturedPid = $TargetWtPid # Fallback to WT itself, handler will figure out
    }
    # else: CapturedPid remains hook's own $PID (last resort)
} catch {}

$B64Title = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Title))
$B64Message = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Message))
$SelfPath = $MyInvocation.MyCommand.Path

# 5. Launch Worker
$ArgumentList = @("-ExecutionPolicy", "Bypass", "-File", "`"$SelfPath`"", "-Worker", "-Base64Title", "`"$B64Title`"", "-Base64Message", "`"$B64Message`"", "-AudioPath", "`"$AudioPath`"", "-TargetPid", "$CapturedPid", "-TargetHwnd", "$TargetHwnd", "-BeaconTitle", "`"$BeaconTitle`"", "-TabIndex", "$CapturedTabIndex")
try {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $ArgumentList
} catch {
    Write-Warning "Failed to launch notification worker: $_"
}
    # CRITICAL: Blocking Wait Strategy (Auto-Resume)
    # Instead of asking user to press Enter (which blocks Claude), we wait until
    # we detect that this window has regained focus.
    if ($Wait -and $TargetHwnd -gt 0) {
        $MaxRetries = 172800 # 24 hours
        Write-Host "`n[Blocking Mode] Holding Beacon '$BeaconTitle'..." -ForegroundColor DarkGray
        Write-Host "Waiting for focus to return to this window..." -ForegroundColor DarkGray
        
        # 1. Grace Period: Give user time to switch away or see the toast
        Start-Sleep -Seconds 2

        # 2. Focus Loop - Check if ANY IDE/Terminal window is focused
        # 添加超时机制避免无限阻塞（30秒后自动恢复）
        $TimeoutSeconds = 30
        $ElapsedMs = 0
        while ($ElapsedMs -lt ($TimeoutSeconds * 1000)) {
            $CurrentFg = [WinApi]::GetForegroundWindow()
            $CurrentFgPid = 0
            [WinApi]::GetWindowThreadProcessId($CurrentFg, [ref]$CurrentFgPid)
            
            # Check if foreground window belongs to IDE/Terminal
            $IsFocusedOnIDE = $false
            if ($CurrentFgPid -gt 0) {
                try {
                    $FgProc = Get-Process -Id $CurrentFgPid -ErrorAction Stop
                    if ($FgProc.ProcessName -eq "WindowsTerminal") {
                        $IsFocusedOnIDE = $true
                    }
                } catch {}
            }
            
            if ($IsFocusedOnIDE) { 
                Write-Host "Focus detected. Resuming..." -ForegroundColor Green
                break 
            }
            Start-Sleep -Milliseconds 100
            $ElapsedMs += 100
        }
        
        if ($ElapsedMs -ge ($TimeoutSeconds * 1000)) {
            Write-Host "Timeout reached. Auto-resuming..." -ForegroundColor Yellow
        }
    } elseif ($Wait) {
        # Fallback if we couldn't identify our own window
        Write-Warning "Could not determine TargetHwnd for Auto-Resume."
        Write-Host "Press ENTER to continue..." 
        $null = Read-Host
    } else {
        "Launcher: Waiting 10s for Worker..." | Out-File "$env:USERPROFILE\.claude\toast_debug.log" -Append -Encoding UTF8
        Start-Sleep -Seconds 10
    }
exit
