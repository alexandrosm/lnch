# Removes lnch and legacy project-starter profile lines.
# Already-open shells keep loaded functions until restarted.
$docs = [Environment]::GetFolderPath('MyDocuments')
$profiles = @(
    (Join-Path $docs 'PowerShell\profile.ps1'),
    (Join-Path $docs 'WindowsPowerShell\profile.ps1')
)
foreach ($p in $profiles) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $lines = @(Get-Content -LiteralPath $p)
    $kept = @($lines | Where-Object { $_ -notmatch '#\s*(lnch|project-starter)\s*$' })
    if ($kept.Count -ne $lines.Count) {
        Set-Content -LiteralPath $p -Value $kept
        Write-Host "removed $($lines.Count - $kept.Count) line(s) from $p"
    } else { Write-Host "nothing to remove: $p" }
}
Write-Host ''
Write-Host 'Project .lnch.json metadata files remain intentionally.'
