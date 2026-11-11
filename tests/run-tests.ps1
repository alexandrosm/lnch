# Engine verification matrix for lnch.
# Runs the `lnch` function against stub agents; touches only a temp dir
# plus a redirected config dir. Works on Windows PowerShell 5.1 and pwsh 7+.
$ErrorActionPreference = 'Stop'

$LnchDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$StubBin    = Join-Path $PSScriptRoot 'stubs'
$TestRoot   = Join-Path ([IO.Path]::GetTempPath()) ('ps-startertest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Projects   = Join-Path $TestRoot 'projects'
$SecondaryProjects = Join-Path $TestRoot 'secondary-projects'
New-Item -ItemType Directory -Path $Projects, $SecondaryProjects -Force | Out-Null

# self-healing PATH: sandbox environments strip System32/Git unpredictably
$sysRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
$gitCmd  = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\cmd' } else { 'C:\Program Files\Git\cmd' }
$env:PATH = "$StubBin;$gitCmd;$sysRoot\System32;$sysRoot\System32\WindowsPowerShell\v1.0;$env:PATH"

$env:LNCH_PROJECTS_DIR = $Projects
$env:LNCH_RUNTIME_DIR = Join-Path $TestRoot 'runtime'
$env:LNCH_DISCOVERY_HOME = Join-Path $TestRoot 'home'
$env:LNCH_WT_LOG = Join-Path $TestRoot 'wt.log'
Remove-Item Env:WT_SESSION -ErrorAction SilentlyContinue

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
@{
    defaultAgent = 'omp'
    gitIdentity = @{ name = 'Lnch Test'; email = 'lnch-test@example.invalid' }
    terminal = @{ readinessTimeoutMs = 0 }
    secondaryProjectRoots = @($SecondaryProjects)
} | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $env:LNCH_CONFIG_DIR 'config.json') -Encoding utf8

$script:fail = 0
function Check($label, $cond) {
    if ($cond) { Write-Host "PASS $label" } else { $script:fail++; Write-Host "FAIL $label" }
}
function Get-WtLaunchIds {
    if (-not (Test-Path -LiteralPath $env:LNCH_WT_LOG -PathType Leaf)) { return @() }
    $text = Get-Content -LiteralPath $env:LNCH_WT_LOG -Raw
    @([regex]::Matches($text, '-LaunchId\s+([0-9a-fA-F-]{36})') | ForEach-Object { $_.Groups[1].Value })
}
function Meta([string]$p) { Get-Content -LiteralPath (Join-Path $Projects "$p\.lnch.json") -Raw }

