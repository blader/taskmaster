---
name: taskmaster
description: |
  Native Codex SessionStart/Stop hooks plus a Claude stop hook
  that keep work moving until an explicit parseable done signal is emitted.
author: blader
version: 5.0.0
---

# Taskmaster

Taskmaster uses native hooks to enforce completion without a wrapper process.

## How It Works

1. **Codex SessionStart hook** injects a compact completion contract when a
   session starts, resumes, or clears.
2. **Codex Stop hook** reconstructs the active task from the transcript and
   blocks the first stop attempt on purpose.
3. **Visible self-check contract**:
   - `TASKMASTER_SELF_CHECK::<session_id>`
   - `GOAL_ACHIEVED::yes|no`
   - `TASKMASTER_DONE::<session_id>` only when the goal is truly complete
4. **Optional verifier**:
   - If `TASKMASTER_VERIFY_COMMAND` is set, stop remains blocked until that
     command passes.
5. **Claude path** keeps the existing stop-hook enforcement based on the done
   token plus the shared compliance prompt.

## Parseable Done Signal

When the work is genuinely complete, the agent must include this exact line
in its final response (on its own line):

```text
TASKMASTER_DONE::<session_id>
```

This gives external automation a deterministic completion marker to parse.

## Configuration

- `TASKMASTER_FORCE_REVIEW_PASS` (default `1`): Codex only. Force one blocked
  stop pass before completion can be accepted.
- `TASKMASTER_VERIFY_COMMAND`: Codex only. Require a repo verification command
  before stop is allowed.
- `TASKMASTER_VERIFY_MAX_OUTPUT` (default `4000`): Codex only. Limit verifier
  output echoed back into the hook block reason.
- `TASKMASTER_MAX` (default `0`): Claude only. Limit repeated stop warnings.

## Setup

Install and run:

```bash
bash ~/.codex/skills/taskmaster/install.sh
codex
```
