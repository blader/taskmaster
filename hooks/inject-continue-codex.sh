#!/usr/bin/env bash
#
# Codex Taskmaster same-process injector (queue-emitter mode).
# Watches a Codex session log and, on each incomplete task_complete/turn_complete,
# writes a continuation prompt file into the expect bridge queue.
#
# Exit codes:
#   0 = at least one done token observed
#   2 = completion(s) observed but no done token
#   3 = no completion events observed
#   4 = invalid usage / prerequisites
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../taskmaster-compliance-prompt.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../taskmaster-prompt-detect.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../taskmaster-state.sh"

usage() {
  cat <<'USAGE'
Usage:
  inject-continue-codex.sh --log <session_log.jsonl> --emit-dir <dir> [--state-dir <dir>] [--follow] [--follow-latest-dir <dir>] [--latest-glob <glob>] [--quiet]

Options:
  --log <path>      Path to CODEX_TUI_SESSION_LOG_PATH file.
  --emit-dir <dir>  Emit injection prompts as files in <dir>.
  --state-dir <dir> Persist follow-state in <dir> so a restarted injector resumes cleanly.
  --follow          Follow live updates until session_end.
  --follow-latest-dir <dir>  While following, switch to the newest matching log in <dir>.
  --latest-glob <glob>       Glob used under --follow-latest-dir. Default: taskmaster-session-*.jsonl
  --quiet           Suppress non-error output.
  -h, --help        Show help.
USAGE
}

LOG_PATH="${CODEX_TUI_SESSION_LOG_PATH:-}"
EMIT_DIR=""
STATE_DIR=""
FOLLOW=0
QUIET=1
DONE_PREFIX="TASKMASTER_DONE"
POLL_INTERVAL="1"
FOLLOW_LATEST_DIR=""
LATEST_GLOB="taskmaster-session-*.jsonl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)
      LOG_PATH="${2:-}"
      shift 2
      ;;
    --emit-dir)
      EMIT_DIR="${2:-}"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="${2:-}"
      shift 2
      ;;
    --follow)
      FOLLOW=1
      shift
      ;;
    --follow-latest-dir)
      FOLLOW_LATEST_DIR="${2:-}"
      shift 2
      ;;
    --latest-glob)
      LATEST_GLOB="${2:-}"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 4
      ;;
  esac
done

if [[ -z "$LOG_PATH" ]]; then
  echo "Missing --log (or CODEX_TUI_SESSION_LOG_PATH)." >&2
  exit 4
fi

if [[ -z "$EMIT_DIR" ]]; then
  echo "Missing --emit-dir." >&2
  exit 4
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 4
fi

mkdir -p "$EMIT_DIR"
STATE_FILE=""
if [[ -n "$STATE_DIR" ]]; then
  mkdir -p "$STATE_DIR"
  STATE_FILE="$STATE_DIR/injector-state.env"
fi
RUNTIME_LOG="${TASKMASTER_RUNTIME_LOG:-}"

SESSION_ID=""
DONE_FOUND=0
SESSION_ENDED=0
TASK_COMPLETE_COUNT=0
INJECTION_COUNT=0
LAST_HANDLED_TURN_ID=""
LAST_HANDLED_SIG=""
CURRENT_LOG_PATH=""
OFFSET=0
PENDING_PARTIAL_LINE=""

log_runtime() {
  local message="$1"
  [[ -n "$RUNTIME_LOG" ]] || return 0
  mkdir -p "$(dirname "$RUNTIME_LOG")"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >>"$RUNTIME_LOG"
}

save_state() {
  [[ -n "$STATE_FILE" ]] || return 0
  # Best-effort: state dir may already be cleaned up by parent
  [[ -d "$(dirname "$STATE_FILE")" ]] || return 0
  cat >"$STATE_FILE" <<EOF
LOG_PATH=$(printf '%q' "$LOG_PATH")
CURRENT_LOG_PATH=$(printf '%q' "$CURRENT_LOG_PATH")
OFFSET=$(printf '%q' "$OFFSET")
SESSION_ID=$(printf '%q' "$SESSION_ID")
DONE_FOUND=$(printf '%q' "$DONE_FOUND")
SESSION_ENDED=$(printf '%q' "$SESSION_ENDED")
TASK_COMPLETE_COUNT=$(printf '%q' "$TASK_COMPLETE_COUNT")
INJECTION_COUNT=$(printf '%q' "$INJECTION_COUNT")
LAST_HANDLED_TURN_ID=$(printf '%q' "$LAST_HANDLED_TURN_ID")
LAST_HANDLED_SIG=$(printf '%q' "$LAST_HANDLED_SIG")
EOF
}

