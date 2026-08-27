# Read-only Level Two session metadata discovery.
$script:LnchSessionInventoryCache = $null

function script:Read-LnchJsonlRecords {
    param([string]$Path, [int]$Limit = 0)
    $records = New-Object System.Collections.ArrayList
    $stream = $null
    $reader = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $reader = New-Object System.IO.StreamReader($stream)
        $lineNumber = 0
        while (-not $reader.EndOfStream -and ($Limit -le 0 -or $records.Count -lt $Limit)) {
            $lineNumber++
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt 16777216) { continue }
            try {
                $value = $line | ConvertFrom-Json
                $records.Add([pscustomobject]@{ Line = $lineNumber; Value = $value }) | Out-Null
            } catch { }
        }
    } catch { }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
    return $records.ToArray()
}

function script:Get-LnchTextFromContent {
    param($Content)
    if ($null -eq $Content) { return $null }
    if ($Content -is [string]) { return $Content }
    $parts = @()
    if ($Content -is [System.Collections.IEnumerable] -and -not ($Content -is [System.Management.Automation.PSCustomObject])) {
        foreach ($item in $Content) {
            $text = Get-LnchTextFromContent $item
            if ($text) { $parts += $text }
        }
    } elseif ($Content.PSObject) {
        if ($Content.text -is [string]) { $parts += $Content.text }
        elseif ($Content.content -is [string]) { $parts += $Content.content }
        elseif ($Content.parts) {
            $text = Get-LnchTextFromContent $Content.parts
            if ($text) { $parts += $text }
        }
    }
    ($parts | Where-Object { $_ }) -join "`n"
}

function script:ConvertTo-LnchSessionPreview {
    param([string]$Text)
    if (-not $Text) { return $null }
    $preview = ($Text -replace '\s+', ' ').Trim()
    if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 117) + '...' }
    $preview
}

function script:New-LnchSessionMetadata {
    param(
        [string]$Agent,
        [string]$NativeId,
        [string]$ProjectPath,
        [string]$Title,
        $CreatedAt,
        $UpdatedAt,
        [string]$ParentId,
        [string]$Model,
        [Nullable[bool]]$Archived,
        [Nullable[bool]]$Active,
        [string]$TranscriptPath,
        [string]$Source,
        [string]$ResumeCommand,
        [string]$Confidence = 'verified'
    )
    if (-not $NativeId) { $NativeId = [System.IO.Path]::GetFileNameWithoutExtension($TranscriptPath) }
    $project = ConvertTo-LnchProjectPath $ProjectPath
    [pscustomobject][ordered]@{
        Ref                 = "$Agent`:$NativeId"
        Agent               = $Agent
        NativeId            = $NativeId
        ProjectId           = if ($project) { Get-LnchWorkspaceId $project } else { $null }
        ProjectPath         = $project
        Title               = ConvertTo-LnchSessionPreview $Title
        CreatedAt           = $(if ($CreatedAt) { (ConvertTo-LnchActivityTime $CreatedAt).ToString('o') } else { $null })
        UpdatedAt           = $(if ($UpdatedAt) { (ConvertTo-LnchActivityTime $UpdatedAt).ToString('o') } else { $null })
        ParentId            = $ParentId
        Model               = $Model
        Archived            = $Archived
        Active              = $Active
        TranscriptPath      = $TranscriptPath
        TranscriptAvailable = [bool]($TranscriptPath -and (Test-Path -LiteralPath $TranscriptPath -PathType Leaf))
        Source              = $Source
        ResumeCommand       = $ResumeCommand
        Confidence          = $Confidence
    }
}

function script:Add-LnchSessionMetadata {
    param([hashtable]$Sessions, [object]$Session)
    if (-not $Session -or -not $Session.NativeId) { return }
    $key = "$($Session.Agent)|$($Session.NativeId)"
    if (-not $Sessions.ContainsKey($key)) { $Sessions[$key] = $Session; return }
    $existing = $Sessions[$key]
    $incomingTime = ConvertTo-LnchActivityTime $Session.UpdatedAt
    $existingTime = ConvertTo-LnchActivityTime $existing.UpdatedAt
    if ($incomingTime -and (-not $existingTime -or $incomingTime -gt $existingTime)) { $Sessions[$key] = $Session }
}

