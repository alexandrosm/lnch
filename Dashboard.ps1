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
    param([Parameter(Mandatory)][string]$Directory, [int]$MaxAgeSeconds = 60)
    $key = Get-LnchDashboardPathKey $Directory
    $now = [datetime]::UtcNow
    $cached = $script:LnchDashboardDiskCache[$key]
    if ($cached -and ($now - $cached.MeasuredAt).TotalSeconds -lt $MaxAgeSeconds) { return [long]$cached.Bytes }
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

        $diskAge = if ($RefreshDisk) { 0 } else { 60 }
        $diskBytes = Get-LnchCachedProjectDiskUsage -Directory $directory.FullName -MaxAgeSeconds $diskAge
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
            DiskBytes      = [long](($projectArray | Measure-Object -Property DiskBytes -Sum).Sum)
            Cost           = $null
            CostKind       = 'unknown'
        }
        Projects    = $projectArray
    }
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

function script:Get-LnchDashboardFrame {
    param([Parameter(Mandatory)]$Snapshot, [int]$Width = 120, [int]$Height = 30, [int]$SelectedIndex = 0, [switch]$Color)
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

    $ordered = @($Snapshot.Projects | Sort-Object @{ Expression = { Get-LnchDashboardSortRank $_.State } }, Name)
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

    $detailsLines = 6
    $visibleRows = [Math]::Max(1, $height - 16)
    $offset = 0
    if ($ordered.Count -gt $visibleRows) {
        $offset = [Math]::Max(0, [Math]::Min($SelectedIndex - [Math]::Floor($visibleRows / 2), $ordered.Count - $visibleRows))
    }
    $lastIndex = [Math]::Min($ordered.Count - 1, $offset + $visibleRows - 1)

    if ($ordered.Count -eq 0) {
        $emptyText = 'No projects found under this root.'
        $lines.Add("$gray$(' ' + $emptyText)$reset") | Out-Null
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
    if ($ordered.Count -gt 0) {
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
    $footer = " UP/DOWN select   R refresh + disk   Q quit                                  updated $generated "
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
    $forceRefresh = $true
    $refreshDisk = $false
    $nextRefresh = [datetime]::MinValue
    $originalTitle = $null
    try { $originalTitle = [Console]::Title; [Console]::Title = 'lnch top' } catch { }
    [Console]::Write("$esc[?1049h$esc[?25l")
    try {
        while ($true) {
            if ($forceRefresh -or [datetime]::UtcNow -ge $nextRefresh) {
                $snapshot = Get-LnchProjectDashboardSnapshot -Root $rootFull -RefreshDisk:$refreshDisk
                $projectCount = @($snapshot.Projects).Count
                if ($projectCount -eq 0) { $selectedIndex = 0 }
                elseif ($selectedIndex -ge $projectCount) { $selectedIndex = 0 }
                $windowWidth = 120
                $windowHeight = 30
                try {
                    $windowWidth = $Host.UI.RawUI.WindowSize.Width
                    $windowHeight = $Host.UI.RawUI.WindowSize.Height
                } catch { }
                $frame = Get-LnchDashboardFrame -Snapshot $snapshot -Width $windowWidth -Height $windowHeight -SelectedIndex $selectedIndex -Color
                [Console]::Write("$esc[2J$esc[H$frame")
                $nextRefresh = [datetime]::UtcNow.AddMilliseconds($RefreshMilliseconds)
                $forceRefresh = $false
                $refreshDisk = $false
            }

            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.Key) {
                    'Q' { return }
                    'Escape' { return }
                    'UpArrow' {
                        $selectedIndex--
                        if ($selectedIndex -lt 0) { $selectedIndex = [Math]::Max(0, @($snapshot.Projects).Count - 1) }
                        $forceRefresh = $true
                    }
                    'DownArrow' {
                        $selectedIndex++
                        if ($selectedIndex -ge @($snapshot.Projects).Count) { $selectedIndex = 0 }
                        $forceRefresh = $true
                    }
                    'R' { $refreshDisk = $true; $forceRefresh = $true }
                }
            }
            Start-Sleep -Milliseconds 50
        }
    } finally {
        [Console]::Write("$esc[0m$esc[?25h$esc[?1049l")
        if ($null -ne $originalTitle) { try { [Console]::Title = $originalTitle } catch { } }
    }
}
