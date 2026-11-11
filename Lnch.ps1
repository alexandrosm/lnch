# lnch: the `lnch` command for PowerShell.
#
#   lnch                      open the live project dashboard;
#                              Enter opens the selected project in a new tab
#   lnch <name> [words...]    create <root>\<name> + git repo, launch agent inline;
#                              extra words become the saved intent
#   lnch -Top                 open the dashboard without launching
#   lnch <name> ... -Yolo     shorthand for the :yolo capability
#
#   CAPABILITY VERBS (may appear anywhere among the prompt words):
#     :pick              resume, choosing among past sessions
#     :plan :edits       approval ladder (where the agent supports it)
#     :yolo              auto-approve everything
#     :model <value>     pin the model for this session
#   A verb an agent does not implement warns and is skipped - never a raw CLI error.
#
#   New projects are seeded with AGENTS.md (+ CLAUDE.md/GEMINI.md pointers), and any
#   postCreate commands from config.json run inside the fresh directory.
#
#   Reopening an existing project uses the newest native session activity or
#   confirmed lnch launch for that exact directory. Instruction scaffolds are
#   not evidence of agent usage; an explicit -Agent always wins.
#
#   AGENT REGISTRY: built-ins below; an optional agents.json next to this script
#   merges over them. Two accepted shapes per agent:
#     v2:  "caps": { "resume": {"args":["-c"]}, "mode:yolo": {"args":["--flag"]} }
#          plus optional takesPromptOnResume
#     v0.3 legacy: continueArgs / takesPromptOnContinue / yoloFlags (auto-migrated)
#
#   -Here   force inline; -TerminalMode tab opts into a new tab.
#   Root:   $env:LNCH_PROJECTS_DIR, otherwise <current working directory>\projects
#   Config: %APPDATA%\lnch\config.json (override dir: $env:LNCH_CONFIG_DIR)
#   Discover: --discover [--json],
#             --sessions [project] [--include-children] [--json],
#             --transcript <agent:session-id> [--json]

$script:LnchRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:LnchVersion = '1.6.1'
$script:KnownVerbs = @('pick', 'yolo', 'plan', 'edits', 'resume', 'resume-pick', 'model')
$script:BuiltInAgentNames = @('omp', 'claude', 'codex', 'gemini', 'aider', 'opencode', 'qwen')
. (Join-Path $script:LnchRoot 'AgentDiscovery.ps1')
. (Join-Path $script:LnchRoot 'ProjectDiscovery.ps1')
. (Join-Path $script:LnchRoot 'SessionDiscovery.ps1')
. (Join-Path $script:LnchRoot 'WindowsTerminal.ps1')
. (Join-Path $script:LnchRoot 'AgentTerm.ps1')
. (Join-Path $script:LnchRoot 'TranscriptDiscovery.ps1')
. (Join-Path $script:LnchRoot 'Dashboard.ps1')

# Built-in registry: capability manifest per agent. Only VERIFIED mappings ship;
# agents.json fills the gaps (that is the point of the tent).
$script:AgentProfiles = @{
    omp = @{
        TakesPromptOnResume = $true
        Caps                = @{
            'resume'      = @{ Args = @('-c') }
            'resume-pick' = @{ Args = @('-r') }
            'mode:yolo'   = @{ Args = @('--approval-mode', 'yolo') }
            'model'       = @{ Args = @('--model') }
        }
    }
    claude = @{
        TakesPromptOnResume = $true
        Caps                = @{
            'resume'      = @{ Args = @('-c') }
            'resume-pick' = @{ Args = @('--resume') }
            'mode:yolo'   = @{ Args = @('--dangerously-skip-permissions') }
            'mode:plan'   = @{ Args = @('--permission-mode', 'plan') }
            'mode:edits'  = @{ Args = @('--permission-mode', 'acceptEdits') }
            'model'       = @{ Args = @('--model') }
        }
    }
    codex = @{
        TakesPromptOnResume = $false
        Caps                = @{
            'resume'      = @{ Args = @('resume', '--last') }
            'resume-pick' = @{ Args = @('resume') }
            'mode:yolo'   = @{ Args = @('--full-auto') }
            'model'       = @{ Args = @('-m') }
        }
    }
    gemini = @{
        TakesPromptOnResume = $true
        Caps                = @{}
    }
    aider = @{
        TakesPromptOnResume = $false
        Caps                = @{
            'resume'    = @{ Args = @('--resume') }
            'mode:yolo' = @{ Args = @('--yes-always') }
            'model'     = @{ Args = @('--model') }
        }
    }
    opencode = @{
        TakesPromptOnResume = $true
        Caps                = @{
            'resume' = @{ Args = @('--continue') }
        }
    }
    qwen = @{
        TakesPromptOnResume = $true
        Caps                = @{
            'mode:yolo' = @{ Args = @('--yolo') }
        }
    }
}

function global:Get-LnchAgentRegistry {
    # builtins -> overlay agents.json (v2 caps shape or v0.3 legacy shape)
    $table = @{}
    foreach ($k in $script:AgentProfiles.Keys) {
        $table[$k] = @{
            TakesPromptOnResume = $script:AgentProfiles[$k].TakesPromptOnResume
            Caps                = $script:AgentProfiles[$k].Caps
        }
    }
    $registry = Join-Path $script:LnchRoot 'agents.json'
    if (Test-Path -LiteralPath $registry) {
        try {
            $custom = Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json
            foreach ($prop in $custom.PSObject.Properties) {
                $e = $prop.Value
                if ($e.caps) {
                    $caps = @{}
                    foreach ($cp in $e.caps.PSObject.Properties) {
                        $caps[$cp.Name] = @{ Args = @(@($cp.Value.args) | Where-Object { $_ }) }
                    }
                    $take = if ($null -ne $e.takesPromptOnResume) { [bool]$e.takesPromptOnResume } else { $true }
                } else {
                    # v0.3 legacy shape
                    $caps = @{
                        'resume'    = @{ Args = @(@($e.continueArgs) | Where-Object { $_ }) }
                        'mode:yolo' = @{ Args = @(@($e.yoloFlags) | Where-Object { $_ }) }
                    }
                    $take = if ($null -ne $e.takesPromptOnContinue) { [bool]$e.takesPromptOnContinue } else { $true }
                }
                $table[$prop.Name] = @{ TakesPromptOnResume = $take; Caps = $caps }
            }
        } catch {
            Write-Warning "agents.json ignored (invalid JSON): $_"
        }
    }
    $table
}

$script:AgentProfiles = Get-LnchAgentRegistry

