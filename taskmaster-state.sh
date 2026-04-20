#!/usr/bin/env bash
set -euo pipefail

taskmaster_state_dir() {
  printf '%s\n' "${TASKMASTER_STATE_DIR:-$HOME/.codex/taskmaster/state}"
}

taskmaster_turn_state_dir() {
  printf '%s/taskmaster-turn-state\n' "$(taskmaster_state_dir)"
}

taskmaster_turn_state_path() {
  local session_id="$1"
  printf '%s/%s.json\n' "$(taskmaster_turn_state_dir)" "$session_id"
}
