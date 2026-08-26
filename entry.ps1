# CLI shim entry: maps flat argv onto the `start` function.
# Called by shell/start-cli.cmd (cmd doskey macro) and shell/start.sh (bash/zsh).
# Flags: --yolo/-yolo, --here/-here, --doctor, --version, --agent <name>,
#        --default-agent <name|none>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-Project.ps1')

$yolo = $false
$here = $false
$doctor = $false
$showVersion = $false
$name = $null
$agent = $null
$setDef = ''
$prompt = New-Object System.Collections.Generic.List[string]

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = $args[$i]
    if ($a -match '^(-yolo|--yolo)$') { $yolo = $true }
    elseif ($a -match '^(-here|--here)$') { $here = $true }
    elseif ($a -match '^(-doctor|--doctor)$') { $doctor = $true }
    elseif ($a -match '^(-version|--version|-v)$') { $showVersion = $true }
    elseif ($a -match '^(-default-agent|--default-agent)$') {
        $i++
        if ($i -ge $args.Count) { Write-Error '--default-agent requires a value (<name>|none)'; exit 1 }
        $setDef = $args[$i]
    }
    elseif ($a -match '^(-agent|--agent)$') {
        $i++
        if ($i -ge $args.Count) { Write-Error '--agent requires a value'; exit 1 }
        $agent = $args[$i]
    }
    elseif ($null -eq $name) { $name = $a }
    else { $prompt.Add($a) }
}

if ($showVersion) { start -Version; return }
if ($doctor) { start -Doctor; return }
if ($setDef -ne '' -or ($setDef -eq '' -and $args -contains '--default-agent') -or $args -contains '-default-agent') {
    start -SetDefaultAgent $setDef
    return
}

$call = @{ Name = $name; Yolo = $yolo; Here = $here }
if ($agent) { $call.Agent = $agent }
if ($prompt.Count -gt 0) { $call.Prompt = [string[]]$prompt.ToArray() }
start @call
