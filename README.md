# Taskmaster

A stop hook skill for [OpenClaw](https://openclaw.ai/) agents that prevents premature stopping. When the agent finishes a response and is about to stop, Taskmaster intercepts and prompts it to re-examine whether all work is truly done.

## How It Works

1. **Agent tries to stop** — the stop hook fires.
2. **Transcript check** — the hook scans recent transcript for incomplete tasks or errors.
3. **Agent is prompted** to verify: original requests addressed, plan steps completed, tasks resolved, errors fixed, no loose ends.
4. **If work remains**, the agent continues working. If truly done, the agent confirms and the hook allows the stop on the next cycle.

The prompt respects user intent — if the user explicitly changed their mind, withdrew a request, or said to skip something, those items are treated as resolved.

## Install

```bash
git clone https://github.com/blader/taskmaster.git
cd taskmaster
bash install.sh
```

This will:
- Copy the skill to `~/.openclaw/skills/taskmaster/`
- Register the stop hook in `~/.openclaw/openclaw.json`

Restart OpenClaw after installing.

### Manual install

If you prefer to install manually:

1. Copy `SKILL.md` to `~/.openclaw/skills/taskmaster/SKILL.md`
2. Copy `scripts/check-completion.sh` to `~/.openclaw/skills/taskmaster/scripts/check-completion.sh`
3. Make it executable: `chmod +x ~/.openclaw/skills/taskmaster/scripts/check-completion.sh`
4. Add this to your `~/.openclaw/openclaw.json`:

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

## Uninstall

```bash
cd taskmaster
bash uninstall.sh
```

## Configuration

Control the maximum number of continuation cycles via the `TASKMASTER_MAX` environment variable:

```bash
# Default: 10 continuations before the hook stops blocking
export TASKMASTER_MAX=20   # allow up to 20
export TASKMASTER_MAX=0    # infinite — never cap (relies on transcript analysis only)
export TASKMASTER_MAX=1    # minimal — one review pass then allow stop
```

## How the stop logic works

On each stop attempt, the hook evaluates two things:

1. **Counter** — how many times it has already blocked in this session (capped at `TASKMASTER_MAX`, or uncapped if `0`).
2. **Transcript signals** — scans the last 50 lines of the session transcript for pending/in-progress tasks or tool errors.

The hook **allows** the agent to stop when:
- The counter reaches `TASKMASTER_MAX` (hard cap), OR
- The hook already fired once (`stop_hook_active=true`) AND no incomplete signals are found in the transcript (the agent reviewed its work and there's nothing left).

The hook **blocks** (forces continuation) otherwise, sending the agent a checklist prompt to re-examine its work.

## Requirements

- [OpenClaw](https://openclaw.ai/) with hooks support
- `jq` (for the install script and the hook itself)
- `bash`

## License

MIT
