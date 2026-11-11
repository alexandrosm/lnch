# lnch

[![ci](https://github.com/alexandrosm/lnch/actions/workflows/ci.yml/badge.svg)](https://github.com/alexandrosm/lnch/actions/workflows/ci.yml)

One word from any shell to a running AI coding agent inside a fresh, git-initialized project.

```powershell
lnch my-app build a snake game
```

creates the project folder, runs `git init`, seeds an **AGENTS.md** skeleton (the cross-harness instruction standard) with `CLAUDE.md`/`GEMINI.md` pointers, and launches your agent **in the current terminal** with `build a snake game` as its initial prompt. Add `--terminal tab` to open a new Windows Terminal tab and monitor the managed launch in the invoking tab's dashboard.

## Install

**PowerShell** — one command:

```powershell
irm https://raw.githubusercontent.com/alexandrosm/lnch/main/bootstrap.ps1 | iex
```

Pin a release and SHA256-verify it:

```powershell
& ~\.lnch\bootstrap.ps1 -Version v1.5.0   # after initial install
```

**bash / zsh (Git Bash, WSL)** — one command:

```bash
curl -fsSL https://raw.githubusercontent.com/alexandrosm/lnch/main/bootstrap.sh | bash
```

**cmd.exe** — one command:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/alexandrosm/lnch/main/bootstrap.ps1 | iex"
```

All three download the repo to `~\.lnch` and wire up that shell's face (the PowerShell bootstrap also wires bash when it detects it). Re-running any of them updates an existing install. The PowerShell launch path also runs the bootstrap before every agent launch, without a cached-version gate. Uninstall per shell: `uninstall.ps1`, `uninstall.sh`, `install-cmd.ps1 -Remove` from the installed folder.

The PowerShell bootstrap validates the downloaded payload before copying it into place. Updates replace shipped files without deleting the installation directory, preserving custom `agents.json` and any projects stored beneath it. Checksum or malformed-archive failures leave the existing installation untouched; failed Git pulls stop before profile installation. Downloads use an invocation-specific temporary directory that is cleaned on success or failure.

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
| `lnch` | Open the live dashboard; select a project and press `Enter` to open it in a new tab |
| `lnch <name>` | Create (or reopen) `<root>\<name>` and auto-resume its owning agent in the current terminal by default |
| `lnch <name> words...` | Extra words become the agent's initial prompt *and* are saved as the project's intent |
| `lnch <name> :<verb>` | Capability verbs (see below) — may appear anywhere among the words |
| `lnch <name> ... -Yolo` / `--yolo` | Shorthand for `:yolo` |
| `lnch <name> ... -Here` / `--here` | Force the current terminal, overriding a saved terminal mode |
| `lnch <name> -Agent <name>` / `--agent` | Force the agent for a new project |
| `lnch <name> -GitName <name> -GitEmail <email>` / `--git-name ... --git-email ...` | Set the new repository's local Git author identity explicitly |
| `lnch -SetDefaultAgent <name>` / `--default-agent` | Persist the default agent (`none` clears) |
| `lnch <name> -TerminalMode <mode>` / `--terminal <mode>` | Choose `inline` (default for named launches), `tab`, `split-right`, `split-down`, or `new-window` |
| `lnch <name> -TerminalBackend <backend>` / `--backend <backend>` | Choose `wt` (default), `auto`, `agentterm`, or `inline` |
| `lnch <name> -TerminalWindow <target>` / `--window <target>` | Target `last`, `new`, the shared `lnch` window, a stable per-`project` window, or a custom Windows Terminal window name/ID |
| `--profile`, `--title-template`, `--tab-color`, `--color-scheme` | Override terminal presentation for one launch |
| `lnch -Tabs [-Prune] [-Json]` / `lnch --tabs [--prune] [--json]` | Inspect the child-process and terminal-identity runtime ledger |
| `lnch -Top [-Json]` / `lnch --top [--json]` | Open the live project/agent dashboard, or emit one normalized JSON snapshot |
| `lnch <name> -NoDashboard` / `--no-dashboard` | Return to the invoking shell after handoff instead of opening the dashboard |
| `lnch -Version` / `--version` / `-v` | Print engine version |
| `lnch -Doctor` / `--doctor` | Audit tools, agents, capability matrix, hooks |
| `lnch -Discover` / `--discover` | Locate the executable and private datastore candidates for all seven built-in agents |
| `lnch -Discover -Json` / `--discover --json` | Emit the versioned discovery document for automation |
| `lnch -Sessions [-Name <project>] [-Agent <agent>] [-IncludeChildren] [-Json]` / `--sessions [project] [--include-children]` | List normalized native sessions; child/subagent sessions are hidden by default |
| `lnch -Transcript <agent:id> [-Json]` / `--transcript <agent:id>` | Explicitly decode one native transcript into the normalized event schema |

### Project creation

New projects choose their agent in this order: explicit `-Agent` → persisted default → sole installed agent → **interactive picker over installed agents** → omp fallback.

Every repository initialized by lnch receives repository-local `user.name` and `user.email` values; lnch never changes global Git configuration. In an interactive shell, the identity picker offers the configured `gitIdentity` default, global Git identity, `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`, the authenticated GitHub CLI profile (privacy-safe `users.noreply.github.com` and public-email choices), and custom name/email entry. Press `Enter` for the first choice. Non-interactive launches use the first valid default; `-GitName` plus `-GitEmail` (or `--git-name` plus `--git-email`) always win. Set `LNCH_NO_GH_IDENTITY=1` to skip GitHub profile discovery.

### Agent top dashboard

Bare `lnch` and `lnch --top` open the same full-screen dashboard. Select an existing project with `Up` / `Down` and press `Enter` to resume its owning agent in a new tab without leaving the dashboard. Managed named launches also enter the dashboard when the invoking host is interactive; use `--no-dashboard` or `LNCH_NO_DASHBOARD=1` to opt out. Inline sessions (the named-launch default, or `--here`) keep the tab for the agent. `lnch --json` and `lnch --top --json` emit the same normalized snapshot without entering the TUI.

The dashboard combines the primary project root with every configured secondary root, preserving the exact root for each row so projects with the same folder name remain independently launchable. It groups each active receipt-rooted process tree by project and refreshes CPU, working/private memory, process count, cumulative I/O, lifecycle state, pinned launch model, and project disk usage. Telemetry collection and Git identity discovery run in background PowerShell pipelines, so selection, resize, and form input repaint immediately instead of waiting for process discovery or `gh`. CPU is normalized across logical processors. The first frame defers recursive disk scans so large project roots appear immediately; unknown values render as `--`. Press `R` to measure disk usage, cache it for 60 seconds, and refresh the frame. Receipt-backed states are `starting`, `running`, `completed`, `failed`, and `stale`; projects without a receipt are `idle`.

Disk usage is the recursive total of readable regular-file lengths; reparse points are skipped to avoid cycles.

Model is shown only when it was explicitly pinned with `:model`; otherwise it remains `unknown`. Cost remains `unknown` until an agent/provider adapter can supply reported usage or an attributable token estimate—lnch never renders a fabricated `$0.00`.

| Key | Action |
|---|---|
| `Up` / `Down` | Select a project outside the form; move between fields inside it |
| `N` | Open the new-project form without leaving the dashboard |
| Type, `Backspace` | Edit the focused project-name or custom-identity field |
| `Tab` / `Shift-Tab` | Move between project, agent, identity, and custom name/email fields |
| `Left` / `Right` | Cycle installed agents or discovered Git identities on the focused choice field |
| `Enter` | Open the selected existing project in a new tab; inside the form, validate and create the new project in the configured managed terminal |
| `R` | Measure project disk usage and refresh immediately |
| `Q` / `Esc` | Leave the dashboard and return to the invoking shell |

By default, the primary project root is the `projects` subfolder of your **current working directory** at the moment you invoke `lnch` (for example, from `D:\work`, `lnch api` creates `D:\work\projects\api`). Set `LNCH_PROJECTS_DIR` to override that primary root. Add `secondaryProjectRoots` to `%APPDATA%\lnch\config.json`, or a path-separator-delimited `LNCH_SECONDARY_PROJECTS_DIRS`, to discover existing projects elsewhere. Named launches search the primary root first and then secondaries; new projects are always created in the primary root. The selected root is captured before terminal handoff, so changing the terminal's working directory never creates a recursive `<project>\projects\<project>` path.

## Terminal backends and lifecycle

Named launches (`lnch <name>`) default to the current terminal. Use `lnch <name> --terminal tab` (PowerShell: `-TerminalMode tab`) to opt into a new tab. Explicit terminal modes and saved `terminal.mode` settings take precedence for named launches; `--here` forces inline execution. Dashboard `Enter` explicitly requests a new tab, even if the saved mode is `inline`. The new-project form uses the configured managed terminal mode (default `tab`).

Inline launches run the agent and post-create hooks inside the project, then restore the invoking directory even if agent startup fails. Consecutive `lnch <name>` commands therefore reuse the same default project root rather than creating nested `projects` directories.

Inline CLI launches preserve the agent's exit code through the PowerShell entry script and bash/cmd shims, so shell conditionals can detect failures. Managed child processes also return the agent's exit code when they finish; the parent managed launch reports terminal handoff, not the eventual agent result.

Immediately before the agent process starts, lnch runs the full update synchronously in the final execution context. Inline launches update in the invoking shell; managed launches update inside the new tab after handoff. Git checkouts run `git pull --ff-only` even when the version number is unchanged. Archive installs resolve the latest tagged release and SHA256-verify its download; a failed release lookup never silently falls back to unverified `main` during a launch. Concurrent launches serialize through `%APPDATA%\lnch\update.lock`. This path updates the payload without rewriting shell profiles or registry hooks. Success or failure is reported, then the requested agent starts either way. Set `LNCH_NO_UPDATE_CHECK=1` to disable automatic updating.

For managed launches, `lnch` treats terminal hosts as replaceable transport adapters. Parent and child exchange a schema-versioned JSON envelope under `%LOCALAPPDATA%\lnch\runtime\launches` (override with `LNCH_RUNTIME_DIR`); the child consumes that file, verifies the exact project directory, and publishes lifecycle receipts under `runtime\sessions`. Prompt arrays, capability verbs, resolved root, selected agent, launch policy, and a unique launch ID therefore survive spaces, Unicode, and concurrent launches without process-global `LNCH_NAME`/`LNCH_PROMPT` variables.

Windows Terminal may replay a tab's original command after an application or machine restart, long after the one-shot launch envelope was consumed. In that path `lnch` rebuilds a resume-only context from the durable lifecycle receipt: project/root/agent identity is preserved, while the original prompt, fresh-project state, and capability verbs are never replayed. If that launch process is still active, the duplicate restored command exits cleanly instead of starting a second agent.

If a managed launch or restored tab points to a project directory that has been deleted or moved, it exits with an error and records a failed launch. It never recreates a replacement workspace at the stale path.

Per-launch PowerShell parameters and their bash/cmd long flags:

| Policy | Values |
|---|---|
| `-TerminalBackend` / `--backend` | `wt` (default), `auto`, `agentterm`, `inline` |
| `-TerminalMode` / `--terminal` | `inline` (named-launch default), `tab` (picker/dashboard default), `split-right`, `split-down`, `new-window` |
| `-TerminalWindow` / `--window` | `last` (default), `new`, `lnch`, `project`, or a custom Windows Terminal name/integer ID |
| `-TerminalProfile` / `--profile` | `current` (default; uses `WT_PROFILE_ID`), `default`, profile name, or GUID |
| `-TerminalTitle` / `--title-template` | Template with `{project}`, `{agent}`, and `{status}` (`new` or `resume`) |
| `-TabColor` / `--tab-color` | `#RGB` or `#RRGGBB` |
| `-ColorScheme` / `--color-scheme` | Existing Windows Terminal color-scheme name |
| `-ReadinessTimeoutMs` / `--readiness-timeout` | Child receipt timeout, `0`–`60000` ms; default `5000` |
| `-AgentTermPath` / `--agentterm-path` | Explicit `agentterm.exe`; `LNCH_AGENTTERM_PATH` is the environment override |
| `-AgentTermHome` / `--agentterm-home` | AgentTerm state root; defaults to `AGENTTERM_HOME`, then `%USERPROFILE%` |
| `-AgentTermPort` / `--agentterm-port` | AgentTerm control port; default `7685` |

Persistent settings live in `%APPDATA%\lnch\config.json` and command-line values win. Omit `terminal.mode` to keep the defaults above, or add `"mode": "tab"` to opt named launches into tabs persistently:

```json
{
  "defaultAgent": "omp",
  "gitIdentity": {
    "name": "Alex Hero",
    "email": "alex@example.com"
  },
  "terminal": {
    "backend": "wt",
    "window": "last",
    "profile": "current",
    "titleTemplate": "{project} · {agent} · {status}",
    "tabColor": "#336699",
    "agentColors": {
      "claude": "#D97757",
      "codex": "#10A37F"
    },
    "colorScheme": "Campbell",
    "agentTermPath": "C:\\tools\\AgentTerm\\agentterm.exe",
    "agentTermHome": "C:\\agentterm-state",
    "agentTermPort": 7685,
    "readinessTimeoutMs": 5000
  }
}
```

Windows Terminal-compatible launches use the app hosting the current session, not blindly `wt.exe` from `PATH`. Within a `WT_SESSION`, lnch walks its process ancestry; when it finds an unpackaged `WindowsTerminal.exe`/WTX host, it invokes that exact executable, keeping new tabs in the running fork. Packaged sessions or shells without a compatible ancestor fall back to `wt` from `PATH`. The backend remains `wt` because the CLI contract is shared. Choosing a backend alone does not change the terminal mode. Explicit `backend: auto` retains capability detection: a running AgentTerm instance wins, otherwise the same WT-compatible resolution is used, then an installed AgentTerm, then inline fallback.

The selected WT-compatible executable receives `--inheritEnvironment` for new-tab actions. Split-pane actions use the shared Windows Terminal CLI contract, which does not expose that flag. AgentTerm launches use its loopback-only bearer-authenticated API and record the returned stable tab ID, session UUID, and shell PID before submitting the child command. `lnch` waits for a child receipt before reporting a launch ready; an accepted command with no receipt produces a warning containing the launch ID instead of a false success.

`lnch --tabs` maps project, agent, child PID, terminal backend, backend-specific identity, `WT_SESSION` where applicable, launch ID, window target, mode, and lifecycle state. `--prune` removes old exited/stale receipts. The [Windows Terminal CLI](https://learn.microsoft.com/windows/terminal/command-line-arguments) exposes `focus-tab` only by volatile numeric index; AgentTerm exposes stable tab and session identities through its control plane.

### ⚠️ `-Yolo` safety

`-Yolo` appends each agent's auto-approval flag (e.g. `--approval-mode yolo`, `--dangerously-skip-permissions`). The agent will then **execute commands without asking you**. It is opt-in per invocation by design — never the default — and its effect is limited to the session it flags.

## Capabilities (the tent)

One verb vocabulary, normalized across every agent. Each agent's registry entry declares which verbs it implements and how; unsupported combinations warn and degrade gracefully instead of surfacing raw CLI errors.

| Verb | Meaning |
|---|---|
| `:resume` | Explicit form of the default resume behavior; does not add a second resume flag |
| `:pick` | Resume this project, choosing among past sessions |
| `:yolo` | Auto-approve everything (same as `-Yolo`) |
| `:plan` | Planning approvals where supported |
| `:edits` | Auto-accept file edits only (Claude) |
| `:model <value>` | Pin the model for this session |

Example: `lnch my-app :plan sketch the API` — planning approvals on whatever agent owns `my-app`.

`:pick` (or `:resume-pick`) takes precedence over `:resume` when both are supplied.

`lnch -Doctor` renders the capability matrix and checks project-root writability using a uniquely named, self-cleaning temporary file.

## Resume: how the agent is chosen

An explicit `-Agent` / `--agent` overrides automatic selection, including when reopening a project. Otherwise:

1. Compare native session activity for the **exact workspace path** with `.lnch.json`'s confirmed `lastUsed` timestamp; the newest agent wins. This includes sessions started outside lnch.
2. If there is no newer native activity, use the recorded agent. Legacy metadata without `lastUsed` is a fallback, not proof that it is newer than native sessions.
3. Without either, fall back to `.claude/`, `.codex/`, or `.gemini/` configuration directories.
4. Finally, use the configured default agent, or `omp`.

Generated `CLAUDE.md` files and matching folder names under another project root are not usage evidence. Child sessions from Claude, Codex, and OpenCode do not replace the last root agent. An unavailable remembered executable fails visibly rather than silently switching agents.

The dashboard uses the same selection rules for idle projects, sharing a native-history inventory for up to 15 seconds; launches always inspect fresh history. Active managed projects continue to display their running agents.

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

Project-local discovery includes the primary root and all configured secondary roots. Set `LNCH_DISCOVERY_ROOTS` to a platform-separated list of additional bounded roots for project-local agents and fingerprints. Changes to the current directory or effective project roots invalidate the short-lived session cache. Discovery never reads credential values or modifies an agent store. Aider remains partial because it has no global project registry. OpenCode is partial when only its current SQLite store remains and no compatible `opencode` CLI is installed.

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

`.lnch.json` in each project root stores `{agent, intent, created, updated, lastUsed}` — plain JSON, safe to edit. After an agent exits successfully, `lastUsed` records when that invocation started. Failed launches and queued terminal handoffs do not overwrite the remembered agent; an older session finishing later does not displace a newer confirmed invocation. Existing extra fields are preserved.

User config lives in `%APPDATA%\lnch\config.json`:

```json
{
  "defaultAgent": "omp",
  "gitIdentity": {
    "name": "Alex Hero",
    "email": "alex@example.com"
  },
  "secondaryProjectRoots": ["C:\\projects"],
  "postCreate": ["npm init -y", "git config commit.template .gitmessage"]
}
```

`secondaryProjectRoots` are searched in order after the primary root and are included in dashboard snapshots, tab completion, project discovery, and session discovery. `postCreate` commands run inside freshly created project directories (failures warn, never block).

## Requirements

Windows. PowerShell 5.1 or 7+ (engine). Optional: Windows Terminal (`wt`), a compatible unpackaged fork such as WTX, or AgentTerm for managed terminal launches (named commands otherwise fall back inline; dashboard launches require a managed backend), `fzf` for agent selection, Git Bash for the bash shim, and any agent executables you register.

## Development

Clone, then run the bundled engine, agent-selection, update, terminal-adapter, bootstrap, cross-shell, and installed-product suites. All use temporary workspaces and redirected configuration; the engine matrix temporarily replaces `agents.json` and restores it afterward, so run the suites sequentially:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-agent-selection.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-agent-selection.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-update.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-update.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-terminal.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-bootstrap.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-bootstrap.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-crossshell.ps1
pwsh       -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-installed.ps1 -InstallDir .
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-smoke-agentterm-live.ps1 -AgentTermPath C:\path\to\agentterm.exe
```

The installed journey uses isolated configuration, launches existing and fresh projects through real child PowerShell processes, restores a consumed Windows Terminal command as a prompt-free resume, and checks dynamic/explicit roots, spaces and Unicode, terminal policy arguments, envelope consumption, readiness/exit receipts, the public ledger, and native resume. CI runs it against both the checked-out payload and the remotely bootstrapped install. On an interactive Windows desktop, `tests\run-smoke-terminal-live.ps1` exercises the current WT-compatible host executable, while `tests\run-smoke-agentterm-live.ps1` exercises a real AgentTerm control plane and takeover-safe shell persistence.

The offline PowerShell bootstrap suite uses local release archives and isolated installer fixtures to verify project/config preservation, checksum and malformed-archive rejection, failed Git updates, temporary-file cleanup, and execution of the installed engine.

The update suite uses a real local Git remote and installed child processes: same-version commits must reach the agent before inline and managed launches, and an actual failed pull must still permit launch. Agent-selection regressions cover stale metadata, native activity, child-session exclusion, duplicate folder names, scaffold files, explicit overrides, failed starts, handoffs, and dashboard consistency.

PSScriptAnalyzer gates every push (settings: `tests/PSScriptAnalyzerSettings.psd1`). CI runs everything on `windows-latest`; tag pushes are packaged into GitHub Releases with SHA256SUMS (`scripts/release-local.ps1` reproduces that locally).
