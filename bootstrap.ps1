# project-starter remote bootstrap for PowerShell / cmd boxes:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm <this-url> | iex"
# Downloads the repo to ~\.project-starter, then wires up the PowerShell face
# (and the bash face when a bash.exe is available). Idempotent: an existing
# git clone is pulled; an older copy is replaced.
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$repo   = 'https://github.com/alexandrosm/project-starter'
$zipUrl = "$repo/archive/refs/heads/main.zip"
$dest   = Join-Path $HOME '.project-starter'
$tmpZip = Join-Path ([IO.Path]::GetTempPath()) 'project-starter-main.zip'
$tmpExt = Join-Path ([IO.Path]::GetTempPath()) ('project-starter-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

Write-Host 'fetching project-starter...'
Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing
if (Test-Path $tmpExt) { Remove-Item $tmpExt -Recurse -Force }
Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpExt -Force
$unpacked = Join-Path $tmpExt 'project-starter-main'

if (Test-Path (Join-Path $dest '.git')) {
    Write-Host 'updating existing clone...'
    git -C $dest pull --ff-only | Out-Null
} else {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item $unpacked $dest -Recurse
}
Remove-Item $tmpZip, $tmpExt -Recurse -Force -ErrorAction SilentlyContinue

& (Join-Path $dest 'install.ps1')

if ((Get-Command bash.exe -ErrorAction SilentlyContinue) -and -not $NoBash) {
    Write-Host ''
    Write-Host 'bash detected - wiring the bash/zsh face too:'
    # bash chokes on backslash paths; hand it a forward-slash drive form
    $posixish = $dest -replace '\\', '/'
    & bash "$posixish/install.sh"
}

Write-Host ''
Write-Host 'done. open a NEW window, then:  start my-project'
