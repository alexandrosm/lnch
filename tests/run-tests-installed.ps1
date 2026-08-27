# Installed-product acceptance: clean config, ordinary command, real child PowerShell.
param([string]$InstallDir = (Join-Path $env:USERPROFILE '.lnch'))
$ErrorActionPreference = 'Stop'

$InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path
if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'Lnch.ps1'))) {
    throw "installed Lnch.ps1 not found under $InstallDir"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lnch-installed-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$cleanHome = Join-Path $testRoot 'home'
$projectRoot = Join-Path $cleanHome 'projects'
$project = Join-Path $projectRoot 'existing'
$configDir = Join-Path $testRoot 'config-that-does-not-exist'
$bin = Join-Path $testRoot 'bin'
$log = Join-Path $testRoot 'agent.log'
$wtHelper = Join-Path $testRoot 'wt-child.ps1'
$runner = Join-Path $testRoot 'invoke-lnch.ps1'

$envNames = @(
    'PATH', 'LNCH_ACCEPTANCE_LOG', 'LNCH_CONFIG_DIR', 'LNCH_NO_UPDATE_CHECK',
    'LNCH_PROJECTS_DIR', 'LNCH_NAME', 'LNCH_PROMPT', 'LNCH_YOLO', 'LNCH_AGENT',
    'LNCH_FRESH', 'LNCH_ROOT', 'LNCH_VERBS'
)
$before = @{}
foreach ($name in $envNames) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    New-Item -ItemType Directory -Force -Path $cleanHome, $project, $bin | Out-Null
    git -C $project init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { git -C $project init | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw 'could not initialize acceptance project' }
    @{ agent = 'omp'; intent = 'existing acceptance project'; created = (Get-Date).ToString('o'); updated = (Get-Date).ToString('o') } |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $project '.lnch.json') -Encoding utf8

    @'
@echo off
>>"%LNCH_ACCEPTANCE_LOG%" echo CWD=%CD%
>>"%LNCH_ACCEPTANCE_LOG%" echo ARGS=%*
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $bin 'omp.cmd') -Encoding ascii

    @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$wtHelper" %*
exit /b %ERRORLEVEL%
"@ | Set-Content -LiteralPath (Join-Path $bin 'wt.cmd') -Encoding ascii

    @'
$ErrorActionPreference = 'Stop'
$values = @($args)
$directoryIndex = [Array]::IndexOf($values, '-d')
if ($directoryIndex -lt 0 -or $directoryIndex + 2 -ge $values.Count) { throw 'wt acceptance stub did not receive -d <dir> <command>' }
$directory = $values[$directoryIndex + 1]
$command = $values[$directoryIndex + 2]
$commandArgs = @($values[($directoryIndex + 3)..($values.Count - 1)])
Push-Location -LiteralPath $directory
try {
    & $command @commandArgs
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}
'@ | Set-Content -LiteralPath $wtHelper -Encoding utf8

    @'
param([string]$InstallDir, [string]$CleanHome)
$ErrorActionPreference = 'Stop'
. (Join-Path $InstallDir 'Lnch.ps1')
Set-Item Function:\Get-LnchLatestReleaseTag -Value { 'v-installed-acceptance' }
Set-Location -LiteralPath $CleanHome
lnch existing
'@ | Set-Content -LiteralPath $runner -Encoding utf8

    [Environment]::SetEnvironmentVariable('PATH', "$bin;$($before['PATH'])", 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_ACCEPTANCE_LOG', $log, 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_CONFIG_DIR', $configDir, 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_NO_UPDATE_CHECK', $null, 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_PROJECTS_DIR', $null, 'Process')
    foreach ($name in @('LNCH_NAME', 'LNCH_PROMPT', 'LNCH_YOLO', 'LNCH_AGENT', 'LNCH_FRESH', 'LNCH_ROOT', 'LNCH_VERBS')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    $shell = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $shell) { $shell = @(Get-Command powershell.exe -CommandType Application -ErrorAction Stop) | Select-Object -First 1 }
    $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $runner -InstallDir $InstallDir -CleanHome $cleanHome 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "installed journey process failed:`n$($output -join [Environment]::NewLine)" }

    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw 'agent stub was not launched by the child process' }
    $agentLog = Get-Content -LiteralPath $log -Raw
    if ($agentLog -notmatch [regex]::Escape("CWD=$project")) { throw "child agent used the wrong cwd:`n$agentLog" }
    if ($agentLog -notmatch 'ARGS=-c\b') { throw "existing project did not resume:`n$agentLog" }
    if (Test-Path -LiteralPath (Join-Path $project 'projects\existing')) { throw 'recursive project path was created' }
    if (-not (Test-Path -LiteralPath (Join-Path $configDir 'update-cache.json') -PathType Leaf)) { throw 'first-run update cache was not written' }
    if (($output -join ' ') -notmatch [regex]::Escape('-> existing opened in a new terminal tab')) { throw "parent launch did not complete:`n$($output -join [Environment]::NewLine)" }

    Write-Host 'PASS installed clean-config cache write'
    Write-Host 'PASS installed real child process'
    Write-Host 'PASS installed dynamic root handoff'
    Write-Host 'PASS installed existing-session resume'
    Write-Host 'RESULT: INSTALLED JOURNEY PASS'
} finally {
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
