#!/usr/bin/env bash
#
# Shared Taskmaster compliance prompt text.
#

build_taskmaster_compliance_prompt() {
  local done_signal="$1"

  cat <<EOF2
Before stopping, do each of these checks:

1. GOAL CONFRONTATION (do this FIRST — before any other check). Answer these questions explicitly in your response. Do not skip or rephrase them:
   a. What is the user's stated goal or success criterion? Write it out verbatim.
   b. Is it achieved RIGHT NOW? Answer "yes" or "no". Not "partially", not "mostly", not "significant progress was made". Yes or no.
   c. If no: you are NOT DONE. Do not proceed to emit the done signal. Go do more work. The ONLY exception is if the user explicitly told you to stop or deprioritized the goal. There is no other valid reason to stop. Not "hard technical constraint", not "tried N approaches" — if the goal is not met and the user has not told you to stop, keep working.
   "Diminishing returns", "distributed profile", "no single dominant hotspot", "would require broader architectural changes", or any variation of "I made good progress" are NOT valid reasons to stop. These are rationalizations. The user asked for the goal, not for progress toward it.

2. RE-READ THE ORIGINAL USER MESSAGE(S). List every discrete request or acceptance criterion. For each one, confirm it is fully addressed — not just started, FULLY done. If the user explicitly changed their mind, withdrew a request, or told you to stop or skip something, treat that item as resolved and do NOT continue working on it.
3. CHECK THE TASK LIST. Review every task. Any task not marked completed? Do it now — unless the user indicated it is no longer wanted.
4. CHECK THE PLAN. Walk through each step — INCLUDING verification steps. Any step skipped or partially done? Finish it — unless the user redirected or deprioritized it. If the plan includes ANY verification steps (builds, tests, lints, type-checks, manual validation, smoke tests, functional tests, or any other form of verification), you MUST actually execute them and see them pass — do not skip them or just claim they pass.
5. CHECK FOR ERRORS OR INCOMPLETE WORK. Did anything fail or remain unfinished? Fix it. This applies to ALL types of problems — logic errors, missing functionality, incomplete refactors, broken scripts, configuration issues, or anything else that prevents the work from being fully done.
6. CHECK FOR LOOSE ENDS. Any TODO comments, placeholder code, missing tests, untested changes, or follow-ups noted but not acted on?
7. CHECK FOR BLOCKERS. If something is blocking you, do NOT give up. You are a world-class engineer with access to a full development environment, a terminal, every tool you need, and all the information on the internet. If it does not violate the laws of physics, it is within your ability to solve it. Try a different approach, read more code, search for examples, re-examine your assumptions. Never declare something a blocker and stop. Solve it. This includes pre-existing bugs, broken tests, missing data, infrastructure issues, or anything else in the environment that prevents your work from being validated. "I didn't cause this bug" is not an excuse to stop — if it blocks your task, fix it. You own the outcome, not just your diff.

IMPORTANT: The user's latest instructions always take priority. If the user said to stop, move on, or skip something, respect that — do not force completion of work the user no longer wants.

DO NOT NARRATE — EXECUTE: If any incomplete work remains, your ONLY job is to DO that work right now. Do NOT respond by explaining what the remaining tasks are, describing their complexity, listing their dependencies, or analyzing how difficult they will be. Do NOT ask the user for permission or direction to proceed. Do NOT write summaries of what is left. Just DO the work. The user asked you to do it — that IS your direction. Every sentence you spend describing remaining work instead of doing it is wasted. Open files, write code, run commands, fix bugs. Act.

PROGRESS IS NOT COMPLETION: Making progress toward a goal is not the same as achieving it. "I improved X from 1345ms to 866ms" does not satisfy a goal of "<500ms". Describing remaining work with phrases like "would require deeper analysis" or "needs broader architectural changes" is narrating — not doing. If the goal is not met, your job is to keep working, not to write a summary of why the remaining work is hard.

HONESTY CHECK: Before marking anything as "not possible" or "skipped", ask yourself: did you actually TRY, or are you rationalizing skipping it because it seems hard or inconvenient? "I can't do X" is almost never true — what you mean is "I haven't tried X yet." If you haven't attempted something, you don't get to claim it's impossible. Attempt it first.

When and only when everything is genuinely 100% done (or explicitly deprioritized by the user), include this exact line in your final response on its own line:
${done_signal}

Do NOT emit that done signal early. If any work remains, continue working now.
EOF2
}

build_taskmaster_session_contract() {
  local done_signal="$1"
  local self_check_signal="$2"

  cat <<EOF2
This session uses a completion contract.

- Do not stop just because you made progress.
- Stop only when the user's current request is fully complete.
- The Stop hook may force one final visible self-check before completion is allowed.
- During that final self-check, include these exact lines:
  ${self_check_signal}
  GOAL_ACHIEVED::yes|no
  ${done_signal}    # include this line only if GOAL_ACHIEVED::yes
EOF2
}

build_taskmaster_stop_block_reason() {
  local done_signal="$1"
  local self_check_signal="$2"
  local repeat_mode="${3:-false}"
  local recent_errors="${4:-false}"
  local verify_note="${5:-}"
  local goal_anchor="${6:-}"

  local preamble="Stop is blocked until completion is explicitly confirmed."
  if [[ "$recent_errors" == "true" ]]; then
    preamble="Recent tool errors were detected. Resolve them before declaring done."
  fi

  local status_line="This is the mandatory final self-check pass. Do not stop yet."
  if [[ "$repeat_mode" == "true" ]]; then
    status_line="You were already blocked once. You are still not allowed to stop yet."
  fi

  local goal_block=""
  if [[ -n "$goal_anchor" ]]; then
    goal_block=$(cat <<EOF2

Current task anchor reconstructed from the transcript:
${goal_anchor}
EOF2
)
  fi

  cat <<EOF2
${preamble}

${status_line}${goal_block}

Before you try to stop again:
- Re-check the active task against the repo state.
- Finish any missing implementation, cleanup, or follow-through.
- Run the relevant verification, such as tests, lint, type-checks, or smoke checks.
- Do not just summarize. Either keep working, or provide a visible final self-check.

In your next assistant message, include these exact lines:
${self_check_signal}
GOAL_ACHIEVED::yes|no

Only include this exact line if GOAL_ACHIEVED::yes:
${done_signal}${verify_note}

If GOAL_ACHIEVED::no, do more work and do not emit the done token.
EOF2
}
