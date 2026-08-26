# Registers/unregisters an interactive-only doskey `lnch` macro for cmd.exe.
# Removes legacy project-starter/start AutoRun hooks during install/remove.
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$bat  = Join-Path $root 'shell\lnch-cmd-autorun.bat'
$cli  = Join-Path $root 'shell\lnch-cli.cmd'
$key  = 'HKCU:\Software\Microsoft\Command Processor'
$legacyBat = Join-Path $root 'shell\cmd-autorun.bat'

function Get-CleanAutoRun([string]$Value) {
    if (-not $Value) { return '' }
    return (@($Value -split '&' | Where-Object { $_ -notmatch '(?i)(project-starter|lnch)' } |
        ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' & ')
}

if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
$cur = (Get-ItemProperty -Path $key -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
$clean = Get-CleanAutoRun $cur

if ($Remove) {
    if ($clean) { Set-ItemProperty -Path $key -Name AutoRun -Value $clean }
    else { Remove-ItemProperty -Path $key -Name AutoRun -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $bat, $legacyBat -Force -ErrorAction SilentlyContinue
    Write-Host "removed lnch/legacy hooks from $key\AutoRun"
    return
}

if (-not (Test-Path -LiteralPath (Join-Path $root 'Lnch.ps1'))) { throw 'run install-cmd.ps1 from the lnch checkout' }
$lines = @(
    '@echo off',
    'rem lnch macro for INTERACTIVE cmd only.',
    'setlocal enabledelayedexpansion',
    'set "LNCH_CL=%cmdcmdline%"',
    'if defined LNCH_CL (',
    '    if not "!LNCH_CL:/c=!"=="!LNCH_CL!" exit /b 0',
    '    if not "!LNCH_CL:/k=!"=="!LNCH_CL!" exit /b 0',
    ')',
    ('doskey lnch="' + $cli + '" $*'),
    'endlocal'
)
Set-Content -LiteralPath $bat -Value ($lines -join "`r`n") -Encoding ascii
Remove-Item -LiteralPath $legacyBat -Force -ErrorAction SilentlyContinue

$seg = "`"$bat`""
$new = if ($clean) { "$clean & $seg" } else { $seg }
if ($cur) { Set-ItemProperty -Path $key -Name AutoRun -Value $new }
else { New-ItemProperty -Path $key -Name AutoRun -Value $new -PropertyType String | Out-Null }
Write-Host "installed: $key\AutoRun"
