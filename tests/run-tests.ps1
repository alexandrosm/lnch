# Engine verification matrix for project-starter.
# Runs the `start` function against stub agents; touches only a temp dir
# plus a redirected config dir. Works on Windows PowerShell 5.1 and pwsh 7+.
$ErrorActionPreference = 'Stop'

$StarterDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StubBin    = Join-Path $PSScriptRoot 'stubs'
$TestRoot   = Join-Path ([IO.Path]::GetTempPath()) ('ps-startertest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Projects   = Join-Path $TestRoot 'projects'
New-Item -ItemType Directory -Path $Projects -Force | Out-Null

# self-healing PATH: sandbox environments strip System32/Git unpredictably
$sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
$gitCmd  = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\cmd' } else { 'C:\Program Files\Git\cmd' }
$env:PATH = "$StubBin;$gitCmd;$sysRoot\System32;$sysRoot\System32\WindowsPowerShell\v1.0;$env:PATH"

# redirected user-config so the persisted-default tests never touch real %APPDATA%
$env:OMP_CONFIG_DIR = Join-Path $TestRoot 'config'
New-Item -ItemType Directory -Force -Path $env:OMP_CONFIG_DIR | Out-Null

# registry fixture: back up any real agents.json, install ours, restore afterwards
$registryPath = Join-Path $StarterDir 'agents.json'
$backup = if (Test-Path -LiteralPath $registryPath) { Get-Content -LiteralPath $registryPath -Raw } else { $null }
@'
{
  "omp":   { "continueArgs": ["-c"], "takesPromptOnContinue": true, "yoloFlags": ["--approval-mode", "yolo"] },
  "aider": { "continueArgs": ["--resume", "--last"], "takesPromptOnContinue": false, "yoloFlags": ["--yes-always"] },
  "bare":  { "continueArgs": [] }
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

# deterministic fresh-project agent: seed the default so pickers never fire in A-I/K
@{ defaultAgent = 'omp' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:OMP_CONFIG_DIR 'config.json') -Encoding utf8

$script:fail = 0
function Check($label, $cond) {
    if ($cond) { Write-Host "PASS $label" } else { $script:fail++; Write-Host "FAIL $label" }
}
function Meta([string]$p) { Get-Content -LiteralPath (Join-Path $Projects "$p\.ps-project.json") -Raw }

try {
    . (Join-Path $StarterDir 'Start-Project.ps1')
    # capture the function object explicitly - immune to alias/scope shadowing
    $__startFn = ${function:start}
    if (-not $__startFn) { throw 'start function failed to load' }

    Write-Host '=== A: fresh, prompt, metadata v2 ==='
    $out = & $__startFn alpha hello world -Here
    Check 'A git'          (Test-Path (Join-Path $Projects 'alpha\.git'))
    Check 'A prompt'       (($out -join ' ') -match '\[omp-stub\] args="hello world"')
    $m = Meta 'alpha'
    Check 'A meta agent'   ($m -match '"agent":\s*"omp"')
    Check 'A meta intent'  ($m -match 'hello world')
    Check 'A meta created' ($m -match '"created"')

    Write-Host '=== B: resume omp -c ==='
    $out = & $__startFn alpha -Here
    Check 'B continue'     (($out -join ' ') -match '\[omp-stub\] args=-c ')

    Write-Host '=== C: claude fingerprint ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'beta\.claude') -Force | Out-Null
    $out = & $__startFn beta -Here
    Check 'C claude'       (($out -join ' ') -match '\[claude-stub\] args=-c')

    Write-Host '=== D: codex drops prompt on resume ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'gamma\.codex') -Force | Out-Null
    $out = & $__startFn gamma some prompt -Here
    $j = $out -join ' '
    Check 'D resume last'  ($j -match '\[codex-stub\] args=resume --last')
    Check 'D no prompt'    (!($j -match 'some prompt'))

    Write-Host '=== E: theta created with intent; bare start -> fzf line -> resumed ==='
    $out = & $__startFn theta build a snake game -Here
    Check 'E fresh theta'  (($out -join ' ') -match '\[omp-stub\] args="build a snake game"')
    $out = & $__startFn -Here
    Check 'E picked theta' (($out -join ' ') -match '\[omp-stub\] args=-c ')
    Check 'E intent saved' ((Meta 'theta') -match 'build a snake game')

    Write-Host '=== F: new-tab handoff env contract ==='
    $out = & $__startFn epsilon hi there
    $j = $out -join ' '
    Check 'F wt spawned'   ($j -match 'WT-STUB .*Start-InTab\.ps1')
    Check 'F name'         ($env:OMP_START_NAME -eq 'epsilon')
    Check 'F prompt'       ($env:OMP_START_PROMPT -eq 'hi there')
    Check 'F yolo empty'   (-not $env:OMP_START_YOLO)
    Check 'F agent env'    ($env:OMP_START_AGENT -eq 'omp')
    $env:OMP_START_NAME = 'zeta'; $env:OMP_START_PROMPT = 'hi there'; $env:OMP_START_YOLO = ''; $env:OMP_START_AGENT = ''
    $out = & $__startFn -FromLauncher
    Check 'F launcher fresh prompt' (($out -join ' ') -match '\[omp-stub\] args="hi there"')

    Write-Host '=== G: root escape rejected ==='
    try { & $__startFn ..\evil -Here; Check 'G reject' $false } catch { Check 'G reject' $true }

    Write-Host '=== H: registry agent via v1-style legacy marker ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'beta2') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Projects 'beta2\.ps-project.json') -Value '{"agent":"aider","updated":"2026-01-01T00:00:00.0000000Z"}'
    $out = & $__startFn beta2 -Here
    Check 'H aider resume' (($out -join ' ') -match '\[aider-stub\] args=--resume --last')

    Write-Host '=== I/J: -Yolo flag mapping ==='
    $out = & $__startFn iota hi -yolo -Here
    Check 'I omp yolo+prompt' (($out -join ' ') -match '\[omp-stub\] args=--approval-mode yolo hi')
    New-Item -ItemType Directory -Path (Join-Path $Projects 'jay') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Projects 'jay\.ps-project.json') -Value '{"agent":"bare","updated":"2026-01-01T00:00:00.0000000Z"}'
    $out = & $__startFn jay p -yolo -Here
    Check 'J bare plain'   (($out -join ' ') -match '\[bare-stub\] args=p')

    Write-Host '=== K: yolo rides the tab handoff ==='
    $out = & $__startFn kappa go -yolo
    $j = $out -join ' '
    Check 'K handed off'   ($j -match 'WT-STUB')
    Check 'K env yolo'     ($env:OMP_START_YOLO -eq '1')
    Check 'K env agent'    ($env:OMP_START_AGENT -eq 'omp')
    $env:OMP_START_NAME = 'kappa'; $env:OMP_START_PROMPT = 'go'; $env:OMP_START_YOLO = '1'; $env:OMP_START_AGENT = 'omp'
    $out = & $__startFn -FromLauncher
    Check 'K resume+yolo+prompt' (($out -join ' ') -match '\[omp-stub\] args=-c --approval-mode yolo go')
    Check 'K env cleared' ((-not $env:OMP_START_NAME) -and (-not $env:OMP_START_YOLO))

    Write-Host '=== L: default agent persisted and honored ==='
    & $__startFn -SetDefaultAgent claude
    $out = & $__startFn zeta3 build a castle -Here
    Check 'L default claude' (($out -join ' ') -match '\[claude-stub\] args="build a castle"')

    Write-Host '=== M: cleared default -> agent picker over installed agents ==='
    & $__startFn -SetDefaultAgent ''
    $out = & $__startFn eta x -Here
    Check 'M picker aider' (($out -join ' ') -match '\[aider-stub\] args=x')

    Write-Host '=== N: doctor audit ==='
    $env:OMP_STARTER_DIR_WIN = $StarterDir
    $out = & powershell.exe -NoProfile -Command '. "$env:OMP_STARTER_DIR_WIN\Start-Project.ps1"; start -Doctor' 2>&1
    $j = $out -join ' '
    Check 'N doctor runs'  ($j -match 'project-starter doctor')
    Check 'N git ok'       ($j -match '\[ok\] git')

    Write-Host '=== O: entry.ps1 --agent passthrough ==='
    $entry = Join-Path $StarterDir 'entry.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry --agent claude kappa2 ship it --here 2>&1
    Check 'O entry agent'  (($out -join ' ') -match '\[claude-stub\] args="ship it"')
} finally {
    if ($null -ne $backup) { Set-Content -LiteralPath $registryPath -Value $backup -Encoding utf8 }
    else { Remove-Item -LiteralPath $registryPath -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:OMP_PROJECTS_DIR, Env:OMP_CONFIG_DIR, Env:OMP_START_NAME, Env:OMP_START_PROMPT, Env:OMP_START_YOLO, Env:OMP_START_AGENT, Env:OMP_STARTER_DIR_WIN -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
}

if ($script:fail -eq 0) {
    Write-Host 'RESULT: ALL PASS'
} else {
    Write-Host "RESULT: $script:fail FAILED"
    exit 1
}
