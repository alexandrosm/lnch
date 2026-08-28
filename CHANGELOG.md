# Changelog

## v1.5.0

- Added AgentTerm as a managed terminal backend with `auto`/`wt`/`agentterm`/`inline` selection, bearer-authenticated tab creation, stable tab/session/process identities, startup command handoff, existing-instance reuse, multi-project tab launches, and backend-aware runtime receipts.
- Added a real AgentTerm end-to-end smoke covering cwd, prompt, launch-envelope consumption, child readiness/exit, and identity agreement between lnch and AgentTerm.
- Added live recursive disk-usage totals to the fzf, full-screen, and numbered project pickers, with human-readable sizes and reparse-point-safe traversal.
- Fixed Windows Terminal session restoration after a tab had consumed its one-shot launch envelope. Restored commands now reconstruct a resume-only context from the durable receipt, never replay the original prompt or capability verbs, and suppress duplicate starts while the original launch process is still active.

## v1.4.0

- Replaced ad hoc new-tab environment variables with a dedicated Windows Terminal adapter and schema-versioned, per-launch JSON envelopes. Prompts, capability verbs, agent choice, resolved roots, and concurrent launches now cross the parent/child boundary without shared mutable variables.
- Added configurable terminal modes (`tab`, right/down splits, new window, inline), window targeting (`last`, `new`, shared `lnch`, stable per-project, custom names/IDs), profile selection, title templates, tab/agent colors, color schemes, and child-readiness timeouts.
- Added runtime lifecycle receipts and `lnch --tabs [--prune] [--json]`, mapping launch IDs to projects, agents, child PIDs, `WT_SESSION`, window/mode, readiness, and exit state. Logical tab focusing remains deliberately unsupported because Windows Terminal exposes only volatile numeric tab indices.
- Batched compatible multi-project launches into one semicolon-delimited `wt.exe` command and made new-tab environment inheritance explicit.
- Expanded CI with adapter contracts and installed-product acceptance covering existing/fresh sessions, dynamic/explicit roots, spaces and Unicode, presentation arguments, envelope consumption, readiness, receipts, and the public ledger. A manual live smoke exercises the real `wt.exe`.

## v1.3.2

- Fixed new-tab launches with a dynamic root by carrying the parent's resolved root into the child process, preventing accidental `<project>\\projects\\<project>` creation and false fresh sessions.
- Fixed first-run update checks by creating `%APPDATA%\\lnch` before writing `update-cache.json`.

## v1.3.1

- Fixed Codex session inflation by classifying spawned subagent threads as children, excluding them from default session/project counts, exposing parent/agent metadata and root `ChildCount`, and adding the explicit `--include-children` view.

## v1.3.0

- Added Level Two unified session catalogs and Level Three explicit transcript normalization across all seven agents, including project reconciliation, native resume metadata, messages, reasoning, tool calls/results, model/compaction/reset events, provenance, loss accounting, CLI/PowerShell APIs, and short-lived read caching.

## v1.2.0

- Added Level One project discovery for all seven agents: native project extraction, unresolved-record retention, path normalization, cross-agent workspace reconciliation, provisional stable identities, per-agent and unified PowerShell APIs, and schema-2 human/JSON output.

## v1.1.0

- Added read-only Level Zero discovery for all seven built-in agents: executable/version detection, environment and profile-aware datastore resolution, existence/readability health, human output, and a versioned JSON document across PowerShell, bash/zsh, and cmd.
- Added an evidence-backed, machine-readable state map for all seven built-in agents, with explicit transcript, config, memory, checkpoint, index, cache, credential, and native interop policies.

## v1.0.3

- The Bash shim now resolves WSL Linux-home scripts through `wslpath` when dispatching to Windows PowerShell, while native `pwsh` keeps native paths.
- Cross-shell tests source the production shim instead of maintaining a duplicate implementation.

## v1.0.2

- Tagged Bash installs extract from a private temporary directory, so they work from any current directory and match the release archive's root layout.
- Release archives preserve LF line endings for every shell script.

## v1.0.1

- Bash bootstrap checksum parsing no longer depends on `awk`; shell built-in `read` consumes `sha256sum`/SHA256SUMS output.

## v1.0.0

- Renamed command and product from project-starter / `start` to **lnch**. Native PowerShell/cmd `start` behavior is restored; no compatibility alias remains.
- Repository, module, source files, shell/cmd shims, environment variables (`LNCH_*`), install root (`~\.lnch`), user config (`%APPDATA%\lnch`), metadata (`.lnch.json`), release assets, URLs, and UI branding all move under lnch.
- One-time migrations remove old profile/rc/AutoRun hooks, move legacy config, and rename `.ps-project.json` metadata on first access.

