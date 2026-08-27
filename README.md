# lnch

[![ci](https://github.com/alexandrosm/lnch/actions/workflows/ci.yml/badge.svg)](https://github.com/alexandrosm/lnch/actions/workflows/ci.yml)

One word from any shell to a running AI coding agent inside a fresh, git-initialized project.

```powershell
lnch my-app build a snake game
```

creates the project folder, runs `git init`, seeds an **AGENTS.md** skeleton (the cross-harness instruction standard) with `CLAUDE.md`/`GEMINI.md` pointers, opens a **new tab in the current Windows Terminal window**, locks the tab title to the project name, and launches your agent with `build a snake game` as its initial prompt.

## Install

**PowerShell** — one command:

```powershell
irm https://raw.githubusercontent.com/alexandrosm/lnch/main/bootstrap.ps1 | iex
```

Pin a release and SHA256-verify it:

```powershell
& ~\.lnch\bootstrap.ps1 -Version v1.1.0   # after initial install
```

**bash / zsh (Git Bash, WSL)** — one command:

```bash
curl -fsSL https://raw.githubusercontent.com/alexandrosm/lnch/main/bootstrap.sh | bash
```

**cmd.exe** — one command:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/alexandrosm/lnch/main/bootstrap.ps1 | iex"
```

All three download the repo to `~\.lnch` and wire up that shell's face (the PowerShell bootstrap also wires bash when it detects it). Re-running any of them updates an existing install. Uninstall per shell: `uninstall.ps1`, `uninstall.sh`, `install-cmd.ps1 -Remove` from the installed folder.

Existing project-starter installs migrate automatically: profile/rc markers are replaced, `%APPDATA%\project-starter` moves to `%APPDATA%\lnch`, and `.ps-project.json` files become `.lnch.json` on first access. The old `start` override is not retained.

## Shells

| Shell | Entry | Notes |
|---|---|---|
| PowerShell 5.1 / 7+ | native function | `-Yolo` / `-Here`; stays in project dir after `-Here` sessions |
| bash / zsh (Git Bash, WSL) | sourced shim | `--yolo` / `--here`; cwd not preserved after `--here` (child process) |
| cmd.exe | doskey macro via HKCU AutoRun | **interactive sessions only** — scripted `cmd /c lnch ...` is untouched |

All three drive one engine (`Lnch.ps1`), so resume detection, the capability registry, metadata, and pickers behave identically everywhere.

## Usage

| Command | Behavior |
|---|---|
| `lnch` | Multi-select existing projects, then launch each in its own tab (fzf if installed, else numbered list) |
| `lnch <name>` | Create (or reopen) `<root>\<name>`. Reopening **auto-resumes** with the agent that last ran there |
| `lnch <name> words...` | Extra words become the agent's initial prompt *and* are saved as the project's intent |
| `lnch <name> :<verb>` | Capability verbs (see below) — may appear anywhere among the words |
| `lnch <name> ... -Yolo` / `--yolo` | Shorthand for `:yolo` |
| `lnch <name> ... -Here` / `--here` | Launch in the current window instead of a new tab |
| `lnch -Agent <name>` / `--agent` | Force the agent for a new project |
| `lnch -SetDefaultAgent <name>` / `--default-agent` | Persist the default agent (`none` clears) |
| `lnch -Version` / `--version` / `-v` | Print engine version |
| `lnch -Doctor` / `--doctor` | Audit tools, agents, capability matrix, hooks |
| `lnch -Discover` / `--discover` | Locate the executable and private datastore candidates for all seven built-in agents |
| `lnch -Discover -Json` / `--discover --json` | Emit the versioned discovery document for automation |


Bare `lnch` is the multi-project launcher. In fzf, press `Tab` to toggle as many projects as you want, then `Enter`; otherwise the built-in TUI provides checkbox-style selection. Non-interactive/limited hosts retain the `1,3-5` / `all` fallback. Each selected project follows its normal agent/resume metadata and opens in its own tab in the current Windows Terminal window.

### Project picker UI

Without fzf, bare `lnch` opens a full-screen multi-select TUI with project name, owning agent, saved intent, relative activity, selected count, and a scrollable viewport:

| Key | Action |
|---|---|
| `Up` / `Down` | Move |
| `Space` | Toggle project |
| `A` / `N` | Select all / none |
| `Enter` | Launch selected projects (or highlighted project when none selected) |
| `Esc` / `Q` | Cancel |

With fzf, the launcher enables rounded borders, multi-select, inline status, selection markers, and `Ctrl-A`/`Ctrl-D` all/none bindings. Set `LNCH_NO_FZF=1` to force the built-in TUI.
New projects choose their agent in this order: explicit `-Agent` → persisted default → sole installed agent → **interactive picker over installed agents** → omp fallback.

By default, the project root is the `projects` subfolder of your **current working directory** at the moment you invoke `lnch` (for example, from `D:\work`, `lnch api` creates `D:\work\projects\api`). Set `LNCH_PROJECTS_DIR` to override that root explicitly.

### ⚠️ `-Yolo` safety

`-Yolo` appends each agent's auto-approval flag (e.g. `--approval-mode yolo`, `--dangerously-skip-permissions`). The agent will then **execute commands without asking you**. It is opt-in per invocation by design — never the default — and its effect is limited to the session it flags.

## Capabilities (the tent)

One verb vocabulary, normalized across every agent. Each agent's registry entry declares which verbs it implements and how; unsupported combinations warn and degrade gracefully instead of surfacing raw CLI errors.

| Verb | Meaning |
|---|---|
| `:pick` | Resume this project, choosing among past sessions |
| `:yolo` | Auto-approve everything (same as `-Yolo`) |
| `:plan` | Planning approvals where supported |
| `:edits` | Auto-accept file edits only (Claude) |
| `:model <value>` | Pin the model for this session |

Example: `lnch my-app :plan sketch the API` — planning approvals on whatever agent owns `my-app`.

`lnch -Doctor` renders the full capability matrix: every installed agent × every verb.

## Resume: how the agent is chosen

Every launch writes `<project>\.lnch.json`. On reopen:

1. That file's `agent` wins (exact recall).
2. Otherwise fingerprints: `.claude/` or `CLAUDE.md` -> `claude -c`; `.codex/` -> `codex resume --last`; `.gemini/` -> `gemini`.
3. Otherwise omp's own session buckets (`~/.omp/agent/sessions/*-<name>-*`) -> `omp -c`.
4. Default: `omp`.

Known limits: Gemini CLI has no trustworthy resume flag, so it relaunches fresh; Codex cannot take a prompt alongside resume, so extra words are dropped with a warning.

## Agents

Built-in registry: **omp, claude, codex, gemini, aider, opencode, qwen**. An optional `agents.json` next to `Lnch.ps1` merges over the built-ins using the v2 caps shape:

```json
{
  "claude": {
    "takesPromptOnResume": true,
    "caps": {
      "resume":      { "args": ["-c"] },
      "resume-pick": { "args": ["--resume"] },
      "mode:yolo":   { "args": ["--dangerously-skip-permissions"] },
      "mode:plan":   { "args": ["--permission-mode", "plan"] }
    }
  }
}
```

v0.3-style entries (`continueArgs` / `yoloFlags` / `takesPromptOnContinue`) auto-migrate.

Run `lnch -Doctor` for the live capability matrix on your machine.

## Datastore discovery

`lnch --discover` performs a read-only Level Zero inventory for **omp, claude, codex, gemini, aider, opencode, and qwen**. It resolves native environment overrides, OMP profiles, XDG roots, split Qwen config/runtime roots, OpenCode config/data/cache/state roots, executable paths, agent versions, existence, path type, and readability. Status is `ready`, `binary-only`, `store-only`, or `absent`; one unreadable or malformed location does not block the other agents.

```powershell
lnch --discover
lnch --discover --json
$inventory = Get-LnchAgentDatastores
```

Discovery never reads credential values or modifies an agent store. Aider is reported as partial because its chat history and repository-map cache are project-local rather than indexed by a global datastore.

## Agent state map

[`agent-state-map.json`](agent-state-map.json) records the user/project roots, canonical transcripts, indexes, memories, checkpoints, caches, credential boundaries, resume commands, and native import/export routes for every built-in agent. It is migration discovery data, not a copy list: credentials are always excluded, mutable databases are read-only locators, caches are rebuilt, and approval/provider settings require semantic translation.

Current native routes captured by the map: OMP imports Claude and Codex sessions; Codex imports Claude/Cursor setup and recent chats; OpenCode provides a native JSON export/import round trip; Qwen exports normalized JSON/JSONL. Gemini and Aider require source-format translation.

## Per-project metadata & user config

`.lnch.json` in each project root stores `{agent, intent, created, updated}` — plain JSON, safe to edit.

User config lives in `%APPDATA%\lnch\config.json`:

```json
{
  "defaultAgent": "omp",
  "postCreate": ["npm init -y", "git config commit.template .gitmessage"]
}
```

`postCreate` commands run inside freshly created project directories (failures warn, never block).

## Requirements

Windows. PowerShell 5.1 or 7+ (engine). Optional: Windows Terminal (`wt`) for new-tab launches, `fzf` for the picker, Git Bash for the bash shim, any agent executables you register.

## Development

Clone, then two bundled suites, both stubbed (touch only temp dirs + a redirected config dir):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1              # expanded engine matrix
pwsh       -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-crossshell.ps1   # shims + cmd lifecycle (18 checks)
```

PSScriptAnalyzer gates every push (settings: `tests/PSScriptAnalyzerSettings.psd1`). CI runs everything on `windows-latest`; tag pushes are packaged into GitHub Releases with SHA256SUMS (`scripts/release-local.ps1` reproduces that locally).
