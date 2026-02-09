
# Protocol Name: claude-runner
# Usage: claude-runner:focus?pid=1234&hwnd=5678&beacon=abcd

$ProtocolName = "claude-runner"
$HandlerScript = "$env:USERPROFILE\.claude\hooks\protocol-handler.ps1"
$PwshPath = (Get-Command pwsh).Source

# Registry Keys
$HKCU = "HKCU:\Software\Classes"
$ProtoKey = "$HKCU\$ProtocolName"
$CommandKey = "$ProtoKey\shell\open\command"

Write-Host "Creating Protocol Handler: $ProtocolName" -ForegroundColor Cyan

# 1. Base Key
if (-not (Test-Path $ProtoKey)) { New-Item -Path $ProtoKey -Force | Out-Null }
Set-ItemProperty -Path $ProtoKey -Name "(default)" -Value "URL:Claude Runner Protocol"
Set-ItemProperty -Path $ProtoKey -Name "URL Protocol" -Value ""

# 2. Command Key
if (-not (Test-Path $CommandKey)) { New-Item -Path $CommandKey -Force | Out-Null }

# 3. Connector Command
# We verify the script exists, if not create a dummy one
if (-not (Test-Path $HandlerScript)) {
    New-Item -Path $HandlerScript -ItemType File -Force -Value "# Placeholder" | Out-Null
}

$VbsPath = "$env:USERPROFILE\.claude\hooks\runner.vbs"
$CommandVal = "`"wscript.exe`" `"$VbsPath`" `"%1`""
Set-ItemProperty -Path $CommandKey -Name "(default)" -Value $CommandVal

Write-Host "✅ Protocol Registered: $ProtocolName" -ForegroundColor Green
Write-Host "Target Script: $VbsPath (Silent VBS)" -ForegroundColor Gray
