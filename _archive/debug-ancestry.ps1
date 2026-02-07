$CurrentPid = $PID
Write-Host "Current PID: $CurrentPid"

function Get-Proc($Id) {
    return Get-CimInstance Win32_Process -Filter "ProcessId = $Id"
}

# 1. Inspect Ancestry
$Shell = Get-Proc $CurrentPid
Write-Host "Shell: $($Shell.Name) ($($Shell.ProcessId)) -> Parent: $($Shell.ParentProcessId)"

$Parent = Get-Proc $Shell.ParentProcessId
if ($Parent) {
    Write-Host "Parent: $($Parent.Name) ($($Parent.ProcessId)) -> Parent: $($Parent.ParentProcessId)"
    
    $GrandParent = Get-Proc $Parent.ParentProcessId
    if ($GrandParent) {
        Write-Host "GrandParent: $($GrandParent.Name) ($($GrandParent.ProcessId))"
        
        # 2. Inspect Siblings (Children of GrandParent)
        Write-Host "`nChildren of GrandParent ($($GrandParent.ProcessId)):"
        
        $Siblings = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($GrandParent.ProcessId)"
        foreach ($s in $Siblings) {
            $IsMatch = if ($s.ProcessId -eq $Parent.ProcessId) { "<-- MATCH PARENT" } else { "" }
            Write-Host "  - $($s.Name) ($($s.ProcessId)) Created: $($s.CreationDate) $IsMatch"
        }
    } else {
        Write-Host "GrandParent not found!"
    }
} else {
    Write-Host "Parent not found!"
}

# 3. Check for Direct Children of Terminal (Newer Architecture?)
# Try finding WindowsTerminal process
$Term = Get-Process -Name "WindowsTerminal" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($Term) {
    Write-Host "`nDirect Children of WindowsTerminal ($($Term.Id)):"
    $TermChildren = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($Term.Id)"
    foreach ($c in $TermChildren) {
         Write-Host "  - $($c.Name) ($($c.ProcessId))"
    }
}
