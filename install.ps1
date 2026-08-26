# Installs/updates the `lnch` function into PowerShell profiles.
# Removes both lnch and legacy project-starter profile lines (clean cutover).
$src = Join-Path $PSScriptRoot 'Lnch.ps1'
if (-not (Test-Path -LiteralPath $src)) { throw "Lnch.ps1 not found next to install.ps1 ($PSScriptRoot)" }

$docs = [Environment]::GetFolderPath('MyDocuments')
$profiles = @(
    (Join-Path $docs 'PowerShell\profile.ps1'),
    (Join-Path $docs 'WindowsPowerShell\profile.ps1')
)
$line = "if (Test-Path -LiteralPath '$src') { . '$src' }  # lnch"

foreach ($p in $profiles) {
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $kept = @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue |
        Where-Object { $_ -notmatch '#\s*(lnch|project-starter)\s*$' })
    $kept += $line
    Set-Content -LiteralPath $p -Value $kept
    Write-Host "installed/updated: $p"
}

$effective = $null
try { $effective = Get-ExecutionPolicy } catch { }
if ($effective -eq 'Restricted') {
    try { Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force }
    catch { Write-Warning "could not relax execution policy: $_" }
}

Write-Host ''
Write-Host 'ready. open a NEW PowerShell window, then:'
Write-Host '  lnch                    # multi-project picker'
Write-Host '  lnch my-project         # create/resume one project'
Write-Host '  lnch my-task fix bug    # initial prompt'
