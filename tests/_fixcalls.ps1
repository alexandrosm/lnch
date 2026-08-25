# One-shot: make engine suite resolve `start` via captured function object.
$f = 'C:\tmp\project-starter\tests\run-tests.ps1'
$L = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $f)
$idx = -1
for ($i = 0; $i -lt $L.Count; $i++) {
    if ($L[$i] -match 'Start-Project\.ps1''\)') { $idx = $i; break }
}
if ($idx -lt 0) { throw 'dot-source anchor not found' }
$L.Insert($idx + 1, '    $global:__startFn = ${function:start}')
$L.Insert($idx + 2, '    if (-not $__startFn) { throw "start function failed to load" }')
$replaced = 0
for ($i = 0; $i -lt $L.Count; $i++) {
    # call sites: "= start ", "= start -", or standalone indented "start "
    if ($L[$i] -match '^(.*?)= start ') {
        $L[$i] = $L[$i] -replace '= start ', '= & $__startFn '
        $replaced++
    } elseif ($L[$i] -match '^(\s*)start (-|\.\.|zeta|alpha|beta|gamma|theta|epsilon|iota|jay|kappa|eta)') {
        $L[$i] = $L[$i] -replace '^(\s*)start ', '$1& $__startFn '
        $replaced++
    }
}
Set-Content -LiteralPath $f -Value $L
Write-Output ("patched call-sites=" + $replaced)