function script:Get-LnchFirstUserPreview {
    param([string]$Agent, [object[]]$Records)
    foreach ($item in $Records) {
        $record = $item.Value
        if ($Agent -eq 'omp' -and $record.type -eq 'message' -and $record.message.role -eq 'user') {
            return ConvertTo-LnchSessionPreview (Get-LnchTextFromContent $record.message.content)
        }
        if ($Agent -eq 'claude' -and $record.type -eq 'user' -and -not $record.isMeta -and -not $record.isSidechain) {
            return ConvertTo-LnchSessionPreview (Get-LnchTextFromContent $record.message.content)
        }
        if ($Agent -eq 'codex' -and $record.type -eq 'response_item' -and $record.payload.type -eq 'message' -and $record.payload.role -eq 'user') {
            return ConvertTo-LnchSessionPreview (Get-LnchTextFromContent $record.payload.content)
        }
        if ($Agent -eq 'codex' -and $record.type -eq 'event_msg' -and $record.payload.type -eq 'user_message') {
            return ConvertTo-LnchSessionPreview ([string]$record.payload.message)
        }
        if ($Agent -eq 'gemini' -and $record.type -eq 'user') {
            return ConvertTo-LnchSessionPreview (Get-LnchTextFromContent $record.content)
        }
        if ($Agent -eq 'qwen' -and $record.type -eq 'user') {
            return ConvertTo-LnchSessionPreview (Get-LnchTextFromContent $record.message.parts)
        }
    }
    $null
}

function script:Get-LnchOmpSessions {
    param([object]$AgentState, [hashtable]$Sessions)
    $activePaths = @{}
    foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -in @('agent-home', 'xdg-home') -and $_.Readable })) {
        $breadcrumbs = Join-Path $store.Path 'terminal-sessions'
        if (Test-Path -LiteralPath $breadcrumbs -PathType Container) {
            foreach ($crumb in @(Get-ChildItem -LiteralPath $breadcrumbs -File -ErrorAction SilentlyContinue)) {
                try {
                    $lines = @(Get-Content -LiteralPath $crumb.FullName -TotalCount 3)
                    if ($lines.Count -ge 2) { $activePaths[(Get-LnchProjectKey $lines[1])] = $true }
                } catch { }
            }
        }
        $root = Join-Path $store.Path 'sessions'
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($bucket in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $bucket.FullName -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
                $records = @(Read-LnchJsonlRecords $file.FullName 256)
                $header = $records.Value | Where-Object type -eq 'session' | Select-Object -First 1
                if (-not $header) { continue }
                $titleRecord = $records.Value | Where-Object type -eq 'title' | Select-Object -First 1
                $modelRecord = $records.Value | Where-Object type -eq 'model_change' | Select-Object -Last 1
                $title = if ($header.title) { $header.title } elseif ($titleRecord.title) { $titleRecord.title } else { Get-LnchFirstUserPreview 'omp' $records }
                $active = $activePaths.ContainsKey((Get-LnchProjectKey $file.FullName))
                Add-LnchSessionMetadata $Sessions (New-LnchSessionMetadata 'omp' $header.id $header.cwd $title $header.timestamp $file.LastWriteTimeUtc $header.parentSession $modelRecord.model $false $active $file.FullName 'session-jsonl' "omp --resume $($header.id)")
            }
        }
    }
}

function script:Get-LnchClaudeSessions {
    param([object]$AgentState, [hashtable]$Sessions)
    foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'user-home' -and $_.Readable })) {
        $root = Join-Path $store.Path 'projects'
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($projectDir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $projectDir.FullName -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
                $records = @(Read-LnchJsonlRecords $file.FullName 256)
                $cwdRecord = $records.Value | Where-Object cwd | Select-Object -First 1
                if (-not $cwdRecord) { continue }
                $customTitle = $records.Value | Where-Object type -eq 'custom-title' | Select-Object -Last 1
                $aiTitle = $records.Value | Where-Object type -eq 'ai-title' | Select-Object -Last 1
                $assistant = $records.Value | Where-Object { $_.type -eq 'assistant' -and $_.message.model } | Select-Object -Last 1
                $first = $records | Select-Object -First 1
                $title = if ($customTitle.customTitle) { $customTitle.customTitle } elseif ($aiTitle.aiTitle) { $aiTitle.aiTitle } else { Get-LnchFirstUserPreview 'claude' $records }
                $id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                $created = if ($first.Value.timestamp) { $first.Value.timestamp } else { $file.CreationTimeUtc }
                Add-LnchSessionMetadata $Sessions (New-LnchSessionMetadata 'claude' $id $cwdRecord.cwd $title $created $file.LastWriteTimeUtc $null $assistant.message.model $false $null $file.FullName 'session-jsonl' "claude --resume $id")
            }
        }
    }
}

