# register-protocol.ps1 - 注册 claude-runner:// URI 协议
# 运行一次即可，将协议处理器注册到 Windows 注册表

$ProtocolName = "claude-runner"
$VbsPath = "$env:USERPROFILE\.claude\hooks\notification-system\runner.vbs"

# Registry Keys
$HKCU = "HKCU:\Software\Classes"
$ProtoKey = "$HKCU\$ProtocolName"
$CommandKey = "$ProtoKey\shell\open\command"

Write-Host "Registering $ProtocolName -> $VbsPath" -ForegroundColor Cyan

# 1. Base Key
if (-not (Test-Path $ProtoKey)) { New-Item -Path $ProtoKey -Force | Out-Null }
Set-ItemProperty -Path $ProtoKey -Name "(default)" -Value "URL:Claude Runner Protocol"
Set-ItemProperty -Path $ProtoKey -Name "URL Protocol" -Value ""

# 2. Command Key
if (-not (Test-Path $CommandKey)) { New-Item -Path $CommandKey -Force | Out-Null }

# 3. Command Value
$CommandVal = "`"wscript.exe`" `"$VbsPath`" `"%1`""
Set-ItemProperty -Path $CommandKey -Name "(default)" -Value $CommandVal

Write-Host "Registered!" -ForegroundColor Green
