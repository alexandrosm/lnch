# Cross-shell verification suite: exercises the bash shim and cmd shim
# against stub agents. Orchestrated from PowerShell; the bash child SOURCES
# tests/_shim-body.sh from disk (LF file) - no bodies through argv, no
# dependency on cygpath. Requires MSYS2/Git-bash (the WindowsApps bash.exe
# WSL launcher drops custom env vars and is intentionally skipped; WSL users
# install via install.sh which sources the shim from disk instead).
param([string]$Starter)
$ErrorActionPreference = 'Stop'

if (-not $Starter) {
    if ($env:STARTER_DIR) { $Starter = $env:STARTER_DIR }
    else { $Starter = 'C:\tmp\project-starter' }
}
if (-not (Test-Path (Join-Path $Starter 'Start-Project.ps1'))) { throw "starter not found at $Starter" }
$stubBin = Join-Path $Starter 'tests\stubs'

# self-healing PATH: sandbox environments strip System32/Git unpredictably
$sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
$gitCmd  = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\cmd' } else { 'C:\Program Files\Git\cmd' }
$env:PATH = "$stubBin;$gitCmd;$sysRoot\System32;$sysRoot\System32\WindowsPowerShell\v1.0;$env:PATH"

# MSYS2 bash only: the WindowsApps bash.exe is a WSL launcher that drops
# custom environment variables, breaking the env-injected fixture state.
$bashExe = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bashExe)) {
    $c = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($c -and $c.Source -notmatch 'WindowsApps') { $bashExe = $c.Source }
    else { throw 'no suitable MSYS2 bash found for cross-shell tests' }
}

function WinToPosix([string]$w) {
    '/' + $w.Substring(0, 1).ToLower() + '/' + $w.Substring(3).Replace('\', '/')
}
$bodyPosix = WinToPosix (Join-Path $Starter 'tests\_shim-body.sh')

$proj = Join-Path ([IO.Path]::GetTempPath()) ('ps-shim-fixed-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $proj | Out-Null
& (Join-Path $Starter 'tests\_seed-bashmatrix.ps1') -Root $proj

# redirected user-config: deterministic omp default across all fresh cases
$env:OMP_CONFIG_DIR = Join-Path ([IO.Path]::GetTempPath()) ('ps-shim-cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $env:OMP_CONFIG_DIR | Out-Null
@{ defaultAgent = 'omp' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:OMP_CONFIG_DIR 'config.json') -Encoding utf8

# agents.json fixture: back up a real one, install ours, restore afterwards
$registryPath = Join-Path $Starter 'agents.json'
$registryBackup = if (Test-Path $registryPath) { Get-Content -Raw $registryPath } else { $null }
@'
{
  "omp":   { "continueArgs": ["-c"], "takesPromptOnContinue": true, "yoloFlags": ["--approval-mode", "yolo"] },
  "aider": { "continueArgs": ["--resume", "--last"], "takesPromptOnContinue": false, "yoloFlags": ["--yes-always"] },
  "bare":  { "continueArgs": [] }
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

$env:OMP_PROJECTS_DIR = $proj
$env:OMP_STARTER_DIR_WIN = $Starter

function BashRun([string]$body) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return ((& $bashExe -c ('. "' + $bodyPosix + '"; ' + $body) 2>&1) | Out-String)
    } finally {
        $ErrorActionPreference = $prev
    }
}
function CmdRun([string]$commandLine) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return ((cmd /c $commandLine 2>&1) | Out-String)
    } finally {
        $ErrorActionPreference = $prev
    }
}

