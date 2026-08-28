# Installed-product acceptance: clean config, real child PowerShell, and terminal lifecycle.
param([string]$InstallDir = (Join-Path $env:USERPROFILE '.lnch'))
$ErrorActionPreference = 'Stop'

$InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path
if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'Lnch.ps1'))) {
    throw "installed Lnch.ps1 not found under $InstallDir"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lnch-installed-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$omega = [char]0x03A9
$cleanHome = Join-Path $testRoot ("home with spaces " + $omega)
$projectRoot = Join-Path $cleanHome 'projects'
$existingProject = Join-Path $projectRoot 'existing'
$explicitRoot = Join-Path $testRoot ("explicit root " + $omega)
$freshProject = Join-Path $explicitRoot 'fresh'
$configDir = Join-Path $testRoot 'config-that-does-not-exist'
$runtimeDir = Join-Path $testRoot 'runtime'
$bin = Join-Path $testRoot 'bin'
$agentLog = Join-Path $testRoot 'agent.log'
$wtLog = Join-Path $testRoot 'wt.log'
$sessionsFile = Join-Path $testRoot 'sessions.json'
$wtExe = Join-Path $bin 'wt.exe'
$compilerScript = Join-Path $testRoot 'compile-console-stub.ps1'
$systemRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
$windowsPowerShell = Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$runner = Join-Path $testRoot 'invoke-lnch.ps1'

$envNames = @(
    'PATH', 'LNCH_ACCEPTANCE_LOG', 'LNCH_ACCEPTANCE_WT_LOG', 'LNCH_CONFIG_DIR', 'LNCH_RUNTIME_DIR', 'LNCH_NO_UPDATE_CHECK',
    'LNCH_PROJECTS_DIR', 'LNCH_NAME', 'LNCH_PROMPT', 'LNCH_YOLO', 'LNCH_AGENT',
    'LNCH_FRESH', 'LNCH_ROOT', 'LNCH_VERBS'
)
$before = @{}
foreach ($name in $envNames) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

function New-LnchAcceptanceStub {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$OutputPath)
    $sourcePath = "$OutputPath.cs"
    [IO.File]::WriteAllText($sourcePath, $Source, (New-Object Text.UTF8Encoding($false)))
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $compilerScript -SourcePath $sourcePath -OutputPath $OutputPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "could not compile acceptance stub $OutputPath"
    }
}

try {
    New-Item -ItemType Directory -Force -Path $cleanHome, $existingProject, $explicitRoot, $bin | Out-Null
    @'
param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
Add-Type -Path $SourcePath -OutputAssembly $OutputPath -OutputType ConsoleApplication
'@ | Set-Content -LiteralPath $compilerScript -Encoding ascii
    git -C $existingProject init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { git -C $existingProject init | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw 'could not initialize acceptance project' }
    @{ agent = 'omp'; intent = 'existing acceptance project'; created = (Get-Date).ToString('o'); updated = (Get-Date).ToString('o') } |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $existingProject '.lnch.json') -Encoding utf8

    $agentStubSource = @'
using System;
using System.IO;
using System.Text;

public static class AgentStub
{
    public static int Main(string[] args)
    {
        string[] encodedArgs = new string[args.Length];
        for (int i = 0; i < args.Length; i++)
            encodedArgs[i] = Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i]));
        string record =
            "CWD64=" + Convert.ToBase64String(Encoding.UTF8.GetBytes(Directory.GetCurrentDirectory())) + Environment.NewLine +
            "ARGS64=" + String.Join(",", encodedArgs) + Environment.NewLine;
        File.AppendAllText(Environment.GetEnvironmentVariable("LNCH_ACCEPTANCE_LOG"), record, new UTF8Encoding(false));
        return 0;
    }
}
'@
    New-LnchAcceptanceStub -Source $agentStubSource -OutputPath (Join-Path $bin 'omp.exe')

    $wtStubSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class WtStub
{
    public static int Main(string[] args)
    {
        try
        {
            string log = Environment.GetEnvironmentVariable("LNCH_ACCEPTANCE_WT_LOG");
            string[] encoded = new string[args.Length];
            for (int i = 0; i < args.Length; i++)
                encoded[i] = Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i]));
            File.AppendAllText(log, String.Join(",", encoded) + Environment.NewLine, new UTF8Encoding(false));

            int directoryIndex = Array.IndexOf(args, "--startingDirectory");
            if (directoryIndex < 0) directoryIndex = Array.IndexOf(args, "-d");
            int noProfileIndex = Array.IndexOf(args, "-NoProfile");
            if (directoryIndex < 0 || noProfileIndex < 1)
                throw new InvalidOperationException("missing starting directory or child command");

            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = args[noProfileIndex - 1];
            start.Arguments = JoinQuoted(args, noProfileIndex);
            start.WorkingDirectory = args[directoryIndex + 1];
            start.UseShellExecute = false;
            Process child = Process.Start(start);
            child.WaitForExit();
            return child.ExitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
    }

    private static string JoinQuoted(string[] values, int start)
    {
        StringBuilder result = new StringBuilder();
        for (int i = start; i < values.Length; i++)
        {
            if (result.Length > 0) result.Append(' ');
            result.Append(Quote(values[i]));
        }
        return result.ToString();
    }

    private static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            return value;
        StringBuilder result = new StringBuilder();
        result.Append('"');
        int slashes = 0;
        foreach (char current in value)
        {
            if (current == '\\') { slashes++; continue; }
            if (current == '"')
            {
                result.Append('\\', slashes * 2 + 1);
                result.Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes);
            slashes = 0;
            result.Append(current);
        }
        result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
