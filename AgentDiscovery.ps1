# Read-only datastore discovery for the seven built-in lnch agents.

function script:Get-LnchDiscoveryHome {
    $homePath = $env:LNCH_DISCOVERY_HOME
    if (-not $homePath) { $homePath = [Environment]::GetFolderPath('UserProfile') }
    if (-not $homePath) { $homePath = $env:USERPROFILE }
    if (-not $homePath) { $homePath = $env:HOME }
    if (-not $homePath) { throw 'could not resolve the user home directory' }
    [System.IO.Path]::GetFullPath($homePath)
}

function script:Resolve-LnchDatastorePath {
    param([string]$Path, [string]$Base)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $value = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    $homePath = Get-LnchDiscoveryHome
    if ($value -eq '~') { $value = $homePath }
    elseif ($value -match '^~[\\/]') { $value = Join-Path $homePath $value.Substring(2) }
    if (-not [System.IO.Path]::IsPathRooted($value)) {
        $origin = if ($Base) { $Base } else { (Get-Location).Path }
        $value = Join-Path $origin $value
    }
    try { [System.IO.Path]::GetFullPath($value) } catch { $value }
}

function script:Test-LnchDatastoreReadable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            $stream.Dispose()
        } else {
            $enumerator = [System.IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator()
            try { $null = $enumerator.MoveNext() } finally {
                if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
            }
        }
        return $true
    } catch {
        return $false
    }
}

function script:Add-LnchDatastore {
    param(
        [System.Collections.Generic.List[object]]$Stores,
        [string]$Kind,
        [string]$Role,
        [string]$Path,
        [string]$Source,
        [switch]$OnlyWhenPresent
    )
    $resolved = Resolve-LnchDatastorePath -Path $Path
    if (-not $resolved) { return }
    $exists = $false
    try { $exists = Test-Path -LiteralPath $resolved } catch { }
    if ($OnlyWhenPresent -and -not $exists) { return }
    foreach ($store in $Stores) {
        if ($store.Kind -eq $Kind -and $store.Path -eq $resolved) { return }
    }
    $pathType = if (-not $exists) { 'missing' } elseif (Test-Path -LiteralPath $resolved -PathType Leaf) { 'file' } else { 'directory' }
    $Stores.Add([pscustomobject][ordered]@{
        Kind     = $Kind
        Role     = $Role
        Path     = $resolved
        Source   = $Source
        PathType = $pathType
        Exists   = [bool]$exists
        Readable = if ($exists) { [bool](Test-LnchDatastoreReadable $resolved) } else { $false }
    }) | Out-Null
}

function script:Add-LnchDefaultStoreWhenDistinct {
    param(
        [System.Collections.Generic.List[object]]$Stores,
        [string]$Kind,
        [string]$Role,
        [string]$Path,
        [string]$PrimaryPath
    )
    $resolved = Resolve-LnchDatastorePath $Path
    $primary = Resolve-LnchDatastorePath $PrimaryPath
    if ($resolved -ne $primary) {
        Add-LnchDatastore $Stores $Kind $Role $resolved 'default-scan' -OnlyWhenPresent
    }
}