function global:Get-LnchConfigPath {
    if ($env:LNCH_CONFIG_DIR) { return $env:LNCH_CONFIG_DIR }
    $base = [Environment]::GetFolderPath('ApplicationData')
    if (-not $base) { $base = if ($env:TEMP) { $env:TEMP } else { 'C:\Windows\Temp' } }
    $path = Join-Path $base 'lnch'
    $legacy = Join-Path $base 'project-starter'
    if (-not (Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $legacy)) {
        try { Move-Item -LiteralPath $legacy -Destination $path -Force } catch {
            Copy-Item -LiteralPath $legacy -Destination $path -Recurse -Force
            Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $path
}

function global:Get-LnchProjectsRoot {
    if ($env:LNCH_PROJECTS_DIR) {
        return [System.IO.Path]::GetFullPath($env:LNCH_PROJECTS_DIR)
    }
    $cwd = (Get-Location).Path
    return [System.IO.Path]::GetFullPath((Join-Path $cwd 'projects'))
}

function global:Get-LnchUserConfig {
    $p = Join-Path (Get-LnchConfigPath) 'config.json'
    if (Test-Path -LiteralPath $p) {
        try { return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { }
    }
    $null
}

function global:Get-LnchSecondaryProjectRoots {
    $values = New-Object 'System.Collections.Generic.List[string]'
    if ($env:LNCH_SECONDARY_PROJECTS_DIRS) {
        foreach ($value in @($env:LNCH_SECONDARY_PROJECTS_DIRS -split [regex]::Escape([string][System.IO.Path]::PathSeparator))) {
            if (-not [string]::IsNullOrWhiteSpace($value)) { $values.Add($value) }
        }
    }
    $config = Get-LnchUserConfig
    if ($config -and $config.secondaryProjectRoots) {
        foreach ($value in @($config.secondaryProjectRoots)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $values.Add([string]$value) }
        }
    }

    $seen = @{}
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in $values) {
        try {
            $root = [System.IO.Path]::GetFullPath($value)
            $key = $root.TrimEnd([char[]]'\/').ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $roots.Add($root)
            }
        } catch { }
    }
    @($roots.ToArray())
}

function global:Get-LnchProjectRoots {
    param([AllowEmptyString()][string]$PrimaryRoot)
    $primary = if ([string]::IsNullOrWhiteSpace($PrimaryRoot)) {
        Get-LnchProjectsRoot
    } else {
        [System.IO.Path]::GetFullPath($PrimaryRoot)
    }
    $seen = @{}
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in @($primary) + @(Get-LnchSecondaryProjectRoots)) {
        $root = [System.IO.Path]::GetFullPath($value)
        $key = $root.TrimEnd([char[]]'\/').ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $roots.Add($root)
        }
    }
    @($roots.ToArray())
}

function global:Get-LnchDefaultAgent {
    $c = Get-LnchUserConfig
    if ($c -and $c.defaultAgent) { return $c.defaultAgent }
    $null
}

function global:Get-LnchPostCreateHook {
    $c = Get-LnchUserConfig
    if ($c -and $c.postCreate) { return @($c.postCreate) }
    @()
}

function global:Set-LnchDefaultAgent {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Agent)
    $dir = Get-LnchConfigPath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $p = Join-Path $dir 'config.json'
    $payload = [ordered]@{}
    $existing = Get-LnchUserConfig
    if ($existing) {
        foreach ($property in $existing.PSObject.Properties) { $payload[$property.Name] = $property.Value }
    }
    $payload.defaultAgent = if ([string]::IsNullOrWhiteSpace($Agent)) { $null } else { $Agent.Trim() }
    if ($PSCmdlet.ShouldProcess($p, 'write default agent config')) {
        $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $p -Encoding utf8
    }
    if ([string]::IsNullOrWhiteSpace($Agent)) { Write-Host 'default agent cleared' }
    else { Write-Host "default agent set to '$($Agent.Trim())'" }
}

$script:LnchGitHubIdentityChecked = $false
$script:LnchGitHubIdentityCache = $null

function script:Resolve-LnchGitIdentityValues {
    param(
        [AllowEmptyString()][string]$Name,
        [AllowEmptyString()][string]$Email,
        [string]$Source = 'custom',
        [string]$Label
    )
    $resolvedName = if ($null -eq $Name) { '' } else { $Name.Trim() }
    $resolvedEmail = if ($null -eq $Email) { '' } else { $Email.Trim() }
    $errorMessage = $null
    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        $errorMessage = 'Git user.name cannot be empty.'
    } elseif ([string]::IsNullOrWhiteSpace($resolvedEmail)) {
        $errorMessage = 'Git user.email cannot be empty.'
    } elseif ($resolvedEmail -notmatch '^[^@\s]+@[^@\s]+$') {
        $errorMessage = 'Git user.email must be an email address.'
    }
    [pscustomobject]@{
        Valid  = [string]::IsNullOrWhiteSpace($errorMessage)
        Name   = $resolvedName
        Email  = $resolvedEmail
        Source = $Source
        Label  = if ($Label) { $Label } else { "$resolvedName <$resolvedEmail>" }
        Custom = $Source -eq 'custom'
        Error  = $errorMessage
    }
}

function script:Get-LnchGitHubIdentity {
    if ($script:LnchGitHubIdentityChecked) { return $script:LnchGitHubIdentityCache }
    $script:LnchGitHubIdentityChecked = $true
    if ($env:LNCH_NO_GH_IDENTITY) { return $null }
    $gh = @(Get-Command gh -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $gh) { return $null }
    try {
        $json = @(& $gh.Source api user 2>$null) -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $null }
        $githubProfile = $json | ConvertFrom-Json
        if (-not $githubProfile.login) { return $null }
        $script:LnchGitHubIdentityCache = [pscustomobject]@{
            Login = [string]$githubProfile.login
            Name  = if ($githubProfile.name) { [string]$githubProfile.name } else { [string]$githubProfile.login }
            Email = if ($githubProfile.email) { [string]$githubProfile.email } else { $null }
            Id    = if ($githubProfile.id) { [long]$githubProfile.id } else { $null }
        }
    } catch {
        $script:LnchGitHubIdentityCache = $null
    }
    $script:LnchGitHubIdentityCache
}

