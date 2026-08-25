# Installs/updates the `start` function into your PowerShell profile(s).
# Replaces any previous project-starter lines (idempotent + path-migration safe).
$src = Join-Path $PSScriptRoot 'Start-Project.ps1'
if (-not (Test-Path -LiteralPath $src)) {
    throw "Start-Project.ps1 not found next to install.ps1 ($PSScriptRoot)"
}

$docs = [Environment]::GetFolderPath('MyDocuments')
$profiles = @(
    (Join-Path $docs 'PowerShell\profile.ps1'),         # PowerShell 7+
    (Join-Path $docs 'WindowsPowerShell\profile.ps1')   # Windows PowerShell 5.1
)

$marker = '# project-starter'
$line = "if (Test-Path -LiteralPath '$src') { . '$src' }  $marker"

foreach ($p in $profiles) {
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $kept = @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue |
        Where-Object { $_ -notmatch [regex]::Escape($marker) })
    $kept += $line
    Set-Content -LiteralPath $p -Value $kept
    Write-Host "installed/updated: $p"
}

# Profiles will not load at all while the EFFECTIVE policy is Restricted.
# CurrentUser alone can be Undefined yet inherit Restricted from a higher scope,
# so judge by Get-ExecutionPolicy (effective), then override at CurrentUser.
$effective = $null
try { $effective = Get-ExecutionPolicy } catch {}

if ($null -eq $effective) {
    Write-Host 'execution policy: could not be queried; skipping check'
} elseif ($effective -eq 'Restricted') {
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    } catch {
        Write-Warning "could not relax execution policy: $_"
    }
    $effective = $null
    try { $effective = Get-ExecutionPolicy } catch {}
    if ($effective -eq 'Restricted') {
        Write-Warning 'profiles will NOT load while the effective execution policy is Restricted.'
        Write-Warning 'set it manually: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
    } else {
        Write-Host "execution policy: Restricted -> $effective"
    }
} else {
    Write-Host "execution policy: $effective"
}

Write-Host ''
Write-Host 'ready. open a NEW PowerShell window, then:'
Write-Host '  start                    # pick an existing project'
Write-Host '  start my-project         # new repo; reopening it RESUMES the last agent'
Write-Host '  start my-task fix bug    # extra words become the initial prompt'
