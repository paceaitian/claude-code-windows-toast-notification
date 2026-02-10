function Format-ClaudeToolInfo {
    param($Name, $InputObj)
    
    $DisplayName = $Name
    $Detail = ""
    
    # 1. Subagent
    if ($Name -eq "Task" -and $InputObj.subagent_type) {
        $SubAgent = ($InputObj.subagent_type -split ":")[-1]
        $DisplayName = $SubAgent.Substring(0,1).ToUpper() + $SubAgent.Substring(1)
        if ($InputObj.description) { $Detail = $InputObj.description }
    }
    # 2. MCP Tools
    elseif ($Name -match "^mcp__") {
        $Parts = $Name -split "__"
        if ($Parts.Count -ge 3) { 
            $DisplayName = $Parts[-1] 
            $DisplayName = $DisplayName.Substring(0,1).ToUpper() + $DisplayName.Substring(1)
        }
        
        if ($InputObj.command) { $Detail = $InputObj.command }
        elseif ($InputObj.query) { $Detail = "Search: " + $InputObj.query }
        elseif ($InputObj.path) { $Detail = $InputObj.path }
        elseif ($InputObj.uri) { $Detail = $InputObj.uri }
    }
    # 3. Standard Tools (Advanced Logic)
    else {
        switch -Regex ($Name) {
            "^Bash$" { 
                if ($InputObj.command) { $Detail = $InputObj.command } 
            }
            "^Grep$" {
                if ($InputObj.pattern) { $Detail = "Search: " + $InputObj.pattern }
            }
            "^(Read|Write|Edit)(_file)?$" { 
                $DisplayName = $Matches[1]
                if ($InputObj.file_path) { 
                    $Detail = Split-Path $InputObj.file_path -Leaf
                } 
            }
            "WebSearch|google_search" {
                if ($InputObj.query) { $Detail = "Search: " + $InputObj.query }
                elseif ($InputObj.q) { $Detail = "Search: " + $InputObj.q }
            }
            default { 
                if ($InputObj.description) { $Detail = $InputObj.description }
                elseif ($InputObj.input) { $Detail = $InputObj.input }
                elseif ($InputObj.path) { $Detail = $InputObj.path }
                elseif ($InputObj.url) { $Detail = $InputObj.url }
                
                # Fallback: JSON Dump
                if (-not $Detail) {
                    try { 
                        $Json = $InputObj | ConvertTo-Json -Depth 1 -Compress 
                        if ($Json.Length -gt 50) { $Json = $Json.Substring(0, 47) + "..." }
                        $Detail = $Json
                    } catch {}
                }
            }
        }
    }

    if ($Detail) {
        if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 397) + "..." }
        # XML Escape (Minimal)
        $Detail = $Detail -replace ">", "&gt;" -replace "<", "&lt;"
        return "[$DisplayName] $Detail"
    }
    return "[$DisplayName]"
}

function Get-ClaudeContentFromPayload {
    param($ToolName, $ToolInput, $Message)
    
    $Result = @{ Message = $null }
    
    if ($ToolName) {
        $ToolString = Format-ClaudeToolInfo -Name $ToolName -InputObj $ToolInput
        
        # Combine with Description (Message) if present
        if ($Message -and $Message -ne "Task finished.") {
             # Clean Message
             if ($Message.Length -gt 800) { $Message = $Message.Substring(0, 797) + "..." }
             $Result.Message = "$ToolString - $Message"
        } else {
             $Result.Message = $ToolString
        }
    }
    return $Result
}

function Get-ClaudeTranscriptInfo {
    param(
        [string]$TranscriptPath,
        [string]$ProjectName
    )

    $Result = @{
        Title = $null
        Message = "Task finished."
        NotificationType = $null
        ResponseTime = $null
    }

    if (-not ($TranscriptPath -and (Test-Path $TranscriptPath))) { return $Result }

    try {
        $TranscriptLines = Get-Content $TranscriptPath -Tail 50 -Encoding UTF8 -ErrorAction Stop
        
        $ResponseTime = ""
        
        # 1. Extract Last Assistant Message
        for ($i = $TranscriptLines.Count - 1; $i -ge 0; $i--) {
            $Line = $TranscriptLines[$i]; if ([string]::IsNullOrWhiteSpace($Line)) { continue }
            try {
                $Entry = $Line | ConvertFrom-Json
                
                if ($Entry.type -eq 'user' -and $Entry.message) { break }

                $Content = $null
                if ($Entry.type -eq 'assistant' -and $Entry.message) { 
                    $Content = $Entry.message.content 
                } elseif ($Entry.type -eq 'message' -and $Entry.role -eq 'assistant') { 
                    $Content = $Entry.content 
                }

                if ($Content) {
                    if ($Entry.timestamp -and -not $ResponseTime) {
                        try { 
                            $ResponseTime = [DateTime]::Parse($Entry.timestamp).ToLocalTime().ToString("HH:mm")
                            $Result.ResponseTime = $ResponseTime
                        } catch {}
                    }

                    # --- TOOL EXTRACTION ---
                    $ToolUse = $Content | Where-Object { $_.type -eq 'tool_use' } | Select-Object -First 1
                    $ToolString = ""
                    
                    if ($ToolUse) {
                        $ToolString = Format-ClaudeToolInfo -Name $ToolUse.name -InputObj $ToolUse.input
                    }

                    # --- TEXT EXTRACTION ---
                    $TextString = ""
                    $LastText = $Content | Where-Object { $_.type -eq 'text' } | Select-Object -ExpandProperty text -Last 1
                    if ($LastText) {
                        $CleanText = $LastText -replace '#{1,6}\s*', '' -replace '\*{1,2}([^*]+)\*{1,2}', '$1' -replace '```[a-z]*\r?\n?', '' -replace '`([^`]+)`', '$1' -replace '\[([^\]]+)\]\([^)]+\)', '$1' -replace '^\s*[-*]\s+', '' -replace '\r?\n', ' '
                        $CleanText = $CleanText.Trim()
                        if ($CleanText.Length -gt 800) { $CleanText = $CleanText.Substring(0, 797) + "..." }
                        $TextString = $CleanText
                    }

                    # --- COMPOSE MESSAGE ---
                    $TimeStr = if ($ResponseTime) { "[$ResponseTime]" } else { "" }
                    $IsPermission = ($TextString -match "(permission|approve|proceed|allow|confirm|authorize)")
                    
                    if ($Result.NotificationType -eq 'permission_prompt' -or $IsPermission) {
                         if (-not $Result.NotificationType) { $Result.NotificationType = 'permission_prompt' }
                         
                         $Body = ""
                         if ($ToolString) {
                             $Body = "$ToolString"
                             if ($TextString) { $Body += " - $TextString" }
                         } else {
                             $Body = $TextString
                         }
                         $Result.Message = "$TimeStr $Body".Trim()
                    } else {
                         # Task Finished / Answer
                         $Body = ""
                         if ($ToolString) { $Body += "$ToolString " }
                         if ($TextString) { $Body += "$TextString" }
                         $Result.Message = "A: $TimeStr $Body".Trim()
                    }

                    if ($Result.Message -ne "Task finished.") { break } 
                }
            } catch {}
        }

        # 2. Extract User Question
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
