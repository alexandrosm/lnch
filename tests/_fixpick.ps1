# One-shot: :pick replaces base resume args instead of stacking.
$f = 'C:\tmp\project-starter\Start-Project.ps1'
$L = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $f)
$idxA = -1
for ($i = 0; $i -lt $L.Count; $i++) {
    if ($L[$i] -match '\$rcap = \$p\.Caps\[''resume''\]') { $idxA = $i; break }
}
if ($idxA -lt 0) { throw 'resume-cap anchor not found' }
$start = $idxA - 1   # 'if ($resuming) {'
$end   = $idxA + 3   # closing '}' of the if/elseif chain
if ($L[$end] -notmatch '^\s*}\s*$') { throw ("unexpected block shape at line " + ($end + 1)) }

$replacement = @(
    '    $wantsPick = @($verbs | Where-Object { $_.Name -in @(''pick'', ''resume-pick'') }).Count -gt 0',
    '    if ($resuming -and -not $wantsPick) {',
    '        $rcap = $p.Caps[''resume'']',
    '        if ($rcap) { $agentArgs += $rcap.Args }',
    '        elseif ($p.Caps.Count -gt 0) { Write-Warning "$agent declares no resume capability; starting a fresh session" }',
    '    }'
)
$L.RemoveRange($start, $end - $start + 1)
$L.InsertRange($start, [string[]]$replacement)
Set-Content -LiteralPath $f -Value $L
Write-Output PATCHED
