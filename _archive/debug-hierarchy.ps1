$Id = $PID
Write-Host "Current PID: $Id"

function Get-ProcDetails($Pid) {
    try {
        $P = Get-CimInstance Win32_Process -Filter "ProcessId = $Pid"
        Write-Host "  Process: $($P.Name) ($Pid)"
        Write-Host "  Created: $($P.CreationDate)"
        Write-Host "  Parent:  $($P.ParentProcessId)"
        return $P.ParentProcessId
    } catch { return 0 }
}

$Parent = Get-ProcDetails $Id
if ($Parent) {
    $Grand = Get-ProcDetails $Parent
    if ($Grand) {
        Get-ProcDetails $Grand
    }
}
