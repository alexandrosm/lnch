# Removes the `start` function's profile lines installed by install.ps1.
# Already-open shells keep the function until they are restarted.
$docs = [Environment]::GetFolderPath('MyDocuments')
$profiles = @(
    (Join-Path $docs 'PowerShell\profile.ps1'),         # PowerShell 7+
    (Join-Path $docs 'WindowsPowerShell\profile.ps1')   # Windows PowerShell 5.1
)

foreach ($p in $profiles) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $lines = Get-Content -LiteralPath $p
    $kept = @($lines | Where-Object { $_ -notmatch '# project-starter\s*$' })
    if ($kept.Count -eq $lines.Count) {
        Write-Host "nothing to remove: $p"
        continue
    }
    Set-Content -LiteralPath $p -Value $kept
    Write-Host "removed $($lines.Count - $kept.Count) line(s) from $p"
}

Write-Host ''
Write-Host 'note: <project>\.ps-project.json metadata files were left in place;'
Write-Host 'they are plain JSON and harmless. Delete manually if desired.'
