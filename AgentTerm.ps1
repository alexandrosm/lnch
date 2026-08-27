# AgentTerm backend for terminal-neutral lnch launch envelopes.

function script:Get-LnchAgentTermLockPath {
    param([Parameter(Mandatory)][string]$AgentTermHome)
    Join-Path ([System.IO.Path]::GetFullPath($AgentTermHome)) '.agentterm\agentterm.lock'
}

function script:Resolve-LnchAgentTermExecutable {
    param([object]$Context)
    $configured = [string]$Context.Terminal.AgentTermPath
    if ($configured) {
        $path = [System.IO.Path]::GetFullPath($configured)
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        return $null
    }
    $command = @(Get-Command agentterm -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($command) { return $command.Source }
    $null
}

function script:Get-LnchAgentTermConnection {
    param([Parameter(Mandatory)][string]$AgentTermHome)
    $lockPath = Get-LnchAgentTermLockPath -AgentTermHome $AgentTermHome
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return $null }
    try { $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $lock.pid -or -not $lock.port -or -not $lock.token) { return $null }
    try { $null = Get-Process -Id ([int]$lock.pid) -ErrorAction Stop } catch { return $null }
    $hostName = if ([string]::IsNullOrWhiteSpace([string]$lock.host) -or $lock.host -eq '0.0.0.0') { '127.0.0.1' } elseif ($lock.host -eq '::') { '::1' } else { [string]$lock.host }
    [pscustomobject][ordered]@{
        Host    = $hostName
        Port    = [int]$lock.port
        Token   = [string]$lock.token
        Pid     = [int]$lock.pid
        BaseUrl = if ($hostName -match ':') { "http://[$hostName]:$($lock.port)" } else { "http://$hostName`:$($lock.port)" }
    }
}

function script:Invoke-LnchAgentTermApi {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body
    )
    $parameters = @{
        Uri        = $Connection.BaseUrl + $Path
        Method     = $Method
        Headers    = @{ Authorization = 'Bearer ' + $Connection.Token }
        TimeoutSec = 30
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 8 -Compress
    }
    Invoke-RestMethod @parameters
}

function script:ConvertTo-LnchPowerShellLiteral {
    param([string]$Value)
    "'" + $Value.Replace("'", "''") + "'"
}

function script:Get-LnchAgentTermChildCommand {
    param([Parameter(Mandatory)]$Context)
    $shell = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    $shellExe = if ($shell) { $shell.Source } else { Join-Path $PSHOME 'powershell.exe' }
    $launcher = Join-Path $script:LnchRoot 'Lnch-InTab.ps1'
    '& {0} -NoProfile -ExecutionPolicy Bypass -File {1} -LaunchId {2} -RuntimeRoot {3}' -f @(
        (ConvertTo-LnchPowerShellLiteral $shellExe),
        (ConvertTo-LnchPowerShellLiteral $launcher),
        (ConvertTo-LnchPowerShellLiteral ([string]$Context.LaunchId)),
        (ConvertTo-LnchPowerShellLiteral ([string]$Context.RuntimeRoot))
    )
}

function script:Wait-LnchAgentTermConnection {
    param([string]$AgentTermHome, [int]$TimeoutMs)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        $connection = Get-LnchAgentTermConnection -AgentTermHome $AgentTermHome
        if ($connection) {
            try {
                $ready = Invoke-LnchAgentTermApi -Connection $connection -Method GET -Path '/api/ready' -Body $null
                if ($ready) { return [pscustomobject]@{ Connection = $connection; Ready = $ready } }
            } catch { }
        }
        Start-Sleep -Milliseconds 100
    }
    $null
}

function script:Start-LnchAgentTerm {
    param([Parameter(Mandatory)]$Context)
    $executable = Resolve-LnchAgentTermExecutable -Context $Context
    if (-not $executable) { throw 'agentterm executable not found (set terminal.agentTermPath or LNCH_AGENTTERM_PATH)' }
    $resolvedHome = [System.IO.Path]::GetFullPath([string]$Context.Terminal.AgentTermHome)
    New-Item -ItemType Directory -Force -Path $resolvedHome | Out-Null
    $arguments = @(
        '--home', ('"' + $resolvedHome + '"'),
        '--cwd', ('"' + [string]$Context.Directory + '"'),
        '--web-port', [string]$Context.Terminal.AgentTermPort
    )
    Start-Process -FilePath $executable -ArgumentList $arguments | Out-Null
    $timeout = [Math]::Max(5000, [int]$Context.Terminal.ReadinessTimeoutMs)
    $state = Wait-LnchAgentTermConnection -AgentTermHome $resolvedHome -TimeoutMs $timeout
    if (-not $state) { throw "AgentTerm did not become ready within $timeout ms" }
    $state
}

