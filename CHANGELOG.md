# Changelog

## v0.5.4

- Windows Terminal tab titles are locked to the project folder name with `--title <project> --suppressApplicationTitle`, preventing shells/agents from overwriting them.

## v0.5.3

- Default project root is now `<current working directory>\projects` at invocation time; `OMP_PROJECTS_DIR` remains the explicit override.
- Picker, doctor, tab completion, and project creation share one root resolver.

## v0.5.2

- Fresh-project tab handoffs preserve first-session state, so the child launches the agent normally instead of incorrectly adding resume flags (`omp -c`) before a session exists.
- Capability verbs survive the terminal handoff via a structured JSON payload; `-Yolo`/`:yolo` deduplicate correctly.
- Windows Terminal launches target the current window (`wt -w 0 new-tab`) instead of spawning a separate window; failure falls back inline.

## v0.5.1

- New projects are seeded with **AGENTS.md** (the cross-harness instruction standard: overview / build & test / code style / security notes) plus `CLAUDE.md` (`@AGENTS.md` import) and `GEMINI.md` pointers.
- **Post-create hooks**: add `"postCreate": ["command1", ...]` to `%APPDATA%\project-starter\config.json`; each command runs inside the fresh project directory after creation (failures warn, never block).
- Capability verbs (`:pick`, `:yolo`, `:plan`, ...) are now recognized **anywhere** among prompt words via a known-verb whitelist; unknown `:tokens` pass through untouched.
- `start --version` / `-v` through all shell faces.

## v0.5.0

- **Capability dispatch ("the tent")**: one verb vocabulary normalized across agents. Registry v2 `caps` map per agent; v0.3 legacy keys auto-migrate. Unsupported verbs warn and skip gracefully.
- `start -Doctor` renders a capability matrix: every installed agent x every verb.

## v0.4.0

- One-command remote installs per shell (`bootstrap.ps1` / `bootstrap.sh`), installing to `~\.project-starter`; idempotent re-runs update an existing clone; version-pinned + SHA256-verified downloads.
- Built-in agent fleet grows to seven: omp, claude, codex, gemini, aider, opencode, qwen.
- New projects ask which agent to launch (picker over *installed* agents); persisted default agent in `%APPDATA%\project-starter\config.json`.
- `start -Doctor`, `start -Version`, cached update check (`OMP_NO_UPDATE_CHECK=1` disables).
- PowerShell Gallery manifest; GitHub Actions CI with PSScriptAnalyzer gate, both stubbed suites and a remote-bootstrap smoke test on windows-latest.

## v0.3.0

- cmd shim (`shell/start-cli.cmd`, `install-cmd.ps1`, interactive-only doskey macro via HKCU AutoRun; `/c`+`/k` guarded).

## v0.2.0

- bash/zsh shim (`shell/start.sh`, `install.sh`, `uninstall.sh`) with dependency-free POSIX->Windows path conversion.

## v0.1.0

- Initial release: create/reuse projects under `%OMP_PROJECTS_DIR%` (default `C:\projects`), `git init -b main`,
  resume detection (.ps-project.json marker -> .claude/.codex/.gemini fingerprints -> omp session buckets),
  intent metadata, project picker (fzf/numbered), Windows Terminal tab handoff,
  MIT license, engine test matrix.
