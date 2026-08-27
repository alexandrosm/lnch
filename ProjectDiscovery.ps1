# Read-only Level One project extraction and cross-agent reconciliation.

function script:ConvertTo-LnchProjectPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $value = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($value -eq '~' -or $value -match '^~[\\/]') {
        $value = Resolve-LnchDatastorePath $value
    } elseif ($value -match '^[A-Za-z]:[\\/]' -or $value.StartsWith('\\')) {
        try { $value = [System.IO.Path]::GetFullPath($value) } catch { }
    } elseif ([System.IO.Path]::DirectorySeparatorChar -eq '/' -and [System.IO.Path]::IsPathRooted($value)) {
        try { $value = [System.IO.Path]::GetFullPath($value) } catch { }
    }
    try {
        if (Test-Path -LiteralPath $value -PathType Container) {
            $value = (Resolve-Path -LiteralPath $value -ErrorAction Stop).ProviderPath
        }
    } catch { }
    $value
}

function script:Get-LnchProjectKey {
    param([string]$Path)
    $normalized = ConvertTo-LnchProjectPath $Path
    if (-not $normalized) { return $null }
    $key = $normalized
    try {
        $root = [System.IO.Path]::GetPathRoot($normalized)
        if ($normalized.Length -gt $root.Length) { $key = $normalized.TrimEnd('\', '/') }
    } catch { }
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { $key = $key.ToLowerInvariant() }
    $key
}

function script:Get-LnchWorkspaceId {
    param([string]$Path)
    if ($Path) {
        $meta = Join-Path $Path '.lnch.json'
        if (Test-Path -LiteralPath $meta -PathType Leaf) {
            try {
                $stored = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
                if ($stored.id) { return "lnch:$($stored.id)" }
            } catch { }
        }
    }
    $key = Get-LnchProjectKey $Path
    if (-not $key) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($key)
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    "workspace:$($hex.Substring(0, 16))"
}

function script:ConvertTo-LnchActivityTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
    if ($Value -is [long] -or $Value -is [int] -or $Value -is [double]) {
        try {
            $number = [double]$Value
            $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [System.DateTimeKind]::Utc)
            if ($number -gt 9999999999) { return $epoch.AddMilliseconds($number) }
            return $epoch.AddSeconds($number)
        } catch { return $null }
    }
    try { return ([datetime]$Value).ToUniversalTime() } catch { return $null }
}

function script:Add-LnchAgentProject {
    param(
        [hashtable]$Projects,
        [string]$Path,
        [string]$NativeKey,
        [string]$Source,
        [int]$SessionCount = 0,
        $LastActivity,
        [ValidateSet('verified', 'inferred', 'unresolved')]
        [string]$Confidence = 'verified'
    )
    $normalized = ConvertTo-LnchProjectPath $Path
    $projectKey = Get-LnchProjectKey $normalized
    if (-not $projectKey) {
        if (-not $NativeKey) { return }
        $projectKey = "unresolved|$NativeKey"
        $Confidence = 'unresolved'
    }
    if (-not $Projects.ContainsKey($projectKey)) {
        $Projects[$projectKey] = @{
            Path          = $normalized
            NativeKeys    = @()
            Sources       = @()
            SessionCount  = 0
            LastActivity  = $null
            Confidence    = $Confidence
        }
    }
    $project = $Projects[$projectKey]
    if (-not $project.Path -and $normalized) { $project.Path = $normalized }
    if ($NativeKey -and $project.NativeKeys -notcontains $NativeKey) { $project.NativeKeys += $NativeKey }
    if ($Source -and $project.Sources -notcontains $Source) { $project.Sources += $Source }
    $project.SessionCount += $SessionCount
    $activity = ConvertTo-LnchActivityTime $LastActivity
    if ($activity -and (-not $project.LastActivity -or $activity -gt $project.LastActivity)) {
        $project.LastActivity = $activity
    }
    $rank = @{ unresolved = 0; inferred = 1; verified = 2 }
    if ($rank[$Confidence] -gt $rank[$project.Confidence]) { $project.Confidence = $Confidence }
}

