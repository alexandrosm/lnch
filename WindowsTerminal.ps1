# Windows Terminal transport, immutable launch envelopes, and runtime receipts.

function global:Get-LnchRuntimeRoot {
    if ($env:LNCH_RUNTIME_DIR) { return [System.IO.Path]::GetFullPath($env:LNCH_RUNTIME_DIR) }
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if ($base) { return [System.IO.Path]::GetFullPath((Join-Path $base 'lnch\runtime')) }
    [System.IO.Path]::GetFullPath((Join-Path (Get-LnchConfigPath) 'runtime'))
}

function script:Get-LnchLaunchDirectory {
    $path = Join-Path (Get-LnchRuntimeRoot) 'launches'
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    $path
}

function script:Get-LnchReceiptDirectory {
    $path = Join-Path (Get-LnchRuntimeRoot) 'sessions'
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    $path
}

function global:Get-LnchLaunchContextPath {
    param([Parameter(Mandatory)][string]$LaunchId)
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParseExact($LaunchId, 'D', [ref]$parsedId)) { throw "invalid launch id: $LaunchId" }
    Join-Path (Get-LnchLaunchDirectory) "$($parsedId.ToString('D')).json"
}

function script:Get-LnchReceiptPath {
    param([Parameter(Mandatory)][string]$LaunchId)
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParseExact($LaunchId, 'D', [ref]$parsedId)) { throw "invalid launch id: $LaunchId" }
    Join-Path (Get-LnchReceiptDirectory) "$($parsedId.ToString('D')).json"
}

function script:Test-LnchReceiptProcessActive {
    param([Parameter(Mandatory)]$Receipt)
    if ($Receipt.State -notin @('restoring', 'child-started', 'agent-running') -or -not $Receipt.Pid) { return $false }
    try {
        $process = Get-Process -Id ([int]$Receipt.Pid) -ErrorAction Stop
        $actualStart = $process.StartTime.ToUniversalTime()
        if ($Receipt.ProcessStartedAt) {
            $expectedStart = ([datetime]$Receipt.ProcessStartedAt).ToUniversalTime()
            return [math]::Abs(($actualStart - $expectedStart).TotalSeconds) -lt 2
        }
        if ($Receipt.UpdatedAt) {
            $updated = ([datetime]$Receipt.UpdatedAt).ToUniversalTime()
            return $actualStart -le $updated.AddMinutes(1)
        }
        $true
    } catch {
        $false
    }
}

function script:ConvertTo-LnchRestoredContext {
    param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$LaunchId)
    if ($Receipt.Schema -ne 1 -or $Receipt.LaunchId -ne $LaunchId) { throw "invalid launch receipt: $LaunchId" }
    foreach ($required in @('Project', 'Directory', 'Root', 'Agent')) {
        if ([string]::IsNullOrWhiteSpace([string]$Receipt.$required)) { throw "launch receipt missing $required" }
    }
    [pscustomobject][ordered]@{
        Schema        = 1
        LaunchId      = $LaunchId
        CreatedAt     = $(if ($Receipt.StartedAt) { [string]$Receipt.StartedAt } else { (Get-Date).ToUniversalTime().ToString('o') })
        Name          = [string]$Receipt.Project
        Directory     = [System.IO.Path]::GetFullPath([string]$Receipt.Directory)
        Root          = [System.IO.Path]::GetFullPath([string]$Receipt.Root)
        Agent         = [string]$Receipt.Agent
        Prompt        = @()
        Verbs         = @()
        Fresh         = $false
        Restored      = $true
        AlreadyActive = Test-LnchReceiptProcessActive -Receipt $Receipt
        RuntimeRoot   = Get-LnchRuntimeRoot
        Terminal      = [pscustomobject][ordered]@{
            Backend            = $(if ($Receipt.Backend) { [string]$Receipt.Backend } else { 'wt' })
            Mode               = $(if ($Receipt.Mode) { [string]$Receipt.Mode } else { 'tab' })
            Window             = $(if ($Receipt.Window) { [string]$Receipt.Window } else { 'last' })
            Profile            = $null
            Title              = [string]$Receipt.Project
            TabColor           = $null
            ColorScheme        = $null
            ReadinessTimeoutMs = 0
            AgentTermPath      = $null
            AgentTermHome      = $null
            AgentTermPort      = $null
            Identity           = $Receipt.TerminalId
            SessionId          = $Receipt.TerminalSessionId
            ProcessId          = $Receipt.TerminalProcessId
        }
    }
}