load_state() {
  [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

on_exit() {
  local rc=$?
  save_state 2>/dev/null || true
  log_runtime "injector_exit rc=${rc} current_log=${CURRENT_LOG_PATH:-$LOG_PATH} session_id=${SESSION_ID:-} task_completes=${TASK_COMPLETE_COUNT} injections=${INJECTION_COUNT} session_ended=${SESSION_ENDED}" 2>/dev/null || true
}

trap on_exit EXIT
load_state
log_runtime "injector_start log=${LOG_PATH} follow=${FOLLOW} latest_dir=${FOLLOW_LATEST_DIR:-} state_file=${STATE_FILE:-}"

build_reprompt() {
  local sid="$1"
  local token
  local shared_prompt

  if [[ -n "$sid" && "$sid" != "null" ]]; then
    token="${DONE_PREFIX}::${sid}"
  else
    token="${DONE_PREFIX}::<session_id>"
  fi

  shared_prompt="$(build_taskmaster_compliance_prompt "$token")"

  local injected_tag
  injected_tag="$(generate_taskmaster_injected_tag followup)"
  cat <<RE-PROMPT
${injected_tag}
TASKMASTER: Stop is blocked until completion is explicitly confirmed.

${shared_prompt}
RE-PROMPT
}

is_done_text() {
  local text="$1"
  [[ -n "$text" ]] || return 1

  if [[ -n "$SESSION_ID" ]]; then
    [[ "$text" == *"${DONE_PREFIX}::${SESSION_ID}"* ]]
  else
    [[ "$text" == *"${DONE_PREFIX}::"* ]]
  fi
}

clear_pending_prompts() {
  rm -f "$EMIT_DIR"/inject.*.txt
}

mark_done() {
  DONE_FOUND=1
}

inject_prompt() {
  local turn_id="$1"
  local sid_for_prompt="$2"
  local prompt_file
  local prompt

  prompt="$(build_reprompt "$sid_for_prompt")"

  prompt_file="$(mktemp "$EMIT_DIR/inject.XXXXXX")"
  mv "$prompt_file" "$prompt_file.txt"
  prompt_file="$prompt_file.txt"
  printf '%s' "$prompt" > "$prompt_file"

  INJECTION_COUNT=$((INJECTION_COUNT + 1))
  if [[ -n "${SESSION_ID:-}" ]]; then
    taskmaster_state_increment_stop_count "$SESSION_ID" 2>/dev/null || true
  fi
  log_runtime "queued continuation prompt turn=${turn_id:-<unknown>} count=${INJECTION_COUNT} file=${prompt_file}"
  if [[ "$QUIET" -eq 0 ]]; then
    echo "[TASKMASTER] queued continuation prompt for turn ${turn_id:-<unknown>} (count=${INJECTION_COUNT}, file=${prompt_file})." >&2
  fi
}

process_line() {
  local line="$1"
  [[ -n "$line" ]] || return 0

  local kind msg_type sid thread_id turn_id msg_text sig

  kind="$(jq -Rr 'fromjson? | .kind // empty' <<<"$line" 2>/dev/null || true)"
  [[ -n "$kind" ]] || return 0

  case "$kind" in
    codex_event)
      msg_type="$(jq -Rr 'fromjson? | .payload.msg.type // empty' <<<"$line" 2>/dev/null || true)"
      case "$msg_type" in
        session_configured)
          sid="$(jq -Rr 'fromjson? | .payload.msg.session_id // empty' <<<"$line" 2>/dev/null || true)"
          if [[ -n "$sid" && "$sid" != "null" ]]; then
            SESSION_ID="$sid"
            [[ "$QUIET" -eq 1 ]] || echo "[TASKMASTER] attached to session $SESSION_ID" >&2
          fi
          ;;
        task_complete|turn_complete)
          TASK_COMPLETE_COUNT=$((TASK_COMPLETE_COUNT + 1))
          sid="$(jq -Rr 'fromjson? | .payload.msg.session_id // empty' <<<"$line" 2>/dev/null || true)"
          thread_id="$(jq -Rr 'fromjson? | .payload.msg.thread_id // empty' <<<"$line" 2>/dev/null || true)"
          turn_id="$(jq -Rr 'fromjson? | .payload.msg.turn_id // empty' <<<"$line" 2>/dev/null || true)"
          msg_text="$(jq -Rr 'fromjson? | .payload.msg.last_agent_message // ""' <<<"$line" 2>/dev/null || true)"

          if [[ -z "$SESSION_ID" ]]; then
            if [[ -n "$sid" && "$sid" != "null" ]]; then
              SESSION_ID="$sid"
            elif [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
              SESSION_ID="$thread_id"
            fi
          fi

          if [[ -n "$turn_id" && "$turn_id" == "$LAST_HANDLED_TURN_ID" ]]; then
            return
          fi

          if [[ -z "$turn_id" ]]; then
            sig="$(printf '%s' "$msg_text" | cksum | awk '{print $1":"$2}')"
            if [[ -n "$sig" && "$sig" == "$LAST_HANDLED_SIG" ]]; then
              return
            fi
            LAST_HANDLED_SIG="$sig"
          else
            LAST_HANDLED_TURN_ID="$turn_id"
          fi

          if is_done_text "$msg_text"; then
            mark_done
            [[ "$QUIET" -eq 1 ]] || echo "[TASKMASTER] done token detected; no injection for turn ${turn_id:-<unknown>}." >&2
          else
            inject_prompt "$turn_id" "$SESSION_ID"
          fi
          ;;
      esac
      ;;
    session_end)
      SESSION_ENDED=1
      ;;
  esac
}