function script:ConvertFrom-LnchAgentProjectMap {
    param([hashtable]$Projects)
    @($Projects.Values | Sort-Object @{ Expression = { if ($_.Path) { $_.Path } else { $_.NativeKeys[0] } } } | ForEach-Object {
        $exists = $false
        if ($_.Path) {
            try { $exists = Test-Path -LiteralPath $_.Path -PathType Container } catch { }
        }
        $name = if ($_.Path) {
            try { Split-Path -Path $_.Path -Leaf } catch { $_.Path }
        } elseif ($_.NativeKeys.Count -gt 0) { $_.NativeKeys[0] } else { '<unknown>' }
        [pscustomobject][ordered]@{
            Name          = $name
            Path          = $_.Path
            Exists        = [bool]$exists
            NativeKeys    = @($_.NativeKeys)
            SessionCount  = [int]$_.SessionCount
            LastActivity  = if ($_.LastActivity) { $_.LastActivity.ToUniversalTime().ToString('o') } else { $null }
            Confidence    = $_.Confidence
            Sources       = @($_.Sources)
        }
    })
}

function script:Read-LnchProjectJsonlHeader {
    param([string]$Agent, [string]$Path)
    $stream = $null
    $reader = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $reader = New-Object System.IO.StreamReader($stream)
        for ($lineNumber = 0; $lineNumber -lt 96 -and -not $reader.EndOfStream; $lineNumber++) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt 4194304) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            switch ($Agent) {
                'omp' {
                    if ($record.type -eq 'session' -and $record.cwd) {
                        return [pscustomobject]@{ Path = [string]$record.cwd; Id = [string]$record.id }
                    }
                }
                'claude' {
                    if ($record.cwd) {
                        $id = if ($record.sessionId) { $record.sessionId } elseif ($record.session_id) { $record.session_id } else { [System.IO.Path]::GetFileNameWithoutExtension($Path) }
                        return [pscustomobject]@{ Path = [string]$record.cwd; Id = [string]$id }
                    }
                }
                'codex' {
                    if ($record.type -eq 'session_meta' -and $record.payload -and $record.payload.cwd) {
                        return [pscustomobject]@{ Path = [string]$record.payload.cwd; Id = [string]$record.payload.id }
                    }
                }
                'qwen' {
                    if ($record.cwd) {
                        return [pscustomobject]@{ Path = [string]$record.cwd; Id = [string]$record.sessionId }
                    }
                }
            }
        }
    } catch { }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
    $null
}

function script:Add-LnchJsonlProjectEvidence {
    param(
        [string]$Agent,
        [object[]]$Files,
        [hashtable]$Projects,
        [string]$NativeKey,
        [string]$Source
    )
    $resolved = 0
    foreach ($file in @($Files)) {
        $header = Read-LnchProjectJsonlHeader -Agent $Agent -Path $file.FullName
        if ($header -and $header.Path) {
            $key = if ($NativeKey) { $NativeKey } elseif ($header.Id) { $header.Id } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
            Add-LnchAgentProject $Projects $header.Path $key $Source 1 $file.LastWriteTimeUtc 'verified'
            $resolved++
        }
    }
    $resolved
}