function script:Write-LnchAtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 10)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        ConvertTo-Json -InputObject $Value -Depth $Depth | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function script:Remove-LnchStaleLaunchFiles {
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-1)
    foreach ($file in @(Get-ChildItem -LiteralPath (Get-LnchLaunchDirectory) -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        if ($file.LastWriteTimeUtc -lt $cutoff) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function global:Get-LnchTerminalConfig {
    [CmdletBinding()]
    param(
        [string]$Mode,
        [string]$Backend,
        [string]$Window,
        [Alias('Profile')][string]$ProfileName,
        [string]$TitleTemplate,
        [string]$TabColor,
        [string]$ColorScheme,
        [string]$AgentTermPath,
        [string]$AgentTermHome,
        [Nullable[int]]$AgentTermPort,
        [Nullable[int]]$ReadinessTimeoutMs,
        [string]$Agent
    )
    $user = Get-LnchUserConfig
    $terminal = if ($user -and $user.terminal) { $user.terminal } else { $null }
    $resolvedBackend = if ($Backend) { $Backend } elseif ($terminal.backend) { [string]$terminal.backend } else { 'auto' }
    $resolvedMode = if ($Mode) { $Mode } elseif ($terminal.mode) { [string]$terminal.mode } else { 'tab' }
    $resolvedWindow = if ($Window) { $Window } elseif ($terminal.window) { [string]$terminal.window } else { 'last' }
    $resolvedProfile = if ($ProfileName) { $ProfileName } elseif ($terminal.profile) { [string]$terminal.profile } else { 'current' }
    $resolvedTitle = if ($TitleTemplate) { $TitleTemplate } elseif ($terminal.titleTemplate) { [string]$terminal.titleTemplate } else { '{project}' }
    $resolvedColor = if ($TabColor) { $TabColor } else { $null }
    if (-not $resolvedColor -and $terminal.agentColors -and $Agent) {
        $colorProperty = $terminal.agentColors.PSObject.Properties[$Agent]
        if ($colorProperty) { $resolvedColor = [string]$colorProperty.Value }
    }
    if (-not $resolvedColor -and $terminal.tabColor) { $resolvedColor = [string]$terminal.tabColor }
    $resolvedScheme = if ($ColorScheme) { $ColorScheme } elseif ($terminal.colorScheme) { [string]$terminal.colorScheme } else { $null }
    $resolvedTimeout = if ($null -ne $ReadinessTimeoutMs) { [int]$ReadinessTimeoutMs } elseif ($null -ne $terminal.readinessTimeoutMs) { [int]$terminal.readinessTimeoutMs } else { 5000 }
    $resolvedAgentTermPath = if ($AgentTermPath) { $AgentTermPath } elseif ($terminal.agentTermPath) { [string]$terminal.agentTermPath } elseif ($env:LNCH_AGENTTERM_PATH) { $env:LNCH_AGENTTERM_PATH } else { $null }
    $resolvedAgentTermHome = if ($AgentTermHome) { $AgentTermHome } elseif ($terminal.agentTermHome) { [string]$terminal.agentTermHome } elseif ($env:AGENTTERM_HOME) { $env:AGENTTERM_HOME } else { $env:USERPROFILE }
    $resolvedAgentTermPort = if ($null -ne $AgentTermPort) { [int]$AgentTermPort } elseif ($null -ne $terminal.agentTermPort) { [int]$terminal.agentTermPort } else { 7685 }

    if ($resolvedBackend -notin @('auto', 'wt', 'agentterm', 'inline')) { throw "invalid terminal backend '$resolvedBackend'" }
    if ($resolvedMode -notin @('tab', 'split-right', 'split-down', 'new-window', 'inline')) { throw "invalid terminal mode '$resolvedMode'" }
    if ([string]::IsNullOrWhiteSpace($resolvedWindow)) { throw 'terminal window target cannot be empty' }
    if ($resolvedColor -and $resolvedColor -notmatch '^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$') { throw "invalid terminal tab color '$resolvedColor'" }
    if ($resolvedTimeout -lt 0 -or $resolvedTimeout -gt 60000) { throw 'terminal readinessTimeoutMs must be between 0 and 60000' }
    if ($resolvedAgentTermPort -lt 1 -or $resolvedAgentTermPort -gt 65535) { throw 'terminal agentTermPort must be between 1 and 65535' }

    $profileTarget = if ($resolvedProfile -eq 'current') { $env:WT_PROFILE_ID } elseif ($resolvedProfile -eq 'default') { $null } else { $resolvedProfile }
    [pscustomobject][ordered]@{
        Backend            = $resolvedBackend
        Mode               = $resolvedMode
        Window             = $resolvedWindow
        Profile            = $profileTarget
        TitleTemplate      = $resolvedTitle
        TabColor           = $resolvedColor
        ColorScheme        = $resolvedScheme
        ReadinessTimeoutMs = $resolvedTimeout
        AgentTermPath      = $resolvedAgentTermPath
        AgentTermHome      = $resolvedAgentTermHome
        AgentTermPort      = $resolvedAgentTermPort
    }
}

function script:Get-LnchProjectWindowName {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Project)
    $safe = ($Project -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    if (-not $safe) { $safe = 'project' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Directory.ToLowerInvariant())) } finally { $sha.Dispose() }
    $suffix = (($hash[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
    "lnch-$safe-$suffix"
}

function script:Resolve-LnchTerminalWindow {
    param([Parameter(Mandatory)]$Terminal, [Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Project)
    if ($Terminal.Mode -eq 'new-window') { return 'new' }
    switch ($Terminal.Window) {
        'last' { 'last' }
        'new' { 'new' }
        'lnch' { 'lnch' }
        'project' { Get-LnchProjectWindowName -Directory $Directory -Project $Project }
        default { [string]$Terminal.Window }
    }
}

function script:Format-LnchTerminalTitle {
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][string]$Agent, [bool]$Fresh)
    $status = if ($Fresh) { 'new' } else { 'resume' }
    $Template.Replace('{project}', $Project).Replace('{agent}', $Agent).Replace('{status}', $status)
}

function global:New-LnchLaunchContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Agent,
        [string[]]$Prompt,
        [object[]]$Verbs,
        [bool]$Fresh,
        [Parameter(Mandatory)]$Terminal
    )
    Remove-LnchStaleLaunchFiles
    $id = [guid]::NewGuid().ToString('D')
    $context = [pscustomobject][ordered]@{
        Schema      = 1
        LaunchId    = $id
        CreatedAt   = (Get-Date).ToUniversalTime().ToString('o')
        Name        = $Name
        Directory   = [System.IO.Path]::GetFullPath($Directory)
        Root        = [System.IO.Path]::GetFullPath($Root)
        Agent       = $Agent
        Prompt      = @($Prompt)
        Verbs       = @($Verbs)
        Fresh       = [bool]$Fresh
        RuntimeRoot = Get-LnchRuntimeRoot
        Terminal    = [pscustomobject][ordered]@{
            Backend            = $Terminal.Backend
            Mode               = $Terminal.Mode
            Window             = Resolve-LnchTerminalWindow -Terminal $Terminal -Directory $Directory -Project $Name
            Profile            = $Terminal.Profile
            Title              = Format-LnchTerminalTitle -Template $Terminal.TitleTemplate -Project $Name -Agent $Agent -Fresh $Fresh
            TabColor           = $Terminal.TabColor
            ColorScheme        = $Terminal.ColorScheme
            ReadinessTimeoutMs = $Terminal.ReadinessTimeoutMs
            AgentTermPath      = $Terminal.AgentTermPath
            AgentTermHome      = $Terminal.AgentTermHome
            AgentTermPort      = $Terminal.AgentTermPort
            Identity           = $null
            SessionId          = $null
            ProcessId          = $null
        }
    }
    Write-LnchAtomicJson -Path (Get-LnchLaunchContextPath $id) -Value $context
    $context
}

