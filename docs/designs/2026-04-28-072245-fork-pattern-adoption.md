# Design: Fork-Pattern Adoption (T1–T3)

**Date**: 2026-04-28
**Source**: `docs/upstream-reviews/blader-taskmaster-forks.md`
**Status**: Draft for review
**Affected version**: targets v4.3.0 (T1), v4.4.0 (T2 conditional), v4.5.0 (T3 opt-in)

This doc turns the three adoption tiers from the fork review into concrete
designs: file-by-file, env var by env var, with JSON schemas, migration paths,
and tests. Each tier ships independently — T1 has no dependencies, T2 is
conditional on a Codex capability check, T3 layers on top of T1+T2.

---

## Conventions

- **New env vars** all prefixed `TASKMASTER_` to match existing namespace.
- **Boolean env vars** truthy = `1|true|yes|on` (case-insensitive); else falsy.
- **Atomic file writes** = write to `<path>.tmp.<pid>` then `mv` into place.
- **State location** defaults to `${TASKMASTER_STATE_DIR:-${TMPDIR:-/tmp}/taskmaster/state}/`.
- **All new shell scripts** use `set -euo pipefail` and `bash` shebang
  (we already require bash for `[[`, `local`, parameter substitution).
- **Tests** live in `tests/` and follow the existing
  `bats`/`shellspec`-equivalent pattern — for new tests use the simplest
  approach: `bash tests/<feature>.test.sh` returning exit 0 on pass.

---

# Tier 1 — Adopt now (low risk, high value)

## T1.1 — `TASKMASTER_VERIFY_COMMAND` shell-verifier gate

### Goal

