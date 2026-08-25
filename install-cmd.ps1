# Registers/unregisters an interactive-only doskey `start` macro for cmd.exe.
# Installs shell\cmd-autorun.bat and chains it into HKCU Command Processor AutoRun.
# The .bat skips itself when cmd runs with /c or /k using DELAYED EXPANSION so the
# quoted %cmdcmdline% value never re-parses; scripted `cmd /c start ...` therefore
# keeps using cmd's built-in start.
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$bat  = Join-Path $root 'shell\cmd-autorun.bat'
$key  = 'HKCU:\Software\Microsoft\Command Processor'

if (-not $Remove) {
    if (-not (Test-Path -LiteralPath (Join-Path $root 'Start-Project.ps1'))) {
        throw "run install-cmd.ps1 from the project-starter checkout"
    }
    # generate the autorun hook with this checkout's absolute path
    $lines = @(
        '@echo off',
        'rem project-starter: `start` macro for INTERACTIVE cmd only.',
        'setlocal enabledelayedexpansion',
        'set "PS_CL=%cmdcmdline%"',
        'if defined PS_CL (',
        '    if not "!PS_CL:/c=!"=="!PS_CL!" exit /b 0',
        '    if not "!PS_CL:/k=!"=="!PS_CL!" exit /b 0',
        ')',
        ('doskey start="' + $bat + '" $*'),
        'endlocal'
    )
    New-Item -ItemType Directory -Force -Path (Split-Path $bat -Parent) | Out-Null
    Set-Content -LiteralPath $bat -Value ($lines -join "`r`n") -Encoding ascii

    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    $cur = (Get-ItemProperty -Path $key -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
    if ($cur -and $cur -match 'project-starter') {
        Write-Host "already installed: $key\AutoRun"
        return
    }
    $seg = "`"$bat`""
    $new = if ($cur) { "$cur & $seg" } else { $seg }
    if ($cur) {
        Set-ItemProperty -Path $key -Name AutoRun -Value $new
    } else {
        New-ItemProperty -Path $key -Name AutoRun -Value $new -PropertyType String | Out-Null
    }
    Write-Host "installed: $key\AutoRun"
} else {
    $cur = (Get-ItemProperty -Path $key -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
    if (-not $cur -or $cur -notmatch 'project-starter') {
        Write-Host 'nothing to remove'
        return
    }
    $kept = @($cur -split '&' | Where-Object { $_ -notmatch 'project-starter' } | ForEach-Object { $_.Trim() }) -join ' & '
    if ($kept) {
        Set-ItemProperty -Path $key -Name AutoRun -Value $kept
    } else {
        Remove-ItemProperty -Path $key -Name AutoRun
    }
    Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue
    Write-Host "removed project-starter from $key\AutoRun"
}
