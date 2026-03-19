#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../taskmaster-compliance-prompt.sh"

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown-session"')"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')"
LAST_MSG="$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""')"
STOP_HOOK_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // "."')"

TRANSCRIPT="${TRANSCRIPT/#\~/$HOME}"
DONE_SIGNAL="TASKMASTER_DONE::${SESSION_ID}"
SELF_CHECK_SIGNAL="TASKMASTER_SELF_CHECK::${SESSION_ID}"
FORCE_REVIEW_PASS="${TASKMASTER_FORCE_REVIEW_PASS:-1}"
VERIFY_CMD="${TASKMASTER_VERIFY_COMMAND:-}"
VERIFY_MAX_OUTPUT="${TASKMASTER_VERIFY_MAX_OUTPUT:-4000}"
VERIFY_NOTE=""
if [[ -n "$VERIFY_CMD" ]]; then
  VERIFY_NOTE=$'\n\nA native verifier is enabled. Even after GOAL_ACHIEVED::yes and the done token, stop will stay blocked until this command passes:\n'"$VERIFY_CMD"
fi

transcript_has_recent_errors() {
  local transcript_path="$1"

  [[ -f "$transcript_path" ]] || return 1
  tail -40 "$transcript_path" 2>/dev/null | grep -qi '"is_error":\s*true'
}

