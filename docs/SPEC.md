# Taskmaster
## Product & Technical Specification

**Version**: 4.3.0  
**Scope**:
- `taskmaster/check-completion.sh`
- `taskmaster/taskmaster-compliance-prompt.sh`
- `taskmaster/hooks/inject-continue-codex.sh`
- `taskmaster/hooks/run-codex-expect-bridge.exp`
- `taskmaster/run-taskmaster-codex.sh`
- `taskmaster/install.sh`
- `taskmaster/uninstall.sh`

## 1. Goal

Prevent premature agent stopping and provide a deterministic, machine-parseable
completion signal while remaining usable across long-lived Codex sessions.

Taskmaster enforces explicit completion through a done-token contract and
continuation/hook feedback when that contract is not satisfied.

Both Codex and Claude paths consume the same shared compliance prompt text from
`taskmaster-compliance-prompt.sh`.

## 2. Completion Contract

A turn is considered complete only when assistant output includes:

```text
TASKMASTER_DONE::<session_id>
```

- `<session_id>` is session-scoped.
- The line must be emitted only when that turn's work is truly complete.
- Automation can parse this line as the authoritative completion marker for the
  completed turn without disabling monitoring for later turns in the same
  Codex process.

## 3. Architecture

### 3.1 Codex Wrapper Path

`run-taskmaster-codex.sh`:

1. Resolves real Codex binary and enables session logging.
2. Starts queue-emitter injector (`hooks/inject-continue-codex.sh`).
3. Runs Codex in managed expect PTY (`hooks/run-codex-expect-bridge.exp`).
4. On incomplete turn (missing done token), injector emits continuation prompt
   files and expect bridge injects them into the same running process.
5. On complete turn (done token present), injector skips injection for that
   turn and keeps following the session log for subsequent turns.
6. Interactive `codex resume ...` launches stay on this managed path rather
   than bypassing Taskmaster as a direct passthrough.

### 3.2 Claude Stop-Hook Path

`check-completion.sh`:

1. Executes as Claude `Stop` hook command.
2. Verifies done token in session transcript.
3. If missing, returns a blocking decision with compliance instructions.
4. If present, allows stop.

### 3.3 Queue Emitter

`hooks/inject-continue-codex.sh`:

- Follows Codex session log.
- Handles `task_complete` / `turn_complete` events.
- Dedupe by turn-id/signature.
- Writes continuation payloads as `inject.*.txt` queue files.

### 3.4 Expect Bridge

`hooks/run-codex-expect-bridge.exp`:

- Polls queue files.
- Injects payload into the same Codex PTY via bracketed paste.
- Submits prompt with Enter after fixed short delay.

### 3.5 Hook-injected prompt tag

Every prompt the hook injects starts with a single-line tag:

```
[taskmaster:injected v=1 kind=<kind>]
<actual content...>
```

`<kind>` ∈ `stop-block | followup | compliance | session-start | verifier-feedback`.
The `compliance` and `session-start` kinds are reserved for future use (T2 native Codex hooks, T3 semantic verifier); only `stop-block`, `followup`, and `verifier-feedback` are emitted in v4.3.0.

Downstream consumers (UserPromptSubmit hook, completion verifier, external
tooling) detect injected prompts via `is_taskmaster_injected_prompt` from
`taskmaster-prompt-detect.sh`. Legacy substring detection is preserved for
prompts emitted before this version.

### 3.6 Session state file

Path: `${TASKMASTER_STATE_DIR:-${TMPDIR:-/tmp}/taskmaster/state}/<session_id>.json`

Schema (v1):

```json
{
  "schema_version": 1,
  "session_id": "<sid>",
  "created_at": "<iso8601>",
  "updated_at": "<iso8601>",
  "stop_count": 0,
  "latest_user_prompt": null,
  "last_verifier_run": null,
  "metadata": {}
}
```

All writes go through `flock` on `<path>.lock` and atomic tmp+mv.

**Legacy migration:** on first read per session, the hook absorbs any
existing counter file at `${TMPDIR}/taskmaster/<session_id>` into
`stop_count` and deletes the legacy file. Idempotent.

## 4. Installation Behavior

`install.sh` auto-detects Codex and/or Claude and installs matching targets.
`uninstall.sh` auto-detects and removes matching targets.

Override knobs:
- `TASKMASTER_INSTALL_TARGET=auto|codex|claude|both`
- `TASKMASTER_UNINSTALL_TARGET=auto|codex|claude|both`

## 5. Configuration

Configurable:
- `TASKMASTER_MAX` (default `0`): warning cap in stop-hook checks.

Fixed:
- done token prefix: `TASKMASTER_DONE`
- poll interval: `1` second
- Codex transport: expect only
- expect payload mode + submit timing

### 5.1 Optional verifier command

| Env var | Default | Meaning |
|---|---|---|
| `TASKMASTER_VERIFY_COMMAND` | unset | Shell command run when the done token is seen. Empty/unset = skip. |
| `TASKMASTER_VERIFY_TIMEOUT` | `60` | Seconds before SIGTERM, +5s grace before SIGKILL. |
| `TASKMASTER_VERIFY_MAX_OUTPUT` | `4000` | Bytes of combined stdout+stderr echoed back into the block reason. |
| `TASKMASTER_VERIFY_CWD` | unset | If set, `cd` here before invoking. Else inherit hook's cwd. |

When `TASKMASTER_VERIFY_COMMAND` is set, stop is allowed only when (a) the
done token is present **and** (b) the command exits 0. A failing verifier
overrides token-based completion and blocks with the command's exit code and
truncated output.

The verifier runs **only** when the done token is present, not on every stop
attempt — this keeps slow verifiers (test suites, builds) from gating
mid-work stop attempts.

## 6. Operational Notes

- Enforcement is same-process for Codex and stop-hook based for Claude.
- There is no standalone monitor-only mode in this design.