function script:Get-LnchCodexSessions {
    param([object]$AgentState, [hashtable]$Sessions)
    foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'user-home' -and $_.Readable })) {
        foreach ($directoryName in @('sessions', '.sessions', 'archived_sessions')) {
            $root = Join-Path $store.Path $directoryName
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
                $records = @(Read-LnchJsonlRecords $file.FullName 256)
                $meta = $records.Value | Where-Object { $_.type -eq 'session_meta' -and $_.payload.cwd } | Select-Object -First 1
                if (-not $meta) { continue }
                $turn = $records.Value | Where-Object { $_.type -eq 'turn_context' -and $_.payload.model } | Select-Object -Last 1
                $titleRecord = $records.Value | Where-Object { $_.type -eq 'event_msg' -and $_.payload.type -eq 'thread_name_updated' } | Select-Object -Last 1
                $title = if ($titleRecord.payload.thread_name) { $titleRecord.payload.thread_name } else { Get-LnchFirstUserPreview 'codex' $records }
                $created = if ($meta.timestamp) { $meta.timestamp } elseif ($meta.payload.timestamp) { $meta.payload.timestamp } else { $file.CreationTimeUtc }
                $parent = if ($meta.payload.parent_thread_id) { $meta.payload.parent_thread_id } else { $meta.payload.forked_from_id }
                $archived = $directoryName -eq 'archived_sessions'
                Add-LnchSessionMetadata $Sessions (New-LnchSessionMetadata 'codex' $meta.payload.id $meta.payload.cwd $title $created $file.LastWriteTimeUtc $parent $turn.payload.model $archived $null $file.FullName 'rollout-jsonl' "codex resume $($meta.payload.id)")
            }
        }
    }
}

function script:Get-LnchGeminiSessions {
    param([object]$AgentState, [hashtable]$Sessions)
    foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'user-home' -and $_.Readable })) {
        $projectPaths = @{}
        $registryPath = Join-Path $store.Path 'projects.json'
        if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
            try {
                $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
                foreach ($property in @($registry.projects.PSObject.Properties)) { $projectPaths[[string]$property.Value] = $property.Name }
            } catch { }
        }
        $tmpRoot = Join-Path $store.Path 'tmp'
        if (-not (Test-Path -LiteralPath $tmpRoot -PathType Container)) { continue }
        foreach ($projectDir in @(Get-ChildItem -LiteralPath $tmpRoot -Directory -ErrorAction SilentlyContinue)) {
            $projectPath = $projectPaths[$projectDir.Name]
            $marker = Join-Path $projectDir.FullName '.project_root'
            if (-not $projectPath -and (Test-Path -LiteralPath $marker -PathType Leaf)) {
                try { $projectPath = (Get-Content -LiteralPath $marker -Raw).Trim() } catch { }
            }
            $chats = Join-Path $projectDir.FullName 'chats'
            if (-not (Test-Path -LiteralPath $chats -PathType Container)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $chats -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.json', '.jsonl') })) {
                $id = $null; $title = $null; $created = $file.CreationTimeUtc; $model = $null
                if ($file.Extension -eq '.json') {
                    try {
                        $conversation = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                        $id = $conversation.sessionId
                        $created = $conversation.startTime
                        $title = $conversation.summary
                        $firstUser = @($conversation.messages | Where-Object type -eq 'user' | Select-Object -First 1)
                        if (-not $title -and $firstUser) { $title = Get-LnchTextFromContent $firstUser[0].content }
                        $model = @($conversation.messages | Where-Object model | Select-Object -Last 1).model
                    } catch { continue }
                } else {
                    $records = @(Read-LnchJsonlRecords $file.FullName 256)
                    $metadata = $records.Value | Where-Object sessionId | Select-Object -First 1
                    $id = $metadata.sessionId
                    if ($metadata.startTime) { $created = $metadata.startTime }
                    $title = if ($metadata.summary) { $metadata.summary } else { Get-LnchFirstUserPreview 'gemini' $records }
                    $model = @($records.Value | Where-Object model | Select-Object -Last 1).model
                }
                if (-not $id) { $id = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
                Add-LnchSessionMetadata $Sessions (New-LnchSessionMetadata 'gemini' $id $projectPath $title $created $file.LastWriteTimeUtc $null $model $false $null $file.FullName 'chat-recording' "gemini --resume $id")
            }
        }
    }
}

