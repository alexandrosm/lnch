# Reproducible local release packaging for project-starter.
# Usage: ./scripts/release-local.ps1 -Tag v0.4.1
# Runs from the REPO ROOT (git rev-parse --show-toplevel) so git archive
# captures the full committed tree. Uses raw .NET SHA256 - no cmdlet
# availability required.
param([Parameter(Mandatory)][string]$Tag)
$ErrorActionPreference = 'Stop'
$repoRoot = (git rev-parse --show-toplevel).Trim()
Set-Location $repoRoot
$zipPath = Join-Path $repoRoot "project-starter-$Tag.zip"

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
"$hash  project-starter-$Tag.zip" | Set-Content SHA256SUMS

$size = (Get-Item $zipPath).Length
Write-Output ("packaged project-starter-$Tag.zip ($size bytes)")
Write-Output ("sha256    = $hash")
if ($size -lt 1000) { throw 'archive suspiciously small - refusing' }
Write-Output 'publish:'
Write-Output ("  gh release create {0} project-starter-{0}.zip SHA256SUMS --title {0} --generate-notes" -f $Tag)
Write-Output 'replace existing assets:'
Write-Output ("  gh release upload {0} project-starter-{0}.zip SHA256SUMS --clobber" -f $Tag)