Let users gate "stop allowed" behind a repo-local shell command. Use cases:
`cargo test`, `pnpm typecheck`, `make ci`, custom smoke scripts. Pairs with
the existing token-based completion (and later with T3's semantic verifier)
as a hard machine check that complements agent self-report.

### API surface

| Env var | Default | Meaning |
|---|---|---|
| `TASKMASTER_VERIFY_COMMAND` | unset | Shell command to run when token is seen. Empty/unset = skip. |
| `TASKMASTER_VERIFY_TIMEOUT` | `60` | Seconds before SIGTERM, +5s grace before SIGKILL. |
| `TASKMASTER_VERIFY_MAX_OUTPUT` | `4000` | Bytes of combined stdout+stderr echoed back into block reason. |
| `TASKMASTER_VERIFY_CWD` | unset | If set, `cd` here before invoking. Else inherit hook's cwd. |

### Behavior

```
on stop hook:
  ... existing logic up to "HAS_DONE_SIGNAL=true" ...

  if HAS_DONE_SIGNAL == true and TASKMASTER_VERIFY_COMMAND is set:
    run command with timeout
    if exit 0:
      clear counter, allow stop  (existing path)
    else:
      capture last $TASKMASTER_VERIFY_MAX_OUTPUT bytes of output
      block with reason that includes:
        - "Verifier failed (exit=N)"
        - command invoked
        - tail of output
        - reminder that token alone is insufficient when verifier configured
      counter NOT incremented (verifier failure isn't a stop attempt — agent
      gets to fix and retry without burning the budget)

  if HAS_DONE_SIGNAL == false:
    existing block-with-checklist behavior (verifier doesn't fire — token must
    come first to avoid running expensive verifier on every stop attempt)
```

### Why token-then-verify rather than verify-on-every-stop

Two reasons:

1. The agent emitting the token is a cheap signal of "I think I'm done." It
   filters out the dozens of stop attempts per session where the agent is
   mid-work and would just be told to keep going by the verifier. We want the
   verifier to run ~once per "I think I'm done" event, not 30 times.
2. Avoids surprising users whose verifier is `make test` (slow). Without the
   token gate, every stop attempt would block on `make test`.

### Files affected

- **NEW** `taskmaster-verify-command.sh` — small library sourced by both
  `check-completion.sh` and the codex stop path, exposing
  `taskmaster_run_verify_command` returning exit code and capturing bounded
  output via a temp file.
- `check-completion.sh` and `hooks/check-completion.sh` — invoke the verifier
  in the `HAS_DONE_SIGNAL=true` branch.
- `taskmaster-compliance-prompt.sh` — extend `build_taskmaster_compliance_prompt`
  to optionally append a "verifier configured: $cmd" hint when one is set.
- `install.sh` — no changes (env var read at runtime, not install time).
- `docs/SPEC.md` — document new env vars and behavior.

### Reference implementation sketch

```bash
# taskmaster-verify-command.sh
taskmaster_run_verify_command() {
  local cmd="${TASKMASTER_VERIFY_COMMAND:-}"
  local timeout="${TASKMASTER_VERIFY_TIMEOUT:-60}"
  local max_output="${TASKMASTER_VERIFY_MAX_OUTPUT:-4000}"
  local cwd="${TASKMASTER_VERIFY_CWD:-}"
  local out_file
  local exit_code

  [ -z "$cmd" ] && return 0   # not configured = pass

  out_file="$(mktemp "${TMPDIR:-/tmp}/taskmaster-verify.XXXXXX")"
  trap 'rm -f "$out_file"' RETURN

  if [ -n "$cwd" ]; then
    ( cd "$cwd" && timeout --kill-after=5 "$timeout" bash -c "$cmd" ) >"$out_file" 2>&1 &
  else
    timeout --kill-after=5 "$timeout" bash -c "$cmd" >"$out_file" 2>&1 &
  fi
  wait "$!" || exit_code=$?
  exit_code="${exit_code:-0}"

  TASKMASTER_VERIFY_OUTPUT_TAIL="$(tail -c "$max_output" "$out_file")"
  TASKMASTER_VERIFY_EXIT_CODE="$exit_code"
  return "$exit_code"
}
```

### Testing

- `tests/verify-command.test.sh`:
  - `TASKMASTER_VERIFY_COMMAND="true"` → exit 0, allows stop
  - `TASKMASTER_VERIFY_COMMAND="false"` → non-zero, blocks
  - `TASKMASTER_VERIFY_COMMAND="sleep 120" TASKMASTER_VERIFY_TIMEOUT=2` → killed, blocks with timeout marker
  - `TASKMASTER_VERIFY_COMMAND="yes | head -c 50000"` → output truncated to `TASKMASTER_VERIFY_MAX_OUTPUT`
  - `TASKMASTER_VERIFY_COMMAND` unset → no-op, behaves identically to current code

### Migration

Zero impact when unset. Existing users see no change.

### Risks

| Risk | Mitigation |
|---|---|
| User sets long-running verifier, sessions stall | Default 60s timeout |
| Verifier writes huge output, OOMs hook | `tail -c $MAX_OUTPUT` from temp file, never load full output in memory |
| Verifier needs project root, hook runs elsewhere | `TASKMASTER_VERIFY_CWD` env var |
| Verifier depends on PATH that wrapper doesn't inherit | Document; use absolute paths in env var |

---

## T1.2 — JSON state-file layout

### Goal

Replace the bare counter file (`${TMPDIR}/taskmaster/<session_id>` containing
just an integer) with structured JSON state. Unblocks T1.3, T2.2, and T3
without each adding its own ad-hoc file.

### State file location

```
${TASKMASTER_STATE_DIR:-${TMPDIR:-/tmp}/taskmaster/state}/<session_id>.json
```

Note the `state/` subfolder — keeps it distinct from existing counter files so
the legacy migration logic can find both.

### Schema (v1)

```json
{
  "schema_version": 1,
  "session_id": "f1b7d967-3043-4422-9ab3-c35693951c9e",
  "created_at": "2026-04-28T07:22:45Z",
  "updated_at": "2026-04-28T07:24:01Z",
  "stop_count": 3,
  "latest_user_prompt": {
    "captured_at": "2026-04-28T07:23:10Z",
    "turn_id": "abc123",
    "prompt": "fix the failing test in foo_test.go"
  },
  "last_verifier_run": {
    "ran_at": "2026-04-28T07:23:55Z",
    "input_hash": "sha256:...",
    "complete": false,
    "reason": "test still failing on line 42",
    "next_action": "run `go test -run TestFoo -v` and fix"
  },
  "metadata": {}
}
```

`metadata` is an open object for future fields without bumping
`schema_version`.

### Helper API

New file `taskmaster-state.sh` (sourced):

```bash
taskmaster_state_dir            # echo path, mkdir -p
taskmaster_state_path <sid>     # echo full path to <sid>.json
taskmaster_state_init <sid>     # create empty file if missing (idempotent)
taskmaster_state_read <sid>     # cat the JSON (empty {} if missing)
taskmaster_state_jq <sid> <expr>     # run jq on state, echo result
taskmaster_state_set <sid> <jq_path> <json_value>
                                # atomic update: read → jq | "<jq_path> = <value>" → tmp → mv
taskmaster_state_increment_stop_count <sid>
taskmaster_state_capture_prompt <sid> <turn_id> <prompt>
taskmaster_state_record_verifier_run <sid> <input_hash> <complete> <reason> <next_action>
```

All writes use atomic tmp+mv. Concurrent writers (rare in practice — single
agent per session) coordinate via `flock` on `<state_path>.lock`.

### Atomic write pattern

```bash
taskmaster_state_set() {
  local sid="$1" jq_expr="$2" json_value="$3"
  local path tmp lock
  path="$(taskmaster_state_path "$sid")"
  tmp="${path}.tmp.$$"
  lock="${path}.lock"

  mkdir -p "$(dirname "$path")"
  exec 9>"$lock"
  flock 9
  if [ -f "$path" ]; then
    jq --argjson v "$json_value" "$jq_expr = \$v" "$path" >"$tmp"
  else
    jq -n --argjson v "$json_value" \
      --arg sid "$sid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "{schema_version:1, session_id:\$sid, created_at:\$now, updated_at:\$now, stop_count:0} | $jq_expr = \$v" \
      >"$tmp"
  fi
  mv "$tmp" "$path"
  exec 9>&-
}
```

### Legacy migration

On first state read for a session, check for the legacy counter file:

```bash
legacy="${TMPDIR:-/tmp}/taskmaster/${SESSION_ID}"
if [ -f "$legacy" ] && [ ! -f "$(taskmaster_state_path "$SESSION_ID")" ]; then
  count=$(cat "$legacy" 2>/dev/null || echo 0)
  taskmaster_state_init "$SESSION_ID"
  taskmaster_state_set "$SESSION_ID" '.stop_count' "$count"
  rm -f "$legacy"
fi
```

Run this exactly once per session (idempotent because file no longer exists
after migration). Net: existing sessions transparently upgrade.

### Files affected

- **NEW** `taskmaster-state.sh`
- `check-completion.sh`, `hooks/check-completion.sh` — replace counter
  file logic with `taskmaster_state_increment_stop_count` and
  `taskmaster_state_jq <sid> '.stop_count'`
- `hooks/inject-continue-codex.sh` — same migration
- `install.sh` — copy new script to skill dirs and `chmod +x`
- `uninstall.sh` — remove the new script
- `docs/SPEC.md` — document state schema and location

### Testing

- `tests/state.test.sh`:
  - Init creates well-formed JSON with schema_version=1
  - Concurrent writers: 100x parallel `taskmaster_state_increment_stop_count`,
    final value == 100 (flock works)
  - Legacy file detected and migrated, then deleted
  - Atomic write: kill -9 mid-write doesn't corrupt main file (tmp file
    abandoned, real file untouched)
  - jq read of nonexistent path returns empty / null without erroring