function global:Receive-LnchLaunchContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LaunchId)
    $path = Get-LnchLaunchContextPath $LaunchId
    $claimedPath = "$path.$PID.$([guid]::NewGuid().ToString('N')).claim"
    $context = $null
    $launchFileObserved = Test-Path -LiteralPath $path -PathType Leaf
    if ($launchFileObserved) {
        try { Move-Item -LiteralPath $path -Destination $claimedPath -ErrorAction Stop } catch { }
        if (Test-Path -LiteralPath $claimedPath -PathType Leaf) {
            try { $context = Get-Content -LiteralPath $claimedPath -Raw | ConvertFrom-Json } finally { Remove-Item -LiteralPath $claimedPath -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($null -eq $context) {
        $receiptPath = Get-LnchReceiptPath $LaunchId
        if ($launchFileObserved) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($watch.ElapsedMilliseconds -lt 2000 -and -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
                Start-Sleep -Milliseconds 50
            }
        }
        $restoreMutex = New-Object System.Threading.Mutex($false, "Local\lnch-restore-$LaunchId")
        $restoreAcquired = $false
        try {
            try { $restoreAcquired = $restoreMutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $restoreAcquired = $true }
            if (-not $restoreAcquired) { throw "launch restore claim timed out: $LaunchId" }
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "launch context not found: $LaunchId" }
            try { $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json } catch { throw "invalid launch receipt: $LaunchId" }
            $context = ConvertTo-LnchRestoredContext -Receipt $receipt -LaunchId $LaunchId
            if (-not $context.AlreadyActive) { Write-LnchTerminalReceipt -Context $context -State restoring | Out-Null }
        } finally {
            if ($restoreAcquired) { $restoreMutex.ReleaseMutex() }
            $restoreMutex.Dispose()
        }
    }
    if ($context.Schema -ne 1 -or $context.LaunchId -ne $LaunchId) { throw "invalid launch context: $LaunchId" }
    foreach ($required in @('Name', 'Directory', 'Root', 'Agent')) {
        if ([string]::IsNullOrWhiteSpace([string]$context.$required)) { throw "launch context missing $required" }
    }
    $context
}