function global:Get-LnchGitIdentityCandidates {
    $items = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $addIdentity = {
        param([string]$Id, [string]$Name, [string]$Email, [string]$Source, [string]$Prefix)
        $identity = Resolve-LnchGitIdentityValues -Name $Name -Email $Email -Source $Source
        if (-not $identity.Valid) { return }
        $key = "$($identity.Name)`0$($identity.Email)"
        if (-not $seen.Add($key)) { return }
        $items.Add([pscustomobject]@{
            Id     = $Id
            Label  = "$Prefix`: $($identity.Name) <$($identity.Email)>"
            Name   = $identity.Name
            Email  = $identity.Email
            Source = $Source
            Custom = $false
        }) | Out-Null
    }

    $config = Get-LnchUserConfig
    if ($config -and $config.gitIdentity) {
        & $addIdentity 'configured' ([string]$config.gitIdentity.name) ([string]$config.gitIdentity.email) 'configured' 'lnch default'
    }

    $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($git) {
        $globalName = @(& $git.Source config --global --get user.name 2>$null | Select-Object -First 1)
        $globalEmail = @(& $git.Source config --global --get user.email 2>$null | Select-Object -First 1)
        if ($globalName.Count -gt 0 -and $globalEmail.Count -gt 0) {
            & $addIdentity 'git-global' ([string]$globalName[0]) ([string]$globalEmail[0]) 'git-global' 'Git global'
        }
    }

    if ($env:GIT_AUTHOR_NAME -and $env:GIT_AUTHOR_EMAIL) {
        & $addIdentity 'git-environment' $env:GIT_AUTHOR_NAME $env:GIT_AUTHOR_EMAIL 'git-environment' 'Git environment'
    }

    $github = Get-LnchGitHubIdentity
    if ($github) {
        $noreplyEmail = if ($github.Id) {
            "$($github.Id)+$($github.Login)@users.noreply.github.com"
        } else {
            "$($github.Login)@users.noreply.github.com"
        }
        & $addIdentity 'github-noreply' $github.Name $noreplyEmail 'github' 'GitHub private email'
        if ($github.Email -and $github.Email -ne $noreplyEmail) {
            & $addIdentity 'github-public' $github.Name $github.Email 'github' 'GitHub public email'
        }
    }

    $items.Add([pscustomobject]@{
        Id = 'custom'; Label = 'Custom name and email...'; Name = ''; Email = ''; Source = 'custom'; Custom = $true
    }) | Out-Null
    @($items.ToArray())
}

function script:Select-LnchGitIdentity {
    param([object[]]$Candidates)
    $choices = @($Candidates)
    if ($choices.Count -eq 0) { $choices = @(Get-LnchGitIdentityCandidates) }
    Write-Host 'Choose the Git identity for this repository:'
    for ($index = 0; $index -lt $choices.Count; $index++) {
        Write-Host ('{0,3}. {1}' -f ($index + 1), $choices[$index].Label)
    }

    while ($true) {
        $answer = Read-Host 'identity number (blank = 1; q = cancel)'
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = '1' }
        if ($answer -match '^(q|quit|cancel)$') { return $null }
        if ($answer -notmatch '^\d+$') {
            Write-Warning 'Enter one of the identity numbers.'
            continue
        }
        $selectedIndex = [int]$answer - 1
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $choices.Count) {
            Write-Warning 'Enter one of the identity numbers.'
            continue
        }
        $selected = $choices[$selectedIndex]
        if (-not $selected.Custom) { return $selected }

        while ($true) {
            $customName = Read-Host 'Git user.name (blank cancels)'
            if ([string]::IsNullOrWhiteSpace($customName)) { return $null }
            $customEmail = Read-Host 'Git user.email (blank cancels)'
            if ([string]::IsNullOrWhiteSpace($customEmail)) { return $null }
            $custom = Resolve-LnchGitIdentityValues -Name $customName -Email $customEmail -Source custom
            if ($custom.Valid) { return $custom }
            Write-Warning $custom.Error
        }
    }
}

function script:Resolve-LnchRepositoryGitIdentity {
    param(
        [AllowEmptyString()][string]$GitName,
        [AllowEmptyString()][string]$GitEmail
    )
    if ($GitName -or $GitEmail) {
        $explicit = Resolve-LnchGitIdentityValues -Name $GitName -Email $GitEmail -Source custom
        if (-not $explicit.Valid) { throw $explicit.Error }
        return $explicit
    }

    $candidates = @(Get-LnchGitIdentityCandidates)
    if (Test-LnchInteractiveTerminal) { return Select-LnchGitIdentity -Candidates $candidates }
    $automatic = @($candidates | Where-Object { -not $_.Custom } | Select-Object -First 1)
    if ($automatic.Count -gt 0) { return $automatic[0] }
    throw 'No Git identity is available. Configure git user.name/user.email or pass --git-name and --git-email.'
}

function script:Set-LnchRepositoryGitIdentity {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)]$Identity
    )
    & git -C $Directory config --local user.name ([string]$Identity.Name)
    if ($LASTEXITCODE -ne 0) { throw "could not configure Git user.name for $Directory" }
    & git -C $Directory config --local user.email ([string]$Identity.Email)
    if ($LASTEXITCODE -ne 0) { throw "could not configure Git user.email for $Directory" }
    Write-Host "Git identity: $($Identity.Name) <$($Identity.Email)> [$($Identity.Source)]"
}


function script:Get-LnchRootVersion {
    param([Parameter(Mandatory)][string]$Root)
    $enginePath = Join-Path $Root 'Lnch.ps1'
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { return $null }
    try {
        $source = Get-Content -LiteralPath $enginePath -Raw
        $match = [regex]::Match($source, '\$script:LnchVersion\s*=\s*''([^'']+)''')
        if ($match.Success) { return [version]$match.Groups[1].Value }
    } catch { }
    $null
}

function script:Invoke-LnchSelfUpdate {
    $bootstrap = Join-Path $script:LnchRoot 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
        throw "bootstrap.ps1 not found under $script:LnchRoot"
    }
    $engine = try { (Get-Process -Id $PID -ErrorAction Stop).Path } catch { $null }
    if (-not $engine -or -not (Test-Path -LiteralPath $engine -PathType Leaf)) {
        $command = @(Get-Command powershell.exe, pwsh.exe -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
        if (-not $command) { throw 'PowerShell executable not found for lnch update' }
        $engine = $command.Source
    }
    $updateArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bootstrap, '-Destination', $script:LnchRoot, '-ContinueLaunch')
    & $engine @updateArgs
    $updateExitCode = $LASTEXITCODE
    if ($updateExitCode -ne 0) { throw "bootstrap exited with code $updateExitCode" }
    $installedVersion = Get-LnchRootVersion -Root $script:LnchRoot
    if (-not $installedVersion) { throw "bootstrap completed without a readable lnch version under $script:LnchRoot" }
}