### Migration

Backward compatible. Existing counter files auto-migrate. New
`TASKMASTER_STATE_DIR` env var lets users relocate.

### Risks

| Risk | Mitigation |
|---|---|
| jq not installed | We already require jq; install.sh checks at install time |
| Disk full when writing tmp | tmp is on same fs as target; mv fails atomically; existing state preserved |
| Stale state files accumulate | Out of scope for v4.3.0 — track as follow-up beads issue (TTL cleanup, e.g., delete files older than 30 days on hook startup) |

---

## T1.3 — Hook-internal-prompt detection (tagged-injection)

### Goal

Mark every prompt the hook injects so we (and future verifiers) can tell
"this is the user asking" from "this is taskmaster reminding the agent."
mickn's fork relies on substring-match heuristics; that's fragile to wording
changes. We can do better with a single explicit tag.

### Design choice: explicit magic tag

Prefix every injected prompt — block reasons, compliance prompts, queue-emitter
follow-ups — with a stable single-line marker:

```
[taskmaster:injected v=1 kind=<kind>]
<actual content>
```

Where `<kind>` is one of `stop-block | followup | compliance | session-start |
verifier-feedback`.

Detection helper:

```bash
is_taskmaster_injected_prompt() {
  local text="$1"
  case "$text" in
    "[taskmaster:injected v="*) return 0 ;;
    *) return 1 ;;
  esac
}
```

