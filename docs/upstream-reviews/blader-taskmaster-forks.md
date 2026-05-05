# Fork Network Review: blader/taskmaster

**Date**: 2026-04-28
**Upstream baseline**: `blader/taskmaster@a1f3feb` ("chore: sync local skill updates", 2026-03-11)
**Our fork**: `micahstubbs/taskmaster` at v4.2.0 (codex wrapper + expect PTY bridge architecture)
**Scope**: All 32 forks of `blader/taskmaster`, default and feature branches.

## Methodology

For every fork in the network, compared default branch to upstream `main` via
`gh api repos/blader/taskmaster/compare/blader:main...<fork>:<branch>`. Then
enumerated all non-`main` branches and compared those too. Ignored forks that
were even with or only behind upstream.

## Fork Activity Summary

| Bucket | Count | Notes |
|---|---|---|
| Even with upstream | 6 | Pure forks, no original commits |
| Behind upstream only | 21 | Stale forks, no rebase needed |
| **Ahead of upstream** | **5** | Worth examining (1 fork, multiple branches) |

The five branches with original commits (excluding our own fork):

| Fork / branch | Ahead | Behind | Theme |
|---|---|---|---|
| `mickn:main` | 5 | 0 | **Native Codex hooks + semantic verifier** (major rewrite, v5.0.0) |
| `mickn:feat/codex-native-hooks` | 3 | 0 | Subset of `mickn:main` |
| `gjlondon:fix/stop-hook-feedback-loop` | 1 | 18 | **Single-fire-by-design** philosophy |
| `levi-openclaw:claude/openclaw-agent-skill-7JoVl` | 1 | 18 | OpenClaw platform port (not adoptable) |
| `Semenka:claude/create-claude-guide-NvneU` | 1 | 18 | Auto-generated CLAUDE.md (not adoptable) |

Effectively, **mickn** is the only fork with substantial original engineering;
**gjlondon** contributes one focused architectural insight.

---

## mickn/taskmaster — Native Hooks + Semantic Verifier (v5.0.0)

5-commit chain that takes the project from "Codex via PTY wrapper" to "Codex via
native hooks." Files removed:

- `hooks/inject-continue-codex.sh` (414 LOC queue emitter)
- `hooks/run-codex-expect-bridge.exp` (84 LOC expect bridge)
- `run-taskmaster-codex.sh` (215 LOC wrapper)
- All tests for the above

Files added:

- `hooks/taskmaster-session-start.sh` (27 LOC)
- `hooks/taskmaster-user-prompt-submit.sh` (107 LOC)
- `hooks/taskmaster-stop.sh` (356 LOC)
- `taskmaster-completion-verifier.py` (311 LOC)
- `taskmaster-state.sh` (15 LOC)
- New test suite

Premise: the OpenAI Codex CLI now supports a Claude-Code-style hooks model
(`~/.codex/hooks.json` with `SessionStart`, `UserPromptSubmit`, `Stop` events).
This obviates the entire PTY-injection architecture our fork currently relies
on. **This is the most consequential change in the fork network and worth
verifying independently** (see "Open Questions" below).

### Patterns worth adopting

#### A1. Per-turn user prompt capture via UserPromptSubmit hook (HIGH VALUE)

`hooks/taskmaster-user-prompt-submit.sh` writes the latest external user prompt
to `~/.codex/taskmaster/state/<session_id>.json`, with explicit filtering of:

1. **Hook-injected reprompts** — strings starting with `<hook_prompt`,
   `Stop is blocked until completion is explicitly confirmed.`,
   `Goal not yet verified complete.`, `Recent tool errors were detected.`
2. **Environment context blocks** — `<environment_context>...</environment_context>`
3. **AGENTS.md preludes** — `# AGENTS.md instructions for ...`

Why it matters: solves the "is this a real user goal or just a hook re-prompt?"
problem cleanly. The current fork has no equivalent — it relies on transcript
parsing inside the stop hook, which is brittle and can re-anchor onto its own
output.

**Adopt this pattern** even if we keep the wrapper architecture — we can write
to a state file from the wrapper layer the same way.

#### A2. Semantic completion verifier (HIGH VALUE, MEDIUM RISK)

`taskmaster-completion-verifier.py` calls an OpenAI model
(`TASKMASTER_COMPLETION_MODEL`, default `gpt-5.4-mini`) with:

- the captured user goal (from A1)
- `last_assistant_message`
- a clipped transcript excerpt (`TASKMASTER_COMPLETION_MAX_CONTEXT_CHARS`,
  default 20000)

Returns JSON `{complete: bool, reason: str, next_action: str}`. If
`complete=false`, the stop hook blocks with the verifier's `reason` and
`next_action` injected into the block reason.

Notable engineering details:

- **Secret redaction** before sending to the model (regexes for
  `Authorization: bearer`, `api_key=`, `sk-...`, `lin_api_...`, `phx_...`,
  `xox[baprs]-...`)
- **Loads `.env`** for `OPENAI_API_KEY` if not already in env
- **Pluggable**: `TASKMASTER_COMPLETION_VERIFIER_COMMAND` lets you swap in any
  command that reads the same JSON stdin and returns the same JSON shape — so
  users without an OpenAI key can wire in a local model
- **Fail-open on disable**: `TASKMASTER_COMPLETION_VERIFY=0|false|off|no`
  reverts to the legacy `TASKMASTER_DONE::<session_id>` token flow

Why it matters: replaces "agent self-reports done" with "second-agent verifies
done." The legacy token approach trusts the agent's own assessment; the
verifier doesn't. For long-running autonomous work this is the difference
between "agent declared victory after 2/5 sub-tasks" and a hard machine check.

**Adopt with care.** Two concrete concerns: (1) every stop attempt now costs
an OpenAI API call — at 30+ stop attempts per long session and gpt-5.4-mini
input pricing, this adds up; (2) `gpt-5.4-mini` is referenced as a default —
verify availability/pricing before defaulting; consider `claude-haiku-4-5` as
the Anthropic-side default with `OPENAI_API_KEY` as an alternative.

#### A3. Optional repo-local verifier command (HIGH VALUE, LOW RISK)

`TASKMASTER_VERIFY_COMMAND`: stop is blocked until the named shell command
exits 0. Output is captured (capped at `TASKMASTER_VERIFY_MAX_OUTPUT`, default
4000 bytes) and echoed back to the agent.

Use cases: `cargo test`, `pnpm typecheck`, `make ci`, custom smoke scripts.
Pure win — pairs with the semantic verifier (or replaces it for repos with a
strong test suite).

**Adopt.** Cheap to add, no external dependencies, immediately useful.

#### A4. JSON state-file architecture (MEDIUM VALUE)

`taskmaster-state.sh` exposes `taskmaster_turn_state_path "$session_id"` that
returns `$TASKMASTER_STATE_DIR/<session_id>.json` (default
`~/.codex/taskmaster/state/`). All hooks read/write through this single API.

Cleaner than our current scatter (counter file in `$TMPDIR/taskmaster/`,
queue files in another directory, no shared schema).

**Adopt the pattern** even if the storage location stays separate per
platform.

#### A5. `safe_copy` helper that no-ops on same-path source/dest (LOW VALUE)

`install.sh:30-46` resolves `cd -P` absolute paths for both source and
destination and skips copy when they match. Prevents `cp: 'X' and 'X' are the
same file` errors when running install from inside the install target. Our
install.sh already has this — confirmed it's already in HEAD.

**Already adopted.**

### Patterns to consider but not adopt as-is

#### B1. Wholesale replacement of the PTY wrapper

`mickn` deletes the wrapper, expect bridge, and queue emitter outright. **Do
not adopt verbatim** without first verifying that:

1. Codex CLI actually exposes `SessionStart`, `UserPromptSubmit`, and `Stop`
   hooks in the version the user is on (`codex --version`)
2. The native `Stop` hook supports `decision: "block"` continuation in the
   same way Claude Code does
3. The `last_assistant_message` field is populated by Codex on stop events

If all three hold, the wrapper is dead weight and we should follow `mickn`. If
any are uncertain, keep both paths and gate on `command -v codex && codex
--help | grep -q hooks` or similar.

#### B2. Removed test files

`mickn` removes the wrapper test suite (`tests/inject-continue-codex.test.sh`,
`tests/run-codex-expect-bridge.test.sh`, `tests/run-taskmaster-codex.test.sh`).
If we decide to keep the wrapper as a fallback, keep the tests.

---

## gjlondon/taskmaster — Single-fire by design

One commit (`30ec9bd` "Fix stop hook feedback loop"). Diagnoses a real bug in
the upstream-style transcript-grep approach: the hook's own checklist text
(containing "status: in_progress") gets written into the transcript, which
then matches the hook's own grep on the next fire — guaranteeing
`HAS_INCOMPLETE_SIGNALS=true` forever. Infinite loop.

Fix: make `stop_hook_active=true` an unconditional early exit before any
transcript analysis. Hook becomes single-fire — fires once with the checklist
prompt, allows stop on the next attempt regardless of transcript contents.

### Pattern: rethink the "repeat until token" philosophy (LOW VALUE for our fork)

Our fork already sidesteps this bug in a different way — we use
`last_assistant_message` for primary detection and only fall back to
transcript parsing for an explicit `TASKMASTER_DONE::<session_id>` token (not
generic "in_progress" matches). The contamination problem doesn't apply.

But the underlying philosophy question is worth a beat:

- **gjlondon's claim**: "If the agent saw the checklist and still tries to
  stop, either the work is done or re-firing won't help."
