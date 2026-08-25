# project-starter: the `start` command for PowerShell.
#
#   start                       pick an existing project (fzf if installed, else numbered list;
#                               shows saved intent + last-active time)
#   start <name> [words...]     create <root>\<name> + git repo, launch agent in a NEW TAB;
#                               extra words become the agent's initial prompt AND are saved
#                               as the project's intent
#   start <name> ... -Yolo      appends the agent's auto-approval flag (opt-in per run)
#
#   Reopening an existing project auto-resumes with the agent that last ran there:
#   recorded in <project>\.ps-project.json ({agent,intent,created,updated}), falling
#   back to .claude/.codex/.gemini fingerprints and omp's own session buckets.
#
#   AGENT REGISTRY: built-ins below; an optional agents.json next to this script
#   merges over them. Per-agent keys:
#     continueArgs           argv used to resume (array)
#     takesPromptOnContinue  whether extra words may ride along on resume (bool)
#     yoloFlags              argv appended by -Yolo (array)
#   Example agents.json:
#     { "aider": { "continueArgs": ["--resume","--last"],
#                  "takesPromptOnContinue": false,
#                  "yoloFlags": ["--yes-always"] } }
#
#   -Here   launch inline instead of a new tab.  Root: $env:OMP_PROJECTS_DIR (default C:\projects)

if (Get-Command start -CommandType Alias -ErrorAction SilentlyContinue) {
    Remove-Item Alias:start -Force -ErrorAction SilentlyContinue
}

$script:StarterRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function global:Get-StarterAgents {
    $table = @{
        omp    = @{ ContinueArgs = @('-c');               TakesPromptOnContinue = $true;  YoloFlags = @('--approval-mode', 'yolo') }
        claude = @{ ContinueArgs = @('-c');               TakesPromptOnContinue = $true;  YoloFlags = @('--dangerously-skip-permissions') }
        codex  = @{ ContinueArgs = @('resume', '--last'); TakesPromptOnContinue = $false; YoloFlags = @('--full-auto') }
        gemini = @{ ContinueArgs = @();                   TakesPromptOnContinue = $true;  YoloFlags = @('--yolo') }
    }
    $registry = Join-Path $script:StarterRoot 'agents.json'
    if (Test-Path -LiteralPath $registry) {
        try {
            $custom = Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json
            foreach ($prop in $custom.PSObject.Properties) {
                $e = $prop.Value
                $table[$prop.Name] = @{
                    ContinueArgs          = @(@($e.continueArgs) | Where-Object { $_ })
                    TakesPromptOnContinue = if ($null -ne $e.takesPromptOnContinue) { [bool]$e.takesPromptOnContinue } else { $true }
                    YoloFlags             = @(@($e.yoloFlags) | Where-Object { $_ })
                }
            }
        } catch {
            Write-Warning "agents.json ignored (invalid JSON): $_"
        }
    }
    $table
}

$script:AgentProfiles = Get-StarterAgents

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
    param([string]$Dir, [string]$Agent, [string]$Intent)
    $path = Join-Path $Dir '.ps-project.json'
    $prev = $null
    if (Test-Path -LiteralPath $path) {
        try { $prev = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { }
    }
    @{
        agent   = $Agent
        intent  = if ($Intent) { $Intent } elseif ($prev -and $prev.intent) { $prev.intent } else { $null }
        created = if ($prev -and $prev.created) { $prev.created } else { (Get-Date).ToString('o') }
        updated = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
}

function script:Limit-StarterText {
    param([string]$Text, [int]$Max)
    if ($Text -and $Text.Length -gt $Max) { $Text.Substring(0, $Max - 3) + '...' } else { $Text }
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
        '{0}  |  {1}' -f $d.Name, (Limit-StarterText $intent 48)
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

function global:start {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name,
        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
        [string[]]$Prompt,
        [switch]$Yolo,
        [switch]$Here,
        [switch]$FromLauncher
    )

    $yoloWanted = [bool]$Yolo

    if ($FromLauncher) {
        # relaunched inside the new tab; state travels via inherited env vars
        $Name       = $env:OMP_START_NAME
        $raw        = $env:OMP_START_PROMPT
        $Prompt     = if ($raw) { @($raw -split '\s+' | Where-Object { $_ }) } else { $null }
        $yoloWanted = ($env:OMP_START_YOLO -eq '1')
        Remove-Item Env:OMP_START_NAME, Env:OMP_START_PROMPT, Env:OMP_START_YOLO -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $rootGuess = if ($env:OMP_PROJECTS_DIR) { $env:OMP_PROJECTS_DIR } else { 'C:\projects' }
        $Name = Select-StarterProject -Root $rootGuess
        if (-not $Name) { return }
    }

    $root = if ($env:OMP_PROJECTS_DIR) { $env:OMP_PROJECTS_DIR } else { 'C:\projects' }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($root)
    } catch {
        Write-Error "OMP_PROJECTS_DIR '$root' is not a valid path"
        return
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
    if ($isNew) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "created $dir"
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

    $agent = if ($isNew) { 'omp' } else { Get-ProjectAgent -Dir $dir }
    $intentWords = if ($Prompt) { $Prompt -join ' ' } else { $null }
    Write-ProjectMeta -Dir $dir -Agent $agent -Intent $intentWords

    # default: hand off to a fresh Windows Terminal tab
    $wt = @(Get-Command wt -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $FromLauncher -and -not $Here -and $wt) {
        $env:OMP_START_NAME   = $Name
        $env:OMP_START_PROMPT = if ($Prompt) { $Prompt -join ' ' } else { '' }
        $env:OMP_START_YOLO   = if ($yoloWanted) { '1' } else { '' }
        $sh = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
        $shellExe = if ($sh) { $sh.Source } else { Join-Path $PSHOME 'powershell.exe' }
        $launcher = Join-Path $script:StarterRoot 'Start-InTab.ps1'
        & $wt.Source nt --title (Split-Path -Path $dir -Leaf) -d $dir $shellExe -NoProfile -ExecutionPolicy Bypass -File $launcher
        if ($LASTEXITCODE -eq 0) {
            Write-Host "-> $(Split-Path -Path $dir -Leaf) opened in a new terminal tab"
            return
        }
        Write-Warning "wt exited with $($LASTEXITCODE); launching inline instead"
        Remove-Item Env:OMP_START_NAME, Env:OMP_START_PROMPT, Env:OMP_START_YOLO -ErrorAction SilentlyContinue
    }

    Set-Location -LiteralPath $dir

    $p        = $script:AgentProfiles[$agent]
    $resuming = -not $isNew
    $agentArgs = @()
    if ($resuming) { $agentArgs += $p.ContinueArgs }
    if ($yoloWanted) {
        if ($p.YoloFlags.Count -gt 0) { $agentArgs += $p.YoloFlags }
        else { Write-Warning "$agent has no yoloFlags registered; running with normal approvals" }
    }
    if ($Prompt -and $resuming -and -not $p.TakesPromptOnContinue) {
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
    $root = if ($env:OMP_PROJECTS_DIR) { $env:OMP_PROJECTS_DIR } else { 'C:\projects' }
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Directory -Filter "$wordToComplete*" -ErrorAction SilentlyContinue |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_.Name) }
    }
}