For backward compatibility (and to handle prompts injected before this
change), include a fallback substring matcher with mickn's exact phrases:

```bash
is_taskmaster_injected_prompt_legacy() {
  local text="$1"
  case "$text" in
    "<hook_prompt"*|\
    "Stop is blocked until completion is explicitly confirmed."*|\
    "Completion check before stopping."*|\
    "Goal not yet verified complete."*|\
    "Recent tool errors were detected."*|\
    "TASKMASTER ("*)  # our current label format
      return 0 ;;
    *) return 1 ;;
  esac
}
```

`is_taskmaster_injected_prompt` returns 0 if EITHER matches.

### Why a tag rather than substring matching alone

| Approach | Pros | Cons |
|---|---|---|
| Substring match only | No format change visible to user | Fragile to copy edits, locale, future preamble tweaks |
| Tag only | Bulletproof | Visible to user in transcript |
| **Both** | Forward-correct + backward-compatible | Slightly more code |

The tag is one short line at the top of the prompt — comparable to the
existing `TASKMASTER (N)` label. Net visual cost is small.

### Files affected

- `taskmaster-compliance-prompt.sh` — add `taskmaster_injected_tag <kind>`
  helper; prepend to `build_taskmaster_compliance_prompt` output
- `check-completion.sh`, `hooks/check-completion.sh` — wrap the `REASON`
  string with the tag
- `hooks/inject-continue-codex.sh` — same for queue payloads
- **NEW** `taskmaster-prompt-detect.sh` — exposes
  `is_taskmaster_injected_prompt` for use by hooks and verifier
- `docs/SPEC.md` — document the tag format (so external tooling can detect
  too)

### Schema versioning

The `v=1` field future-proofs the tag. If we ever change semantics (e.g., add
required machine-readable fields), bump to `v=2` and have the detector accept
both.

### Testing

- `tests/prompt-detect.test.sh`:
  - Tagged prompt → detected
  - Legacy mickn substring → detected (back-compat)
  - User text containing the word "taskmaster" but not the tag → NOT detected
  - Empty string → NOT detected
  - Tag with future version `v=99` → still detected (forward-compat: prefix
    match `[taskmaster:injected v=`)

### Migration

User-visible: each block reason gets a tag line at top. Document in
release notes.

### Risks

| Risk | Mitigation |
|---|---|
| Tag confuses users / models | Use plain ASCII, single line; mention in SKILL.md so models know the tag is metadata, not a directive |
| Some prompt path forgets the tag | `is_taskmaster_injected_prompt` falls back to legacy substring matcher |
| Markdown rendering mangles `[...]` | The tag is plain ASCII outside any code block; if a renderer hides it, the legacy substring matcher still works |

---

# Tier 2 — Adopt after upstream-reality check

T2 depends on a verifiable claim: that the OpenAI Codex CLI exposes native
hooks similar to Claude Code's. The fork review left this as an open
question. T2.0 is a discovery step that gates T2.1 and T2.2.

## T2.0 — Codex hook capability detection (precondition)

### Goal

Determine whether the installed `codex` binary supports `SessionStart`,
`UserPromptSubmit`, and `Stop` hooks via `~/.codex/hooks.json`. Without this,
T2.1/T2.2 cannot be implemented natively and the wrapper architecture stays.

### Detection plan

1. `codex --version` → record version
2. `codex --help 2>&1 | grep -i hook` → does help mention hooks?
3. Check `~/.codex/hooks.json` schema in the installed Codex docs (if any)
4. Smoke test: write a minimal `~/.codex/hooks.json` with a `SessionStart`
   hook that writes a sentinel file; launch `codex`; confirm sentinel created
