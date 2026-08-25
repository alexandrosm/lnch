# CLI shim entry: maps flat argv onto the `start` function.
# Called by shell/start-cli.cmd (cmd doskey macro) and shell/start.sh (bash/zsh).
# Flags: --yolo/-yolo, --here/-here (lowercase twins of the PowerShell -Yolo/-Here).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-Project.ps1')

$yolo = $false
$here = $false
$name = $null
$prompt = New-Object System.Collections.Generic.List[string]

foreach ($a in $args) {
    if ($a -match '^(-yolo|--yolo)$') { $yolo = $true }
    elseif ($a -match '^(-here|--here)$') { $here = $true }
    elseif ($null -eq $name) { $name = $a }
    else { $prompt.Add($a) }
}

$call = @{ Name = $name; Yolo = $yolo; Here = $here }
if ($prompt.Count -gt 0) { $call.Prompt = [string[]]$prompt.ToArray() }
start @call