process_chunk() {
  local chunk="$1"
  local has_complete_tail="${2:-0}"
  local combined_chunk
  local line
  local trailing_partial=""

  combined_chunk="${PENDING_PARTIAL_LINE}${chunk}"
  PENDING_PARTIAL_LINE=""

  if [[ "$has_complete_tail" == "1" ]]; then
    combined_chunk+=$'\n'
  elif [[ "$combined_chunk" != *$'\n' ]]; then
    trailing_partial="${combined_chunk##*$'\n'}"
    if [[ "$combined_chunk" == "$trailing_partial" ]]; then
      PENDING_PARTIAL_LINE="$combined_chunk"
      return 0
    fi
    combined_chunk="${combined_chunk%$trailing_partial}"
    PENDING_PARTIAL_LINE="$trailing_partial"
  fi

  while IFS= read -r line; do
    process_line "$line" || true
  done <<<"$combined_chunk"
}

latest_log_path() {
  local dir="$1"
  local glob="$2"
  local latest=""
  local expanded=()
  shopt -s nullglob
  expanded=("$dir"/$glob)
  shopt -u nullglob
  if [[ ${#expanded[@]} -eq 0 ]]; then
    return 0
  fi
  latest="$(ls -t "${expanded[@]}" 2>/dev/null | head -n 1 || true)"
  [[ -n "$latest" ]] && printf '%s\n' "$latest"
}

switch_log_if_needed() {
  local latest=""
  if [[ -z "$FOLLOW_LATEST_DIR" ]]; then
    return 0
  fi
  latest="$(latest_log_path "$FOLLOW_LATEST_DIR" "$LATEST_GLOB")"
  if [[ -z "$latest" ]]; then
    return 0
  fi
  if [[ "$latest" == "$CURRENT_LOG_PATH" ]]; then
    return 0
  fi
  CURRENT_LOG_PATH="$latest"
  LOG_PATH="$latest"
  OFFSET=0
  SESSION_ID=""
  SESSION_ENDED=0
  LAST_HANDLED_TURN_ID=""
  LAST_HANDLED_SIG=""
  save_state
  log_runtime "injector_switch_log log=${CURRENT_LOG_PATH}"
  [[ "$QUIET" -eq 1 ]] || echo "[TASKMASTER] switched to latest session log: $CURRENT_LOG_PATH" >&2
}

if [[ "$FOLLOW" -eq 1 ]]; then
  CURRENT_LOG_PATH="$LOG_PATH"
  while [[ ! -f "$LOG_PATH" ]]; do
    switch_log_if_needed
    sleep "$POLL_INTERVAL"
  done
elif [[ ! -f "$LOG_PATH" ]]; then
  echo "Log path does not exist: $LOG_PATH" >&2
  exit 4
fi

while true; do
  switch_log_if_needed

  if [[ ! -f "$LOG_PATH" ]]; then
    if [[ "$FOLLOW" -eq 1 ]]; then
      sleep "$POLL_INTERVAL"
      continue
    fi
    echo "Log path does not exist: $LOG_PATH" >&2
    exit 4
  fi

  local_size="$(wc -c <"$LOG_PATH" 2>/dev/null || echo 0)"
  if [[ "$local_size" -lt "$OFFSET" ]]; then
    OFFSET=0
  fi

  if [[ "$local_size" -gt "$OFFSET" ]]; then
    chunk="$(tail -c +"$((OFFSET + 1))" "$LOG_PATH" 2>/dev/null || true)"
    has_complete_tail=0
    last_byte_hex="$(tail -c 1 "$LOG_PATH" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')"
    if [[ "$last_byte_hex" == "0a" ]]; then
      has_complete_tail=1
    fi
    process_chunk "$chunk" "$has_complete_tail"
    OFFSET="$local_size"
  fi

  if [[ "$FOLLOW" -eq 0 ]]; then
    break
  fi

  if [[ -z "$FOLLOW_LATEST_DIR" && "$SESSION_ENDED" -eq 1 ]]; then
    break
  fi

  sleep "$POLL_INTERVAL"
done

if [[ "$TASK_COMPLETE_COUNT" -eq 0 ]]; then
  exit 3
fi

if [[ "$INJECTION_COUNT" -gt 0 ]]; then
  exit 2
fi

if [[ "$DONE_FOUND" -eq 1 ]]; then
  exit 0
fi

exit 2
