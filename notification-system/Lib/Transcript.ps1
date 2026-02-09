function Get-ClaudeTranscriptInfo {
    param(
        [string]$TranscriptPath,
        [string]$ProjectName
    )

    $Result = @{
        Title = $null
        Message = "Task finished."
        NotificationType = $null
    }

    if (-not ($TranscriptPath -and (Test-Path $TranscriptPath))) { return $Result }

    try {
        $TranscriptLines = Get-Content $TranscriptPath -Tail 50 -Encoding UTF8 -ErrorAction Stop
        
        $ResponseTime = ""
        $ToolUseInfo = $null
        $TextMessage = $null
        
        # 1. Extract Last Assistant Message
        for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
            $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
            try {
                $Entry = $Line | ConvertFrom-Json
                
                # STOP if User Message found
                if ($Entry.type -eq 'user' -and $Entry.message) { break }

                if ($Entry.type -eq 'assistant' -and $Entry.message) { $Content = $Entry.message.content } elseif ($Entry.type -eq 'message' -and $Entry.role -eq 'assistant') { $Content = $Entry.content } else { $Content = $null }
                
                if ($Content) {
                    if ($Entry.timestamp -and -not $ResponseTime) {
                        try { $ResponseTime = [DateTime]::Parse($Entry.timestamp).ToLocalTime().ToString("HH:mm") } catch {}
                    }

                    # Tool Info
                    $ToolUse = $Content | Where-Object { $_.type -eq 'tool_use' } | Select-Object -First 1
                    if ($ToolUse) {
                        $ToolName = $ToolUse.name
                        $ToolInput = $ToolUse.input
                        
                        $Detail = ""; $Description = ""
                        if ($ToolInput.description) { $Description = $ToolInput.description }
                        
                        if ($ToolName -match "^Bash$") { if ($ToolInput.command) { $Detail = $ToolInput.command } }
                        elseif ($ToolName -match "^(Read|Write|Edit)$") { if ($ToolInput.file_path) { $Detail = "$ToolName " + $ToolInput.file_path } }
                        elseif ($ToolName -match "Search") { if ($ToolInput.query) { $Detail = $ToolInput.query } }
                        elseif ($ToolName -eq "Task") {
                                # Special handling for Subagent Tasks
                                if ($ToolInput.subagent_type) {
                                    $RawName = ($ToolInput.subagent_type -split ":")[-1]
                                    if ($RawName.Length -gt 0) {
                                        $ToolName = $RawName.Substring(0,1).ToUpper() + $RawName.Substring(1)
                                    } else {
                                        $ToolName = $RawName
                                    }
                                }
                                if ($ToolInput.description) { $Detail = $ToolInput.description }
                        }
                        else { 
                                if ($ToolInput.input) { $Detail = $ToolInput.input }
                                elseif ($ToolInput.path) { $Detail = $ToolInput.path }
                        }
                        
                        if (-not $Detail -and -not $Description) {
                                $json = $ToolInput | ConvertTo-Json -Depth 1 -Compress
                                if ($json.Length -gt 50) { $Detail = $json.Substring(0,47) + "..." } else { $Detail = $json }
                        }

                        $Combined = ""
                        if ($Detail) { $Combined = $Detail }
                        if ($Description) { if ($Combined) { $Combined += " - " }; $Combined += $Description }
                        if ($Combined.Length -gt 200) { $Combined = $Combined.Substring(0, 197) + "..." }
                        
                        $ToolUseInfo = "[$ToolName] $Combined"
                    }

                    # Text Info
                    $LastText = $Content | Where-Object { $_.type -eq 'text' } | Select-Object -ExpandProperty text -Last 1
                    if ($LastText) {
                            $CleanText = $LastText -replace '#{1,6}\s*', '' -replace '\*{1,2}([^*]+)\*{1,2}', '$1' -replace '```[a-z]*\r?\n?', '' -replace '`([^`]+)`', '$1' -replace '\[([^\]]+)\]\([^)]+\)', '$1' -replace '^\s*[-*]\s+', '' -replace '\r?\n', ' '
                            $CleanText = $CleanText.Trim()
                            if ($CleanText.Length -gt 800) { $CleanText = $CleanText.Substring(0, 797) + "..." }
                            $TextMessage = if ($ResponseTime) { "A: [$ResponseTime] $CleanText" } else { "A: $CleanText" }
                    }

                    # Compose
                    if ($TextMessage -and $ToolUseInfo) {
                        # Determine Type
                        if ($ToolName -match "Wait" -or ($TextMessage -match "Proceed")) {
                            $Result.NotificationType = 'permission_prompt'
                        }
                        
                        if ($Result.NotificationType -eq 'permission_prompt') {
                                $Desc = $TextMessage -replace '^A: (\[.*?\] )?', ''
                                $Result.Message = "$ToolUseInfo - $Desc"
                        } else {
                                $Result.Message = "$ToolUseInfo  $TextMessage"
                        }
                    } elseif ($TextMessage) { $Result.Message = $TextMessage }
                    elseif ($ToolUseInfo) { $Result.Message = $ToolUseInfo }

                    if ($Result.Message -ne "Task finished.") { break } 
                }
            } catch {}
        }

        # 2. Extract User Question (for Title)
        for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
                $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
                try {
                    $Entry = $Line | ConvertFrom-Json
                    if ($Entry.type -eq 'user' -and $Entry.message -and -not $Entry.isMeta) {
                        $UserContent = $Entry.message.content
                        if ($UserContent -is [string] -and $UserContent -notmatch '^\s*<') {
                            $UserText = $UserContent.Trim()
                            if ($UserText.Length -gt 60) { $UserText = $UserText.Substring(0, 57) + "..." }
                            if ($UserText) { $Result.Title = "Q: $UserText"; break }
                        }
                    }
                } catch {}
        }
    } catch { Write-DebugLog "Transcript Parse Error: $_" }
    
    # Fallback Title
    if (-not $Result.Title) { 
        if ($ProjectName) { $Result.Title = "Task Done [$ProjectName]" } 
        else { $Result.Title = "Claude Notification" }
    }

    return $Result
}