function global:Invoke-LnchAgentTerm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Contexts)
    if ($Contexts.Count -eq 0) { return @() }
    $results = New-Object Collections.ArrayList
    $resolvedHome = [System.IO.Path]::GetFullPath([string]$Contexts[0].Terminal.AgentTermHome)
    $connection = Get-LnchAgentTermConnection -AgentTermHome $resolvedHome
    $ready = $null
    $started = $false
    if ($connection) {
        try { $ready = Invoke-LnchAgentTermApi -Connection $connection -Method GET -Path '/api/ready' -Body $null } catch { $connection = $null }
    }
    if (-not $connection) {
        try {
            $state = Start-LnchAgentTerm -Context $Contexts[0]
            $connection = $state.Connection
            $ready = $state.Ready
            $started = $true
        } catch {
            $launchError = [string]$_
            return @($Contexts | ForEach-Object { [pscustomobject]@{ Context = $_; Accepted = $false; Ready = $false; Receipt = $null; Error = $launchError } })
        }
    }

    $availableInitial = if ($started -and @($ready.tabs).Count -eq 1) { @($ready.tabs)[0] } else { $null }
    foreach ($context in $Contexts) {
        if ($context.Terminal.Mode -ne 'tab') {
            $results.Add([pscustomobject]@{ Context = $context; Accepted = $false; Ready = $false; Receipt = $null; Error = "AgentTerm supports terminal mode 'tab'; requested '$($context.Terminal.Mode)'" }) | Out-Null
            continue
        }
        try {
            $command = Get-LnchAgentTermChildCommand -Context $context
            if ($availableInitial) {
                $tab = $availableInitial
                $availableInitial = $null
                $null = Invoke-LnchAgentTermApi -Connection $connection -Method PATCH -Path "/api/tabs/$($tab.id)" -Body @{ title = $context.Terminal.Title }
                Set-LnchLaunchTerminalIdentity -Context $context -Backend agentterm -Identity $tab.id -SessionId $tab.session_id -ProcessId ([int]$tab.pid)
                $null = Invoke-LnchAgentTermApi -Connection $connection -Method POST -Path "/api/submit?tab=$($tab.id)" -Body @{ text = $command; submit = $true; delay_ms = 50; submit_key = 'enter' }
            } else {
                $tab = Invoke-LnchAgentTermApi -Connection $connection -Method POST -Path '/api/tabs' -Body @{
                    cwd = [string]$context.Directory
                    title = [string]$context.Terminal.Title
                    command = $command
                }
                Set-LnchLaunchTerminalIdentity -Context $context -Backend agentterm -Identity $tab.id -SessionId $tab.session_id -ProcessId ([int]$tab.pid)
            }
            $receipt = Wait-LnchTerminalReceipt -Context $context
            $isReady = [int]$context.Terminal.ReadinessTimeoutMs -eq 0 -or $null -ne $receipt
            $results.Add([pscustomobject][ordered]@{
                Context  = $context
                Accepted = $true
                Ready    = $isReady
                Receipt  = $receipt
                Error    = if ($isReady) { $null } else { 'child readiness timeout' }
            }) | Out-Null
        } catch {
            $results.Add([pscustomobject]@{ Context = $context; Accepted = $false; Ready = $false; Receipt = $null; Error = "AgentTerm launch failed: $_" }) | Out-Null
        }
    }
    $results.ToArray()
}

function global:Invoke-LnchTerminal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Contexts)
    if ($Contexts.Count -eq 0) { return @() }
    $backend = [string]$Contexts[0].Terminal.Backend
    if ($backend -eq 'auto') {
        $resolvedHome = [System.IO.Path]::GetFullPath([string]$Contexts[0].Terminal.AgentTermHome)
        if (Get-LnchAgentTermConnection -AgentTermHome $resolvedHome) { $backend = 'agentterm' }
        elseif (Get-Command wt -CommandType Application -ErrorAction SilentlyContinue) { $backend = 'wt' }
        elseif (Resolve-LnchAgentTermExecutable -Context $Contexts[0]) { $backend = 'agentterm' }
        else { $backend = 'inline' }
    }
    switch ($backend) {
        'wt' { Invoke-LnchWindowsTerminal -Contexts $Contexts }
        'agentterm' { Invoke-LnchAgentTerm -Contexts $Contexts }
        default { @($Contexts | ForEach-Object { [pscustomobject]@{ Context = $_; Accepted = $false; Ready = $false; Receipt = $null; Error = 'no managed terminal backend available' } }) }
    }
}
