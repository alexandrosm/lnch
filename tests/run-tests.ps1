# Bundled verification matrix for project-starter.
# Runs the `start` function against stub agents; touches only a temp dir.
# Usage: powershell|pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
$ErrorActionPreference = 'Stop'

$StarterDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StubBin    = Join-Path $PSScriptRoot 'stubs'
$TestRoot   = Join-Path ([IO.Path]::GetTempPath()) ('ps-startertest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Projects   = Join-Path $TestRoot 'projects'
New-Item -ItemType Directory -Path $Projects -Force | Out-Null

$env:OMP_PROJECTS_DIR = $Projects
$env:PATH = "$StubBin;$env:PATH"

# registry fixture: back up a real agents.json, install ours, restore afterwards
$registryPath = Join-Path $StarterDir 'agents.json'
$backup = if (Test-Path -LiteralPath $registryPath) { Get-Content -LiteralPath $registryPath -Raw } else { $null }
@'
{
  "omp":   { "continueArgs": ["-c"], "takesPromptOnContinue": true, "yoloFlags": ["--approval-mode", "yolo"] },
  "aider": { "continueArgs": ["--resume", "--last"], "takesPromptOnContinue": false, "yoloFlags": ["--yes-always"] },
  "bare":  { "continueArgs": [] }
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

$script:fail = 0
function Check($label, $cond) {
    if ($cond) { Write-Host "PASS $label" } else { $script:fail++; Write-Host "FAIL $label" }
}
function Meta([string]$p) { Get-Content -LiteralPath (Join-Path $Projects "$p\.ps-project.json") -Raw }

try {
    . (Join-Path $StarterDir 'Start-Project.ps1')

    Write-Host '=== A: fresh, prompt, metadata v2 ==='
    $out = start alpha hello world -Here
    Check 'A git'          (Test-Path (Join-Path $Projects 'alpha\.git'))
    Check 'A prompt'       (($out -join ' ') -match '\[omp-stub\] args="hello world"')
    $m = Meta 'alpha'
    Check 'A meta agent'   ($m -match '"agent":\s*"omp"')
    Check 'A meta intent'  ($m -match 'hello world')
    Check 'A meta created' ($m -match '"created"')

    Write-Host '=== B: resume omp -c ==='
    $out = start alpha -Here
    Check 'B continue'     (($out -join ' ') -match '\[omp-stub\] args=-c ')

    Write-Host '=== C: claude fingerprint ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'beta\.claude') -Force | Out-Null
    $out = start beta -Here
    Check 'C claude'       (($out -join ' ') -match '\[claude-stub\] args=-c')

    Write-Host '=== D: codex drops prompt on resume ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'gamma\.codex') -Force | Out-Null
    $out = start gamma some prompt -Here
    $j = $out -join ' '
    Check 'D resume last'  ($j -match '\[codex-stub\] args=resume --last')
    Check 'D no prompt'    (!($j -match 'some prompt'))

    Write-Host '=== E: theta created with intent; bare start -> fzf line -> resumed ==='
    $out = start theta build a snake game -Here
    Check 'E fresh theta'  (($out -join ' ') -match '\[omp-stub\] args="build a snake game"')
    $out = start -Here
    Check 'E picked theta' (($out -join ' ') -match '\[omp-stub\] args=-c ')
    Check 'E intent saved' ((Meta 'theta') -match 'build a snake game')

    Write-Host '=== F: new-tab handoff env contract ==='
    $out = start epsilon hi there
    $j = $out -join ' '
    Check 'F wt spawned'   ($j -match 'WT-STUB .*Start-InTab\.ps1')
    Check 'F name'         ($env:OMP_START_NAME -eq 'epsilon')
    Check 'F prompt'       ($env:OMP_START_PROMPT -eq 'hi there')
    Check 'F yolo empty'   (-not $env:OMP_START_YOLO)
    $env:OMP_START_NAME = 'zeta'; $env:OMP_START_PROMPT = 'hi there'; $env:OMP_START_YOLO = ''
    $out = start -FromLauncher
    Check 'F launcher fresh prompt' (($out -join ' ') -match '\[omp-stub\] args="hi there"')

    Write-Host '=== G: root escape rejected ==='
    try { start ..\evil -Here; Check 'G reject' $false } catch { Check 'G reject' $true }

    Write-Host '=== H: registry agent via v1-style legacy marker ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'beta2') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Projects 'beta2\.ps-project.json') -Value '{"agent":"aider","updated":"2026-01-01T00:00:00.0000000Z"}'
    $out = start beta2 -Here
    Check 'H aider resume' (($out -join ' ') -match '\[aider-stub\] args=--resume --last')
    $h = Meta 'beta2'
    Check 'H upgraded meta' (($h -match '"created"') -and ($h -match '"agent":\s*"aider"'))

    Write-Host '=== I: -Yolo appends registered flag on fresh start ==='
    $out = start iota hi -yolo -Here
    Check 'I omp yolo+prompt' (($out -join ' ') -match '\[omp-stub\] args=--approval-mode yolo hi')

    Write-Host '=== J: -Yolo without registered flags warns and proceeds ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'jay') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Projects 'jay\.ps-project.json') -Value '{"agent":"bare","updated":"2026-01-01T00:00:00.0000000Z"}'
    $out = start jay p -yolo -Here
    Check 'J bare plain'   (($out -join ' ') -match '\[bare-stub\] args=p')

    Write-Host '=== K: yolo rides the tab handoff ==='
    $out = start kappa go -yolo
    $j = $out -join ' '
    Check 'K handed off'   ($j -match 'WT-STUB')
    Check 'K env yolo'     ($env:OMP_START_YOLO -eq '1')
    $env:OMP_START_NAME = 'kappa'; $env:OMP_START_PROMPT = 'go'; $env:OMP_START_YOLO = '1'
    $out = start -FromLauncher
    $j = $out -join ' '
    Check 'K resume+yolo+prompt' ($j -match '\[omp-stub\] args=-c --approval-mode yolo go')
    Check 'K env cleared' ((-not $env:OMP_START_NAME) -and (-not $env:OMP_START_YOLO))
} finally {
    if ($null -ne $backup) { Set-Content -LiteralPath $registryPath -Value $backup -Encoding utf8 }
    else { Remove-Item -LiteralPath $registryPath -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:OMP_PROJECTS_DIR, Env:OMP_START_NAME, Env:OMP_START_PROMPT, Env:OMP_START_YOLO -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -eq 0) {
    Write-Host 'RESULT: ALL PASS'
} else {
    Write-Host "RESULT: $script:fail FAILED"
    exit 1
}
