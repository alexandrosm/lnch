# Runs inside the terminal tab spawned by `lnch`.
param([Parameter(Mandatory)][string]$LaunchId, [Parameter(Mandatory)][string]$RuntimeRoot)
$ErrorActionPreference = 'Stop'
$env:LNCH_RUNTIME_DIR = [System.IO.Path]::GetFullPath($RuntimeRoot)
. (Join-Path $PSScriptRoot 'Lnch.ps1')
$exitCode = 0
lnch -FromLauncher -LaunchId $LaunchId -RuntimeRoot $RuntimeRoot -ExitCode ([ref]$exitCode)
exit $exitCode
