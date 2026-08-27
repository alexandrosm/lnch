# Manual behavioral smoke against the installed Windows Terminal executable.
$ErrorActionPreference = 'Stop'
$lnchRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$wt = @(Get-Command wt -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
if (-not $wt) { throw 'Windows Terminal (wt.exe) is not installed' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lnch-live-wt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$projectRoot = Join-Path $testRoot 'projects'
$project = Join-Path $projectRoot 'live-terminal-smoke'
$configDir = Join-Path $testRoot 'config'
$runtimeDir = Join-Path $testRoot 'runtime'
$bin = Join-Path $testRoot 'bin'
$agentLog = Join-Path $testRoot 'agent.log'
$names = @('PATH', 'LNCH_PROJECTS_DIR', 'LNCH_CONFIG_DIR', 'LNCH_RUNTIME_DIR', 'LNCH_LIVE_AGENT_LOG', 'LNCH_NO_UPDATE_CHECK')
$before = @{}
foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    New-Item -ItemType Directory -Force -Path $projectRoot, $configDir, $runtimeDir, $bin | Out-Null
    @'
@echo off
>"%LNCH_LIVE_AGENT_LOG%" echo CWD=%CD%
>>"%LNCH_LIVE_AGENT_LOG%" echo ARGS=%*
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $bin 'omp.cmd') -Encoding ascii
    @{ defaultAgent = 'omp'; terminal = @{ readinessTimeoutMs = 10000 } } |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $configDir 'config.json') -Encoding utf8
    $env:PATH = "$bin;$($before['PATH'])"
    $env:LNCH_PROJECTS_DIR = $projectRoot
    $env:LNCH_CONFIG_DIR = $configDir
    $env:LNCH_RUNTIME_DIR = $runtimeDir
    $env:LNCH_LIVE_AGENT_LOG = $agentLog
    $env:LNCH_NO_UPDATE_CHECK = '1'

    . (Join-Path $lnchRoot 'Lnch.ps1')
    lnch -Name live-terminal-smoke -Prompt @('real', 'terminal') -Agent omp -TerminalMode new-window -TerminalTitle 'lnch live smoke' -ReadinessTimeoutMs 10000

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $receipt = $null
    do {
        $receipt = @(Get-LnchTerminalSessions | Where-Object Project -eq 'live-terminal-smoke' | Select-Object -First 1)[0]
        if ($receipt -and $receipt.State -eq 'agent-exited') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not (Test-Path -LiteralPath $agentLog -PathType Leaf)) { throw 'real Windows Terminal child did not run the agent stub' }
    $agentOutput = Get-Content -LiteralPath $agentLog -Raw
    if ($agentOutput -notmatch [regex]::Escape("CWD=$project")) { throw "real child used the wrong directory:`n$agentOutput" }
    if ($agentOutput -notmatch [regex]::Escape('ARGS="real terminal"')) { throw "real child lost the prompt:`n$agentOutput" }
    if (-not $receipt -or $receipt.State -ne 'agent-exited' -or $receipt.ExitCode -ne 0) { throw 'real child did not publish a successful exit receipt' }
    if ([string]::IsNullOrWhiteSpace([string]$receipt.WtSession)) { throw 'real child receipt omitted WT_SESSION' }
    if ($receipt.Window -ne 'new' -or $receipt.Mode -ne 'new-window') { throw 'real terminal launch policy was not recorded' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $runtimeDir 'launches') -File -ErrorAction SilentlyContinue).Count -ne 0) { throw 'real child did not consume its launch envelope' }

    Write-Host "PASS real Windows Terminal executable: $($wt.Source)"
    Write-Host 'PASS real child readiness and exit receipts'
    Write-Host 'PASS real child cwd, prompt, and environment inheritance'
    Write-Host 'RESULT: REAL WINDOWS TERMINAL PASS'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
