$l = @($input | Where-Object { $_ })
$t = @($l | Where-Object { $_ -like 'theta*' })[0]
if ($t) { Write-Output $t } elseif ($l.Count -gt 0) { Write-Output $l[0] }
