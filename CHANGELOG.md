# Changelog

## v0.5.0

- **Capability dispatch ("the tent")**: one verb vocabulary normalized across agents. Leading-or-inline `:pick`, `:plan`, `:edits`, `:yolo`, `:model <value>` tokens map onto per-agent argument sets from the registry; unsupported verbs warn and skip gracefully. `-Yolo` becomes shorthand for `:yolo`.
- Registry v2: `agents.json` entries use a `caps` map (`resume`, `resume-pick`, `mode:*`, `model`); v0.3 legacy keys (`continueArgs`/`yoloFlags`/`takesPromptOnContinue`) auto-migrate.
- `start -Doctor` renders a capability matrix: every installed agent x every verb, yes/dash.
- `:pick` replaces base-resume args instead of stacking them.

## v0.4.0

- One-command remote installs per shell: `irm .../bootstrap.ps1 | iex` (PowerShell/cmd), `curl -fsSL .../bootstrap.sh | bash` (bash/zsh). Installs to `~\.project-starter`; idempotent re-runs update an existing clone; `-Version <tag>` pins a release and SHA256-verifies it against the published SHA256SUMS.
- Built-in agent fleet grows to seven: omp, claude, codex, gemini, aider, opencode, qwen (best-effort flags documented; unknowns warn instead of guessing).
- New projects ask which agent to launch (picker over *installed* agents) instead of silently choosing omp.
- Persistent default agent: `start -SetDefaultAgent <name>` / `--default-agent`, stored in `%APPDATA%\project-starter\config.json`.
- Per-invocation override: `-Agent <name>` / `--agent <name>`.
- `start -Doctor` / `--doctor`: audits tools, agents, projects root writability, cmd AutoRun hook, shell rc lines.
- `start -Version`: prints the engine version; lightweight cached update check against GitHub releases (disable with `OMP_NO_UPDATE_CHECK=1`).
- PowerShell Gallery module manifest (`ProjectStarter.psd1`) prepared.
- GitHub Actions CI runs both stubbed suites plus a remote-bootstrap smoke test on windows-latest. Tag pushes are packaged into a GitHub Release with SHA256SUMS by `.github/workflows/release.yml`.

## v0.3.0

- cmd shim (`shell/start-cli.cmd`, `install-cmd.ps1`, interactive-only doskey macro via HKCU AutoRun; `/c`+`/k` guarded).
- Cross-shell suite `tests/run-tests-crossshell.ps1`.

## v0.2.0

- bash/zsh shim (`shell/start.sh`, `install.sh`, `uninstall.sh`) with dependency-free POSIX->Windows path conversion.

## v0.1.0

- Initial release: create/reuse projects under `%OMP_PROJECTS_DIR%` (default `C:\projects`), `git init -b main`,
  resume detection (.ps-project.json marker -> .claude/.codex/.gemini fingerprints -> omp session buckets),
  intent metadata, project picker (fzf/numbered), Windows Terminal tab handoff,
  MIT license, engine test matrix.
