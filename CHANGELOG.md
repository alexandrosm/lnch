# Changelog

## v0.3.0 - unreleased

- Built-in agent fleet grows to seven: omp, claude, codex, gemini, aider, opencode, qwen (best-effort flags documented; unknowns warn instead of guessing).
- New projects ask which agent to launch (picker over *installed* agents) instead of silently choosing omp.
- Persistent default agent: `start -SetDefaultAgent <name>` / `--default-agent`; stored in `%APPDATA%\project-starter\config.json`.
- Per-invocation override: `-Agent <name>` / `--agent <name>`.
- `start -Doctor` / `--doctor`: audits tools, agents, projects root writability, cmd AutoRun hook, shell rc lines.
- PowerShell Gallery module manifest (`ProjectStarter.psd1`) prepared.
- GitHub Actions CI running both test suites on windows-latest.

## v0.2.0

- bash/zsh shim (`shell/start.sh`, `install.sh`, `uninstall.sh`) with dependency-free POSIX->Windows path conversion.
- cmd shim (`shell/start-cli.cmd`, `install-cmd.ps1`, interactive-only doskey macro via HKCU AutoRun; `/c`+`/k` guarded).
- Cross-shell suite `tests/run-tests-crossshell.ps1` (15 checks).

## v0.1.0

- Initial release: create/reuse projects under `%OMP_PROJECTS_DIR%` (default `C:\projects`), `git init -b main`,
  resume detection (.ps-project.json marker -> .claude/.codex/.gemini fingerprints -> omp session buckets),
  intent metadata, agent registry (`agents.json`), `-Yolo`, project picker (fzf/numbered),
  Windows Terminal tab handoff, per-shell installers/uninstaller, MIT license,
  engine matrix `tests/run-tests.ps1` (27 checks, dual-shell verified).
