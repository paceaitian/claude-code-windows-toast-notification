# Toast.ps1 - Windows Toast 通知发送模块
# 使用 BurntToast 模块显示富文本通知，支持按钮交互和自定义音频

<#
.SYNOPSIS
    发送 Claude 通知到 Windows Toast

.PARAMETER Title
    通知标题（通常是用户问题）

.PARAMETER ToolInfo
    工具调用信息（如 "[Bash] ls -la"）

.PARAMETER Description
    描述文本（助手回复内容）

.PARAMETER ProjectName
    项目名称（用于点击跳转）

.PARAMETER AudioPath
    自定义音频文件路径

.PARAMETER NotificationType
    通知类型（如 'permission_prompt'）

.PARAMETER ModulePath
    BurntToast 模块路径（可选）

.PARAMETER TargetPid
    目标进程 ID（用于点击跳转）
#>
function Send-ClaudeToast {
    param(
        [string]$Title,
        [string]$ToolInfo,
        [string]$Description,
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
        Write-Host "[$ProjectName] $Title - $ToolInfo $Description"
        return
    }

    Write-DebugLog "Toast: Title='$Title' ToolInfo='$ToolInfo'"

    # 2. Construct URI
    $LaunchUri = "claude-runner:focus?windowtitle=$([Uri]::EscapeDataString($ProjectName))"
    if ($TargetPid -gt 0) { $LaunchUri += "&pid=$TargetPid" }
    if ($NotificationType) { $LaunchUri += "&notification_type=$NotificationType" }

    # 3. Audio Logic
    $FinalSoundPath = $null
    $PermissionAudioPath = $Script:CONFIG_PERMISSION_AUDIO_PATH
    if (-not $PermissionAudioPath) { $PermissionAudioPath = "$env:USERPROFILE\OneDrive\Aurora.wav" }

    if ($AudioPath -and (Test-Path $AudioPath)) {
        $FinalSoundPath = $AudioPath
    } elseif ($NotificationType -eq 'permission_prompt') {
        if (Test-Path $PermissionAudioPath) { $FinalSoundPath = $PermissionAudioPath }
    }

    try {
        # 4. Build Text Elements (三层显示：标题 + 工具信息 + 描述)
        $TitleMaxLines = $Script:CONFIG_TOAST_TITLE_MAX_LINES
        $ToolMaxLines = $Script:CONFIG_TOAST_TOOL_MAX_LINES
        $MsgMaxLines = $Script:CONFIG_TOAST_MESSAGE_MAX_LINES
        if (-not $TitleMaxLines) { $TitleMaxLines = 1 }
        if (-not $ToolMaxLines) { $ToolMaxLines = 1 }
        if (-not $MsgMaxLines) { $MsgMaxLines = 2 }

        $Text1 = New-BTText -Text $Title -MaxLines $TitleMaxLines

        $Children = @($Text1)

        # 工具信息行（截断显示，悬停完整）
        if ($ToolInfo) {
            $Text2 = New-BTText -Text $ToolInfo -MaxLines $ToolMaxLines -Wrap
            $Children += $Text2
        }

        # 描述行（截断显示，悬停完整）
        if ($Description) {
            $Text3 = New-BTText -Text $Description -MaxLines $MsgMaxLines -Wrap
            $Children += $Text3
        }

        # Logo
        $LogoPath = $Script:CONFIG_LOGO_PATH
        if (-not $LogoPath) { $LogoPath = "$env:USERPROFILE\.claude\assets\claude-logo.png" }
        $Img = if (Test-Path $LogoPath) { New-BTImage -Source $LogoPath -AppLogoOverride -Crop Circle } else { $null }

        $Binding = if ($Img) { New-BTBinding -Children $Children -AppLogoOverride $Img } else { New-BTBinding -Children $Children }
        $Visual = New-BTVisual -BindingGeneric $Binding

        # 5. Buttons
        $Buttons = @()
        $DismissBtn = New-BTButton -Content 'Dismiss' -Dismiss

        if ($NotificationType -eq 'permission_prompt') {
            $ApproveBtn = New-BTButton -Content 'Proceed' -Arguments "action=approve&pid=$TargetPid" -ActivationType Protocol
            $Buttons += $ApproveBtn
        }

        $Buttons += $DismissBtn
        $Actions = New-BTAction -Buttons $Buttons

        # 6. Audio Configuration
        $Audio = if ($FinalSoundPath) { New-BTAudio -Silent } else { New-BTAudio -Source 'ms-winsoundevent:Notification.Default' }

        # 7. Submit Notification
        $Content = New-BTContent -Visual $Visual -Actions $Actions -Audio $Audio `
            -ActivationType Protocol -Launch $LaunchUri -Scenario Reminder

        Submit-BTNotification -Content $Content

        # 8. Play Custom Sound (异步播放，不阻塞通知显示)
        if ($FinalSoundPath) {
            try {
                $Player = New-Object System.Media.SoundPlayer $FinalSoundPath
                # 使用异步播放，让音频在后台播放
                # 注意：不使用 PlaySync() 是因为不想阻塞通知流程
                # Dispose 会在 GC 时自动调用，这里不立即 Dispose 以确保音频播放完成
                $Player.Play()
            } catch { Write-DebugLog "Sound Play Error: $_" }
        }
    } catch { Write-DebugLog "Toast Error: $_" }
}
