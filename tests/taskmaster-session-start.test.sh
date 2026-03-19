#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_START_HOOK="$REPO_ROOT/hooks/taskmaster-session-start.sh"

output="$(
  jq -n --arg session_id "session-123" '{session_id: $session_id}' | "$SESSION_START_HOOK"
)"

if ! grep -F "TASKMASTER_SELF_CHECK::session-123" <<<"$output" >/dev/null 2>&1; then
  printf 'expected self-check marker in session-start contract\n' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

if ! grep -F "TASKMASTER_DONE::session-123" <<<"$output" >/dev/null 2>&1; then
  printf 'expected done marker in session-start contract\n' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo "ok"
