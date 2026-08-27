# lnch

[![ci](https://github.com/alexandrosm/lnch/actions/workflows/ci.yml/badge.svg)](https://github.com/alexandrosm/lnch/actions/workflows/ci.yml)

One word from any shell to a running AI coding agent inside a fresh, git-initialized project.

```powershell
lnch my-app build a snake game
```

creates the project folder, runs `git init`, seeds an **AGENTS.md** skeleton (the cross-harness instruction standard) with `CLAUDE.md`/`GEMINI.md` pointers, opens a **new tab in the most recently used Windows Terminal window** by default, locks the tab title to the project name, and launches your agent with `build a snake game` as its initial prompt.

## Install

**PowerShell** — one command:

```powershell
irm https://raw.githubusercontent.com/alexandrosm/lnch/main/bootstrap.ps1 | iex
```

Pin a release and SHA256-verify it:

```powershell
& ~\.lnch\bootstrap.ps1 -Version v1.4.0   # after initial install
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
| `lnch <name> -TerminalMode <mode>` / `--terminal <mode>` | Choose `tab`, `split-right`, `split-down`, `new-window`, or `inline` |
| `lnch <name> -TerminalWindow <target>` / `--window <target>` | Target `last`, `new`, the shared `lnch` window, a stable per-`project` window, or a custom Windows Terminal window name/ID |
| `--profile`, `--title-template`, `--tab-color`, `--color-scheme` | Override terminal presentation for one launch |
| `lnch -Tabs [-Prune] [-Json]` / `lnch --tabs [--prune] [--json]` | Inspect the child-process/Windows Terminal runtime ledger |
| `lnch -Version` / `--version` / `-v` | Print engine version |
| `lnch -Doctor` / `--doctor` | Audit tools, agents, capability matrix, hooks |
| `lnch -Discover` / `--discover` | Locate the executable and private datastore candidates for all seven built-in agents |
| `lnch -Discover -Json` / `--discover --json` | Emit the versioned discovery document for automation |
| `lnch -Sessions [-Name <project>] [-Agent <agent>] [-IncludeChildren] [-Json]` / `--sessions [project] [--include-children]` | List normalized native sessions; child/subagent sessions are hidden by default |
| `lnch -Transcript <agent:id> [-Json]` / `--transcript <agent:id>` | Explicitly decode one native transcript into the normalized event schema |


Bare `lnch` is the multi-project launcher. In fzf, press `Tab` to toggle as many projects as you want, then `Enter`; otherwise the built-in TUI provides checkbox-style selection. Non-interactive/limited hosts retain the `1,3-5` / `all` fallback. Each selected project follows its normal agent/resume metadata. Compatible targets are submitted to `wt.exe` as one semicolon-delimited batch instead of one process per project.

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

By default, the project root is the `projects` subfolder of your **current working directory** at the moment you invoke `lnch` (for example, from `D:\work`, `lnch api` creates `D:\work\projects\api`). Set `LNCH_PROJECTS_DIR` to override that root explicitly. The resolved root is captured before a Windows Terminal handoff and reused inside the child tab; changing the child tab's working directory never creates a recursive `<project>\projects\<project>` path.

## Windows Terminal policy and lifecycle

`lnch` treats Windows Terminal as a transport adapter rather than an implicit shell side effect. Parent and child exchange a schema-versioned JSON envelope under `%LOCALAPPDATA%\lnch\runtime\launches` (override with `LNCH_RUNTIME_DIR`); the child consumes that file, verifies the exact project directory, and publishes lifecycle receipts under `runtime\sessions`. Prompt arrays, capability verbs, resolved root, selected agent, launch policy, and a unique launch ID therefore survive spaces, Unicode, and concurrent launches without process-global `LNCH_NAME`/`LNCH_PROMPT` variables.

Per-launch PowerShell parameters and their bash/cmd long flags:

| Policy | Values |
|---|---|
| `-TerminalMode` / `--terminal` | `tab` (default), `split-right`, `split-down`, `new-window`, `inline` |
| `-TerminalWindow` / `--window` | `last` (default), `new`, `lnch`, `project`, or a custom Windows Terminal name/integer ID |
| `-TerminalProfile` / `--profile` | `current` (default; uses `WT_PROFILE_ID`), `default`, profile name, or GUID |
| `-TerminalTitle` / `--title-template` | Template with `{project}`, `{agent}`, and `{status}` (`new` or `resume`) |
| `-TabColor` / `--tab-color` | `#RGB` or `#RRGGBB` |
| `-ColorScheme` / `--color-scheme` | Existing Windows Terminal color-scheme name |
| `-ReadinessTimeoutMs` / `--readiness-timeout` | Child receipt timeout, `0`–`60000` ms; default `5000` |

Persistent defaults live in `%APPDATA%\lnch\config.json` and command-line values win:

```json
{
  "defaultAgent": "omp",
  "terminal": {
    "mode": "tab",
    "window": "last",
    "profile": "current",
    "titleTemplate": "{project} · {agent} · {status}",
    "tabColor": "#336699",
    "agentColors": {
      "claude": "#D97757",
      "codex": "#10A37F"
    },
    "colorScheme": "Campbell",
    "readinessTimeoutMs": 5000
  }
}
```

New-tab actions pass `--inheritEnvironment` explicitly. Split-pane actions use Windows Terminal's split command contract, which does not expose that flag. `lnch` waits for a child receipt before reporting a launch ready; an accepted command with no receipt produces a warning containing the launch ID instead of a false success.

`lnch --tabs` maps project, agent, child PID, `WT_SESSION`, launch ID, window target, mode, and lifecycle state. `--prune` removes old exited/stale receipts. The [Windows Terminal CLI](https://learn.microsoft.com/windows/terminal/command-line-arguments) exposes `focus-tab` only by volatile numeric index and no public tab-identity enumeration API, so `lnch` deliberately does not claim it can refocus a logical project tab.

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

`lnch --discover` performs a read-only Level Zero and One inventory for **omp, claude, codex, gemini, aider, opencode, and qwen**. Level Zero resolves native environment overrides, OMP profiles, XDG roots, split Qwen config/runtime roots, OpenCode config/data/cache/state roots, executable paths, agent versions, existence, path type, and readability.

Level One extracts each agent's known projects from native indexes, JSONL headers, ownership markers, project-local fingerprints, or a supported native listing command. Paths are canonicalized and reconciled into one workspace entry with a provisional `workspace:<hash>` identity, source agents, native keys, evidence sources, last activity, existence, and confidence. Unresolvable encoded records remain visible under their owning agent instead of being silently discarded.

```powershell
lnch --discover
lnch --discover --json          # schema 2: Agents[] plus reconciled Projects[]
$stores = Get-LnchAgentDatastores
$byAgent = Get-LnchAgentProjects
$projectInventory = Get-LnchProjectInventory
```

Set `LNCH_DISCOVERY_ROOTS` to a platform-separated list of additional bounded roots for project-local agents and fingerprints. Discovery never reads credential values or modifies an agent store. Aider remains partial because it has no global project registry. OpenCode is partial when only its current SQLite store remains and no compatible `opencode` CLI is installed.

## Sessions and normalized transcripts

Level Two catalogs native sessions for all seven agents without copying them. Session schema `1` includes `agent:id` reference, native ID, reconciled project identity/path, title, timestamps, parent/fork, model, archived/active state when knowable, transcript path/availability, native resume command, source, and confidence.

```powershell
lnch --sessions
lnch --sessions api --agent claude --json
$sessions = Get-LnchSessionInventory
```

The default catalog contains user-facing root sessions. Child/subagent threads remain attached through `ParentId`, `Kind: child`, agent metadata, and each root's `ChildCount`, but are shown only on request:

```powershell
lnch --sessions --agent codex --include-children
$all = Get-LnchSessionInventory -Agent codex -IncludeChildren
```

This distinction matters for multi-agent runtimes: one user Codex session can spawn hundreds of internal worker threads, which are not independent user sessions.

Level Three decodes one explicitly selected native transcript into ordered events: messages, reasoning summaries, tool calls/results, model changes, compaction, reset, and system boundaries. Every event retains source type/line and parent identity where available; unsupported native records become counted loss entries rather than disappearing silently.

```powershell
lnch --transcript omp:01abc... --json
$transcript = Get-LnchSessionTranscript -Reference 'claude:<session-id>'
```

Transcript output can contain source prompts, file contents, command output, and credentials previously exposed to an agent. It is never emitted by ordinary discovery and should be handled as confidential data. Aider's Markdown source necessarily loses structured tools and timestamps; OpenCode current-database decoding uses its native exporter when installed.

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

Windows. PowerShell 5.1 or 7+ (engine). Optional: Windows Terminal (`wt`) for managed tab/pane/window launches (otherwise `lnch` falls back inline), `fzf` for the picker, Git Bash for the bash shim, any agent executables you register.

## Development

Clone, then run the bundled engine, terminal-adapter, cross-shell, and installed-product suites. All write only to temporary directories and redirected configuration:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-terminal.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-crossshell.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-installed.ps1 -InstallDir .
```

The installed journey starts from a missing config directory, launches existing and fresh projects through real child PowerShell processes, and checks dynamic/explicit roots, spaces and Unicode, terminal policy arguments, envelope consumption, readiness/exit receipts, the public ledger, and native resume. CI runs it against both the checked-out payload and the remotely bootstrapped install. On an interactive Windows desktop, `tests\run-smoke-terminal-live.ps1` additionally opens a short-lived real `wt.exe` window and verifies its child lifecycle end to end.

PSScriptAnalyzer gates every push (settings: `tests/PSScriptAnalyzerSettings.psd1`). CI runs everything on `windows-latest`; tag pushes are packaged into GitHub Releases with SHA256SUMS (`scripts/release-local.ps1` reproduces that locally).
