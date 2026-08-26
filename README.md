# project-starter

[![ci](https://github.com/alexandrosm/project-starter/actions/workflows/ci.yml/badge.svg)](https://github.com/alexandrosm/project-starter/actions/workflows/ci.yml)

One word from any shell to a running AI coding agent inside a fresh, git-initialized project.

```powershell
start my-app build a snake game
```

creates the project folder, runs `git init`, seeds an **AGENTS.md** skeleton (the cross-harness instruction standard) with `CLAUDE.md`/`GEMINI.md` pointers, opens a **new Windows Terminal tab**, and launches your agent with `build a snake game` as its initial prompt.

## Install

**PowerShell** — one command:

```powershell
irm https://raw.githubusercontent.com/alexandrosm/project-starter/main/bootstrap.ps1 | iex
```

Pin a release and SHA256-verify it:

```powershell
& ~\.project-starter\bootstrap.ps1 -Version v0.5.1   # after initial install
```

**bash / zsh (Git Bash, WSL)** — one command:

```bash
curl -fsSL https://raw.githubusercontent.com/alexandrosm/project-starter/main/bootstrap.sh | bash
```

**cmd.exe** — one command:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/alexandrosm/project-starter/main/bootstrap.ps1 | iex"
```

All three download the repo to `~\.project-starter` and wire up that shell's face (the PowerShell bootstrap also wires bash when it detects it). Re-running any of them updates an existing install. Uninstall per shell: `uninstall.ps1`, `uninstall.sh`, `install-cmd.ps1 -Remove` from the installed folder.

## Shells

| Shell | Entry | Notes |
|---|---|---|
| PowerShell 5.1 / 7+ | native function | `-Yolo` / `-Here`; stays in project dir after `-Here` sessions |
| bash / zsh (Git Bash, WSL) | sourced shim | `--yolo` / `--here`; cwd not preserved after `--here` (child process) |
| cmd.exe | doskey macro via HKCU AutoRun | **interactive sessions only** — scripted `cmd /c start ...` is untouched |

All three drive one engine (`Start-Project.ps1`), so resume detection, the capability registry, metadata, and pickers behave identically everywhere.

## Usage

| Command | Behavior |
|---|---|
| `start` | Pick an existing project (fzf if installed, else numbered list); shows saved intent + last-active time |
| `start <name>` | Create (or reopen) `<root>\<name>`. Reopening **auto-resumes** with the agent that last ran there |
| `start <name> words...` | Extra words become the agent's initial prompt *and* are saved as the project's intent |
| `start <name> :<verb>` | Capability verbs (see below) — may appear anywhere among the words |
| `start <name> ... -Yolo` / `--yolo` | Shorthand for `:yolo` |
| `start <name> ... -Here` / `--here` | Launch in the current window instead of a new tab |
| `start -Agent <name>` / `--agent` | Force the agent for a new project |
| `start -SetDefaultAgent <name>` / `--default-agent` | Persist the default agent (`none` clears) |
| `start -Version` / `--version` / `-v` | Print engine version |
| `start -Doctor` / `--doctor` | Audit tools, agents, capability matrix, hooks |

New projects choose their agent in this order: explicit `-Agent` → persisted default → sole installed agent → **interactive picker over installed agents** → omp fallback.

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

Example: `start my-app :plan sketch the API` — planning approvals on whatever agent owns `my-app`.

`start -Doctor` renders the full capability matrix: every installed agent × every verb.

## Resume: how the agent is chosen

Every launch writes `<project>\.ps-project.json`. On reopen:

1. That file's `agent` wins (exact recall).
2. Otherwise fingerprints: `.claude/` or `CLAUDE.md` -> `claude -c`; `.codex/` -> `codex resume --last`; `.gemini/` -> `gemini`.
3. Otherwise omp's own session buckets (`~/.omp/agent/sessions/*-<name>-*`) -> `omp -c`.
4. Default: `omp`.

Known limits: Gemini CLI has no trustworthy resume flag, so it relaunches fresh; Codex cannot take a prompt alongside resume, so extra words are dropped with a warning.

## Agents

Built-in registry: **omp, claude, codex, gemini, aider, opencode, qwen**. An optional `agents.json` next to `Start-Project.ps1` merges over the built-ins using the v2 caps shape:

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

Run `start -Doctor` for the live capability matrix on your machine.

## Per-project metadata & user config

`.ps-project.json` in each project root stores `{agent, intent, created, updated}` — plain JSON, safe to edit.

User config lives in `%APPDATA%\project-starter\config.json`:

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
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1              # engine matrix (34 checks)
pwsh       -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-crossshell.ps1   # shims + cmd lifecycle (15 checks)
```

PSScriptAnalyzer gates every push (settings: `tests/PSScriptAnalyzerSettings.psd1`). CI runs everything on `windows-latest`; tag pushes are packaged into GitHub Releases with SHA256SUMS (`scripts/release-local.ps1` reproduces that locally).