5. Same for `UserPromptSubmit` and `Stop`

Outcome documented in `docs/upstream-reviews/codex-hooks-capability-<version>.md`.

### Decision gates

| Outcome | Action |
|---|---|
| All three hooks supported, `Stop` allows `decision: "block"` | Proceed with T2.1, T2.2 |
| Only some supported | Implement what's supported; keep wrapper for the rest |
| None supported | Park T2 indefinitely; T1+T3 deliver the most value anyway |

## T2.1 — Native Codex hooks (conditional)

### Goal

Add a parallel implementation path that uses Codex's native hook system
instead of the PTY wrapper. Both paths coexist; install.sh picks at install
time based on T2.0 detection. Wrapper stays as the fallback for older Codex
versions.

### New files

- `hooks/codex-session-start.sh` — emits the SKILL.md context contract
  (parallels current `run-taskmaster-codex.sh` startup)
- `hooks/codex-user-prompt-submit.sh` — captures user prompts (T2.2)
- `hooks/codex-stop.sh` — runs the same completion check as
  `check-completion.sh` but adapted to Codex's hook input shape

The Claude side (`hooks/check-completion.sh`) is unchanged.

### install.sh changes

```bash
detect_codex_native_hooks() {
  command -v codex >/dev/null 2>&1 || return 1
  # Capability probe — see T2.0 for actual detection logic
  codex --help 2>&1 | grep -qi 'hooks.json' || return 1
  return 0
}

if [ "$INSTALL_TARGET" = "codex" ] || [ "$INSTALL_TARGET" = "auto" ] || [ "$INSTALL_TARGET" = "both" ]; then
  if detect_codex_native_hooks && [ "${TASKMASTER_CODEX_MODE:-auto}" != "wrapper" ]; then
    install_codex_native     # writes ~/.codex/hooks.json, links new hooks
  else
    install_codex_wrapper    # current behavior
  fi
fi
```

Override env var `TASKMASTER_CODEX_MODE=wrapper|native|auto` lets the user
force either path even when both work.

### Hooks.json layout

```json
{
  "hooks": {
    "SessionStart":     [{"command": "~/.codex/skills/taskmaster/hooks/codex-session-start.sh"}],
    "UserPromptSubmit": [{"command": "~/.codex/skills/taskmaster/hooks/codex-user-prompt-submit.sh"}],
    "Stop":             [{"command": "~/.codex/skills/taskmaster/hooks/codex-stop.sh"}]
  }
}
```

(Exact structure depends on T2.0 findings; mickn's install.sh writes
`~/.codex/hooks.json` and his `install.sh` is the reference implementation
to start from.)

### Coexistence with wrapper

The wrapper writes `inject.*.txt` queue files; the native path writes JSON
state. Both populate `~/.codex/taskmaster/state/<sid>.json` (T1.2). The
codex-stop.sh script reads the same state file, so the verifier (T3) works
identically on both paths.

### Files affected

- **NEW** `hooks/codex-session-start.sh`, `hooks/codex-user-prompt-submit.sh`,
  `hooks/codex-stop.sh`
- `install.sh` — capability detection, branch, write hooks.json (when
  native), preserve wrapper install (when not)
- `uninstall.sh` — remove hooks.json entries cleanly without clobbering
  user-added entries (jq-based merge/unmerge, NOT file replacement)
- `docs/SPEC.md` — document both paths and the chooser logic
- `tests/install.test.sh` — both paths covered
- **NEW** `tests/codex-stop.test.sh`

### Migration

- New installs on capable Codex: native by default
- Existing wrapper installs: re-run `install.sh` to upgrade; or set
  `TASKMASTER_CODEX_MODE=wrapper` to stay on wrapper
- Wrapper code is NOT deleted in this change — strangler-fig pattern, keep
  both, monitor breakage for one full release cycle, only then prune

### Risks

| Risk | Mitigation |
|---|---|
| `~/.codex/hooks.json` already has user entries | Merge with jq; don't overwrite |
| Codex hook contract changes between versions | Pin tested versions in docs; add a `codex --version` check at hook entry that warns on unknown versions |
| Native and wrapper both run accidentally | install.sh sets one OR the other; sanity check at hook entry that we're not double-firing |

