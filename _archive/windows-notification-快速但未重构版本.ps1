<#
.SYNOPSIS
    Windows Notification Hook (Copy 2) - Tab Title Strategy + Full Transcript Parsing
    Updates Terminal Tab Title to Project Name for robust tracking.
    Restores Rich Q/A Notifications.
#>

param(
    [Parameter(Mandatory=$false, Position=0)] [string]$Title = "Claude Notification",
    [Parameter(Mandatory=$false, Position=1)] [string]$Message = "Task finished.",
    [string]$AudioPath,
    [Parameter(ValueFromPipeline=$true)] [psobject]$InputObject,
    
    # Worker Params
    [switch]$Worker,
    [string]$Base64Title,
    [string]$Base64Message,
    [string]$ProjectName,
    [string]$NotificationType,
    [string]$ModulePath,
    [string]$TranscriptPath, # NEW: Pass path instead of full text
    [switch]$EnableDebug,
    [switch]$Wait,
    [int]$Delay = 0,
    [int]$TargetPid = 0 # NEW: Expect L3 Shell PID
)

# Common Helpers
$DebugLog = "$env:USERPROFILE\.claude\toast_debug.log"
$Script:DebugEnabled = $EnableDebug -or ($env:CLAUDE_HOOK_DEBUG -eq "1")

function Write-DebugLog([string]$Msg) {
    if ($Script:DebugEnabled) { 
        "[$((Get-Date).ToString('HH:mm:ss'))] $Msg" | Out-File $DebugLog -Append -Encoding UTF8 
    }
}

function Repair-Encoding([string]$str) {
    if ([string]::IsNullOrEmpty($str)) { return $str }
    try { 
        $bytes = [System.Text.Encoding]::Default.GetBytes($str)
        return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) 
    } catch { return $str }
}