try {
    . (Join-Path $LnchDir 'Lnch.ps1')
    $__lnchFn = ${function:lnch}
    if (-not $__lnchFn) { throw 'lnch function failed to load' }

    $secondaryOnly = Join-Path $SecondaryProjects 'secondary-only'
    New-Item -ItemType Directory -Path (Join-Path $secondaryOnly '.git') -Force | Out-Null
    @{ agent = 'omp'; intent = 'secondary fixture'; updated = '2026-01-01T00:00:00Z' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $secondaryOnly '.lnch.json') -Encoding utf8
    $configuredRoots = @(Get-LnchProjectRoots)
    Check 'secondary root configured' ($configuredRoots.Count -eq 2 -and $configuredRoots[0] -eq [System.IO.Path]::GetFullPath($Projects) -and $configuredRoots[1] -eq [System.IO.Path]::GetFullPath($SecondaryProjects))

    $identityCandidates = @(Get-LnchGitIdentityCandidates)
    Check 'identity configured candidate' (@($identityCandidates | Where-Object {
        $_.Id -eq 'configured' -and $_.Name -eq 'Lnch Test' -and $_.Email -eq 'lnch-test@example.invalid'
    }).Count -eq 1)
    Check 'identity GitHub private candidate' (@($identityCandidates | Where-Object {
        $_.Id -eq 'github-noreply' -and $_.Email -eq '12345+octocat@users.noreply.github.com'
    }).Count -eq 1)
    Check 'identity GitHub public candidate' (@($identityCandidates | Where-Object {
        $_.Id -eq 'github-public' -and $_.Email -eq 'mona@example.com'
    }).Count -eq 1)
    Check 'identity custom candidate' (@($identityCandidates | Where-Object Id -eq 'custom').Count -eq 1)

    Write-Host '=== A: named project starts inline by default ==='
    $invokingDirectory = (Get-Location).Path
    $out = & $__lnchFn alpha hello world
    Check 'A git'          (Test-Path (Join-Path $Projects 'alpha\.git'))
    Check 'A prompt'       (($out -join ' ') -match '\[omp-stub\] args="hello world"')
    Check 'A agent uses project directory' (($out -join ' ') -match [regex]::Escape("[omp-stub] cwd=$(Join-Path $Projects 'alpha')"))
    Check 'A restores invoking directory' ((Get-Location).Path -eq $invokingDirectory)
    Check 'A no terminal handoff' (-not (Test-Path -LiteralPath $env:LNCH_WT_LOG))
    Check 'A agents-md'    (Test-Path (Join-Path $Projects 'alpha\AGENTS.md'))
    Check 'A claude-ptr'   ((Get-Content (Join-Path $Projects 'alpha\CLAUDE.md') -Raw) -match '@AGENTS.md')
    $m = Meta 'alpha'
    Check 'A meta agent'   ($m -match '"agent":\s*"omp"')
    Check 'A meta intent'  ($m -match 'hello world')
    $alphaGitName = [string](& git -C (Join-Path $Projects 'alpha') config --local --get user.name)
    $alphaGitEmail = [string](& git -C (Join-Path $Projects 'alpha') config --local --get user.email)
    Check 'A local git name' ($alphaGitName.Trim() -eq 'Lnch Test')
    Check 'A local git email' ($alphaGitEmail.Trim() -eq 'lnch-test@example.invalid')

    Write-Host '=== B: named project resumes inline by default ==='
    $out = & $__lnchFn alpha
    Check 'B continue'     (($out -join ' ') -match '\[omp-stub\] args=-c ')
    Check 'B no terminal handoff' (-not (Test-Path -LiteralPath $env:LNCH_WT_LOG))

    Write-Host '=== B1: secondary project roots ==='
    $out = & $__lnchFn secondary-only -Here
    Check 'B1 existing secondary project selected' (($out -join ' ') -match [regex]::Escape("[omp-stub] cwd=$secondaryOnly"))
    Check 'B1 secondary project not recreated in primary' (-not (Test-Path -LiteralPath (Join-Path $Projects 'secondary-only')))
    $secondaryAlpha = Join-Path $SecondaryProjects 'alpha'
    New-Item -ItemType Directory -Path (Join-Path $secondaryAlpha '.git') -Force | Out-Null
    @{ agent = 'omp'; updated = '2026-01-01T00:00:00Z' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $secondaryAlpha '.lnch.json') -Encoding utf8
    $out = & $__lnchFn alpha -Here
    Check 'B1 primary root wins duplicate name' (($out -join ' ') -match [regex]::Escape("[omp-stub] cwd=$(Join-Path $Projects 'alpha')"))

    Write-Host '=== B2: failed agent startup restores the caller ==='
    $missingAgent = 'lnch-missing-' + [guid]::NewGuid().ToString('N')
    $script:AgentProfiles[$missingAgent] = @{ TakesPromptOnResume = $true; Caps = @{} }
    $launchFailed = $false
    try {
        try {
            $null = & $__lnchFn missing-agent -Agent $missingAgent -ResolvedRoot (Join-Path $TestRoot 'failure-projects')
        } catch [System.Management.Automation.CommandNotFoundException] {
            $launchFailed = $true
        }
        Check 'B2 reports missing executable' $launchFailed
        Check 'B2 restores caller after exception' ((Get-Location).Path -eq $invokingDirectory)
    } finally {
        $script:AgentProfiles.Remove($missingAgent)
    }

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

    Write-Host '=== E: named prompt and intent ==='
    $out = & $__lnchFn theta build a snake game -Here
    Check 'E fresh theta'  (($out -join ' ') -match '\[omp-stub\] args="build a snake game"')
    Check 'E intent saved' ((Meta 'theta') -match 'build a snake game')

    Write-Host '=== E1: bare command opens the dashboard without launching ==='
    Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force -ErrorAction SilentlyContinue
    $bareDashboard = ((& $__lnchFn -Json) -join [Environment]::NewLine) | ConvertFrom-Json
    $secondaryDashboardProject = @($bareDashboard.Projects | Where-Object { $_.Name -eq 'secondary-only' -and $_.Directory -eq $secondaryOnly })[0]
    Check 'E1 dashboard inventory' ($bareDashboard.Schema -eq 1 -and @($bareDashboard.Roots).Count -eq 2 -and @($bareDashboard.Projects | Where-Object Name -eq 'theta').Count -eq 1 -and $secondaryDashboardProject.Root -eq [System.IO.Path]::GetFullPath($SecondaryProjects))
    Check 'E1 no terminal handoff' (-not (Test-Path -LiteralPath $env:LNCH_WT_LOG))
    $emptyDashboardRoot = Join-Path $TestRoot 'empty-dashboard'
    $emptyDashboard = ((& $__lnchFn -Json -ResolvedRoot $emptyDashboardRoot) -join [Environment]::NewLine) | ConvertFrom-Json
    Check 'E1 empty dashboard does not create a project' ($emptyDashboard.Summary.ProjectCount -eq 0 -and -not (Test-Path -LiteralPath $emptyDashboardRoot))

    Write-Host '=== E4: project disk usage ==='
    $usageRoot = Join-Path $Projects 'usage-fixture'
    $usageNested = Join-Path $usageRoot 'nested'
    $usageEmpty = Join-Path $usageRoot 'empty'
    New-Item -ItemType Directory -Path $usageNested, $usageEmpty -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $usageRoot 'root.bin'), (New-Object byte[] 2048))
    [System.IO.File]::WriteAllBytes((Join-Path $usageNested 'child.bin'), (New-Object byte[] 1024))
    Check 'E4 recursive bytes' ((Get-LnchProjectDiskUsage -Dir $usageRoot) -eq 3072)
    Check 'E4 empty directory' ((Get-LnchProjectDiskUsage -Dir $usageEmpty) -eq 0)

    Write-Host '=== E5: live project dashboard telemetry ==='
    $dashboardTerminal = Get-LnchTerminalConfig -Backend wt -ReadinessTimeoutMs 0 -Agent omp
    $dashboardContext = New-LnchLaunchContext -Name 'usage-fixture' -Directory $usageRoot -Root $Projects -Agent omp -Prompt @() -Verbs @([pscustomobject]@{ Name = 'model'; Value = 'gpt-5.6-sol' }) -Fresh $false -Terminal $dashboardTerminal
    $null = Write-LnchTerminalReceipt -Context $dashboardContext -State agent-running
    $dashboardPreview = Get-LnchProjectDashboardSnapshot -Root $Projects
    $previewTelemetry = @($dashboardPreview.Projects | Where-Object Name -eq 'usage-fixture')[0]
    Check 'E5 disk deferred' ($null -eq $previewTelemetry.DiskBytes -and $null -eq $dashboardPreview.Summary.DiskBytes)
    $dashboardSnapshot = Get-LnchProjectDashboardSnapshot -Root $Projects -RefreshDisk
    $usageTelemetry = @($dashboardSnapshot.Projects | Where-Object Name -eq 'usage-fixture')[0]
    Check 'E5 schema' ($dashboardSnapshot.Schema -eq 1 -and $dashboardSnapshot.Root -eq [System.IO.Path]::GetFullPath($Projects))
    Check 'E5 active process tree' ($usageTelemetry.State -eq 'running' -and $usageTelemetry.ActiveSessions -eq 1 -and $usageTelemetry.ProcessCount -ge 1 -and $usageTelemetry.WorkingSetBytes -gt 0)
    Check 'E5 disk and model' ($usageTelemetry.DiskBytes -eq 3072 -and $usageTelemetry.Model -eq 'gpt-5.6-sol' -and $usageTelemetry.ModelSource -eq 'launch')
    Check 'E5 cost remains unknown' ($null -eq $usageTelemetry.Cost -and $usageTelemetry.CostKind -eq 'unknown')
    $multiRootSnapshot = Get-LnchProjectDashboardSnapshot -Root $Projects -ProjectRoots $configuredRoots
    $secondaryTelemetry = @($multiRootSnapshot.Projects | Where-Object { $_.Name -eq 'secondary-only' -and $_.Directory -eq $secondaryOnly })[0]
    Check 'E5 secondary root telemetry' (@($multiRootSnapshot.Roots).Count -eq 2 -and $secondaryTelemetry.Root -eq [System.IO.Path]::GetFullPath($SecondaryProjects))
    $duplicateAlphaRows = @($multiRootSnapshot.Projects | Where-Object Name -eq 'alpha')
    Check 'E5 duplicate names retain exact roots' ($duplicateAlphaRows.Count -eq 2 -and @($duplicateAlphaRows | Where-Object Root -eq ([System.IO.Path]::GetFullPath($SecondaryProjects))).Count -eq 1)
    $dashboardCreate = script:New-LnchDashboardCreateState -IdentityCandidates $identityCandidates
    $dashboardCreate.Name = 'from-tui'
    $dashboardCompactCreateFrame = script:Get-LnchDashboardFrame -Snapshot $dashboardSnapshot -Width 60 -Height 16 -SelectedIndex 0 -CreateState $dashboardCreate
    Check 'E5 compact create frame height' (([regex]::Split($dashboardCompactCreateFrame, '\r?\n')).Count -eq 16)
    $customIdentityIndex = [array]::IndexOf(@($dashboardCreate.Identities | ForEach-Object Id), 'custom')
    $dashboardCreate.IdentityIndex = $customIdentityIndex
    $dashboardCustomInvalid = script:Get-LnchDashboardCreateIdentity -CreateState $dashboardCreate
    $dashboardCreate.CustomName = 'Dashboard Hero'
    $dashboardCreate.CustomEmail = 'dashboard@example.test'
    $dashboardCustomIdentity = script:Get-LnchDashboardCreateIdentity -CreateState $dashboardCreate
    Check 'E5 custom identity validation' (-not $dashboardCustomInvalid.Valid -and $dashboardCustomIdentity.Valid -and $dashboardCustomIdentity.Name -eq 'Dashboard Hero' -and $dashboardCustomIdentity.Email -eq 'dashboard@example.test')
    $dashboardValidName = script:Resolve-LnchDashboardProjectName -Root $Projects -Name 'from-tui'
    $dashboardInvalidName = script:Resolve-LnchDashboardProjectName -Root $Projects -Name '..\outside'
    Check 'E5 create validation' ($dashboardValidName.Valid -and $dashboardValidName.Directory -eq (Join-Path $Projects 'from-tui') -and -not $dashboardInvalidName.Valid)

    $dashboardWorker = script:New-LnchDashboardSnapshotWorker
    $dashboardAsyncResult = $null
    try {
        $dashboardWorkerStarted = script:Start-LnchDashboardSnapshotRequest -Worker $dashboardWorker -Root $Projects
        $dashboardDeadline = [datetime]::UtcNow.AddSeconds(10)
        while (-not $dashboardAsyncResult -and [datetime]::UtcNow -lt $dashboardDeadline) {
            $dashboardAsyncResult = script:Receive-LnchDashboardSnapshotRequest -Worker $dashboardWorker
            if (-not $dashboardAsyncResult) { Start-Sleep -Milliseconds 10 }
        }
        Check 'E5 async telemetry' ($dashboardWorkerStarted -and $dashboardAsyncResult -and -not $dashboardAsyncResult.Error -and $dashboardAsyncResult.Snapshot.Schema -eq 1)
    } finally {
        script:Close-LnchDashboardSnapshotWorker -Worker $dashboardWorker
    }

    $dashboardIdentityRequest = script:Start-LnchDashboardIdentityRequest
    $dashboardIdentityResult = $null
    try {
        $dashboardIdentityDeadline = [datetime]::UtcNow.AddSeconds(10)
        while (-not $dashboardIdentityResult -and [datetime]::UtcNow -lt $dashboardIdentityDeadline) {
            $dashboardIdentityResult = script:Receive-LnchDashboardIdentityRequest -Request $dashboardIdentityRequest
            if (-not $dashboardIdentityResult) { Start-Sleep -Milliseconds 10 }
        }
        if ($dashboardIdentityResult) { $dashboardIdentityRequest = $null }
        Check 'E5 async identity discovery' ($dashboardIdentityResult -and -not $dashboardIdentityResult.Error -and @($dashboardIdentityResult.Identities | Where-Object Id -eq 'github-noreply').Count -eq 1)
    } finally {
        script:Close-LnchDashboardIdentityRequest -Request $dashboardIdentityRequest
    }

    Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force -ErrorAction SilentlyContinue
    $dashboardProjectRequest = script:Start-LnchDashboardProjectProcess -Root $Projects -Name 'from-tui' -Agent 'omp' -GitName $dashboardCustomIdentity.Name -GitEmail $dashboardCustomIdentity.Email
    $dashboardProjectFinished = $dashboardProjectRequest.Process.WaitForExit(15000)
    $dashboardProjectExitCode = if ($dashboardProjectFinished) { [int]$dashboardProjectRequest.Process.ExitCode } else { -1 }
    $dashboardProjectRequest.Process.Dispose()
    $dashboardWtLog = if (Test-Path -LiteralPath $env:LNCH_WT_LOG) { Get-Content -LiteralPath $env:LNCH_WT_LOG -Raw } else { '' }
    $dashboardGitName = [string](& git -C (Join-Path $Projects 'from-tui') config --local --get user.name)
    $dashboardGitEmail = [string](& git -C (Join-Path $Projects 'from-tui') config --local --get user.email)
    Check 'E5 create from dashboard' ($dashboardProjectFinished -and $dashboardProjectExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $Projects 'from-tui\AGENTS.md')))
    Check 'E5 dashboard local identity' ($dashboardGitName.Trim() -eq 'Dashboard Hero' -and $dashboardGitEmail.Trim() -eq 'dashboard@example.test')
    Check 'E5 create launches terminal' ($dashboardWtLog -match 'new-tab .*--title from-tui ')
    foreach ($dashboardLaunchId in @(Get-WtLaunchIds)) {
        Remove-Item -LiteralPath (Get-LnchLaunchContextPath $dashboardLaunchId) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path (Join-Path $env:LNCH_RUNTIME_DIR 'sessions') "$dashboardLaunchId.json") -Force -ErrorAction SilentlyContinue
    }

    Write-Host '=== E6: dashboard opens an existing project in a tab ==='
    $dashboardConfigPath = Join-Path $env:LNCH_CONFIG_DIR 'config.json'
    $dashboardSavedConfig = Get-Content -LiteralPath $dashboardConfigPath -Raw
    try {
        $dashboardConfig = $dashboardSavedConfig | ConvertFrom-Json
        $dashboardConfig.terminal | Add-Member -NotePropertyName mode -NotePropertyValue inline
        $dashboardConfig | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $dashboardConfigPath -Encoding utf8
        Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force -ErrorAction SilentlyContinue
        $openedProject = Invoke-LnchDashboardProjectLaunch -Root $Projects -Name alpha -Existing
        $openedLog = Get-Content -LiteralPath $env:LNCH_WT_LOG -Raw
        Check 'E6 explicit tab overrides inline default' ($openedLog -match 'new-tab .*--title alpha ')
        $out = & $__lnchFn -FromLauncher -LaunchId $openedProject.LaunchId -RuntimeRoot $env:LNCH_RUNTIME_DIR
        Check 'E6 owning agent resumes in original project' (($out -join ' ') -match '\[omp-stub\] args=-c\b' -and ($out -join ' ') -match [regex]::Escape("[omp-stub] cwd=$(Join-Path $Projects 'alpha')"))
        Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force -ErrorAction SilentlyContinue
        $openedSecondary = Invoke-LnchDashboardProjectLaunch -Root $SecondaryProjects -Name alpha -Existing
        $out = & $__lnchFn -FromLauncher -LaunchId $openedSecondary.LaunchId -RuntimeRoot $env:LNCH_RUNTIME_DIR
        Check 'E6 duplicate-name secondary opens from selected root' (($out -join ' ') -match [regex]::Escape("[omp-stub] cwd=$secondaryAlpha"))
        $missingProjectRejected = $false
        try {
            Invoke-LnchDashboardProjectLaunch -Root $Projects -Name missing-dashboard-project -Existing | Out-Null
        } catch {
            $missingProjectRejected = $true
        }
        Check 'E6 missing selection is not recreated' ($missingProjectRejected -and -not (Test-Path -LiteralPath (Join-Path $Projects 'missing-dashboard-project')))
    } finally {
        Set-Content -LiteralPath $dashboardConfigPath -Value $dashboardSavedConfig -Encoding utf8
    }

    $topJson = ((& $__lnchFn -Top -Json) -join [Environment]::NewLine) | ConvertFrom-Json
    Check 'E5 top JSON' ($topJson.Schema -eq 1 -and @($topJson.Projects | Where-Object Name -eq 'usage-fixture').Count -eq 1)
    $longTopPath = Join-Path $Projects '--top'
    $longTopJson = ((& $__lnchFn --top --json) -join [Environment]::NewLine) | ConvertFrom-Json
    Check 'E5 direct GNU top' ($longTopJson.Schema -eq 1 -and -not (Test-Path -LiteralPath $longTopPath))
    $env:LNCH_NO_DASHBOARD = '1'
    Check 'E5 dashboard opt-out' (-not (Test-LnchDashboardAutoStart))
    Remove-Item Env:LNCH_NO_DASHBOARD -ErrorAction SilentlyContinue
    $null = Write-LnchTerminalReceipt -Context $dashboardContext -State agent-exited -ExitCode 0
    Remove-Item -LiteralPath (Get-LnchLaunchContextPath $dashboardContext.LaunchId) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path (Join-Path $env:LNCH_RUNTIME_DIR 'sessions') "$($dashboardContext.LaunchId).json") -Force -ErrorAction SilentlyContinue

    Write-Host '=== F: versioned new-tab launch envelope ==='
    Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force -ErrorAction SilentlyContinue
    $out = & $__lnchFn epsilon hi there -TerminalMode tab
    $wtLog = Get-Content -LiteralPath $env:LNCH_WT_LOG -Raw
    Check 'F sticky project title' ($wtLog -match 'new-tab .*--title epsilon .*--suppressApplicationTitle')
    Check 'F last window target' ($wtLog -match '--window last')
    $launchId = @(Get-WtLaunchIds | Select-Object -Last 1)[0]
    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath (Join-Path $Projects 'epsilon')
        $out = & $__lnchFn -FromLauncher -LaunchId $launchId -RuntimeRoot $env:LNCH_RUNTIME_DIR
    } finally {
        Set-Location -LiteralPath $previousLocation
    }
    $j = $out -join ' '
    Check 'F launcher fresh prompt' (($j -match '\[omp-stub\] args="hi there"') -and -not ($j -match 'args=-c'))
    Check 'F context consumed' (-not (Test-Path -LiteralPath (Get-LnchLaunchContextPath $launchId)))
    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath (Join-Path $Projects 'epsilon')
        $restoredOut = & $__lnchFn -FromLauncher -LaunchId $launchId -RuntimeRoot $env:LNCH_RUNTIME_DIR
    } finally { Set-Location -LiteralPath $previousLocation }
    $restoredText = $restoredOut -join ' '
    Check 'F restored tab resumes' ($restoredText -match '\[omp-stub\] args=-c\b')
    Check 'F restored tab does not replay prompt' ($restoredText -notmatch 'hi there')
    $activeContext = Receive-LnchLaunchContext -LaunchId $launchId
    $null = Write-LnchTerminalReceipt -Context $activeContext -State child-started
    $duplicateOut = @(& $__lnchFn -FromLauncher -LaunchId $launchId -RuntimeRoot $env:LNCH_RUNTIME_DIR *>&1)
    $duplicateText = $duplicateOut -join ' '
    Check 'F active duplicate suppressed' ($duplicateText -notmatch '\[omp-stub\]')
    $null = Write-LnchTerminalReceipt -Context $activeContext -State agent-exited -ExitCode 0

    Write-Host '=== F2: existing project envelope resumes ==='
    Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force -ErrorAction SilentlyContinue
    $out = & $__lnchFn alpha --terminal tab
    $launchId = @(Get-WtLaunchIds | Select-Object -Last 1)[0]
    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath (Join-Path $Projects 'alpha')
        $out = & $__lnchFn -FromLauncher -LaunchId $launchId -RuntimeRoot $env:LNCH_RUNTIME_DIR
    } finally { Set-Location -LiteralPath $previousLocation }
    Check 'F2 resumes' (($out -join ' ') -match '\[omp-stub\] args=-c\b')

    Write-Host '=== F3: saved terminal policy and inline overrides ==='
    $configPath = Join-Path $env:LNCH_CONFIG_DIR 'config.json'
    $savedConfig = Get-Content -LiteralPath $configPath -Raw
    try {
        $config = $savedConfig | ConvertFrom-Json
        $config.terminal | Add-Member -NotePropertyName mode -NotePropertyValue tab
        $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding utf8
        Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force
        $out = & $__lnchFn alpha
        Check 'F3 saved tab mode launches a tab' ((Get-Content -LiteralPath $env:LNCH_WT_LOG -Raw) -match 'new-tab .*--title alpha ')
        foreach ($configuredLaunchId in @(Get-WtLaunchIds)) {
            Remove-Item -LiteralPath (Get-LnchLaunchContextPath $configuredLaunchId) -Force
        }
        Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force
        $out = & $__lnchFn alpha -Here
        Check 'F3 Here overrides saved tab mode' (($out -join ' ') -match '\[omp-stub\] args=-c\b' -and -not (Test-Path -LiteralPath $env:LNCH_WT_LOG))
        $out = & $__lnchFn alpha --terminal inline
        Check 'F3 terminal inline overrides saved tab mode' (($out -join ' ') -match '\[omp-stub\] args=-c\b' -and -not (Test-Path -LiteralPath $env:LNCH_WT_LOG))
    } finally {
        Set-Content -LiteralPath $configPath -Value $savedConfig -Encoding utf8
    }

    Write-Host '=== F4: removed managed workspaces are never recreated ==='
    foreach ($handoffState in @('pending', 'restored')) {
        $vanishedRoot = Join-Path $TestRoot "removed-$handoffState-root"
        $vanishedDirectory = Join-Path $vanishedRoot 'removed-workspace'
        New-Item -ItemType Directory -Path $vanishedDirectory -Force | Out-Null
        $vanishedContext = New-LnchLaunchContext -Name removed-workspace -Directory $vanishedDirectory -Root $vanishedRoot -Agent omp -Fresh ($handoffState -eq 'pending') -Terminal (Get-LnchTerminalConfig -ReadinessTimeoutMs 0)
        if ($handoffState -eq 'restored') {
            $vanishedContext = Receive-LnchLaunchContext -LaunchId $vanishedContext.LaunchId
            Write-LnchTerminalReceipt -Context $vanishedContext -State agent-exited -ExitCode 0 | Out-Null
        }
        Remove-Item -LiteralPath $vanishedRoot -Recurse -Force
        $missingRejected = $false
        try { & $__lnchFn -FromLauncher -LaunchId $vanishedContext.LaunchId -RuntimeRoot $env:LNCH_RUNTIME_DIR | Out-Null } catch { $missingRejected = $true }
        $missingReceipt = Get-LnchTerminalSessions | Where-Object LaunchId -eq $vanishedContext.LaunchId
        Check "F4 $handoffState rejects missing workspace without creating root" ($missingRejected -and -not (Test-Path -LiteralPath $vanishedRoot) -and $missingReceipt.State -eq 'failed')
    }

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

    Write-Host '=== K: yolo rides the launch envelope ==='
    Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force -ErrorAction SilentlyContinue
    $out = & $__lnchFn kappa go -yolo -TerminalMode tab
    $launchId = @(Get-WtLaunchIds | Select-Object -Last 1)[0]
    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath (Join-Path $Projects 'kappa')
        $out = & $__lnchFn -FromLauncher -LaunchId $launchId -RuntimeRoot $env:LNCH_RUNTIME_DIR
    } finally { Set-Location -LiteralPath $previousLocation }
    $j = $out -join ' '
    Check 'K fresh+yolo+prompt' (($j -match '\[omp-stub\] args=--approval-mode yolo go') -and -not ($j -match 'args=-c'))

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
    $doctorSentinel = Join-Path $Projects '.doctor-probe'
    Set-Content -LiteralPath $doctorSentinel -Value 'user-owned data'
    $out = & powershell.exe -NoProfile -Command '. "$env:LNCH_INSTALL_DIR\Lnch.ps1"; lnch -Doctor' 2>&1
    $j = $out -join ' '
    Check 'N doctor runs'  ($j -match 'lnch doctor')
    Check 'N git ok'       ($j -match '\[ok\] git')
    Check 'N cap matrix'   ($j -match 'resume-pick')
    Check 'N hooks line'   ($j -match 'post-create hooks configured')
    Check 'N secondary root' ($j -match [regex]::Escape("secondary projects root $SecondaryProjects"))
    Check 'N doctor preserves existing files' ((Test-Path -LiteralPath $doctorSentinel) -and (Get-Content -LiteralPath $doctorSentinel -Raw).Trim() -eq 'user-owned data')
    Check 'N doctor removes only its own probe' (@(Get-ChildItem -LiteralPath $Projects -Filter '.lnch-doctor-*.tmp' -Force).Count -eq 0)

    Write-Host '=== O: entry.ps1 --agent passthrough ==='
    $entry = Join-Path $LnchDir 'entry.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry --agent claude --git-name 'Entry Hero' --git-email entry@example.test kappa2 ship it --here --no-dashboard 2>&1
    Check 'O entry agent'  (($out -join ' ') -match '\[claude-stub\] args="ship it"')
    $entryGitName = [string](& git -C (Join-Path $Projects 'kappa2') config --local --get user.name)
    $entryGitEmail = [string](& git -C (Join-Path $Projects 'kappa2') config --local --get user.email)
    Check 'O entry identity options' ($entryGitName.Trim() -eq 'Entry Hero' -and $entryGitEmail.Trim() -eq 'entry@example.test')
    $invalidIdentityOutput = @(& $__lnchFn invalid-identity -GitName 'Name Only' -Here -ErrorAction Continue 2>&1)
    Check 'O incomplete identity rejected' (($invalidIdentityOutput -join ' ') -match 'user.email cannot be empty' -and -not (Test-Path -LiteralPath (Join-Path $Projects 'invalid-identity')))
    $entryTopOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry --top --json 2>&1
    $entryTop = $null
    try { $entryTop = (($entryTopOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json } catch { }
    Check 'O entry top JSON' ($entryTop -and $entryTop.Schema -eq 1 -and @($entryTop.Projects).Count -gt 0)

    Write-Host '=== P: :pick replaces base resume ==='
    $out = & $__lnchFn alpha :pick -Here 2>&1
    $j = $out -join ' '
    Check 'P pick only'    (($j -match 'args=-r\b') -and (!($j -match 'args=-c\b')))
    $out = & $__lnchFn alpha :resume -Here
    Check 'P explicit resume is not duplicated' (@($out | Where-Object { $_.Trim() -eq '[omp-stub] args=-c' }).Count -eq 1)
    $out = & $__lnchFn alpha :resume :pick -Here
    Check 'P picker takes precedence over explicit resume' (@($out | Where-Object { $_.Trim() -eq '[omp-stub] args=-r' }).Count -eq 1)

    Write-Host '=== P1: supported approval modes reach the agent ==='
    $out = & $__lnchFn beta :plan sketch design -Here
    Check 'P1 planning mode with prompt' (($out -join ' ').Trim() -match '\[claude-stub\] args=-c --permission-mode plan "sketch design"$')
    $out = & $__lnchFn beta :edits -Here
    Check 'P1 edit approval mode' (($out -join ' ').Trim() -match '\[claude-stub\] args=-c --permission-mode acceptEdits$')

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
{ "defaultAgent": "omp", "gitIdentity": { "name": "Lnch Test", "email": "lnch-test@example.invalid" }, "postCreate": ["Set-Content hooked.txt -Value hooked"], "terminal": { "readinessTimeoutMs": 0 } }
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
        Check 'U restores caller' ((Get-Location).Path -eq $caller)
        $out = & $__lnchFn localroot
        Check 'U repeated launch resumes original project' (($out -join ' ') -match '\[omp-stub\] args=-c\b')
        Check 'U repeated launch avoids nested project' (-not (Test-Path -LiteralPath (Join-Path $expectedLocalRoot 'localroot\projects\localroot')))

        $overrideRoot = Join-Path $TestRoot 'explicit-root'
        $env:LNCH_PROJECTS_DIR = $overrideRoot
        $out = & $__lnchFn overridden hi -Agent omp -Here
        Check 'U explicit override' (Test-Path (Join-Path $overrideRoot 'overridden\.git'))
    } finally {
        Set-Location -LiteralPath $originalLocation
        if ($originalRoot) { $env:LNCH_PROJECTS_DIR = $originalRoot }
        else { Remove-Item Env:LNCH_PROJECTS_DIR -ErrorAction SilentlyContinue }
    }

    Write-Host '=== U2: dynamic root survives new-tab handoff ==='
    try {
        Set-Location -LiteralPath $caller
        Remove-Item Env:LNCH_PROJECTS_DIR -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $env:LNCH_WT_LOG -Force -ErrorAction SilentlyContinue
        $dynamicRoot = [System.IO.Path]::GetFullPath((Join-Path $caller 'projects'))
        $dynamicProject = Join-Path $dynamicRoot 'dynamic-tab'
        $out = & $__lnchFn dynamic-tab hi -Agent omp -TerminalMode tab
        $launchId = @(Get-WtLaunchIds | Select-Object -Last 1)[0]
        Set-Location -LiteralPath $dynamicProject
        $out = & $__lnchFn -FromLauncher -LaunchId $launchId -RuntimeRoot $env:LNCH_RUNTIME_DIR
        $joined = $out -join ' '
        Check 'U2 original project cwd' ($joined -match [regex]::Escape("[omp-stub] cwd=$dynamicProject"))
        Check 'U2 no recursive project' (-not (Test-Path -LiteralPath (Join-Path $dynamicProject 'projects\dynamic-tab')))
        Check 'U2 context consumed' (-not (Test-Path -LiteralPath (Get-LnchLaunchContextPath $launchId)))
        Check 'U2 post-create hook' (Test-Path -LiteralPath (Join-Path $dynamicProject 'hooked.txt'))
    } finally {
        Set-Location -LiteralPath $originalLocation
        if ($originalRoot) { $env:LNCH_PROJECTS_DIR = $originalRoot }
        else { Remove-Item Env:LNCH_PROJECTS_DIR -ErrorAction SilentlyContinue }
    }

    Write-Host '=== V: Level Zero and One agent discovery ==='
    $discoveryRoot = Join-Path $TestRoot 'agent-stores'
    $discoveryEnvNames = @(
        'PI_CODING_AGENT_DIR', 'OMP_PROFILE', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME',
        'GEMINI_CLI_HOME', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG',
        'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME',
        'QWEN_HOME', 'QWEN_RUNTIME_DIR', 'LNCH_DISCOVERY_HOME', 'LNCH_DISCOVERY_ROOTS'
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
        $discoveryHome = Join-Path $discoveryRoot 'home'
        $projectRoot = Join-Path $discoveryRoot 'projects'
        $sharedProject = Join-Path $projectRoot 'shared-omp-claude'
        $codexProject = Join-Path $projectRoot 'codex-project'
        $geminiProject = Join-Path $projectRoot 'gemini-project'
        $aiderProject = Join-Path $projectRoot 'aider-project'
        $openProject = Join-Path $projectRoot 'opencode-project'
        $qwenProject = Join-Path $projectRoot 'qwen-project'

        foreach ($dir in @(
            $discoveryHome, $ompStore, $claudeStore, $codexStore, (Join-Path $geminiBase '.gemini'),
            $openConfig, (Join-Path $xdgData 'opencode'), (Join-Path $xdgCache 'opencode'),
            (Join-Path $xdgState 'opencode'), $qwenStore, $qwenRuntime,
            $sharedProject, $codexProject, $geminiProject, $aiderProject, $openProject, $qwenProject
        )) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Set-Content -LiteralPath $openConfigFile -Value '{}'

        $ompBucket = Join-Path $ompStore 'sessions\-fixture-shared-'
        New-Item -ItemType Directory -Force -Path $ompBucket | Out-Null
        @(
            (@{ type = 'title'; title = 'fixture' } | ConvertTo-Json -Compress),
            (@{ type = 'session'; version = 3; id = 'omp-fixture'; timestamp = '2026-08-26T00:00:00Z'; cwd = $sharedProject } | ConvertTo-Json -Compress),
            (@{ type = 'message'; id = 'omp-user'; parentId = $null; timestamp = '2026-08-26T00:00:01Z'; message = @{ role = 'user'; content = 'fix the fixture' } } | ConvertTo-Json -Depth 6 -Compress),
            (@{ type = 'message'; id = 'omp-assistant'; parentId = 'omp-user'; timestamp = '2026-08-26T00:00:02Z'; message = @{ role = 'assistant'; model = 'fixture-model'; content = @(@{ type = 'text'; text = 'working' }, @{ type = 'toolCall'; id = 'tool-1'; name = 'read'; arguments = @{ path = 'fixture.txt' } }) } } | ConvertTo-Json -Depth 8 -Compress),
            (@{ type = 'message'; id = 'omp-result'; parentId = 'omp-assistant'; timestamp = '2026-08-26T00:00:03Z'; message = @{ role = 'toolResult'; toolCallId = 'tool-1'; toolName = 'read'; content = @(@{ type = 'text'; text = 'fixture result' }); isError = $false } } | ConvertTo-Json -Depth 8 -Compress)
        ) | Set-Content -LiteralPath (Join-Path $ompBucket 'fixture.jsonl') -Encoding utf8

        $claudeProjectStore = Join-Path $claudeStore 'projects\fixture-shared'
        New-Item -ItemType Directory -Force -Path $claudeProjectStore | Out-Null
        @(
            (@{ type = 'user'; uuid = 'claude-user'; sessionId = 'claude-fixture'; cwd = $sharedProject; timestamp = '2026-08-26T00:01:00Z'; message = @{ role = 'user'; content = 'claude fixture prompt' } } | ConvertTo-Json -Depth 6 -Compress),
            (@{ type = 'assistant'; uuid = 'claude-assistant'; parentUuid = 'claude-user'; sessionId = 'claude-fixture'; cwd = $sharedProject; timestamp = '2026-08-26T00:01:01Z'; message = @{ role = 'assistant'; model = 'claude-fixture-model'; content = @(@{ type = 'text'; text = 'claude fixture answer' }) } } | ConvertTo-Json -Depth 8 -Compress)
        ) | Set-Content -LiteralPath (Join-Path $claudeProjectStore 'claude-fixture.jsonl') -Encoding utf8

        $codexSessionStore = Join-Path $codexStore 'sessions\2026\08\26'
        New-Item -ItemType Directory -Force -Path $codexSessionStore | Out-Null
        @(
            (@{ type = 'session_meta'; timestamp = '2026-08-26T00:02:00Z'; payload = @{ id = 'codex-fixture'; cwd = $codexProject } } | ConvertTo-Json -Depth 5 -Compress),
            (@{ type = 'turn_context'; timestamp = '2026-08-26T00:02:01Z'; payload = @{ model = 'codex-fixture-model' } } | ConvertTo-Json -Depth 5 -Compress),
            (@{ type = 'response_item'; timestamp = '2026-08-26T00:02:02Z'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = 'codex fixture prompt' }) } } | ConvertTo-Json -Depth 8 -Compress),
            (@{ type = 'response_item'; timestamp = '2026-08-26T00:02:03Z'; payload = @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'codex fixture answer' }) } } | ConvertTo-Json -Depth 8 -Compress),
            (@{ type = 'compacted'; timestamp = '2026-08-26T00:02:04Z'; payload = @{ message = 'codex fixture compacted' } } | ConvertTo-Json -Depth 5 -Compress)
        ) | Set-Content -LiteralPath (Join-Path $codexSessionStore 'rollout-codex-fixture.jsonl') -Encoding utf8
        @(
            (@{ type = 'session_meta'; timestamp = '2026-08-26T00:02:10Z'; payload = @{ id = 'codex-child-fixture'; cwd = $codexProject; parent_thread_id = 'codex-fixture'; forked_from_id = 'codex-fixture'; thread_source = 'subagent'; agent_path = '/root/reviewer'; agent_nickname = 'Reviewer' } } | ConvertTo-Json -Depth 8 -Compress),
            (@{ type = 'response_item'; timestamp = '2026-08-26T00:02:11Z'; payload = @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'codex child answer' }) } } | ConvertTo-Json -Depth 8 -Compress)
        ) | Set-Content -LiteralPath (Join-Path $codexSessionStore 'rollout-codex-child-fixture.jsonl') -Encoding utf8

        $geminiStore = Join-Path $geminiBase '.gemini'
        $geminiRegistry = [ordered]@{ projects = [ordered]@{} }
        $geminiRegistry.projects[$geminiProject] = 'gemini-fixture'
        $geminiRegistry | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $geminiStore 'projects.json') -Encoding utf8
        $geminiChats = Join-Path $geminiStore 'tmp\gemini-fixture\chats'
        New-Item -ItemType Directory -Force -Path $geminiChats | Out-Null
        @(
            '{"sessionId":"gemini-fixture","projectHash":"fixture","startTime":"2026-08-26T00:03:00Z"}',
            (@{ id = 'gemini-user'; type = 'user'; timestamp = '2026-08-26T00:03:01Z'; content = 'gemini fixture prompt' } | ConvertTo-Json -Compress),
            (@{ id = 'gemini-answer'; type = 'gemini'; timestamp = '2026-08-26T00:03:02Z'; model = 'gemini-fixture-model'; content = 'gemini fixture answer' } | ConvertTo-Json -Compress)
        ) | Set-Content -LiteralPath (Join-Path $geminiChats 'session-gemini-fixture.jsonl') -Encoding utf8

        @(
            '# aider chat started at 2026-08-26',
            '#### aider fixture prompt',
            '',
            'aider fixture answer'
        ) | Set-Content -LiteralPath (Join-Path $aiderProject '.aider.chat.history.md') -Encoding utf8

        $openLegacy = Join-Path $xdgData 'opencode\storage\session\fixture'
        New-Item -ItemType Directory -Force -Path $openLegacy | Out-Null
        @{ id = 'opencode-fixture'; directory = $openProject; title = 'fixture'; time = @{ created = 1787702700000; updated = 1787702701000 } } |
            ConvertTo-Json -Depth 5 -Compress |
            Set-Content -LiteralPath (Join-Path $openLegacy 'opencode-fixture.json') -Encoding utf8
        $openMessageRoot = Join-Path $xdgData 'opencode\storage\message\opencode-fixture'
        $openPartRoot = Join-Path $xdgData 'opencode\storage\part\open-message'
        New-Item -ItemType Directory -Force -Path $openMessageRoot, $openPartRoot | Out-Null
        @{ id = 'open-message'; sessionID = 'opencode-fixture'; role = 'user'; time = @{ created = 1787702701000 } } |
            ConvertTo-Json -Depth 5 -Compress |
            Set-Content -LiteralPath (Join-Path $openMessageRoot 'open-message.json') -Encoding utf8
        @{ id = 'open-part'; sessionID = 'opencode-fixture'; messageID = 'open-message'; type = 'text'; text = 'opencode fixture prompt' } |
            ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $openPartRoot 'open-part.json') -Encoding utf8

        $qwenChats = Join-Path $qwenRuntime 'projects\qwen-fixture\chats'
        New-Item -ItemType Directory -Force -Path $qwenChats | Out-Null
        @(
            (@{ uuid = 'qwen-user'; parentUuid = $null; sessionId = 'qwen-fixture'; timestamp = '2026-08-26T00:04:00Z'; type = 'user'; cwd = $qwenProject; version = 'fixture'; message = @{ role = 'user'; parts = @(@{ text = 'qwen fixture prompt' }) } } | ConvertTo-Json -Depth 8 -Compress),
            (@{ uuid = 'qwen-answer'; parentUuid = 'qwen-user'; sessionId = 'qwen-fixture'; timestamp = '2026-08-26T00:04:01Z'; type = 'assistant'; cwd = $qwenProject; version = 'fixture'; model = 'qwen-fixture-model'; message = @{ role = 'model'; parts = @(@{ text = 'qwen fixture answer' }) } } | ConvertTo-Json -Depth 8 -Compress)
        ) | Set-Content -LiteralPath (Join-Path $qwenChats 'qwen-fixture.jsonl') -Encoding utf8

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
        [Environment]::SetEnvironmentVariable('LNCH_DISCOVERY_ROOTS', $projectRoot, 'Process')
        [Environment]::SetEnvironmentVariable('LNCH_DISCOVERY_HOME', $discoveryHome, 'Process')

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

        $projectInventory = Get-LnchProjectInventory
        Check 'V project schema' ($projectInventory.Schema -eq 2)
        Check 'V unified fixture count' (@($projectInventory.Projects | Where-Object { $_.Path -in @($sharedProject, $codexProject, $geminiProject, $aiderProject, $openProject, $qwenProject) }).Count -eq 6)
        $sharedWorkspace = $projectInventory.Projects | Where-Object Path -eq $sharedProject | Select-Object -First 1
        Check 'V shared reconciliation' ($sharedWorkspace -and @($sharedWorkspace.Agents | Where-Object { $_ -in @('omp', 'claude') }).Count -eq 2)
        Check 'V codex project' (@(($projectInventory.Agents | Where-Object Agent -eq 'codex').Projects | Where-Object Path -eq $codexProject).Count -eq 1)
        $codexProjectEntry = ($projectInventory.Agents | Where-Object Agent -eq 'codex').Projects | Where-Object Path -eq $codexProject | Select-Object -First 1
        Check 'V codex root project count' ($codexProjectEntry.SessionCount -eq 1 -and $codexProjectEntry.Sources -contains 'child-rollout-jsonl')
        Check 'V gemini project' (@(($projectInventory.Agents | Where-Object Agent -eq 'gemini').Projects | Where-Object Path -eq $geminiProject).Count -eq 1)
        Check 'V aider partial project' (@(($projectInventory.Agents | Where-Object Agent -eq 'aider').Projects | Where-Object Path -eq $aiderProject).Count -eq 1)
        Check 'V opencode project' (@(($projectInventory.Agents | Where-Object Agent -eq 'opencode').Projects | Where-Object Path -eq $openProject).Count -eq 1)
        Check 'V qwen project' (@((Get-LnchAgentProjects -Agent qwen) | Where-Object Path -eq $qwenProject).Count -eq 1)

        $sessionInventory = Get-LnchSessionInventory
        $fixtureSessions = @($sessionInventory.Sessions | Where-Object { $_.ProjectPath -in @($sharedProject, $codexProject, $geminiProject, $aiderProject, $openProject, $qwenProject) })
        Check 'V session schema' ($sessionInventory.Schema -eq 1)
        Check 'V seven agent sessions' (@($fixtureSessions.Agent | Sort-Object -Unique).Count -eq 7)
        Check 'V session project IDs' (@($fixtureSessions | Where-Object { $_.ProjectId -like 'workspace:*' }).Count -eq 7)
        $codexAllSessions = Get-LnchSessionInventory -Agent codex -IncludeChildren -Refresh
        $codexFixtureSessions = @($codexAllSessions.Sessions | Where-Object ProjectPath -eq $codexProject)
        $codexRootSession = $codexFixtureSessions | Where-Object NativeId -eq 'codex-fixture' | Select-Object -First 1
        $codexChildSession = $codexFixtureSessions | Where-Object NativeId -eq 'codex-child-fixture' | Select-Object -First 1
        Check 'V codex children excluded default' (@($fixtureSessions | Where-Object Agent -eq 'codex').Count -eq 1)
        Check 'V codex child classified' ($codexFixtureSessions.Count -eq 2 -and $codexChildSession.Kind -eq 'child' -and $codexChildSession.ParentId -eq 'codex-fixture')
        Check 'V codex child count' ($codexRootSession.Kind -eq 'root' -and $codexRootSession.ChildCount -eq 1)
        $codexChildTranscript = Get-LnchSessionTranscript -Reference 'codex:codex-child-fixture'
        Check 'V codex child transcript' ($codexChildTranscript.Stats.Messages -eq 1)

        foreach ($fixtureAgent in @('omp', 'claude', 'codex', 'gemini', 'aider', 'opencode', 'qwen')) {
            $fixtureSession = $fixtureSessions | Where-Object Agent -eq $fixtureAgent | Select-Object -First 1
            $transcript = if ($fixtureSession) { Get-LnchSessionTranscript -Reference $fixtureSession.Ref } else { $null }
            Check \"V $fixtureAgent transcript\" ($transcript -and $transcript.Schema -eq 1 -and @($transcript.Events).Count -gt 0)
        }
        $ompTranscript = Get-LnchSessionTranscript -Reference 'omp:omp-fixture'
        Check 'V omp tools normalized' ($ompTranscript.Stats.ToolCalls -eq 1 -and $ompTranscript.Stats.ToolResults -eq 1)
        $codexTranscript = Get-LnchSessionTranscript -Reference 'codex:codex-fixture'
        Check 'V codex compaction' (@($codexTranscript.Events | Where-Object Kind -eq 'compaction').Count -eq 1)

        $sessionJsonOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $LnchDir 'entry.ps1') --sessions --json 2>&1
        $sessionJson = $null
        try { $sessionJson = (($sessionJsonOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json } catch { }
        Check 'V entry session JSON' ($sessionJson -and $sessionJson.Schema -eq 1 -and @($sessionJson.Sessions).Count -ge 7)
        $childSessionJsonOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $LnchDir 'entry.ps1') --sessions --agent codex --include-children --json 2>&1
        $childSessionJson = $null
        try { $childSessionJson = (($childSessionJsonOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json } catch { }
        Check 'V entry child sessions' ($childSessionJson -and @($childSessionJson.Sessions | Where-Object Kind -eq 'child').Count -eq 1)
        $transcriptJsonOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $LnchDir 'entry.ps1') --transcript omp:omp-fixture --json 2>&1
        $transcriptJson = $null
        try { $transcriptJson = (($transcriptJsonOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json } catch { }
        Check 'V entry transcript JSON' ($transcriptJson -and $transcriptJson.Schema -eq 1 -and $transcriptJson.Stats.ToolCalls -eq 1)

        $jsonOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $LnchDir 'entry.ps1') --discover --json 2>&1
        $jsonDocument = $null
        try { $jsonDocument = (($jsonOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json } catch { }
        Check 'V entry JSON schema' ($jsonDocument -and $jsonDocument.Schema -eq 2)
        Check 'V entry JSON agents' ($jsonDocument -and @($jsonDocument.Agents).Count -eq 7)
        Check 'V entry JSON projects' ($jsonDocument -and @($jsonDocument.Projects).Count -ge 6)

        Write-Host '=== V2: discovery and session cache follow configured roots ==='
        $rootConfigPath = Join-Path $env:LNCH_CONFIG_DIR 'config.json'
        $rootConfigBefore = Get-Content -LiteralPath $rootConfigPath -Raw
        $secondaryEnvBefore = $env:LNCH_SECONDARY_PROJECTS_DIRS
        try {
            $catalogRoot = Join-Path $TestRoot 'outside\deep\configured'
            $catalogProject = Join-Path $catalogRoot 'local-history'
            $envCatalogRoot = Join-Path $TestRoot 'outside\deep\environment'
            $envCatalogProject = Join-Path $envCatalogRoot 'env-history'
            New-Item -ItemType Directory -Path $catalogProject, $envCatalogProject -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $catalogProject '.aider.chat.history.md') -Value '#### configured root task'
            Set-Content -LiteralPath (Join-Path $envCatalogProject '.aider.chat.history.md') -Value '#### environment root task'
            $beforeRoots = Get-LnchSessionInventory -Agent aider -Refresh
            Check 'V2 unrelated history excluded' (@($beforeRoots.Sessions | Where-Object ProjectPath -eq $catalogProject).Count -eq 0)
            $rootConfig = $rootConfigBefore | ConvertFrom-Json
            $rootConfig | Add-Member -NotePropertyName secondaryProjectRoots -NotePropertyValue @($catalogRoot) -Force
            $rootConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rootConfigPath -Encoding utf8
            $afterRoots = Get-LnchSessionInventory -Agent aider
            $configuredHistory = @($afterRoots.Sessions | Where-Object ProjectPath -eq $catalogProject)
            Check 'V2 configured root invalidates session cache' ($configuredHistory.Count -eq 1 -and $configuredHistory[0].Title -eq 'configured root task')
            $env:LNCH_SECONDARY_PROJECTS_DIRS = $envCatalogRoot
            $envRoots = Get-LnchSessionInventory -Agent aider
            $envHistory = @($envRoots.Sessions | Where-Object ProjectPath -eq $envCatalogProject)
            Check 'V2 environment root invalidates session cache' ($envHistory.Count -eq 1 -and $envHistory[0].Title -eq 'environment root task')
        } finally {
            Set-Content -LiteralPath $rootConfigPath -Value $rootConfigBefore -Encoding utf8
            [Environment]::SetEnvironmentVariable('LNCH_SECONDARY_PROJECTS_DIRS', $secondaryEnvBefore, 'Process')
        }
    } finally {
        foreach ($envName in $discoveryEnvNames) {
            [Environment]::SetEnvironmentVariable($envName, $discoveryEnvBefore[$envName], 'Process')
        }
    }
} finally {
    if ($null -ne $backup) { Set-Content -LiteralPath $registryPath -Value $backup -Encoding utf8 }
    else { Remove-Item -LiteralPath $registryPath -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:LNCH_PROJECTS_DIR, Env:LNCH_CONFIG_DIR, Env:LNCH_RUNTIME_DIR, Env:LNCH_WT_LOG, Env:LNCH_NAME, Env:LNCH_PROMPT, Env:LNCH_YOLO, Env:LNCH_AGENT, Env:LNCH_FRESH, Env:LNCH_ROOT, Env:LNCH_VERBS, Env:LNCH_INSTALL_DIR, Env:LNCH_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
}

if ($script:fail -eq 0) {
    Write-Host 'RESULT: ALL PASS'
} else {
    Write-Host "RESULT: $script:fail FAILED"
    exit 1
}