function global:Write-LnchTerminalReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$State, [Nullable[int]]$ExitCode, [string]$ErrorMessage)
    $processStartedAt = try { (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { $null }
    $receipt = [pscustomobject][ordered]@{
        Schema       = 1
        LaunchId     = $Context.LaunchId
        State        = $State
        Pid          = $PID
        ProcessStartedAt = $processStartedAt
        WtSession    = $env:WT_SESSION
        Project      = $Context.Name
        Directory    = $Context.Directory
        Root         = $Context.Root
        Agent        = $Context.Agent
        Backend      = $Context.Terminal.Backend
        Window       = $Context.Terminal.Window
        Mode         = $Context.Terminal.Mode
        TerminalId   = $Context.Terminal.Identity
        TerminalSessionId = $Context.Terminal.SessionId
        TerminalProcessId = $Context.Terminal.ProcessId
        StartedAt    = $Context.CreatedAt
        UpdatedAt    = (Get-Date).ToUniversalTime().ToString('o')
        ExitCode     = $ExitCode
        ErrorMessage = $ErrorMessage
    }
    Write-LnchAtomicJson -Path (Get-LnchReceiptPath $Context.LaunchId) -Value $receipt
    $receipt
}

function script:Wait-LnchTerminalReceipt {
    param([Parameter(Mandatory)]$Context)
    $timeout = [int]$Context.Terminal.ReadinessTimeoutMs
    if ($timeout -le 0) { return $null }
    $path = Get-LnchReceiptPath $Context.LaunchId
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $timeout) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($receipt.LaunchId -eq $Context.LaunchId -and $receipt.State -in @('child-started', 'agent-running', 'agent-exited', 'failed')) { return $receipt }
            } catch { }
        }
        Start-Sleep -Milliseconds 50
    }
    $null
}