## T2.2 — UserPromptSubmit goal capture

### Goal

Persist the user's actual goal for each turn to state, so T3's verifier has
something concrete to verify against (rather than guessing from transcript).

### Hook input

Codex passes JSON on stdin (per mickn's reference; T2.0 must confirm exact
field names):

```json
{
  "session_id": "...",
  "turn_id": "...",
  "prompt": "<the user's text>",
  "cwd": "...",
  "model": "..."
}
```

### Behavior

```bash
# read input
INPUT=$(cat)
SID=$(jq -r .session_id <<<"$INPUT")
TID=$(jq -r .turn_id <<<"$INPUT")
PROMPT=$(jq -r .prompt <<<"$INPUT")

# filter
if is_taskmaster_injected_prompt "$PROMPT"; then exit 0; fi
if is_environment_context_only_prompt "$PROMPT"; then exit 0; fi
if is_agents_md_prelude "$PROMPT"; then exit 0; fi

# capture
taskmaster_state_capture_prompt "$SID" "$TID" "$PROMPT"
```

### Wrapper-side parity

For users on the wrapper path (T2.1 not active), we don't have a
UserPromptSubmit event. Two options:

1. **Skip goal capture** — verifier (T3) has to infer goal from transcript.
   Acceptable but lower-quality verifications.
2. **Parse the Codex session log** — `inject-continue-codex.sh` already
   tails the session log for `task_complete` events; teach it to also handle
   user-prompt events and write to state.

Option 2 is mostly free since we're already tailing the log. Implement it
during T2.2.

### Filters (in priority order)

1. Tagged taskmaster-injected (T1.3) → skip
2. Legacy substring match → skip
3. Pure `<environment_context>...</environment_context>` block → skip
4. `# AGENTS.md instructions for ...` prelude only → skip
5. Else → capture

Filters live in `taskmaster-prompt-detect.sh` (T1.3) — extend that file with
helpers for env-context and agents-md detection.

### Files affected

- `hooks/codex-user-prompt-submit.sh` (new in T2.1, populated here)
- `taskmaster-prompt-detect.sh` (T1.3) — extended with new filters
- `hooks/inject-continue-codex.sh` — extended to also write user prompts to
  state (wrapper-side parity)
- `tests/prompt-detect.test.sh` — extended

### Testing

- All 4 filter classes correctly skipped
- A real user prompt is captured into `latest_user_prompt` and history
- Concurrent prompts in same session don't lose data (per-turn keying via
  `turns[$turn_id]`)
- Prompts > 100KB are stored in full (no truncation at capture time;
  truncation happens at verifier-input time, T3.1)

---

# Tier 3 — Adopt with explicit knobs

## T3.1 — Semantic completion verifier

### Goal

Replace "agent self-reports done" with "second agent verifies done" at
opt-in. When enabled, the stop hook calls an LLM with the captured user goal,
the agent's last message, and a transcript excerpt; the LLM returns
`{complete, reason, next_action}`. This catches cases where the agent
declares victory after partial work.

**Default OFF.** Users opt in explicitly via env var.

### API surface

| Env var | Default | Meaning |
|---|---|---|
| `TASKMASTER_COMPLETION_VERIFY` | `0` | Master switch. Truthy = verifier runs. |
| `TASKMASTER_COMPLETION_PROVIDER` | `auto` | `anthropic\|openai\|command\|auto` |
| `TASKMASTER_COMPLETION_MODEL` | provider-dependent | See below |
| `TASKMASTER_COMPLETION_VERIFIER_COMMAND` | unset | Custom shell verifier; overrides built-in |
| `TASKMASTER_COMPLETION_TIMEOUT` | `30` | Seconds, then fail-open with logged warning |
| `TASKMASTER_COMPLETION_MAX_CONTEXT_CHARS` | `20000` | Total chars sent to LLM (input+goal+last_msg+transcript_tail) |
| `TASKMASTER_COMPLETION_CACHE` | `1` | Cache by input hash; `0` disables |
| `TASKMASTER_COMPLETION_FAIL_OPEN` | `1` | On API/timeout error: `1` allow stop, `0` block stop |

