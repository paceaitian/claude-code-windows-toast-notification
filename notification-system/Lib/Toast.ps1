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
        Write-DebugLog "BurntToast not found. Text-only fallback. Cost=$Cost Duration=$Duration"
        Write-Host "[$ProjectName] $Title - $Message"
        return
    }

    Write-DebugLog "Toast: Title='$Title'"

    # 2. Construct URI
    $LaunchUri = "claude-runner:focus?windowtitle=$([Uri]::EscapeDataString($ProjectName))"
    if ($TargetPid -gt 0) { $LaunchUri += "&pid=$TargetPid" }
    if ($NotificationType) { $LaunchUri += "&notification_type=$NotificationType" }

    # 3. Audio Logic
    # Priority: Explicit AudioPath > Permission Prompt (Aurora) > Default Silent (controlled by BurntToast)
    $FinalSoundPath = $null

    if ($AudioPath -and (Test-Path $AudioPath)) {
        $FinalSoundPath = $AudioPath
    } elseif ($NotificationType -eq 'permission_prompt') {
        $AuroraPath = "$env:USERPROFILE\OneDrive\Aurora.wav"
        if (Test-Path $AuroraPath) { $FinalSoundPath = $AuroraPath }
    }

    try {
        $Text1 = New-BTText -Text $Title
        $Text2 = New-BTText -Text $Message
        $Logo = "$env:USERPROFILE\.claude\assets\claude-logo.png"
        $Img = if (Test-Path $Logo) { New-BTImage -Source $Logo -AppLogoOverride -Crop Circle } else { $null }
        
        $Children = @($Text1, $Text2)
        $Binding = if ($Img) { New-BTBinding -Children $Children -AppLogoOverride $Img } else { New-BTBinding -Children $Children }
        $Visual = New-BTVisual -BindingGeneric $Binding

        # Buttons
        $Buttons = @()

        # 4. Buttons (ALWAYS include Dismiss for Persistence)
        $DismissBtn = New-BTButton -Content 'Dismiss' -Dismiss
        
        if ($NotificationType -eq 'permission_prompt') {
            # Use specific button ID for protocol handler to recognize
            $ApproveBtn = New-BTButton -Content 'Proceed' -Arguments "action=approve&pid=$TargetPid" -ActivationType Protocol
            $Buttons += $ApproveBtn
        }
        
        $Buttons += $DismissBtn
        $Actions = New-BTAction -Buttons $Buttons

        # Audio Configuration
        $Audio = if ($FinalSoundPath) { New-BTAudio -Silent } else { New-BTAudio -Source 'ms-winsoundevent:Notification.Default' }

        $Content = New-BTContent -Visual $Visual -Actions $Actions -Audio $Audio `
            -ActivationType Protocol -Launch $LaunchUri -Scenario Reminder

        Submit-BTNotification -Content $Content
        
        # Play Custom Sound
        if ($FinalSoundPath) {
            $Player = New-Object System.Media.SoundPlayer $FinalSoundPath
            $Player.Play() # Async play
        }
    } catch { Write-DebugLog "Toast Error: $_" }

}
