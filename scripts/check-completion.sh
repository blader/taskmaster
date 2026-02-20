#!/usr/bin/env bash
#
# Taskmaster stop hook for OpenClaw agents.
# Keeps the agent working until the plan and user requests are 100% done.
#
# Uses a session-scoped counter to prevent infinite loops.
# Set TASKMASTER_MAX to change the max continuation count (default: 10, 0 = infinite).
#
set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path')
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

# --- loop guard ---
COUNTER_DIR="${TMPDIR:-/tmp}/taskmaster"
mkdir -p "$COUNTER_DIR"
COUNTER_FILE="${COUNTER_DIR}/${SESSION_ID}"
MAX=${TASKMASTER_MAX:-10}

COUNT=0
if [ -f "$COUNTER_FILE" ]; then
  COUNT=$(cat "$COUNTER_FILE")
fi

# After max continuations, allow stop and clean up (0 = infinite, never cap)
if [ "$MAX" -gt 0 ] && [ "$COUNT" -ge "$MAX" ]; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- transcript analysis ---
HAS_INCOMPLETE_SIGNALS=false

if [ -f "$TRANSCRIPT" ]; then
  TAIL=$(tail -50 "$TRANSCRIPT" 2>/dev/null || true)

  # Check for task-list items still pending/in-progress
  if echo "$TAIL" | grep -qi '"status":\s*"in_progress"\|"status":\s*"pending"' 2>/dev/null; then
    HAS_INCOMPLETE_SIGNALS=true
  fi

  # Check for recent errors in tool results
  if echo "$TAIL" | grep -qi '"is_error":\s*true' 2>/dev/null; then
    HAS_INCOMPLETE_SIGNALS=true
  fi

  # If the hook already fired once (stop_hook_active=true) and there are no
  # incomplete signals, the agent has had a chance to review and chose to stop
  # again — that means it genuinely believes it's done. Allow the stop.
  if [ "$STOP_HOOK_ACTIVE" = "true" ] && [ "$HAS_INCOMPLETE_SIGNALS" = false ]; then
    rm -f "$COUNTER_FILE"
    exit 0
  fi
fi

# --- decide ---
NEXT=$((COUNT + 1))
echo "$NEXT" > "$COUNTER_FILE"

# Build the continuation reason with context
if [ "$HAS_INCOMPLETE_SIGNALS" = true ]; then
  PREAMBLE="Incomplete tasks or recent errors were detected in the session."
else
  PREAMBLE="Verify that all work is truly complete before stopping."
fi

if [ "$MAX" -gt 0 ]; then
  LABEL="TASKMASTER (${NEXT}/${MAX})"
else
  LABEL="TASKMASTER (${NEXT})"
fi

REASON="${LABEL}: ${PREAMBLE}

Before stopping, do each of these checks:

1. RE-READ THE ORIGINAL USER MESSAGE(S). List every discrete request or acceptance criterion. For each one, confirm it is fully addressed — not just started, FULLY done. If the user explicitly changed their mind, withdrew a request, or told you to stop or skip something, treat that item as resolved and do NOT continue working on it.
2. CHECK THE TASK LIST. Review every task. Any task not marked completed? Do it now — unless the user indicated it is no longer wanted.
3. CHECK THE PLAN. Walk through each step. Any step skipped or partially done? Finish it — unless the user redirected or deprioritized it.
4. CHECK FOR ERRORS. Did any tool call, build, test, or lint fail? Fix it.
5. CHECK FOR LOOSE ENDS. Any TODO comments, placeholder code, missing tests, or follow-ups noted but not acted on?

IMPORTANT: The user's latest instructions always take priority. If the user said to stop, move on, or skip something, respect that — do not force completion of work the user no longer wants.

If after this review everything is genuinely 100% done (or explicitly deprioritized by the user), briefly confirm completion for each user request. Otherwise, immediately continue working on whatever remains — do not just describe what is left, ACTUALLY DO IT."

jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
