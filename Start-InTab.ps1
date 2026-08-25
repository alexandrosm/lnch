# Runs inside the terminal tab spawned by `start`.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-Project.ps1')
start -FromLauncher
