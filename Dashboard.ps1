# Live project and agent telemetry for the lnch dashboard.

$script:LnchDashboardCpuSamples = @{}
$script:LnchDashboardDiskCache = @{}

function script:Get-LnchDashboardPathKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant() } catch { return $Path.Trim().TrimEnd('\').ToLowerInvariant() }
}

function script:Test-LnchInteractiveTerminal {
    try {
        return ($Host.Name -eq 'ConsoleHost') -and (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
    } catch {
        return $false
    }
}

function global:Test-LnchDashboardAutoStart {
    param([switch]$NoDashboard)
    if ($NoDashboard -or $env:LNCH_NO_DASHBOARD) { return $false }
    Test-LnchInteractiveTerminal
}

function script:Get-LnchDashboardProcessTable {
    $rows = @()
    try {
        $rows = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, ReadTransferCount, WriteTransferCount -ErrorAction Stop)
    } catch { }

    $native = @{}
    $children = @{}
    foreach ($row in $rows) {
        $processId = [int]$row.ProcessId
        $parentId = [int]$row.ParentProcessId
        $native[$processId] = $row
        if (-not $children.ContainsKey($parentId)) { $children[$parentId] = New-Object System.Collections.ArrayList }
        $children[$parentId].Add($processId) | Out-Null
    }
    [pscustomobject]@{ Native = $native; Children = $children }
}

function script:Get-LnchDashboardProcessTreeIds {
    param([Parameter(Mandatory)][int[]]$RootIds, [Parameter(Mandatory)]$ProcessTable)
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $queue = New-Object 'System.Collections.Generic.Queue[int]'
    foreach ($rootId in $RootIds) {
        if ($rootId -gt 0 -and $ProcessTable.Native.ContainsKey($rootId) -and $seen.Add($rootId)) { $queue.Enqueue($rootId) }
    }
    while ($queue.Count -gt 0) {
        $currentId = $queue.Dequeue()
        if (-not $ProcessTable.Children.ContainsKey($currentId)) { continue }
        foreach ($childId in @($ProcessTable.Children[$currentId])) {
            $childProcessId = [int]$childId
            if ($seen.Add($childProcessId)) { $queue.Enqueue($childProcessId) }
        }
    }
    @($seen)
}

function script:Get-LnchCachedProjectDiskUsage {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [int]$MaxAgeSeconds = 60,
        [switch]$Refresh
    )
    $key = Get-LnchDashboardPathKey $Directory
    $now = [datetime]::UtcNow
    $cached = $script:LnchDashboardDiskCache[$key]
    if ($cached -and -not $Refresh -and ($now - $cached.MeasuredAt).TotalSeconds -lt $MaxAgeSeconds) {
        return [long]$cached.Bytes
    }
    if (-not $Refresh) { return $null }
    $bytes = [long](Get-LnchProjectDiskUsage -Dir $Directory)
    $script:LnchDashboardDiskCache[$key] = [pscustomobject]@{ MeasuredAt = $now; Bytes = $bytes }
    $bytes
}

function script:Get-LnchDashboardProjectState {
    param([object[]]$Sessions)
    $active = @($Sessions | Where-Object Active)
    if (@($active | Where-Object State -eq 'agent-running').Count -gt 0) { return 'running' }
    if ($active.Count -gt 0) { return 'starting' }
    if ($Sessions.Count -eq 0) { return 'idle' }
    switch ([string]$Sessions[0].State) {
        'failed' { 'failed' }
        'stale' { 'stale' }
        'agent-exited' { if ($null -ne $Sessions[0].ExitCode -and [int]$Sessions[0].ExitCode -ne 0) { 'failed' } else { 'completed' } }
        default { 'idle' }
    }
}

