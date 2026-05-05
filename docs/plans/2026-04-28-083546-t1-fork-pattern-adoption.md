# Tier 1 Fork-Pattern Adoption — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Ship the three Tier-1 patterns from `docs/designs/2026-04-28-072245-fork-pattern-adoption.md`: a `TASKMASTER_VERIFY_COMMAND` shell-verifier gate (T1.1), tagged hook-internal-prompt detection (T1.3), and a JSON state-file layout with legacy-counter migration (T1.2). Bumps version 4.2.0 → 4.3.0.

**Architecture:** Three independent additions. T1.1 adds a sourced helper (`taskmaster-verify-command.sh`) called from both stop-hook variants when the done token is seen. T1.3 introduces an explicit `[taskmaster:injected v=1 kind=...]` tag that wraps every prompt the hook injects, plus a sourced detector (`taskmaster-prompt-detect.sh`) with a legacy substring-match fallback for back-compat. T1.2 replaces the bare counter file at `${TMPDIR}/taskmaster/<session_id>` with a `flock`-protected JSON file at `${TASKMASTER_STATE_DIR:-${TMPDIR}/taskmaster/state}/<session_id>.json` exposed through a sourced library (`taskmaster-state.sh`); a one-time migration on first read absorbs the legacy counter and deletes the old file.

**Tech Stack:** bash 5+, `jq`, `flock`, `timeout` (GNU coreutils), `mktemp`, plain-bash test scripts.

**Order rationale:** Phase A first (T1.1) — smallest, no migration. Phase B (T1.3) — independent, but touches every prompt-injection site. Phase C (T1.2) — biggest change because counter usage is in three files; doing it last means we don't rewrite already-touched code twice. Phase D — version bump, CHANGELOG, tag.

**Test invocation:** every new test is `bash tests/<name>.test.sh` returning exit 0 on pass, non-zero on fail. Existing tests follow the same convention.

---

## Pre-flight

**Step 1: Confirm clean working tree and current version**

Run: `git status && grep '^version:' SKILL.md`
Expected: `working tree clean` and `version: 4.2.0`. If anything modified, stop and ask the user.

**Step 2: Confirm required tools are installed**

Run: `which jq flock timeout mktemp`
Expected: all four resolve. If `timeout` is missing on macOS, install GNU coreutils (`brew install coreutils`) and use `gtimeout`. The plan assumes `timeout`; on macOS, swap globally before starting Phase A.

---

# Phase A — T1.1: `TASKMASTER_VERIFY_COMMAND`

### Task A1: Write the failing tests for the verify-command helper

**Files:**
- Create: `tests/verify-command.test.sh`

**Step 1: Write the test file**

```bash
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
```

**Step 2: Run test to verify it fails**