function script:Get-LnchAgentDatastoreCandidates {
    param([string]$Agent)
    $stores = New-Object 'System.Collections.Generic.List[object]'
    $homePath = Get-LnchDiscoveryHome

    switch ($Agent) {
        'omp' {
            $defaultRoot = Join-Path $homePath '.omp\agent'
            if ($env:PI_CODING_AGENT_DIR) {
                Add-LnchDatastore $stores 'agent-home' 'config-sessions-memory-auth' $env:PI_CODING_AGENT_DIR 'PI_CODING_AGENT_DIR'
                Add-LnchDefaultStoreWhenDistinct $stores 'agent-home' 'config-sessions-memory-auth' $defaultRoot $env:PI_CODING_AGENT_DIR
            } elseif ($env:OMP_PROFILE -and $env:OMP_PROFILE.Trim() -notin @('', 'default')) {
                $profileRoot = Join-Path $homePath ".omp\profiles\$($env:OMP_PROFILE.Trim())\agent"
                Add-LnchDatastore $stores 'agent-home' 'config-sessions-memory-auth' $profileRoot 'OMP_PROFILE'
                Add-LnchDefaultStoreWhenDistinct $stores 'agent-home' 'config-sessions-memory-auth' $defaultRoot $profileRoot
            } else {
                Add-LnchDatastore $stores 'agent-home' 'config-sessions-memory-auth' $defaultRoot 'default'
            }
            $profiles = Join-Path $homePath '.omp\profiles'
            if (Test-Path -LiteralPath $profiles -PathType Container) {
                foreach ($profileDir in @(Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue)) {
                    Add-LnchDatastore $stores 'agent-home' 'config-sessions-memory-auth' (Join-Path $profileDir.FullName 'agent') 'profile-scan'
                }
            }
            foreach ($xdgName in @('XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME')) {
                $xdg = [Environment]::GetEnvironmentVariable($xdgName)
                if ($xdg) {
                    Add-LnchDatastore $stores 'xdg-home' 'split-data-state-cache' (Join-Path $xdg 'omp') $xdgName -OnlyWhenPresent
                }
            }
        }
        'claude' {
            $defaultRoot = Join-Path $homePath '.claude'
            $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $defaultRoot }
            Add-LnchDatastore $stores 'user-home' 'config-sessions-memory-plugins' $root $(if ($env:CLAUDE_CONFIG_DIR) { 'CLAUDE_CONFIG_DIR' } else { 'default' })
            Add-LnchDefaultStoreWhenDistinct $stores 'user-home' 'config-sessions-memory-plugins' $defaultRoot $root
            Add-LnchDatastore $stores 'global-state' 'auth-mcp-trust-app-state' (Join-Path $homePath '.claude.json') 'default'
        }
        'codex' {
            $defaultRoot = Join-Path $homePath '.codex'
            $root = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { $defaultRoot }
            Add-LnchDatastore $stores 'user-home' 'config-sessions-memory-auth' $root $(if ($env:CODEX_HOME) { 'CODEX_HOME' } else { 'default' })
            Add-LnchDefaultStoreWhenDistinct $stores 'user-home' 'config-sessions-memory-auth' $defaultRoot $root
        }
        'gemini' {
            $defaultRoot = Join-Path $homePath '.gemini'
            $root = if ($env:GEMINI_CLI_HOME) { Join-Path $env:GEMINI_CLI_HOME '.gemini' } else { $defaultRoot }
            Add-LnchDatastore $stores 'user-home' 'config-sessions-memory-auth' $root $(if ($env:GEMINI_CLI_HOME) { 'GEMINI_CLI_HOME' } else { 'default' })
            Add-LnchDefaultStoreWhenDistinct $stores 'user-home' 'config-sessions-memory-auth' $defaultRoot $root
        }
        'aider' {
            Add-LnchDatastore $stores 'user-state' 'analytics-only' (Join-Path $homePath '.aider') 'default'
            Add-LnchDatastore $stores 'user-config' 'layered-config-possibly-secrets' (Join-Path $homePath '.aider.conf.yml') 'default'
        }
        'opencode' {
            $defaultData = Join-Path $homePath '.local\share\opencode'
            $dataRoot = if ($env:XDG_DATA_HOME) { Join-Path $env:XDG_DATA_HOME 'opencode' } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'opencode' } else { $defaultData }
            Add-LnchDatastore $stores 'data-home' 'sessions-projects-auth-logs' $dataRoot $(if ($env:XDG_DATA_HOME) { 'XDG_DATA_HOME' } elseif ($env:LOCALAPPDATA) { 'LOCALAPPDATA' } else { 'default' })
            Add-LnchDefaultStoreWhenDistinct $stores 'data-home' 'sessions-projects-auth-logs' $defaultData $dataRoot

            $defaultConfig = Join-Path $homePath '.config\opencode'
            $configRoot = if ($env:OPENCODE_CONFIG_DIR) { $env:OPENCODE_CONFIG_DIR } elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'opencode' } elseif ($env:APPDATA) { Join-Path $env:APPDATA 'opencode' } else { $defaultConfig }
            Add-LnchDatastore $stores 'config-home' 'config-agents-skills-plugins' $configRoot $(if ($env:OPENCODE_CONFIG_DIR) { 'OPENCODE_CONFIG_DIR' } elseif ($env:XDG_CONFIG_HOME) { 'XDG_CONFIG_HOME' } elseif ($env:APPDATA) { 'APPDATA' } else { 'default' })
            Add-LnchDefaultStoreWhenDistinct $stores 'config-home' 'config-agents-skills-plugins' $defaultConfig $configRoot

            if ($env:OPENCODE_CONFIG) { Add-LnchDatastore $stores 'config-file' 'runtime-config-override' $env:OPENCODE_CONFIG 'OPENCODE_CONFIG' }
            if ($env:XDG_CACHE_HOME) { Add-LnchDatastore $stores 'cache-home' 'derived-cache' (Join-Path $env:XDG_CACHE_HOME 'opencode') 'XDG_CACHE_HOME' }
            if ($env:XDG_STATE_HOME) { Add-LnchDatastore $stores 'state-home' 'locks-runtime-state' (Join-Path $env:XDG_STATE_HOME 'opencode') 'XDG_STATE_HOME' }
            Add-LnchDatastore $stores 'cache-home' 'derived-cache' (Join-Path $homePath '.cache\opencode') 'xdg-default' -OnlyWhenPresent
            Add-LnchDatastore $stores 'state-home' 'locks-runtime-state' (Join-Path $homePath '.local\state\opencode') 'xdg-default' -OnlyWhenPresent
        }
        'qwen' {
            $defaultRoot = Join-Path $homePath '.qwen'
            $root = if ($env:QWEN_HOME) { $env:QWEN_HOME } else { $defaultRoot }
            Add-LnchDatastore $stores 'user-home' 'config-memory-auth-extensions' $root $(if ($env:QWEN_HOME) { 'QWEN_HOME' } else { 'default' })
            Add-LnchDefaultStoreWhenDistinct $stores 'user-home' 'config-memory-auth-extensions' $defaultRoot $root
            $runtime = if ($env:QWEN_RUNTIME_DIR) { $env:QWEN_RUNTIME_DIR } else { $root }
            Add-LnchDatastore $stores 'runtime-home' 'sessions-workflows-tool-results' $runtime $(if ($env:QWEN_RUNTIME_DIR) { 'QWEN_RUNTIME_DIR' } else { 'user-home' })
        }
    }
    return $stores.ToArray()
}

