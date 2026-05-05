#!/usr/bin/env bash
#
# Tests for taskmaster-prompt-detect.sh.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/taskmaster-prompt-detect.sh"

# shellcheck disable=SC1090
source "$LIB"

PASS_COUNT=0
FAIL_COUNT=0

assert_detected() {
  local name="$1"
  local text="$2"
  if is_taskmaster_injected_prompt "$text"; then
    printf 'ok  %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf 'FAIL %s\n' "$name" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_detected() {
  local name="$1"
  local text="$2"
  if is_taskmaster_injected_prompt "$text"; then
    printf 'FAIL %s (false positive)\n' "$name" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    printf 'ok  %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# --- Tag detection ---
assert_detected "tagged stop-block" \
  "[taskmaster:injected v=1 kind=stop-block]
TASKMASTER (1): Stop is blocked..."

assert_detected "tagged followup" \
  "[taskmaster:injected v=1 kind=followup]
continue"

assert_detected "tagged compliance" "[taskmaster:injected v=1 kind=compliance]"

# --- Forward-compat: future schema version still detected ---
assert_detected "future schema v=99" "[taskmaster:injected v=99 kind=anything]"

# --- Legacy substring matches (back-compat with mickn's prompts and our own) ---
assert_detected "legacy: <hook_prompt" "<hook_prompt name=foo>...</hook_prompt>"
assert_detected "legacy: Stop is blocked" "Stop is blocked until completion is explicitly confirmed."
assert_detected "legacy: Completion check before stopping" "Completion check before stopping."
assert_detected "legacy: TASKMASTER (N) label" "TASKMASTER (5/100): Stop is blocked..."
assert_detected "legacy: TASKMASTER (N) label, no max" "TASKMASTER (5): Stop is blocked..."
assert_detected "legacy: Goal not yet verified complete" "Goal not yet verified complete."
assert_detected "legacy: Recent tool errors were detected" "Recent tool errors were detected."

# --- Negatives ---
assert_not_detected "empty string" ""
assert_not_detected "real user prompt" "fix the failing test in foo_test.go"
assert_not_detected "user mentions taskmaster word" "I want to use taskmaster for this project"
assert_not_detected "tag-like but malformed" "[taskmaster:injected]"
assert_not_detected "tag-like but missing v=" "[taskmaster:injected kind=stop-block]"

# --- generate_taskmaster_injected_tag produces a parseable tag ---
TAG="$(generate_taskmaster_injected_tag stop-block)"
assert_detected "generated tag is detectable" "$TAG"
[[ "$TAG" == "[taskmaster:injected v=1 kind=stop-block]" ]] && {
  printf 'ok  generated tag exact format\n'; PASS_COUNT=$((PASS_COUNT + 1));
} || {
  printf 'FAIL generated tag exact format (got: %s)\n' "$TAG" >&2; FAIL_COUNT=$((FAIL_COUNT + 1));
}

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" == 0 ]]