$script:fail = 0; $script:pass = 0
function Check($label, $cond, [string]$dump) {
    if ($cond) { Write-Host "PASS $label"; $script:pass++ }
    else {
        Write-Host "FAIL $label"
        if ($dump) {
            $flat = $dump -replace '\r?\n', ' | '
            Write-Host ('  out: ' + $flat.Substring(0, [Math]::Min(260, $flat.Length)))
        }
        $script:fail++
    }
}
function Meta($name) { Get-Content -Raw (Join-Path $proj "$name\.ps-project.json") }
function AutoRunValue {
    (Get-ItemProperty 'HKCU:\Software\Microsoft\Command Processor' -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
}

try {
    Write-Host '=== A: fresh, prompt, metadata ==='
    $out = BashRun 'start alpha hello world --here'
    Check A-prompt ($out -match '\[omp-stub\] args="hello world"') $out
    Check A-git    (Test-Path (Join-Path $proj 'alpha\.git'))
    $m = Meta 'alpha'
    Check A-meta   (($m -match '"agent"') -and ($m -match 'hello world'))

    Write-Host '=== B: resume omp -c ==='
    $out = BashRun 'start alpha --here'
    Check B-resume ($out -match '\[omp-stub\] args=-c\b')

    Write-Host '=== C: claude fingerprint ==='
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'beta\.claude') | Out-Null
    $out = BashRun 'start beta --here'
    Check C-claude ($out -match '\[claude-stub\] args=-c')

    Write-Host '=== E: intent saved; picker resumes ==='
    $out = BashRun 'start theta build a snake game --here'
    Check E-fresh  ($out -match 'args="build a snake game"') $out
    $out = BashRun 'start --here'
    Check E-picker (($out -match '\[omp-stub\]') -and ($out -match 'args=-c\b')) $out

    Write-Host '=== G: root escape rejected ==='
    BashRun 'start ../evil --here' *> $null
    Check G-reject ($LASTEXITCODE -ne 0)

    Write-Host '=== H: registry agent via legacy marker ==='
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'beta2') | Out-Null
    Set-Content -LiteralPath (Join-Path $proj 'beta2\.ps-project.json') -Value '{"agent":"aider","updated":"2026-01-01T00:00:00Z"}'
    $out = BashRun 'start beta2 --here'
    Check H-aider ($out -match '\[aider-stub\] args=--resume --last')

    Write-Host '=== I/J: -yolo flag mapping ==='
    $out = BashRun 'start iota hi --yolo --here'
    Check I-yolo ($out -match 'args=--approval-mode yolo hi')
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'jay') | Out-Null
    Set-Content -LiteralPath (Join-Path $proj 'jay\.ps-project.json') -Value '{"agent":"bare","updated":"2026-01-01T00:00:00Z"}'
    $out = BashRun 'start jay p --yolo --here'
    Check J-noflags ($out -match '\[bare-stub\] args=p')

    Write-Host '=== F: tab handoff reaches wt stub ==='
    $out = BashRun 'start kappa go'
    Check F-handoff (($out -match 'WT-STUB') -and ($out -match 'Start-InTab\.ps1'))

    Write-Host '=== CMD: AutoRun lifecycle + start-cli.cmd ==='
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Starter 'install-cmd.ps1') | Out-Null
    $chk = AutoRunValue
    Check CMD-autorun-installed (($null -ne $chk) -and ($chk -match 'project-starter'))
    $cli = Join-Path $Starter 'shell\start-cli.cmd'
    $out = CmdRun ('"' + $cli + '" delta hi there --here')
    Check CMD-shim (($out -match '\[omp-stub\]') -and ($out -match 'hi there')) $out
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Starter 'install-cmd.ps1') -Remove | Out-Null
    $chk2 = AutoRunValue
    Check CMD-autorun-removed ((( $null -eq $chk2) -or (-not ($chk2 -match 'project-starter'))))
} finally {
    if ($null -ne $registryBackup) { Set-Content -LiteralPath $registryPath -Value $registryBackup -Encoding utf8 }
    else { Remove-Item -LiteralPath $registryPath -Force -ErrorAction SilentlyContinue }
    $cfgDir = $env:OMP_CONFIG_DIR
    Remove-Item Env:OMP_PROJECTS_DIR, Env:OMP_CONFIG_DIR, Env:OMP_STARTER_DIR_WIN -ErrorAction SilentlyContinue
    if ($cfgDir) { Remove-Item -Recurse -Force $cfgDir -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "RESULT: ALL PASS ($script:pass checks)" }
else { Write-Host "RESULT: $($script:fail) FAILED ($script:pass passed)"; exit 1 }
