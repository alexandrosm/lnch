# project-starter remote bootstrap for PowerShell / cmd boxes:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm <this-url> | iex"
# Optional: -Version v0.3.0 pins a tagged release (default: latest release,
# falling back to the main branch when the API is unreachable).
# Tagged downloads are SHA256-verified against the release's SHA256SUMS.
param([string]$Version = '')

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$repo    = 'https://github.com/alexandrosm/project-starter'
$api     = 'https://api.github.com/repos/alexandrosm/project-starter'
$dest    = Join-Path $HOME '.project-starter'
$headers = @{ 'User-Agent' = 'project-starter-bootstrap' }

if (-not $Version) {
    Write-Host 'resolving latest release...'
    try {
        $Version = (Invoke-RestMethod -Uri "$api/releases/latest" -TimeoutSec 10 -Headers $headers).tag_name
        Write-Host "latest release: $Version"
    } catch {
        Write-Warning 'could not reach the GitHub API; falling back to the main branch'
        $Version = 'main'
    }
}

$tmpZip = Join-Path ([IO.Path]::GetTempPath()) ('project-starter-' + ($Version -replace '[^A-Za-z0-9._-]', '') + '.zip')
$tmpExt = Join-Path ([IO.Path]::GetTempPath()) ('project-starter-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

function Get-StarterFileSha256([string]$Path) {
    # raw .NET hash: immune to cmdlet/module availability in stripped hosts
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '')
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

Write-Host "fetching project-starter $Version..."
if ($Version -eq 'main') {
    Invoke-WebRequest -Uri "$repo/archive/refs/heads/main.zip" -OutFile $tmpZip -UseBasicParsing
    $innerPrefix = 'project-starter-main'
} else {
    Invoke-WebRequest -Uri "$repo/releases/download/$Version/project-starter-$Version.zip" -OutFile $tmpZip -UseBasicParsing
    $sumsTxt = Join-Path ([IO.Path]::GetTempPath()) 'SHA256SUMS'
    Invoke-WebRequest -Uri "$repo/releases/download/$Version/SHA256SUMS" -OutFile $sumsTxt -UseBasicParsing
    $sumLine = (Get-Content $sumsTxt) |
        Where-Object { $_ -match ('project-starter-' + [regex]::Escape($Version) + '\.zip') } |
        Select-Object -First 1
    if (-not $sumLine) { throw 'SHA256SUMS did not contain an entry for the archive' }
    $expected = ($sumLine -split '\s+')[0]
    $actual = Get-StarterFileSha256 $tmpZip
    if ($actual -ne $expected) { throw "checksum mismatch: expected $expected got $actual" }
    Write-Host 'checksum verified'
    $innerPrefix = "project-starter-$Version"
}

if (Test-Path $tmpExt) { Remove-Item $tmpExt -Recurse -Force }
Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpExt -Force
$unpacked = Join-Path $tmpExt $innerPrefix
if (-not (Test-Path (Join-Path $unpacked 'Start-Project.ps1'))) { $unpacked = $tmpExt }

if (Test-Path (Join-Path $dest '.git')) {
    Write-Host 'updating existing clone...'
    git -C $dest pull --ff-only | Out-Null
} else {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item $unpacked $dest -Recurse
}
Remove-Item $tmpZip, $tmpExt -Recurse -Force -ErrorAction SilentlyContinue

& (Join-Path $dest 'install.ps1')

# wire the bash/zsh face using an MSYS2 bash (the WindowsApps bash.exe is a WSL
# launcher that cannot read Windows paths)
$bashExe = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bashExe)) {
    $cand = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($cand -and $cand.Source -notmatch 'WindowsApps') { $bashExe = $cand.Source }
}
if ($bashExe -and (Test-Path $bashExe)) {
    Write-Host ''
    Write-Host 'bash detected - wiring the bash/zsh face too:'
    $drive = $dest.Substring(0, 1).ToLower()
    $rest  = $dest.Substring(3).Replace('\', '/')
    $posix = "/$drive/$rest"
    & $bashExe "$posix/install.sh"
} else {
    Write-Host ''
    Write-Host 'no MSYS2 bash found - skipping bash/zsh face (see README for manual install)'
}

Write-Host ''
Write-Host 'done. open a NEW window, then:  start my-project'
