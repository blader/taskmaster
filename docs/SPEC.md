# Taskmaster
## Product & Technical Specification

**Version**: 2.2.0
**Scope**: `taskmaster/hooks/check-completion.sh`, `taskmaster/SKILL.md`

## 1. Goal

Prevent premature agent stopping and provide a deterministic, machine-parseable
completion signal.

Taskmaster now blocks every stop attempt until the agent emits an explicit
done token in the transcript.

## 2. Completion Contract

A stop is allowed only when the transcript contains:

```text
TASKMASTER_DONE::<session_id>
```

- `<session_id>` is the hook runtime session id.
- The line must be emitted by the agent only when work is truly complete.
- External systems can parse this line as the authoritative completion marker.

## 3. Hook Behavior

### 3.1 Stop Decision Logic

On each stop event:

1. Read stdin JSON from hook runtime.
2. Skip very short transcripts (`< 20` lines) to avoid subagent false fires.
3. Build session-scoped state under `${TMPDIR:-/tmp}/taskmaster/<session_id>`.
4. Scan transcript tail for done token `TASKMASTER_DONE::<session_id>`.
5. If token exists: allow stop (`exit 0`) and clear counter file.
6. If token missing: increment counter and block stop with a checklist prompt.
7. Optional safety cap: if `TASKMASTER_MAX > 0` and counter reaches cap,
   allow stop and clear counter file.

### 3.2 Prompt Architecture

The verbose completion checklist lives in `SKILL.md`, which is loaded as system
context (invisible to the user in session history). The hook's `reason` field
is kept minimal — just a label, status, and done signal — so it does not
pollute the conversation transcript.

When blocking, Taskmaster injects a brief reason:

- `TASKMASTER (N)` or `TASKMASTER (N/MAX)` label.
- Short status (stop blocked / errors detected).
- Reference to follow the taskmaster completion checklist.
- The exact done signal to emit when truly complete.

The full checklist (re-read user messages, check task list, check plan, check
for errors, check for loose ends, check for blockers, honesty check) is in the
"Completion Checklist" section of `SKILL.md`.

### 3.3 Error Signal Hinting

Taskmaster inspects recent transcript lines for `"is_error": true` and adjusts
the brief preamble text to call out unresolved errors.

## 4. Runtime Interfaces

### 4.1 Input (stdin JSON)

- `session_id` (string)
- `transcript_path` (string)
- `stop_hook_active` (ignored)

### 4.2 Output

- Allow stop: exit code `0`, no stdout
- Block stop: stdout JSON

```json
{ "decision": "block", "reason": "..." }
```

## 5. Configuration

- `TASKMASTER_MAX` (default `0`)
  - `0`: infinite blocking until done token appears
  - `>0`: max block count before forced allow
- `TASKMASTER_DONE_PREFIX` (default `TASKMASTER_DONE`)
  - Done token format becomes `<prefix>::<session_id>`

## 6. State

- Directory: `${TMPDIR:-/tmp}/taskmaster`
- File: `${TMPDIR:-/tmp}/taskmaster/<session_id>`
- Content: integer fire count
- Lifecycle: created on first block, removed when stop is allowed

## 7. Registration

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/skills/taskmaster/hooks/check-completion.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

## 8. Operational Notes

- Default behavior is strict: no token, no stop.
- For emergency escape hatch in automation, set `TASKMASTER_MAX` to a positive
  value.
- Parse done signals using exact-match line parsing for reliability.
