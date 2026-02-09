param([string]$UriArgs)

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
        if ([WinApi]::IsIconic($HwndArg)) {
            [WinApi]::ShowWindow($HwndArg, 9) # SW_RESTORE
        }
        $Success = [WinApi]::SetForegroundWindow($HwndArg)
        Write-DebugLog "PROTOCOL: SetForegroundWindow(HWND) -> $Success"
    }
    
    # Strategy B: PID (Process)
    elseif ($PidArg -ne 0) {
        Write-DebugLog "PROTOCOL: Target PID $PidArg"
        $Proc = Get-Process -Id $PidArg -ErrorAction SilentlyContinue
        
        if ($Proc -and $Proc.MainWindowHandle -ne [IntPtr]::Zero) {
            # Try Main Window Handle
            if ([WinApi]::IsIconic($Proc.MainWindowHandle)) {
                [WinApi]::ShowWindow($Proc.MainWindowHandle, 9)
            }
            $Success = [WinApi]::SetForegroundWindow($Proc.MainWindowHandle)
            Write-DebugLog "PROTOCOL: SetForegroundWindow(PID_Handle) -> $Success"
        }
        
        # Fallback: AppActivate (Legacy but robust for some apps)
        if (-not $Success) {
            Write-DebugLog "PROTOCOL: Trying fallback AppActivate($PidArg)..."
            $wshell = New-Object -ComObject WScript.Shell
            if ($wshell.AppActivate($PidArg)) { 
                $Success = $true 
                Write-DebugLog "PROTOCOL: AppActivate Success."
            }
        }
    }
    
    # Strategy C: Window Title (Search)
    elseif (-not [string]::IsNullOrWhiteSpace($WindowTitle)) {
        Write-DebugLog "PROTOCOL: Searching Title '$WindowTitle'"
        
        # Find Process (Priority: Exact > Partial, Non-Explorer)
        $Proc = Get-Process | Where-Object { $_.MainWindowTitle -eq $WindowTitle -and $_.ProcessName -ne "explorer" } | Select-Object -First 1
        if (-not $Proc) {
            $Proc = Get-Process | Where-Object { $_.MainWindowTitle -like "*$WindowTitle*" -and $_.ProcessName -ne "explorer" } | Select-Object -First 1
        }
        
        if ($Proc) {
            Write-DebugLog "PROTOCOL: Found $($Proc.ProcessName) ($($Proc.Id))"
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
    }

    # 3. Action Logic (Button Click)
    if ($UriArgs -match "button=1") {
        Write-DebugLog "PROTOCOL: Action 'Allow' detected. Sending '1'..."
        Start-Sleep -Milliseconds 250 # Wait for focus
        $wshell = New-Object -ComObject WScript.Shell
        $wshell.SendKeys("1")
    }

} catch {
    Write-DebugLog "PROTOCOL ERROR: $_"
}
