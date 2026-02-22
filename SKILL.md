---
name: taskmaster
description: |
  Stop hook that keeps the agent working until all plans and user requests are
  100% complete. Fires on every stop attempt until the agent emits an explicit
  parseable done signal in its final response. Provides deterministic machine
  detection for true completion.
author: blader
version: 2.2.0
---

# Taskmaster

A stop hook that prevents the agent from stopping prematurely. When the agent
is about to stop, this hook checks for a session-specific done token in the
transcript. If the token is missing, it blocks the stop and forces another
completion review cycle.

## How It Works

1. **Agent tries to stop** — the stop hook fires every time.
2. **Hook scans transcript** for a parseable token:
   `TASKMASTER_DONE::<session_id>`
3. **Token missing** — hook blocks stop with a brief trigger message.
4. **Token present** — hook allows stop and clears session counter state.

## Completion Checklist

When the stop hook blocks you, execute this checklist before emitting the
done signal. Do NOT narrate or summarize — just DO the work.

1. **RE-READ THE ORIGINAL USER MESSAGE(S).** List every discrete request or
   acceptance criterion. For each one, confirm it is fully addressed — not
   just started, FULLY done. If the user explicitly changed their mind,
   withdrew a request, or told you to stop or skip something, treat that
   item as resolved and do NOT continue working on it.

2. **CHECK THE TASK LIST.** Review every task. Any task not marked completed?
   Do it now — unless the user indicated it is no longer wanted.

3. **CHECK THE PLAN.** Walk through each step — INCLUDING verification steps.
   Any step skipped or partially done? Finish it — unless the user redirected
   or deprioritized it. If the plan includes ANY verification steps (builds,
   tests, lints, type-checks, manual validation, smoke tests, functional
   tests, or any other form of verification), you MUST actually execute them
   and see them pass — do not skip them or just claim they pass.

4. **CHECK FOR ERRORS OR INCOMPLETE WORK.** Did anything fail or remain
   unfinished? Fix it. This applies to ALL types of problems — logic errors,
   missing functionality, incomplete refactors, broken scripts, configuration
   issues, or anything else that prevents the work from being fully done.

5. **CHECK FOR LOOSE ENDS.** Any TODO comments, placeholder code, missing
   tests, untested changes, or follow-ups noted but not acted on?

6. **CHECK FOR BLOCKERS.** If something is blocking you, do NOT give up. You
   are a world-class engineer with access to a full development environment,
   a terminal, every tool you need, and all the information on the internet.
   If it does not violate the laws of physics, it is within your ability to
   solve it. Try a different approach, read more code, search for examples,
   re-examine your assumptions. Never declare something a blocker and stop.
   Solve it.

**User priority:** The user's latest instructions always take priority. If the
user said to stop, move on, or skip something, respect that — do not force
completion of work the user no longer wants.

**DO NOT NARRATE — EXECUTE:** If any incomplete work remains, your ONLY job is
to DO that work right now. Do NOT respond by explaining what the remaining
tasks are, describing their complexity, listing their dependencies, or
analyzing how difficult they will be. Do NOT ask the user for permission or
direction to proceed. Do NOT write summaries of what is left. Just DO the
work. The user asked you to do it — that IS your direction. Every sentence you
spend describing remaining work instead of doing it is wasted. Open files,
write code, run commands, fix bugs. Act.

**HONESTY CHECK:** Before marking anything as "not possible" or "skipped", ask
yourself: did you actually TRY, or are you rationalizing skipping it because
it seems hard or inconvenient? "I can't do X" is almost never true — what you
mean is "I haven't tried X yet." If you haven't attempted something, you don't
get to claim it's impossible. Attempt it first.

## Parseable Done Signal

When the work is genuinely complete, include this exact line in your final
response (on its own line):

```text
TASKMASTER_DONE::<session_id>
```

Do NOT emit that done signal early. If any work remains, continue working.

This gives external automation a deterministic completion marker to parse.

## Configuration

- `TASKMASTER_MAX` (default `0`): Max number of blocked stop attempts before
  allowing stop. `0` means infinite (keep firing).
- `TASKMASTER_DONE_PREFIX` (default `TASKMASTER_DONE`): Prefix used for the
  done token.

## Setup

The hook must be registered in `~/.claude/settings.json`:

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

## Disabling

To temporarily disable, remove or comment out the Stop hook in
`~/.claude/settings.json`.
