# Manual behavioral smoke against the currently hosting Windows Terminal-compatible app.
$ErrorActionPreference = 'Stop'
$lnchRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lnch-live-wt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$projectRoot = Join-Path $testRoot 'projects'
$project = Join-Path $projectRoot 'live-terminal-smoke'
$configDir = Join-Path $testRoot 'config'
$runtimeDir = Join-Path $testRoot 'runtime'
$bin = Join-Path $testRoot 'bin'
$agentLog = Join-Path $testRoot 'agent.json'
$agentProbe = Join-Path $testRoot 'agent-probe.ps1'
$names = @('PATH', 'LNCH_PROJECTS_DIR', 'LNCH_CONFIG_DIR', 'LNCH_RUNTIME_DIR', 'LNCH_LIVE_AGENT_LOG', 'LNCH_LIVE_AGENT_PROBE', 'LNCH_NO_UPDATE_CHECK')
$before = @{}
foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    New-Item -ItemType Directory -Force -Path $projectRoot, $configDir, $runtimeDir, $bin | Out-Null
    @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AgentArguments
)

$observation = [ordered]@{
    Cwd           = (Get-Location).Path
    Arguments     = @($AgentArguments)
    WtSession     = $env:WT_SESSION
    HostPath      = $null
    HostProcessId = $null
}
try {
    $processes = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath -ErrorAction Stop)
    $byId = @{}
    foreach ($process in $processes) { $byId[[int]$process.ProcessId] = $process }
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $currentId = $PID
    while ($currentId -gt 0 -and $byId.ContainsKey([int]$currentId) -and $seen.Add([int]$currentId)) {
        $process = $byId[[int]$currentId]
        if ([string]$process.Name -match '^(WindowsTerminal(?:Preview)?|wtx|wtd)\.exe$') {
            $observation.HostPath = [string]$process.ExecutablePath
            $observation.HostProcessId = [int]$process.ProcessId
            break
        }
        $currentId = [int]$process.ParentProcessId
    }
} catch {}
$observation | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $env:LNCH_LIVE_AGENT_LOG -Encoding utf8
'@ | Set-Content -LiteralPath $agentProbe -Encoding ascii
    @'
@echo off
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%LNCH_LIVE_AGENT_PROBE%" %*
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $bin 'omp.cmd') -Encoding ascii
    @{ defaultAgent = 'omp'; terminal = @{ readinessTimeoutMs = 10000 } } |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $configDir 'config.json') -Encoding utf8
    $env:PATH = "$bin;$($before['PATH'])"
    $env:LNCH_PROJECTS_DIR = $projectRoot
    $env:LNCH_CONFIG_DIR = $configDir
    $env:LNCH_RUNTIME_DIR = $runtimeDir
    $env:LNCH_LIVE_AGENT_LOG = $agentLog
    $env:LNCH_LIVE_AGENT_PROBE = $agentProbe
    $env:LNCH_NO_UPDATE_CHECK = '1'

    . (Join-Path $lnchRoot 'Lnch.ps1')
    $terminalCommand = script:Resolve-LnchWindowsTerminalCommand
    if (-not $terminalCommand) { throw 'No Windows Terminal-compatible command is available' }
    lnch -Name live-terminal-smoke -Prompt @('real', 'terminal') -Agent omp -GitName 'Lnch Smoke' -GitEmail 'lnch-smoke@example.invalid' -TerminalMode tab -TerminalTitle 'lnch live smoke' -ReadinessTimeoutMs 10000 -NoDashboard

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $receipt = $null
    do {
        $receipt = @(Get-LnchTerminalSessions | Where-Object Project -eq 'live-terminal-smoke' | Select-Object -First 1)[0]
        if ($receipt -and $receipt.State -eq 'agent-exited') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not (Test-Path -LiteralPath $agentLog -PathType Leaf)) { throw 'real WT-compatible child did not run the agent probe' }
    $observation = Get-Content -LiteralPath $agentLog -Raw | ConvertFrom-Json
    if ([string]$observation.Cwd -ne $project) { throw "real child used the wrong directory: $($observation.Cwd)" }
    if (@($observation.Arguments).Count -ne 1 -or [string]$observation.Arguments[0] -ne 'real terminal') { throw "real child lost the prompt: $($observation.Arguments -join ', ')" }
    if (-not $receipt -or $receipt.State -ne 'agent-exited' -or $receipt.ExitCode -ne 0) { throw 'real child did not publish a successful exit receipt' }
    if ([string]::IsNullOrWhiteSpace([string]$receipt.WtSession) -or [string]$observation.WtSession -ne [string]$receipt.WtSession) { throw 'real child WT_SESSION was not observed consistently' }
    if ($receipt.Window -ne 'last' -or $receipt.Mode -ne 'tab') { throw 'real terminal launch policy was not recorded' }
    if ($terminalCommand.Origin -eq 'current-terminal') {
        if (-not [string]::Equals([string]$observation.HostPath, [string]$terminalCommand.Source, [StringComparison]::OrdinalIgnoreCase)) { throw "new tab ran under '$($observation.HostPath)', expected '$($terminalCommand.Source)'" }
        if ([int]$observation.HostProcessId -ne [int]$terminalCommand.ProcessId) { throw "new tab joined terminal PID $($observation.HostProcessId), expected $($terminalCommand.ProcessId)" }
    }
    if (@(Get-ChildItem -LiteralPath (Join-Path $runtimeDir 'launches') -File -ErrorAction SilentlyContinue).Count -ne 0) { throw 'real child did not consume its launch envelope' }

    Write-Host "PASS current terminal executable: $($terminalCommand.Source) [$($terminalCommand.Origin)]"
    Write-Host "PASS child tab host: $($observation.HostPath) [PID $($observation.HostProcessId)]"
    Write-Host 'PASS real child readiness and exit receipts'
    Write-Host 'PASS real child cwd, prompt, and environment inheritance'
    Write-Host 'RESULT: REAL WINDOWS TERMINAL PASS'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
