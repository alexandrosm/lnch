# Reproducible local release packaging for lnch.
# Usage: ./scripts/release-local.ps1 -Tag v0.5.2
# Order matters: the TAG must exist before git archive can read it.
# Uses raw .NET SHA256 - no cmdlet availability required.
param([Parameter(Mandatory)][string]$Tag)
$ErrorActionPreference = 'Stop'
$repoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw 'not inside a git repository' }
Set-Location $repoRoot

# fail fast if the tag is missing locally
git rev-parse -q --verify "refs/tags/$Tag" | Out-Null
if ($LASTEXITCODE -ne 0) {
    git tag -a $Tag -m "$Tag"
    if ($LASTEXITCODE -ne 0) { throw "failed to create tag $Tag" }
    Write-Output ("created tag {0}" -f $Tag)
}

$zipPath = Join-Path $repoRoot "lnch-$Tag.zip"
git archive --format=zip "--output=$zipPath" $Tag

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $stream = [System.IO.File]::OpenRead($zipPath)
    try {
        $bytes = $sha.ComputeHash($stream)
    } finally {
        $stream.Dispose()
    }
} finally {
    $sha.Dispose()
}
$hash = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
$sumLine = "$hash  lnch-$Tag.zip`n"
[System.IO.File]::WriteAllText((Join-Path $repoRoot 'SHA256SUMS'), $sumLine, (New-Object System.Text.UTF8Encoding($false)))

$size = (Get-Item $zipPath).Length
Write-Output ("packaged lnch-$Tag.zip ($size bytes)")
Write-Output ("sha256    = $hash")
if ($size -lt 1000) { throw 'archive suspiciously small - refusing' }
Write-Output 'publish:'
Write-Output ("  gh release create {0} lnch-{0}.zip SHA256SUMS --title {0} --generate-notes" -f $Tag)
Write-Output 'replace existing assets:'
Write-Output ("  gh release upload {0} lnch-{0}.zip SHA256SUMS --clobber" -f $Tag)