function script:Add-LnchWtActionArguments {
    param([Parameter(Mandatory)][System.Collections.ArrayList]$Arguments, [Parameter(Mandatory)]$Context, [bool]$FirstInGroup, [Parameter(Mandatory)][string]$ShellExe, [Parameter(Mandatory)][string]$Launcher)
    $mode = [string]$Context.Terminal.Mode
    if ($mode -in @('split-right', 'split-down') -and (-not $FirstInGroup -or $Context.Terminal.Window -ne 'new')) {
        $Arguments.Add('split-pane') | Out-Null
        $Arguments.Add($(if ($mode -eq 'split-right') { '--vertical' } else { '--horizontal' })) | Out-Null
    } else {
        $Arguments.Add('new-tab') | Out-Null
        $Arguments.Add('--inheritEnvironment') | Out-Null
    }
    if ($Context.Terminal.Profile) { $Arguments.Add('--profile') | Out-Null; $Arguments.Add([string]$Context.Terminal.Profile) | Out-Null }
    $Arguments.Add('--startingDirectory') | Out-Null; $Arguments.Add([string]$Context.Directory) | Out-Null
    $Arguments.Add('--title') | Out-Null; $Arguments.Add([string]$Context.Terminal.Title) | Out-Null
    $Arguments.Add('--suppressApplicationTitle') | Out-Null
    if ($Context.Terminal.TabColor) { $Arguments.Add('--tabColor') | Out-Null; $Arguments.Add([string]$Context.Terminal.TabColor) | Out-Null }
    if ($Context.Terminal.ColorScheme) { $Arguments.Add('--colorScheme') | Out-Null; $Arguments.Add([string]$Context.Terminal.ColorScheme) | Out-Null }
    $Arguments.Add($ShellExe) | Out-Null
    foreach ($value in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Launcher, '-LaunchId', $Context.LaunchId, '-RuntimeRoot', $Context.RuntimeRoot)) { $Arguments.Add($value) | Out-Null }
}

function global:Set-LnchLaunchTerminalIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Backend,
        $Identity,
        [string]$SessionId,
        [Nullable[int]]$ProcessId
    )
    $Context.Terminal.Backend = $Backend
    $Context.Terminal.Identity = $Identity
    $Context.Terminal.SessionId = $SessionId
    $Context.Terminal.ProcessId = $ProcessId
    Write-LnchAtomicJson -Path (Get-LnchLaunchContextPath $Context.LaunchId) -Value $Context
}

