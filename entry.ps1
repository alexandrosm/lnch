# CLI shim entry: maps flat argv onto the `lnch` function.
# Called by shell/lnch-cli.cmd (cmd doskey macro) and shell/lnch.sh (bash/zsh).
# Flags: --yolo/-yolo, --here/-here, --doctor, --discover, --sessions,
#        --include-children, --transcript <agent:id>, --tabs, --prune, --json,
#        --terminal/--terminal-backend/--window/--profile/--title-template,
#        --tab-color/--color-scheme/--agentterm-path/--agentterm-home/--agentterm-port,
#        --readiness-timeout, --version/-v, --agent <name>, --default-agent <name|none>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lnch.ps1')

$yolo = $false
$here = $false
$doctor = $false
$discover = $false
$sessions = $false
$includeChildren = $false
$transcript = $null
$json = $false
$tabs = $false
$prune = $false
$terminalMode = $null
$terminalBackend = $null
$terminalWindow = $null
$terminalProfile = $null
$terminalTitle = $null
$tabColor = $null
$colorScheme = $null
$agentTermPath = $null
$agentTermHome = $null
$agentTermPort = $null
$readinessTimeoutMs = $null
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
    elseif ($a -match '^(-discover|--discover)$') { $discover = $true }
    elseif ($a -match '^(-sessions|--sessions)$') { $sessions = $true }
    elseif ($a -match '^(-include-children|--include-children)$') { $includeChildren = $true }
    elseif ($a -match '^(-tabs|--tabs)$') { $tabs = $true }
    elseif ($a -match '^(-prune|--prune)$') { $prune = $true }
    elseif ($a -match '^(-transcript|--transcript)$') {
        $i++
        if ($i -ge $args.Count) { Write-Error '--transcript requires a session reference'; exit 1 }
        $transcript = $args[$i]
    }
    elseif ($a -match '^(-terminal|--terminal)$') {
        $i++; if ($i -ge $args.Count) { Write-Error '--terminal requires a mode'; exit 1 }; $terminalMode = $args[$i]
    }
    elseif ($a -match '^(-backend|--backend|-terminal-backend|--terminal-backend)$') {
        $i++; if ($i -ge $args.Count) { Write-Error '--terminal-backend requires auto, wt, agentterm, or inline'; exit 1 }; $terminalBackend = $args[$i]
    }
    elseif ($a -match '^(-window|--window)$') {
        $i++; if ($i -ge $args.Count) { Write-Error '--window requires a target'; exit 1 }; $terminalWindow = $args[$i]
    }
    elseif ($a -match '^(-profile|--profile)$') {
        $i++; if ($i -ge $args.Count) { Write-Error '--profile requires a name or GUID'; exit 1 }; $terminalProfile = $args[$i]
    }
    elseif ($a -match '^(-title-template|--title-template)$') {
        $i++; if ($i -ge $args.Count) { Write-Error '--title-template requires a value'; exit 1 }; $terminalTitle = $args[$i]
    }
    elseif ($a -match '^(-tab-color|--tab-color)$') {
        $i++; if ($i -ge $args.Count) { Write-Error '--tab-color requires #RGB or #RRGGBB'; exit 1 }; $tabColor = $args[$i]
    }
    elseif ($a -match '^(-color-scheme|--color-scheme)$') {
        $i++; if ($i -ge $args.Count) { Write-Error '--color-scheme requires a name'; exit 1 }; $colorScheme = $args[$i]
    }
    elseif ($a -match '^(-agentterm-path|--agentterm-path)$') {
        $i++; if ($i -ge $args.Count) { Write-Error '--agentterm-path requires a value'; exit 1 }; $agentTermPath = $args[$i]
    }
    elseif ($a -match '^(-agentterm-home|--agentterm-home)$') {
        $i++; if ($i -ge $args.Count) { Write-Error '--agentterm-home requires a value'; exit 1 }; $agentTermHome = $args[$i]
    }
    elseif ($a -match '^(-agentterm-port|--agentterm-port)$') {
        $i++; if ($i -ge $args.Count -or $args[$i] -notmatch '^\d+$') { Write-Error '--agentterm-port requires a port'; exit 1 }; $agentTermPort = [int]$args[$i]
    }
    elseif ($a -match '^(-readiness-timeout|--readiness-timeout)$') {
        $i++; if ($i -ge $args.Count -or $args[$i] -notmatch '^\d+$') { Write-Error '--readiness-timeout requires milliseconds'; exit 1 }; $readinessTimeoutMs = [int]$args[$i]
    }
    elseif ($a -match '^(-json|--json)$') { $json = $true }
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

if ($showVersion) { lnch -Version; return }
if ($doctor) { lnch -Doctor; return }
if ($discover) { lnch -Discover -Json:$json; return }
if ($sessions) { lnch -Sessions -Name $name -Agent $agent -IncludeChildren:$includeChildren -Json:$json; return }
if ($transcript) { lnch -Transcript $transcript -Agent $agent -Json:$json; return }
if ($tabs) { lnch -Tabs -Prune:$prune -Json:$json; return }
if ($setDef -ne '' -or ($setDef -eq '' -and $args -contains '--default-agent') -or $args -contains '-default-agent') {
    lnch -SetDefaultAgent $setDef
    return
}

$call = @{ Name = $name; Yolo = $yolo; Here = $here }
if ($agent) { $call.Agent = $agent }
if ($terminalMode) { $call.TerminalMode = $terminalMode }
if ($terminalBackend) { $call.TerminalBackend = $terminalBackend }
if ($terminalWindow) { $call.TerminalWindow = $terminalWindow }
if ($terminalProfile) { $call.TerminalProfile = $terminalProfile }
if ($terminalTitle) { $call.TerminalTitle = $terminalTitle }
if ($tabColor) { $call.TabColor = $tabColor }
if ($colorScheme) { $call.ColorScheme = $colorScheme }
if ($agentTermPath) { $call.AgentTermPath = $agentTermPath }
if ($agentTermHome) { $call.AgentTermHome = $agentTermHome }
if ($null -ne $agentTermPort) { $call.AgentTermPort = $agentTermPort }
if ($null -ne $readinessTimeoutMs) { $call.ReadinessTimeoutMs = $readinessTimeoutMs }
if ($prompt.Count -gt 0) { $call.Prompt = [string[]]$prompt.ToArray() }
lnch @call
