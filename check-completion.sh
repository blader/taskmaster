#!/usr/bin/env bash
#
# Stop hook: keep firing until the agent emits an explicit done signal.
#
# The stop is allowed only after the transcript contains:
#   TASKMASTER_DONE::<session_id>
#
# Optional env vars:
#   TASKMASTER_MAX          Max number of blocks before allowing stop (default: 0 = infinite)
#   TASKMASTER_DONE_PREFIX  Prefix for done token (default: TASKMASTER_DONE)
#
set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path')
if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  SESSION_ID="unknown-session"
fi

# --- skip subagents: they have very short transcripts ---
if [ -f "$TRANSCRIPT" ]; then
  LINE_COUNT=$(wc -l < "$TRANSCRIPT" 2>/dev/null || echo "0")
  if [ "$LINE_COUNT" -lt 20 ]; then
    exit 0
  fi
fi

# --- counter ---
COUNTER_DIR="${TMPDIR:-/tmp}/taskmaster"
mkdir -p "$COUNTER_DIR"
COUNTER_FILE="${COUNTER_DIR}/${SESSION_ID}"
MAX=${TASKMASTER_MAX:-0}

COUNT=0
if [ -f "$COUNTER_FILE" ]; then
  COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
fi

# --- done signal detection ---
DONE_PREFIX="${TASKMASTER_DONE_PREFIX:-TASKMASTER_DONE}"
DONE_SIGNAL="${DONE_PREFIX}::${SESSION_ID}"
HAS_DONE_SIGNAL=false
HAS_RECENT_ERRORS=false

if [ -f "$TRANSCRIPT" ]; then
  TAIL_400=$(tail -400 "$TRANSCRIPT" 2>/dev/null || true)
  if echo "$TAIL_400" | grep -Fq "$DONE_SIGNAL" 2>/dev/null; then
    HAS_DONE_SIGNAL=true
  fi

  TAIL_40=$(tail -40 "$TRANSCRIPT" 2>/dev/null || true)
  if echo "$TAIL_40" | grep -qi '"is_error":\s*true' 2>/dev/null; then
    HAS_RECENT_ERRORS=true
  fi
fi

if [ "$HAS_DONE_SIGNAL" = true ]; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

NEXT=$((COUNT + 1))
echo "$NEXT" > "$COUNTER_FILE"

# Optional escape hatch. Default is infinite (0) so hook keeps firing.
if [ "$MAX" -gt 0 ] && [ "$NEXT" -ge "$MAX" ]; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

if [ "$HAS_RECENT_ERRORS" = true ]; then
  PREAMBLE="Recent errors detected — resolve them."
else
  PREAMBLE="Stop blocked."
fi

if [ "$MAX" -gt 0 ]; then
  LABEL="TASKMASTER (${NEXT}/${MAX})"
else
  LABEL="TASKMASTER (${NEXT})"
fi

# --- reprompt (kept minimal — full checklist lives in SKILL.md system context) ---
REASON="${LABEL}: ${PREAMBLE} Follow the taskmaster completion checklist. Done signal: ${DONE_SIGNAL}"

jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
