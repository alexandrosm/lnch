# Exact-workspace, native-history, explicit-override, and failed-launch regressions.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('lnch-agent-selection-' + [guid]::NewGuid().ToString('N'))
$names = @('PATH', 'LNCH_PROJECTS_DIR', 'LNCH_CONFIG_DIR', 'LNCH_RUNTIME_DIR', 'LNCH_NO_UPDATE_CHECK', 'LNCH_DISCOVERY_HOME', 'PI_CODING_AGENT_DIR', 'OMP_PROFILE', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'GEMINI_CLI_HOME', 'QWEN_HOME', 'QWEN_RUNTIME_DIR', 'XDG_DATA_HOME', 'OPENCODE_CONFIG_DIR')
$before = @{}
foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Check($label, $condition) {
    if (-not $condition) { throw "FAIL $label" }
    Write-Host "PASS $label"
}
try {
    $env:PATH = (Join-Path $repo 'tests\stubs') + ';' + $env:PATH
    $env:LNCH_PROJECTS_DIR = Join-Path $temp 'projects'
    $env:LNCH_CONFIG_DIR = Join-Path $temp 'config'
    $env:LNCH_RUNTIME_DIR = Join-Path $temp 'runtime'
    $env:LNCH_NO_UPDATE_CHECK = '1'
    $env:LNCH_DISCOVERY_HOME = Join-Path $temp 'home'
    $env:PI_CODING_AGENT_DIR = Join-Path $temp 'omp'
    $env:CLAUDE_CONFIG_DIR = Join-Path $temp 'claude'
    $env:CODEX_HOME = Join-Path $temp 'codex'
    $env:GEMINI_CLI_HOME = Join-Path $temp 'gemini'
    $env:QWEN_HOME = Join-Path $temp 'qwen'
    $env:QWEN_RUNTIME_DIR = $env:QWEN_HOME
    $env:XDG_DATA_HOME = Join-Path $temp 'xdg'
    $env:OPENCODE_CONFIG_DIR = Join-Path $temp 'opencode'
    Remove-Item Env:OMP_PROFILE -ErrorAction SilentlyContinue
    $project = Join-Path $env:LNCH_PROJECTS_DIR 'demo'
    $otherProject = Join-Path $temp 'other\demo'
    $ompBucket = Join-Path $env:PI_CODING_AGENT_DIR 'sessions\same-name-bucket'
    $codexSessions = Join-Path $env:CODEX_HOME 'sessions'
    $claudeBucket = Join-Path $env:CLAUDE_CONFIG_DIR 'projects\other-demo'
    New-Item -ItemType Directory -Path $env:LNCH_CONFIG_DIR, (Join-Path $project '.git'), $otherProject, $ompBucket, $codexSessions, $claudeBucket -Force | Out-Null
    @{ defaultAgent = 'omp'; terminal = @{ readinessTimeoutMs = 0 } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $env:LNCH_CONFIG_DIR 'config.json')
    . (Join-Path $repo 'Lnch.ps1')
    $launch = ${function:lnch}
    $metaPath = Join-Path $project '.lnch.json'
    @{ agent = 'claude'; id = 'stable-project'; updated = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $metaPath
    $epoch = [datetime]'2026-01-01T00:00:00Z'
    $ompFile = Join-Path $ompBucket 'root.jsonl'
    @{ type = 'session'; id = 'omp-root'; cwd = $project } | ConvertTo-Json -Compress | Set-Content -LiteralPath $ompFile
    (Get-Item -LiteralPath $ompFile).LastWriteTimeUtc = $epoch
    $codexFile = Join-Path $codexSessions 'root.jsonl'
    @{ type = 'session_meta'; payload = @{ id = 'codex-root'; cwd = $project } } | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $codexFile
    (Get-Item -LiteralPath $codexFile).LastWriteTimeUtc = $epoch.AddMinutes(1)
    Check 'native history outranks unconfirmed legacy metadata' ((Get-ProjectAgent $project) -eq 'codex')

    $childFile = Join-Path $codexSessions 'child.jsonl'
    @{ type = 'session_meta'; payload = @{ id = 'codex-child'; cwd = $project; parent_thread_id = 'codex-root' } } | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $childFile
    (Get-Item -LiteralPath $ompFile).LastWriteTimeUtc = $epoch.AddMinutes(2)
    (Get-Item -LiteralPath $childFile).LastWriteTimeUtc = $epoch.AddMinutes(3)
    $claudeChild = Join-Path $claudeBucket 'child.jsonl'
    @{ type = 'user'; cwd = $project; sessionId = 'claude-child'; isSidechain = $true } | ConvertTo-Json -Compress | Set-Content -LiteralPath $claudeChild
    (Get-Item -LiteralPath $claudeChild).LastWriteTimeUtc = $epoch.AddMinutes(3)
    Check 'newer subagent does not replace last root agent' ((Get-ProjectAgent $project) -eq 'omp')
    $otherFile = Join-Path $claudeBucket 'other.jsonl'
    @{ type = 'user'; cwd = $otherProject; sessionId = 'other-root' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $otherFile
    (Get-Item -LiteralPath $otherFile).LastWriteTimeUtc = $epoch.AddMinutes(4)
    Check 'same basename in another root is not usage evidence' ((Get-ProjectAgent $project) -eq 'omp')

    $empty = Join-Path $env:LNCH_PROJECTS_DIR 'scaffold-only'
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $empty 'CLAUDE.md') -Value '@AGENTS.md'
    Check 'generated instruction file does not select Claude' ((Get-ProjectAgent $empty) -eq 'omp')
    $out = & $launch demo -Agent claude -Here
    Check 'explicit agent overrides existing project history' (($out -join ' ') -match '\[claude-stub\] args=-c')
    $metadata = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    Check 'successful launch records usage without losing workspace identity' ($metadata.agent -eq 'claude' -and $metadata.lastUsed -and $metadata.id -eq 'stable-project')
    Check 'confirmed launch beats older native sessions' ((Get-ProjectAgent $project) -eq 'claude')
    Write-ProjectMeta -Dir $project -Agent omp -UsedAt ([datetime]$metadata.lastUsed).AddSeconds(-1)
    Check 'older session finishing later cannot replace newer usage' ((Get-ProjectAgent $project) -eq 'claude')
    (Get-Item -LiteralPath $codexFile).LastWriteTimeUtc = ([datetime]$metadata.lastUsed).ToUniversalTime().AddSeconds(1)
    Check 'subsequent native activity is visible immediately' ((Get-ProjectAgent $project) -eq 'codex')

    $savedMetadata = Get-Content -LiteralPath $metaPath -Raw
    $missing = 'lnch-missing-' + [guid]::NewGuid().ToString('N')
    $script:AgentProfiles[$missing] = @{ TakesPromptOnResume = $true; Caps = @{} }
    $rejected = $false
    try { & $launch demo -Agent $missing -Here | Out-Null } catch [System.Management.Automation.CommandNotFoundException] { $rejected = $true }
    Check 'failed executable does not overwrite last-used agent' ($rejected -and (Get-Content -LiteralPath $metaPath -Raw) -eq $savedMetadata)
    $bin = Join-Path $temp 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $bin 'failed-agent.cmd') -Value "@echo off`r`nexit /b 9" -Encoding ascii
    $env:PATH = "$bin;$env:PATH"
    $script:AgentProfiles['failed-agent'] = @{ TakesPromptOnResume = $true; Caps = @{} }
    $agentExit = 0
    & $launch demo -Agent failed-agent -Here -ExitCode ([ref]$agentExit) | Out-Null
    Check 'nonzero startup does not overwrite last-used agent' ($agentExit -eq 9 -and (Get-Content -LiteralPath $metaPath -Raw) -eq $savedMetadata)
    $batch = New-Object System.Collections.ArrayList
    & $launch demo -Agent omp -LaunchBatch $batch | Out-Null
    Check 'queued handoff does not claim the agent ran' ($batch.Count -eq 1 -and (Get-Content -LiteralPath $metaPath -Raw) -eq $savedMetadata)
    $snapshot = Get-LnchProjectDashboardSnapshot -Root $env:LNCH_PROJECTS_DIR -RefreshDisk
    $row = @($snapshot.Projects | Where-Object Name -eq 'demo')[0]
    Check 'dashboard shows the same native last-used agent' ($row.Agent -eq 'codex')
    $singleRoot = (& $launch -Top -Json -ResolvedRoot $env:LNCH_PROJECTS_DIR) | ConvertFrom-Json
    Check 'single-root dashboard preserves the full primary path' ($singleRoot.Root -eq $env:LNCH_PROJECTS_DIR -and @($singleRoot.Roots).Count -eq 1)
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'RESULT: AGENT SELECTION PASS'
exit 0
