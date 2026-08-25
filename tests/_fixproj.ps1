# One-shot: restore missing OMP_PROJECTS_DIR assignment after PATH healing.
$f = 'C:\tmp\project-starter\tests\run-tests.ps1'
$L = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $f)
$idx = -1
for ($i = 0; $i -lt $L.Count; $i++) {
    if ($L[$i] -match '^\$env:PATH = "\$StubBin;\$gitCmd') { $idx = $i; break }
}
if ($idx -lt 0) { throw 'PATH anchor not found' }
if (($L | Where-Object { $_ -match '^\$env:OMP_PROJECTS_DIR = \$Projects' })) {
    Write-Output 'already-present'; return
}
$L.Insert($idx + 1, '')
$L.Insert($idx + 2, '$env:OMP_PROJECTS_DIR = $Projects')
Set-Content -LiteralPath $f -Value $L
Write-Output PATCHED
