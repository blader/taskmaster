# Taskmaster
## Product & Technical Specification

**Version**: 5.0.0
**Scope**:
- `taskmaster/check-completion.sh`
- `taskmaster/taskmaster-compliance-prompt.sh`
- `taskmaster/taskmaster-state.sh`
- `taskmaster/hooks/taskmaster-session-start.sh`
- `taskmaster/hooks/taskmaster-user-prompt-submit.sh`
- `taskmaster/hooks/taskmaster-stop.sh`
- `taskmaster/install.sh`
- `taskmaster/uninstall.sh`

## 1. Goal

Prevent premature agent stopping and provide a deterministic, machine-parseable
completion signal while remaining usable across long-lived Codex and Claude
sessions.

Taskmaster enforces explicit completion through a done-token contract and
hook-based feedback when that contract is not satisfied.

Both Codex and Claude paths consume shared prompt text from
`taskmaster-compliance-prompt.sh`.

## 2. Completion Contract

A turn is considered complete only when assistant output includes:

```text
TASKMASTER_DONE::<session_id>
```

- `<session_id>` is session-scoped.
- The line must be emitted only when that turn's work is truly complete.

### 2.1 Codex Native Stop Contract

The Codex native-hook path preserves the same completion signal as the original
Taskmaster:

```text
TASKMASTER_DONE::<session_id>
```

- The hook may continue the same turn when the token is missing.
- There is no mandatory visible self-check protocol in the supported design.

## 3. Architecture

### 3.1 Codex Native Hooks Path

`hooks/taskmaster-session-start.sh`:

1. Executes as a Codex `SessionStart` hook on `startup`, `resume`, and `clear`.
2. Emits a compact durable completion contract referencing the session-scoped
   done token.

`hooks/taskmaster-user-prompt-submit.sh`:

1. Executes as a Codex `UserPromptSubmit` hook.
2. Persists the exact user prompt for the current `session_id` + `turn_id`.
3. Ignores Taskmaster-generated continuation prompts and pure environment-only
   prompts.

`hooks/taskmaster-stop.sh`:

1. Executes as a Codex `Stop` hook.
2. Reads `session_id`, `turn_id`, `transcript_path`,
   `last_assistant_message`, and `cwd` from hook input.
3. Loads the exact saved turn prompt when available and otherwise reconstructs
   the active task from the transcript.
4. If the latest assistant message already contains
   `TASKMASTER_DONE::<session_id>`, the hook allows stop immediately.
5. Otherwise the hook blocks stop and continues Codex with:
   - the reconstructed current-task anchor
   - the original rich Taskmaster compliance prompt
6. Optionally runs `TASKMASTER_VERIFY_COMMAND` in the session working
   directory. Stop stays blocked until that verifier succeeds.

### 3.2 Claude Stop-Hook Path

`check-completion.sh`:

1. Executes as a Claude `Stop` hook command.
2. Verifies the done token in the latest assistant message or transcript.
3. If missing, returns a blocking decision with the shared compliance prompt.
4. If present, allows stop.

## 4. Installation Behavior

`install.sh` auto-detects Codex and/or Claude and installs matching targets.
`uninstall.sh` auto-detects and removes matching targets.

Override knobs:
- `TASKMASTER_INSTALL_TARGET=auto|codex|claude|both`
- `TASKMASTER_UNINSTALL_TARGET=auto|codex|claude|both`

### 4.1 Codex Install

Install updates:
- `~/.codex/skills/taskmaster/`
- `~/.codex/config.toml` to ensure `[features] codex_hooks = true`
- `~/.codex/hooks.json` to ensure Taskmaster `SessionStart`,
  `UserPromptSubmit`, and `Stop` command hooks are present

Install also removes legacy Taskmaster wrapper symlinks from:
- `~/.codex/bin/codex`
- `~/.codex/bin/codex-taskmaster`

### 4.2 Claude Install

Install updates:
- `~/.claude/skills/taskmaster/`
- `~/.claude/hooks/taskmaster-check-completion.sh`
- `~/.claude/settings.json` to ensure the stop hook is configured

## 5. Configuration

Configurable:
- `TASKMASTER_VERIFY_COMMAND`: Codex only. Require a shell verifier command
  before stop is allowed.
- `TASKMASTER_VERIFY_MAX_OUTPUT` (default `4000`): Codex only. Limit verifier
  output in hook block reasons.
- `TASKMASTER_MAX` (default `0`): Claude only. Warning cap in stop-hook checks.

Fixed:
- done token prefix: `TASKMASTER_DONE`

## 6. Operational Notes

- Codex enforcement is entirely native-hook based. There is no wrapper or
  expect bridge in the supported architecture.
- The stop hook segments tasks inside a long-lived Codex session using the most
  recent done token as the boundary.
- If no prior done token exists, the stop hook falls back to the active user
  instructions found in the transcript to infer the task anchor.
- Uninstall removes Taskmaster hook entries but preserves `codex_hooks = true`
  so unrelated native-hook workflows are not broken.