- **Our claim**: "Repeat until the agent emits an explicit done signal,
  because some agents will try to bail before reading the prompt fully."

Empirically, our position is correct for adversarial-stop cases, but
gjlondon's is correct in 95% of real sessions. The cost of being wrong on our
side is one extra reprompt cycle; the cost of being wrong on gjlondon's side
is a session that stops with work undone.

**Do not adopt.** Keep the repeat-until-token model. But consider documenting
the design tradeoff in `docs/SPEC.md` so it doesn't get re-litigated.

---

## levi-openclaw — Not adoptable

Single commit "Rework Taskmaster as an OpenClaw agent skill" — wholesale port
to a different platform (`~/.openclaw/` paths, OpenClaw skill frontmatter,
`scripts/` subfolder convention). Has zero overlap with what we're trying to
do. Skip.

## Semenka — Not adoptable

Single commit adding a 95-line `CLAUDE.md` that's a generic Claude-Code
project guide for the upstream repo (auto-generated by the
`claude/create-claude-guide-NvneU` workflow). No taskmaster-specific
engineering content. Skip.

---

## Recommended adoption plan

In order of value/effort ratio:

### Tier 1 — adopt now (low risk, high value)

1. **`TASKMASTER_VERIFY_COMMAND`** (A3 above). Pure config addition. ~30 LOC
   to wire into the existing `check-completion.sh` and Codex stop path.
2. **JSON state-file layout** (A4). Replace the bare counter file in
   `$TMPDIR/taskmaster/` with a JSON state file under
   `$TASKMASTER_STATE_DIR/<session_id>.json` that holds counter, last-known
   user prompt, and any future fields. Backward-compatible if the migration
   reads the legacy counter file once and discards it.
3. **Hook-internal-prompt detection** in user-facing hooks (subset of A1).
   Even without a full UserPromptSubmit hook, we can teach the wrapper layer
   to recognize and not reprocess our own injected reprompts.

### Tier 2 — adopt after upstream-reality check

4. **Native Codex hooks path** (B1). Conditional on verifying that
   `codex` actually supports the three hook types `mickn` assumes. If yes,
   add a parallel native-hooks code path and let `install.sh` choose between
   wrapper and native at install time based on `codex` capability detection.
   Don't delete the PTY wrapper yet — keep as fallback for older Codex
   installs.
5. **UserPromptSubmit hook for goal capture** (A1). Only useful with a native
   hooks path — depends on (4).

### Tier 3 — adopt with explicit knobs

6. **Semantic completion verifier** (A2). High-value but introduces an LLM
   dependency and per-stop API cost. Recommended shape for our fork:
   - Default OFF (`TASKMASTER_COMPLETION_VERIFY=0`) — opt-in via env
   - Default model `claude-haiku-4-5` (cheaper, lower latency, keeps us on
     Anthropic infra) when `ANTHROPIC_API_KEY` is set; fall back to
     OpenAI `gpt-5.4-mini` when only `OPENAI_API_KEY` is present
   - Port the secret-redaction regex set verbatim — that's a free correctness
     improvement
   - Port `TASKMASTER_COMPLETION_VERIFIER_COMMAND` pluggable interface so
     local-model users can wire in `llama-server` or similar

### Not adopting

7. Single-fire philosophy (gjlondon) — incompatible with our explicit-token
   contract.
8. PTY-wrapper deletion (B1 verbatim) — premature until native hooks
   verified.
9. OpenClaw port (levi-openclaw) — different platform.

---

## Open questions for follow-up

1. **Does `codex` actually support native `SessionStart`, `UserPromptSubmit`,
   and `Stop` hooks?** Mickn's install.sh writes to `~/.codex/hooks.json`,
   which implies yes, but we should verify on the version our users are
   pinned to. If not, his entire architecture is conditional on a future
   Codex release.

2. **Is `gpt-5.4-mini` the right default verifier model?** Mickn picked it
   without comment. We should benchmark cost-per-stop and verifier accuracy
   against `claude-haiku-4-5` before defaulting.

3. **Should the verifier short-circuit on transcript size?** A 20k-char
   transcript at every stop attempt × 30 stops × dozens of users is real
   tokens. Worth a "skip verifier if transcript hasn't changed since last
   verifier call" cache.

## Reproducing this review

```bash
# enumerate forks ahead of upstream
for fork in $(gh api repos/blader/taskmaster/forks --paginate -q '.[].full_name'); do
  ahead=$(gh api "repos/blader/taskmaster/compare/blader:main...${fork#*/}:main" \
    -q '.ahead_by' 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] && echo "$fork ahead=$ahead"
done

# for each interesting fork, also check non-main branches
for fork in <names>; do
  gh api "repos/${fork}/taskmaster/branches" -q '.[].name' \
    | grep -v '^main$'
done
```
