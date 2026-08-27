# Cross-shell verification suite: exercises the bash shim and cmd shim
# against stub agents. Orchestrated from PowerShell; the bash child SOURCES
# tests/_shim-body.sh from disk (LF file) - no bodies through argv, no
# dependency on cygpath. Requires MSYS2/Git-bash (the WindowsApps bash.exe
# WSL launcher drops custom env vars and is intentionally skipped; WSL users
# install via install.sh which sources the shim from disk instead).
param([string]$LnchRoot)
$ErrorActionPreference = 'Stop'

if (-not $LnchRoot) {
    if ($env:LNCH_DIR) { $LnchRoot = $env:LNCH_DIR }
    else { $LnchRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
}
if (-not (Test-Path (Join-Path $LnchRoot 'Lnch.ps1'))) { throw "starter not found at $LnchRoot" }
$stubBin = Join-Path $LnchRoot 'tests\stubs'

# self-healing PATH: sandbox environments strip System32/Git unpredictably
$sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
$gitCmd  = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\cmd' } else { 'C:\Program Files\Git\cmd' }
$env:PATH = "$stubBin;$gitCmd;$sysRoot\System32;$sysRoot\System32\WindowsPowerShell\v1.0;$env:PATH"

# MSYS2 bash only: the WindowsApps bash.exe is a WSL launcher that drops
$env:LNCH_NO_UPDATE_CHECK = '1'
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
$bodyPosix = WinToPosix (Join-Path $LnchRoot 'tests\_shim-body.sh')

$proj = Join-Path ([IO.Path]::GetTempPath()) ('ps-shim-fixed-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $proj | Out-Null
& (Join-Path $LnchRoot 'tests\_seed-bashmatrix.ps1') -Root $proj

# redirected user-config: deterministic omp default across all fresh cases
$env:LNCH_CONFIG_DIR = Join-Path ([IO.Path]::GetTempPath()) ('ps-shim-cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $env:LNCH_CONFIG_DIR | Out-Null
@{ defaultAgent = 'omp' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:LNCH_CONFIG_DIR 'config.json') -Encoding utf8

# agents.json fixture: back up a real one, install ours, restore afterwards
$registryPath = Join-Path $LnchRoot 'agents.json'
$registryBackup = if (Test-Path $registryPath) { Get-Content -Raw $registryPath } else { $null }
@'
{
  "omp":   { "continueArgs": ["-c"], "takesPromptOnContinue": true, "yoloFlags": ["--approval-mode", "yolo"] },
  "aider": { "continueArgs": ["--resume", "--last"], "takesPromptOnContinue": false, "yoloFlags": ["--yes-always"] },
  "bare":  { "continueArgs": [] }
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

$env:LNCH_PROJECTS_DIR = $proj
$env:LNCH_INSTALL_DIR = $LnchRoot

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
function Meta($name) { Get-Content -Raw (Join-Path $proj "$name\.lnch.json") }
function AutoRunValue {
    (Get-ItemProperty 'HKCU:\Software\Microsoft\Command Processor' -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
}

try {
    Write-Host '=== A: fresh, prompt, metadata ==='
    $out = BashRun 'lnch alpha hello world --here'
    Check A-prompt ($out -match '\[omp-stub\] args="hello world"') $out
    Check A-git    (Test-Path (Join-Path $proj 'alpha\.git'))
    $m = Meta 'alpha'
    Check A-meta   (($m -match '"agent"') -and ($m -match 'hello world'))

    Write-Host '=== B: resume omp -c ==='
    $out = BashRun 'lnch alpha --here'
    Check B-resume ($out -match '\[omp-stub\] args=-c\b')

    Write-Host '=== C: claude fingerprint ==='
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'beta\.claude') | Out-Null
    $out = BashRun 'lnch beta --here'
    Check C-claude ($out -match '\[claude-stub\] args=-c')

    Write-Host '=== E: intent saved; picker resumes ==='
    $out = BashRun 'lnch theta build a snake game --here'
    Check E-fresh  ($out -match 'args="build a snake game"') $out
    $out = BashRun 'lnch --here'
    Check E-picker (($out -match '\[omp-stub\]') -and ($out -match 'args=-c\b')) $out

    Write-Host '=== E2: multi-project picker through bash face ==='
    $env:LNCH_TEST_FZF_MULTI = '1'
    $out = BashRun 'lnch'
    Remove-Item Env:LNCH_TEST_FZF_MULTI -ErrorAction SilentlyContinue
    Check E2-theta ($out -match 'WT-STUB -w 0 new-tab --title theta ') $out
    Check E2-alpha ($out -match 'WT-STUB -w 0 new-tab --title alpha ') $out
    Check E2-count ([regex]::Matches($out, 'WT-STUB').Count -eq 2) $out

    Write-Host '=== G: root escape rejected ==='
    BashRun 'lnch ../evil --here' *> $null
    Check G-reject ($LASTEXITCODE -ne 0)

    Write-Host '=== H: registry agent via legacy marker ==='
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'beta2') | Out-Null
    Set-Content -LiteralPath (Join-Path $proj 'beta2\.lnch.json') -Value '{"agent":"aider","updated":"2026-01-01T00:00:00Z"}'
    $out = BashRun 'lnch beta2 --here'
    Check H-aider ($out -match '\[aider-stub\] args=--resume --last')

    Write-Host '=== I/J: -yolo flag mapping ==='
    $out = BashRun 'lnch iota hi --yolo --here'
    Check I-yolo ($out -match 'args=--approval-mode yolo hi')
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'jay') | Out-Null
    Set-Content -LiteralPath (Join-Path $proj 'jay\.lnch.json') -Value '{"agent":"bare","updated":"2026-01-01T00:00:00Z"}'
    $out = BashRun 'lnch jay p --yolo --here'
    Check J-noflags ($out -match '\[bare-stub\] args=p')

    Write-Host '=== F: tab handoff reaches wt stub ==='
    $out = BashRun 'lnch kappa go'
    Check F-handoff (($out -match 'WT-STUB -w 0 new-tab --title kappa --suppressApplicationTitle') -and ($out -match 'Lnch-InTab\.ps1'))

    Write-Host '=== DISC: datastore discovery through bash face ==='
    $out = BashRun 'lnch --discover --json'
    Check DISC-bash (($out -match '"Schema"\s*:\s*2') -and ($out -match '"Agent"\s*:\s*"omp"')) $out

    Write-Host '=== CMD: AutoRun lifecycle + lnch-cli.cmd ==='
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $LnchRoot 'install-cmd.ps1') | Out-Null
    $chk = AutoRunValue
    Check CMD-autorun-installed (($null -ne $chk) -and ($chk -match 'lnch'))
    $cli = Join-Path $LnchRoot 'shell\lnch-cli.cmd'
    $out = CmdRun ('"' + $cli + '" delta hi there --here')
    Check CMD-shim (($out -match '\[omp-stub\]') -and ($out -match 'hi there')) $out
    $out = CmdRun ('"' + $cli + '" --discover --json')
    Check DISC-cmd (($out -match '"Schema"\s*:\s*2') -and ($out -match '"Agent"\s*:\s*"codex"')) $out
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $LnchRoot 'install-cmd.ps1') -Remove | Out-Null
    $chk2 = AutoRunValue
    Check CMD-autorun-removed ((( $null -eq $chk2) -or (-not ($chk2 -match 'lnch'))))
} finally {
    if ($null -ne $registryBackup) { Set-Content -LiteralPath $registryPath -Value $registryBackup -Encoding utf8 }
    else { Remove-Item -LiteralPath $registryPath -Force -ErrorAction SilentlyContinue }
    $cfgDir = $env:LNCH_CONFIG_DIR
    Remove-Item Env:LNCH_PROJECTS_DIR, Env:LNCH_CONFIG_DIR, Env:LNCH_INSTALL_DIR, Env:LNCH_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    if ($cfgDir) { Remove-Item -Recurse -Force $cfgDir -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "RESULT: ALL PASS ($script:pass checks)" }
else { Write-Host "RESULT: $($script:fail) FAILED ($script:pass passed)"; exit 1 }
