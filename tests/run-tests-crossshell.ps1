# Cross-shell verification suite: exercises the bash shim and cmd shim
# against stub agents. Orchestrated from PowerShell; the bash child SOURCES
# tests/_shim-body.sh from disk (LF file) - no bodies through argv, no
# dependency on cygpath. Requires MSYS2/Git-bash (the WindowsApps bash.exe
# WSL launcher drops custom env vars and is intentionally skipped; WSL users
# install via install.sh which sources the shim from disk instead).
$ErrorActionPreference = 'Stop'

$starter = 'C:\tmp\project-starter'
if (-not (Test-Path "$starter\Start-Project.ps1")) { throw "starter not found at $starter" }
$stubBin = "$starter\tests\stubs"

$bashExe = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bashExe)) {
    $c = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($c -and $c.Source -notmatch 'WindowsApps') { $bashExe = $c.Source }
    else { throw 'no suitable MSYS2 bash found for cross-shell tests' }
}

function WinToPosix([string]$w) {
    '/' + $w.Substring(0, 1).ToLower() + '/' + $w.Substring(3).Replace('\', '/')
}
$bodyPosix = WinToPosix "$starter\tests\_shim-body.sh"

$proj = Join-Path ([IO.Path]::GetTempPath()) ('ps-shim-fixed-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $proj | Out-Null
& "$starter\tests\_seed-bashmatrix.ps1" -Root $proj

# agents.json fixture: back up a real one, install ours, restore afterwards
$registryPath = "$starter\agents.json"
$registryBackup = if (Test-Path $registryPath) { Get-Content -Raw $registryPath } else { $null }
@'
{
  "omp":   { "continueArgs": ["-c"], "takesPromptOnContinue": true, "yoloFlags": ["--approval-mode", "yolo"] },
  "aider": { "continueArgs": ["--resume", "--last"], "takesPromptOnContinue": false, "yoloFlags": ["--yes-always"] },
  "bare":  { "continueArgs": [] }
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

$env:OMP_PROJECTS_DIR = $proj
$env:PATH = "$stubBin;$env:PATH"
$env:OMP_STARTER_DIR_WIN = $starter

function BashRun([string]$body) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return ((& $bashExe -c ('. "' + $bodyPosix + '"; ' + $body) 2>&1) | Out-String)
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

try {
    Write-Host '=== A: fresh, prompt, metadata ==='
    $out = BashRun 'start alpha hello world --here'
    Check A-prompt ($out -match '\[omp-stub\] args="hello world"') $out
    Check A-git    (Test-Path (Join-Path $proj 'alpha\.git'))
    $m = Meta 'alpha'
    Check A-meta   (($m -match '"agent"') -and ($m -match 'hello world'))

    Write-Host '=== B: resume omp -c ==='
    $out = BashRun 'start alpha --here'
    Check B-resume ($out -match 'args=-c\b') $out

    Write-Host '=== C: claude fingerprint ==='
    $out = BashRun 'start beta --here'
    Check C-claude ($out -match '\[claude-stub\] args=-c') $out

    Write-Host '=== E: intent saved; picker resumes ==='
    $out = BashRun 'start theta build a snake game --here'
    Check E-fresh  ($out -match 'args="build a snake game"') $out
    $out = BashRun 'start --here'
    Check E-picker (($out -match 'args=-c\b') -and ($out -match '\[omp-stub\]')) $out

    Write-Host '=== G: root escape rejected ==='
    BashRun 'start ../evil --here' *> $null
    Check G-reject ($LASTEXITCODE -ne 0)

    Write-Host '=== H: registry agent via legacy marker ==='
    $out = BashRun 'start beta2 --here'
    Check H-aider ($out -match '\[aider-stub\] args=--resume --last') $out

    Write-Host '=== I/J: -yolo flag mapping ==='
    $out = BashRun 'start iota hi --yolo --here'
    Check I-yolo ($out -match 'args=--approval-mode yolo hi') $out
    $out = BashRun 'start jay p --yolo --here'
    Check J-noflags ($out -match '\[bare-stub\] args=p') $out

    Write-Host '=== F: tab handoff reaches wt stub ==='
    $out = BashRun 'start kappa go'
    Check F-handoff (($out -match 'WT-STUB') -and ($out -match 'Start-InTab\.ps1')) $out

    Write-Host '=== CMD: AutoRun lifecycle + start-cli.cmd ==='
    $reg = 'HKCU\Software\Microsoft\Command Processor'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$starter\install-cmd.ps1" | Out-Null
    $installed = ((cmd /c "reg query ""$reg"" /v AutoRun 2>nul") | Out-String) -match 'project-starter'
    Check CMD-autorun-installed $installed
    $cli = "$starter\shell\start-cli.cmd"
    $out = (cmd /c "`"$cli`" delta hi there --here" 2>&1) | Out-String
    Check CMD-shim (($out -match '\[omp-stub\]') -and ($out -match 'hi there')) $out
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$starter\install-cmd.ps1" -Remove | Out-Null
    $stillThere = ((cmd /c "reg query ""$reg"" /v AutoRun 2>nul") | Out-String) -match 'project-starter'
    Check CMD-autorun-removed (-not $stillThere)
} finally {
    if ($null -ne $registryBackup) { Set-Content -LiteralPath $registryPath -Value $registryBackup -Encoding utf8 }
    else { Remove-Item -LiteralPath $registryPath -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:OMP_PROJECTS_DIR, Env:OMP_STARTER_DIR_WIN -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $proj -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "RESULT: ALL PASS ($script:pass checks)" }
else { Write-Host "RESULT: $($script:fail) FAILED ($script:pass passed)"; exit 1 }