### Provider auto-detection

```
provider == "auto":
  if ANTHROPIC_API_KEY set → "anthropic" with model claude-haiku-4-5
  elif OPENAI_API_KEY set  → "openai"    with model gpt-5.4-mini
  elif TASKMASTER_COMPLETION_VERIFIER_COMMAND set → "command"
  else → log warning, fall back to legacy token detection (don't block)
```

Default Anthropic over OpenAI for two reasons: (1) we ship Claude users
predominantly; (2) Haiku is cheaper than gpt-5.4-mini at comparable quality
for this task. Users on OpenAI infra can set
`TASKMASTER_COMPLETION_PROVIDER=openai` explicitly.

### Verifier I/O contract

Same shape regardless of provider. Custom commands implement this protocol.

**Input (stdin JSON)**:

```json
{
  "schema_version": 1,
  "session_id": "...",
  "user_goal": "<from state.latest_user_prompt.prompt>",
  "last_assistant_message": "<from hook input>",
  "transcript_excerpt": "<tail of transcript, clipped to fit budget>"
}
```

**Output (stdout JSON)**:

```json
{
  "complete": true,
  "reason": "test passes; types check; no TODO comments added",
  "next_action": null,
  "evidence": "ran `pnpm test` mentally based on transcript"
}
```

When `complete=false`, `next_action` MUST be a single concrete next step
(not a list), and it gets injected verbatim into the block reason.

### Built-in verifier prompt structure

The built-in `taskmaster-completion-verifier.py` builds a prompt like:

```
You are a strict completion verifier. Your job is to decide whether the
agent has fully achieved the user's stated goal.

USER GOAL:
{user_goal}

AGENT'S LAST MESSAGE:
{last_assistant_message}

TRANSCRIPT EXCERPT (most recent activity):
{transcript_excerpt}

Respond with JSON only: {"complete": bool, "reason": str, "next_action":
str | null, "evidence": str}.

Strict rules:
- "Made progress" is not complete. Only "goal fully achieved" is complete.
- If verification steps in the goal are unrun, complete = false.
- If the agent says "I cannot" without trying, complete = false.
- If the user explicitly deprioritized something, treat it as resolved.
```

Port mickn's secret-redaction regex set verbatim before the prompt is
constructed.

### Caching

Hash inputs (sha256 of `user_goal + "|" + last_assistant_message + "|" + tail(transcript_excerpt, 4000)`).
Store last hash + result in `state.last_verifier_run` (T1.2 schema).

Cache hit logic:
- If input hash matches last run AND the previous result was `complete=true`,
  reuse → allow stop
- If input hash matches AND previous result was `complete=false`, reuse →
  block with same reason (avoids re-querying when agent retried stop without
  any new work)
- If input hash differs → new query

Net effect: an agent that hammers stop without doing new work pays for one
verifier call, not N.

### Integration with stop hook

```
on stop:
  ...existing logic up to HAS_DONE_SIGNAL detection...

  if TASKMASTER_COMPLETION_VERIFY is truthy:
    if no latest_user_prompt captured (T2.2 inactive or first turn):
      log warning, fall through to token-based detection
    else:
      run verifier (with cache)
      if complete:
        if TASKMASTER_VERIFY_COMMAND set: run that too (T1.1)
          if exit 0: allow stop
          else: block with verifier output
        else: allow stop
      else:
        block with verifier reason + next_action (counter still NOT
        incremented when verifier blocks — same rationale as T1.1)
  else:
    existing token-based logic
```

### Files affected

- **NEW** `taskmaster-completion-verifier.py` (Python, ported from mickn with
  redaction regexes intact, provider auto-detection added, caching added,
  Anthropic-first defaults)
- **NEW** `taskmaster-completion-verifier-anthropic.py` (or single file with
  provider abstraction; single file is simpler)
- `check-completion.sh`, `hooks/check-completion.sh`, `hooks/codex-stop.sh` —
  invoke verifier when configured
- `taskmaster-state.sh` — `taskmaster_state_record_verifier_run` helper
  (introduced in T1.2 schema, used here)