function script:Get-LnchDiscoveryDirectories {
    $roots = @()
    if ($env:LNCH_DISCOVERY_ROOTS) {
        $roots += @($env:LNCH_DISCOVERY_ROOTS -split [regex]::Escape([string][System.IO.Path]::PathSeparator) | Where-Object { $_ })
    }
    if ($env:LNCH_PROJECTS_DIR) { $roots += $env:LNCH_PROJECTS_DIR }
    try { $roots += Get-LnchProjectsRoot } catch { }
    $homePath = Get-LnchDiscoveryHome
    $roots += Join-Path $homePath 'projects'
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { $roots += 'C:\projects' }
    $roots += (Get-Location).Path

    $seen = @{}
    $result = @()
    $skipDirectories = @('.git', '.lnch', '.omp', '.claude', '.codex', '.gemini', '.qwen', '.opencode', 'node_modules')
    foreach ($rootValue in @($roots | Where-Object { $_ })) {
        $root = Resolve-LnchDatastorePath $rootValue
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $key = Get-LnchProjectKey $root
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $result += $root }
        foreach ($child in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $skipDirectories -notcontains $_.Name })) {
            $childKey = Get-LnchProjectKey $child.FullName
            if (-not $seen.ContainsKey($childKey)) { $seen[$childKey] = $true; $result += $child.FullName }
            foreach ($grandchild in @(Get-ChildItem -LiteralPath $child.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $skipDirectories -notcontains $_.Name })) {
                $grandchildKey = Get-LnchProjectKey $grandchild.FullName
                if (-not $seen.ContainsKey($grandchildKey)) { $seen[$grandchildKey] = $true; $result += $grandchild.FullName }
            }
        }
    }
    @($result)
}

function script:Add-LnchProjectMarkers {
    param([string]$Agent, [string[]]$Directories, [hashtable]$Projects)
    $markers = switch ($Agent) {
        'omp'      { @('.omp') }
        'claude'   { @('.claude') }
        'codex'    { @('.codex') }
        'gemini'   { @('.gemini') }
        'aider'    { @('.aider.chat.history.md', '.aider.input.history', '.aider.conf.yml', '.aider.tags.cache.v3', '.aider.tags.cache.v4') }
        'opencode' { @('.opencode', 'opencode.json', 'opencode.jsonc') }
        'qwen'     { @('.qwen') }
        default    { @() }
    }
    foreach ($directory in $Directories) {
        $hits = @($markers | Where-Object { Test-Path -LiteralPath (Join-Path $directory $_) })
        if ($hits.Count -eq 0) { continue }
        $last = $null
        foreach ($marker in $hits) {
            try {
                $item = Get-Item -LiteralPath (Join-Path $directory $marker) -ErrorAction Stop
                if (-not $last -or $item.LastWriteTimeUtc -gt $last) { $last = $item.LastWriteTimeUtc }
            } catch { }
        }
        $sessionCount = if ($Agent -eq 'aider' -and (Test-Path -LiteralPath (Join-Path $directory '.aider.chat.history.md'))) { 1 } else { 0 }
        Add-LnchAgentProject $Projects $directory $directory 'project-marker' $sessionCount $last 'inferred'
    }
}

