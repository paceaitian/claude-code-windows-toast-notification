function Send-ClaudeToast {
    param(
        [string]$Title,
        [string]$Message,
        [string]$ProjectName,
        [string]$AudioPath,
        [string]$NotificationType,
        [string]$ModulePath,
        [int]$TargetPid
    )

    # 1. Load BurntToast
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

    if (-not (Get-Module BurntToast)) {
        Write-DebugLog "BurntToast not found. Text-only fallback."
        Write-Host "[$ProjectName] $Title - $Message"
        return
    }

    # 2. Construct URI
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
}
