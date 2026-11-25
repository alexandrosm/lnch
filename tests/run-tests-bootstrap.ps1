# Offline archive-install regression coverage; no user profiles or registry are changed.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('lnch-bootstrap-test-' + [guid]::NewGuid().ToString('N'))
$originalHome = $HOME
$originalTemp = $env:TEMP
$originalTmp = $env:TMP
$script:fail = 0
function Check($label, $condition) {
    if ($condition) { Write-Host "PASS $label" } else { $script:fail++; Write-Host "FAIL $label" }
}
function Get-ArchiveHash([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

# Only the network boundary is replaced. Hashing, extraction, copying, and the
# installed engine execute for real; fixture installers cannot edit user state.
$downloadState = @{ Archive = $null; Hash = $null }
Set-Item Function:\Invoke-WebRequest -Value ({
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    if ($Uri.EndsWith('/SHA256SUMS')) {
        Set-Content -LiteralPath $OutFile -Value ($downloadState.Hash + '  lnch-v99.0.0.zip') -Encoding ascii
    } else {
        Copy-Item -LiteralPath $downloadState.Archive -Destination $OutFile -Force
    }
}.GetNewClosure())

try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    Set-Variable HOME -Value (Join-Path $temp 'home') -Force
    $env:TEMP = Join-Path $temp 'downloads'
    $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
    $payload = Join-Path $temp 'payload\lnch-v99.0.0'
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    Copy-Item -Path (Join-Path $repo '*.ps1') -Destination $payload
    Copy-Item -LiteralPath (Join-Path $repo 'agent-state-map.json') -Destination $payload
    Set-Content -LiteralPath (Join-Path $payload 'install.ps1') -Value 'param([switch]$ContinueLaunch); Set-Content -LiteralPath (Join-Path $PSScriptRoot ''install-ran'') -Value ''yes'''
    Set-Content -LiteralPath (Join-Path $payload 'install-cmd.ps1') -Value '# Isolated fixture: never touch the registry.'
    Set-Content -LiteralPath (Join-Path $payload 'install.sh') -Value 'exit 0' -Encoding ascii
    $downloadState.Archive = Join-Path $temp 'release.zip'
    Compress-Archive -LiteralPath $payload -DestinationPath $downloadState.Archive
    $downloadState.Hash = Get-ArchiveHash $downloadState.Archive
    $validArchive = $downloadState.Archive
    $validHash = $downloadState.Hash

    $destination = Join-Path $temp 'existing install'
    $project = Join-Path $destination 'projects\keep-me'
    $legacyWork = Join-Path $HOME '.project-starter\projects\keep-me\work.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyWork) -Force | Out-Null
    Set-Content -LiteralPath $legacyWork -Value 'unmigrated project data'
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $project 'work.txt') -Value 'irreplaceable project data'
    Set-Content -LiteralPath (Join-Path $destination 'agents.json') -Value '{"custom":{"caps":{}}}'
    Set-Content -LiteralPath (Join-Path $destination 'Lnch.ps1') -Value '# old engine'
    & (Join-Path $repo 'bootstrap.ps1') -Version v99.0.0 -Destination $destination
    Check 'manual install preserves legacy projects' ((Test-Path -LiteralPath $legacyWork) -and (Get-Content -LiteralPath $legacyWork -Raw).Trim() -eq 'unmigrated project data')
    $keptProject = Join-Path $project 'work.txt'
    $keptRegistry = Join-Path $destination 'agents.json'
    Check 'archive update preserves project data' ((Test-Path -LiteralPath $keptProject) -and (Get-Content -LiteralPath $keptProject -Raw).Trim() -eq 'irreplaceable project data')
    Check 'archive update preserves custom agents' ((Test-Path -LiteralPath $keptRegistry) -and (Get-Content -LiteralPath $keptRegistry -Raw).Trim() -eq '{"custom":{"caps":{}}}')
    $version = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $destination 'entry.ps1') --version
    Check 'updated engine runs from destination' ($LASTEXITCODE -eq 0 -and $version -match '^lnch v\d+\.\d+\.\d+$')

    $protected = Join-Path $temp 'protected'
    New-Item -ItemType Directory -Path $protected -Force | Out-Null
    $sentinel = Join-Path $protected 'Lnch.ps1'
    Set-Content -LiteralPath $sentinel -Value '# original engine'
    $downloadState.Hash = '0' * 64
    $rejected = $false
    try { & (Join-Path $repo 'bootstrap.ps1') -Version v99.0.0 -Destination $protected -ContinueLaunch } catch { $rejected = $true }
    Check 'bad checksum leaves installation untouched' ($rejected -and (Get-Content -LiteralPath $sentinel -Raw).Trim() -eq '# original engine' -and -not (Test-Path -LiteralPath (Join-Path $protected 'install-ran')))

    Set-Item Function:\Invoke-RestMethod -Value { throw 'fixture release lookup failure' }
    $rejected = $false
    try { & (Join-Path $repo 'bootstrap.ps1') -Destination $protected -ContinueLaunch } catch { $rejected = $true }
    Check 'automatic update fails closed when release lookup fails' ($rejected -and (Get-Content -LiteralPath $sentinel -Raw).Trim() -eq '# original engine')

    $malformed = Join-Path $temp 'malformed'
    New-Item -ItemType Directory -Path $malformed -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $malformed 'unrelated.txt') -Value 'not an lnch release'
    $downloadState.Archive = Join-Path $temp 'malformed.zip'
    Compress-Archive -LiteralPath $malformed -DestinationPath $downloadState.Archive
    $downloadState.Hash = Get-ArchiveHash $downloadState.Archive
    $rejected = $false
    try { & (Join-Path $repo 'bootstrap.ps1') -Version v99.0.0 -Destination $protected -ContinueLaunch } catch { $rejected = $true }
    Check 'malformed archive leaves installation untouched' ($rejected -and (Test-Path -LiteralPath $sentinel) -and (Get-Content -LiteralPath $sentinel -Raw).Trim() -eq '# original engine')

    $downloadState.Archive = $validArchive
    $downloadState.Hash = $validHash
    $clone = Join-Path $temp 'clone'
    New-Item -ItemType Directory -Path $clone -Force | Out-Null
    & git -C $clone init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'fixture git init failed' }
    Set-Content -LiteralPath (Join-Path $clone 'install.ps1') -Value 'param([switch]$ContinueLaunch); Set-Content -LiteralPath (Join-Path $PSScriptRoot ''install-ran'') -Value ''yes'''
    Set-Content -LiteralPath (Join-Path $clone 'install-cmd.ps1') -Value '# Isolated fixture.'
    Set-Content -LiteralPath (Join-Path $clone 'install.sh') -Value 'exit 0' -Encoding ascii
    $rejected = $false
    try { & (Join-Path $repo 'bootstrap.ps1') -Version v99.0.0 -Destination $clone -ContinueLaunch 2>$null } catch { $rejected = $true }
    Check 'failed git pull does not run installers' ($rejected -and -not (Test-Path -LiteralPath (Join-Path $clone 'install-ran')))
    Check 'bootstrap cleans owned temporary files' (@(Get-ChildItem -LiteralPath $env:TEMP -Force).Count -eq 0)
} finally {
    Set-Variable HOME -Value $originalHome -Force
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail) { Write-Host "RESULT: $script:fail FAILED"; exit 1 }
Write-Host 'RESULT: BOOTSTRAP ALL PASS'
exit 0
