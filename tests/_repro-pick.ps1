# Isolated repro v2: mirrors suite context (config seed + 2>&1 capture).
$ErrorActionPreference = 'Stop'
$StarterDir = 'C:\tmp\project-starter'
$stubBin    = "$StarterDir\tests\stubs"
$sysRoot    = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
$gitCmd     = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\cmd' } else { 'C:\Program Files\Git\cmd' }
$proj       = Join-Path ([IO.Path]::GetTempPath()) ('ps-pickprobe2-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $proj | Out-Null

$registryPath = Join-Path $StarterDir 'agents.json'
@'
{
  "omp":   { "caps": { "resume": {"args":["-c"]}, "resume-pick": {"args":["-r"]}, "mode:yolo": {"args":["--approval-mode","yolo"]}, "model": {"args":["--model"]} }, "takesPromptOnResume": true },
  "aider": { "caps": { "resume": {"args":["--resume","--last"]} }, "takesPromptOnResume": false },
  "bare":  { "caps": {} }
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

$env:OMP_PROJECTS_DIR = $proj
$env:OMP_CONFIG_DIR   = Join-Path $proj '_cfg'
New-Item -ItemType Directory -Force -Path $env:OMP_CONFIG_DIR | Out-Null
@{ defaultAgent = 'omp' } | ConvertTo-Json | Set-Content (Join-Path $env:OMP_CONFIG_DIR 'config.json')
$env:PATH = "$stubBin;$gitCmd;$sysRoot\System32;" + $env:PATH

. (Join-Path $StarterDir 'Start-Project.ps1')
$__sf = ${function:start}

Write-Host '--- create alpha ---'
$o1 = & $__sf alpha hello -Here 2>&1
($o1 | Out-String) | Write-Host

Write-Host '--- :pick with 2>&1 (suite style) ---'
$out = & $__sf alpha :pick -Here 2>&1
Write-Output ("CAP=[" + (($out | Out-String) -replace '\r?\n', ' | ') + "]")

Write-Host '--- :model fresh nu4 -Agent omp ---'
$out2 = & $__sf nu4 :model opus -Agent omp -Here 2>&1
Write-Output ("CAP2=[" + (($out2 | Out-String) -replace '\r?\n', ' | ') + "]")

Remove-Item -Recurse -Force $proj -ErrorAction SilentlyContinue
Remove-Item Env:OMP_PROJECTS_DIR, Env:OMP_CONFIG_DIR -ErrorAction SilentlyContinue
