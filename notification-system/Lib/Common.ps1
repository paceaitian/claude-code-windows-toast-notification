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
