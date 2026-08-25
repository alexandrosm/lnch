# Installs the `start` function into your PowerShell profile(s).
# Run once:  powershell -ExecutionPolicy Bypass -File install.ps1
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
foreach ($p in $profiles) {
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $existing = if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw } else { '' }
    if ($existing -and $existing.Contains($marker)) {
        Write-Host "already installed: $p"
    } else {
        Add-Content -Path $p -Value "if (Test-Path -LiteralPath '$src') { . '$src' }  $marker"
        Write-Host "installed:         $p"
    }
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
Write-Host '  start                              # pick a project (shows saved intents)'
Write-Host '  start my-project                   # new repo; reopening RESUMES the last agent'
Write-Host '  start my-task fix bug              # words become initial prompt AND saved intent'
Write-Host '  start risky-refactor ... -Yolo     # appends the agent auto-approval flag'
Write-Host ''
Write-Host 'projects open in a NEW terminal tab (-Here stays inline).'
Write-Host 'per-project metadata lives in <project>\.ps-project.json.'
Write-Host 'add/tweak agents via agents.json next to Start-Project.ps1.'
Write-Host "projects root: `$env:OMP_PROJECTS_DIR, default C:\projects"
Write-Host ''
Write-Host 'an ALREADY-open window will not see this until you reload its profile:'
Write-Host "  . '$src'"
