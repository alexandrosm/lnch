# Engine verification matrix for lnch.
# Runs the `lnch` function against stub agents; touches only a temp dir
# plus a redirected config dir. Works on Windows PowerShell 5.1 and pwsh 7+.
$ErrorActionPreference = 'Stop'

$LnchDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StubBin    = Join-Path $PSScriptRoot 'stubs'
$TestRoot   = Join-Path ([IO.Path]::GetTempPath()) ('ps-startertest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Projects   = Join-Path $TestRoot 'projects'
New-Item -ItemType Directory -Path $Projects -Force | Out-Null

# self-healing PATH: sandbox environments strip System32/Git unpredictably
$sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
$gitCmd  = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\cmd' } else { 'C:\Program Files\Git\cmd' }
$env:PATH = "$StubBin;$gitCmd;$sysRoot\System32;$sysRoot\System32\WindowsPowerShell\v1.0;$env:PATH"

$env:LNCH_PROJECTS_DIR = $Projects

$env:LNCH_NO_UPDATE_CHECK = '1'
# redirected user-config so persisted-default/hook tests never touch real %APPDATA%
$env:LNCH_CONFIG_DIR = Join-Path $TestRoot 'config'
New-Item -ItemType Directory -Force -Path $env:LNCH_CONFIG_DIR | Out-Null

# registry fixture (v2 caps shape): back up any real agents.json first
$registryPath = Join-Path $LnchDir 'agents.json'
$backup = if (Test-Path -LiteralPath $registryPath) { Get-Content -LiteralPath $registryPath -Raw } else { $null }
@'
{
  "omp":   { "caps": { "resume": {"args":["-c"]}, "resume-pick": {"args":["-r"]}, "mode:yolo": {"args":["--approval-mode","yolo"]}, "model": {"args":["--model"]} }, "takesPromptOnResume": true },
  "aider": { "caps": { "resume": {"args":["--resume","--last"]}, "mode:yolo": {"args":["--yes-always"]} }, "takesPromptOnResume": false },
  "bare":  { "caps": {} }
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

# deterministic fresh-project agent: seed the default so pickers never fire in A-O
@{ defaultAgent = 'omp' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:LNCH_CONFIG_DIR 'config.json') -Encoding utf8

$script:fail = 0
function Check($label, $cond) {
    if ($cond) { Write-Host "PASS $label" } else { $script:fail++; Write-Host "FAIL $label" }
}
function Meta([string]$p) { Get-Content -LiteralPath (Join-Path $Projects "$p\.lnch.json") -Raw }

try {
    . (Join-Path $LnchDir 'Lnch.ps1')
    $__lnchFn = ${function:lnch}
    if (-not $__lnchFn) { throw 'lnch function failed to load' }

    Write-Host '=== A: fresh, prompt, metadata, scaffold ==='
    $out = & $__lnchFn alpha hello world -Here
    Check 'A git'          (Test-Path (Join-Path $Projects 'alpha\.git'))
    Check 'A prompt'       (($out -join ' ') -match '\[omp-stub\] args="hello world"')
    Check 'A agents-md'    (Test-Path (Join-Path $Projects 'alpha\AGENTS.md'))
    Check 'A claude-ptr'   ((Get-Content (Join-Path $Projects 'alpha\CLAUDE.md') -Raw) -match '@AGENTS.md')
    $m = Meta 'alpha'
    Check 'A meta agent'   ($m -match '"agent":\s*"omp"')
    Check 'A meta intent'  ($m -match 'hello world')

    Write-Host '=== B: resume omp -c ==='
    $out = & $__lnchFn alpha -Here
    Check 'B continue'     (($out -join ' ') -match '\[omp-stub\] args=-c ')

    Write-Host '=== C: claude fingerprint ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'beta\.claude') -Force | Out-Null
    $out = & $__lnchFn beta -Here
    Check 'C claude'       (($out -join ' ') -match '\[claude-stub\] args=-c')

    Write-Host '=== D: codex drops prompt on resume ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'gamma\.codex') -Force | Out-Null
    $out = & $__lnchFn gamma some prompt -Here
    $j = $out -join ' '
    Check 'D resume last'  ($j -match '\[codex-stub\] args=resume --last')
    Check 'D no prompt'    (!($j -match 'some prompt'))

    Write-Host '=== E: theta intent; bare lnch -> fzf line -> resumed ==='
    $out = & $__lnchFn theta build a snake game -Here
    Check 'E fresh theta'  (($out -join ' ') -match '\[omp-stub\] args="build a snake game"')
    $out = & $__lnchFn -Here
    Check 'E picked theta' (($out -join ' ') -match '\[omp-stub\] args=-c ')
    Check 'E intent saved' ((Meta 'theta') -match 'build a snake game')

    Write-Host '=== E2: multi-project picker launches every selection ==='
    $env:LNCH_TEST_FZF_MULTI = '1'
    $out = & $__lnchFn
    Remove-Item Env:LNCH_TEST_FZF_MULTI -ErrorAction SilentlyContinue
    $j = $out -join ' '
    Check 'E2 theta tab' ($j -match 'WT-STUB -w 0 new-tab --title theta ')
    Check 'E2 alpha tab' ($j -match 'WT-STUB -w 0 new-tab --title alpha ')
    Check 'E2 exactly two' ([regex]::Matches($j, 'WT-STUB').Count -eq 2)
    Remove-Item Env:LNCH_NAME, Env:LNCH_PROMPT, Env:LNCH_YOLO, Env:LNCH_AGENT, Env:LNCH_FRESH, Env:LNCH_VERBS -ErrorAction SilentlyContinue

    Write-Host '=== E3: numbered multi-range parser ==='
    $indexes = @(ConvertFrom-LnchProjectSelection -Selection '1,3-4' -Count 5)
    Check 'E3 range' (($indexes -join ',') -eq '1,3,4')
    Check 'E3 all' ((@(ConvertFrom-LnchProjectSelection -Selection 'all' -Count 4) -join ',') -eq '1,2,3,4')

    Write-Host '=== F: new-tab handoff env contract ==='
    $out = & $__lnchFn epsilon hi there
    $j = $out -join ' '
    Check 'F sticky project title' ($j -match 'WT-STUB -w 0 new-tab --title epsilon --suppressApplicationTitle .*Lnch-InTab\.ps1')
    Check 'F name'            ($env:LNCH_NAME -eq 'epsilon')
    Check 'F prompt'          ($env:LNCH_PROMPT -eq 'hi there')
    Check 'F fresh env'       ($env:LNCH_FRESH -eq '1')
    Check 'F verbs env'       ($env:LNCH_VERBS -match '"Verbs":\[\]')
    Check 'F agent env'       ($env:LNCH_AGENT -eq 'omp')
    $out = & $__lnchFn -FromLauncher
    $j = $out -join ' '
    Check 'F launcher fresh prompt' (($j -match '\[omp-stub\] args="hi there"') -and -not ($j -match 'args=-c'))
    Check 'F env cleared' ((-not $env:LNCH_NAME) -and (-not $env:LNCH_FRESH) -and (-not $env:LNCH_VERBS))

    Write-Host '=== F2: existing project handoff resumes ==='
    $out = & $__lnchFn alpha
    Check 'F2 not fresh' (-not $env:LNCH_FRESH)
    $out = & $__lnchFn -FromLauncher
    Check 'F2 resumes' (($out -join ' ') -match '\[omp-stub\] args=-c\b')

    Write-Host '=== G: root escape rejected ==='
    try { & $__lnchFn ..\evil -Here; Check 'G reject' $false } catch { Check 'G reject' $true }

    Write-Host '=== H: registry agent via legacy marker ==='
    New-Item -ItemType Directory -Path (Join-Path $Projects 'beta2') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Projects 'beta2\.lnch.json') -Value '{"agent":"aider","updated":"2026-01-01T00:00:00.0000000Z"}'
    $out = & $__lnchFn beta2 -Here
    Check 'H aider resume' (($out -join ' ') -match '\[aider-stub\] args=--resume --last')

    Write-Host '=== I/J: -Yolo maps to mode:yolo cap ==='
    $out = & $__lnchFn iota hi -yolo -Here
    Check 'I omp yolo+prompt' (($out -join ' ') -match '\[omp-stub\] args=--approval-mode yolo hi')
    New-Item -ItemType Directory -Path (Join-Path $Projects 'jay') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Projects 'jay\.lnch.json') -Value '{"agent":"bare","updated":"2026-01-01T00:00:00.0000000Z"}'
    $out = & $__lnchFn jay p -yolo -Here
    Check 'J bare plain'   (($out -join ' ') -match '\[bare-stub\] args=p')

    Write-Host '=== K: yolo rides the tab handoff ==='
    $out = & $__lnchFn kappa go -yolo
    $j = $out -join ' '
    Check 'K handed off'   ($j -match 'WT-STUB -w 0 new-tab --title kappa --suppressApplicationTitle')
    Check 'K env yolo'     ($env:LNCH_YOLO -eq '1')
    Check 'K env agent'    ($env:LNCH_AGENT -eq 'omp')
    Check 'K env fresh'    ($env:LNCH_FRESH -eq '1')
    Check 'K env verbs'    ($env:LNCH_VERBS -match '"Name":"yolo"')
    $out = & $__lnchFn -FromLauncher
    $j = $out -join ' '
    Check 'K fresh+yolo+prompt' (($j -match '\[omp-stub\] args=--approval-mode yolo go') -and -not ($j -match 'args=-c'))
    Check 'K env cleared' ((-not $env:LNCH_NAME) -and (-not $env:LNCH_YOLO) -and (-not $env:LNCH_FRESH) -and (-not $env:LNCH_VERBS))

    Write-Host '=== L: default agent persisted and honored ==='
    & $__lnchFn -SetDefaultAgent claude
    $out = & $__lnchFn zeta3 build a castle -Here
    Check 'L default claude' (($out -join ' ') -match '\[claude-stub\] args="build a castle"')

    Write-Host '=== M: cleared default -> agent picker over installed agents ==='
    & $__lnchFn -SetDefaultAgent ''
    $out = & $__lnchFn eta x -Here
    Check 'M picker aider' (($out -join ' ') -match '\[aider-stub\] args=x')

    Write-Host '=== N: doctor audit incl capability matrix ==='
    $env:LNCH_INSTALL_DIR = $LnchDir
    $out = & powershell.exe -NoProfile -Command '. "$env:LNCH_INSTALL_DIR\Lnch.ps1"; lnch -Doctor' 2>&1
    $j = $out -join ' '
    Check 'N doctor runs'  ($j -match 'lnch doctor')
    Check 'N git ok'       ($j -match '\[ok\] git')
    Check 'N cap matrix'   ($j -match 'resume-pick')
    Check 'N hooks line'   ($j -match 'post-create hooks configured')

    Write-Host '=== O: entry.ps1 --agent passthrough ==='
    $entry = Join-Path $LnchDir 'entry.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry --agent claude kappa2 ship it --here 2>&1
    Check 'O entry agent'  (($out -join ' ') -match '\[claude-stub\] args="ship it"')

    Write-Host '=== P: :pick replaces base resume ==='
    $out = & $__lnchFn alpha :pick -Here 2>&1
    $j = $out -join ' '
    Check 'P pick only'    (($j -match 'args=-r\b') -and (!($j -match 'args=-c\b')))

    Write-Host '=== Q: :model capability verb (fresh) ==='
    $out = & $__lnchFn nu4 :model opus -Agent omp -Here 2>&1
    Check 'Q model opus'   (($out -join ' ') -match '\[omp-stub\] args=--model opus')

    Write-Host '=== R: unsupported capability warns and skips ==='
    $out = & $__lnchFn jay hi :plan -Here 2>&1 3>&1
    $j = $out -join ' '
    Check 'R warns'        ($j -match 'does not support :plan')
    Check 'R no plan args' ((!($j -match '--permission-mode')))

    Write-Host '=== S: v0.3 legacy agents.json auto-migrates ==='
    @'
{
  "aider": { "continueArgs": ["--resume", "--last"], "takesPromptOnContinue": false, "yoloFlags": ["--yes-always"] }
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8
    $reg = Get-LnchAgentRegistry
    Check 'S legacy mapped' ($reg['aider'].Caps['resume'].Args.Count -eq 2 -and $reg['aider'].TakesPromptOnResume -eq $false)


    Write-Host '=== S2: legacy project metadata migrates to .lnch.json ==='
    $legacyDir = Join-Path $Projects 'legacy-meta'
    New-Item -ItemType Directory -Force -Path $legacyDir | Out-Null
    Set-Content -LiteralPath (Join-Path $legacyDir '.ps-project.json') -Value '{"agent":"omp","intent":"legacy metadata"}'
    $out = & $__lnchFn legacy-meta -Here
    Check 'S2 new metadata' (Test-Path (Join-Path $legacyDir '.lnch.json'))
    Check 'S2 old removed' (-not (Test-Path (Join-Path $legacyDir '.ps-project.json')))
    Check 'S2 resume preserved' (($out -join ' ') -match '\[omp-stub\] args=-c\b')
    Write-Host '=== T: post-create hook runs in fresh project ==='
    @'
{ "defaultAgent": "omp", "postCreate": ["Set-Content hooked.txt -Value hooked"] }
'@ | Set-Content -LiteralPath (Join-Path $env:LNCH_CONFIG_DIR 'config.json') -Encoding utf8
    $out = & $__lnchFn wabbit build it -Here 2>&1
    Check 'T hook ran'     (Test-Path (Join-Path $Projects 'wabbit\hooked.txt'))
    Check 'T hook prompt'  (($out -join ' ') -match 'args="build it"')

    Write-Host '=== U: dynamic current-dir root + explicit override ==='
    $originalLocation = Get-Location
    $originalRoot = $env:LNCH_PROJECTS_DIR
    try {
        $caller = Join-Path $TestRoot 'caller'
        New-Item -ItemType Directory -Force -Path $caller | Out-Null
        Set-Location -LiteralPath $caller
        Remove-Item Env:LNCH_PROJECTS_DIR -ErrorAction SilentlyContinue
        $expectedLocalRoot = Join-Path $caller 'projects'
        Check 'U helper current-dir' ((Get-LnchProjectsRoot) -eq [System.IO.Path]::GetFullPath($expectedLocalRoot))
        $out = & $__lnchFn localroot hi -Agent omp -Here
        Check 'U local project' (Test-Path (Join-Path $expectedLocalRoot 'localroot\.git'))

        $overrideRoot = Join-Path $TestRoot 'explicit-root'
        $env:LNCH_PROJECTS_DIR = $overrideRoot
        $out = & $__lnchFn overridden hi -Agent omp -Here
        Check 'U explicit override' (Test-Path (Join-Path $overrideRoot 'overridden\.git'))
    } finally {
        Set-Location -LiteralPath $originalLocation
        if ($originalRoot) { $env:LNCH_PROJECTS_DIR = $originalRoot }
        else { Remove-Item Env:LNCH_PROJECTS_DIR -ErrorAction SilentlyContinue }
    }

    Write-Host '=== V: Level Zero agent datastore discovery ==='
    $discoveryRoot = Join-Path $TestRoot 'agent-stores'
    $discoveryEnvNames = @(
        'PI_CODING_AGENT_DIR', 'OMP_PROFILE', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME',
        'GEMINI_CLI_HOME', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG',
        'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME',
        'QWEN_HOME', 'QWEN_RUNTIME_DIR'
    )
    $discoveryEnvBefore = @{}
    foreach ($envName in $discoveryEnvNames) {
        $discoveryEnvBefore[$envName] = [Environment]::GetEnvironmentVariable($envName, 'Process')
    }
    try {
        $ompStore = Join-Path $discoveryRoot 'omp-agent'
        $claudeStore = Join-Path $discoveryRoot 'claude-home'
        $codexStore = Join-Path $discoveryRoot 'codex-home'
        $geminiBase = Join-Path $discoveryRoot 'gemini-base'
        $openConfig = Join-Path $discoveryRoot 'opencode-config'
        $openConfigFile = Join-Path $discoveryRoot 'opencode-extra.json'
        $xdgData = Join-Path $discoveryRoot 'xdg-data'
        $xdgCache = Join-Path $discoveryRoot 'xdg-cache'
        $xdgState = Join-Path $discoveryRoot 'xdg-state'
        $qwenStore = Join-Path $discoveryRoot 'qwen-home'
        $qwenRuntime = Join-Path $discoveryRoot 'qwen-runtime'

        foreach ($dir in @(
            $ompStore, $claudeStore, $codexStore, (Join-Path $geminiBase '.gemini'),
            $openConfig, (Join-Path $xdgData 'opencode'), (Join-Path $xdgCache 'opencode'),
            (Join-Path $xdgState 'opencode'), $qwenStore, $qwenRuntime
        )) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Set-Content -LiteralPath $openConfigFile -Value '{}'

        [Environment]::SetEnvironmentVariable('PI_CODING_AGENT_DIR', $ompStore, 'Process')
        [Environment]::SetEnvironmentVariable('OMP_PROFILE', $null, 'Process')
        [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $claudeStore, 'Process')
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $codexStore, 'Process')
        [Environment]::SetEnvironmentVariable('GEMINI_CLI_HOME', $geminiBase, 'Process')
        [Environment]::SetEnvironmentVariable('OPENCODE_CONFIG_DIR', $openConfig, 'Process')
        [Environment]::SetEnvironmentVariable('OPENCODE_CONFIG', $openConfigFile, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_DATA_HOME', $xdgData, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_CACHE_HOME', $xdgCache, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_STATE_HOME', $xdgState, 'Process')
        [Environment]::SetEnvironmentVariable('QWEN_HOME', $qwenStore, 'Process')
        [Environment]::SetEnvironmentVariable('QWEN_RUNTIME_DIR', $qwenRuntime, 'Process')

        $inventory = @(Get-LnchAgentDatastores)
        Check 'V seven agents' ($inventory.Count -eq 7)
        Check 'V exact builtins' ((@($inventory.Agent | Sort-Object) -join ',') -eq 'aider,claude,codex,gemini,omp,opencode,qwen')

        $ompInventory = $inventory | Where-Object Agent -eq 'omp'
        $claudeInventory = $inventory | Where-Object Agent -eq 'claude'
        $codexInventory = $inventory | Where-Object Agent -eq 'codex'
        $geminiInventory = $inventory | Where-Object Agent -eq 'gemini'
        $openInventory = $inventory | Where-Object Agent -eq 'opencode'
        $qwenInventory = $inventory | Where-Object Agent -eq 'qwen'

        Check 'V omp env root' (@($ompInventory.Datastores | Where-Object { $_.Source -eq 'PI_CODING_AGENT_DIR' -and $_.Path -eq $ompStore -and $_.Readable }).Count -eq 1)
        Check 'V claude env root' (@($claudeInventory.Datastores | Where-Object { $_.Source -eq 'CLAUDE_CONFIG_DIR' -and $_.Path -eq $claudeStore -and $_.Readable }).Count -eq 1)
        Check 'V codex env root' (@($codexInventory.Datastores | Where-Object { $_.Source -eq 'CODEX_HOME' -and $_.Path -eq $codexStore -and $_.Readable }).Count -eq 1)
        Check 'V gemini env root' (@($geminiInventory.Datastores | Where-Object { $_.Source -eq 'GEMINI_CLI_HOME' -and $_.Path -eq (Join-Path $geminiBase '.gemini') -and $_.Readable }).Count -eq 1)
        Check 'V opencode data root' (@($openInventory.Datastores | Where-Object { $_.Source -eq 'XDG_DATA_HOME' -and $_.Path -eq (Join-Path $xdgData 'opencode') -and $_.Readable }).Count -eq 1)
        Check 'V opencode config file' (@($openInventory.Datastores | Where-Object { $_.Source -eq 'OPENCODE_CONFIG' -and $_.Path -eq $openConfigFile -and $_.PathType -eq 'file' }).Count -eq 1)
        Check 'V qwen split roots' (
            @($qwenInventory.Datastores | Where-Object { $_.Source -eq 'QWEN_HOME' -and $_.Path -eq $qwenStore }).Count -eq 1 -and
            @($qwenInventory.Datastores | Where-Object { $_.Source -eq 'QWEN_RUNTIME_DIR' -and $_.Path -eq $qwenRuntime }).Count -eq 1
        )

        $jsonOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $LnchDir 'entry.ps1') --discover --json 2>&1
        $jsonDocument = $null
        try { $jsonDocument = (($jsonOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json } catch { }
        Check 'V entry JSON schema' ($jsonDocument -and $jsonDocument.Schema -eq 1)
        Check 'V entry JSON agents' ($jsonDocument -and @($jsonDocument.Agents).Count -eq 7)
    } finally {
        foreach ($envName in $discoveryEnvNames) {
            [Environment]::SetEnvironmentVariable($envName, $discoveryEnvBefore[$envName], 'Process')
        }
    }
} finally {
    if ($null -ne $backup) { Set-Content -LiteralPath $registryPath -Value $backup -Encoding utf8 }
    else { Remove-Item -LiteralPath $registryPath -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:LNCH_PROJECTS_DIR, Env:LNCH_CONFIG_DIR, Env:LNCH_NAME, Env:LNCH_PROMPT, Env:LNCH_YOLO, Env:LNCH_AGENT, Env:LNCH_FRESH, Env:LNCH_VERBS, Env:LNCH_INSTALL_DIR, Env:LNCH_NO_UPDATE_CHECK, Env:LNCH_TEST_FZF_MULTI -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
}

if ($script:fail -eq 0) {
    Write-Host 'RESULT: ALL PASS'
} else {
    Write-Host "RESULT: $script:fail FAILED"
    exit 1
}
