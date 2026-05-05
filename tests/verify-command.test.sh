#!/usr/bin/env bash
#
# Tests for taskmaster-verify-command.sh.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/taskmaster-verify-command.sh"

# shellcheck disable=SC1090
source "$LIB"

PASS_COUNT=0
FAIL_COUNT=0

assert() {
  local name="$1"
  local condition="$2"
  if eval "$condition"; then
    printf 'ok  %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf 'FAIL %s\n' "$name" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- Unset command is a no-op pass ---
unset TASKMASTER_VERIFY_COMMAND TASKMASTER_VERIFY_TIMEOUT TASKMASTER_VERIFY_MAX_OUTPUT TASKMASTER_VERIFY_CWD
TASKMASTER_VERIFY_OUTPUT_TAIL=""
TASKMASTER_VERIFY_EXIT_CODE=""
taskmaster_run_verify_command
assert "unset command returns 0" "[[ \"$?\" == \"0\" ]]"
assert "unset command leaves exit code blank" "[[ -z \"$TASKMASTER_VERIFY_EXIT_CODE\" ]]"

# --- Successful command ---
TASKMASTER_VERIFY_COMMAND="true"
taskmaster_run_verify_command
rc=$?
assert "successful command returns 0" "[[ \"$rc\" == \"0\" ]]"
assert "successful command sets exit code 0" "[[ \"$TASKMASTER_VERIFY_EXIT_CODE\" == \"0\" ]]"

# --- Failing command ---
TASKMASTER_VERIFY_COMMAND="exit 7"
set +e; taskmaster_run_verify_command; rc=$?; set -e
assert "failing command propagates exit code" "[[ \"$rc\" == \"7\" ]]"
assert "failing command captures exit code 7" "[[ \"$TASKMASTER_VERIFY_EXIT_CODE\" == \"7\" ]]"

# --- Output captured ---
TASKMASTER_VERIFY_COMMAND='echo hello-world; echo to-stderr >&2'
taskmaster_run_verify_command
assert "stdout captured" '[[ "$TASKMASTER_VERIFY_OUTPUT_TAIL" == *hello-world* ]]'
assert "stderr captured (combined)" '[[ "$TASKMASTER_VERIFY_OUTPUT_TAIL" == *to-stderr* ]]'

# --- Output truncation ---
TASKMASTER_VERIFY_COMMAND='yes hello | head -c 50000'
TASKMASTER_VERIFY_MAX_OUTPUT=200
taskmaster_run_verify_command
unset TASKMASTER_VERIFY_MAX_OUTPUT
assert "output truncated to MAX_OUTPUT bytes" "[[ \"\${#TASKMASTER_VERIFY_OUTPUT_TAIL}\" -le 200 ]]"

# --- Timeout ---
TASKMASTER_VERIFY_COMMAND='sleep 30'
TASKMASTER_VERIFY_TIMEOUT=1
set +e; START=$(date +%s); taskmaster_run_verify_command; rc=$?; END=$(date +%s); set -e
unset TASKMASTER_VERIFY_TIMEOUT
ELAPSED=$((END - START))
assert "timeout fires within 10s" "[[ \"$ELAPSED\" -lt 10 ]]"
assert "timeout produces non-zero exit" "[[ \"$rc\" != \"0\" ]]"

# --- CWD respected ---
TMPCWD="$(mktemp -d)"
trap 'rm -rf "$TMPCWD"' EXIT
TASKMASTER_VERIFY_COMMAND='pwd'
TASKMASTER_VERIFY_CWD="$TMPCWD"
taskmaster_run_verify_command
unset TASKMASTER_VERIFY_CWD
TMPCWD_REAL="$(cd "$TMPCWD" && pwd -P)"
assert "cwd honored" '[[ "$TASKMASTER_VERIFY_OUTPUT_TAIL" == *"$TMPCWD_REAL"* ]]'

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" == 0 ]]
