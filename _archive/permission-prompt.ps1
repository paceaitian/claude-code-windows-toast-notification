param(
    [string]$Title = "Permission Request",
    [string]$Message = "Claude Code needs your permission to execute a command.",
    [string]$AudioPath = "C:\Users\Xiao\OneDrive\Aurora.wav",
    [switch]$AutoInput,
    [int]$Delay = 0,
    [string]$PayloadPath = "",
    [long]$ParentWindow = 0,
    [int]$TargetPid = 0
)

# --- 0. Load Dependencies First ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- 1. Define Helper Types ---
$Source = @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClaudeUtils {
    public class WindowWrapper : IWin32Window {
        private IntPtr _handle;
        public WindowWrapper(IntPtr handle) { _handle = handle; }
        public IntPtr Handle { get { return _handle; } }
    }

    public static class NativeMethods {
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();
        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [DllImport("user32.dll")]
        public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("user32.dll")]
        public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, uint dwExtraInfo);
    }
}
"@
Add-Type -TypeDefinition $Source -ReferencedAssemblies System.Windows.Forms

# --- 2. Fast Hide Self ---
$ConsoleHwnd = [ClaudeUtils.NativeMethods]::GetConsoleWindow()
if ($ConsoleHwnd -ne [IntPtr]::Zero) {
    [ClaudeUtils.NativeMethods]::ShowWindow($ConsoleHwnd, 0) # SW_HIDE
}

# --- 3. Smart Delay ---
$DebugLog = "$env:USERPROFILE\.claude\permission_debug.log"
"--- Run $(Get-Date) | Parent: $ParentWindow ---" | Out-File $DebugLog -Append -Encoding UTF8

if ($PayloadPath -and (Test-Path $PayloadPath)) {
    try {
        $JsonContent = Get-Content $PayloadPath -Raw -Encoding UTF8
        $Payload = $JsonContent | ConvertFrom-Json
        if ($Payload.message) { $Message = $Payload.message }
        
        if ($Delay -gt 0 -and $Payload.transcript_path) {
             $TranscriptPath = $Payload.transcript_path
             if (Test-Path $TranscriptPath) {
                 Start-Sleep -Seconds 1
                 $InitialTime = (Get-Item $TranscriptPath).LastWriteTime
                 Start-Sleep -Seconds $Delay
                 
                 $CurrentTime = (Get-Item $TranscriptPath).LastWriteTime
                 if ($CurrentTime -gt $InitialTime) {
                     "Activity detected. Exit." | Out-File $DebugLog -Append -Encoding UTF8
                     Remove-Item $PayloadPath -Force -ErrorAction SilentlyContinue
                     exit 0
                 }
             } else { Start-Sleep -Seconds $Delay }
        } elseif ($Delay -gt 0) { Start-Sleep -Seconds $Delay }
    } catch {
        "Error: $_" | Out-File $DebugLog -Append -Encoding UTF8
    }
    Remove-Item $PayloadPath -Force -ErrorAction SilentlyContinue

} elseif ($Delay -gt 0) {
    Start-Sleep -Seconds $Delay
}

# --- 4. UI Construction ---
$ColorBg     = [System.Drawing.Color]::FromArgb(255, 30, 30, 30)
$ColorText   = [System.Drawing.Color]::FromArgb(255, 240, 240, 240)
$ColorAccent = [System.Drawing.Color]::FromArgb(255, 217, 119, 87)
$ColorBtn    = [System.Drawing.Color]::FromArgb(255, 50, 50, 50)
$FontMain    = New-Object System.Drawing.Font("Segoe UI", 10)
$FontTitle   = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)

$Form = New-Object System.Windows.Forms.Form
$Form.Text = $Title
$Form.Size = New-Object System.Drawing.Size(460, 220)
$Form.StartPosition = "CenterScreen"
$Form.FormBorderStyle = "FixedDialog"
$Form.MaximizeBox = $false
$Form.MinimizeBox = $false
$Form.TopMost = $true
$Form.BackColor = $ColorBg
$Form.ForeColor = $ColorText
$Form.ShowIcon = $false

$LblTitle = New-Object System.Windows.Forms.Label
$LblTitle.Text = $Title
$LblTitle.Font = $FontTitle
$LblTitle.Location = New-Object System.Drawing.Point(20, 20)
$LblTitle.AutoSize = $true
$Form.Controls.Add($LblTitle)

$LblMessage = New-Object System.Windows.Forms.Label
$LblMessage.Text = $Message
$LblMessage.Font = $FontMain
$LblMessage.Location = New-Object System.Drawing.Point(20, 55)
$LblMessage.Size = New-Object System.Drawing.Size(410, 60)
$Form.Controls.Add($LblMessage)