function global:Get-LnchProjectDashboardSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$RefreshDisk)

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $sessions = @(Get-LnchTerminalSessions | Sort-Object UpdatedAt -Descending)
    $processTable = Get-LnchDashboardProcessTable
    $now = [datetime]::UtcNow
    $processorCount = [Math]::Max(1, [Environment]::ProcessorCount)
    $projects = New-Object System.Collections.Generic.List[object]
    $directories = if (Test-Path -LiteralPath $rootFull -PathType Container) {
        @(Get-ChildItem -LiteralPath $rootFull -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    } else { @() }

    foreach ($directory in $directories) {
        $directoryKey = Get-LnchDashboardPathKey $directory.FullName
        $projectSessions = @($sessions | Where-Object { (Get-LnchDashboardPathKey $_.Directory) -eq $directoryKey })
        $activeSessions = @($projectSessions | Where-Object Active)
        $latest = if ($projectSessions.Count -gt 0) { $projectSessions[0] } else { $null }

        $meta = $null
        $metaPath = Get-LnchProjectMetaPath -Dir $directory.FullName
        if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
            try { $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json } catch { }
        }

        $agents = @($activeSessions | ForEach-Object { [string]$_.Agent } | Where-Object { $_ } | Sort-Object -Unique)
        if ($agents.Count -eq 0 -and $latest -and $latest.Agent) { $agents = @([string]$latest.Agent) }
        if ($agents.Count -eq 0 -and $meta -and $meta.agent) { $agents = @([string]$meta.agent) }
        $agent = if ($agents.Count -gt 0) { $agents -join '+' } else { 'auto' }

        $rootIds = @($activeSessions | ForEach-Object { if ($_.Pid) { [int]$_.Pid } })
        $processIds = if ($rootIds.Count -gt 0) { @(Get-LnchDashboardProcessTreeIds -RootIds $rootIds -ProcessTable $processTable) } else { @() }
        $totalCpuSeconds = [double]0
        $workingSetBytes = [long]0
        $privateBytes = [long]0
        $readBytes = [long]0
        $writeBytes = [long]0
        $liveIds = New-Object 'System.Collections.Generic.List[int]'

        foreach ($processId in $processIds) {
            try {
                $process = Get-Process -Id $processId -ErrorAction Stop
                $totalCpuSeconds += $process.TotalProcessorTime.TotalSeconds
                $workingSetBytes += [long]$process.WorkingSet64
                $privateBytes += [long]$process.PrivateMemorySize64
                $liveIds.Add([int]$processId)
            } catch { }
            if ($processTable.Native.ContainsKey([int]$processId)) {
                $nativeProcess = $processTable.Native[[int]$processId]
                try { $readBytes += [long]$nativeProcess.ReadTransferCount } catch { }
                try { $writeBytes += [long]$nativeProcess.WriteTransferCount } catch { }
            }
        }

        $cpuPercent = [double]0
        if ($liveIds.Count -gt 0) {
            $previous = $script:LnchDashboardCpuSamples[$directoryKey]
            if ($previous) {
                $elapsedSeconds = ($now - $previous.MeasuredAt).TotalSeconds
                $cpuDelta = $totalCpuSeconds - [double]$previous.CpuSeconds
                if ($elapsedSeconds -gt 0 -and $cpuDelta -ge 0) {
                    $cpuPercent = ($cpuDelta / $elapsedSeconds / $processorCount) * 100
                }
            }
            $script:LnchDashboardCpuSamples[$directoryKey] = [pscustomobject]@{ MeasuredAt = $now; CpuSeconds = $totalCpuSeconds }
        } else {
            $script:LnchDashboardCpuSamples.Remove($directoryKey)
        }

        $diskBytes = Get-LnchCachedProjectDiskUsage -Directory $directory.FullName -Refresh:$RefreshDisk
        $state = Get-LnchDashboardProjectState -Sessions $projectSessions
        $modelSession = @($activeSessions + $projectSessions | Where-Object { $_ -and $_.PSObject.Properties['Model'] -and $_.Model } | Select-Object -First 1)
        $model = if ($modelSession.Count -gt 0) { [string]$modelSession[0].Model } else { $null }
        $updatedAt = if ($latest -and $latest.UpdatedAt) { [string]$latest.UpdatedAt } elseif ($meta -and $meta.updated) { [string]$meta.updated } else { $directory.LastWriteTimeUtc.ToString('o') }

        $projects.Add([pscustomobject][ordered]@{
            Name              = $directory.Name
            Directory         = $directory.FullName
            Agent             = $agent
            State             = $state
            StateSource       = if ($latest) { 'terminal-receipt' } else { 'filesystem' }
            ActiveSessions    = $activeSessions.Count
            LaunchIds         = @($activeSessions | ForEach-Object LaunchId)
            Pids              = @($liveIds | Sort-Object)
            ProcessCount      = $liveIds.Count
            CpuPercent        = [Math]::Round([Math]::Max(0, $cpuPercent), 1)
            CpuSeconds        = [Math]::Round($totalCpuSeconds, 1)
            WorkingSetBytes   = $workingSetBytes
            PrivateBytes      = $privateBytes
            ReadBytes         = $readBytes
            WriteBytes        = $writeBytes
            Model             = $model
            ModelSource       = if ($model) { 'launch' } else { 'unknown' }
            Cost              = $null
            CostKind          = 'unknown'
            DiskBytes         = $diskBytes
            UpdatedAt         = $updatedAt
            ExitCode          = if ($latest) { $latest.ExitCode } else { $null }
            ErrorMessage      = if ($latest) { $latest.ErrorMessage } else { $null }
        }) | Out-Null
    }

    $projectArray = @($projects.ToArray())
    $measuredDisk = @($projectArray | Where-Object { $null -ne $_.DiskBytes })
    [pscustomobject][ordered]@{
        Schema      = 1
        GeneratedAt = $now.ToString('o')
        Root        = $rootFull
        Summary     = [pscustomobject][ordered]@{
            ProjectCount   = $projectArray.Count
            ActiveProjects = @($projectArray | Where-Object { $_.ActiveSessions -gt 0 }).Count
            ActiveSessions = [int](($projectArray | Measure-Object -Property ActiveSessions -Sum).Sum)
            ProcessCount   = [int](($projectArray | Measure-Object -Property ProcessCount -Sum).Sum)
            CpuPercent     = [Math]::Round([double](($projectArray | Measure-Object -Property CpuPercent -Sum).Sum), 1)
            WorkingSetBytes = [long](($projectArray | Measure-Object -Property WorkingSetBytes -Sum).Sum)
            DiskBytes      = if ($measuredDisk.Count -gt 0) { [long](($measuredDisk | Measure-Object -Property DiskBytes -Sum).Sum) } else { $null }
            Cost           = $null
            CostKind       = 'unknown'
        }
        Projects    = $projectArray
    }
}

function script:New-LnchDashboardSnapshotWorker {
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $initializer = [System.Management.Automation.PowerShell]::Create()
    try {
        $initializer.Runspace = $runspace
        $null = $initializer.AddScript({
            param([string]$LnchRoot)
            $ErrorActionPreference = 'Stop'
            . (Join-Path $LnchRoot 'Lnch.ps1')
        }).AddArgument($script:LnchRoot)
        $null = $initializer.Invoke()
        if ($initializer.HadErrors) {
            throw (@($initializer.Streams.Error | ForEach-Object { [string]$_ }) -join '; ')
        }
    } catch {
        try { $runspace.Close() } catch { }
        $runspace.Dispose()
        throw
    } finally {
        $initializer.Dispose()
    }

    [pscustomobject]@{
        Runspace    = $runspace
        PowerShell  = $null
        AsyncResult = $null
    }
}

function script:Start-LnchDashboardSnapshotRequest {
    param(
        [Parameter(Mandatory)]$Worker,
        [Parameter(Mandatory)][string]$Root,
        [switch]$RefreshDisk
    )
    if ($Worker.PowerShell) { return $false }

    $request = [System.Management.Automation.PowerShell]::Create()
    try {
        $request.Runspace = $Worker.Runspace
        $null = $request.AddCommand('Get-LnchProjectDashboardSnapshot').AddParameter('Root', $Root)
        if ($RefreshDisk) { $null = $request.AddParameter('RefreshDisk', $true) }
        $Worker.PowerShell = $request
        $Worker.AsyncResult = $request.BeginInvoke()
        $true
    } catch {
        $request.Dispose()
        $Worker.PowerShell = $null
        $Worker.AsyncResult = $null
        throw
    }
}

function script:Receive-LnchDashboardSnapshotRequest {
    param([Parameter(Mandatory)]$Worker)
    if (-not $Worker.PowerShell -or -not $Worker.AsyncResult.IsCompleted) { return $null }

    $request = $Worker.PowerShell
    $asyncResult = $Worker.AsyncResult
    $snapshot = $null
    $errorMessage = $null
    try {
        $items = @($request.EndInvoke($asyncResult))
        if ($request.HadErrors) {
            $errorMessage = @($request.Streams.Error | ForEach-Object { [string]$_ }) -join '; '
        } else {
            $snapshot = $items | Where-Object { $_ -and $_.PSObject.Properties['Schema'] } | Select-Object -Last 1
            if (-not $snapshot) { $errorMessage = 'telemetry refresh returned no snapshot' }
        }
    } catch {
        $errorMessage = [string]$_
    } finally {
        $request.Dispose()
        $Worker.PowerShell = $null
        $Worker.AsyncResult = $null
    }

    [pscustomobject]@{
        Snapshot = $snapshot
        Error    = $errorMessage
    }
}

function script:Close-LnchDashboardSnapshotWorker {
    param($Worker)
    if (-not $Worker) { return }
    if ($Worker.PowerShell) {
        try { $Worker.PowerShell.Stop() } catch { }
        $Worker.PowerShell.Dispose()
        $Worker.PowerShell = $null
        $Worker.AsyncResult = $null
    }
    try { $Worker.Runspace.Close() } catch { }
    $Worker.Runspace.Dispose()
}

