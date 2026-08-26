# project-starter: the `start` command for PowerShell.
#
#   start                      pick an existing project (fzf if installed, else numbered list;
#                              shows saved intent + last-active time)
#   start <name> [words...]    create <root>\<name> + git repo, launch agent in a NEW TAB;
#                              extra words become the agent's initial prompt AND are saved
#                              as the project's intent
#   start <name> ... -Yolo     shorthand for the :yolo capability
#
#   CAPABILITY VERBS (may appear anywhere among the prompt words):
#     :pick              resume, choosing among past sessions
#     :plan :edits       approval ladder (where the agent supports it)
#     :yolo              auto-approve everything
#     :model <value>     pin the model for this session
#   A verb an agent does not implement warns and is skipped - never a raw CLI error.
#
#   New projects are seeded with AGENTS.md (+ CLAUDE.md/GEMINI.md pointers), and any
#   postCreate commands from config.json run inside the fresh directory.
#
#   Reopening an existing project auto-resumes with the agent that last ran there:
#   recorded in .ps-project.json ({agent,intent,created,updated}), falling back to
#   .claude/.codex/.gemini fingerprints and omp's own session buckets.
#
#   AGENT REGISTRY: built-ins below; an optional agents.json next to this script
#   merges over them. Two accepted shapes per agent:
#     v2:  "caps": { "resume": {"args":["-c"]}, "mode:yolo": {"args":["--flag"]} }
#          plus optional takesPromptOnResume
#     v0.3 legacy: continueArgs / takesPromptOnContinue / yoloFlags (auto-migrated)
#
#   -Here   launch inline instead of a new tab.
#   Root:   $env:OMP_PROJECTS_DIR, otherwise <current working directory>\projects
#   Config: %APPDATA%\project-starter\config.json (override dir: $env:OMP_CONFIG_DIR)

if (Get-Command start -CommandType Alias -ErrorAction SilentlyContinue) {
    Remove-Item Alias:start -Force -ErrorAction SilentlyContinue
}

$script:StarterRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:StarterVersion = '0.5.3'
$script:KnownVerbs = @('pick', 'yolo', 'plan', 'edits', 'resume', 'resume-pick', 'model')

# Built-in registry: capability manifest per agent. Only VERIFIED mappings ship;
# agents.json fills the gaps (that is the point of the tent).
$script:AgentProfiles = @{
    omp = @{
        TakesPromptOnResume = $true
        Caps                = @{
            'resume'      = @{ Args = @('-c') }
            'resume-pick' = @{ Args = @('-r') }
            'mode:yolo'   = @{ Args = @('--approval-mode', 'yolo') }
            'model'       = @{ Args = @('--model') }
        }
    }
    claude = @{
        TakesPromptOnResume = $true
        Caps                = @{
            'resume'      = @{ Args = @('-c') }
            'resume-pick' = @{ Args = @('--resume') }
            'mode:yolo'   = @{ Args = @('--dangerously-skip-permissions') }
            'mode:plan'   = @{ Args = @('--permission-mode', 'plan') }
            'mode:edits'  = @{ Args = @('--permission-mode', 'acceptEdits') }
            'model'       = @{ Args = @('--model') }
        }
    }
    codex = @{
        TakesPromptOnResume = $false
        Caps                = @{
            'resume'      = @{ Args = @('resume', '--last') }
            'resume-pick' = @{ Args = @('resume') }
            'mode:yolo'   = @{ Args = @('--full-auto') }
            'model'       = @{ Args = @('-m') }
        }
    }
    gemini = @{
        TakesPromptOnResume = $true
        Caps                = @{}
    }
    aider = @{
        TakesPromptOnResume = $false
        Caps                = @{
            'resume'    = @{ Args = @('--resume') }
            'mode:yolo' = @{ Args = @('--yes-always') }
            'model'     = @{ Args = @('--model') }
        }
    }
    opencode = @{
        TakesPromptOnResume = $true
        Caps                = @{
            'resume' = @{ Args = @('--continue') }
        }
    }
    qwen = @{
        TakesPromptOnResume = $true
        Caps                = @{
            'mode:yolo' = @{ Args = @('--yolo') }
        }
    }
}

