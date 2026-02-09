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
        # We iterate backwards to find the *last* relevant assistant action.
        for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
            $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
            try {
                $Entry = $Line | ConvertFrom-Json
                
                # STOP if User Message found (boundary of current turn)
                if ($Entry.type -eq 'user' -and $Entry.message) { break }

                # Normalize Content
                $Content = $null
                # Standard Message Format
                if ($Entry.type -eq 'assistant' -and $Entry.message) { 
                    $Content = $Entry.message.content 
                } 
                # Legacy / Alternative Format
                elseif ($Entry.type -eq 'message' -and $Entry.role -eq 'assistant') { 
                    $Content = $Entry.content 
                }

                if ($Content) {
                    # Extract Timestamp
                    if ($Entry.timestamp -and -not $ResponseTime) {
                        try { $ResponseTime = [DateTime]::Parse($Entry.timestamp).ToLocalTime().ToString("HH:mm") } catch {}
                    }

                    # --- TOOL EXTRACTION ---
                    # Prioritize Tool Use over Text for "Action" notifications
                    $ToolUse = $Content | Where-Object { $_.type -eq 'tool_use' } | Select-Object -First 1
                    if ($ToolUse) {
                        $ToolName = $ToolUse.name
                        $ToolInput = $ToolUse.input
                        
                        $Detail = ""
                        $Description = ""

                        # Heuristic Mapping
                        switch -Regex ($ToolName) {
                            "^Bash$" {
                                if ($ToolInput.command) { $Detail = $ToolInput.command }
                            }
                            "^(Read|Write|Edit)(_file)?$" {
                                if ($ToolInput.file_path) { 
                                    $Action = $Matches[1]
                                    $Detail = "$Action " + (Split-Path $ToolInput.file_path -Leaf)
                                }
                            }
                            "^Grep(_search)?$" {
                                if ($ToolInput.pattern) { $Detail = "Search: " + $ToolInput.pattern }
                            }
                            "^Task$" {
                                # Subagent
                                if ($ToolInput.subagent_type) {
                                    $RawName = ($ToolInput.subagent_type -split ":")[-1]
                                    $ToolName = $RawName.Substring(0,1).ToUpper() + $RawName.Substring(1)
                                }
                                # Use description for Detail if available
                                if ($ToolInput.description) { $Detail = $ToolInput.description }
                                elseif ($ToolInput.prompt) { 
                                    $Detail = $ToolInput.prompt 
                                    if ($Detail.Length -gt 50) { $Detail = $Detail.Substring(0,47) + "..." }
                                }
                            }
                            "WebSearch|google_search" {
                                if ($ToolInput.query) { $Detail = "Search: " + $ToolInput.query }
                            }
                            default {
                                # Generic Fallback
                                if ($ToolInput.path) { $Detail = $ToolInput.path }
                                elseif ($ToolInput.command) { $Detail = $ToolInput.command }
                                elseif ($ToolInput.input) { $Detail = $ToolInput.input }
                            }
                        }

                        # Fallback for Detail
                        if (-not $Detail -and $Description) { $Detail = $Description }
                        
                        # formatting
                        if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 397) + "..." }
                        
                        $ToolUseInfo = "[$ToolName] $Detail"
                    }

                    # --- TEXT EXTRACTION ---
                    $LastText = $Content | Where-Object { $_.type -eq 'text' } | Select-Object -ExpandProperty text -Last 1
                    if ($LastText) {
                            $CleanText = $LastText -replace '#{1,6}\s*', '' -replace '\*{1,2}([^*]+)\*{1,2}', '$1' -replace '```[a-z]*\r?\n?', '' -replace '`([^`]+)`', '$1' -replace '\[([^\]]+)\]\([^)]+\)', '$1' -replace '^\s*[-*]\s+', '' -replace '\r?\n', ' '
                            $CleanText = $CleanText.Trim()
                            if ($CleanText.Length -gt 800) { $CleanText = $CleanText.Substring(0, 797) + "..." }
                            
                            # Prefix
                            $TextMessage = if ($ResponseTime) { "A: [$ResponseTime] $CleanText" } else { "A: $CleanText" }
                    }

                    # --- COMPOSE NOTIFICATION ---
                    # Priority: Permission > Tool > Text
                    
                    # Check for Permission Prompt Context
                    # (Usually signaled by 'Wait' tool or text like 'Proceed?')
                    # But we also rely on $NotificationType passed from Launcher/Payload.
                    # Here we just detect *potential* permission context from text.
                    $IsPermissionContext = ($TextMessage -match "(permission|approve|proceed|allow|confirm)")

                    if ($ToolUseInfo) {
                        if ($TextMessage -and $IsPermissionContext) {
                            # "I need permission to run this..."
                            # Output: "[Bash] rm -rf / - I need permission..."
                            $Desc = $TextMessage -replace '^A: (\[.*?\] )?', ''
                            $Result.Message = "$ToolUseInfo - $Desc"
                            $Result.NotificationType = 'permission_prompt' # Infer type if not set
                        } else {
                            # Just a tool use (e.g. "I will list files" + [Bash] ls)
                            $Result.Message = "$ToolUseInfo"
                        }
                    } elseif ($TextMessage) {
                        $Result.Message = $TextMessage
                    }

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
