# Runs inside the terminal tab spawned by `lnch`.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lnch.ps1')
lnch -FromLauncher
