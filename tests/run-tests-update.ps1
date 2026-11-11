# Real local Git remote, real bootstrap subprocesses, and real agent processes.
# No network, shell profiles, registry hooks, or production checkout are changed.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('lnch-update-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $temp 'source'
$remote = Join-Path $temp 'remote.git'
$install = Join-Path $temp 'install with spaces'
$engine = (Get-Process -Id $PID).Path
$names = @('PATH', 'LNCH_PROJECTS_DIR', 'LNCH_CONFIG_DIR', 'LNCH_RUNTIME_DIR', 'LNCH_NO_UPDATE_CHECK', 'LNCH_DISCOVERY_HOME', 'LNCH_UPDATE_PAYLOAD', 'LNCH_UPDATE_OBSERVED')
$before = @{}
foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Check($label, $condition) {
    if (-not $condition) { throw "FAIL $label" }
    Write-Host "PASS $label"
}
function Invoke-TestGit([string[]]$Arguments) {
    & git @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fixture git failed: $Arguments" }
}
function Invoke-InstalledProcess([string]$File, [string]$Arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $engine
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $File + '" ' + $Arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'installed process timed out' }
        $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result + $stderr.Result }
        Write-Host $result.Output.TrimEnd()
        $result
    } finally { $process.Dispose() }
}
function Publish-Payload([string]$Value) {
    Set-Content -LiteralPath (Join-Path $source 'update-payload.txt') -Value $Value -Encoding ascii
    Invoke-TestGit @('-C', $source, 'add', 'update-payload.txt')
    Invoke-TestGit @('-C', $source, '-c', 'user.name=lnch-test', '-c', 'user.email=lnch@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', $Value)
    Invoke-TestGit @('-C', $source, 'push', '--quiet', 'origin', 'HEAD')
}
try {
    $bin = Join-Path $temp 'bin'
    $env:PATH = "$bin;$env:PATH"
    $env:LNCH_PROJECTS_DIR = Join-Path $temp 'projects'
    $env:LNCH_CONFIG_DIR = Join-Path $temp 'config'
    $env:LNCH_RUNTIME_DIR = Join-Path $temp 'runtime'
    $env:LNCH_DISCOVERY_HOME = Join-Path $temp 'home'
    $env:LNCH_UPDATE_PAYLOAD = Join-Path $install 'update-payload.txt'
    $env:LNCH_UPDATE_OBSERVED = Join-Path $temp 'agent-observed.txt'
    Remove-Item Env:LNCH_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $source, $bin, $env:LNCH_CONFIG_DIR, (Join-Path $env:LNCH_PROJECTS_DIR 'project\.git') -Force | Out-Null
    Copy-Item -Path (Join-Path $repo '*.ps1') -Destination $source
    Copy-Item -LiteralPath (Join-Path $repo 'agent-state-map.json') -Destination $source
    # Fail safely if launch-time updating accidentally runs shell installers.
    Set-Content -LiteralPath (Join-Path $source 'install.ps1') -Value "throw 'pre-launch update must not rewrite profiles'" -Encoding ascii
    Set-Content -LiteralPath (Join-Path $source 'install-cmd.ps1') -Value "throw 'pre-launch update must not rewrite the registry'" -Encoding ascii
    Set-Content -LiteralPath (Join-Path $source 'agents.json') -Value '{"observer":{"caps":{}}}' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $source 'update-payload.txt') -Value 'old' -Encoding ascii
    @'
@echo off
type "%LNCH_UPDATE_PAYLOAD%" > "%LNCH_UPDATE_OBSERVED%"
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $bin 'observer.cmd') -Encoding ascii
    Invoke-TestGit @('init', '--bare', '--quiet', $remote)
    Invoke-TestGit @('-C', $source, 'init', '--quiet', '-b', 'main')
    Invoke-TestGit @('-C', $source, 'add', '.')
    Invoke-TestGit @('-C', $source, '-c', 'user.name=lnch-test', '-c', 'user.email=lnch@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'initial')
    Invoke-TestGit @('-C', $source, 'remote', 'add', 'origin', $remote)
    Invoke-TestGit @('-C', $source, 'push', '--quiet', '--set-upstream', 'origin', 'main')
    Invoke-TestGit @('clone', '--quiet', '--branch', 'main', $remote, $install)
    . (Join-Path $install 'Lnch.ps1')
    @{ latest = "v$script:LnchVersion"; checked = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:LNCH_CONFIG_DIR 'update-cache.json')

    Publish-Payload 'inline-ready'
    $result = Invoke-InstalledProcess (Join-Path $install 'entry.ps1') 'project --agent observer --here'
    Check 'same-version remote changes are installed before inline agent starts' ($result.ExitCode -eq 0 -and (Get-Content -LiteralPath $env:LNCH_UPDATE_OBSERVED -Raw).Trim() -eq 'inline-ready')
    Check 'pre-launch update avoids shell installation side effects' ($result.Output -notmatch 'update failed')

    Publish-Payload 'managed-ready'
    $batch = New-Object Collections.ArrayList
    & ${function:lnch} project -Agent observer -LaunchBatch $batch | Out-Null
    Check 'parent handoff leaves update to final execution context' ((Get-Content -LiteralPath $env:LNCH_UPDATE_PAYLOAD -Raw).Trim() -eq 'inline-ready')
    $arguments = '-LaunchId ' + $batch[0].LaunchId + ' -RuntimeRoot "' + $env:LNCH_RUNTIME_DIR + '"'
    $result = Invoke-InstalledProcess (Join-Path $install 'Lnch-InTab.ps1') $arguments
    Check 'managed child installs changes before agent starts' ($result.ExitCode -eq 0 -and (Get-Content -LiteralPath $env:LNCH_UPDATE_OBSERVED -Raw).Trim() -eq 'managed-ready')

    Invoke-TestGit @('-C', $install, 'remote', 'set-url', 'origin', (Join-Path $temp 'missing.git'))
    Remove-Item -LiteralPath $env:LNCH_UPDATE_OBSERVED
    $result = Invoke-InstalledProcess (Join-Path $install 'entry.ps1') 'project --agent observer --here'
    Check 'real update failure is reported without preventing agent launch' ($result.ExitCode -eq 0 -and $result.Output -match 'lnch update failed' -and (Get-Content -LiteralPath $env:LNCH_UPDATE_OBSERVED -Raw).Trim() -eq 'managed-ready')
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'RESULT: UPDATE FLOW PASS'
exit 0
