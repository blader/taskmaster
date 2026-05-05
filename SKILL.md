---
name: taskmaster
description: |
  Codex wrapper plus same-process expect PTY injector
  that keeps work moving until an explicit parseable done signal is emitted.
author: blader
version: 4.3.0
---

# Taskmaster

Taskmaster for Codex uses session-log polling plus automatic continuation.
Codex TUI does not currently expose arbitrary writable stop hooks, so this
skill implements the same completion contract externally.

## How It Works

1. **Run Codex via wrapper**: `run-taskmaster-codex.sh` sets
   `CODEX_TUI_RECORD_SESSION=1` and a log path.
2. **Injector parses log events** and checks completion on each
   `task_complete` event.
3. **Parseable token contract**:
   `TASKMASTER_DONE::<session_id>`
4. **Token missing**:
   - inject follow-up user message into the same running process via
     expect PTY bridge transport, using the shared compliance prompt.
5. **Token present**: no further injection.

## A note on the injected-prompt tag

If you see a line starting with `[taskmaster:injected v=…]` at the top of a
message, that's metadata the hook adds to its own prompts. Treat it as a
marker, not as content you need to act on.

## Parseable Done Signal

When the work is genuinely complete, the agent must include this exact line
in its final response (on its own line):

```text
TASKMASTER_DONE::<session_id>
```

This gives external automation a deterministic completion marker to parse.

## Configuration

- `TASKMASTER_MAX` (default `0`): max warning count before suppression in the
  stop hook. `0` means unlimited warnings.

Fixed behavior (not configurable):
- Done token prefix: `TASKMASTER_DONE`
- Poll interval: `1` second
- Transport: expect only
- Expect payload mode and submit delay are fixed

## Setup

Install and run:

```bash
bash ~/.codex/skills/taskmaster/install.sh
codex-taskmaster
```
