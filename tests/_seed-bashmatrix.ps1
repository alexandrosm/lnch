# Seeds fixture projects for tests/run-tests-bash.sh (PS-side, mount-proof).
param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path `
    "$Root\beta\.claude", "$Root\beta2", "$Root\jay" | Out-Null
Set-Content -LiteralPath "$Root\beta2\.ps-project.json" `
    -Value '{"agent":"aider","updated":"2026-01-01T00:00:00Z"}'
Set-Content -LiteralPath "$Root\jay\.ps-project.json" `
    -Value '{"agent":"bare","updated":"2026-01-01T00:00:00Z"}'
