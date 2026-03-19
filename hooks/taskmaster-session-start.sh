#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../taskmaster-compliance-prompt.sh"

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown-session"')"
DONE_SIGNAL="TASKMASTER_DONE::${SESSION_ID}"
SELF_CHECK_SIGNAL="TASKMASTER_SELF_CHECK::${SESSION_ID}"

build_taskmaster_session_contract "$DONE_SIGNAL" "$SELF_CHECK_SIGNAL"
