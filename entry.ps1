# CLI shim entry: maps flat argv onto the `lnch` function.
# Called by shell/lnch-cli.cmd (cmd doskey macro) and shell/lnch.sh (bash/zsh).
# Flags: --yolo/-yolo, --here/-here, --no-dashboard, --top, --doctor,
#        --discover, --sessions, --include-children, --transcript <agent:id>, --tabs, --prune, --json,
#        --terminal/--terminal-backend/--window/--profile/--title-template,
#        --tab-color/--color-scheme/--agentterm-path/--agentterm-home/--agentterm-port,
#        --readiness-timeout, --version/-v, --agent <name>, --default-agent <name|none>,
#        --git-name <name>, --git-email <email>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lnch.ps1')

$call = ConvertFrom-LnchCliArguments -Arguments $args
$exitCode = 0
lnch @call -ExitCode ([ref]$exitCode)
exit $exitCode