function global:Get-StarterAgentRegistry {
    # builtins -> overlay agents.json (v2 caps shape or v0.3 legacy shape)
    $table = @{}
    foreach ($k in $script:AgentProfiles.Keys) {
        $table[$k] = @{
            TakesPromptOnResume = $script:AgentProfiles[$k].TakesPromptOnResume
            Caps                = $script:AgentProfiles[$k].Caps
        }
    }
    $registry = Join-Path $script:StarterRoot 'agents.json'
    if (Test-Path -LiteralPath $registry) {
        try {
            $custom = Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json
            foreach ($prop in $custom.PSObject.Properties) {
                $e = $prop.Value
                if ($e.caps) {
                    $caps = @{}
                    foreach ($cp in $e.caps.PSObject.Properties) {
                        $caps[$cp.Name] = @{ Args = @(@($cp.Value.args) | Where-Object { $_ }) }
                    }
                    $take = if ($null -ne $e.takesPromptOnResume) { [bool]$e.takesPromptOnResume } else { $true }
                } else {
                    # v0.3 legacy shape
                    $caps = @{
                        'resume'    = @{ Args = @(@($e.continueArgs) | Where-Object { $_ }) }
                        'mode:yolo' = @{ Args = @(@($e.yoloFlags) | Where-Object { $_ }) }
                    }
                    $take = if ($null -ne $e.takesPromptOnContinue) { [bool]$e.takesPromptOnContinue } else { $true }
                }
                $table[$prop.Name] = @{ TakesPromptOnResume = $take; Caps = $caps }
            }
        } catch {
            Write-Warning "agents.json ignored (invalid JSON): $_"
        }
    }
    $table
}

$script:AgentProfiles = Get-StarterAgentRegistry

function global:Get-StarterConfigPath {
    if ($env:OMP_CONFIG_DIR) { return $env:OMP_CONFIG_DIR }
    $base = [Environment]::GetFolderPath('ApplicationData')
    if (-not $base) { $base = if ($env:TEMP) { $env:TEMP } else { 'C:\Windows\Temp' } }
    Join-Path $base 'project-starter'
}

function global:Get-StarterProjectsRoot {
    if ($env:OMP_PROJECTS_DIR) {
        return [System.IO.Path]::GetFullPath($env:OMP_PROJECTS_DIR)
    }
    $cwd = (Get-Location).Path
    return [System.IO.Path]::GetFullPath((Join-Path $cwd 'projects'))
}

function global:Get-StarterUserConfig {
    $p = Join-Path (Get-StarterConfigPath) 'config.json'
    if (Test-Path -LiteralPath $p) {
        try { return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { }
    }
    $null
}

function global:Get-StarterDefaultAgent {
    $c = Get-StarterUserConfig
    if ($c -and $c.defaultAgent) { return $c.defaultAgent }
    $null
}

function global:Get-StarterPostCreateHook {
    $c = Get-StarterUserConfig
    if ($c -and $c.postCreate) { return @($c.postCreate) }
    @()
}

function global:Set-StarterDefaultAgent {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Agent)
    $dir = Get-StarterConfigPath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $p = Join-Path $dir 'config.json'
    $payload = @{ defaultAgent = if ([string]::IsNullOrWhiteSpace($Agent)) { $null } else { $Agent.Trim() } }
    if ($PSCmdlet.ShouldProcess($p, 'write default agent config')) {
        $payload | ConvertTo-Json | Set-Content -LiteralPath $p -Encoding utf8
    }
    if ([string]::IsNullOrWhiteSpace($Agent)) { Write-Host 'default agent cleared' }
    else { Write-Host "default agent set to '$($Agent.Trim())'" }
}

