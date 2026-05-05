#!/usr/bin/env bash
#
# Optional shell verifier gate for the Taskmaster stop hook.
#
# When TASKMASTER_VERIFY_COMMAND is set, calling taskmaster_run_verify_command
# runs the command with a timeout, captures combined output (truncated), and
# sets:
#   TASKMASTER_VERIFY_EXIT_CODE   the command's exit code
#   TASKMASTER_VERIFY_OUTPUT_TAIL last $TASKMASTER_VERIFY_MAX_OUTPUT bytes of output
# It returns the command's exit code (0 = pass, non-zero = block).
# When unset, returns 0 with empty fields (no-op pass).
#
# Env knobs:
#   TASKMASTER_VERIFY_COMMAND     command string; empty/unset = skip
#   TASKMASTER_VERIFY_TIMEOUT     seconds before SIGTERM (default 60); +5s grace SIGKILL
#   TASKMASTER_VERIFY_MAX_OUTPUT  bytes of output kept (default 4000)
#   TASKMASTER_VERIFY_CWD         optional cwd override
#

taskmaster_run_verify_command() {
  TASKMASTER_VERIFY_OUTPUT_TAIL=""
  TASKMASTER_VERIFY_EXIT_CODE=""

  local cmd="${TASKMASTER_VERIFY_COMMAND:-}"
  if [[ -z "$cmd" ]]; then
    return 0
  fi

  local timeout_sec="${TASKMASTER_VERIFY_TIMEOUT:-60}"
  local max_output="${TASKMASTER_VERIFY_MAX_OUTPUT:-4000}"
  local cwd="${TASKMASTER_VERIFY_CWD:-}"
  local out_file rc=0
  local prev_errexit=0
  case $- in *e*) prev_errexit=1;; esac
  set +e

  out_file="$(mktemp "${TMPDIR:-/tmp}/taskmaster-verify.XXXXXX")"
  trap 'rm -f "$out_file"' RETURN

  if [[ -n "$cwd" ]]; then
    ( cd "$cwd" && timeout --kill-after=5 "$timeout_sec" bash -c "$cmd" ) \
      >"$out_file" 2>&1
    rc=$?
  else
    timeout --kill-after=5 "$timeout_sec" bash -c "$cmd" >"$out_file" 2>&1
    rc=$?
  fi

  TASKMASTER_VERIFY_OUTPUT_TAIL="$(tail -c "$max_output" "$out_file" 2>/dev/null || true)"
  TASKMASTER_VERIFY_EXIT_CODE="$rc"

  rm -f "$out_file"
  if [[ "$prev_errexit" == "1" ]]; then set -e; fi
  return "$rc"
}
