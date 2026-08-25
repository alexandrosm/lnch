# project-starter remote bootstrap for PowerShell / cmd boxes:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm <this-url> | iex"
# Downloads the repo to ~\.project-starter, then wires up the PowerShell face
# (and the bash face when an MSYS2/Git-bash is available). Idempotent.
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
    # convert to MSYS-style POSIX path: C:\foo -> /c/foo
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
