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
        [string]$Window,
        [Alias('Profile')][string]$ProfileName,
        [string]$TitleTemplate,
        [string]$TabColor,
        [string]$ColorScheme,
        [Nullable[int]]$ReadinessTimeoutMs,
        [string]$Agent
    )
    $user = Get-LnchUserConfig
    $terminal = if ($user -and $user.terminal) { $user.terminal } else { $null }
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

    if ($resolvedMode -notin @('tab', 'split-right', 'split-down', 'new-window', 'inline')) { throw "invalid terminal mode '$resolvedMode'" }
    if ([string]::IsNullOrWhiteSpace($resolvedWindow)) { throw 'terminal window target cannot be empty' }
    if ($resolvedColor -and $resolvedColor -notmatch '^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$') { throw "invalid terminal tab color '$resolvedColor'" }
    if ($resolvedTimeout -lt 0 -or $resolvedTimeout -gt 60000) { throw 'terminal readinessTimeoutMs must be between 0 and 60000' }

    $profileTarget = if ($resolvedProfile -eq 'current') { $env:WT_PROFILE_ID } elseif ($resolvedProfile -eq 'default') { $null } else { $resolvedProfile }
    [pscustomobject][ordered]@{
        Mode               = $resolvedMode
        Window             = $resolvedWindow
        Profile            = $profileTarget
        TitleTemplate      = $resolvedTitle
        TabColor           = $resolvedColor
        ColorScheme        = $resolvedScheme
        ReadinessTimeoutMs = $resolvedTimeout
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
            Mode               = $Terminal.Mode
            Window             = Resolve-LnchTerminalWindow -Terminal $Terminal -Directory $Directory -Project $Name
            Profile            = $Terminal.Profile
            Title              = Format-LnchTerminalTitle -Template $Terminal.TitleTemplate -Project $Name -Agent $Agent -Fresh $Fresh
            TabColor           = $Terminal.TabColor
            ColorScheme        = $Terminal.ColorScheme
            ReadinessTimeoutMs = $Terminal.ReadinessTimeoutMs
        }
    }
    Write-LnchAtomicJson -Path (Get-LnchLaunchContextPath $id) -Value $context
    $context
}

function global:Receive-LnchLaunchContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LaunchId)
    $path = Get-LnchLaunchContextPath $LaunchId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "launch context not found: $LaunchId" }
    try { $context = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    if ($context.Schema -ne 1 -or $context.LaunchId -ne $LaunchId) { throw "invalid launch context: $LaunchId" }
    foreach ($required in @('Name', 'Directory', 'Root', 'Agent')) {
        if ([string]::IsNullOrWhiteSpace([string]$context.$required)) { throw "launch context missing $required" }
    }
    $context
}

function global:Write-LnchTerminalReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$State, [Nullable[int]]$ExitCode, [string]$ErrorMessage)
    $receipt = [pscustomobject][ordered]@{
        Schema       = 1
        LaunchId     = $Context.LaunchId
        State        = $State
        Pid          = $PID
        WtSession    = $env:WT_SESSION
        Project      = $Context.Name
        Directory    = $Context.Directory
        Root         = $Context.Root
        Agent        = $Context.Agent
        Window       = $Context.Terminal.Window
        Mode         = $Context.Terminal.Mode
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

function global:Invoke-LnchWindowsTerminal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Contexts)
    if ($Contexts.Count -eq 0) { return @() }
    $wt = @(Get-Command wt -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $wt) { return @($Contexts | ForEach-Object { [pscustomobject]@{ Context = $_; Accepted = $false; Ready = $false; Receipt = $null; Error = 'wt not found' } }) }
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
        $processAlive = $false
        if ($receipt.Pid) { try { $processAlive = $null -ne (Get-Process -Id ([int]$receipt.Pid) -ErrorAction Stop) } catch { } }
        $active = $receipt.State -in @('child-started', 'agent-running') -and $processAlive
        $stale = $receipt.State -in @('child-started', 'agent-running') -and -not $processAlive
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
            Window       = $receipt.Window
            Mode         = $receipt.Mode
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
    foreach ($item in $items) { Write-Host ("[{0}] {1} | {2} | {3} | pid={4}" -f $item.State, $item.Project, $item.Agent, $item.Window, $item.Pid) }
}