- `install.sh` — copy verifier scripts; `chmod +x`; check Python 3 available
  if `TASKMASTER_COMPLETION_VERIFY=1` at install time (warn, don't block)
- `docs/SPEC.md` — full env-var table
- **NEW** `docs/cost-and-performance.md` — back-of-envelope cost per session
  for each provider/model

### Testing

- `tests/verifier.test.sh`:
  - `TASKMASTER_COMPLETION_VERIFY=0` → verifier never runs (no API calls
    made; pkill any rogue processes)
  - Mock provider via `TASKMASTER_COMPLETION_VERIFIER_COMMAND=tests/mock-verifier.sh`
    that returns scripted JSON
  - Cache hit: same input twice → only first call hits the mock
  - Cache miss: input changes → second call hits mock
  - Timeout: mock that sleeps > timeout → verifier exits with fail-open
  - `TASKMASTER_COMPLETION_FAIL_OPEN=0`: timeout blocks stop instead
  - Provider auto-detection: ANTHROPIC_API_KEY set → anthropic chosen
  - Secret redaction: mock that echoes input verifies `sk-...` was redacted

### Migration

Default OFF means existing users see no change. Adoption is opt-in by
setting `TASKMASTER_COMPLETION_VERIFY=1`.

### Risks

| Risk | Mitigation |
|---|---|
| API outage blocks all stops | `TASKMASTER_COMPLETION_FAIL_OPEN=1` (default); log warning |
| Cost surprise | Default OFF; document per-provider per-session cost in cost-and-performance.md |
| Wrong default model | `TASKMASTER_COMPLETION_MODEL` overrides; document; revisit after first month of usage data |
| Secrets leaked to LLM | Port regex set verbatim; add tests that validate redaction; consider opt-out via `TASKMASTER_COMPLETION_REDACT=0` only for users who explicitly want raw context (don't make this the default) |
| Verifier disagrees with token | Verifier wins. Token alone is insufficient when verifier is on. Document this clearly. |
| Latency added to every stop | Cache cuts repeated queries; default 30s timeout caps worst case |

---

# Open questions for follow-up

These were flagged in the fork review and are restated here as design-time
risks:

1. **Codex native hooks reality** (gates T2). Action: T2.0 capability probe
   ASAP, on the user's installed Codex version. If supported, design proceeds
   as written. If not, T2 is parked and T1+T3 still ship.

2. **Verifier model selection** (impacts T3 cost/quality). Action: after T3
   ships behind the OFF default, pilot with `claude-haiku-4-5` and
   `gpt-5.4-mini` on real sessions, compare false-positive and
   false-negative rates, document findings in
   `docs/cost-and-performance.md`.

3. **Transcript-tail caching invariant** (impacts T3 cost). Action: confirm
   that hashing the last 4000 chars of transcript_excerpt is stable enough
   that "agent retried stop after producing 1KB of new output" reliably
   misses the cache (we want a fresh verifier call), while "agent retried
   stop with no new output" reliably hits.

4. **Hooks.json merge semantics** (impacts T2.1). Action: T2.0 should also
   verify whether multiple `Stop` hooks compose (run all? short-circuit on
   first block? user-defined order?). If only one is allowed, install.sh
   needs a "we'd overwrite your existing Stop hook" warning gate.

# Rollout sequencing

| Phase | Tier(s) | Gating |
|---|---|---|
| 1 | T1.1, T1.2, T1.3 | None — independent of upstream |
| 2 | T2.0 (capability probe) | Phase 1 merged |
| 3 | T2.1, T2.2 | T2.0 outcome positive |
| 4 | T3.1 | T1+T2 merged |

Each phase is its own PR with its own version bump.

# Out of scope (deliberately)

- Stale state-file cleanup / TTL — separate beads issue
- POSIX-portable install.sh (mickn's `46f6a44` pattern) — incompatible with
  our bash-only constructs; skipped per fork review
- Single-fire stop philosophy (`gjlondon`) — incompatible with our
  explicit-token contract; skipped per fork review
- OpenClaw platform port (`levi-openclaw`) — different platform; skipped
- Auto-generated CLAUDE.md (`Semenka`) — generic content, no project value;
  skipped
