# Windows Terminal adapter contract tests. All state is temporary.
$ErrorActionPreference = 'Stop'
$LnchRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lnch-terminal-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$configDir = Join-Path $testRoot 'config'
$runtimeDir = Join-Path $testRoot 'runtime'
$bin = Join-Path $testRoot 'bin'
$wtLog = Join-Path $testRoot 'wt.log'
$omega = [char]0x03A9
$middleDot = [char]0x00B7
$titleTemplate = "{project} $middleDot {agent}"
$projectA = Join-Path $testRoot ("project A " + $omega)
$projectB = Join-Path $testRoot 'project B'
$oldPath = $env:PATH
$oldConfig = $env:LNCH_CONFIG_DIR
$oldRuntime = $env:LNCH_RUNTIME_DIR
$oldWtLog = $env:LNCH_WT_LOG
$oldProfile = $env:WT_PROFILE_ID
$script:fail = 0

function Check([string]$Label, [bool]$Condition) {
    if ($Condition) { Write-Host "PASS $Label" } else { $script:fail++; Write-Host "FAIL $Label" }
}

try {
    New-Item -ItemType Directory -Force -Path $configDir, $runtimeDir, $bin, $projectA, $projectB | Out-Null
    @'
@echo off
if defined LNCH_WT_LOG >>"%LNCH_WT_LOG%" echo WT %*
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $bin 'wt.cmd') -Encoding ascii
    @{ defaultAgent = 'omp'; terminal = @{ readinessTimeoutMs = 0; window = 'last'; titleTemplate = $titleTemplate; agentColors = @{ omp = '#123456' } } } |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $configDir 'config.json') -Encoding utf8
    $env:PATH = "$bin;$oldPath"
    $env:LNCH_CONFIG_DIR = $configDir
    $env:LNCH_RUNTIME_DIR = $runtimeDir
    $env:LNCH_WT_LOG = $wtLog
    $env:WT_PROFILE_ID = '{11111111-1111-1111-1111-111111111111}'
    . (Join-Path $LnchRoot 'Lnch.ps1')

    $defaults = Get-LnchTerminalConfig -Agent omp
    Check 'default tab mode' ($defaults.Mode -eq 'tab')
    Check 'default backend auto' ($defaults.Backend -eq 'auto')
    Check 'current profile captured' ($defaults.Profile -eq $env:WT_PROFILE_ID)
    Check 'agent color selected' ($defaults.TabColor -eq '#123456')
    Check 'title template loaded' ($defaults.TitleTemplate -eq $titleTemplate)
    $inlinePolicy = Get-LnchTerminalConfig -Mode inline -Window workbench -Profile default -Agent omp
    Check 'inline mode accepted' ($inlinePolicy.Mode -eq 'inline')
    Check 'custom window accepted' ($inlinePolicy.Window -eq 'workbench')
    Check 'default profile omits override' ($null -eq $inlinePolicy.Profile)
    $agentTermPolicy = Get-LnchTerminalConfig -Backend agentterm -AgentTermPath 'C:\tools\agentterm.exe' -AgentTermHome $testRoot -AgentTermPort 8123 -Agent omp
    Check 'AgentTerm policy accepted' ($agentTermPolicy.Backend -eq 'agentterm' -and $agentTermPolicy.AgentTermPort -eq 8123 -and $agentTermPolicy.AgentTermHome -eq $testRoot)

    $contextA = New-LnchLaunchContext -Name alpha -Directory $projectA -Root $testRoot -Agent omp -Prompt @('hello', 'world') -Verbs @() -Fresh $false -Terminal $defaults
    $contextB = New-LnchLaunchContext -Name beta -Directory $projectB -Root $testRoot -Agent omp -Prompt @() -Verbs @() -Fresh $true -Terminal $defaults
    Check 'unique launch ids' ($contextA.LaunchId -ne $contextB.LaunchId)
    Check 'launch files written' ((Test-Path (Get-LnchLaunchContextPath $contextA.LaunchId)) -and (Test-Path (Get-LnchLaunchContextPath $contextB.LaunchId)))
    $results = @(Invoke-LnchWindowsTerminal -Contexts @($contextA, $contextB))
    $logged = Get-Content -LiteralPath $wtLog -Raw
    Check 'batch accepted' (@($results | Where-Object Accepted).Count -eq 2)
    Check 'WT invocation resolves backend' (@($results | Where-Object { $_.Context.Terminal.Backend -eq 'wt' }).Count -eq 2)
    Check 'one batched wt call' ([regex]::Matches($logged, '^WT ', [System.Text.RegularExpressions.RegexOptions]::Multiline).Count -eq 1)
    Check 'two tab actions' ([regex]::Matches($logged, 'new-tab').Count -eq 2)
    Check 'environment inheritance explicit' ([regex]::Matches($logged, '--inheritEnvironment').Count -eq 2)
    Check 'profile emitted' ($logged -match [regex]::Escape("--profile $($env:WT_PROFILE_ID)"))
    Check 'title rendered' ($contextA.Terminal.Title -eq "alpha $middleDot omp" -and $logged -match '--title')
    Check 'agent tab color emitted' ($logged -match [regex]::Escape('--tabColor #123456'))
    foreach ($context in @($contextA, $contextB)) { Remove-Item -LiteralPath (Get-LnchLaunchContextPath $context.LaunchId) -Force }

    Remove-Item -LiteralPath $wtLog -Force
    $split = Get-LnchTerminalConfig -Mode split-right -Window lnch -Profile PowerShell -TitleTemplate '{project}:{status}' -TabColor '#ABC' -ColorScheme Campbell -ReadinessTimeoutMs 0 -Agent omp
    $splitContext = New-LnchLaunchContext -Name gamma -Directory $projectA -Root $testRoot -Agent omp -Prompt @() -Verbs @() -Fresh $true -Terminal $split
    $null = Invoke-LnchWindowsTerminal -Contexts @($splitContext)
    $logged = Get-Content -LiteralPath $wtLog -Raw
    Check 'named window emitted' ($logged -match '--window lnch')
    Check 'split right emitted' ($logged -match 'split-pane --vertical')
    Check 'custom profile emitted' ($logged -match '--profile PowerShell')
    Check 'custom title rendered' ($logged -match '--title gamma:new')
    Check 'short color emitted' ($logged -match '--tabColor #ABC')
    Check 'color scheme emitted' ($logged -match '--colorScheme Campbell')
    Remove-Item -LiteralPath (Get-LnchLaunchContextPath $splitContext.LaunchId) -Force

    Remove-Item -LiteralPath $wtLog -Force
    $down = Get-LnchTerminalConfig -Mode split-down -Window lnch -ReadinessTimeoutMs 0 -Agent omp
    $downContext = New-LnchLaunchContext -Name delta -Directory $projectA -Root $testRoot -Agent omp -Prompt @() -Verbs @() -Fresh $false -Terminal $down
    $null = Invoke-LnchWindowsTerminal -Contexts @($downContext)
    Check 'split down emitted' ((Get-Content -LiteralPath $wtLog -Raw) -match 'split-pane --horizontal')
    Remove-Item -LiteralPath (Get-LnchLaunchContextPath $downContext.LaunchId) -Force

    Remove-Item -LiteralPath $wtLog -Force
    $newWindow = Get-LnchTerminalConfig -Mode new-window -Window last -ReadinessTimeoutMs 0 -Agent omp
    $newContext = New-LnchLaunchContext -Name epsilon -Directory $projectA -Root $testRoot -Agent omp -Prompt @() -Verbs @() -Fresh $false -Terminal $newWindow
    $null = Invoke-LnchWindowsTerminal -Contexts @($newContext)
    $logged = Get-Content -LiteralPath $wtLog -Raw
    Check 'new window target emitted' ($logged -match '--window new')
    Check 'new window uses tab' ($logged -match 'new-tab')
    Remove-Item -LiteralPath (Get-LnchLaunchContextPath $newContext.LaunchId) -Force

    $projectWindow = Get-LnchTerminalConfig -Mode tab -Window project -ReadinessTimeoutMs 0 -Agent omp
    $projectContext = New-LnchLaunchContext -Name 'my project' -Directory $projectA -Root $testRoot -Agent omp -Prompt @() -Verbs @() -Fresh $false -Terminal $projectWindow
    Check 'project window stable name' ($projectContext.Terminal.Window -match '^lnch-my-project-[0-9a-f]{8}$')
    Remove-Item -LiteralPath (Get-LnchLaunchContextPath $projectContext.LaunchId) -Force

    $timeout = Get-LnchTerminalConfig -Mode tab -Window last -ReadinessTimeoutMs 50 -Agent omp
    $timeoutContext = New-LnchLaunchContext -Name timeout -Directory $projectA -Root $testRoot -Agent omp -Prompt @() -Verbs @() -Fresh $false -Terminal $timeout
    $timeoutResult = @(Invoke-LnchWindowsTerminal -Contexts @($timeoutContext))[0]
    Check 'readiness timeout detected' ($timeoutResult.Accepted -and -not $timeoutResult.Ready -and $timeoutResult.Error -eq 'child readiness timeout')
    Remove-Item -LiteralPath (Get-LnchLaunchContextPath $timeoutContext.LaunchId) -Force

    $receiptContext = New-LnchLaunchContext -Name receipt -Directory $projectA -Root $testRoot -Agent omp -Prompt @() -Verbs @() -Fresh $false -Terminal $defaults
    $null = Write-LnchTerminalReceipt -Context $receiptContext -State child-started
    $live = Get-LnchTerminalSessions | Where-Object LaunchId -eq $receiptContext.LaunchId
    Check 'live receipt visible' ($live.Active -and $live.State -eq 'child-started')
    $null = Write-LnchTerminalReceipt -Context $receiptContext -State agent-exited -ExitCode 0
    $exited = Get-LnchTerminalSessions | Where-Object LaunchId -eq $receiptContext.LaunchId
    Check 'exit receipt visible' (-not $exited.Active -and $exited.State -eq 'agent-exited' -and $exited.ExitCode -eq 0)
    $receiptPath = Join-Path (Join-Path $runtimeDir 'sessions') "$($receiptContext.LaunchId).json"
    $receiptRecord = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $receiptRecord.UpdatedAt = (Get-Date).ToUniversalTime().AddDays(-8).ToString('o')
    $receiptRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8
    $null = @(Get-LnchTerminalSessions -Prune)
    Check 'old exit receipt pruned' (-not (Test-Path -LiteralPath $receiptPath))
    Remove-Item -LiteralPath (Get-LnchLaunchContextPath $receiptContext.LaunchId) -Force

    Set-LnchDefaultAgent claude | Out-Null
    $preserved = Get-LnchUserConfig
    Check 'default-agent preserves terminal config' ($preserved.defaultAgent -eq 'claude' -and $preserved.terminal.window -eq 'last')

    $invalidMode = $false; try { Get-LnchTerminalConfig -Mode sideways -Agent omp | Out-Null } catch { $invalidMode = $true }
    $invalidColor = $false; try { Get-LnchTerminalConfig -TabColor red -Agent omp | Out-Null } catch { $invalidColor = $true }
    $invalidLaunchId = $false; try { Get-LnchLaunchContextPath '..\outside' | Out-Null } catch { $invalidLaunchId = $true }
    $invalidBackend = $false; try { Get-LnchTerminalConfig -Backend mystery -Agent omp | Out-Null } catch { $invalidBackend = $true }
    Check 'invalid mode rejected' $invalidMode
    Check 'invalid color rejected' $invalidColor
    Check 'invalid launch id rejected' $invalidLaunchId
    Check 'invalid backend rejected' $invalidBackend

    Write-Host ''
    if ($script:fail -eq 0) { Write-Host 'RESULT: TERMINAL ADAPTER PASS' } else { throw "$script:fail terminal adapter check(s) failed" }
} finally {
    $env:PATH = $oldPath
    $env:LNCH_CONFIG_DIR = $oldConfig
    $env:LNCH_RUNTIME_DIR = $oldRuntime
    $env:LNCH_WT_LOG = $oldWtLog
    $env:WT_PROFILE_ID = $oldProfile
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