# ================= WORKER MODE =================
if ($Worker) {
    trap { Write-DebugLog "WORKER CRASH: $_"; exit 1 }
    
    # Decode Base64 params
    try {
        if ($Base64Title) { $Title = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Title)) }
        if ($Base64Message) { $Message = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64Message)) }
        if ($ProjectName) { $ProjectName = [Uri]::UnescapeDataString($ProjectName) }
        if ($TranscriptPath) { $TranscriptPath = [Uri]::UnescapeDataString($TranscriptPath) }
    } catch { Write-DebugLog "Decode Error: $_" }

    # 1. Setup WinApi
    try {
        if (-not ([System.Management.Automation.PSTypeName]'WinApi').Type) {
            Add-Type @"
            using System;
            using System.Runtime.InteropServices;
            using System.Text;
            public class WinApi {
                [DllImport("kernel32.dll")] public static extern bool AttachConsole(uint dwProcessId);
                [DllImport("kernel32.dll")] public static extern bool FreeConsole();
                [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
                [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
                [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
            }
"@
        }
    } catch { Write-DebugLog "WinApi Setup Error: $_" }

    # -----------------------------------------------------------
    # WATCHDOG STRATEGY (Persistent Override)
    # We attach ONCE, then enforce title every second.
    # This acts as an active lock against Shell/Claude resets.
    # -----------------------------------------------------------
    
    # 1. Helper: Check Focus (STRICT TITLE MATCH)
    function Test-IsFocused {
        try {
            $Hwnd = [WinApi]::GetForegroundWindow()
            $Sb = [System.Text.StringBuilder]::new(256)
            [WinApi]::GetWindowText($Hwnd, $Sb, 256) | Out-Null
            $Title = $Sb.ToString()
            if ($Title -like "*$ProjectName*") { return $true }
        } catch {}
        return $false
    }
    
    # 2. Watchdog Loop
    if ($TargetPid -gt 0 -and $ProjectName) {
        try {
            # Initial Sleep to let Shell start
            Start-Sleep -Milliseconds 300
            
            # Persistent Attachment
            [WinApi]::FreeConsole() | Out-Null
            if ([WinApi]::AttachConsole($TargetPid)) {
                Write-DebugLog "Watchdog: Attached to Console (PID $TargetPid)"
                
                # Loop
                $Max = $Delay
                for ($i = 0; $i -le $Max; $i++) {
                    
                    # A. Force Title (Every Second)
                    try {
                        # Native
                        [System.Console]::Title = $ProjectName
                        # OSC (Direct Flush)
                        $Osc = "$([char]27)]0;$ProjectName$([char]7)"
                        [System.Console]::Out.Write($Osc)
                        [System.Console]::Out.Flush()
                        
                        if ($i -eq 0) { Write-DebugLog "Watchdog: Title Set '$ProjectName'" }
                    } catch {}

                    # B. Focus Check
                    if (Test-IsFocused) {
                         Write-DebugLog "Watchdog: User Focused at T=$i. Exiting."
                         exit 0
                    } else {
                         if ($i % 2 -eq 0) { Write-DebugLog "Watchdog: Focus Mismatch (Checking...)" }
                    }
                    
                    # Sleep (unless last iter)
                    if ($i -lt $Max) { Start-Sleep -Seconds 1 }
                }
                
                # Cleanup
                [WinApi]::FreeConsole() | Out-Null
                
            } else {
                Write-DebugLog "Watchdog: Failed to attach. Running simple delay."
                Start-Sleep -Seconds $Delay
            }
        } catch { Write-DebugLog "Watchdog Error: $_" }
    } else {
        # Fallback (No PID)
        Start-Sleep -Seconds $Delay
    }

    # 4. Final Safety Focus Check (Post-Loop)
    if (Test-IsFocused) {
        Write-DebugLog "Final Check: User is focused. Aborting."
        exit 0
    }

    # 2. Transcript Parsing (Moved from Launcher)
    # This involves JSON parsing which can be slow (~80ms)
    if ($TranscriptPath -and (Test-Path $TranscriptPath)) {
        try {
            # Logic copied from previous Launcher implementation
            $TranscriptLines = Get-Content $TranscriptPath -Tail 50 -Encoding UTF8 -ErrorAction Stop
            
            $ResponseTime = ""
            $ToolUseInfo = $null
            $TextMessage = $null
            
            # 5a. Extract Last Assistant Message
            for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
                $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
                try {
                    $Entry = $Line | ConvertFrom-Json
                    
                    # STOP if User Message found
                    if ($Entry.type -eq 'user' -and $Entry.message) { break }

                    if ($Entry.type -eq 'assistant' -and $Entry.message) { $Content = $Entry.message.content } elseif ($Entry.type -eq 'message' -and $Entry.role -eq 'assistant') { $Content = $Entry.content } else { $Content = $null }
                    
                    if ($Content) {
                        if ($Entry.timestamp -and -not $ResponseTime) {
                            try { $ResponseTime = [DateTime]::Parse($Entry.timestamp).ToLocalTime().ToString("HH:mm") } catch {}
                        }

                        # Tool Info
                        $ToolUse = $Content | Where-Object { $_.type -eq 'tool_use' } | Select-Object -First 1
                        if ($ToolUse) {
                            $ToolName = $ToolUse.name
                            $ToolInput = $ToolUse.input
                            
                            $Detail = ""; $Description = ""
                            if ($ToolInput.description) { $Description = $ToolInput.description }
                            
                            if ($ToolName -match "^Bash$") { if ($ToolInput.command) { $Detail = $ToolInput.command } }
                            elseif ($ToolName -match "^(Read|Write|Edit)$") { if ($ToolInput.file_path) { $Detail = "$ToolName " + $ToolInput.file_path } }
                            elseif ($ToolName -match "Search") { if ($ToolInput.query) { $Detail = $ToolInput.query } }
                            elseif ($ToolName -eq "Task") {
                                 # Special handling for Subagent Tasks
                                 if ($ToolInput.subagent_type) {
                                      $RawName = ($ToolInput.subagent_type -split ":")[-1]
                                      if ($RawName.Length -gt 0) {
                                          $ToolName = $RawName.Substring(0,1).ToUpper() + $RawName.Substring(1)
                                      } else {
                                          $ToolName = $RawName
                                      }
                                 }
                                 if ($ToolInput.description) { $Detail = $ToolInput.description }
                            }
                            else { 
                                 if ($ToolInput.input) { $Detail = $ToolInput.input }
                                 elseif ($ToolInput.path) { $Detail = $ToolInput.path }
                            }
                            
                            if (-not $Detail -and -not $Description) {
                                 $json = $ToolInput | ConvertTo-Json -Depth 1 -Compress
                                 if ($json.Length -gt 50) { $Detail = $json.Substring(0,47) + "..." } else { $Detail = $json }
                            }

                            $Combined = ""
                            if ($Detail) { $Combined = $Detail }
                            if ($Description) { if ($Combined) { $Combined += " - " }; $Combined += $Description }
                            if ($Combined.Length -gt 200) { $Combined = $Combined.Substring(0, 197) + "..." }
                            
                            $ToolUseInfo = "[$ToolName] $Combined"
                        }

                        # Text Info
                        $LastText = $Content | Where-Object { $_.type -eq 'text' } | Select-Object -ExpandProperty text -Last 1
                        if ($LastText) {
                             $CleanText = $LastText -replace '#{1,6}\s*', '' -replace '\*{1,2}([^*]+)\*{1,2}', '$1' -replace '```[a-z]*\r?\n?', '' -replace '`([^`]+)`', '$1' -replace '\[([^\]]+)\]\([^)]+\)', '$1' -replace '^\s*[-*]\s+', '' -replace '\r?\n', ' '
                             $CleanText = $CleanText.Trim()
                             if ($CleanText.Length -gt 800) { $CleanText = $CleanText.Substring(0, 797) + "..." }
                             $TextMessage = if ($ResponseTime) { "A: [$ResponseTime] $CleanText" } else { "A: $CleanText" }
                        }

                        # Compose
                        if ($TextMessage -and $ToolUseInfo) {
                            if ($NotificationType -eq 'permission_prompt') {
                                 $Desc = $TextMessage -replace '^A: (\[.*?\] )?', ''
                                 $Message = "$ToolUseInfo - $Desc"
                            } else {
                                 $Message = "$ToolUseInfo  $TextMessage"
                            }
                        } elseif ($TextMessage) { $Message = $TextMessage }
                        elseif ($ToolUseInfo) { $Message = $ToolUseInfo }

                        if ($Message -ne "Task finished.") { break } 
                    }
                } catch {}
            }

            # 5b. Extract User Question (for Title)
            for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
                 $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
                 try {
                     $Entry = $Line | ConvertFrom-Json
                     if ($Entry.type -eq 'user' -and $Entry.message -and -not $Entry.isMeta) {
                         $UserContent = $Entry.message.content
                         if ($UserContent -is [string] -and $UserContent -notmatch '^\s*<') {
                              $UserText = $UserContent.Trim()
                              if ($UserText.Length -gt 60) { $UserText = $UserText.Substring(0, 57) + "..." }
                              if ($UserText) { $Title = "Q: $UserText"; break }
                         }
                     }
                 } catch {}
            }
        } catch { Write-DebugLog "Transcript Parse Error: $_" }
    }

    # Fallback Title if simple default
    if ($Title -eq "Claude Notification" -and $ProjectName) { $Title = "Task Done [$ProjectName]" }

    Write-DebugLog "Title: $Title"
    Write-DebugLog "Message: $Message"

    # Load BurntToast
    try {
        if ($ModulePath -and (Test-Path $ModulePath)) {
            Import-Module $ModulePath -Force -ErrorAction Stop
        } else {
            Import-Module BurntToast -ErrorAction Stop
        }
    } catch {
        # Fallback search
        $Paths = ($env:PSModulePath -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $Paths += "$env:USERPROFILE\Documents\WindowsPowerShell\Modules"
        $Paths += "$env:USERPROFILE\OneDrive\Documents\WindowsPowerShell\Modules"
        
        foreach ($p in $Paths) {
            if (Test-Path $p) {
                $check = Join-Path $p "BurntToast"
                if (Test-Path $check) { 
                    $psd1 = Get-ChildItem $check -Recurse -Filter "*.psd1" | Select-Object -First 1
                    if ($psd1) { Import-Module $psd1.FullName -Force -ErrorAction Stop; break }
                }
            }
        }
    }

    # Construct URI
    $LaunchUri = "claude-runner:focus?windowtitle=$([Uri]::EscapeDataString($ProjectName))"
    if ($TargetPid -gt 0) { $LaunchUri += "&pid=$TargetPid" }
    if ($NotificationType) { $LaunchUri += "&notification_type=$NotificationType" }

    try {
        $Text1 = New-BTText -Text $Title
        $Text2 = New-BTText -Text $Message
        $Logo = "$env:USERPROFILE\.claude\assets\claude-logo.png"
        $Img = if (Test-Path $Logo) { New-BTImage -Source $Logo -AppLogoOverride -Crop Circle } else { $null }
        
        $Binding = if ($Img) { New-BTBinding -Children $Text1, $Text2 -AppLogoOverride $Img } else { New-BTBinding -Children $Text1, $Text2 }
        $Visual = New-BTVisual -BindingGeneric $Binding

        # Buttons
        $Actions = $null
        if ($NotificationType -eq "permission_prompt") {
            $Btn1 = New-BTButton -Content 'Allow' -Arguments "$LaunchUri&button=1" -ActivationType Protocol
            $BtnDismiss = New-BTButton -Dismiss -Content 'Dismiss'
            $Actions = New-BTAction -Buttons $Btn1, $BtnDismiss
        } else {
            $BtnDismiss = New-BTButton -Dismiss
            $Actions = New-BTAction -Buttons $BtnDismiss
        }

        $Content = New-BTContent -Visual $Visual -Actions $Actions -Audio (New-BTAudio -Silent) `
            -ActivationType Protocol -Launch $LaunchUri -Scenario Reminder

        Submit-BTNotification -Content $Content
    } catch { Write-DebugLog "Toast Error: $_" }

    if ($AudioPath -and (Test-Path $AudioPath)) {
        try { (New-Object System.Media.SoundPlayer $AudioPath).PlaySync() } catch {}
    }
    exit
}

# ================= LAUNCHER MODE =================
Write-DebugLog "--- LAUNCHER (OPTIMIZED) ---"

# 1. Parse Input
try {
    $Payload = $null
    if ($InputObject) {
        if ($InputObject -is [string]) { $Payload = $InputObject | ConvertFrom-Json -ErrorAction SilentlyContinue } else { $Payload = $InputObject }
    } elseif ($input) {
        $Raw = $input | Out-String; if (-not [string]::IsNullOrWhiteSpace($Raw)) { $Payload = $Raw | ConvertFrom-Json -ErrorAction SilentlyContinue }
    }
} catch {}

# 2. Extract Project info (Fast)
$ProjectName = "Claude"
if ($Payload.project_name) { $ProjectName = $Payload.project_name }
elseif ($Payload.projectPath) { $ProjectName = Split-Path $Payload.projectPath -Leaf }
elseif ($Payload.project_dir) { $ProjectName = Split-Path $Payload.project_dir -Leaf }
if ($ProjectName -eq "Claude" -and $env:CLAUDE_PROJECT_DIR) { $ProjectName = Split-Path $env:CLAUDE_PROJECT_DIR -Leaf }

# 3. CONSOLE INJECTION LOGIC (Fixes Tab Title via OSC)
try {
    Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    using System.Diagnostics;

    public class WinApiConsole {
        [DllImport("kernel32.dll")] public static extern bool AttachConsole(uint dwProcessId);
        [DllImport("kernel32.dll")] public static extern bool FreeConsole();

        // Parent Process Logic
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool Process32First(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool Process32Next(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool CloseHandle(IntPtr hObject);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        struct PROCESSENTRY32 {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        public static int GetParentPid(int pid) {
            IntPtr hSnapshot = CreateToolhelp32Snapshot(0x00000002, 0); // TH32CS_SNAPPROCESS
            if (hSnapshot == IntPtr.Zero) return 0;

            PROCESSENTRY32 procEntry = new PROCESSENTRY32();
            procEntry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));

            if (Process32First(hSnapshot, ref procEntry)) {
                do {
                    if (procEntry.th32ProcessID == pid) {
                        CloseHandle(hSnapshot);
                        return (int)procEntry.th32ParentProcessID;
                    }
                } while (Process32Next(hSnapshot, ref procEntry));
            }
            CloseHandle(hSnapshot);
            return 0;
        }
    }
"@

    # B. Ancestor Lookup (Claude-Aware) - OPTIMIZED P/INVOKE
    # Goal: Find the Interactive Shell (pwsh/cmd) that launched Claude.
    # Tree: Hook(L0) -> Runner(L1 cmd) -> Claude(L2) -> InteractiveShell(L3 pwsh) -> Terminal
    $TargetPid = 0
    $CurrentId = $PID
    $FoundClaude = $false
    
    for ($i=0; $i -lt 10; $i++) {
        try {
            $Proc = Get-Process -Id $CurrentId -ErrorAction Stop
            $Name = $Proc.ProcessName
            
            # Detect Claude Process in the chain
            if ($Name -match "^(claude|node|claude-code)$") {
                $FoundClaude = $true
            }
            
            # Match common shells
            if ($Name -match "^(cmd|pwsh|powershell|bash)$") {
                if ($FoundClaude) {
                    $TargetPid = $Proc.Id
                    Write-DebugLog "Launcher: Found Interactive Shell L$i '$Name' (PID: $TargetPid)"
                    break
                } else {
                    Write-DebugLog "Launcher: Skipping Runner Shell L$i '$Name' (PID: $($Proc.Id))"
                }
            }
            
            # P/Invoke Walk Up (Extremely Fast)
            $ParentId = [WinApiConsole]::GetParentPid($CurrentId)
            if ($ParentId -le 0) { break }
            $CurrentId = $ParentId
        } catch { break }
    }
    
    # Fallback: If we walked all the way matching logic failed, try the highest non-runner shell?
    # For now, let's trust the FoundClaude logic. If User runs hook manually, this skips L1.
    
    # C. Injection
    if ($TargetPid -gt 0) {
        # 1. Detach from current invisible console
        [WinApiConsole]::FreeConsole() | Out-Null
        
        # 2. Attach to the Target Shell's console
        if ([WinApiConsole]::AttachConsole($TargetPid)) {
            
            # 3. DUAL INJECTION STRATEGY
            # Method A: Native Console Title (Updates internal buffer)
            try { [Console]::Title = $ProjectName } catch {}

            # Method B: OSC Sequence (Updates Terminal Tab)
            $Osc = "$([char]27)]0;$ProjectName$([char]7)"
            [Console]::Write($Osc)
            try { [Console]::Out.Flush() } catch {}

            Write-DebugLog "Launcher: Injected Title '$ProjectName' (Method A+B) into PID $TargetPid"
             
            # 4. Detach again
            [WinApiConsole]::FreeConsole() | Out-Null
        } else {
             Write-DebugLog "Launcher: Failed to AttachConsole (Error: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
    } else {
        Write-DebugLog "Launcher: No suitable Interactive Shell found (FoundClaude=$FoundClaude)."
    }

} catch {
    Write-DebugLog "Launcher Injection Error: $_"
}

# 4. Extract other basic info
if ($Payload.notification_type) { $NotificationType = $Payload.notification_type }
if ($Payload.title) { $Title = $Payload.title }
if ($Payload.message) { $Message = $Payload.message }

# 5. Prepare Worker Arguments
$B64Title = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Title))
$B64Message = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Message))
$EncProject = [Uri]::EscapeDataString($ProjectName)

$TranscriptArg = ""
if ($Payload.transcript_path) {
    $EncTranscript = [Uri]::EscapeDataString($Payload.transcript_path)
    $TranscriptArg = "-TranscriptPath `"$EncTranscript`""
}

$DebugArg = ""
if ($EnableDebug) { $DebugArg = "-EnableDebug" }

# Robust Module Path Discovery
$ModuleArg = ""
$BT = $null
# 1. Try ListAvailable
$BT = Get-Module -ListAvailable BurntToast | Select-Object -First 1
# 2. If not found, Manual Search (User fix)
if (-not $BT) {
    $SearchPaths = $env:PSModulePath -split ';'
    # Force check User Documents paths (often missing in limited environments)
    $SearchPaths += "$env:USERPROFILE\Documents\WindowsPowerShell\Modules"
    $SearchPaths += "$env:USERPROFILE\OneDrive\Documents\WindowsPowerShell\Modules"
    
    foreach ($p in $SearchPaths) {
        $Possible = Join-Path $p "BurntToast"
        if (Test-Path $Possible) {
             # Check for any .psd1
             $Manifest = Get-ChildItem $Possible -Recurse -Filter "*.psd1" | Select-Object -First 1
             if ($Manifest) { $BT = [PSCustomObject]@{ ModuleBase = $Manifest.DirectoryName }; break }
        }
    }
}
if ($BT) { $ModuleArg = "-ModulePath `"$($BT.ModuleBase)`"" }

$DelayArg = ""
if ($Delay -gt 0) { $DelayArg = "-Delay $Delay" }

$TargetPidArg = ""
if ($TargetPid -gt 0) { $TargetPidArg = "-TargetPid $TargetPid" }

$Self = $MyInvocation.MyCommand.Path

# 6. Launch Worker (Fast - Fire and Forget)
$WorkerProc = Start-Process "pwsh" -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Self`" -Worker -Base64Title `"$B64Title`" -Base64Message `"$B64Message`" -ProjectName `"$EncProject`" -NotificationType `"$NotificationType`" -AudioPath `"$AudioPath`" $ModuleArg $TranscriptArg $DebugArg $DelayArg $TargetPidArg"


if ($Wait) {
    # Blocking Mode (Wait for Worker) with Safety Timeout
    if ($WorkerProc) {
        # Wait up to 30 seconds (or Delay + 10s buffer)
        $Timeout = if ($Delay -gt 0) { ($Delay * 1000) + 10000 } else { 30000 }
        
        $Exited = $WorkerProc.WaitForExit($Timeout)
        if (-not $Exited) {
            Write-Warning "Worker process timed out (PID: $($WorkerProc.Id))."
        }
    }
}

exit 0
