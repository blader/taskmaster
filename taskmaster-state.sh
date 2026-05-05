#!/usr/bin/env bash
#
# Persistent JSON session state for Taskmaster.
#
# Layout: ${TASKMASTER_STATE_DIR:-${TMPDIR:-/tmp}/taskmaster/state}/<session_id>.json
#
# Schema (v1):
# {
#   "schema_version": 1,
#   "session_id": "<sid>",
#   "created_at": "<iso8601>",
#   "updated_at": "<iso8601>",
#   "stop_count": 0,
#   "latest_user_prompt": null | {captured_at, turn_id, prompt},
#   "last_verifier_run":  null | {ran_at, input_hash, complete, reason, next_action},
#   "metadata": {}
# }
#
# Atomicity: all writes go through tmp+mv guarded by flock on <path>.lock.
#

# Idempotent re-source guard (matches Phase B prompt-detect pattern).
[[ -n "${TASKMASTER_STATE_LOADED:-}" ]] && return 0
readonly TASKMASTER_STATE_LOADED=1

taskmaster_state_dir() {
  printf '%s\n' "${TASKMASTER_STATE_DIR:-${TMPDIR:-/tmp}/taskmaster/state}"
}

taskmaster_state_path() {
  local sid="$1"
  printf '%s/%s.json\n' "$(taskmaster_state_dir)" "$sid"
}

taskmaster_state_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

taskmaster_state_init() {
  local sid="$1"
  local path tmp lock now
  path="$(taskmaster_state_path "$sid")"
  mkdir -p "$(dirname "$path")"
  [[ -f "$path" ]] && return 0

  lock="${path}.lock"
  tmp="${path}.tmp.$$"
  now="$(taskmaster_state_now)"

  exec 9>"$lock"
  flock 9
  if [[ ! -f "$path" ]]; then
    if jq -n \
        --arg sid "$sid" \
        --arg now "$now" \
        '{
          schema_version: 1,
          session_id: $sid,
          created_at: $now,
          updated_at: $now,
          stop_count: 0,
          latest_user_prompt: null,
          last_verifier_run: null,
          metadata: {}
        }' >"$tmp"; then
      mv "$tmp" "$path"
    else
      rm -f "$tmp"
      exec 9>&-
      return 1
    fi
  fi
  exec 9>&-
}

taskmaster_state_jq() {
  local sid="$1" expr="$2"
  local path
  path="$(taskmaster_state_path "$sid")"
  [[ -f "$path" ]] || return 0
  jq -r "$expr" <"$path" 2>/dev/null
}

# Run jq with a transformation expression and atomically write the result back.
taskmaster_state_update() {
  local sid="$1" expr="$2"
  local path tmp lock now
  path="$(taskmaster_state_path "$sid")"
  taskmaster_state_init "$sid"

  lock="${path}.lock"
  tmp="${path}.tmp.$$"
  now="$(taskmaster_state_now)"

  exec 9>"$lock"
  flock 9
  if jq --arg now "$now" "$expr | .updated_at = \$now" "$path" >"$tmp"; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    exec 9>&-
    return 1
  fi
  exec 9>&-
}

taskmaster_state_increment_stop_count() {
  local sid="$1"
  taskmaster_state_update "$sid" '.stop_count = (.stop_count + 1)'
}

taskmaster_state_capture_prompt() {
  local sid="$1" turn_id="$2" prompt="$3"
  local path tmp lock now
  path="$(taskmaster_state_path "$sid")"
  taskmaster_state_init "$sid"

  lock="${path}.lock"
  tmp="${path}.tmp.$$"
  now="$(taskmaster_state_now)"

  exec 9>"$lock"
  flock 9
  if jq \
      --arg now "$now" \
      --arg turn "$turn_id" \
      --arg prompt "$prompt" \
      '.latest_user_prompt = {captured_at: $now, turn_id: $turn, prompt: $prompt}
       | .updated_at = $now' \
      "$path" >"$tmp"; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    exec 9>&-
    return 1
  fi
  exec 9>&-
}

taskmaster_state_record_verifier_run() {
  local sid="$1" input_hash="$2" complete="$3" reason="$4" next_action="$5"
  case "$complete" in
    true|false) ;;
    *) return 64 ;;
  esac
  local path tmp lock now
  path="$(taskmaster_state_path "$sid")"
  taskmaster_state_init "$sid"

  lock="${path}.lock"
  tmp="${path}.tmp.$$"
  now="$(taskmaster_state_now)"

  exec 9>"$lock"
  flock 9
  if jq \
      --arg now "$now" \
      --arg hash "$input_hash" \
      --argjson complete "$complete" \
      --arg reason "$reason" \
      --arg next "$next_action" \
      '.last_verifier_run = {
          ran_at: $now,
          input_hash: $hash,
          complete: $complete,
          reason: $reason,
          next_action: $next
       } | .updated_at = $now' \
      "$path" >"$tmp"; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    exec 9>&-
    return 1
  fi
  exec 9>&-
}

# One-time migration: absorb legacy ${TMPDIR}/taskmaster/<sid> counter into the
# state file's stop_count, then delete the legacy file. Idempotent — safe to
# call on every hook entry.
taskmaster_state_migrate_legacy_counter() {
  local sid="$1"
  local legacy="${TMPDIR:-/tmp}/taskmaster/${sid}"
  [[ -f "$legacy" ]] || return 0

  local count
  count="$(cat "$legacy" 2>/dev/null || echo 0)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  # Cap length to prevent int overflow on downstream NEXT=$((COUNT + 1)).
  [[ ${#count} -le 12 ]] || count=0

  taskmaster_state_init "$sid"

  local path tmp lock now
  path="$(taskmaster_state_path "$sid")"
  lock="${path}.lock"
  tmp="${path}.tmp.$$"
  now="$(taskmaster_state_now)"

  exec 9>"$lock"
  flock 9
  # Re-check legacy file under lock — if a peer migrated already, no-op.
  if [[ -f "$legacy" ]]; then
    if jq --arg now "$now" --argjson n "$count" \
        '.stop_count = (.stop_count + $n) | .updated_at = $now' \
        "$path" >"$tmp"; then
      mv "$tmp" "$path"
      rm -f "$legacy"
    else
      rm -f "$tmp"
      exec 9>&-
      return 1
    fi
  fi
  exec 9>&-
}