function script:Get-LnchAgentProjectEvidence {
    param([object]$AgentState, [string[]]$KnownDirectories)
    $agent = $AgentState.Agent
    $projects = @{}
    $notes = @()
    $completeness = if ($AgentState.Status -eq 'absent') { 'not-found' } else { 'complete' }

    switch ($agent) {
        'omp' {
            foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -in @('agent-home', 'xdg-home') -and $_.Readable })) {
                $sessions = Join-Path $store.Path 'sessions'
                if (-not (Test-Path -LiteralPath $sessions -PathType Container)) { continue }
                foreach ($bucket in @(Get-ChildItem -LiteralPath $sessions -Directory -ErrorAction SilentlyContinue)) {
                    $files = @(Get-ChildItem -LiteralPath $bucket.FullName -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
                    if ($files.Count -eq 0) { continue }
                    $resolved = Add-LnchJsonlProjectEvidence 'omp' $files $projects $bucket.Name 'session-jsonl'
                    if ($resolved -eq 0) {
                        $latest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                        Add-LnchAgentProject $projects $null $bucket.Name 'encoded-session-bucket' $files.Count $latest.LastWriteTimeUtc 'unresolved'
                    }
                }
            }
        }
        'claude' {
            foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'global-state' -and $_.Readable })) {
                try {
                    $state = Get-Content -LiteralPath $store.Path -Raw | ConvertFrom-Json
                    foreach ($property in @($state.projects.PSObject.Properties)) {
                        Add-LnchAgentProject $projects $property.Name $property.Name 'global-project-index' 0 $null 'verified'
                    }
                } catch { $notes += "Could not parse Claude global project index: $($store.Path)"; $completeness = 'partial' }
            }
            foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'user-home' -and $_.Readable })) {
                $container = Join-Path $store.Path 'projects'
                if (-not (Test-Path -LiteralPath $container -PathType Container)) { continue }
                foreach ($projectDir in @(Get-ChildItem -LiteralPath $container -Directory -ErrorAction SilentlyContinue)) {
                    $files = @(Get-ChildItem -LiteralPath $projectDir.FullName -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
                    $resolved = Add-LnchJsonlProjectEvidence 'claude' $files $projects $projectDir.Name 'session-jsonl'
                    if ($files.Count -gt 0 -and $resolved -eq 0) {
                        $latest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                        Add-LnchAgentProject $projects $null $projectDir.Name 'encoded-project-directory' $files.Count $latest.LastWriteTimeUtc 'unresolved'
                    }
                }
            }
        }
        'codex' {
            foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'user-home' -and $_.Readable })) {
                foreach ($directoryName in @('sessions', '.sessions', 'archived_sessions')) {
                    $container = Join-Path $store.Path $directoryName
                    if (-not (Test-Path -LiteralPath $container -PathType Container)) { continue }
                    $files = @(Get-ChildItem -LiteralPath $container -File -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue)
                    $null = Add-LnchJsonlProjectEvidence 'codex' $files $projects $null 'rollout-jsonl'
                }
            }
        }
        'gemini' {
            foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'user-home' -and $_.Readable })) {
                $registryPath = Join-Path $store.Path 'projects.json'
                $slugs = @{}
                if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
                    try {
                        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
                        foreach ($property in @($registry.projects.PSObject.Properties)) {
                            $slug = [string]$property.Value
                            $slugs[$slug] = $true
                            $chats = Join-Path $store.Path "tmp\$slug\chats"
                            $files = if (Test-Path -LiteralPath $chats -PathType Container) { @(Get-ChildItem -LiteralPath $chats -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.json', '.jsonl') }) } else { @() }
                            $latest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                            Add-LnchAgentProject $projects $property.Name $slug 'projects.json' $files.Count $(if ($latest) { $latest.LastWriteTimeUtc } else { $null }) 'verified'
                        }
                    } catch { $notes += "Could not parse Gemini project registry: $registryPath"; $completeness = 'partial' }
                }
                foreach ($baseName in @('tmp', 'history')) {
                    $base = Join-Path $store.Path $baseName
                    if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
                    foreach ($slugDir in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
                        $marker = Join-Path $slugDir.FullName '.project_root'
                        if (Test-Path -LiteralPath $marker -PathType Leaf) {
                            try {
                                $owner = (Get-Content -LiteralPath $marker -Raw).Trim()
                                Add-LnchAgentProject $projects $owner $slugDir.Name 'project-root-marker' 0 $slugDir.LastWriteTimeUtc 'verified'
                                $slugs[$slugDir.Name] = $true
                            } catch { }
                        } elseif ($baseName -eq 'tmp' -and -not $slugs.ContainsKey($slugDir.Name) -and (Test-Path -LiteralPath (Join-Path $slugDir.FullName 'chats'))) {
                            $files = @(Get-ChildItem -LiteralPath (Join-Path $slugDir.FullName 'chats') -File -ErrorAction SilentlyContinue)
                            $latest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                            Add-LnchAgentProject $projects $null $slugDir.Name 'unindexed-project-directory' $files.Count $(if ($latest) { $latest.LastWriteTimeUtc } else { $null }) 'unresolved'
                        }
                    }
                }
            }
        }
        'aider' {
            Add-LnchProjectMarkers 'aider' $KnownDirectories $projects
            $notes += 'Aider has no global project registry; historical discovery is bounded to configured/common roots and projects known by another agent.'
            $completeness = 'partial'
        }
        'opencode' {
            foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'data-home' -and $_.Readable })) {
                $legacy = Join-Path $store.Path 'storage\session'
                if (Test-Path -LiteralPath $legacy -PathType Container) {
                    foreach ($file in @(Get-ChildItem -LiteralPath $legacy -File -Recurse -Filter '*.json' -ErrorAction SilentlyContinue)) {
                        try {
                            $session = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                            $directory = if ($session.directory) { $session.directory } elseif ($session.path -and $session.path.root) { $session.path.root } else { $null }
                            if ($directory) { Add-LnchAgentProject $projects $directory $session.id 'legacy-session-json' 1 $file.LastWriteTimeUtc 'verified' }
                        } catch { }
                    }
                }
            }
            $command = if ($AgentState.Executable) { $AgentState.Executable } else { $null }
            if ($command) {
                try {
                    $raw = (& $command session list --format json 2>$null) -join [Environment]::NewLine
                    $start = $raw.IndexOf('[')
                    $end = $raw.LastIndexOf(']')
                    if ($start -ge 0 -and $end -ge $start) {
                        foreach ($session in @(($raw.Substring($start, $end - $start + 1)) | ConvertFrom-Json)) {
                            Add-LnchAgentProject $projects $session.directory $session.projectId 'native-session-list' 1 $session.updated 'verified'
                        }
                    }
                } catch { $notes += 'OpenCode native project listing failed.'; $completeness = 'partial' }
            }
            $hasDatabase = @($AgentState.Datastores | Where-Object { $_.Kind -eq 'data-home' -and (Test-Path -LiteralPath (Join-Path $_.Path 'opencode.db')) }).Count -gt 0
            if ($hasDatabase -and -not $command) {
                $notes += 'OpenCode SQLite datastore found without a compatible opencode CLI; current SQLite projects are not readable dependency-free.'
                $completeness = 'partial'
            }
        }
        'qwen' {
            foreach ($store in @($AgentState.Datastores | Where-Object { $_.Kind -eq 'runtime-home' -and $_.Readable })) {
                $container = Join-Path $store.Path 'projects'
                if (-not (Test-Path -LiteralPath $container -PathType Container)) { continue }
                foreach ($projectDir in @(Get-ChildItem -LiteralPath $container -Directory -ErrorAction SilentlyContinue)) {
                    $chats = Join-Path $projectDir.FullName 'chats'
                    if (-not (Test-Path -LiteralPath $chats -PathType Container)) { continue }
                    $files = @(Get-ChildItem -LiteralPath $chats -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
                    $resolved = Add-LnchJsonlProjectEvidence 'qwen' $files $projects $projectDir.Name 'session-jsonl'
                    if ($files.Count -gt 0 -and $resolved -eq 0) {
                        $latest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                        Add-LnchAgentProject $projects $null $projectDir.Name 'encoded-project-directory' $files.Count $latest.LastWriteTimeUtc 'unresolved'
                    }
                }
            }
        }
    }

    if ($agent -ne 'aider') { Add-LnchProjectMarkers $agent $KnownDirectories $projects }
    $projectList = @(ConvertFrom-LnchAgentProjectMap $projects)
    if ($projectList.Count -gt 0 -and $completeness -eq 'not-found') { $completeness = 'partial' }
    [pscustomobject][ordered]@{
        Completeness = $completeness
        Projects     = $projectList
        Notes        = @($notes)
    }
}