function global:Invoke-LnchWindowsTerminal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Contexts)
    if ($Contexts.Count -eq 0) { return @() }
    $wt = @(Get-Command wt -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $wt) { return @($Contexts | ForEach-Object { [pscustomobject]@{ Context = $_; Accepted = $false; Ready = $false; Receipt = $null; Error = 'wt not found' } }) }
    foreach ($context in $Contexts) { Set-LnchLaunchTerminalIdentity -Context $context -Backend wt }
    $shell = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    $shellExe = if ($shell) { $shell.Source } else { Join-Path $PSHOME 'powershell.exe' }
    $launcher = Join-Path $script:LnchRoot 'Lnch-InTab.ps1'
    $results = New-Object System.Collections.ArrayList
    foreach ($windowGroup in @($Contexts | Group-Object { $_.Terminal.Window })) {
        $arguments = New-Object System.Collections.ArrayList
        $arguments.Add('--window') | Out-Null
        $arguments.Add([string]$windowGroup.Name) | Out-Null
        $first = $true
        foreach ($context in @($windowGroup.Group)) {
            if (-not $first) { $arguments.Add(';') | Out-Null }
            Add-LnchWtActionArguments -Arguments $arguments -Context $context -FirstInGroup $first -ShellExe $shellExe -Launcher $launcher
            $first = $false
        }
        $wtOutput = @(& $wt.Source @($arguments.ToArray()) 2>&1)
        $wtExitCode = $LASTEXITCODE
        $accepted = $wtExitCode -eq 0
        foreach ($context in @($windowGroup.Group)) {
            $receipt = if ($accepted) { Wait-LnchTerminalReceipt -Context $context } else { $null }
            $ready = $accepted -and ([int]$context.Terminal.ReadinessTimeoutMs -eq 0 -or $null -ne $receipt)
            $results.Add([pscustomobject][ordered]@{
                Context  = $context
                Accepted = $accepted
                Ready    = $ready
                Receipt  = $receipt
                Error    = if (-not $accepted) { "wt exited with $wtExitCode`: $($wtOutput -join ' ')" } elseif (-not $ready) { 'child readiness timeout' } else { $null }
            }) | Out-Null
        }
    }
    $results.ToArray()
}

function global:Get-LnchTerminalSessions {
    [CmdletBinding()]
    param([switch]$Prune)
    $now = (Get-Date).ToUniversalTime()
    foreach ($file in @(Get-ChildItem -LiteralPath (Get-LnchReceiptDirectory) -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try { $receipt = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
        $processAlive = Test-LnchReceiptProcessActive -Receipt $receipt
        $active = $receipt.State -in @('restoring', 'child-started', 'agent-running') -and $processAlive
        $stale = $receipt.State -in @('restoring', 'child-started', 'agent-running') -and -not $processAlive
        $updated = try { ([datetime]$receipt.UpdatedAt).ToUniversalTime() } catch { $file.LastWriteTimeUtc }
        $oldTerminalState = $receipt.State -in @('agent-exited', 'failed') -and ($now - $updated).TotalDays -gt 7
        if ($Prune -and (($stale -and ($now - $updated).TotalHours -gt 1) -or $oldTerminalState)) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        [pscustomobject][ordered]@{
            LaunchId     = $receipt.LaunchId
            State        = $(if ($stale) { 'stale' } else { $receipt.State })
            Active       = [bool]$active
            Pid          = $receipt.Pid
            WtSession    = $receipt.WtSession
            Project      = $receipt.Project
            Directory    = $receipt.Directory
            Agent        = $receipt.Agent
            Backend      = $receipt.Backend
            Window       = $receipt.Window
            Mode         = $receipt.Mode
            TerminalId   = $receipt.TerminalId
            TerminalSessionId = $receipt.TerminalSessionId
            TerminalProcessId = $receipt.TerminalProcessId
            StartedAt    = $receipt.StartedAt
            UpdatedAt    = $receipt.UpdatedAt
            ExitCode     = $receipt.ExitCode
            ErrorMessage = $receipt.ErrorMessage
        }
    }
}

function global:Show-LnchTerminalSessions {
    [CmdletBinding()]
    param([switch]$Json, [switch]$Prune)
    $items = @(Get-LnchTerminalSessions -Prune:$Prune | Sort-Object UpdatedAt -Descending)
    if ($Json) {
        ConvertTo-Json -InputObject ([pscustomobject][ordered]@{ Schema = 1; GeneratedAt = (Get-Date).ToUniversalTime().ToString('o'); Sessions = $items }) -Depth 6
        return
    }
    Write-Host ("== lnch terminal sessions ({0}) ==" -f $items.Count)
    foreach ($item in $items) { Write-Host ("[{0}] {1} | {2} | {3}:{4} | pid={5}" -f $item.State, $item.Project, $item.Agent, $item.Backend, $item.Window, $item.Pid) }
}