function script:Get-StarterUpdateNoticeState {
    # returns latest release tag or $null; caches for 24h; never throws
    if ($env:OMP_NO_UPDATE_CHECK) { return $null }
    $cacheFile = Join-Path (Get-StarterConfigPath) 'update-cache.json'
    if (Test-Path -LiteralPath $cacheFile) {
        try {
            $c = Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json
            if (((Get-Date) - [datetime]$c.checked).TotalHours -lt 24) { return $c.latest }
        } catch { }
    }
    $latest = $null
    try {
        $latest = (Invoke-RestMethod -Uri 'https://api.github.com/repos/alexandrosm/project-starter/releases/latest' `
            -TimeoutSec 3 -Headers @{ 'User-Agent' = 'project-starter' }).tag_name
        @{ latest = $latest; checked = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $cacheFile -Encoding utf8
    } catch { }
    return $latest
}

function global:Show-StarterUpdateNotice {
    $latest = Get-StarterUpdateNoticeState
    if (-not $latest) { return }
    try {
        $latestVersion = [version]$latest.TrimStart('v')
        $currentVersion = [version]$script:StarterVersion
        if ($latestVersion -gt $currentVersion) {
            Write-Host ("update available: {0} (installed v{1}) - rerun the install one-liner from the README" -f $latest, $script:StarterVersion)
        }
    } catch { }
}

function global:Get-ProjectAgent {
    param([string]$Dir)

    # 1) our own metadata records exactly what ran here last
    $meta = Join-Path $Dir '.ps-project.json'
    if (Test-Path -LiteralPath $meta) {
        try {
            $m = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
            if ($m.agent -and $script:AgentProfiles.ContainsKey($m.agent) -and
                (Get-Command $m.agent -CommandType Application -ErrorAction SilentlyContinue)) {
                return $m.agent
            }
        } catch { }   # corrupt metadata -> fall through to probes
    }

    # 2) foreign-agent fingerprints
    if (((Test-Path -LiteralPath (Join-Path $Dir '.claude')) -or
         (Test-Path -LiteralPath (Join-Path $Dir 'CLAUDE.md'))) -and
        (@(Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)).Count -gt 0) { return 'claude' }
    if ((Test-Path -LiteralPath (Join-Path $Dir '.codex')) -and
        (@(Get-Command codex -CommandType Application -ErrorAction SilentlyContinue)).Count -gt 0) { return 'codex' }
    if ((Test-Path -LiteralPath (Join-Path $Dir '.gemini')) -and
        (@(Get-Command gemini -CommandType Application -ErrorAction SilentlyContinue)).Count -gt 0) { return 'gemini' }

    # 3) omp keeps sessions outside the project, bucketed by cwd hash
    $leaf = Split-Path -Path $Dir -Leaf
    $buckets = Join-Path $env:USERPROFILE '.omp\agent\sessions'
    if (Test-Path -LiteralPath $buckets) {
        $found = Get-ChildItem -LiteralPath $buckets -Directory -Filter "*-$leaf-*" -ErrorAction SilentlyContinue |
                 Where-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.jsonl' -ErrorAction SilentlyContinue } |
                 Select-Object -First 1
        if ($found) { return 'omp' }
    }
    'omp'
}

function global:Write-ProjectMeta {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Dir, [string]$Agent, [string]$Intent)
    $path = Join-Path $Dir '.ps-project.json'
    $prev = $null
    if (Test-Path -LiteralPath $path) {
        try { $prev = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { }
    }
    if ($PSCmdlet.ShouldProcess($path, 'write project metadata')) {
        @{
            agent   = $Agent
            intent  = if ($Intent) { $Intent } elseif ($prev -and $prev.intent) { $prev.intent } else { $null }
            created = if ($prev -and $prev.created) { $prev.created } else { (Get-Date).ToString('o') }
            updated = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
    }
}

function global:Select-StarterProject {
    param([string]$Root)
    $dirs = @()
    if (Test-Path -LiteralPath $Root) {
        $dirs = @(Get-ChildItem -LiteralPath $Root -Directory | Sort-Object LastWriteTime -Descending)
    }
    if ($dirs.Count -eq 0) {
        Write-Host "no projects under $Root yet."
        Write-Host 'usage: start <name> [initial prompt...]'
        return $null
    }

    # line format: "<name>  |  <intent>"; picking parses the name before the pipe
    $lines = foreach ($d in $dirs) {
        $intent = $null
        $metaPath = Join-Path $d.FullName '.ps-project.json'
        if (Test-Path -LiteralPath $metaPath) {
            try { $intent = (Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json).intent } catch { }
        }
        $shown = $intent
        if ($shown -and $shown.Length -gt 48) { $shown = $shown.Substring(0, 45) + '...' }
        '{0}  |  {1}' -f $d.Name, $shown
    }

    if ((@(Get-Command fzf -CommandType Application -ErrorAction SilentlyContinue)).Count -gt 0) {
        $picked = $lines | fzf --height 40% --reverse
        if ($LASTEXITCODE -eq 0 -and $picked) { return (($picked -split '\|')[0]).Trim() }
        return $null
    }

    for ($i = 0; $i -lt $dirs.Count; $i++) {
        ('{0,3}. {1}' -f ($i + 1), $lines[$i]) | Write-Host
    }
    $answer = Read-Host 'project number (blank cancels)'
    if ($answer -match '^\d+$') {
        $n = [int]$answer
        if ($n -ge 1 -and $n -le $dirs.Count) {
            return (($lines[$n - 1] -split '\|')[0]).Trim()
        }
    }
    $null
}

function global:Select-StarterAgent {
    param([string[]]$Candidates)
    if ($Candidates.Count -eq 0) { return 'omp' }
    if ((@(Get-Command fzf -CommandType Application -ErrorAction SilentlyContinue)).Count -gt 0) {
        $picked = @($Candidates | Sort-Object) | fzf --height 30% --reverse --prompt 'agent> '
        if ($LASTEXITCODE -eq 0 -and $picked -and $script:AgentProfiles.ContainsKey($picked.Trim())) {
            return $picked.Trim()
        }
        return $null
    }
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        ('{0,3}. {1}' -f ($i + 1), $Candidates[$i]) | Write-Host
    }
    $answer = Read-Host 'agent number (blank = omp)'
    if ($answer -match '^\d+$') {
        $n = [int]$answer
        if ($n -ge 1 -and $n -le $Candidates.Count) { return $Candidates[$n - 1] }
    }
    $null
}

function global:start {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
        [string[]]$Prompt,
        [switch]$Yolo,
        [switch]$Here,
        [switch]$FromLauncher,
        [string]$Agent,
        [string]$SetDefaultAgent,
        [switch]$Doctor,
        [switch]$Version
    )

    # --- management modes ------------------------------------------------
    if ($Version) {
        Write-Output ("project-starter v{0}" -f $script:StarterVersion)
        return
    }
    if ($PSBoundParameters.ContainsKey('SetDefaultAgent')) {
        Set-StarterDefaultAgent -Agent $SetDefaultAgent
        return
    }
    if ($Doctor) {
        Write-Host ("== project-starter doctor (v{0}) ==" -f $script:StarterVersion)
        foreach ($tool in @('git', 'wt', 'fzf', 'pwsh', 'powershell')) {
            $c = @(Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($c) { Write-Host ("[ok] {0,-11} {1}" -f $tool, $c.Source) }
            else { Write-Host ("[--] {0,-11} not found" -f $tool) }
        }
        $verbs = @('resume', 'resume-pick', 'mode:yolo', 'mode:plan', 'model')
        Write-Host ('{0,-9} {1}' -f 'agent', ($verbs -join '  '))
        foreach ($a in ($script:AgentProfiles.Keys | Sort-Object)) {
            $exe = @(Get-Command $a -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
            $cells = foreach ($v in $verbs) {
                if ($script:AgentProfiles[$a].Caps.ContainsKey($v)) { ' yes' } else { '  - ' }
            }
            $tag = if ($exe) { 'ok' } else { '--' }
            Write-Host ("[{0}] {1,-9} {2}" -f $tag, $a, ($cells -join ' '))
        }
        $hooks = @(Get-StarterPostCreateHook)
        Write-Host ("[--] post-create hooks configured: {0}" -f $hooks.Count)
        try { $rootNow = Get-StarterProjectsRoot } catch { $rootNow = '<invalid>' }
        $writable = $false
        try {
            $probe = Join-Path $rootNow '.doctor-probe'
            New-Item -ItemType File -Path $probe -Force | Out-Null
            Remove-Item -LiteralPath $probe -Force
            $writable = $true
        } catch { }
        Write-Host ("[{0}] projects root {1} (writable={2})" -f ($(if ($writable) { 'ok' } else { '!!' })), $rootNow, $writable)
        $def = Get-StarterDefaultAgent
        Write-Host ("[--] default agent: {0}" -f ($(if ($def) { $def } else { '<unset - picker decides on new projects>' })))
        $ar = (Get-ItemProperty 'HKCU:\Software\Microsoft\Command Processor' -Name AutoRun -ErrorAction SilentlyContinue).AutoRun
        Write-Host ("[{0}] cmd AutoRun hook" -f ($(if ($ar -match 'project-starter') { 'ok' } else { '--' })))
        foreach ($rcf in @('$HOME\.bashrc', '$HOME\.zshrc')) {
            $rp = $ExecutionContext.InvokeCommand.ExpandString($rcf)
            $hit = (Test-Path -LiteralPath $rp) -and (Get-Content -LiteralPath $rp -ErrorAction SilentlyContinue | Where-Object { $_ -match 'project-starter' })
            Write-Host ("[{0}] {1}" -f ($(if ($hit) { 'ok' } else { '--' })), $rp)
        }
        return
    }

    $yoloWanted = [bool]$Yolo

    if ($FromLauncher) {
        # relaunched inside the new tab; state travels via inherited env vars
        $Name             = $env:OMP_START_NAME
        $raw              = $env:OMP_START_PROMPT
        $Prompt           = if ($raw) { @($raw -split '\s+' | Where-Object { $_ }) } else { $null }
        $yoloWanted       = ($env:OMP_START_YOLO -eq '1')
        $launcherAgent    = $env:OMP_START_AGENT
        $launcherFresh    = ($env:OMP_START_FRESH -eq '1')
        $launcherVerbJson = $env:OMP_START_VERBS
        Remove-Item Env:OMP_START_NAME, Env:OMP_START_PROMPT, Env:OMP_START_YOLO, Env:OMP_START_AGENT, Env:OMP_START_FRESH, Env:OMP_START_VERBS -ErrorAction SilentlyContinue
    } else {
        Show-StarterUpdateNotice
    }

    # --- extract known capability verbs from anywhere in the prompt -------
    $verbs = New-Object System.Collections.Generic.List[object]
    $kept  = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Prompt.Count) {
        $t = $Prompt[$i]
        if ($t -like ':*') {
            $v = $t.TrimStart(':').Trim()
            if ($script:KnownVerbs -contains $v) {
                if ($v -eq 'model') {
                    if ($i + 1 -ge $Prompt.Count) { Write-Error ':model requires a value (e.g. :model opus)'; return }
                    $i++
                    $verbs.Add([pscustomobject]@{ Name = 'model'; Value = $Prompt[$i] })
                    $i++
                    continue
                }
                $verbs.Add([pscustomobject]@{ Name = $v })
                $i++
                continue
            }
        }
        $kept.Add($t)
        $i++
    }
    $Prompt = @($kept)
    if ($launcherVerbJson) {
        try {
            $restoredVerbPayload = $launcherVerbJson | ConvertFrom-Json
            foreach ($launcherVerb in @($restoredVerbPayload.Verbs)) {
                if ($launcherVerb) { $verbs.Add($launcherVerb) }
            }
        } catch {
            Write-Warning "could not restore launcher capabilities: $_"
        }
    }
    if ($yoloWanted -and -not ($verbs | Where-Object { $_.Name -eq 'yolo' })) {
        $verbs.Insert(0, [pscustomobject]@{ Name = 'yolo' })
    }

    try {
        $rootFull = Get-StarterProjectsRoot
    } catch {
        Write-Error "projects root is invalid: $_"
        return
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = Select-StarterProject -Root $rootFull
        if (-not $Name) { return }
    }

    if (-not (Test-Path -LiteralPath $rootFull)) {
        New-Item -ItemType Directory -Path $rootFull -Force | Out-Null
    }

    # allow nested names (foo/bar) but never absolute paths or root escapes
    if ($Name -match '^[A-Za-z]:' -or $Name.StartsWith('\')) {
        Write-Error "'$Name' must be relative to the projects root ($rootFull)"
        return
    }
    $dir = [System.IO.Path]::GetFullPath((Join-Path $rootFull $Name))
    if (-not $dir.StartsWith($rootFull.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "'$Name' escapes the projects root ($rootFull)"
        return
    }

    $isNew = -not (Test-Path -LiteralPath $dir)
    # The parent creates the directory before launching a tab. Preserve whether
    # this is the project's first session independently from filesystem existence.
    $freshSession = $isNew -or ($FromLauncher -and $launcherFresh)
    if ($isNew) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "created $dir"

        # seed cross-harness instruction scaffolding (AGENTS.md standard)
        $leafName = Split-Path -Path $dir -Leaf
        $agentsMd = Join-Path $dir 'AGENTS.md'
        $claudeMd = Join-Path $dir 'CLAUDE.md'
        $geminiMd = Join-Path $dir 'GEMINI.md'
        if (-not (Test-Path -LiteralPath $agentsMd)) {
            $tpl = @(
                ('# ' + $leafName),
                '',
                '## Overview',
                '',
                'Describe the project here.',
                '',
                '## Build & Test',
                '',
                '- Build:',
                '- Test:',
                '',
                '## Code Style',
                '',
                '-',
                '',
                '## Security Notes',
                '',
                '-'
            )
            Set-Content -LiteralPath $agentsMd -Value $tpl -Encoding utf8
        }
        if (-not (Test-Path -LiteralPath $claudeMd)) {
            Set-Content -LiteralPath $claudeMd -Value '@AGENTS.md' -Encoding utf8
        }
        if (-not (Test-Path -LiteralPath $geminiMd)) {
            Set-Content -LiteralPath $geminiMd -Value 'Instructions live in AGENTS.md.' -Encoding utf8
        }
    }

    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Error 'git not found in PATH'
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
        git -C $dir init -b main
        if ($LASTEXITCODE -ne 0) { git -C $dir init }   # pre-2.28 fallback
        if ($LASTEXITCODE -ne 0) { Write-Error 'git init failed'; return }
        Write-Host 'initialized git repo'
    }

    # --- agent resolution -------------------------------------------------
    if (-not $freshSession) {
        $agent = Get-ProjectAgent -Dir $dir
    } else {
        $installed = @($script:AgentProfiles.Keys | Where-Object {
            @(Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue).Count -gt 0
        } | Sort-Object)
        if ($Agent) {
            if (-not $script:AgentProfiles.ContainsKey($Agent)) {
                Write-Error "unknown agent '$Agent' (known: $($script:AgentProfiles.Keys -join ', '))"
                return
            }
            if (($installed | Where-Object { $_ -eq $Agent }).Count -eq 0) {
                Write-Warning "'$Agent' is registered but not found on PATH; launching anyway"
            }
            $agent = $Agent
        }
        elseif ($FromLauncher -and $launcherAgent) { $agent = $launcherAgent }
        else {
            $def = Get-StarterDefaultAgent
            if ($def -and ($installed | Where-Object { $_ -eq $def })) {
                $agent = $def
                Write-Host "using default agent '$def' (change: start -SetDefaultAgent <name>|none)"
            }
            elseif ($installed.Count -eq 1) { $agent = $installed[0] }
            elseif ($installed.Count -gt 1) {
                $agent = Select-StarterAgent -Candidates $installed
                if (-not $agent) { $agent = 'omp' }
                Write-Host "selected agent: $agent (make permanent: start -SetDefaultAgent $agent)"
            }
            else {
                $agent = 'omp'
                Write-Warning 'no registered agents found on PATH; defaulting to omp'
            }
        }
    }
    Write-ProjectMeta -Dir $dir -Agent $agent -Intent $(if ($Prompt) { $Prompt -join ' ' } else { $null })


    # default: hand off to a fresh Windows Terminal tab
    $wt = @(Get-Command wt -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $FromLauncher -and -not $Here -and $wt) {
        $env:OMP_START_NAME   = $Name
        $env:OMP_START_PROMPT = if ($Prompt) { $Prompt -join ' ' } else { '' }
        $env:OMP_START_YOLO   = if ($yoloWanted) { '1' } else { '' }
        $env:OMP_START_AGENT  = $agent
        $env:OMP_START_FRESH  = if ($isNew) { '1' } else { '' }
        $verbPayload = @()
        foreach ($verbItem in $verbs) { $verbPayload += $verbItem }
        $env:OMP_START_VERBS = ConvertTo-Json -InputObject @{ Verbs = $verbPayload } -Depth 4 -Compress
        $sh = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
        $shellExe = if ($sh) { $sh.Source } else { Join-Path $PSHOME 'powershell.exe' }
        $launcher = Join-Path $script:StarterRoot 'Start-InTab.ps1'
        & $wt.Source -w 0 new-tab --title (Split-Path -Path $dir -Leaf) -d $dir $shellExe -NoProfile -ExecutionPolicy Bypass -File $launcher
        if ($LASTEXITCODE -eq 0) {
            Write-Host "-> $(Split-Path -Path $dir -Leaf) opened in a new terminal tab"
            return
        }
        Write-Warning "wt exited with $($LASTEXITCODE); launching inline instead"
        Remove-Item Env:OMP_START_NAME, Env:OMP_START_PROMPT, Env:OMP_START_YOLO, Env:OMP_START_AGENT, Env:OMP_START_FRESH, Env:OMP_START_VERBS -ErrorAction SilentlyContinue
    }

    Set-Location -LiteralPath $dir
    # --- post-create hooks (fresh projects only) ---------------------------
    if ($isNew) {
        foreach ($h in (Get-StarterPostCreateHook)) {
            Write-Host "post-create hook: $h"
            try { Invoke-Expression $h | Out-Null } catch { Write-Warning "post-create hook failed: $_" }
        }
    }

    # --- apply capabilities ------------------------------------------------
    $p        = $script:AgentProfiles[$agent]
    $resuming = -not $freshSession
    $agentArgs = @()

    $wantsPick = @($verbs | Where-Object { $_.Name -in @('pick', 'resume-pick') }).Count -gt 0
    if ($resuming -and -not $wantsPick) {
        $rcap = $p.Caps['resume']
        if ($rcap) { $agentArgs += $rcap.Args }
        elseif ($p.Caps.Count -gt 0) { Write-Warning "$agent declares no resume capability; starting a fresh session" }
    }

    foreach ($v in $verbs) {
        $capKey = switch ($v.Name) {
            'yolo'  { 'mode:yolo' }
            'pick'  { 'resume-pick' }
            default { $v.Name }
        }
        if ($capKey -in @('resume', 'resume-pick') -and -not $resuming) { continue }
        $cap = $p.Caps[$capKey]
        if (-not $cap) {
            Write-Warning "$agent does not support :$($v.Name); skipping"
            continue
        }
        $agentArgs += $cap.Args
        if ($capKey -eq 'model') { $agentArgs += $v.Value }
    }

    if ($Prompt -and $resuming -and (-not $p.TakesPromptOnResume)) {
        Write-Warning "dropping prompt ('$($Prompt -join ' ')): cannot combine with $agent resume"
    } elseif ($Prompt) {
        $agentArgs += ($Prompt -join ' ')
    }

    $verb = if ($resuming) { 'resuming' } else { 'starting' }
    Write-Host ("{0} {1} with {2} {3}" -f $verb, (Split-Path -Path $dir -Leaf), $agent, ($agentArgs -join ' '))
    & $agent @agentArgs
}

# <Tab> completes project names from the projects root
Register-ArgumentCompleter -CommandName start -ParameterName Name -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    try { $root = Get-StarterProjectsRoot } catch { return }
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Directory -Filter "$wordToComplete*" -ErrorAction SilentlyContinue |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_.Name) }
    }
}
