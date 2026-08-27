param([string]$AgentTermPath = 'C:\Users\Alexandros\projects\AgentTerm\dist\agentterm.exe')

$ErrorActionPreference = 'Stop'
$lnchRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AgentTermPath = (Resolve-Path -LiteralPath $AgentTermPath).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lnch-agentterm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$projects = Join-Path $testRoot 'projects'
$project = Join-Path $projects 'agentterm-live'
$config = Join-Path $testRoot 'config'
$runtime = Join-Path $testRoot 'runtime'
$agentTermState = Join-Path $testRoot 'agentterm-state'
$bin = Join-Path $testRoot 'bin'
$agentLog = Join-Path $testRoot 'agent.log'
$names = @('PATH', 'LNCH_PROJECTS_DIR', 'LNCH_CONFIG_DIR', 'LNCH_RUNTIME_DIR', 'LNCH_AGENTTERM_PATH', 'LNCH_LIVE_AGENT_LOG', 'LNCH_NO_UPDATE_CHECK', 'AGENTTERM_HOME')
$before = @{}
foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    New-Item -ItemType Directory -Force -Path $projects, $config, $runtime, $agentTermState, $bin | Out-Null
    @'
@echo off
>"%LNCH_LIVE_AGENT_LOG%" echo CWD=%CD%
>>"%LNCH_LIVE_AGENT_LOG%" echo ARGS=%*
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $bin 'omp.cmd') -Encoding ascii
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()

    $env:PATH = "$bin;$($before['PATH'])"
    $env:LNCH_PROJECTS_DIR = $projects
    $env:LNCH_CONFIG_DIR = $config
    $env:LNCH_RUNTIME_DIR = $runtime
    $env:LNCH_AGENTTERM_PATH = $AgentTermPath
    $env:AGENTTERM_HOME = $agentTermState
    $env:LNCH_LIVE_AGENT_LOG = $agentLog
    $env:LNCH_NO_UPDATE_CHECK = '1'
    @{ defaultAgent = 'omp'; terminal = @{ backend = 'agentterm'; agentTermPath = $AgentTermPath; agentTermHome = $agentTermState; agentTermPort = $port; readinessTimeoutMs = 15000 } } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $config 'config.json') -Encoding utf8

    . (Join-Path $lnchRoot 'Lnch.ps1')
    lnch -Name agentterm-live -Prompt @('real', 'terminal') -Agent omp -TerminalBackend agentterm -ReadinessTimeoutMs 15000

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $receipt = $null
    do {
        $receipts = @(Get-ChildItem -LiteralPath (Join-Path $runtime 'sessions') -File -Filter '*.json' -ErrorAction SilentlyContinue)
        if ($receipts.Count -eq 1) {
            try { $receipt = Get-Content -LiteralPath $receipts[0].FullName -Raw | ConvertFrom-Json } catch { }
        }
        if ((Test-Path -LiteralPath $agentLog -PathType Leaf) -and $receipt -and $receipt.State -eq 'agent-exited') { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not (Test-Path -LiteralPath $agentLog -PathType Leaf)) { throw 'AgentTerm child did not launch the agent stub' }
    $output = Get-Content -LiteralPath $agentLog -Raw
    if ($output -notmatch [regex]::Escape("CWD=$project")) { throw "AgentTerm child used the wrong cwd:`n$output" }
    if ($output -notmatch [regex]::Escape('ARGS="real terminal"')) { throw "AgentTerm child lost the prompt:`n$output" }
    if (-not $receipt -or $receipt.State -ne 'agent-exited' -or $receipt.Backend -ne 'agentterm') { throw 'lnch receipt did not record AgentTerm completion' }
    if ($null -eq $receipt.TerminalId -or -not $receipt.TerminalSessionId -or -not $receipt.TerminalProcessId) { throw 'lnch receipt omitted AgentTerm identity' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $runtime 'launches') -File -Filter '*.json').Count -ne 0) { throw 'AgentTerm child did not consume its launch envelope' }

    $lock = Get-Content -LiteralPath (Join-Path $agentTermState '.agentterm\agentterm.lock') -Raw | ConvertFrom-Json
    $headers = @{ Authorization = 'Bearer ' + $lock.token }
    $tabs = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/tabs" -Headers $headers
    $tab = @($tabs.tabs | Where-Object id -eq $receipt.TerminalId)[0]
    if (-not $tab -or $tab.title -ne 'agentterm-live' -or $tab.session_id -ne $receipt.TerminalSessionId) { throw 'AgentTerm registry and lnch receipt identities disagree' }

    $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/shutdown?terminate=true" -Method POST -Headers $headers
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ($null -eq (Get-Process -Id ([int]$lock.pid) -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -ne (Get-Process -Id ([int]$lock.pid) -ErrorAction SilentlyContinue)) { throw 'AgentTerm did not exit after smoke' }

    Write-Host 'PASS lnch AgentTerm launch and readiness'
    Write-Host 'PASS lnch envelope and receipt lifecycle'
    Write-Host 'PASS stable AgentTerm tab/session/process identity'
    Write-Host 'PASS AgentTerm cwd and prompt handoff'
    Write-Host 'RESULT: LNCH AGENTTERM PASS'
} finally {
    $lockPath = Join-Path $agentTermState '.agentterm\agentterm.lock'
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        try {
            $cleanupLock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
            $cleanupHeaders = @{ Authorization = 'Bearer ' + $cleanupLock.token }
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$($cleanupLock.port)/api/shutdown?terminate=true" -Method POST -Headers $cleanupHeaders -TimeoutSec 5
        } catch {
            if ($cleanupLock.pid) { Stop-Process -Id ([int]$cleanupLock.pid) -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($metaFile in @(Get-ChildItem -LiteralPath (Join-Path $agentTermState '.agentterm\sessions') -Filter meta.json -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $meta = Get-Content -LiteralPath $metaFile.FullName -Raw | ConvertFrom-Json
            Stop-Process -Id ([int]$meta.pid) -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
