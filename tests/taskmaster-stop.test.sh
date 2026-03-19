#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOP_HOOK="$REPO_ROOT/hooks/taskmaster-stop.sh"
TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/taskmaster-stop-test.XXXXXX")"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

TRANSCRIPT_PATH="$TEST_TMPDIR/transcript.jsonl"

cat > "$TRANSCRIPT_PATH" <<'EOF'
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Old finished task"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Finished old task\nTASKMASTER_DONE::session-123"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Implement native Codex hooks"}]}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Partial progress only."}]}}
EOF

first_output="$(
  jq -n \
    --arg session_id "session-123" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg last_assistant_message "Partial progress only." \
    --arg cwd "$TEST_TMPDIR" \
    '{
      session_id: $session_id,
      transcript_path: $transcript_path,
      last_assistant_message: $last_assistant_message,
      stop_hook_active: false,
      cwd: $cwd
    }' | "$STOP_HOOK"
)"

if [[ "$(printf '%s' "$first_output" | jq -r '.decision')" != "block" ]]; then
  printf 'expected first stop attempt to block\n' >&2
  printf '%s\n' "$first_output" >&2
  exit 1
fi

first_reason="$(printf '%s' "$first_output" | jq -r '.reason')"
if ! grep -F "TASKMASTER_SELF_CHECK::session-123" <<<"$first_reason" >/dev/null 2>&1; then
  printf 'expected self-check marker in first block reason\n' >&2
  printf '%s\n' "$first_reason" >&2
  exit 1
fi

if ! grep -F "Implement native Codex hooks" <<<"$first_reason" >/dev/null 2>&1; then
  printf 'expected current task anchor in first block reason\n' >&2
  printf '%s\n' "$first_reason" >&2
  exit 1
fi

if grep -F "Old finished task" <<<"$first_reason" >/dev/null 2>&1; then
  printf 'did not expect old completed task in first block reason\n' >&2
  printf '%s\n' "$first_reason" >&2
  exit 1
fi

final_message=$'TASKMASTER_SELF_CHECK::session-123\nGOAL_ACHIEVED::yes\nTASKMASTER_DONE::session-123'

repeat_output="$(
  jq -n \
    --arg session_id "session-123" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg last_assistant_message "$final_message" \
    --arg cwd "$TEST_TMPDIR" \
    '{
      session_id: $session_id,
      transcript_path: $transcript_path,
      last_assistant_message: $last_assistant_message,
      stop_hook_active: true,
      cwd: $cwd
    }' | "$STOP_HOOK"
)"

if [[ -n "$repeat_output" ]]; then
  printf 'expected compliant repeated stop attempt to allow stop with no output\n' >&2
  printf '%s\n' "$repeat_output" >&2
  exit 1
fi

verify_input="$(
  jq -n \
    --arg session_id "session-123" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg last_assistant_message "$final_message" \
    --arg cwd "$TEST_TMPDIR" \
    '{
      session_id: $session_id,
      transcript_path: $transcript_path,
      last_assistant_message: $last_assistant_message,
      stop_hook_active: true,
      cwd: $cwd
    }'
)"

verify_output="$(TASKMASTER_VERIFY_COMMAND='printf "verification failed\n" >&2; exit 1' "$STOP_HOOK" <<<"$verify_input")"

if [[ "$(printf '%s' "$verify_output" | jq -r '.decision')" != "block" ]]; then
  printf 'expected verifier failure to block stop\n' >&2
  printf '%s\n' "$verify_output" >&2
  exit 1
fi

verify_reason="$(printf '%s' "$verify_output" | jq -r '.reason')"
if ! grep -F "native verification failed" <<<"$verify_reason" >/dev/null 2>&1; then
  printf 'expected verifier failure reason\n' >&2
  printf '%s\n' "$verify_reason" >&2
  exit 1
fi

echo "ok"
