---
name: taskmaster
description: Stop hook that keeps the agent working until all plans and user requests are 100% complete. Fires when the agent tries to stop, re-examines the plan and task list, and forces continuation if anything is unfinished. Prevents premature stopping on multi-step tasks.
metadata: { "openclaw": { "requires": { "bins": ["jq", "bash"] } } }
---

# Taskmaster

A stop hook that prevents the agent from stopping prematurely. When a response
finishes and the agent is about to stop, this hook intercepts and prompts it
to re-examine whether all work is truly done.

## How It Works

1. **Agent tries to stop** — the stop hook fires.
2. **The hook checks** for incomplete signals (pending tasks, recent errors).
3. **Agent is prompted** to verify: original requests addressed, plan steps
   completed, tasks resolved, errors fixed, no loose ends.
4. **If work remains**, the agent continues. If truly done, it confirms and
   the hook allows the stop on the next cycle.

## Loop Protection

A session-scoped counter limits continuations to **10 by default**. Set
`TASKMASTER_MAX` environment variable to change:

```bash
export TASKMASTER_MAX=20  # allow up to 20 continuations
export TASKMASTER_MAX=0   # infinite — never cap (relies on stop_hook_active check only)
```

## Setup

Run the installer from the skill directory:

```bash
bash install.sh
```

This registers the stop hook in `~/.openclaw/openclaw.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.openclaw/skills/taskmaster/scripts/check-completion.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

## Disabling

To temporarily disable, either:
- Remove or comment out the Stop hook in `~/.openclaw/openclaw.json`
- Set `TASKMASTER_MAX=1` to allow only one continuation check
