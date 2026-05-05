#!/usr/bin/env bash
#
# Detect prompts that Taskmaster itself injected, so they don't get
# treated as fresh user goals by downstream consumers (T2.2 user-prompt
# capture, T3 verifier).
#
# Two-tier detection:
#   1. Forward path: explicit `[taskmaster:injected v=<N> kind=<kind>]` tag
#      on the first non-empty line. Forward-compatible across schema bumps.
#   2. Legacy fallback: substring match against known wording from this
#      project and from mickn/taskmaster's fork.
#

# Idempotent re-source: avoid `readonly` re-declaration error under `set -e`.
[[ -n "${TASKMASTER_PROMPT_DETECT_LOADED:-}" ]] && return 0
readonly TASKMASTER_PROMPT_DETECT_LOADED=1
readonly TASKMASTER_INJECTED_TAG_VERSION=1

# Emit the canonical tag for a given kind. Caller prepends to their prompt.
# Kinds: stop-block, followup, compliance, session-start, verifier-feedback.
generate_taskmaster_injected_tag() {
  local kind="${1:-unknown}"
  printf '[taskmaster:injected v=%d kind=%s]' \
    "$TASKMASTER_INJECTED_TAG_VERSION" "$kind"
}

is_taskmaster_injected_tag_line() {
  local text="$1"
  [[ "$text" =~ ^\[taskmaster:injected[[:space:]]v=[0-9]+[[:space:]]kind=[a-zA-Z0-9_-]+\] ]]
}

is_taskmaster_legacy_injected_prompt() {
  local text="$1"
  case "$text" in
    "<hook_prompt"*) return 0 ;;
    "Stop is blocked until completion is explicitly confirmed."*) return 0 ;;
    "Completion check before stopping."*) return 0 ;;
    "Goal not yet verified complete."*) return 0 ;;
    "Recent tool errors were detected."*) return 0 ;;
    "TASKMASTER ("*) return 0 ;;
  esac
  return 1
}

is_taskmaster_injected_prompt() {
  local text="$1"
  [[ -n "$text" ]] || return 1
  if is_taskmaster_injected_tag_line "$text"; then
    return 0
  fi
  if is_taskmaster_legacy_injected_prompt "$text"; then
    return 0
  fi
  return 1
}
