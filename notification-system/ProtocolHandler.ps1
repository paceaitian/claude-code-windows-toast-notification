# ProtocolHandler.ps1 - URI 协议处理器
# 响应 claude-runner:// 协议，激活窗口并处理按钮动作

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

    # Strategy B: PID (Process)
    elseif ($PidArg -ne 0) {
        Write-DebugLog "PROTOCOL: Target PID $PidArg"
        $Proc = Get-Process -Id $PidArg -ErrorAction SilentlyContinue

        if ($Proc -and $Proc.MainWindowHandle -ne [IntPtr]::Zero) {
            if ([WinApi]::IsIconic($Proc.MainWindowHandle)) {
                [WinApi]::ShowWindow($Proc.MainWindowHandle, 9)
            }
            $Success = [WinApi]::SetForegroundWindow($Proc.MainWindowHandle)
            Write-DebugLog "PROTOCOL: SetForegroundWindow(PID_Handle) -> $Success"
        }

        # Fallback: AppActivate
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

    # 3. Action Logic (Button Click) - 修复：匹配 action=approve
    if ($UriArgs -match "action=approve") {
        Write-DebugLog "PROTOCOL: Action 'Approve' detected."

        $SendKeysDelay = $Script:CONFIG_SENDKEYS_DELAY_MS
        if (-not $SendKeysDelay) { $SendKeysDelay = 250 }
        Start-Sleep -Milliseconds $SendKeysDelay

        # 验证当前窗口是否正确（双重验证减少竞态条件）
        if ($WindowTitle) {
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