function script:Get-LnchAgentVersion {
    param([System.Management.Automation.ApplicationInfo]$Command)
    if (-not $Command) { return $null }
    try {
        $output = @(& $Command.Source --version 2>&1)
        $line = $output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
        if ($line) { return ([string]$line).Trim() }
    } catch { }
    try {
        $version = $Command.FileVersionInfo.ProductVersion
        if ($version) { return $version }
    } catch { }
    $null
}

function global:Get-LnchAgentDatastores {
    [CmdletBinding()]
    param()
    foreach ($agent in $script:BuiltInAgentNames) {
        $command = @(Get-Command $agent -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
        $stores = @(Get-LnchAgentDatastoreCandidates -Agent $agent)
        $found = @($stores | Where-Object { $_.Exists }).Count -gt 0
        $readable = @($stores | Where-Object { $_.Readable }).Count -gt 0
        $status = if ($command -and $readable) { 'ready' } elseif ($command) { 'binary-only' } elseif ($found) { 'store-only' } else { 'absent' }
        $notes = @()
        if ($agent -eq 'aider') { $notes += 'Aider has no global project/session store; its histories and caches are project-local.' }
        foreach ($store in @($stores | Where-Object { $_.Exists -and -not $_.Readable })) {
            $notes += "Datastore is not readable: $($store.Path)"
        }
        [pscustomobject][ordered]@{
            Agent      = $agent
            Installed  = [bool]$command
            Executable = if ($command) { $command.Source } else { $null }
            Version    = Get-LnchAgentVersion $command
            Status     = $status
            Discovery  = if ($agent -eq 'aider') { 'partial' } else { 'complete' }
            Datastores = @($stores)
            Notes      = @($notes)
        }
    }
}

function global:Show-LnchAgentDatastores {
    [CmdletBinding()]
    param([switch]$Json)
    $inventory = Get-LnchProjectInventory
    if ($Json) {
        ConvertTo-Json -InputObject $inventory -Depth 10
        return
    }

    Write-Host '== lnch agent and project discovery =='
    foreach ($item in $inventory.Agents) {
        $tag = switch ($item.Status) { 'ready' { 'ok' } 'store-only' { 'db' } 'binary-only' { 'bin' } default { '--' } }
        $version = if ($item.Version) { " | $($item.Version)" } else { '' }
        Write-Host ("[{0}] {1,-9} {2}{3} | projects={4} ({5})" -f $tag, $item.Agent, $item.Status, $version, $item.Projects.Count, $item.ProjectDiscovery)
        if ($item.Executable) { Write-Host ("          executable: {0}" -f $item.Executable) }
        foreach ($store in $item.Datastores) {
            $storeTag = if ($store.Readable) { 'ok' } elseif ($store.Exists) { '!!' } else { '--' }
            Write-Host ("          [{0}] {1,-12} {2} ({3})" -f $storeTag, $store.Kind, $store.Path, $store.Source)
        }
        foreach ($project in $item.Projects) {
            $projectPath = if ($project.Path) { $project.Path } else { "<unresolved:$($project.NativeKeys -join ',')>" }
            $activity = if ($project.LastActivity) { $project.LastActivity } else { '-' }
            Write-Host ("               {0} | sessions={1} | active={2}" -f $projectPath, $project.SessionCount, $activity)
        }
        foreach ($note in $item.Notes) { Write-Host ("          note: {0}" -f $note) }
    }

    Write-Host ''
    Write-Host ("== unified projects ({0}) ==" -f $inventory.Projects.Count)
    foreach ($project in $inventory.Projects) {
        Write-Host ("     {0} | agents={1} | active={2}" -f $project.Path, ($project.Agents -join ','), $(if ($project.LastActivity) { $project.LastActivity } else { '-' }))
    }
}
