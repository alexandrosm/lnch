$l = @($input | Where-Object { $_ })
if ($env:LNCH_TEST_FZF_LOG) {
    @($l) | Set-Content -LiteralPath $env:LNCH_TEST_FZF_LOG -Encoding utf8
}
if ($env:LNCH_TEST_FZF_MULTI) {
    @($l | Where-Object { $_ -like 'theta*' -or $_ -like 'alpha*' }) | Write-Output
    return
}
$t = @($l | Where-Object { $_ -like 'theta*' })[0]
if ($t) { Write-Output $t } elseif ($l.Count -gt 0) { Write-Output $l[0] }