$BtnView = New-Object System.Windows.Forms.Button
$BtnView.Text = "View (Enter)"
$BtnView.Font = $FontMain
$BtnView.Size = New-Object System.Drawing.Size(110, 35)
$BtnView.Location = New-Object System.Drawing.Point(320, 130)
$BtnView.FlatStyle = "Flat"
$BtnView.BackColor = $ColorAccent
$BtnView.ForeColor = [System.Drawing.Color]::White
$BtnView.FlatAppearance.BorderSize = 0
$BtnView.Cursor = [System.Windows.Forms.Cursors]::Hand
$BtnView.DialogResult = [System.Windows.Forms.DialogResult]::OK
$Form.Controls.Add($BtnView)

$BtnDismiss = New-Object System.Windows.Forms.Button
$BtnDismiss.Text = "Dismiss (Esc)"
$BtnDismiss.Font = $FontMain
$BtnDismiss.Size = New-Object System.Drawing.Size(110, 35)
$BtnDismiss.Location = New-Object System.Drawing.Point(200, 130)
$BtnDismiss.FlatStyle = "Flat"
$BtnDismiss.BackColor = $ColorBtn
$BtnDismiss.ForeColor = $ColorText
$BtnDismiss.FlatAppearance.BorderSize = 0
$BtnDismiss.Cursor = [System.Windows.Forms.Cursors]::Hand
$BtnDismiss.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$Form.Controls.Add($BtnDismiss)

$Form.AcceptButton = $BtnView
$Form.CancelButton = $BtnDismiss

# --- 5. Show & Activation ---
# Play sound
if ($AudioPath -and (Test-Path $AudioPath)) {
    try { (New-Object System.Media.SoundPlayer($AudioPath)).Play() } catch {}
} else {
    [System.Media.SystemSounds]::Exclamation.Play()
}

$Result = $null

# Prepare Owner Wrapper
# SIMPLIFIED: No Owner Wrapper to avoid double-dialogs and focus deadlocks.
# Just a simple TopMost dialog.
$Form.TopMost = $true
$Form.Activate()
$Result = $Form.ShowDialog()

# --- 6. Auto Input with "Force Foreground" Strategy ---
    # --- 6. Handle Response (Focus vs Dismiss) ---
if ($Result -eq [System.Windows.Forms.DialogResult]::OK) {
    # USER CLICKED "VIEW" -> FORCE FOCUS
    
    "Attempting Focus." | Out-File $DebugLog -Append -Encoding UTF8

    try {
        # Define AllowSetForegroundWindow
        $ASFW_Signature = @"
[DllImport("user32.dll")]
public static extern bool AllowSetForegroundWindow(int dwProcessId);
"@
        if (-not ([System.Management.Automation.PSTypeName]'Win32.NativeMethods_ASFW').Type) {
            Add-Type -MemberDefinition $ASFW_Signature -Name NativeMethods_ASFW -Namespace Win32
        }

        # Allow ANY process to steal focus (ASFW_ANY = -1)
        [Win32.NativeMethods_ASFW]::AllowSetForegroundWindow(-1)
        
        $wshell = New-Object -ComObject WScript.Shell
        
        # Priority 1: PID-based Activation (Most Reliable for specific shells)
        if ($TargetPid -gt 0) {
            "Activating PID: $TargetPid" | Out-File $DebugLog -Append -Encoding UTF8
            
            # 1. Try AppActivate
            $success = $wshell.AppActivate($TargetPid)
            
            if ($success) { 
                "PID Activation Success" | Out-File $DebugLog -Append -Encoding UTF8
                # Even if successful, force a Restore just in case it's minimized
                # We don't have the handle easily here without more P/Invoke, but AppActivate usually restores.
                exit 0
            }
            "PID Activation Failed. Trying Handle..." | Out-File $DebugLog -Append -Encoding UTF8
        }
        
        # Priority 2: Handle-based Activation (Legacy/Fallback)
        if ($ParentWindow -ne 0) {
            $HwndPtr = [IntPtr]$ParentWindow
            
            # P/Invoke Fallback with SwitchToThisWindow (often bypasses restrictions)
            "Trying SwitchToThisWindow for Handle: $HwndPtr" | Out-File $DebugLog -Append -Encoding UTF8
            [ClaudeUtils.NativeMethods]::SwitchToThisWindow($HwndPtr, $true)
            [ClaudeUtils.NativeMethods]::SetForegroundWindow($HwndPtr)
        }
    } catch {
        "Focus Error: $_" | Out-File $DebugLog -Append -Encoding UTF8
    }
} else {
    # USER CLICKED "DISMISS" -> DO NOTHING
    "Dismissed by user." | Out-File $DebugLog -Append -Encoding UTF8
}

exit 0