'@
    New-LnchAcceptanceStub -Source $wtStubSource -OutputPath $wtExe

    @'
param([string]$InstallDir, [string]$CleanHome, [string]$ExplicitRoot, [string]$SessionsFile)
$ErrorActionPreference = 'Stop'
. (Join-Path $InstallDir 'Lnch.ps1')
Set-Item Function:\Get-LnchLatestReleaseTag -Value { 'v-installed-acceptance' }
Set-Location -LiteralPath $CleanHome
lnch existing
$env:LNCH_PROJECTS_DIR = $ExplicitRoot
try {
    lnch -Name fresh -Prompt @('hello', 'installed') -Agent omp -TerminalMode tab -TerminalWindow lnch -TerminalProfile ('Power Shell ' + [char]0x03A9) -TerminalTitle '{project}:{agent}' -TabColor '#ABCDEF' -ColorScheme Campbell
} finally {
    Remove-Item Env:LNCH_PROJECTS_DIR -ErrorAction SilentlyContinue
}
lnch -Tabs -Json | Set-Content -LiteralPath $SessionsFile -Encoding utf8
$sessions = Get-Content -LiteralPath $SessionsFile -Raw | ConvertFrom-Json
$freshSession = @($sessions.Sessions | Where-Object Project -eq 'fresh')[0]
if (-not $freshSession) { throw 'fresh launch receipt was not recorded before restoration' }
& (Join-Path $InstallDir 'Lnch-InTab.ps1') -LaunchId $freshSession.LaunchId -RuntimeRoot $env:LNCH_RUNTIME_DIR
lnch -Tabs -Json | Set-Content -LiteralPath $SessionsFile -Encoding utf8
'@ | Set-Content -LiteralPath $runner -Encoding utf8

    [Environment]::SetEnvironmentVariable('PATH', "$bin;$($before['PATH'])", 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_ACCEPTANCE_LOG', $agentLog, 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_ACCEPTANCE_WT_LOG', $wtLog, 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_CONFIG_DIR', $configDir, 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_RUNTIME_DIR', $runtimeDir, 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_NO_UPDATE_CHECK', $null, 'Process')
    [Environment]::SetEnvironmentVariable('LNCH_PROJECTS_DIR', $null, 'Process')
    foreach ($name in @('LNCH_NAME', 'LNCH_PROMPT', 'LNCH_YOLO', 'LNCH_AGENT', 'LNCH_FRESH', 'LNCH_ROOT', 'LNCH_VERBS')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    $shell = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    if (-not $shell) { $shell = @(Get-Command powershell.exe -CommandType Application -ErrorAction Stop) | Select-Object -First 1 }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $runner -InstallDir $InstallDir -CleanHome $cleanHome -ExplicitRoot $explicitRoot -SessionsFile $sessionsFile 2>&1)
        $journeyExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($journeyExitCode -ne 0) { throw "installed journey process failed:`n$($output -join [Environment]::NewLine)" }

    if (-not (Test-Path -LiteralPath $agentLog -PathType Leaf)) { throw 'agent stub was not launched by the child process' }
    $agentLines = @(Get-Content -LiteralPath $agentLog)
    $agentCwds = @($agentLines | Where-Object { $_ -like 'CWD64=*' } | ForEach-Object {
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Substring(6)))
    })
    $agentArguments = @($agentLines | Where-Object { $_ -like 'ARGS64=*' } | ForEach-Object {
        $encoded = $_.Substring(7)
        if ($encoded) { ,@($encoded -split ',' | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }) } else { ,@() }
    })
    if (@($agentCwds | Where-Object { $_ -eq $existingProject }).Count -ne 1) { throw "existing child used the wrong cwd: $($agentCwds -join '; ')" }
    if (@($agentCwds | Where-Object { $_ -eq $freshProject }).Count -ne 2) { throw "fresh child and restored tab used the wrong cwd: $($agentCwds -join '; ')" }
    $resumeInvocations = @($agentArguments | Where-Object { $_.Count -eq 1 -and $_[0] -eq '-c' })
    $freshInvocations = @($agentArguments | Where-Object { $_.Count -eq 1 -and $_[0] -eq 'hello installed' })
    if ($resumeInvocations.Count -ne 2) { throw "existing and restored projects did not resume exactly once each" }
    if ($freshInvocations.Count -ne 1) { throw 'fresh prompt was replayed during terminal restoration' }
    if (Test-Path -LiteralPath (Join-Path $existingProject 'projects\existing')) { throw 'recursive project path was created' }
    if (-not (Test-Path -LiteralPath (Join-Path $freshProject '.git') -PathType Container)) { throw 'fresh explicit-root project was not initialized' }
    if (-not (Test-Path -LiteralPath (Join-Path $freshProject 'AGENTS.md') -PathType Leaf)) { throw 'fresh project scaffold was not installed' }
    $metadata = Get-Content -LiteralPath (Join-Path $freshProject '.lnch.json') -Raw | ConvertFrom-Json
    if ($metadata.agent -ne 'omp' -or $metadata.intent -ne 'hello installed') { throw 'fresh project metadata did not preserve agent and prompt' }

    if (-not (Test-Path -LiteralPath (Join-Path $configDir 'update-cache.json') -PathType Leaf)) { throw 'first-run update cache was not written' }
    $joinedOutput = $output -join ' '
    $existingOpened = $joinedOutput -match '-> existing opened in (?:wt|Windows Terminal)'
    $freshOpened = $joinedOutput -match '-> fresh opened in (?:wt|Windows Terminal)'
    if (-not $existingOpened -or -not $freshOpened) {
        throw "parent launches did not complete:`n$($output -join [Environment]::NewLine)"
    }

    $wtCalls = @(Get-Content -LiteralPath $wtLog | ForEach-Object {
        $decoded = @($_ -split ',' | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
        Write-Output (, $decoded)
    })
    if ($wtCalls.Count -ne 2) { throw "expected two wt calls, found $($wtCalls.Count)" }
    $freshWt = @($wtCalls | Where-Object { $_ -contains 'fresh:omp' })[0]
    if (-not $freshWt) { throw 'fresh terminal title was not emitted' }
    foreach ($required in @('--inheritEnvironment', '--window', 'lnch', '--profile', ('Power Shell ' + [char]0x03A9), '--tabColor', '#ABCDEF', '--colorScheme', 'Campbell')) {
        if ($freshWt -notcontains $required) { throw "fresh terminal invocation omitted $required" }
    }

    $receipts = @(Get-ChildItem -LiteralPath (Join-Path $runtimeDir 'sessions') -File -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($receipts.Count -ne 2) { throw "expected two terminal receipts, found $($receipts.Count)" }
    $receiptValues = @($receipts | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    if (@($receiptValues | Where-Object State -ne 'agent-exited').Count -ne 0) { throw 'terminal receipts did not reach agent-exited' }
    if (@($receiptValues.Directory | Sort-Object -Unique).Count -ne 2) { throw 'terminal receipts did not retain both project directories' }
    $sessionDocument = Get-Content -LiteralPath $sessionsFile -Raw | ConvertFrom-Json
    if ($sessionDocument.Schema -ne 1 -or @($sessionDocument.Sessions).Count -ne 2) { throw 'lnch -Tabs did not report both terminal sessions' }
    $pending = @(Get-ChildItem -LiteralPath (Join-Path $runtimeDir 'launches') -File -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($pending.Count -ne 0) { throw 'consumed launch contexts were not removed' }

    Write-Host 'PASS installed clean-config cache write'
    Write-Host 'PASS installed real child processes'
    Write-Host 'PASS installed dynamic and explicit roots'
    Write-Host 'PASS installed paths with spaces and Unicode'
    Write-Host 'PASS installed launch receipt lifecycle'
    Write-Host 'PASS installed terminal presentation policy'
    Write-Host 'PASS installed public terminal session ledger'
    Write-Host 'PASS installed existing resume and fresh prompt'
    Write-Host 'PASS installed Windows Terminal restoration resumes without replay'
    Write-Host 'RESULT: INSTALLED JOURNEY PASS'
} finally {
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