function script:Merge-LnchDiscoveredProjects {
    param([object[]]$Agents)
    $workspaces = @{}
    foreach ($agentState in $Agents) {
        foreach ($project in @($agentState.Projects | Where-Object { $_.Path })) {
            $key = Get-LnchProjectKey $project.Path
            if (-not $key) { continue }
            if (-not $workspaces.ContainsKey($key)) {
                $workspaces[$key] = @{
                    Id           = Get-LnchWorkspaceId $project.Path
                    Path         = ConvertTo-LnchProjectPath $project.Path
                    LastActivity = $null
                    Sources      = @()
                }
            }
            $workspace = $workspaces[$key]
            $activity = ConvertTo-LnchActivityTime $project.LastActivity
            if ($activity -and (-not $workspace.LastActivity -or $activity -gt $workspace.LastActivity)) {
                $workspace.LastActivity = $activity
            }
            $workspace.Sources += [pscustomobject][ordered]@{
                Agent         = $agentState.Agent
                NativeKeys    = @($project.NativeKeys)
                SessionCount  = $project.SessionCount
                LastActivity  = $project.LastActivity
                Confidence    = $project.Confidence
                Sources       = @($project.Sources)
            }
        }
    }
    @($workspaces.Values | Sort-Object Path | ForEach-Object {
        $agentNames = @($_.Sources.Agent | Sort-Object -Unique)
        $exists = $false
        try { $exists = Test-Path -LiteralPath $_.Path -PathType Container } catch { }
        $name = try { Split-Path -Path $_.Path -Leaf } catch { $_.Path }
        [pscustomobject][ordered]@{
            Id           = $_.Id
            Name         = $name
            Path         = $_.Path
            Exists       = [bool]$exists
            LastActivity = if ($_.LastActivity) { $_.LastActivity.ToUniversalTime().ToString('o') } else { $null }
            Agents       = $agentNames
            Sources      = @($_.Sources)
        }
    })
}