function script:Start-LnchDashboardIdentityRequest {
    $request = [System.Management.Automation.PowerShell]::Create()
    try {
        $null = $request.AddScript({
            param([string]$LnchRoot)
            $ErrorActionPreference = 'Stop'
            . (Join-Path $LnchRoot 'Lnch.ps1')
            Get-LnchGitIdentityCandidates
        }).AddArgument($script:LnchRoot)
        [pscustomobject]@{
            PowerShell  = $request
            AsyncResult = $request.BeginInvoke()
        }
    } catch {
        $request.Dispose()
        throw
    }
}

function script:Receive-LnchDashboardIdentityRequest {
    param([Parameter(Mandatory)]$Request)
    if (-not $Request.AsyncResult.IsCompleted) { return $null }
    $identities = @()
    $errorMessage = $null
    try {
        $identities = @($Request.PowerShell.EndInvoke($Request.AsyncResult) | Where-Object {
            $_ -and $_.PSObject.Properties['Id']
        })
        if ($Request.PowerShell.HadErrors) {
            $errorMessage = @($Request.PowerShell.Streams.Error | ForEach-Object { [string]$_ }) -join '; '
        } elseif ($identities.Count -eq 0) {
            $errorMessage = 'identity discovery returned no options'
        }
    } catch {
        $errorMessage = [string]$_
    } finally {
        $Request.PowerShell.Dispose()
    }
    [pscustomobject]@{
        Identities = $identities
        Error      = $errorMessage
    }
}

function script:Close-LnchDashboardIdentityRequest {
    param($Request)
    if (-not $Request -or -not $Request.PowerShell) { return }
    if (-not $Request.AsyncResult.IsCompleted) {
        try { $Request.PowerShell.Stop() } catch { }
    }
    $Request.PowerShell.Dispose()
}

function script:Format-LnchDashboardBytes {
    param([Nullable[long]]$Bytes)
    if ($null -eq $Bytes) { return '--' }
    $value = [long]$Bytes
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($value -lt 1KB) { return ([string]::Format($culture, '{0} B', $value)) }
    if ($value -lt 1MB) { return ([string]::Format($culture, '{0:0.0} KB', ($value / 1KB))) }
    if ($value -lt 1GB) { return ([string]::Format($culture, '{0:0.0} MB', ($value / 1MB))) }
    if ($value -lt 1TB) { return ([string]::Format($culture, '{0:0.0} GB', ($value / 1GB))) }
    [string]::Format($culture, '{0:0.0} TB', ($value / 1TB))
}

function script:Limit-LnchDashboardText {
    param([string]$Text, [int]$Width)
    if ($Width -le 0) { return '' }
    $value = if ([string]::IsNullOrEmpty($Text)) { '--' } else { $Text }
    if ($value.Length -le $Width) { return $value }
    if ($Width -eq 1) { return $value.Substring(0, 1) }
    $value.Substring(0, $Width - 1) + [char]0x2026
}

function script:Format-LnchDashboardCell {
    param([string]$Text, [int]$Width, [switch]$Right)
    $value = Limit-LnchDashboardText -Text $Text -Width $Width
    if ($Right) { return $value.PadLeft($Width) }
    $value.PadRight($Width)
}

function script:Get-LnchDashboardStatusDisplay {
    param([string]$State)
    $solid = [char]0x25CF
    $half = [char]0x25D0
    $check = [char]0x2713
    $circle = [char]0x25CB
    switch ($State) {
        'running' { "$solid RUNNING" }
        'starting' { "$half STARTING" }
        'failed' { "$solid FAILED" }
        'stale' { '! STALE' }
        'completed' { "$check DONE" }
        default { "$circle IDLE" }
    }
}

function script:Get-LnchDashboardSortRank {
    param([string]$State)
    switch ($State) {
        'running' { 0 }
        'starting' { 1 }
        'failed' { 2 }
        'stale' { 3 }
        'completed' { 4 }
        default { 5 }
    }
}

function script:Get-LnchDashboardOrderedProjects {
    param([Parameter(Mandatory)]$Snapshot)
    @($Snapshot.Projects | Sort-Object @{ Expression = { Get-LnchDashboardSortRank $_.State } }, Name)
}

function script:Get-LnchDashboardAvailableAgents {
    $agents = @($script:AgentProfiles.Keys | Where-Object {
        @(Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue).Count -gt 0
    } | Sort-Object)
    if ($agents.Count -eq 0) { return @('omp') }
    $agents
}

function script:New-LnchDashboardCreateState {
    param([object[]]$IdentityCandidates)
    $agents = @(Get-LnchDashboardAvailableAgents)
    $identities = if ($IdentityCandidates -and $IdentityCandidates.Count -gt 0) {
        @($IdentityCandidates)
    } else {
        @(Get-LnchGitIdentityCandidates)
    }
    $agentIndex = 0
    $defaultAgent = $null
    try { $defaultAgent = Get-LnchDefaultAgent } catch { }
    if ($defaultAgent) {
        for ($index = 0; $index -lt $agents.Count; $index++) {
            if ($agents[$index] -eq $defaultAgent) {
                $agentIndex = $index
                break
            }
        }
    }
    [pscustomobject]@{
        Name                = ''
        Agents              = $agents
        AgentIndex          = $agentIndex
        Identities          = $identities
        IdentityIndex       = 0
        CustomName          = ''
        CustomEmail         = ''
        Focus               = 0
        Error               = $null
    }
}

function script:Get-LnchDashboardCreateAgent {
    param([Parameter(Mandatory)]$CreateState)
    $agents = @($CreateState.Agents)
    if ($agents.Count -eq 0) { return 'omp' }
    $index = [Math]::Max(0, [Math]::Min([int]$CreateState.AgentIndex, $agents.Count - 1))
    [string]$agents[$index]
}

function script:Get-LnchDashboardCreateIdentity {
    param([Parameter(Mandatory)]$CreateState)
    $identities = @($CreateState.Identities)
    if ($identities.Count -eq 0) {
        return Resolve-LnchGitIdentityValues -Name $CreateState.CustomName -Email $CreateState.CustomEmail -Source custom
    }
    $index = [Math]::Max(0, [Math]::Min([int]$CreateState.IdentityIndex, $identities.Count - 1))
    $selected = $identities[$index]
    if ($selected.Custom) {
        return Resolve-LnchGitIdentityValues -Name $CreateState.CustomName -Email $CreateState.CustomEmail -Source custom
    }
    $selected
}

function script:Get-LnchDashboardCreateFocusCount {
    param([Parameter(Mandatory)]$CreateState)
    $identity = Get-LnchDashboardCreateIdentity -CreateState $CreateState
    if ($identity.Custom) { return 5 }
    3
}