Run: `bash tests/verify-command.test.sh`
Expected: FAIL with `taskmaster-verify-command.sh: No such file or directory` (because the lib doesn't exist yet).

**Step 3: Commit the failing test**

```bash
git add tests/verify-command.test.sh
git commit -m "test: add failing tests for taskmaster-verify-command lib (T1.1)"
```

---

### Task A2: Implement `taskmaster-verify-command.sh`

**Files:**
- Create: `taskmaster-verify-command.sh`

**Step 1: Write the helper**

```bash
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

  out_file="$(mktemp "${TMPDIR:-/tmp}/taskmaster-verify.XXXXXX")"

  if [[ -n "$cwd" ]]; then
    set +e
    ( cd "$cwd" && timeout --kill-after=5 "$timeout_sec" bash -c "$cmd" ) \
      >"$out_file" 2>&1
    rc=$?
    set -e
  else
    set +e
    timeout --kill-after=5 "$timeout_sec" bash -c "$cmd" >"$out_file" 2>&1
    rc=$?
    set -e
  fi

  TASKMASTER_VERIFY_OUTPUT_TAIL="$(tail -c "$max_output" "$out_file" 2>/dev/null || true)"
  TASKMASTER_VERIFY_EXIT_CODE="$rc"

  rm -f "$out_file"
  return "$rc"
}
```

**Step 2: Make it executable**

```bash
chmod +x taskmaster-verify-command.sh
```

**Step 3: Run the test to verify it passes**

Run: `bash tests/verify-command.test.sh`
Expected: `8 passed, 0 failed`. If any test fails, fix the implementation — do NOT change the test.

**Step 4: Commit the implementation**

```bash
git add taskmaster-verify-command.sh
git commit -m "feat: add taskmaster-verify-command lib for shell-verifier gate (T1.1)"
```

---

### Task A3: Wire the verifier into `check-completion.sh`

**Files:**
- Modify: `check-completion.sh`

**Step 1: Source the helper near the top (after the compliance-prompt source)**

Find the line that sources `taskmaster-compliance-prompt.sh` (around line 20). Immediately after it, add:

```bash
# shellcheck disable=SC1091
source "$SCRIPT_DIR/taskmaster-verify-command.sh"
```

**Step 2: Insert the verifier call inside the `HAS_DONE_SIGNAL=true` branch**

Find the block (around line 92):

```bash
if [ "$HAS_DONE_SIGNAL" = true ]; then
  rm -f "$COUNTER_FILE"
  exit 0
fi
```

Replace with:

```bash
if [ "$HAS_DONE_SIGNAL" = true ]; then
  if [ -n "${TASKMASTER_VERIFY_COMMAND:-}" ]; then
    if taskmaster_run_verify_command; then
      rm -f "$COUNTER_FILE"
      exit 0
    else
      VERIFY_REASON="TASKMASTER: verifier failed (exit=${TASKMASTER_VERIFY_EXIT_CODE}). Command: ${TASKMASTER_VERIFY_COMMAND}

Output (last ${TASKMASTER_VERIFY_MAX_OUTPUT:-4000} bytes):
${TASKMASTER_VERIFY_OUTPUT_TAIL}

Token alone is insufficient when a verifier is configured. Fix the failures and try again."
      jq -n --arg reason "$VERIFY_REASON" '{ decision: "block", reason: $reason }'
      exit 0
    fi
  fi
  rm -f "$COUNTER_FILE"
  exit 0
fi
```

**Step 3: Sanity-check the script**

Run: `bash -n check-completion.sh`
Expected: no output (parses cleanly).

**Step 4: Smoke test the integration manually**

Run:
```bash
TASKMASTER_VERIFY_COMMAND="false" \
  echo '{"session_id":"smoke-A3","transcript_path":"/dev/null","last_assistant_message":"TASKMASTER_DONE::smoke-A3"}' \
  | bash check-completion.sh
```
Expected: a JSON object with `"decision":"block"` and a `"reason"` field that contains `verifier failed (exit=1)`.

Run again with `TASKMASTER_VERIFY_COMMAND="true"`. Expected: empty output, exit 0.

---

### Task A4: Wire the verifier into `hooks/check-completion.sh`

**Files:**
- Modify: `hooks/check-completion.sh`

Apply the **same** two edits as A3, but the source path is `$SCRIPT_DIR/../taskmaster-verify-command.sh` (one directory up).

**Step 1: Source the helper**

After the existing `source "$SCRIPT_DIR/../taskmaster-compliance-prompt.sh"` line, add:

```bash
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../taskmaster-verify-command.sh"
```

**Step 2: Insert the verifier call** in the same `HAS_DONE_SIGNAL=true` branch (same code as A3).

**Step 3: Sanity-check**

Run: `bash -n hooks/check-completion.sh`
Expected: no output.

---

### Task A5: Update `install.sh` to copy and chmod the new file

**Files:**
- Modify: `install.sh`

**Step 1: Find the `copy_skill_files` function (around line 49) and add a `safe_copy` line for the new file**

Locate this block:
```bash
safe_copy "$SCRIPT_DIR/taskmaster-compliance-prompt.sh" "$skill_dir/taskmaster-compliance-prompt.sh"
```

Add immediately below it:
```bash
safe_copy "$SCRIPT_DIR/taskmaster-verify-command.sh" "$skill_dir/taskmaster-verify-command.sh"
```

**Step 2: Add a `chmod +x` line**

Locate the `chmod +x "$skill_dir/taskmaster-compliance-prompt.sh"` line. Add immediately below:
```bash
chmod +x "$skill_dir/taskmaster-verify-command.sh"
```

**Step 3: Sanity-check**

Run: `bash -n install.sh`
Expected: no output.

---

### Task A6: Update `uninstall.sh` to remove the new file

**Files:**
- Modify: `uninstall.sh`

**Step 1: Find where compliance-prompt.sh is removed and add a parallel rm for verify-command.sh.**

Locate `rm -f "$skill_dir/taskmaster-compliance-prompt.sh"` (or grep for `taskmaster-compliance-prompt.sh` in `uninstall.sh`). Add immediately below:

```bash
rm -f "$skill_dir/taskmaster-verify-command.sh"
```

**Step 2: Sanity-check**

Run: `bash -n uninstall.sh`

---

### Task A7: Document the new env vars in `docs/SPEC.md`

**Files:**
- Modify: `docs/SPEC.md`

**Step 1: Find the "Configuration" section (section 5) and add a subsection for verify-command env vars.**

Add at the end of the configuration section:

```markdown
### 5.x Optional verifier command

| Env var | Default | Meaning |
|---|---|---|
| `TASKMASTER_VERIFY_COMMAND` | unset | Shell command run when the done token is seen. Empty/unset = skip. |
| `TASKMASTER_VERIFY_TIMEOUT` | `60` | Seconds before SIGTERM, +5s grace before SIGKILL. |
| `TASKMASTER_VERIFY_MAX_OUTPUT` | `4000` | Bytes of combined stdout+stderr echoed back into the block reason. |
| `TASKMASTER_VERIFY_CWD` | unset | If set, `cd` here before invoking. Else inherit hook's cwd. |

When `TASKMASTER_VERIFY_COMMAND` is set, stop is allowed only when (a) the
done token is present **and** (b) the command exits 0. A failing verifier
overrides token-based completion and blocks with the command's exit code and
truncated output.

The verifier runs **only** when the done token is present, not on every stop
attempt — this keeps slow verifiers (test suites, builds) from gating
mid-work stop attempts.
```

(Replace `5.x` with the next available subsection number when adding.)

---

### Task A8: Phase A end-to-end run + commit

**Step 1: Run all tests**

Run: `bash tests/verify-command.test.sh`
Expected: `8 passed, 0 failed`.

**Step 2: Confirm syntax across all touched scripts**

Run: `bash -n check-completion.sh hooks/check-completion.sh install.sh uninstall.sh taskmaster-verify-command.sh`
Expected: no output.

**Step 3: Commit Phase A integration**

```bash
git add check-completion.sh hooks/check-completion.sh install.sh uninstall.sh docs/SPEC.md
git commit -m "feat: gate stop on TASKMASTER_VERIFY_COMMAND when token present (T1.1)

When TASKMASTER_VERIFY_COMMAND is set, the stop hook runs the command
after the done token is detected. Exit 0 allows stop; non-zero blocks
with a truncated output dump. Verifier only fires when the token is
present, so mid-work stop attempts don't pay the cost of a slow verifier."
```

---

# Phase B — T1.3: Tagged hook-internal-prompt detection

### Task B1: Write the failing tests for the prompt-detect helper

**Files:**
- Create: `tests/prompt-detect.test.sh`

**Step 1: Write the test file**

```bash
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
```

**Step 2: Run to verify it fails**

Run: `bash tests/prompt-detect.test.sh`
Expected: FAIL with `taskmaster-prompt-detect.sh: No such file or directory`.

**Step 3: Commit failing tests**

```bash
git add tests/prompt-detect.test.sh
git commit -m "test: add failing tests for taskmaster-prompt-detect lib (T1.3)"
```

---

### Task B2: Implement `taskmaster-prompt-detect.sh`

**Files:**
- Create: `taskmaster-prompt-detect.sh`

**Step 1: Write the lib**

```bash
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
  # Match `[taskmaster:injected v=<digits> kind=<word>]` at start of text.
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
```

**Step 2: Make executable**

```bash
chmod +x taskmaster-prompt-detect.sh
```

**Step 3: Run tests**

Run: `bash tests/prompt-detect.test.sh`
Expected: all assertions pass. If any fail, fix the implementation.

**Step 4: Commit**

```bash
git add taskmaster-prompt-detect.sh
git commit -m "feat: add taskmaster-prompt-detect lib with tag + legacy detection (T1.3)"
```

---

### Task B3: Tag the prompts emitted by `check-completion.sh`

**Files:**
- Modify: `check-completion.sh`

**Step 1: Source the new lib near the top**

After the existing `source` lines, add:

```bash
# shellcheck disable=SC1091
source "$SCRIPT_DIR/taskmaster-prompt-detect.sh"
```

**Step 2: Wrap the `REASON` construction with the tag**

Locate the `REASON=` block (around line 115):

```bash
SHARED_PROMPT="$(build_taskmaster_compliance_prompt "$DONE_SIGNAL")"
REASON="${LABEL}: ${PREAMBLE}

${SHARED_PROMPT}"
```

Replace with:

```bash
SHARED_PROMPT="$(build_taskmaster_compliance_prompt "$DONE_SIGNAL")"
INJECTED_TAG="$(generate_taskmaster_injected_tag stop-block)"
REASON="${INJECTED_TAG}
${LABEL}: ${PREAMBLE}

${SHARED_PROMPT}"
```

**Step 3: Sanity-check**

Run: `bash -n check-completion.sh`
Expected: no output.

**Step 4: Smoke test**

Run:
```bash
echo '{"session_id":"smoke-B3","transcript_path":"/dev/null","last_assistant_message":""}' \
  | bash check-completion.sh \
  | jq -r .reason \
  | head -1
```
Expected: `[taskmaster:injected v=1 kind=stop-block]`

---

### Task B4: Tag the prompts emitted by `hooks/check-completion.sh`

**Files:**
- Modify: `hooks/check-completion.sh`

Same pattern as B3 with `$SCRIPT_DIR/../` prefix.

**Step 1: Source the lib**

After existing sources, add:
```bash
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../taskmaster-prompt-detect.sh"
```

**Step 2: Wrap the `REASON`** with the same `generate_taskmaster_injected_tag stop-block` prefix as B3.

**Step 3: Sanity-check + smoke test** (same JSON probe).

---

### Task B5: Tag the prompts emitted by `hooks/inject-continue-codex.sh`

**Files:**
- Modify: `hooks/inject-continue-codex.sh`

**Step 1: Source the lib**

The injector already sources `taskmaster-compliance-prompt.sh`. Find that source line and add:

```bash
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../taskmaster-prompt-detect.sh"
```

**Step 2: Wrap the heredoc in `build_reprompt`**

Locate the `cat <<RE-PROMPT` block (around line 176):

```bash
  cat <<RE-PROMPT
TASKMASTER: Stop is blocked until completion is explicitly confirmed.

${shared_prompt}
RE-PROMPT
```

Replace with:

```bash
  local injected_tag
  injected_tag="$(generate_taskmaster_injected_tag followup)"
  cat <<RE-PROMPT
${injected_tag}
TASKMASTER: Stop is blocked until completion is explicitly confirmed.

${shared_prompt}
RE-PROMPT
```

**Step 3: Sanity-check**

Run: `bash -n hooks/inject-continue-codex.sh`
Expected: no output.

---

### Task B6: Document the tag in `docs/SPEC.md` and `SKILL.md`

**Files:**
- Modify: `docs/SPEC.md`
- Modify: `SKILL.md`

**Step 1: Add a "Hook-injected prompt tag" subsection to `docs/SPEC.md`**

In the Architecture section (3), add:

```markdown
### 3.x Hook-injected prompt tag

Every prompt the hook injects starts with a single-line tag:

```
[taskmaster:injected v=1 kind=<kind>]
<actual content...>
```

`<kind>` ∈ `stop-block | followup | compliance | session-start | verifier-feedback`.

Downstream consumers (UserPromptSubmit hook, completion verifier, external
tooling) detect injected prompts via `is_taskmaster_injected_prompt` from
`taskmaster-prompt-detect.sh`. Legacy substring detection is preserved for
prompts emitted before this version.
```

**Step 2: Add a brief mention in `SKILL.md`**

In the SKILL.md system context, after the "How It Works" section, add a short paragraph (helps the model treat the tag as metadata, not directive):

```markdown
## A note on the injected-prompt tag

If you see a line starting with `[taskmaster:injected v=…]` at the top of a
message, that's metadata the hook adds to its own prompts. Treat it as a
marker, not as content you need to act on.
```

---

### Task B7: Update `install.sh` and `uninstall.sh` for the new file

**Files:**
- Modify: `install.sh`
- Modify: `uninstall.sh`

**Step 1: install.sh** — add `safe_copy` and `chmod +x` for `taskmaster-prompt-detect.sh` parallel to the changes in A5.

**Step 2: uninstall.sh** — add `rm -f` parallel to A6.

**Step 3: Sanity-check**

Run: `bash -n install.sh uninstall.sh`

---

### Task B8: Phase B end-to-end + commit

**Step 1: Run all tests**

Run: `bash tests/prompt-detect.test.sh && bash tests/verify-command.test.sh`
Expected: both pass.

**Step 2: Smoke test the tag is present in real hook output**

Run:
```bash
echo '{"session_id":"smoke-B8","transcript_path":"/dev/null","last_assistant_message":""}' \
  | bash check-completion.sh \
  | jq -r .reason \
  | head -3
```
Expected: first line is `[taskmaster:injected v=1 kind=stop-block]`.

**Step 3: Commit Phase B**

```bash
git add check-completion.sh hooks/check-completion.sh hooks/inject-continue-codex.sh \
        install.sh uninstall.sh docs/SPEC.md SKILL.md
git commit -m "feat: tag every hook-injected prompt with [taskmaster:injected v=1 kind=...] (T1.3)

Adds an explicit single-line marker to the top of every prompt the hook
injects. Downstream consumers detect injected prompts via the new
taskmaster-prompt-detect lib (forward path: tag match; back-compat:
legacy substring match against current and mickn/taskmaster wording)."
```

---

# Phase C — T1.2: JSON state-file layout

### Task C1: Write the failing tests for the state lib

**Files:**
- Create: `tests/state.test.sh`

**Step 1: Write the test file**

```bash
#!/usr/bin/env bash
#
# Tests for taskmaster-state.sh.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/taskmaster-state.sh"

# Isolate state under a temp dir
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/taskmaster-state-test.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT
export TASKMASTER_STATE_DIR="$TEST_HOME/state"

# shellcheck disable=SC1090
source "$LIB"

PASS=0; FAIL=0
ok() { printf 'ok  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL+1)); }

# --- init creates well-formed JSON with schema_version=1 ---
SID="sess-$$"
taskmaster_state_init "$SID"
PATH_OUT="$(taskmaster_state_path "$SID")"
[[ -f "$PATH_OUT" ]] && ok "init creates file" || fail "init creates file"
SV="$(jq -r .schema_version <"$PATH_OUT")"
[[ "$SV" == "1" ]] && ok "schema_version is 1" || fail "schema_version is 1 (got $SV)"
SI="$(jq -r .session_id <"$PATH_OUT")"
[[ "$SI" == "$SID" ]] && ok "session_id stamped" || fail "session_id stamped"
SC="$(jq -r .stop_count <"$PATH_OUT")"
[[ "$SC" == "0" ]] && ok "stop_count starts at 0" || fail "stop_count starts at 0 (got $SC)"

# --- increment ---
taskmaster_state_increment_stop_count "$SID"
SC="$(jq -r .stop_count <"$PATH_OUT")"
[[ "$SC" == "1" ]] && ok "stop_count after one increment is 1" || fail "increment 1 (got $SC)"

taskmaster_state_increment_stop_count "$SID"
taskmaster_state_increment_stop_count "$SID"
SC="$(jq -r .stop_count <"$PATH_OUT")"
[[ "$SC" == "3" ]] && ok "stop_count after three increments is 3" || fail "increment 3 (got $SC)"

# --- concurrent increments ---
SID2="sess-conc-$$"
taskmaster_state_init "$SID2"
PATH_C="$(taskmaster_state_path "$SID2")"
N=50
for i in $(seq 1 "$N"); do
  ( taskmaster_state_increment_stop_count "$SID2" ) &
done
wait
SC="$(jq -r .stop_count <"$PATH_C")"
[[ "$SC" == "$N" ]] && ok "concurrent $N increments reach $N" \
  || fail "concurrent increments lost some (got $SC, expected $N)"

# --- legacy migration ---
LEGACY_DIR="${TMPDIR:-/tmp}/taskmaster"
mkdir -p "$LEGACY_DIR"
SID3="sess-legacy-$$"
LEGACY_FILE="$LEGACY_DIR/$SID3"
echo "7" > "$LEGACY_FILE"

# State doesn't exist yet; migration should pull the 7
taskmaster_state_migrate_legacy_counter "$SID3"
[[ -f "$(taskmaster_state_path "$SID3")" ]] && ok "legacy migration creates state file" \
  || fail "legacy migration creates state file"
SC="$(jq -r .stop_count <"$(taskmaster_state_path "$SID3")")"
[[ "$SC" == "7" ]] && ok "legacy counter value migrated" \
  || fail "legacy counter value migrated (got $SC, expected 7)"
[[ ! -f "$LEGACY_FILE" ]] && ok "legacy file deleted after migration" \
  || fail "legacy file deleted after migration"

# --- migration is idempotent (rerun without legacy file is a no-op) ---
taskmaster_state_migrate_legacy_counter "$SID3"
SC="$(jq -r .stop_count <"$(taskmaster_state_path "$SID3")")"
[[ "$SC" == "7" ]] && ok "second migration call is a no-op" \
  || fail "second migration mutated state (got $SC)"

# --- jq read of nonexistent path returns null ---
SID4="sess-empty-$$"
VAL="$(taskmaster_state_jq "$SID4" '.latest_user_prompt.prompt' 2>/dev/null || echo "MISSING")"
[[ "$VAL" == "null" || -z "$VAL" || "$VAL" == "MISSING" ]] && ok "nonexistent path read is safe" \
  || fail "nonexistent path read is safe (got $VAL)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
```

**Step 2: Run to verify failure**

Run: `bash tests/state.test.sh`
Expected: FAIL with `taskmaster-state.sh: No such file or directory`.

**Step 3: Commit failing tests**

```bash
git add tests/state.test.sh
git commit -m "test: add failing tests for taskmaster-state lib (T1.2)"
```

---

### Task C2: Implement `taskmaster-state.sh`

**Files:**
- Create: `taskmaster-state.sh`

**Step 1: Write the lib**

```bash
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
    jq -n \
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
      }' >"$tmp"
    mv "$tmp" "$path"
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
  jq --arg now "$now" "$expr | .updated_at = \$now" "$path" >"$tmp"
  mv "$tmp" "$path"
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
  jq \
    --arg now "$now" \
    --arg turn "$turn_id" \
    --arg prompt "$prompt" \
    '.latest_user_prompt = {captured_at: $now, turn_id: $turn, prompt: $prompt}
     | .updated_at = $now' \
    "$path" >"$tmp"
  mv "$tmp" "$path"
  exec 9>&-
}

taskmaster_state_record_verifier_run() {
  local sid="$1" input_hash="$2" complete="$3" reason="$4" next_action="$5"
  local path tmp lock now
  path="$(taskmaster_state_path "$sid")"
  taskmaster_state_init "$sid"

  lock="${path}.lock"
  tmp="${path}.tmp.$$"
  now="$(taskmaster_state_now)"

  exec 9>"$lock"
  flock 9
  jq \
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
    "$path" >"$tmp"
  mv "$tmp" "$path"
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

  taskmaster_state_init "$sid"
  taskmaster_state_update "$sid" ".stop_count = $count"
  rm -f "$legacy"
}
```

**Step 2: Make executable**

```bash
chmod +x taskmaster-state.sh
```

**Step 3: Run tests**

Run: `bash tests/state.test.sh`
Expected: all pass. Common failure modes:
- macOS `flock` not in PATH — install `flock` from coreutils, or skip the concurrent test on systems without it.
- `mkdir -p` race — already handled by `taskmaster_state_init`.

**Step 4: Commit**

```bash
git add taskmaster-state.sh
git commit -m "feat: add taskmaster-state JSON state lib with flock + atomic writes (T1.2)"
```

---

### Task C3: Refactor `check-completion.sh` to use the state lib

**Files:**
- Modify: `check-completion.sh`

**Step 1: Source the lib**

After existing `source` calls, add:

```bash
# shellcheck disable=SC1091
source "$SCRIPT_DIR/taskmaster-state.sh"
```

**Step 2: Replace the counter logic**

Locate the existing block:

```bash
# --- counter ---
COUNTER_DIR="${TMPDIR:-/tmp}/taskmaster"
mkdir -p "$COUNTER_DIR"
COUNTER_FILE="${COUNTER_DIR}/${SESSION_ID}"
MAX=${TASKMASTER_MAX:-100}

COUNT=0
if [ -f "$COUNTER_FILE" ]; then
  COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
fi
```

Replace with:

```bash
# --- counter (state-file backed) ---
taskmaster_state_migrate_legacy_counter "$SESSION_ID"
taskmaster_state_init "$SESSION_ID"

MAX=${TASKMASTER_MAX:-100}
COUNT="$(taskmaster_state_jq "$SESSION_ID" '.stop_count')"
[[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
```

**Step 3: Replace `rm -f "$COUNTER_FILE"` (allow-stop paths) with state reset**

Find every occurrence of `rm -f "$COUNTER_FILE"` (there are two: HAS_DONE_SIGNAL=true branch, and MAX-reached branch). Replace each with:

```bash
taskmaster_state_update "$SESSION_ID" '.stop_count = 0'
```

**Step 4: Replace `echo "$NEXT" > "$COUNTER_FILE"` with state increment**

Find:

```bash
NEXT=$((COUNT + 1))
echo "$NEXT" > "$COUNTER_FILE"
```

Replace with:

```bash
taskmaster_state_increment_stop_count "$SESSION_ID"
NEXT=$((COUNT + 1))
```

(`NEXT` is still computed locally for the LABEL string; the source of truth is the state file.)

**Step 5: Sanity-check**

Run: `bash -n check-completion.sh`
Expected: no output.

**Step 6: Smoke test**

Run:
```bash
TASKMASTER_STATE_DIR="$(mktemp -d)/state" \
  echo '{"session_id":"smoke-C3","transcript_path":"/dev/null","last_assistant_message":""}' \
  | bash check-completion.sh \
  | jq -r .reason | head -2
echo "---"
ls "$TASKMASTER_STATE_DIR"
cat "$TASKMASTER_STATE_DIR"/smoke-C3.json | jq .
```
Expected: tag line + `TASKMASTER (1/100): ...`; state file shows `stop_count: 1`.

---

### Task C4: Refactor `hooks/check-completion.sh` similarly

**Files:**
- Modify: `hooks/check-completion.sh`

Apply the **same** four edits as C3. Source path is `$SCRIPT_DIR/../taskmaster-state.sh`.

**Step 1: Source the lib** (with `..` prefix).

**Step 2–4: Same replacements as C3.**

**Step 5: Sanity-check + smoke test** (same probe).

---

### Task C5: Refactor `hooks/inject-continue-codex.sh` to use state lib

**Files:**
- Modify: `hooks/inject-continue-codex.sh`

The injector tracks injection counts in a runtime file already; this task is **purely additive** — also write to the JSON state when we have a session id, so that future tooling can read both. Do not break the existing injector state file.

**Step 1: Source the lib**

After existing sources, add:

```bash
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../taskmaster-state.sh"
```

**Step 2: In `inject_prompt`, also bump the JSON state's stop_count when SESSION_ID is known**

Find the existing increment line:

```bash
INJECTION_COUNT=$((INJECTION_COUNT + 1))
```

Add immediately after:

```bash
if [[ -n "${SESSION_ID:-}" ]]; then
  taskmaster_state_increment_stop_count "$SESSION_ID" 2>/dev/null || true
fi
```

(`|| true` because the injector's startup ordering can call `inject_prompt` very early; we don't want a state-file write failure to crash the injector.)

**Step 3: Sanity-check**

Run: `bash -n hooks/inject-continue-codex.sh`
Expected: no output.

---

### Task C6: Update `install.sh` and `uninstall.sh` for the state lib

**Files:**
- Modify: `install.sh`
- Modify: `uninstall.sh`

**Step 1: install.sh** — `safe_copy` and `chmod +x` for `taskmaster-state.sh` parallel to A5/B7.

**Step 2: uninstall.sh** — `rm -f` parallel to A6/B7.

**Step 3: Sanity-check**

Run: `bash -n install.sh uninstall.sh`

---

### Task C7: Document the state file in `docs/SPEC.md`

**Files:**
- Modify: `docs/SPEC.md`

**Step 1: Add a "Session state" subsection to the Architecture section.**

```markdown
### 3.x Session state file

Path: `${TASKMASTER_STATE_DIR:-${TMPDIR:-/tmp}/taskmaster/state}/<session_id>.json`

Schema (v1):

```json
{
  "schema_version": 1,
  "session_id": "<sid>",
  "created_at": "<iso8601>",
  "updated_at": "<iso8601>",
  "stop_count": 0,
  "latest_user_prompt": null,
  "last_verifier_run": null,
  "metadata": {}
}
```

All writes go through `flock` on `<path>.lock` and atomic tmp+mv.

**Legacy migration:** on first read per session, the hook absorbs any
existing counter file at `${TMPDIR}/taskmaster/<session_id>` into
`stop_count` and deletes the legacy file. Idempotent.
```

---

### Task C8: Phase C end-to-end + commit

**Step 1: Run all three test suites**

Run: `bash tests/state.test.sh && bash tests/prompt-detect.test.sh && bash tests/verify-command.test.sh`
Expected: all pass.

**Step 2: Verify legacy migration works against a real legacy file**

Run:
```bash
LEGACY_DIR="${TMPDIR:-/tmp}/taskmaster"
mkdir -p "$LEGACY_DIR"
echo "5" > "$LEGACY_DIR/migrate-c8"
TASKMASTER_STATE_DIR="$(mktemp -d)/state" \
  echo '{"session_id":"migrate-c8","transcript_path":"/dev/null","last_assistant_message":""}' \
  | bash check-completion.sh >/dev/null
# After hook fires: legacy file should be gone, state file should have stop_count = 6 (5 migrated + 1 increment)
ls "$LEGACY_DIR/migrate-c8" 2>&1 | grep -q "No such file" && echo "ok: legacy file removed"
jq -r '.stop_count' "$TASKMASTER_STATE_DIR/migrate-c8.json"
```
Expected: `ok: legacy file removed` and `stop_count: 6`.

**Step 3: Sanity-check all touched scripts**

Run: `bash -n check-completion.sh hooks/check-completion.sh hooks/inject-continue-codex.sh install.sh uninstall.sh taskmaster-state.sh`
Expected: no output.

**Step 4: Commit Phase C**

```bash
git add check-completion.sh hooks/check-completion.sh hooks/inject-continue-codex.sh \
        install.sh uninstall.sh docs/SPEC.md
git commit -m "feat: replace counter file with JSON state file + flock + migration (T1.2)

stop_count now lives in a flock-protected JSON file at
\$TASKMASTER_STATE_DIR/<session_id>.json (default: \$TMPDIR/taskmaster/state).
Legacy counter files are absorbed on first read and deleted. Schema is
versioned for forward compatibility with T2/T3 fields (latest_user_prompt,
last_verifier_run)."
```

---

# Phase D — Release plumbing

### Task D1: Bump version to 4.3.0

**Files:**
- Modify: `SKILL.md`

**Step 1: Bump the `version:` line in the YAML frontmatter from `4.2.0` to `4.3.0`.**

Run: `sed -i 's/^version: 4\.2\.0$/version: 4.3.0/' SKILL.md && grep '^version:' SKILL.md`
Expected: `version: 4.3.0`.

---

### Task D2: Bump version in `docs/SPEC.md`

**Files:**
- Modify: `docs/SPEC.md`

**Step 1: Update the `**Version**:` line at the top of SPEC.md from `4.2.0` to `4.3.0`.**

Use `Edit` tool — match exactly to avoid clobbering similar lines.

---

### Task D3: Add a CHANGELOG.md entry for 4.3.0

**Files:**
- Modify: `CHANGELOG.md` (created during the rebase from upstream)

**Step 1: Insert a new section at the top of the file (above the existing `## v2.3.0` entry):**

```markdown
## v4.3.0 — 2026-04-28

### Added
- `TASKMASTER_VERIFY_COMMAND` env var: opt-in shell verifier that gates
  stop after the done token is seen. Pairs with test suites, type-checkers,
  or any repo-local check. Companion knobs: `TASKMASTER_VERIFY_TIMEOUT`
  (default 60s), `TASKMASTER_VERIFY_MAX_OUTPUT` (default 4000 bytes),
  `TASKMASTER_VERIFY_CWD`. (T1.1)
- Tagged hook-injected prompts: every prompt the hook injects starts
  with `[taskmaster:injected v=1 kind=<kind>]`. New
  `taskmaster-prompt-detect.sh` lib lets downstream consumers
  distinguish injected reprompts from real user goals. Legacy substring
  detection preserved for back-compat. (T1.3)
- JSON session state file at
  `${TASKMASTER_STATE_DIR:-${TMPDIR}/taskmaster/state}/<session_id>.json`,
  flock-protected, atomic writes. Schema v1 with `stop_count`,
  `latest_user_prompt`, `last_verifier_run`, `metadata` fields ready for
  T2/T3. (T1.2)

### Changed
- Stop-count tracking moved from the bare counter file at
  `${TMPDIR}/taskmaster/<session_id>` to the new JSON state file.
  Legacy counter files are absorbed on first read and deleted —
  no user action required.

### References
- Design: `docs/designs/2026-04-28-072245-fork-pattern-adoption.md`
- Plan: `docs/plans/2026-04-28-083546-t1-fork-pattern-adoption.md`
- Source review: `docs/upstream-reviews/blader-taskmaster-forks.md`
```

---

### Task D4: Final test run

**Step 1: Run every test in `tests/`**

Run: `for t in tests/*.test.sh; do echo "=== $t ==="; bash "$t" || exit 1; done && echo "ALL TESTS PASS"`
Expected: `ALL TESTS PASS`.

**Step 2: Smoke test the full hook with all three features active**

Run:
```bash
TM_STATE="$(mktemp -d)/state"
TASKMASTER_STATE_DIR="$TM_STATE" \
TASKMASTER_VERIFY_COMMAND="true" \
  echo '{"session_id":"final-smoke","transcript_path":"/dev/null","last_assistant_message":"TASKMASTER_DONE::final-smoke"}' \
  | bash check-completion.sh
echo "exit=$?"
ls "$TM_STATE"
jq . "$TM_STATE/final-smoke.json"
```
Expected: empty output (allow stop), `exit=0`, state file shows the session was tracked. (`stop_count` should be 0 because the done token short-circuited before the increment, then was reset.)

Repeat with `TASKMASTER_VERIFY_COMMAND="false"`. Expected: blocking JSON output with `verifier failed (exit=1)` in the reason.

---

### Task D5: Commit version bump and CHANGELOG

**Step 1: Stage and commit**

```bash
git add SKILL.md docs/SPEC.md CHANGELOG.md
git commit -m "release v4.3.0: T1 fork-pattern adoption (verify-command, tag, state-file)

See CHANGELOG.md for the full entry. Three independent additions
ported from the fork-network review (mickn/taskmaster), each
opt-in or backward-compatible."
```

**Step 2: Tag the release**

```bash
git tag -a v4.3.0 -m "v4.3.0: T1 fork-pattern adoption (T1.1 verify-command, T1.2 state-file, T1.3 prompt tag)"
git tag -n v4.3.0
```

**Step 3: Confirm clean state**

Run: `git status && git log --oneline -10`
Expected: `working tree clean`; the last seven commits trace the plan (test, impl, test, impl, test, impl, release).

---

# Out of scope for this plan

The design doc lists items deliberately deferred:

- Stale state-file cleanup / TTL — separate beads issue.
- Native Codex hooks (T2) — gated on capability probe.
- Semantic completion verifier (T3) — opt-in, ships after T2.

# Risks watched during execution

- **macOS `flock` / `timeout` availability**: if the executing engineer is on macOS without GNU coreutils, install before starting (`brew install coreutils flock`) or stop and ask the user.
- **State-dir collision with parallel sessions**: the `flock` per file makes this safe, but if `$TASKMASTER_STATE_DIR` lives on a network filesystem with broken locking, concurrency tests will flake. Document this as a known caveat in SPEC if encountered.
- **Smoke tests that depend on `last_assistant_message` shape**: the field is what Claude Code passes; if the engineer is testing with a different runtime that uses a different field, override the test JSON shape accordingly.
