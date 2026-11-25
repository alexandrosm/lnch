# lnch remote bootstrap for PowerShell / cmd boxes:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm <this-url> | iex"
# Optional: -Version vX.Y.Z pins a tagged release (default: latest release,
# falling back to the main branch when the API is unreachable).
# Tagged downloads are SHA256-verified against the release's SHA256SUMS.
param(
    [string]$Version = '',
    [string]$Destination = '',
    [switch]$ContinueLaunch
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$repo    = 'https://github.com/alexandrosm/lnch'
$api     = 'https://api.github.com/repos/alexandrosm/lnch'
$dest = if ([string]::IsNullOrWhiteSpace($Destination)) { Join-Path $HOME '.lnch' } else { [IO.Path]::GetFullPath($Destination) }
if ([string]::Equals($dest, [IO.Path]::GetPathRoot($dest), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to install lnch over filesystem root '$dest'"
}
$legacyDest = Join-Path $HOME '.project-starter'
$headers = @{ 'User-Agent' = 'lnch-bootstrap' }

$isGitCheckout = Test-Path -LiteralPath (Join-Path $dest '.git')
if (-not $Version -and -not $isGitCheckout) {
    Write-Host 'resolving latest release...'
    try {
        $Version = (Invoke-RestMethod -Uri "$api/releases/latest" -TimeoutSec 10 -Headers $headers).tag_name
        Write-Host "latest release: $Version"
    } catch {
        if ($ContinueLaunch) { throw 'could not resolve a verified release for the pre-launch update' }
        Write-Warning 'could not reach the GitHub API; falling back to the main branch'
        $Version = 'main'
    }
}


function Get-LnchFileSha256([string]$Path) {
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

if ($isGitCheckout) {
    Write-Host 'updating existing clone...'
    git -C $dest pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull failed with exit code $LASTEXITCODE" }
} else {
    # Each invocation owns its downloads, including the checksum manifest.
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('lnch-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpRoot | Out-Null
    try {
        $tmpZip = Join-Path $tmpRoot 'release.zip'
        $tmpExt = Join-Path $tmpRoot 'unpacked'
        Write-Host "fetching lnch $Version..."
        if ($Version -eq 'main') {
            Invoke-WebRequest -Uri "$repo/archive/refs/heads/main.zip" -OutFile $tmpZip -UseBasicParsing
            $innerPrefix = 'lnch-main'
        } else {
            Invoke-WebRequest -Uri "$repo/releases/download/$Version/lnch-$Version.zip" -OutFile $tmpZip -UseBasicParsing
            $sumsTxt = Join-Path $tmpRoot 'SHA256SUMS'
            Invoke-WebRequest -Uri "$repo/releases/download/$Version/SHA256SUMS" -OutFile $sumsTxt -UseBasicParsing
            $sumLine = (Get-Content -LiteralPath $sumsTxt) |
                Where-Object { $_ -match ('^[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape("lnch-$Version.zip") + '$') } |
                Select-Object -First 1
            if (-not $sumLine) { throw 'SHA256SUMS did not contain an entry for the archive' }
            $expected = ($sumLine -split '\s+')[0]
            $actual = Get-LnchFileSha256 $tmpZip
            if ($actual -ne $expected) { throw "checksum mismatch: expected $expected got $actual" }
            Write-Host 'checksum verified'
            $innerPrefix = "lnch-$Version"
        }

        # A new staging path needs no overwrite overload; this works on .NET Framework and Core.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $tmpExt)
        $unpacked = Join-Path $tmpExt $innerPrefix
        if (-not (Test-Path -LiteralPath (Join-Path $unpacked 'Lnch.ps1') -PathType Leaf)) { $unpacked = $tmpExt }
        foreach ($required in @('Lnch.ps1', 'entry.ps1', 'install.ps1', 'install-cmd.ps1', 'install.sh')) {
            if (-not (Test-Path -LiteralPath (Join-Path $unpacked $required) -PathType Leaf)) {
                throw "archive is missing $required; installation unchanged"
            }
        }

        # Replace shipped files, never the enclosing directory: users may keep
        # custom agents.json and projects under an installed lnch root.
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path (Join-Path $unpacked '*') -Destination $dest -Recurse -Force
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The command and shell shims already point at this installation. A launch-time
# update must not rewrite profiles or registry hooks on every agent invocation.
if ($ContinueLaunch) { return }

& (Join-Path $dest 'install.ps1')
& (Join-Path $dest 'install-cmd.ps1')

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

if (Test-Path -LiteralPath $legacyDest) {
    Write-Host "left $legacyDest in place; check it for projects before removing it"
}

Write-Host ''
Write-Host 'done. open a NEW window, then:  lnch my-project'
