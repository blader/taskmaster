#!/usr/bin/env bash
#
# Stop hook: keep firing until the agent emits an explicit done signal.
#
# The stop is allowed only after the transcript contains:
#   TASKMASTER_DONE::<session_id>
#
# Optional env vars:
#   TASKMASTER_MAX          Max number of blocks before allowing stop (default: 100)
#
# errexit (-e) deliberately omitted — matches hooks/check-completion.sh.
# Hook MUST emit a decision JSON; a non-zero from a helper lib (e.g.
# taskmaster_state_update on a corrupt state file) shouldn't abort before
# the final jq -n write. Per-call error handling lives at the call sites.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/taskmaster-compliance-prompt.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/taskmaster-verify-command.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/taskmaster-prompt-detect.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/taskmaster-state.sh"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path')
# Expand leading ~ to $HOME (tilde not expanded inside quotes by bash)
TRANSCRIPT="${TRANSCRIPT/#\~/$HOME}"
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

# --- counter (state-file backed) ---
taskmaster_state_migrate_legacy_counter "$SESSION_ID"
taskmaster_state_init "$SESSION_ID"

MAX=${TASKMASTER_MAX:-100}
COUNT="$(taskmaster_state_jq "$SESSION_ID" '.stop_count')"
[[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0

transcript_has_done_signal() {
  local transcript_path="$1"
  local done_signal="$2"

  [ -f "$transcript_path" ] || return 1

  tail -400 "$transcript_path" 2>/dev/null \
    | jq -Rr '
        fromjson?
        | select(.type == "response_item" and .payload.type == "message" and .payload.role == "assistant")
        | .payload.content[]?
        | select(.type == "output_text")
        | .text // empty
      ' 2>/dev/null \
    | grep -Fq "$done_signal"
}

# --- done signal detection ---
DONE_SIGNAL="TASKMASTER_DONE::${SESSION_ID}"
HAS_DONE_SIGNAL=false
HAS_RECENT_ERRORS=false

# Check last_assistant_message first (available immediately, unlike transcript)
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')
if echo "$LAST_MSG" | grep -Fq "$DONE_SIGNAL" 2>/dev/null; then
  HAS_DONE_SIGNAL=true
fi

# Fall back to transcript search
if [ "$HAS_DONE_SIGNAL" = false ] && [ -f "$TRANSCRIPT" ]; then
  if transcript_has_done_signal "$TRANSCRIPT" "$DONE_SIGNAL"; then
    HAS_DONE_SIGNAL=true
  fi
fi

if [ -f "$TRANSCRIPT" ]; then
  TAIL_40=$(tail -40 "$TRANSCRIPT" 2>/dev/null || true)
  if echo "$TAIL_40" | grep -qi '"is_error":\s*true' 2>/dev/null; then
    HAS_RECENT_ERRORS=true
  fi
fi

if [ "$HAS_DONE_SIGNAL" = true ]; then
  if [ -n "${TASKMASTER_VERIFY_COMMAND:-}" ]; then
    if taskmaster_run_verify_command; then
      taskmaster_state_update "$SESSION_ID" '.stop_count = 0'
      exit 0
    else
      VERIFY_REASON="$(generate_taskmaster_injected_tag verifier-feedback)
TASKMASTER: verifier failed (exit=${TASKMASTER_VERIFY_EXIT_CODE}). Command: ${TASKMASTER_VERIFY_COMMAND}

Output (last ${TASKMASTER_VERIFY_MAX_OUTPUT:-4000} bytes):
${TASKMASTER_VERIFY_OUTPUT_TAIL}

Token alone is insufficient when a verifier is configured. Fix the failures and try again."
      jq -n --arg reason "$VERIFY_REASON" '{ decision: "block", reason: $reason }'
      exit 0
    fi
  fi
  taskmaster_state_update "$SESSION_ID" '.stop_count = 0'
  exit 0
fi

taskmaster_state_increment_stop_count "$SESSION_ID"
NEXT=$((COUNT + 1))

# Optional escape hatch after MAX continuations.
if [ "$MAX" -gt 0 ] && [ "$NEXT" -ge "$MAX" ]; then
  taskmaster_state_update "$SESSION_ID" '.stop_count = 0'
  exit 0
fi

if [ "$HAS_RECENT_ERRORS" = true ]; then
  PREAMBLE="Recent tool errors were detected. Resolve them before declaring done."
else
  PREAMBLE="Stop is blocked until completion is explicitly confirmed."
fi

if [ "$MAX" -gt 0 ]; then
  LABEL="TASKMASTER (${NEXT}/${MAX})"
else
  LABEL="TASKMASTER (${NEXT})"
fi

# --- reprompt ---
SHARED_PROMPT="$(build_taskmaster_compliance_prompt "$DONE_SIGNAL")"
INJECTED_TAG="$(generate_taskmaster_injected_tag stop-block)"
REASON="${INJECTED_TAG}
${LABEL}: ${PREAMBLE}

${SHARED_PROMPT}"

jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