function script:Get-LnchAiderSessions {
    param([object]$AgentState, [hashtable]$Sessions)
    foreach ($project in @($AgentState.Projects | Where-Object Path)) {
        $history = Join-Path $project.Path '.aider.chat.history.md'
        if (-not (Test-Path -LiteralPath $history -PathType Leaf)) { continue }
        $file = Get-Item -LiteralPath $history
        $title = $null
        try {
            foreach ($line in @(Get-Content -LiteralPath $history -TotalCount 200)) {
                if ($line.StartsWith('#### ')) { $title = $line.Substring(5); break }
            }
        } catch { }
        $workspace = Get-LnchWorkspaceId $project.Path
        $id = "history-$($workspace.Split(':')[-1])"
        Add-LnchSessionMetadata $Sessions (New-LnchSessionMetadata 'aider' $id $project.Path $title $file.CreationTimeUtc $file.LastWriteTimeUtc $null $null $false $null $history 'markdown-history' "aider --restore-chat-history --chat-history-file `"$history`"")
    }
}

function script:Get-LnchOpenCodeSessions {
    param([object]$AgentState, [hashtable]$Sessions)
    foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'data-home' -and $_.Readable })) {
        $legacy = Join-Path $store.Path 'storage\session'
        if (Test-Path -LiteralPath $legacy -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $legacy -File -Recurse -Filter '*.json' -ErrorAction SilentlyContinue)) {
                try {
                    $session = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                    $directory = if ($session.directory) { $session.directory } elseif ($session.path -and $session.path.root) { $session.path.root } else { $null }
                    if ($directory -and $session.id) {
                        Add-LnchSessionMetadata $Sessions (New-LnchSessionMetadata 'opencode' $session.id $directory $session.title $session.time.created $session.time.updated $session.parentID $session.model.modelID $false $null $file.FullName 'legacy-session-json' "opencode --session $($session.id)")
                    }
                } catch { }
            }
        }
    }
    if ($AgentState.Executable) {
        try {
            $raw = (& $AgentState.Executable session list --format json 2>$null) -join [Environment]::NewLine
            $start = $raw.IndexOf('['); $end = $raw.LastIndexOf(']')
            if ($start -ge 0 -and $end -ge $start) {
                foreach ($session in @(($raw.Substring($start, $end - $start + 1)) | ConvertFrom-Json)) {
                    Add-LnchSessionMetadata $Sessions (New-LnchSessionMetadata 'opencode' $session.id $session.directory $session.title $session.created $session.updated $null $null $false $null $null 'native-session-list' "opencode --session $($session.id)")
                }
            }
        } catch { }
    }
}

function script:Get-LnchQwenSessions {
    param([object]$AgentState, [hashtable]$Sessions)
    foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'runtime-home' -and $_.Readable })) {
        $root = Join-Path $store.Path 'projects'
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($projectDir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $chats = Join-Path $projectDir.FullName 'chats'
            if (-not (Test-Path -LiteralPath $chats -PathType Container)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $chats -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
                $records = @(Read-LnchJsonlRecords $file.FullName 256)
                $first = $records.Value | Where-Object { $_.sessionId -and $_.cwd } | Select-Object -First 1
                if (-not $first) { continue }
                $titleRecord = $records.Value | Where-Object { $_.type -eq 'system' -and $_.subtype -eq 'custom_title' } | Select-Object -Last 1
                $modelRecord = $records.Value | Where-Object { $_.type -eq 'system' -and $_.subtype -eq 'session_model' } | Select-Object -Last 1
                $parentRecord = $records.Value | Where-Object { $_.type -eq 'system' -and $_.subtype -eq 'parent_session' } | Select-Object -First 1
                $title = if ($titleRecord.systemPayload.title) { $titleRecord.systemPayload.title } else { Get-LnchFirstUserPreview 'qwen' $records }
                $sidecar = Join-Path $chats "$($first.sessionId).runtime.json"
                $active = Test-Path -LiteralPath $sidecar -PathType Leaf
                Add-LnchSessionMetadata $Sessions (New-LnchSessionMetadata 'qwen' $first.sessionId $first.cwd $title $first.timestamp $file.LastWriteTimeUtc $parentRecord.systemPayload.parentSessionId $modelRecord.systemPayload.model $false $active $file.FullName 'session-jsonl' "qwen --resume $($first.sessionId)")
            }
        }
    }
}

function global:Get-LnchSessionInventory {
    [CmdletBinding()]
    param([string]$Project, [string[]]$Agent, [switch]$Refresh)
    $cacheVariables = @(
        'PI_CODING_AGENT_DIR', 'OMP_PROFILE', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME',
        'GEMINI_CLI_HOME', 'OPENCODE_CONFIG_DIR', 'XDG_DATA_HOME',
        'QWEN_HOME', 'QWEN_RUNTIME_DIR', 'LNCH_DISCOVERY_HOME',
        'LNCH_DISCOVERY_ROOTS'
    )
    $scopeKey = if ($Agent) { (@($Agent | Sort-Object -Unique) -join ',') } else { '*' }
    $cacheKey = (($cacheVariables | ForEach-Object { "$_=$([Environment]::GetEnvironmentVariable($_, 'Process'))" }) -join '|') + "|agents=$scopeKey"
    $cacheValid = -not $Refresh -and $script:LnchSessionInventoryCache -and
        $script:LnchSessionInventoryCache.Key -eq $cacheKey -and
        (([datetime]::UtcNow - $script:LnchSessionInventoryCache.CreatedAt).TotalSeconds -lt 15)
    if ($cacheValid) {
        $projectInventory = $script:LnchSessionInventoryCache.ProjectInventory
        $items = @($script:LnchSessionInventoryCache.Sessions)
    } else {
        $projectInventory = Get-LnchProjectInventory
        $sessions = @{}
        foreach ($agentState in $projectInventory.Agents) {
            if ($Agent -and $Agent -notcontains $agentState.Agent) { continue }
            switch ($agentState.Agent) {
                'omp'      { Get-LnchOmpSessions $agentState $sessions }
                'claude'   { Get-LnchClaudeSessions $agentState $sessions }
                'codex'    { Get-LnchCodexSessions $agentState $sessions }
                'gemini'   { Get-LnchGeminiSessions $agentState $sessions }
                'aider'    { Get-LnchAiderSessions $agentState $sessions }
                'opencode' { Get-LnchOpenCodeSessions $agentState $sessions }
                'qwen'     { Get-LnchQwenSessions $agentState $sessions }
            }
        }
        $items = @($sessions.Values)
        $script:LnchSessionInventoryCache = [pscustomobject]@{
            Key              = $cacheKey
            CreatedAt        = [datetime]::UtcNow
            ProjectInventory = $projectInventory
            Sessions         = $items
        }
    }
    if ($Agent) { $items = @($items | Where-Object { $Agent -contains $_.Agent }) }
    if ($Project) {
        $matching = @($projectInventory.Projects | Where-Object {
            $_.Id -eq $Project -or $_.Path -eq $Project -or $_.Name -eq $Project
        })
        $paths = @($matching.Path | Where-Object { $_ })
        if ($paths.Count -eq 0) { $paths = @(ConvertTo-LnchProjectPath $Project) }
        $keys = @($paths | ForEach-Object { Get-LnchProjectKey $_ })
        $items = @($items | Where-Object { $_.ProjectPath -and $keys -contains (Get-LnchProjectKey $_.ProjectPath) })
    }
    $items = @($items | Sort-Object @{ Expression = { if ($_.UpdatedAt) { [datetime]$_.UpdatedAt } else { [datetime]::MinValue } }; Descending = $true }, Agent, NativeId)
    [pscustomobject][ordered]@{
        Schema      = 1
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        Sessions    = $items
    }
}

function global:Show-LnchSessions {
    [CmdletBinding()]
    param([string]$Project, [string[]]$Agent, [switch]$Json)
    $inventory = Get-LnchSessionInventory -Project $Project -Agent $Agent
    if ($Json) { ConvertTo-Json -InputObject $inventory -Depth 8; return }
    Write-Host ("== lnch sessions ({0}) ==" -f $inventory.Sessions.Count)
    foreach ($session in $inventory.Sessions) {
        $title = if ($session.Title) { $session.Title } else { '<untitled>' }
        $projectPath = if ($session.ProjectPath) { $session.ProjectPath } else { '<unresolved>' }
        Write-Host ("[{0}] {1} | {2} | {3}" -f $session.Agent, $session.NativeId, $title, $session.UpdatedAt)
        Write-Host ("     {0}" -f $projectPath)
    }
}