function script:Resolve-LnchDashboardProjectName {
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyString()][string]$Name
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $value = if ($null -eq $Name) { '' } else { $Name.Trim() }
    $errorMessage = $null
    $directory = $null

    if ([string]::IsNullOrWhiteSpace($value)) {
        $errorMessage = 'Enter a project name.'
    } elseif ([System.IO.Path]::IsPathRooted($value) -or $value.IndexOfAny([char[]]'\/') -ge 0) {
        $errorMessage = 'Use one folder name under the projects root.'
    } elseif ($value.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        $errorMessage = 'The project name contains an invalid filename character.'
    } else {
        try {
            $directory = [System.IO.Path]::GetFullPath((Join-Path $rootFull $value))
            $prefix = $rootFull.TrimEnd([char[]]'\/') + [System.IO.Path]::DirectorySeparatorChar
            if (-not $directory.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $errorMessage = 'The project name escapes the projects root.'
            } elseif (Test-Path -LiteralPath $directory) {
                $errorMessage = "Project '$value' already exists."
            }
        } catch {
            $errorMessage = [string]$_.Exception.Message
        }
    }

    [pscustomobject]@{
        Valid     = [string]::IsNullOrWhiteSpace($errorMessage)
        Name      = $value
        Directory = $directory
        Error     = $errorMessage
    }
}

function global:Invoke-LnchDashboardProjectLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][string]$GitName,
        [Parameter(Mandatory)][string]$GitEmail
    )
    $resolved = Resolve-LnchDashboardProjectName -Root $Root -Name $Name
    if (-not $resolved.Valid) { throw $resolved.Error }

    $terminal = Get-LnchTerminalConfig -Agent $Agent
    if ($terminal.Mode -eq 'inline' -or $terminal.Backend -eq 'inline') {
        throw 'Starting a project from the dashboard requires a managed terminal backend.'
    }

    $batch = New-Object System.Collections.ArrayList
    $invoke = @{
        Name               = $resolved.Name
        Agent              = $Agent
        GitName            = $GitName
        GitEmail           = $GitEmail
        ResolvedRoot       = [System.IO.Path]::GetFullPath($Root)
        NoDashboard        = $true
        LaunchBatch        = $batch
        TerminalMode       = $terminal.Mode
        TerminalBackend    = $terminal.Backend
        TerminalWindow     = $terminal.Window
        TerminalProfile    = $terminal.Profile
        TerminalTitle      = $terminal.TitleTemplate
        TabColor           = $terminal.TabColor
        ColorScheme        = $terminal.ColorScheme
        AgentTermPath      = $terminal.AgentTermPath
        AgentTermHome      = $terminal.AgentTermHome
        AgentTermPort      = $terminal.AgentTermPort
        ReadinessTimeoutMs = $terminal.ReadinessTimeoutMs
    }
    $startFunction = ${function:lnch}
    $messages = @(& $startFunction @invoke *>&1)
    if ($batch.Count -ne 1) {
        $detail = @($messages | ForEach-Object { [string]$_ } | Where-Object { $_ }) -join '; '
        if (-not $detail) { $detail = 'project launch did not produce a terminal request' }
        throw $detail
    }

    $launchResult = @(Invoke-LnchTerminal -Contexts $batch.ToArray())[0]
    if (-not $launchResult.Accepted) { throw $launchResult.Error }
    [pscustomobject]@{
        Name     = $resolved.Name
        Agent    = $Agent
        Accepted = $true
        Ready    = [bool]$launchResult.Ready
        LaunchId = [string]$launchResult.Context.LaunchId
    }
}

function script:Start-LnchDashboardProjectProcess {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][string]$GitName,
        [Parameter(Mandatory)][string]$GitEmail
    )
    $resolved = Resolve-LnchDashboardProjectName -Root $Root -Name $Name
    if (-not $resolved.Valid) { throw $resolved.Error }

    $shell = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    $identity = Resolve-LnchGitIdentityValues -Name $GitName -Email $GitEmail -Source custom
    if (-not $identity.Valid) { throw $identity.Error }

    $shellExecutable = if ($shell) { $shell.Source } else { Join-Path $PSHOME 'powershell.exe' }
    $lnchScript = Join-Path $script:LnchRoot 'Lnch.ps1'
    $command = @(
        '$ErrorActionPreference = ''Stop'''
        ('. {0}' -f (ConvertTo-LnchPowerShellLiteral $lnchScript))
        ('Invoke-LnchDashboardProjectLaunch -Root {0} -Name {1} -Agent {2} -GitName {3} -GitEmail {4} | Out-Null' -f @(
            (ConvertTo-LnchPowerShellLiteral ([System.IO.Path]::GetFullPath($Root))),
            (ConvertTo-LnchPowerShellLiteral $resolved.Name),
            (ConvertTo-LnchPowerShellLiteral $Agent),
            (ConvertTo-LnchPowerShellLiteral $identity.Name),
            (ConvertTo-LnchPowerShellLiteral $identity.Email)
        ))
    ) -join [Environment]::NewLine
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath $shellExecutable -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand" -WorkingDirectory $script:LnchRoot -WindowStyle Hidden -PassThru
    [pscustomobject]@{
        Name      = $resolved.Name
        Agent     = $Agent
        GitName   = $identity.Name
        GitEmail  = $identity.Email
        Process   = $process
        StartedAt = [datetime]::UtcNow
    }
}