extract_active_task_state_from_transcript() {
  local transcript_path="$1"
  local done_signal="$2"

  [[ -f "$transcript_path" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  python3 - "$transcript_path" "$done_signal" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
done_signal = sys.argv[2]
if not path.exists():
    raise SystemExit(0)


def normalize(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        return ""
    lines = [line.rstrip() for line in text.splitlines()]
    text = "\n".join(lines)
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.strip()


def clip(text: str, limit: int = 1200) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def message_text_from_content(content):
    parts = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, str):
                parts.append(item)
                continue
            if not isinstance(item, dict):
                continue
            text = item.get("text")
            if isinstance(text, str) and text.strip():
                parts.append(text)
                continue
            if item.get("type") in {"input_text", "output_text"}:
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    parts.append(text)
                    continue
            inner = item.get("content")
            if isinstance(inner, str) and inner.strip():
                parts.append(inner)
    elif isinstance(content, str):
        parts.append(content)
    return normalize("\n".join(parts))


def extract_role_and_text(obj):
    if not isinstance(obj, dict):
        return None, None

    if obj.get("type") == "response_item":
        payload = obj.get("payload")
        if isinstance(payload, dict) and payload.get("type") == "message":
            role = payload.get("role")
            text = message_text_from_content(payload.get("content"))
            if role and text:
                return role, text

    role = obj.get("role")
    if isinstance(role, str):
        text = message_text_from_content(obj.get("content"))
        if not text:
            text_val = obj.get("text")
            if isinstance(text_val, str):
                text = normalize(text_val)
        if text:
            return role, text

    payload = obj.get("payload")
    if isinstance(payload, dict):
        role = payload.get("role")
        if isinstance(role, str):
            text = message_text_from_content(payload.get("content"))
            if text:
                return role, text

    message = obj.get("message")
    if isinstance(message, dict):
        role = message.get("role") or obj.get("role")
        if isinstance(role, str):
            text = message_text_from_content(message.get("content"))
            if text:
                return role, text

    return None, None


messages = []
with path.open("r", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        role, text = extract_role_and_text(obj)
        if role and text:
            messages.append({"role": role, "text": text})

last_done_idx = -1
for i, message in enumerate(messages):
    if message["role"] == "assistant" and done_signal in message["text"]:
        last_done_idx = i

segment = messages[last_done_idx + 1 :] if last_done_idx >= 0 else messages
segment_users = [m["text"] for m in segment if m["role"] == "user"]
all_users = [m["text"] for m in messages if m["role"] == "user"]
last_assistant = ""
for message in reversed(segment):
    if message["role"] == "assistant":
        last_assistant = message["text"]
        break


def unique_preserve_order(values):
    out = []
    for value in values:
        if value not in out:
            out.append(value)
    return out


anchor_blocks = []
if last_done_idx >= 0:
    if segment_users:
        unique_segment = unique_preserve_order(segment_users)
        root = unique_segment[0]
        anchor_blocks.append("Current task root request, this started after the previous done token:\n1. " + clip(root))
        refinements = unique_segment[1:]
        if refinements:
            anchor_blocks.append(
                "Current task refinements or overrides:\n"
                + "\n\n".join(f"{i + 1}. {clip(msg)}" for i, msg in enumerate(refinements))
            )
else:
    recent = unique_preserve_order(all_users[-4:])
    if recent:
        anchor_blocks.append(
            "Recent active user instructions, newest task context is inferred from these messages:\n"
            + "\n\n".join(f"{i + 1}. {clip(msg)}" for i, msg in enumerate(recent))
        )

anchor = "\n\n".join(anchor_blocks).strip()
if len(anchor) > 4000:
    anchor = anchor[:3999].rstrip() + "…"

print(json.dumps({"goal_anchor": anchor, "last_assistant": last_assistant}))
PY
}

run_optional_verifier() {
  local verifier_cmd="$1"
  local cwd="$2"
  local max_output="$3"

  [[ -n "$verifier_cmd" ]] || return 0

  local tmp_output
  tmp_output="$(mktemp "${TMPDIR:-/tmp}/taskmaster-verify.XXXXXX")"
  (
    cd "$cwd"
    bash -lc "$verifier_cmd"
  ) >"$tmp_output" 2>&1 || {
    local truncated
    truncated="$(tail -c "$max_output" "$tmp_output" 2>/dev/null || true)"
    rm -f "$tmp_output"
    jq -n --arg reason "Completion self-check passed, but native verification failed. Fix the remaining issues, rerun verification, and only then stop.

Verification command:
${verifier_cmd}

Last output:
${truncated}" '{ decision: "block", reason: $reason }'
    return 1
  }

  rm -f "$tmp_output"
  return 0
}

LAST_MSG_FALLBACK=""
GOAL_ANCHOR=""
if [[ -f "$TRANSCRIPT" ]]; then
  STATE_JSON="$(extract_active_task_state_from_transcript "$TRANSCRIPT" "$DONE_SIGNAL" || true)"
  if [[ -n "$STATE_JSON" ]]; then
    GOAL_ANCHOR="$(printf '%s' "$STATE_JSON" | jq -r '.goal_anchor // ""' 2>/dev/null || true)"
    LAST_MSG_FALLBACK="$(printf '%s' "$STATE_JSON" | jq -r '.last_assistant // ""' 2>/dev/null || true)"
  fi
fi

if [[ -z "$LAST_MSG" ]]; then
  LAST_MSG="$LAST_MSG_FALLBACK"
fi

HAS_RECENT_ERRORS=false
if transcript_has_recent_errors "$TRANSCRIPT"; then
  HAS_RECENT_ERRORS=true
fi

has_self_check_marker() {
  local text="$1"

  [[ -n "$text" ]] && grep -Fq "$SELF_CHECK_SIGNAL" <<<"$text" 2>/dev/null
}

has_goal_yes() {
  local text="$1"

  [[ -n "$text" ]] && grep -Eq '(^|[[:space:]])GOAL_ACHIEVED::yes($|[[:space:]])' <<<"$text" 2>/dev/null
}

has_done_signal() {
  local text="$1"

  [[ -n "$text" ]] && grep -Fq "$DONE_SIGNAL" <<<"$text" 2>/dev/null
}

REPEAT_MODE=false
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  REPEAT_MODE=true
fi

if [[ "$FORCE_REVIEW_PASS" != "0" && "$REPEAT_MODE" != "true" ]]; then
  REASON="$(build_taskmaster_stop_block_reason "$DONE_SIGNAL" "$SELF_CHECK_SIGNAL" false "$HAS_RECENT_ERRORS" "$VERIFY_NOTE" "$GOAL_ANCHOR")"
  jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
  exit 0
fi

if ! has_self_check_marker "$LAST_MSG"; then
  REASON="$(build_taskmaster_stop_block_reason "$DONE_SIGNAL" "$SELF_CHECK_SIGNAL" true "$HAS_RECENT_ERRORS" "$VERIFY_NOTE" "$GOAL_ANCHOR")"
  jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
  exit 0
fi

if ! has_goal_yes "$LAST_MSG"; then
  REASON="$(build_taskmaster_stop_block_reason "$DONE_SIGNAL" "$SELF_CHECK_SIGNAL" true "$HAS_RECENT_ERRORS" "$VERIFY_NOTE" "$GOAL_ANCHOR")"
  jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
  exit 0
fi

if ! has_done_signal "$LAST_MSG"; then
  REASON="$(build_taskmaster_stop_block_reason "$DONE_SIGNAL" "$SELF_CHECK_SIGNAL" true "$HAS_RECENT_ERRORS" "$VERIFY_NOTE" "$GOAL_ANCHOR")"
  jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'
  exit 0
fi

if run_optional_verifier "$VERIFY_CMD" "$CWD" "$VERIFY_MAX_OUTPUT"; then
  exit 0
fi

exit 0
