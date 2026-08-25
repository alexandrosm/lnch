# project-starter

One word from any shell to a running AI coding agent inside a fresh, git-initialized project.

```powershell
start my-app build a snake game
```

creates the project folder, runs `git init`, opens a **new Windows Terminal tab**, and launches your agent with `build a snake game` as its initial prompt.

## Shells

| Shell | Install | Notes |
|---|---|---|
| PowerShell 5.1 / 7+ | `powershell -ExecutionPolicy Bypass -File install.ps1` | Native function; `-Yolo` / `-Here`; stays in project dir after `-Here` sessions |
| bash / zsh (Git Bash, WSL) | `bash install.sh` | Thin shim into the same engine; `--yolo` / `--here`; cwd not preserved after `--here` (child process) |
| cmd.exe | `powershell -ExecutionPolicy Bypass -File install-cmd.ps1` | doskey macro via HKCU AutoRun; **interactive sessions only** — scripted `cmd /c start ...` is untouched |

All three drive one engine (`Start-Project.ps1`), so resume detection, the agent registry, metadata, and pickers behave identically everywhere. Uninstall per shell: `uninstall.ps1`, `uninstall.sh`, `install-cmd.ps1 -Remove`.

## Usage

| Command | Behavior |
|---|---|
| `start` | Pick an existing project (fzf if installed, else numbered list); shows saved intent + last-active time |
| `start <name>` | Create (or reopen) `<root>\<name>`. Reopening **auto-resumes** with the agent that last ran there |
| `start <name> words...` | Extra words become the agent's initial prompt *and* are saved as the project's intent |
| `start <name> ... -Yolo` / `--yolo` | Appends the agent's auto-approval flag (opt-in per invocation) |
| `start <name> ... -Here` / `--here` | Launch in the current window instead of a new tab |

PowerShell `<Tab>` completes project names. Projects root: `$env:OMP_PROJECTS_DIR`, default `C:\projects`.

## Resume: how the agent is chosen

Every launch writes `<project>\.ps-project.json`. On reopen:

1. That file's `agent` wins (exact recall).
2. Otherwise fingerprints: `.claude/` or `CLAUDE.md` -> `claude -c`; `.codex/` -> `codex resume --last`; `.gemini/` -> `gemini`.
3. Otherwise omp's own session buckets (`~/.omp/agent/sessions/*-<name>-*`) -> `omp -c`.
4. Default: `omp`.

Known limits: Gemini CLI has no trustworthy resume flag, so it relaunches fresh; Codex cannot take a prompt alongside resume, so extra words are dropped with a warning.

## Custom agents — `agents.json`

Optional file next to `Start-Project.ps1`; entries merge over the built-ins (omp, claude, codex, gemini).

```json
{
  "aider": {
    "continueArgs": ["--resume", "--last"],
    "takesPromptOnContinue": false,
    "yoloFlags": ["--yes-always"]
  },
  "omp": { "continueArgs": ["--continue"] }
}
```

| Key | Meaning | Default |
|---|---|---|
| `continueArgs` | argv used when resuming an existing project | `[]` |
| `takesPromptOnContinue` | may extra words ride along on resume | `true` |
| `yoloFlags` | argv appended by `-Yolo` | `[]` (warns) |

Built-in flags: omp `--approval-mode yolo`, claude `--dangerously-skip-permissions`, codex `--full-auto`, gemini `--yolo`.

## Per-project metadata

`.ps-project.json` in each project root:

```json
{
  "agent": "omp",
  "intent": "build a snake game",
  "created": "2026-08-23T10:00:00.0000000Z",
  "updated": "2026-08-23T12:30:00.0000000Z"
}
```

Plain JSON, safe to edit or commit-ignore.

## Requirements

Windows. PowerShell 5.1 or 7+ (engine). Optional: Windows Terminal (`wt`) for new-tab launches, `fzf` for the picker, Git Bash for the bash shim, any agent executables you register.

## Development

Two bundled suites, both stubbed (touch only temp dirs):

```powershell
powershell  -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1              # engine matrix (27 checks)
pwsh        -NoProfile -ExecutionPolicy Bypass -File tests\run-tests-crossshell.ps1   # bash + cmd shims (15 checks)
```