function script:Get-LnchDashboardFrame {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [int]$Width = 120,
        [int]$Height = 30,
        [int]$SelectedIndex = 0,
        [switch]$Color,
        [object]$CreateState,
        [string]$Notice,
        [switch]$Loading
    )
    $width = [Math]::Max(60, $Width)
    $height = [Math]::Max(16, $Height)
    $esc = [char]27
    $reset = if ($Color) { "$esc[0m" } else { '' }
    $bold = if ($Color) { "$esc[1m" } else { '' }
    $dim = if ($Color) { "$esc[2m" } else { '' }
    $cyan = if ($Color) { "$esc[38;2;45;212;191m" } else { '' }
    $blue = if ($Color) { "$esc[38;2;96;165;250m" } else { '' }
    $purple = if ($Color) { "$esc[38;2;192;132;252m" } else { '' }
    $green = if ($Color) { "$esc[38;2;74;222;128m" } else { '' }
    $yellow = if ($Color) { "$esc[38;2;250;204;21m" } else { '' }
    $red = if ($Color) { "$esc[38;2;248;113;113m" } else { '' }
    $gray = if ($Color) { "$esc[38;2;148;163;184m" } else { '' }
    $white = if ($Color) { "$esc[38;2;241;245;249m" } else { '' }
    $reverse = if ($Color) { "$esc[7m" } else { '' }
    $horizontal = [string]([char]0x2500)
    $vertical = [string]([char]0x2502)
    $topLeft = [string]([char]0x256D)
    $topRight = [string]([char]0x256E)
    $bottomLeft = [string]([char]0x2570)
    $bottomRight = [string]([char]0x256F)

    $summary = $Snapshot.Summary
    $cpuText = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0}%', [double]$summary.CpuPercent)
    $summaryText = " ACTIVE $($summary.ActiveProjects)/$($summary.ProjectCount)   SESSIONS $($summary.ActiveSessions)   PROCS $($summary.ProcessCount)   CPU $cpuText   RAM $(Format-LnchDashboardBytes $summary.WorkingSetBytes)   DISK $(Format-LnchDashboardBytes $summary.DiskBytes)   COST -- "
    $rootText = " ROOT  $($Snapshot.Root)"
    $title = ' LNCH TOP '
    $top = $topLeft + $horizontal + $title + ($horizontal * [Math]::Max(0, $width - $title.Length - 3)) + $topRight
    $bottom = $bottomLeft + ($horizontal * ($width - 2)) + $bottomRight
    $innerWidth = $width - 4
    $summaryCell = (Limit-LnchDashboardText $summaryText $innerWidth).PadRight($innerWidth)
    $rootCell = (Limit-LnchDashboardText $rootText $innerWidth).PadRight($innerWidth)

    $ordered = @(Get-LnchDashboardOrderedProjects -Snapshot $Snapshot)
    if ($ordered.Count -eq 0) { $SelectedIndex = 0 }
    elseif ($SelectedIndex -lt 0) { $SelectedIndex = $ordered.Count - 1 }
    elseif ($SelectedIndex -ge $ordered.Count) { $SelectedIndex = 0 }

    $wide = $width -ge 122
    $medium = $width -ge 92
    if ($wide) { $projectWidth = [Math]::Min(32, [Math]::Max(16, $width - 85)) }
    elseif ($medium) { $projectWidth = [Math]::Min(32, [Math]::Max(16, $width - 59)) }
    else { $projectWidth = [Math]::Max(14, $width - 43) }

    if ($wide) {
        $headerRow = ' ' + (Format-LnchDashboardCell 'PROJECT' $projectWidth) + ' ' + (Format-LnchDashboardCell 'AGENT' 9) + ' ' + (Format-LnchDashboardCell 'STATUS' 11) + ' ' + (Format-LnchDashboardCell 'CPU' 7 -Right) + ' ' + (Format-LnchDashboardCell 'MEMORY' 10 -Right) + ' ' + (Format-LnchDashboardCell 'PROC' 5 -Right) + ' ' + (Format-LnchDashboardCell 'MODEL' 15) + ' ' + (Format-LnchDashboardCell 'COST' 9 -Right) + ' ' + (Format-LnchDashboardCell 'DISK' 10 -Right)
    } elseif ($medium) {
        $headerRow = ' ' + (Format-LnchDashboardCell 'PROJECT' $projectWidth) + ' ' + (Format-LnchDashboardCell 'AGENT' 9) + ' ' + (Format-LnchDashboardCell 'STATUS' 11) + ' ' + (Format-LnchDashboardCell 'CPU' 7 -Right) + ' ' + (Format-LnchDashboardCell 'MEMORY' 10 -Right) + ' ' + (Format-LnchDashboardCell 'PROC' 5 -Right) + ' ' + (Format-LnchDashboardCell 'DISK' 10 -Right)
    } else {
        $headerRow = ' ' + (Format-LnchDashboardCell 'PROJECT' $projectWidth) + ' ' + (Format-LnchDashboardCell 'STATUS' 11) + ' ' + (Format-LnchDashboardCell 'CPU' 7 -Right) + ' ' + (Format-LnchDashboardCell 'MEMORY' 10 -Right) + ' ' + (Format-LnchDashboardCell 'DISK' 10 -Right)
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("$purple$bold$top$reset") | Out-Null
    $lines.Add("$purple$vertical$reset $white$bold$summaryCell$reset $purple$vertical$reset") | Out-Null
    $lines.Add("$purple$vertical$reset $gray$rootCell$reset $purple$vertical$reset") | Out-Null
    $lines.Add("$purple$bottom$reset") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add("$cyan$bold$headerRow$reset") | Out-Null
    $lines.Add("$blue$($horizontal * [Math]::Min($width, $headerRow.Length))$reset") | Out-Null

    $detailsLines = if ($CreateState) { 9 } else { 6 }
    $visibleRows = if ($CreateState) {
        [Math]::Max(0, $height - (10 + $detailsLines))
    } else {
        [Math]::Max(1, $height - (10 + $detailsLines))
    }
    $offset = 0
    if ($ordered.Count -gt $visibleRows) {
        $offset = [Math]::Max(0, [Math]::Min($SelectedIndex - [Math]::Floor($visibleRows / 2), $ordered.Count - $visibleRows))
    }
    $lastIndex = [Math]::Min($ordered.Count - 1, $offset + $visibleRows - 1)

    if ($ordered.Count -eq 0) {
        if ($visibleRows -gt 0) {
            $emptyText = if ($Loading) { 'Loading project telemetry...' } else { 'No projects found under this root. Press N to create one.' }
            $lines.Add("$gray$(' ' + $emptyText)$reset") | Out-Null
        }
    } else {
        for ($index = $offset; $index -le $lastIndex; $index++) {
            $project = $ordered[$index]
            $status = Get-LnchDashboardStatusDisplay $project.State
            $cpu = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0}%', [double]$project.CpuPercent)
            $memory = Format-LnchDashboardBytes $project.WorkingSetBytes
            $disk = Format-LnchDashboardBytes $project.DiskBytes
            if ($wide) {
                $row = ' ' + (Format-LnchDashboardCell $project.Name $projectWidth) + ' ' + (Format-LnchDashboardCell $project.Agent 9) + ' ' + (Format-LnchDashboardCell $status 11) + ' ' + (Format-LnchDashboardCell $cpu 7 -Right) + ' ' + (Format-LnchDashboardCell $memory 10 -Right) + ' ' + (Format-LnchDashboardCell ([string]$project.ProcessCount) 5 -Right) + ' ' + (Format-LnchDashboardCell $(if ($project.Model) { $project.Model } else { '--' }) 15) + ' ' + (Format-LnchDashboardCell '--' 9 -Right) + ' ' + (Format-LnchDashboardCell $disk 10 -Right)
            } elseif ($medium) {
                $row = ' ' + (Format-LnchDashboardCell $project.Name $projectWidth) + ' ' + (Format-LnchDashboardCell $project.Agent 9) + ' ' + (Format-LnchDashboardCell $status 11) + ' ' + (Format-LnchDashboardCell $cpu 7 -Right) + ' ' + (Format-LnchDashboardCell $memory 10 -Right) + ' ' + (Format-LnchDashboardCell ([string]$project.ProcessCount) 5 -Right) + ' ' + (Format-LnchDashboardCell $disk 10 -Right)
            } else {
                $row = ' ' + (Format-LnchDashboardCell $project.Name $projectWidth) + ' ' + (Format-LnchDashboardCell $status 11) + ' ' + (Format-LnchDashboardCell $cpu 7 -Right) + ' ' + (Format-LnchDashboardCell $memory 10 -Right) + ' ' + (Format-LnchDashboardCell $disk 10 -Right)
            }
            if ($index -eq $SelectedIndex -and $Color) {
                $lines.Add("$reverse$cyan$row$reset") | Out-Null
            } else {
                $stateColor = switch ($project.State) {
                    'running' { $green }
                    'starting' { $cyan }
                    'failed' { $red }
                    'stale' { $yellow }
                    'completed' { $blue }
                    default { $gray }
                }
                $lines.Add("$stateColor$row$reset") | Out-Null
            }
        }
    }

    while ($lines.Count -lt $height - $detailsLines) { $lines.Add('') | Out-Null }
    if ($CreateState) {
        $createAgent = Get-LnchDashboardCreateAgent -CreateState $CreateState
        $createIdentity = Get-LnchDashboardCreateIdentity -CreateState $CreateState
        $identityOptions = @($CreateState.Identities)
        $identityIndex = [Math]::Max(0, [Math]::Min([int]$CreateState.IdentityIndex, $identityOptions.Count - 1))
        $selectedIdentity = if ($identityOptions.Count -gt 0) { $identityOptions[$identityIndex] } else { $createIdentity }
        $identityLabel = if ($selectedIdentity.Custom) { 'Custom name and email' } else { [string]$selectedIdentity.Label }
        $gitName = if ($selectedIdentity.Custom) { [string]$CreateState.CustomName } else { [string]$createIdentity.Name }
        $gitEmail = if ($selectedIdentity.Custom) { [string]$CreateState.CustomEmail } else { [string]$createIdentity.Email }
        $focus = [int]$CreateState.Focus
        $cursor = [char]0x2588
        $detailTitle = ' NEW PROJECT '
        $detailTop = $topLeft + $horizontal + $detailTitle + ($horizontal * [Math]::Max(0, $width - $detailTitle.Length - 3)) + $topRight
        $detailBottom = $bottomLeft + ($horizontal * ($width - 2)) + $bottomRight
        $nameMark = if ($focus -eq 0) { '>' } else { ' ' }
        $agentMark = if ($focus -eq 1) { '>' } else { ' ' }
        $identityMark = if ($focus -eq 2) { '>' } else { ' ' }
        $gitNameMark = if ($focus -eq 3) { '>' } else { ' ' }
        $gitEmailMark = if ($focus -eq 4) { '>' } else { ' ' }
        $detailOne = " $nameMark NAME      $($CreateState.Name)$(if ($focus -eq 0) { $cursor })"
        $detailTwo = " $agentMark AGENT     $createAgent"
        $detailThree = " $identityMark IDENTITY  $identityLabel"
        $detailFour = " $gitNameMark GIT NAME  $gitName$(if ($focus -eq 3) { $cursor })"
        $detailFive = " $gitEmailMark GIT EMAIL $gitEmail$(if ($focus -eq 4) { $cursor })"
        $detailSix = if ($CreateState.Error) { " ERROR  $($CreateState.Error)" } else { ' TAB move   LEFT/RIGHT choose   ENTER start   ESC cancel' }
        $lines.Add("$blue$detailTop$reset") | Out-Null
        foreach ($detail in @($detailOne, $detailTwo, $detailThree, $detailFour, $detailFive, $detailSix)) {
            $cell = (Limit-LnchDashboardText $detail $innerWidth).PadRight($innerWidth)
            $detailColor = if ($CreateState.Error -and $detail -eq $detailSix) { $red } elseif ($detail.StartsWith(' >')) { $white } else { $dim }
            $lines.Add("$blue$vertical$reset $detailColor$cell$reset $blue$vertical$reset") | Out-Null
        }
        $lines.Add("$blue$detailBottom$reset") | Out-Null
    } elseif ($ordered.Count -gt 0) {
        $selected = $ordered[$SelectedIndex]
        $detailTitle = " PROJECT  $($selected.Name) "
        $detailTop = $topLeft + $horizontal + $detailTitle + ($horizontal * [Math]::Max(0, $width - $detailTitle.Length - 3)) + $topRight
        $detailBottom = $bottomLeft + ($horizontal * ($width - 2)) + $bottomRight
        $pids = if ($selected.Pids.Count -gt 0) { $selected.Pids -join ',' } else { '--' }
        $detailOne = " PATH  $($selected.Directory)"
        $detailTwo = " PIDS  $pids   CPU TIME  $($selected.CpuSeconds)s   PRIVATE  $(Format-LnchDashboardBytes $selected.PrivateBytes)   IO  R $(Format-LnchDashboardBytes $selected.ReadBytes) / W $(Format-LnchDashboardBytes $selected.WriteBytes)"
        $detailThree = " MODEL  $(if ($selected.Model) { $selected.Model } else { 'unknown' }) [$($selected.ModelSource)]   COST  unknown   STATE SOURCE  $($selected.StateSource)"
        $lines.Add("$blue$detailTop$reset") | Out-Null
        foreach ($detail in @($detailOne, $detailTwo, $detailThree)) {
            $cell = (Limit-LnchDashboardText $detail $innerWidth).PadRight($innerWidth)
            $lines.Add("$blue$vertical$reset $dim$cell$reset $blue$vertical$reset") | Out-Null
        }
        $lines.Add("$blue$detailBottom$reset") | Out-Null
    }
    $generated = try { ([datetime]$Snapshot.GeneratedAt).ToLocalTime().ToString('HH:mm:ss') } catch { '--:--:--' }
    if ($CreateState) {
        $footer = ' TYPE text   TAB/UP/DOWN move   LEFT/RIGHT choose   ENTER start   ESC cancel '
    } elseif ($Notice) {
        $footer = " $Notice   N new project   Q quit   updated $generated "
    } else {
        $footer = " UP/DOWN select   N new project   R measure disk   Q quit   updated $generated "
    }
    $lines.Add("$cyan$bold$(Limit-LnchDashboardText $footer $width)$reset") | Out-Null
    $lines -join [Environment]::NewLine
}