function script:Invoke-LnchUpdateFlow {
    if ($env:LNCH_NO_UPDATE_CHECK) { return }

    $lock = $null
    try {
        $configDir = Get-LnchConfigPath
        if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        $lockPath = Join-Path $configDir 'update.lock'
        $deadline = [datetime]::UtcNow.AddMinutes(2)
        do {
            try {
                $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            } catch [IO.IOException] {
                if ([datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            }
        } while (-not $lock -and [datetime]::UtcNow -lt $deadline)
        if (-not $lock) {
            Write-Warning 'lnch update is still running elsewhere; continuing agent launch'
            return
        }

        Write-Host 'updating lnch before agent launch...'
        try {
            Invoke-LnchSelfUpdate
            Write-Host "lnch update complete (v$(Get-LnchRootVersion -Root $script:LnchRoot)); continuing agent launch"
        } catch {
            Write-Warning "lnch update failed ($($_.Exception.Message)); continuing agent launch"
        }
    } catch {
        Write-Warning "lnch update could not start ($($_.Exception.Message)); continuing agent launch"
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}

function global:Get-LnchProjectMetaPath {
    param([string]$Dir)
    $path = Join-Path $Dir '.lnch.json'
    $legacy = Join-Path $Dir '.ps-project.json'
    if (-not (Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $legacy)) {
        try { Move-Item -LiteralPath $legacy -Destination $path -Force } catch {
            Copy-Item -LiteralPath $legacy -Destination $path -Force
            Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
        }
    }
    return $path
}

function global:Get-ProjectAgent {
    param([string]$Dir, [hashtable]$NativeActivity)
    $projectKey = Get-LnchProjectKey $Dir
    $selected = $null
    $lastUsed = [datetime]::MinValue
    $meta = Get-LnchProjectMetaPath -Dir $Dir
    if (Test-Path -LiteralPath $meta -PathType Leaf) {
        try {
            $stored = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
            if ($stored.agent -and $script:AgentProfiles.ContainsKey($stored.agent)) {
                $selected = [string]$stored.agent
                # Legacy "updated" was written before startup, even on failure.
                # Only lastUsed is a confirmed launch timestamp.
                $confirmed = ConvertTo-LnchActivityTime $stored.lastUsed
                if ($confirmed) { $lastUsed = $confirmed }
            }
        } catch { }
    }

    # Dashboard snapshots supply one shared inventory. A launch always reads
    # fresh history, with confirmed usage bounding the files worth inspecting.
    if ($null -eq $NativeActivity) {
        $NativeActivity = Get-LnchNativeAgentActivity -Directories @($Dir) -ProjectPath $Dir -Since $lastUsed -PreferredAgent $selected
    }
    $native = $NativeActivity[$projectKey]
    if ($native -and $native.LastUsed -gt $lastUsed) { $selected = $native.Agent }
    if ($selected) { return $selected }

    # Configuration directories are weak fallback evidence, never newer usage.
    foreach ($candidate in @('claude', 'codex', 'gemini')) {
        if (Test-Path -LiteralPath (Join-Path $Dir ".$candidate") -PathType Container) { return $candidate }
    }
    $default = Get-LnchDefaultAgent
    if ($default -and $script:AgentProfiles.ContainsKey($default)) { return $default }
    'omp'
}

function global:Write-ProjectMeta {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Dir, [string]$Agent, [string]$Intent, [datetime]$UsedAt = [datetime]::UtcNow)
    $path = Get-LnchProjectMetaPath -Dir $Dir
    $prev = $null
    if (Test-Path -LiteralPath $path) {
        try { $prev = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { }
    }
    # An older concurrent session may finish after a newer launch.
    $previousUsage = if ($prev) { ConvertTo-LnchActivityTime $prev.lastUsed } else { $null }
    if ($previousUsage -and $previousUsage -gt $UsedAt.ToUniversalTime()) { return }
    if ($PSCmdlet.ShouldProcess($path, 'write project metadata')) {
        $payload = [ordered]@{}
        if ($prev) {
            foreach ($property in $prev.PSObject.Properties) { $payload[$property.Name] = $property.Value }
        }
        $payload.agent = $Agent
        $payload.intent = if ($Intent) { $Intent } elseif ($prev -and $prev.intent) { $prev.intent } else { $null }
        $payload.created = if ($prev -and $prev.created) { $prev.created } else { $UsedAt.ToUniversalTime().ToString('o') }
        $payload.updated = [datetime]::UtcNow.ToString('o')
        $payload.lastUsed = $UsedAt.ToUniversalTime().ToString('o')
        Write-LnchAtomicJson -Path $path -Value $payload
    }
}

function global:Get-LnchProjectDiskUsage {
    # Recursive byte total for one project directory. Stack-based walk:
    # skips reparse points (junction/symlink cycles) and tolerates
    # unreadable files/directories by excluding them.
    param([Parameter(Mandatory)][string]$Dir)
    $total = [long]0
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push([System.IO.Path]::GetFullPath($Dir))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $entries = $null
        try { $entries = [System.IO.Directory]::EnumerateFileSystemEntries($current) } catch { continue }
        foreach ($entry in $entries) {
            try {
                $attr = [System.IO.File]::GetAttributes($entry)
                if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($attr -band [System.IO.FileAttributes]::Directory) { $pending.Push($entry) }
                else { $total += ([System.IO.FileInfo]$entry).Length }
            } catch { }
        }
    }
    $total
}

function global:Select-LnchAgent {
    param([string[]]$Candidates)
    if ($Candidates.Count -eq 0) { return 'omp' }
    if ((@(Get-Command fzf -CommandType Application -ErrorAction SilentlyContinue)).Count -gt 0) {
        $picked = @($Candidates | Sort-Object) | fzf --height 30% --reverse --prompt 'agent> '
        if ($LASTEXITCODE -eq 0 -and $picked -and $script:AgentProfiles.ContainsKey($picked.Trim())) {
            return $picked.Trim()
        }
        return $null
    }
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        ('{0,3}. {1}' -f ($i + 1), $Candidates[$i]) | Write-Host
    }
    $answer = Read-Host 'agent number (blank = omp)'
    if ($answer -match '^\d+$') {
        $n = [int]$answer
        if ($n -ge 1 -and $n -le $Candidates.Count) { return $Candidates[$n - 1] }
    }
    $null
}

$script:LnchCliSwitchOptions = @{
    '-yolo' = 'Yolo'; '--yolo' = 'Yolo'
    '-here' = 'Here'; '--here' = 'Here'
    '-no-dashboard' = 'NoDashboard'; '--no-dashboard' = 'NoDashboard'
    '-top' = 'Top'; '--top' = 'Top'
    '-doctor' = 'Doctor'; '--doctor' = 'Doctor'
    '-discover' = 'Discover'; '--discover' = 'Discover'
    '-sessions' = 'Sessions'; '--sessions' = 'Sessions'
    '-include-children' = 'IncludeChildren'; '--include-children' = 'IncludeChildren'
    '-tabs' = 'Tabs'; '--tabs' = 'Tabs'
    '-prune' = 'Prune'; '--prune' = 'Prune'
    '-json' = 'Json'; '--json' = 'Json'
    '-version' = 'Version'; '--version' = 'Version'; '-v' = 'Version'
}

$script:LnchCliValueOptions = @{
    '-transcript' = @{ Parameter = 'Transcript'; Error = '--transcript requires a session reference' }
    '--transcript' = @{ Parameter = 'Transcript'; Error = '--transcript requires a session reference' }
    '-terminal' = @{ Parameter = 'TerminalMode'; Error = '--terminal requires a mode' }
    '--terminal' = @{ Parameter = 'TerminalMode'; Error = '--terminal requires a mode' }
    '-backend' = @{ Parameter = 'TerminalBackend'; Error = '--terminal-backend requires auto, wt, agentterm, or inline' }
    '--backend' = @{ Parameter = 'TerminalBackend'; Error = '--terminal-backend requires auto, wt, agentterm, or inline' }
    '-terminal-backend' = @{ Parameter = 'TerminalBackend'; Error = '--terminal-backend requires auto, wt, agentterm, or inline' }
    '--terminal-backend' = @{ Parameter = 'TerminalBackend'; Error = '--terminal-backend requires auto, wt, agentterm, or inline' }
    '-window' = @{ Parameter = 'TerminalWindow'; Error = '--window requires a target' }
    '--window' = @{ Parameter = 'TerminalWindow'; Error = '--window requires a target' }
    '-profile' = @{ Parameter = 'TerminalProfile'; Error = '--profile requires a name or GUID' }
    '--profile' = @{ Parameter = 'TerminalProfile'; Error = '--profile requires a name or GUID' }
    '-title-template' = @{ Parameter = 'TerminalTitle'; Error = '--title-template requires a value' }
    '--title-template' = @{ Parameter = 'TerminalTitle'; Error = '--title-template requires a value' }
    '-tab-color' = @{ Parameter = 'TabColor'; Error = '--tab-color requires #RGB or #RRGGBB' }
    '--tab-color' = @{ Parameter = 'TabColor'; Error = '--tab-color requires #RGB or #RRGGBB' }
    '-color-scheme' = @{ Parameter = 'ColorScheme'; Error = '--color-scheme requires a name' }
    '--color-scheme' = @{ Parameter = 'ColorScheme'; Error = '--color-scheme requires a name' }
    '-agentterm-path' = @{ Parameter = 'AgentTermPath'; Error = '--agentterm-path requires a value' }
    '--agentterm-path' = @{ Parameter = 'AgentTermPath'; Error = '--agentterm-path requires a value' }
    '-agentterm-home' = @{ Parameter = 'AgentTermHome'; Error = '--agentterm-home requires a value' }
    '--agentterm-home' = @{ Parameter = 'AgentTermHome'; Error = '--agentterm-home requires a value' }
    '-agentterm-port' = @{ Parameter = 'AgentTermPort'; Error = '--agentterm-port requires a port'; Integer = $true }
    '--agentterm-port' = @{ Parameter = 'AgentTermPort'; Error = '--agentterm-port requires a port'; Integer = $true }
    '-readiness-timeout' = @{ Parameter = 'ReadinessTimeoutMs'; Error = '--readiness-timeout requires milliseconds'; Integer = $true }
    '--readiness-timeout' = @{ Parameter = 'ReadinessTimeoutMs'; Error = '--readiness-timeout requires milliseconds'; Integer = $true }
    '-default-agent' = @{ Parameter = 'SetDefaultAgent'; Error = '--default-agent requires a value (<name>|none)' }
    '--default-agent' = @{ Parameter = 'SetDefaultAgent'; Error = '--default-agent requires a value (<name>|none)' }
    '-agent' = @{ Parameter = 'Agent'; Error = '--agent requires a value' }
    '--agent' = @{ Parameter = 'Agent'; Error = '--agent requires a value' }
    '-git-name' = @{ Parameter = 'GitName'; Error = '--git-name requires a value' }
    '--git-name' = @{ Parameter = 'GitName'; Error = '--git-name requires a value' }
    '-git-email' = @{ Parameter = 'GitEmail'; Error = '--git-email requires a value' }
    '--git-email' = @{ Parameter = 'GitEmail'; Error = '--git-email requires a value' }
}

function global:ConvertFrom-LnchCliArguments {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Arguments = @())

    $call = @{}
    $name = $null
    $prompt = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $token = [string]$Arguments[$index]
        if ($script:LnchCliSwitchOptions.ContainsKey($token)) {
            $call[$script:LnchCliSwitchOptions[$token]] = $true
            continue
        }
        if ($script:LnchCliValueOptions.ContainsKey($token)) {
            $option = $script:LnchCliValueOptions[$token]
            $index++
            if ($index -ge $Arguments.Count) { throw $option.Error }
            $value = [string]$Arguments[$index]
            if ($option.Integer -and $value -notmatch '^\d+$') { throw $option.Error }
            $call[$option.Parameter] = if ($option.Integer) { [int]$value } else { $value }
            continue
        }
        if ($null -eq $name) { $name = $token }
        else { $prompt.Add($token) }
    }

    if ($null -ne $name) { $call.Name = $name }
    if ($prompt.Count -gt 0) { $call.Prompt = [string[]]$prompt.ToArray() }
    $call
}