## v0.7.0

- Bare `lnch` now has a polished dependency-free full-screen multi-select TUI: alternate-screen rendering, ANSI color, metadata-rich rows (agent, intent, activity), selected count, scrollable viewport, and keyboard controls for move/toggle/all/none/launch/cancel.
- fzf mode receives a styled 85%-height multi-select interface with border, padding, inline status, markers, and all/none bindings; `LNCH_NO_FZF=1` forces the built-in picker.
- Real PTY verification selects two projects and asserts exact two-tab fan-out.

## v0.6.0

- Bare `lnch` is now a multi-project launcher: fzf uses `--multi` (`Tab` toggles, `Enter` accepts), and the numbered fallback accepts lists/ranges such as `1,3-5` or `all`.
- Every selected project launches through the normal agent/resume path into its own same-window Windows Terminal tab.
- Native and bash-face suites assert exact multi-tab fan-out; parser tests cover ranges, deduplication, and all-selection.

## v0.5.4

- Windows Terminal tab titles are locked to the project folder name with `--title <project> --suppressApplicationTitle`, preventing shells/agents from overwriting them.

## v0.5.3

- Default project root is now `<current working directory>\projects` at invocation time; `LNCH_PROJECTS_DIR` remains the explicit override.
- Picker, doctor, tab completion, and project creation share one root resolver.

## v0.5.2

- Fresh-project tab handoffs preserve first-session state, so the child launches the agent normally instead of incorrectly adding resume flags (`omp -c`) before a session exists.
- Capability verbs survive the terminal handoff via a structured JSON payload; `-Yolo`/`:yolo` deduplicate correctly.
- Windows Terminal launches target the current window (`wt -w 0 new-tab`) instead of spawning a separate window; failure falls back inline.

## v0.5.1

- New projects are seeded with **AGENTS.md** (the cross-harness instruction standard: overview / build & test / code style / security notes) plus `CLAUDE.md` (`@AGENTS.md` import) and `GEMINI.md` pointers.
- **Post-create hooks**: add `"postCreate": ["command1", ...]` to `%APPDATA%\lnch\config.json`; each command runs inside the fresh project directory after creation (failures warn, never block).
- Capability verbs (`:pick`, `:yolo`, `:plan`, ...) are now recognized **anywhere** among prompt words via a known-verb whitelist; unknown `:tokens` pass through untouched.
- `lnch --version` / `-v` through all shell faces.

## v0.5.0

- **Capability dispatch ("the tent")**: one verb vocabulary normalized across agents. Registry v2 `caps` map per agent; v0.3 legacy keys auto-migrate. Unsupported verbs warn and skip gracefully.
- `lnch -Doctor` renders a capability matrix: every installed agent x every verb.

## v0.4.0

- One-command remote installs per shell (`bootstrap.ps1` / `bootstrap.sh`), installing to `~\.lnch`; idempotent re-runs update an existing clone; version-pinned + SHA256-verified downloads.
- Built-in agent fleet grows to seven: omp, claude, codex, gemini, aider, opencode, qwen.
- New projects ask which agent to launch (picker over *installed* agents); persisted default agent in `%APPDATA%\lnch\config.json`.
- `lnch -Doctor`, `lnch -Version`, cached update check (`LNCH_NO_UPDATE_CHECK=1` disables).
- PowerShell Gallery manifest; GitHub Actions CI with PSScriptAnalyzer gate, both stubbed suites and a remote-bootstrap smoke test on windows-latest.

## v0.3.0

- cmd shim (`shell/lnch-cli.cmd`, `install-cmd.ps1`, interactive-only doskey macro via HKCU AutoRun; `/c`+`/k` guarded).

## v0.2.0

- bash/zsh shim (`shell/lnch.sh`, `install.sh`, `uninstall.sh`) with dependency-free POSIX->Windows path conversion.

## v0.1.0

- Initial release: create/reuse projects under `%LNCH_PROJECTS_DIR%` (default `C:\projects`), `git init -b main`,
  resume detection (.lnch.json marker -> .claude/.codex/.gemini fingerprints -> omp session buckets),
  intent metadata, project picker (fzf/numbered), Windows Terminal tab handoff,
  MIT license, engine test matrix.