function global:Show-LnchDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$Json,
        [switch]$Once,
        [ValidateRange(250, 10000)][int]$RefreshMilliseconds = 1200
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if ($Json) {
        Get-LnchProjectDashboardSnapshot -Root $rootFull | ConvertTo-Json -Depth 8
        return
    }

    $interactive = Test-LnchInteractiveTerminal
    if ($Once -or -not $interactive) {
        $snapshot = Get-LnchProjectDashboardSnapshot -Root $rootFull
        Get-LnchDashboardFrame -Snapshot $snapshot -Width 120 -Height 30 -SelectedIndex 0
        return
    }

    $esc = [char]27
    $selectedIndex = 0
    $createState = $null
    $projectLaunch = $null
    $notice = $null
    $noticeUntil = [datetime]::MinValue
    $loading = $true
    $renderPending = $true
    $refreshDiskQueued = $false
    $refreshDiskActive = $false
    $nextRefresh = [datetime]::MinValue
    $lastWidth = 0
    $lastHeight = 0
    $worker = $null
    $identityRequest = $null
    $identityCandidates = $null
    $createPending = $false
    $snapshot = [pscustomobject][ordered]@{
        Schema      = 1
        GeneratedAt = [datetime]::UtcNow.ToString('o')
        Root        = $rootFull
        Summary     = [pscustomobject][ordered]@{
            ProjectCount = 0; ActiveProjects = 0; ActiveSessions = 0; ProcessCount = 0
            CpuPercent = 0; WorkingSetBytes = 0; DiskBytes = $null; Cost = $null; CostKind = 'unknown'
        }
        Projects    = @()
    }

    try {
        $worker = New-LnchDashboardSnapshotWorker
        $null = Start-LnchDashboardSnapshotRequest -Worker $worker -Root $rootFull
        $nextRefresh = [datetime]::MaxValue
    } catch {
        $worker = $null
        $snapshot = Get-LnchProjectDashboardSnapshot -Root $rootFull
        $loading = $false
        $notice = 'Background telemetry unavailable; using synchronous refresh.'
        $noticeUntil = [datetime]::UtcNow.AddSeconds(5)
        $nextRefresh = [datetime]::UtcNow.AddMilliseconds($RefreshMilliseconds)
    }

    try {
        $identityRequest = Start-LnchDashboardIdentityRequest
    } catch {
        $identityCandidates = @(Get-LnchGitIdentityCandidates)
    }

    $originalTitle = $null
    try { $originalTitle = [Console]::Title; [Console]::Title = 'lnch top' } catch { }
    [Console]::Write("$esc[?1049h$esc[?25l")
    try {
        while ($true) {
            $now = [datetime]::UtcNow

            if ($projectLaunch) {
                try {
                    if ($projectLaunch.Process.HasExited) {
                        $exitCode = [int]$projectLaunch.Process.ExitCode
                        if ($exitCode -eq 0) {
                            $notice = "Started $($projectLaunch.Name) with $($projectLaunch.Agent) as $($projectLaunch.GitName)."
                        } else {
                            $notice = "Failed to start $($projectLaunch.Name) (exit $exitCode)."
                        }
                        $noticeUntil = $now.AddSeconds(5)
                        $projectLaunch.Process.Dispose()
                        $projectLaunch = $null
                        $nextRefresh = [datetime]::MinValue
                        $renderPending = $true
                    }
                } catch {
                    $notice = "Project launch status failed: $($_.Exception.Message)"
                    $noticeUntil = $now.AddSeconds(5)
                    try { $projectLaunch.Process.Dispose() } catch { }
                    $projectLaunch = $null
                    $renderPending = $true
                }
            } elseif ($notice -and $noticeUntil -ne [datetime]::MaxValue -and $now -ge $noticeUntil) {
                $notice = $null
                $renderPending = $true
            }

            if ($identityRequest) {
                $identityResult = Receive-LnchDashboardIdentityRequest -Request $identityRequest
                if ($identityResult) {
                    $identityRequest = $null
                    if ($identityResult.Identities.Count -gt 0) {
                        $identityCandidates = @($identityResult.Identities)
                        if ($identityResult.Error) {
                            $notice = 'Some automatic Git identity sources were unavailable.'
                            $noticeUntil = $now.AddSeconds(5)
                        }
                    } else {
                        $identityCandidates = @([pscustomobject]@{
                            Id = 'custom'; Valid = $true; Name = ''; Email = ''; Source = 'custom'
                            Label = 'Custom name and email'; Custom = $true; Error = $null
                        })
                        $notice = 'Automatic Git identity discovery failed; custom identity remains available.'
                        $noticeUntil = $now.AddSeconds(5)
                    }
                    if ($createPending) {
                        $createState = New-LnchDashboardCreateState -IdentityCandidates $identityCandidates
                        $createPending = $false
                        if (-not $identityResult.Error) {
                            $notice = $null
                            $noticeUntil = [datetime]::MinValue
                        }
                    }
                    $renderPending = $true
                }
            }

            if ($worker) {
                $refreshResult = Receive-LnchDashboardSnapshotRequest -Worker $worker
                if ($refreshResult) {
                    if ($refreshResult.Snapshot) {
                        $selectedName = $null
                        $previousProjects = @(Get-LnchDashboardOrderedProjects -Snapshot $snapshot)
                        if ($previousProjects.Count -gt 0 -and $selectedIndex -lt $previousProjects.Count) {
                            $selectedName = [string]$previousProjects[$selectedIndex].Name
                        }
                        $snapshot = $refreshResult.Snapshot
                        $loading = $false
                        $updatedProjects = @(Get-LnchDashboardOrderedProjects -Snapshot $snapshot)
                        $selectedIndex = 0
                        if ($selectedName) {
                            for ($index = 0; $index -lt $updatedProjects.Count; $index++) {
                                if ($updatedProjects[$index].Name -eq $selectedName) {
                                    $selectedIndex = $index
                                    break
                                }
                            }
                        }
                        if ($refreshDiskActive) {
                            $notice = 'Disk usage refreshed.'
                            $noticeUntil = $now.AddSeconds(3)
                        }
                    } else {
                        $notice = "Telemetry refresh failed: $($refreshResult.Error)"
                        $noticeUntil = $now.AddSeconds(5)
                    }
                    $refreshDiskActive = $false
                    $nextRefresh = $now.AddMilliseconds($RefreshMilliseconds)
                    $renderPending = $true
                }

                if (-not $worker.PowerShell -and ($refreshDiskQueued -or $now -ge $nextRefresh)) {
                    $refreshDiskActive = $refreshDiskQueued
                    $null = Start-LnchDashboardSnapshotRequest -Worker $worker -Root $rootFull -RefreshDisk:$refreshDiskActive
                    $refreshDiskQueued = $false
                    $nextRefresh = [datetime]::MaxValue
                    if ($refreshDiskActive) {
                        $notice = 'Measuring project disk usage...'
                        $noticeUntil = [datetime]::MaxValue
                        $renderPending = $true
                    }
                }
            } elseif ($now -ge $nextRefresh) {
                $snapshot = Get-LnchProjectDashboardSnapshot -Root $rootFull -RefreshDisk:$refreshDiskQueued
                $loading = $false
                $refreshDiskQueued = $false
                $nextRefresh = $now.AddMilliseconds($RefreshMilliseconds)
                $projectCount = @($snapshot.Projects).Count
                if ($projectCount -eq 0 -or $selectedIndex -ge $projectCount) { $selectedIndex = 0 }
                $renderPending = $true
            }

            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($createState) {
                    $agentCount = @($createState.Agents).Count
                    $identityCount = @($createState.Identities).Count
                    switch ($key.Key) {
                        'Escape' {
                            $createState = $null
                        }
                        'Enter' {
                            $resolved = Resolve-LnchDashboardProjectName -Root $rootFull -Name $createState.Name
                            $createIdentity = Get-LnchDashboardCreateIdentity -CreateState $createState
                            if (-not $resolved.Valid) {
                                $createState.Error = $resolved.Error
                            } elseif (-not $createIdentity.Valid) {
                                $createState.Error = $createIdentity.Error
                            } else {
                                $createAgent = Get-LnchDashboardCreateAgent -CreateState $createState
                                try {
                                    $projectLaunch = Start-LnchDashboardProjectProcess -Root $rootFull -Name $resolved.Name -Agent $createAgent -GitName $createIdentity.Name -GitEmail $createIdentity.Email
                                    $notice = "Starting $($resolved.Name) with $createAgent as $($createIdentity.Name) <$($createIdentity.Email)>..."
                                    $noticeUntil = [datetime]::MaxValue
                                    $createState = $null
                                    $nextRefresh = [datetime]::MinValue
                                } catch {
                                    $createState.Error = [string]$_.Exception.Message
                                }
                            }
                        }
                        'Tab' {
                            $focusCount = Get-LnchDashboardCreateFocusCount -CreateState $createState
                            $delta = if (($key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0) { -1 } else { 1 }
                            $createState.Focus = ([int]$createState.Focus + $delta + $focusCount) % $focusCount
                            $createState.Error = $null
                        }
                        'UpArrow' {
                            $focusCount = Get-LnchDashboardCreateFocusCount -CreateState $createState
                            $createState.Focus = ([int]$createState.Focus - 1 + $focusCount) % $focusCount
                            $createState.Error = $null
                        }
                        'DownArrow' {
                            $focusCount = Get-LnchDashboardCreateFocusCount -CreateState $createState
                            $createState.Focus = ([int]$createState.Focus + 1) % $focusCount
                            $createState.Error = $null
                        }
                        'LeftArrow' {
                            if ([int]$createState.Focus -eq 1 -and $agentCount -gt 0) {
                                $createState.AgentIndex = ([int]$createState.AgentIndex - 1 + $agentCount) % $agentCount
                            } elseif ([int]$createState.Focus -eq 2 -and $identityCount -gt 0) {
                                $createState.IdentityIndex = ([int]$createState.IdentityIndex - 1 + $identityCount) % $identityCount
                            }
                            $createState.Error = $null
                        }
                        'RightArrow' {
                            if ([int]$createState.Focus -eq 1 -and $agentCount -gt 0) {
                                $createState.AgentIndex = ([int]$createState.AgentIndex + 1) % $agentCount
                            } elseif ([int]$createState.Focus -eq 2 -and $identityCount -gt 0) {
                                $createState.IdentityIndex = ([int]$createState.IdentityIndex + 1) % $identityCount
                            }
                            $createState.Error = $null
                        }
                        'Backspace' {
                            switch ([int]$createState.Focus) {
                                0 {
                                    if ($createState.Name.Length -gt 0) {
                                        $createState.Name = $createState.Name.Substring(0, $createState.Name.Length - 1)
                                    }
                                }
                                3 {
                                    if ($createState.CustomName.Length -gt 0) {
                                        $createState.CustomName = $createState.CustomName.Substring(0, $createState.CustomName.Length - 1)
                                    }
                                }
                                4 {
                                    if ($createState.CustomEmail.Length -gt 0) {
                                        $createState.CustomEmail = $createState.CustomEmail.Substring(0, $createState.CustomEmail.Length - 1)
                                    }
                                }
                            }
                            $createState.Error = $null
                        }
                        default {
                            $focus = [int]$createState.Focus
                            if ($key.Key -eq 'U' -and ($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0) {
                                if ($focus -eq 0) { $createState.Name = '' }
                                elseif ($focus -eq 3) { $createState.CustomName = '' }
                                elseif ($focus -eq 4) { $createState.CustomEmail = '' }
                                $createState.Error = $null
                            } elseif (-not [char]::IsControl($key.KeyChar)) {
                                if ($focus -eq 0 -and $createState.Name.Length -lt 120) {
                                    $createState.Name += $key.KeyChar
                                } elseif ($focus -eq 3 -and $createState.CustomName.Length -lt 120) {
                                    $createState.CustomName += $key.KeyChar
                                } elseif ($focus -eq 4 -and $createState.CustomEmail.Length -lt 254) {
                                    $createState.CustomEmail += $key.KeyChar
                                }
                                $createState.Error = $null
                            }
                        }
                    }
                    $renderPending = $true
                    continue
                }

                switch ($key.Key) {
                    'Q' { return }
                    'Escape' { return }
                    'UpArrow' {
                        $projectCount = @(Get-LnchDashboardOrderedProjects -Snapshot $snapshot).Count
                        $selectedIndex--
                        if ($selectedIndex -lt 0) { $selectedIndex = [Math]::Max(0, $projectCount - 1) }
                        $renderPending = $true
                    }
                    'DownArrow' {
                        $projectCount = @(Get-LnchDashboardOrderedProjects -Snapshot $snapshot).Count
                        $selectedIndex++
                        if ($selectedIndex -ge $projectCount) { $selectedIndex = 0 }
                        $renderPending = $true
                    }
                    'N' {
                        if ($projectLaunch) {
                            $notice = 'Wait for the current project launch to finish.'
                            $noticeUntil = [datetime]::UtcNow.AddSeconds(3)
                        } elseif ($identityCandidates) {
                            $createState = New-LnchDashboardCreateState -IdentityCandidates $identityCandidates
                        } else {
                            $createPending = $true
                            $notice = 'Loading Git identity options...'
                            $noticeUntil = [datetime]::MaxValue
                        }
                        $renderPending = $true
                    }
                    'R' {
                        $refreshDiskQueued = $true
                        $nextRefresh = [datetime]::MinValue
                    }
                }
            }

            $windowWidth = 120
            $windowHeight = 30
            try {
                $windowWidth = $Host.UI.RawUI.WindowSize.Width
                $windowHeight = $Host.UI.RawUI.WindowSize.Height
            } catch { }
            if ($windowWidth -ne $lastWidth -or $windowHeight -ne $lastHeight) {
                $lastWidth = $windowWidth
                $lastHeight = $windowHeight
                $renderPending = $true
            }
            if ($renderPending) {
                $frame = Get-LnchDashboardFrame -Snapshot $snapshot -Width $windowWidth -Height $windowHeight -SelectedIndex $selectedIndex -Color -CreateState $createState -Notice $notice -Loading:$loading
                [Console]::Write("$esc[H$frame$esc[J")
                $renderPending = $false
            }
            [System.Threading.Thread]::Sleep(15)
        }
    } finally {
        [Console]::Write("$esc[0m$esc[?25h$esc[?1049l")
        if ($projectLaunch) { try { $projectLaunch.Process.Dispose() } catch { } }
        Close-LnchDashboardSnapshotWorker -Worker $worker
        Close-LnchDashboardIdentityRequest -Request $identityRequest
        if ($null -ne $originalTitle) { try { [Console]::Title = $originalTitle } catch { } }
    }
}