function global:lnch {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
        [string[]]$Prompt,
        [switch]$Yolo,
        [switch]$Here,
        [switch]$NoDashboard,
        [switch]$FromLauncher,
        [string]$LaunchId,
        [string]$RuntimeRoot,
        [object]$LaunchBatch,
        [string]$ResolvedRoot,
        [string]$Agent,
        [string]$GitName,
        [string]$GitEmail,
        [string]$SetDefaultAgent,
        [switch]$Doctor,
        [switch]$Discover,
        [switch]$Sessions,
        [switch]$IncludeChildren,
        [string]$Transcript,
        [switch]$Top,
        [switch]$Tabs,
        [switch]$Prune,
        [string]$TerminalMode,
        [string]$TerminalBackend,
        [string]$TerminalWindow,
        [string]$TerminalProfile,
        [string]$TerminalTitle,
        [string]$TabColor,
        [string]$ColorScheme,
        [string]$AgentTermPath,
        [string]$AgentTermHome,
        [Nullable[int]]$AgentTermPort,
        [Nullable[int]]$ReadinessTimeoutMs,
        [switch]$Json,
        [switch]$Version,
        [ref]$ExitCode
    )
    # Entry scripts request a status without mixing it into agent stdout.
    if ($null -ne $ExitCode) { $ExitCode.Value = 0 }
    # PowerShell 5.1 treats GNU-style options as positional strings. Normalize
    # recognized long options through the same parser used by cmd/bash/zsh.
    $rawCliArguments = New-Object 'System.Collections.Generic.List[string]'
    if ($PSBoundParameters.ContainsKey('Name')) { $rawCliArguments.Add([string]$Name) }
    if ($PSBoundParameters.ContainsKey('Prompt')) {
        foreach ($argument in $Prompt) { $rawCliArguments.Add([string]$argument) }
    }
    $containsLongOption = $false
    foreach ($argument in $rawCliArguments) {
        if ($argument.StartsWith('--') -and (
            $script:LnchCliSwitchOptions.ContainsKey($argument) -or
            $script:LnchCliValueOptions.ContainsKey($argument)
        )) {
            $containsLongOption = $true
            break
        }
    }
    if ($containsLongOption) {
        $normalizedCall = ConvertFrom-LnchCliArguments -Arguments $rawCliArguments.ToArray()
        foreach ($parameterName in @($PSBoundParameters.Keys)) {
            if ($parameterName -notin @('Name', 'Prompt')) {
                $normalizedCall[$parameterName] = $PSBoundParameters[$parameterName]
            }
        }
        lnch @normalizedCall
        return
    }


    # --- management modes ------------------------------------------------
    if ($Version) {
        Write-Output ("lnch v{0}" -f $script:LnchVersion)
        return
    }
    if ($Discover) {
        Show-LnchAgentDatastores -Json:$Json
        return
    }
    if ($Sessions) {
        Show-LnchSessions -Project $Name -Agent $(if ($Agent) { @($Agent) } else { $null }) -IncludeChildren:$IncludeChildren -Json:$Json
        return
    }
    if ($Transcript) {
        Show-LnchSessionTranscript -Reference $Transcript -Agent $Agent -Json:$Json
        return
    }
    if ($Top) {
        [string[]]$dashboardRoots = if ($ResolvedRoot) {
            @([System.IO.Path]::GetFullPath($ResolvedRoot))
        } else {
            @(Get-LnchProjectRoots)
        }
        Show-LnchDashboard -Root $dashboardRoots[0] -ProjectRoots $dashboardRoots -Json:$Json
        return
    }
    if ($Tabs) {
        Show-LnchTerminalSessions -Json:$Json -Prune:$Prune
        return
    }
    if ($PSBoundParameters.ContainsKey('SetDefaultAgent')) {
        Set-LnchDefaultAgent -Agent $SetDefaultAgent
        return
    }
    if ($Doctor) {
        Write-Host ("== lnch doctor (v{0}) ==" -f $script:LnchVersion)
        foreach ($tool in @('git', 'wt', 'fzf', 'pwsh', 'powershell')) {
            $c = @(Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($c) { Write-Host ("[ok] {0,-11} {1}" -f $tool, $c.Source) }
            else { Write-Host ("[--] {0,-11} not found" -f $tool) }
        }
        $verbs = @('resume', 'resume-pick', 'mode:yolo', 'mode:plan', 'model')
        Write-Host ('{0,-9} {1}' -f 'agent', ($verbs -join '  '))
        foreach ($a in ($script:AgentProfiles.Keys | Sort-Object)) {
            $exe = @(Get-Command $a -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
            $cells = foreach ($v in $verbs) {
                if ($script:AgentProfiles[$a].Caps.ContainsKey($v)) { ' yes' } else { '  - ' }
            }
            $tag = if ($exe) { 'ok' } else { '--' }
            Write-Host ("[{0}] {1,-9} {2}" -f $tag, $a, ($cells -join ' '))
        }
        $hooks = @(Get-LnchPostCreateHook)
        Write-Host ("[--] post-create hooks configured: {0}" -f $hooks.Count)
        try { $rootNow = Get-LnchProjectsRoot } catch { $rootNow = '<invalid>' }
        $writable = $false
        $probeStream = $null
        try {
            $probe = Join-Path $rootNow ('.lnch-doctor-' + [guid]::NewGuid().ToString('N') + '.tmp')
            $probeStream = [IO.FileStream]::new($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
            $writable = $true
        } catch { } finally {
            if ($probeStream) { $probeStream.Dispose() }
        }
        Write-Host ("[{0}] projects root {1} (writable={2})" -f ($(if ($writable) { 'ok' } else { '!!' })), $rootNow, $writable)
        foreach ($secondaryRoot in @(Get-LnchSecondaryProjectRoots)) {
            $available = Test-Path -LiteralPath $secondaryRoot -PathType Container
            Write-Host ("[{0}] secondary projects root {1}" -f ($(if ($available) { 'ok' } else { '--' })), $secondaryRoot)
        }
        $def = Get-LnchDefaultAgent
        Write-Host ("[--] default agent: {0}" -f ($(if ($def) { $def } else { '<unset - picker decides on new projects>' })))
        $ar = (Get-ItemProperty 'HKCU:\Software\Microsoft\Command Processor' -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
        Write-Host ("[{0}] cmd AutoRun hook" -f ($(if ($ar -match 'lnch') { 'ok' } else { '--' })))
        foreach ($rcf in @('$HOME\.bashrc', '$HOME\.zshrc')) {
            $rp = $ExecutionContext.InvokeCommand.ExpandString($rcf)
            $hit = (Test-Path -LiteralPath $rp) -and (Get-Content -LiteralPath $rp -ErrorAction SilentlyContinue | Where-Object { $_ -match 'lnch' })
            Write-Host ("[{0}] {1}" -f ($(if ($hit) { 'ok' } else { '--' })), $rp)
        }
        return
    }

    if (-not $FromLauncher -and [string]::IsNullOrWhiteSpace($Name)) {
        lnch -Top -Json:$Json -ResolvedRoot $ResolvedRoot
        return
    }

    $yoloWanted = [bool]$Yolo
    $launcherContext = $null

    if ($FromLauncher) {
        if ($RuntimeRoot) { $env:LNCH_RUNTIME_DIR = [System.IO.Path]::GetFullPath($RuntimeRoot) }
        if (-not $LaunchId) { throw 'FromLauncher requires LaunchId' }
        $launcherContext = Receive-LnchLaunchContext -LaunchId $LaunchId
        $Name             = [string]$launcherContext.Name
        $Prompt           = @($launcherContext.Prompt)
        $launcherAgent    = [string]$launcherContext.Agent
        $launcherFresh    = [bool]$launcherContext.Fresh
        $launcherRoot     = [string]$launcherContext.Root
        $launcherVerbs    = @($launcherContext.Verbs)
        if ($launcherContext.AlreadyActive) {
            Write-Host "launch $LaunchId is already active for $Name; skipping duplicate restored-tab start"
            return
        }
    }

    # --- extract known capability verbs from anywhere in the prompt -------
    $verbs = New-Object System.Collections.Generic.List[object]
    $kept  = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Prompt.Count) {
        $t = $Prompt[$i]
        if ($t -like ':*') {
            $v = $t.TrimStart(':').Trim()
            if ($script:KnownVerbs -contains $v) {
                if ($v -eq 'model') {
                    if ($i + 1 -ge $Prompt.Count) {
                        if ($launcherContext) { Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage ':model requires a value' | Out-Null }
                        Write-Error ':model requires a value (e.g. :model opus)'
                        return
                    }
                    $i++
                    $verbs.Add([pscustomobject]@{ Name = 'model'; Value = $Prompt[$i] })
                    $i++
                    continue
                }
                $verbs.Add([pscustomobject]@{ Name = $v })
                $i++
                continue
            }
        }
        $kept.Add($t)
        $i++
    }
    $Prompt = @($kept)
    if ($launcherVerbs) {
        foreach ($launcherVerb in $launcherVerbs) {
            if ($launcherVerb) { $verbs.Add($launcherVerb) }
        }
    }
    if ($yoloWanted -and -not ($verbs | Where-Object { $_.Name -eq 'yolo' })) {
        $verbs.Insert(0, [pscustomobject]@{ Name = 'yolo' })
    }

    $searchSecondaryRoots = -not $FromLauncher -and [string]::IsNullOrWhiteSpace($ResolvedRoot)
    try {
        $rootFull = if ($FromLauncher) {
            [System.IO.Path]::GetFullPath($launcherRoot)
        } elseif ($ResolvedRoot) {
            [System.IO.Path]::GetFullPath($ResolvedRoot)
        } else {
            Get-LnchProjectsRoot
        }
    } catch {
        if ($launcherContext) { Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage "projects root is invalid: $_" | Out-Null }
        Write-Error "projects root is invalid: $_"
        return
    }

    # Dashboard requests use managed tabs; named commands stay inline.
    $defaultTerminalMode = if ($null -ne $LaunchBatch) { 'tab' } else { 'inline' }

    # Defer primary-root creation until existing projects have been resolved
    # across secondary roots.

    # allow nested names (foo/bar) but never absolute paths or root escapes
    if ($Name -match '^[A-Za-z]:' -or $Name.StartsWith('\')) {
        Write-Error "'$Name' must be relative to the projects root ($rootFull)"
        return
    }
    $dir = [System.IO.Path]::GetFullPath((Join-Path $rootFull $Name))
    if (-not $dir.StartsWith($rootFull.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "'$Name' escapes the projects root ($rootFull)"
        return
    }

    if ($searchSecondaryRoots -and -not (Test-Path -LiteralPath $dir)) {
        foreach ($secondaryRoot in @(Get-LnchSecondaryProjectRoots)) {
            $secondaryRootFull = [System.IO.Path]::GetFullPath($secondaryRoot)
            if ($secondaryRootFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath $secondaryRootFull -PathType Container)) { continue }
            $secondaryDirectory = [System.IO.Path]::GetFullPath((Join-Path $secondaryRootFull $Name))
            $secondaryPrefix = $secondaryRootFull.TrimEnd('\') + '\'
            if ($secondaryDirectory.StartsWith($secondaryPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $secondaryDirectory -PathType Container)) {
                $rootFull = $secondaryRootFull
                $dir = $secondaryDirectory
                break
            }
        }
    }

    if ($launcherContext) {
        $expectedDirectory = [System.IO.Path]::GetFullPath([string]$launcherContext.Directory)
        if (-not $dir.Equals($expectedDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage "launch directory mismatch: expected $expectedDirectory got $dir" | Out-Null
            throw "launch directory mismatch: expected $expectedDirectory got $dir"
        }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            $message = "launch project no longer exists: $dir"
            Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage $message | Out-Null
            throw $message
        }
        Write-LnchTerminalReceipt -Context $launcherContext -State child-started | Out-Null
    }
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        New-Item -ItemType Directory -Path $rootFull -Force | Out-Null
    }

    $gitCommand = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $gitCommand) {
        if ($launcherContext) { Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage 'git not found in PATH' | Out-Null }
        Write-Error 'git not found in PATH'
        return
    }
    $needsGitInitialization = -not (Test-Path -LiteralPath (Join-Path $dir '.git'))
    $gitIdentity = $null
    if ($needsGitInitialization) {
        try {
            $gitIdentity = Resolve-LnchRepositoryGitIdentity -GitName $GitName -GitEmail $GitEmail
        } catch {
            $message = [string]$_.Exception.Message
            if ($launcherContext) { Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage $message | Out-Null }
            Write-Error $message
            return
        }
        if (-not $gitIdentity) {
            Write-Warning 'project creation cancelled: no Git identity selected'
            return
        }
    }

    $isNew = -not (Test-Path -LiteralPath $dir)
    # The parent creates the directory before launching a tab. Preserve whether
    # this is the project's first session independently from filesystem existence.
    $freshSession = $isNew -or ($FromLauncher -and $launcherFresh)
    if ($isNew) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "created $dir"

        # seed cross-harness instruction scaffolding (AGENTS.md standard)
        $leafName = Split-Path -Path $dir -Leaf
        $agentsMd = Join-Path $dir 'AGENTS.md'
        $claudeMd = Join-Path $dir 'CLAUDE.md'
        $geminiMd = Join-Path $dir 'GEMINI.md'
        if (-not (Test-Path -LiteralPath $agentsMd)) {
            $tpl = @(
                ('# ' + $leafName),
                '',
                '## Overview',
                '',
                'Describe the project here.',
                '',
                '## Build & Test',
                '',
                '- Build:',
                '- Test:',
                '',
                '## Code Style',
                '',
                '-',
                '',
                '## Security Notes',
                '',
                '-'
            )
            Set-Content -LiteralPath $agentsMd -Value $tpl -Encoding utf8
        }
        if (-not (Test-Path -LiteralPath $claudeMd)) {
            Set-Content -LiteralPath $claudeMd -Value '@AGENTS.md' -Encoding utf8
        }
        if (-not (Test-Path -LiteralPath $geminiMd)) {
            Set-Content -LiteralPath $geminiMd -Value 'Instructions live in AGENTS.md.' -Encoding utf8
        }
    }

    if ($needsGitInitialization) {
        & $gitCommand.Source -C $dir init -b main
        if ($LASTEXITCODE -ne 0) { & $gitCommand.Source -C $dir init }
        if ($LASTEXITCODE -ne 0) {
            if ($launcherContext) { Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage 'git init failed' | Out-Null }
            Write-Error 'git init failed'
            return
        }
        try {
            Set-LnchRepositoryGitIdentity -Directory $dir -Identity $gitIdentity
        } catch {
            $message = [string]$_.Exception.Message
            if ($launcherContext) { Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage $message | Out-Null }
            Write-Error $message
            return
        }
        Write-Host 'initialized git repo'
    }

    # --- agent resolution -------------------------------------------------
    if ($FromLauncher -and $launcherAgent) {
        $agent = $launcherAgent
    } elseif ($Agent) {
        $agent = $Agent
    } elseif (-not $freshSession) {
        $agent = Get-ProjectAgent -Dir $dir
    } else {
        $installed = @($script:AgentProfiles.Keys | Where-Object {
            @(Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue).Count -gt 0
        } | Sort-Object)
        $def = Get-LnchDefaultAgent
        if ($def -and ($installed | Where-Object { $_ -eq $def })) {
            $agent = $def
            Write-Host "using default agent '$def' (change: lnch -SetDefaultAgent <name>|none)"
        }
        elseif ($installed.Count -eq 1) { $agent = $installed[0] }
        elseif ($installed.Count -gt 1) {
            $agent = Select-LnchAgent -Candidates $installed
            if (-not $agent) { $agent = 'omp' }
            Write-Host "selected agent: $agent (make permanent: lnch -SetDefaultAgent $agent)"
        }
        else {
            $agent = 'omp'
            Write-Warning 'no registered agents found on PATH; defaulting to omp'
        }
    }
    if (-not $script:AgentProfiles.ContainsKey($agent)) {
        $message = "unknown agent '$agent' (known: $($script:AgentProfiles.Keys -join ', '))"
        if ($launcherContext) { Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage $message | Out-Null }
        Write-Error $message
        return
    }


    # Explicit options and saved policy override the invocation's default mode.
    if (-not $FromLauncher) {
        $requestedMode = if ($Here -or $TerminalBackend -eq 'inline') { 'inline' } else { $TerminalMode }
        $terminal = Get-LnchTerminalConfig -Mode $requestedMode -DefaultMode $defaultTerminalMode -Backend $TerminalBackend -Window $TerminalWindow -ProfileName $TerminalProfile -TitleTemplate $TerminalTitle -TabColor $TabColor -ColorScheme $ColorScheme -AgentTermPath $AgentTermPath -AgentTermHome $AgentTermHome -AgentTermPort $AgentTermPort -ReadinessTimeoutMs $ReadinessTimeoutMs -Agent $agent
        if ($terminal.Mode -ne 'inline' -and $terminal.Backend -ne 'inline') {
            $verbPayload = @()
            foreach ($verbItem in $verbs) { $verbPayload += $verbItem }
            $context = New-LnchLaunchContext -Name $Name -Directory $dir -Root $rootFull -Agent $agent -Prompt @($Prompt) -Verbs $verbPayload -Fresh $isNew -Terminal $terminal
            if ($null -ne $LaunchBatch) {
                $LaunchBatch.Add($context) | Out-Null
                return
            }
            $launchResult = @(Invoke-LnchTerminal -Contexts @($context))[0]
            if ($launchResult.Accepted) {
                if (-not $launchResult.Ready) { Write-Warning "terminal accepted $Name, but child readiness timed out (launch $($context.LaunchId))" }
                else { Write-Host "-> $Name opened in $($context.Terminal.Backend)" }
                if (Test-LnchDashboardAutoStart -NoDashboard:$NoDashboard) {
                    [string[]]$dashboardRoots = if ($ResolvedRoot) { @($rootFull) } else { @(Get-LnchProjectRoots) }
                    Show-LnchDashboard -Root $dashboardRoots[0] -ProjectRoots $dashboardRoots
                }
                return
            }
            Write-Warning "$($launchResult.Error); launching inline instead"
            & ${function:lnch} -FromLauncher -LaunchId $context.LaunchId -RuntimeRoot $context.RuntimeRoot -ExitCode $ExitCode
            return
        }
    }

    $invokingLocation = Get-Location
    try {
        Set-Location -LiteralPath $dir
        # --- post-create hooks (fresh projects only) ---------------------------
        if ($freshSession) {
            foreach ($h in (Get-LnchPostCreateHook)) {
                Write-Host "post-create hook: $h"
                try { Invoke-Expression $h | Out-Null } catch { Write-Warning "post-create hook failed: $_" }
            }
        }

        # --- apply capabilities ------------------------------------------------
        $p        = $script:AgentProfiles[$agent]
        $resuming = -not $freshSession
        $agentArgs = @()

        $wantsPick = @($verbs | Where-Object { $_.Name -in @('pick', 'resume-pick') }).Count -gt 0
        if ($resuming -and -not $wantsPick) {
            $rcap = $p.Caps['resume']
            if ($rcap) { $agentArgs += $rcap.Args }
            elseif ($p.Caps.Count -gt 0) { Write-Warning "$agent declares no resume capability; starting a fresh session" }
        }

        foreach ($v in $verbs) {
            $capKey = switch ($v.Name) {
                'yolo'  { 'mode:yolo' }
                'plan'  { 'mode:plan' }
                'edits' { 'mode:edits' }
                'pick'  { 'resume-pick' }
                default { $v.Name }
            }
            # Resume was applied above; an explicit picker takes precedence.
            if ($capKey -eq 'resume' -or ($capKey -eq 'resume-pick' -and -not $resuming)) { continue }
            $cap = $p.Caps[$capKey]
            if (-not $cap) {
                Write-Warning "$agent does not support :$($v.Name); skipping"
                continue
            }
            $agentArgs += $cap.Args
            if ($capKey -eq 'model') { $agentArgs += $v.Value }
        }

        if ($Prompt -and $resuming -and (-not $p.TakesPromptOnResume)) {
            Write-Warning "dropping prompt ('$($Prompt -join ' ')): cannot combine with $agent resume"
        } elseif ($Prompt) {
            $agentArgs += ($Prompt -join ' ')
        }

        # Complete any available verified update in the final execution context,
        # then continue into the requested agent regardless of update failure.
        Invoke-LnchUpdateFlow

        $verb = if ($resuming) { 'resuming' } else { 'starting' }
        Write-Host ("{0} {1} with {2} {3}" -f $verb, (Split-Path -Path $dir -Leaf), $agent, ($agentArgs -join ' '))
        if ($launcherContext) { Write-LnchTerminalReceipt -Context $launcherContext -State agent-running | Out-Null }
        $agentFailed = $false
        try {
            $agentStartedAt = [datetime]::UtcNow
            $global:LASTEXITCODE = 0
            & $agent @agentArgs
            $agentExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
            if ($null -ne $ExitCode) { $ExitCode.Value = $agentExitCode }
            if ($agentExitCode -eq 0) {
                Write-ProjectMeta -Dir $dir -Agent $agent -Intent $(if ($Prompt) { $Prompt -join ' ' } else { $null }) -UsedAt $agentStartedAt
            }
        } catch {
            $agentFailed = $true
            if ($launcherContext) { Write-LnchTerminalReceipt -Context $launcherContext -State failed -ErrorMessage ([string]$_) | Out-Null }
            throw
        } finally {
            if ($launcherContext -and -not $agentFailed) { Write-LnchTerminalReceipt -Context $launcherContext -State agent-exited -ExitCode $agentExitCode | Out-Null }
        }
    } finally {
        Set-Location -LiteralPath $invokingLocation.Path
    }
}

# <Tab> completes project names from the primary and secondary roots.
Register-ArgumentCompleter -CommandName lnch -ParameterName Name -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    try { $roots = @(Get-LnchProjectRoots) } catch { return }
    $seen = @{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Filter "$wordToComplete*" -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $key = $directory.Name.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                [System.Management.Automation.CompletionResult]::new($directory.Name)
            }
        }
    }
}
