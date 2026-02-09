param([string]$UriArgs)

$Log = "$env:USERPROFILE\.claude\protocol_debug.log"
function Log($Msg) { "$((Get-Date).ToString('HH:mm:ss')) $Msg" | Out-File $Log -Append -Encoding UTF8 }

Log "Triggered: $UriArgs"

try {
    # Parse HWND (Direct Handle)
    $HwndArg = 0
    if ($UriArgs -match "hwnd=(\d+)") {
        try { $HwndArg = [IntPtr]::new([long]$Matches[1]) } catch {}
    }

    # Parse PID (Robust Process Activation)
    $PidArg = 0
    if ($UriArgs -match "pid=(\d+)") {
        try { $PidArg = [int]$Matches[1] } catch {}
    }

    # Parse windowtitle (Fallback)
    $WindowTitle = $null
    if ($UriArgs -match "windowtitle=([^&]+)") {
        $WindowTitle = [Uri]::UnescapeDataString($Matches[1])
    }
    
    if ($HwndArg -ne 0) {
        # ... (Existing HWND logic)
        Log "Target HWND: $HwndArg"
        # ...
    } elseif ($PidArg -ne 0) {
        Log "Target PID: $PidArg"
        try {
            # Method 1: Modern P/Invoke (Works for Windows Terminal)
            Add-Type @"
                using System;
                using System.Runtime.InteropServices;
                public class WinApi {
                    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
                    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
                    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
                    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
                }
"@ 
            $Proc = Get-Process -Id $PidArg -ErrorAction SilentlyContinue
            $Success = $false

            if ($Proc -and $Proc.MainWindowHandle -ne [IntPtr]::Zero) {
                 [WinApi]::SetForegroundWindow($Proc.MainWindowHandle) | Out-Null
                 Log "SetForegroundWindow(ProcHandle) Executed."
                 $Success = $true
            }

            # Method 2: Legacy AppActivate (Fallback for old conhost)
            if (-not $Success) {
                 Log "Main Window handle not found/valid. Trying legacy AppActivate..."
                 $wshell = New-Object -ComObject WScript.Shell
                 if ($wshell.AppActivate($PidArg)) {
                     Log "AppActivate(PID) Success!"
                 } else {
                     Log "AppActivate(PID) Failed."
                 }
            }
        } catch { Log "PID Activation Error: $_" }

    } elseif (-not [string]::IsNullOrWhiteSpace($WindowTitle)) {
        Log "Target HWND: $HwndArg"
        # Method 1a: Direct HWND Focus
        Add-Type @"
        using System;
        using System.Runtime.InteropServices;
        public class WinApi {
            [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
            [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
            [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        }
"@
        if ([WinApi]::IsIconic($HwndArg)) {
            [WinApi]::ShowWindow($HwndArg, 9) # SW_RESTORE
            Log "Restored minimized window."
        }
        $Success = [WinApi]::SetForegroundWindow($HwndArg)
        if ($Success) { Log "SetForegroundWindow(HWND) Success!" } else { Log "SetForegroundWindow(HWND) Failed." }

    } elseif (-not [string]::IsNullOrWhiteSpace($WindowTitle)) {
        Log "Target Title: '$WindowTitle'"
        
        # Method 1b: Find Process by Title (Excluding Explorer!)
        Add-Type @"
        using System;
        using System.Runtime.InteropServices;
        public class WinApi {
            [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
            [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
            [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        }
"@
        # Priority 1: Exact Match (Non-Explorer)
        $Proc = Get-Process | Where-Object { $_.MainWindowTitle -eq $WindowTitle -and $_.ProcessName -ne "explorer" } | Select-Object -First 1
        
        # Priority 2: Partial Match (Non-Explorer)
        if (-not $Proc) {
            $Proc = Get-Process | Where-Object { $_.MainWindowTitle -like "*$WindowTitle*" -and $_.ProcessName -ne "explorer" } | Select-Object -First 1
        }
        
        if ($Proc) {
            Log "Found Process: $($Proc.ProcessName) (PID: $($Proc.Id))"
            $Handle = $Proc.MainWindowHandle
            
            if ([WinApi]::IsIconic($Handle)) {
                [WinApi]::ShowWindow($Handle, 9)
                Log "Restored minimized window."
            }
            
            $Success = [WinApi]::SetForegroundWindow($Handle)
            if ($Success) {
                Log "SetForegroundWindow Success!"
            } else {
                Log "SetForegroundWindow Failed. Falling back to AppActivate..."
                $wshell = New-Object -ComObject WScript.Shell
                $wshell.AppActivate($Proc.Id) 
            }
        } else {
            Log "Process not found for title: $WindowTitle"
        }

    } else {
        Log "No HWND or windowtitle found in URI."
    }

    if ($UriArgs -match "button=1") {
        Log "Action: User clicked 'Allow' - Sending Input '1'..."
        try {
            # Safety delay to ensure focus has settled
            Start-Sleep -Milliseconds 200
            $wshell = New-Object -ComObject WScript.Shell
            $wshell.SendKeys("1")
            Log "Input sent."
        } catch {
            Log "SendKeys Error: $_"
        }
    }

} catch {
    Log "Error: $_"
}