function global:Get-LnchProjectInventory {
    [CmdletBinding()]
    param()
    $datastores = @(Get-LnchAgentDatastores)
    $knownDirectories = @(Get-LnchDiscoveryDirectories)
    $results = @{}

    foreach ($agentName in @($script:BuiltInAgentNames | Where-Object { $_ -ne 'aider' })) {
        $agentState = $datastores | Where-Object Agent -eq $agentName | Select-Object -First 1
        $evidence = Get-LnchAgentProjectEvidence -AgentState $agentState -KnownDirectories $knownDirectories
        $results[$agentName] = $evidence
        foreach ($project in @($evidence.Projects | Where-Object { $_.Path })) {
            if ($knownDirectories -notcontains $project.Path) { $knownDirectories += $project.Path }
        }
    }
    $aiderState = $datastores | Where-Object Agent -eq 'aider' | Select-Object -First 1
    $results['aider'] = Get-LnchAgentProjectEvidence -AgentState $aiderState -KnownDirectories $knownDirectories

    $agents = @($script:BuiltInAgentNames | ForEach-Object {
        $name = $_
        $base = $datastores | Where-Object Agent -eq $name | Select-Object -First 1
        $projectState = $results[$name]
        [pscustomobject][ordered]@{
            Agent             = $base.Agent
            Installed         = $base.Installed
            Executable        = $base.Executable
            Version           = $base.Version
            Status            = $base.Status
            Discovery         = $base.Discovery
            ProjectDiscovery  = $projectState.Completeness
            Datastores        = @($base.Datastores)
            Projects          = @($projectState.Projects)
            Notes             = @($base.Notes) + @($projectState.Notes)
        }
    })

    [pscustomobject][ordered]@{
        Schema      = 2
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        Agents      = $agents
        Projects    = @(Merge-LnchDiscoveredProjects $agents)
    }
}

function global:Get-LnchAgentProjects {
    [CmdletBinding()]
    param([string[]]$Agent)
    $inventory = Get-LnchProjectInventory
    foreach ($agentState in $inventory.Agents) {
        if ($Agent -and $Agent -notcontains $agentState.Agent) { continue }
        foreach ($project in $agentState.Projects) {
            [pscustomobject][ordered]@{
                Agent         = $agentState.Agent
                Name          = $project.Name
                Path          = $project.Path
                Exists        = $project.Exists
                NativeKeys    = @($project.NativeKeys)
                SessionCount  = $project.SessionCount
                LastActivity  = $project.LastActivity
                Confidence    = $project.Confidence
                Sources       = @($project.Sources)
            }
        }
    }
}
