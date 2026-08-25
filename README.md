# project-starter

One word from PowerShell to a running AI coding agent inside a fresh, git-initialized project.

```powershell
start my-app build a snake game
```

creates `C:\projects\my-app`, runs `git init`, opens a **new Windows Terminal tab**, and launches your agent with `build a snake game` as its initial prompt.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Idempotent. Dot-sources `Start-Project.ps1` from both the PowerShell 7+ and Windows PowerShell 5.1 profiles, lifts a Restricted execution policy if needed, and prints the reload hint for already-open windows.

## Usage

| Command | Behavior |
|---|---|
| `start` | Pick an existing project (fzf if installed, else numbered list); shows saved intent + last-active time |
| `start <name>` | Create (or reopen) `<root>\<name>`. Reopening **auto-resumes** with the agent that last ran there |
| `start <name> words...` | Extra words become the agent's initial prompt *and* are saved as the project's intent |
| `start <name> ... -Yolo` | Appends the agent's auto-approval flag (opt-in per invocation) |
| `start <name> ... -Here` | Launch in the current window instead of a new tab |

`<Tab>` completes project names. Projects root: `$env:OMP_PROJECTS_DIR`, default `C:\projects`.

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

Windows, PowerShell 5.1 or 7+, `git` on PATH. Optional: Windows Terminal (`wt`) for new-tab launches, `fzf` for the picker, any agent executables you register.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Removes the profile lines. Already-open shells keep the function until restarted.

## Development

Bundled verification matrix (stubbed agents; touches only a temp dir):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1   # or pwsh
```
