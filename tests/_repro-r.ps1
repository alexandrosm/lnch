# Isolated repro: bare agent + :plan.
$ErrorActionPreference = 'Stop'
$StarterDir = 'C:\tmp\project-starter'
$stubBin    = "$StarterDir\tests\stubs"
$proj       = Join-Path ([IO.Path]::GetTempPath()) ('ps-rprobe-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $proj | Out-Null

$registryPath = Join-Path $StarterDir 'agents.json'
@'
{
  "omp":   { "caps": { "resume": {"args":["-c"]} }, "takesPromptOnResume": true },
  "bare":  { "caps": {} }
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

$env:OMP_PROJECTS_DIR = $proj
$env:PATH = "$stubBin;C:\Windows\System32;" + $env:PATH

. (Join-Path $StarterDir 'Start-Project.ps1')
$__sf = ${function:start}

New-Item -ItemType Directory -Force -Path (Join-Path $proj 'jay2') | Out-Null
Set-Content -LiteralPath (Join-Path $proj 'jay2\.ps-project.json') -Value '{"agent":"bare","updated":"2026-01-01T00:00:00Z"}'

$out = & $__sf jay2 hi :plan -Here 2>&1
Write-Output ("CAP=[" + (($out | Out-String) -replace '\r?\n', ' | ') + "]")
$types = ($out | ForEach-Object { $_.GetType().Name }) -join ','
Write-Output ("TYPES=[" + $types + "]")

Remove-Item -Recurse -Force $proj -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $registryPath -Force -ErrorAction SilentlyContinue
