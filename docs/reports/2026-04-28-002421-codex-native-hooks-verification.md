# Codex Native Hooks: Verification Before Adopting mickn's Architecture

**Generated:** 2026-04-28
**Topic:** Does the OpenAI Codex CLI actually support `SessionStart`, `UserPromptSubmit`, and `Stop` hooks natively today, or is `mickn:main`'s rewrite conditional on a future Codex release?

## Executive Summary

**Codex native hooks are real, shipped, and stable.** The OpenAI Codex
CLI exposes `SessionStart`, `UserPromptSubmit`, and `Stop` as first-class
hook events documented at `developers.openai.com/codex/hooks`. Hooks
were marked stable in **v0.122.0 (2026-04-20)** via PR #19012
("Mark codex_hooks stable"). The locally installed version on this
machine is **`codex-cli 0.125.0`** — three releases past the stable
cutoff and well within the supported window.

`mickn:main`'s v5.0.0 rewrite — which deletes the PTY wrapper, expect
bridge, and queue emitter, replacing them with `taskmaster-session-start.sh`,
`taskmaster-user-prompt-submit.sh`, and `taskmaster-stop.sh` — therefore
does **not** depend on any unreleased Codex feature. It targets shipping,
documented behavior. All three preconditions from the original fork
review (`docs/upstream-reviews/blader-taskmaster-forks.md` §B1) are
satisfied:

1. Codex CLI exposes `SessionStart`, `UserPromptSubmit`, and `Stop` ✅  
2. The native `Stop` hook supports `decision: "block"` continuation ✅  
3. `last_assistant_message` is populated on Stop events ✅ (with one  
   caveat — see §3)

The answer to the open question is: **proceed with the port. The
wrapper layer is dead weight on Codex 0.122+.** Two caveats worth
gating on are documented in §3 and flow into the punch list.

## Research Findings

### 1. Hook events explicitly documented

The official Codex hooks reference
([developers.openai.com/codex/hooks](https://developers.openai.com/codex/hooks))
lists six hook events: `SessionStart`, `PreToolUse`, `PermissionRequest`,
`PostToolUse`, `UserPromptSubmit`, `Stop`. The three Taskmaster needs
are all present and have dedicated sections.

Hooks are configured via `~/.codex/hooks.json` (user scope) or
`<repo>/.codex/hooks.json` (project scope), with optional inline
configuration in `config.toml`. Per-layer hooks are merged, not
overridden — higher-precedence layers add to lower ones. Project-local
hooks only load when the `.codex/` layer is trusted.

### 2. `Stop` hook semantics match Claude Code

The docs explicitly state, for the `Stop` event:

> "For this event, `decision: "block"` doesn't reject the turn.
> Instead, it tells Codex to continue and automatically creates a new
> continuation prompt"

The `reason` field becomes the continuation prompt. This is the same
contract Claude Code's Stop hook uses, which is exactly what
`taskmaster-stop.sh` needs in order to push a TASKMASTER continuation
prompt back into the same running session.

`Stop`'s stdin payload includes:

- `turn_id` — the active Codex turn ID
- `stop_hook_active` — whether continuation has already occurred
  (the standard guard against infinite re-fire loops; matches Claude's
  field of the same name)
- `last_assistant_message` — "Latest assistant message text, if available"

The "if available" caveat on `last_assistant_message` is the only
non-trivial parity gap with Claude Code. It is the basis for caveat
(C2) in §3.

### 3. Release timeline

From the Codex changelog
([developers.openai.com/codex/changelog](https://developers.openai.com/codex/changelog)):

| Version | Date | Hook-related change |
|---------|------|---------------------|
| v0.116.0 | 2026-03 | Hooks present in experimental form (referenced in issue #15266 reproductions) |
| v0.122.0 | 2026-04-20 | `PermissionRequest` hooks added (#17563); OTEL metrics for hook runs (#18026) |
| v0.123.0 | 2026-04-23 | Hooks in `config.toml` / `requirements.toml` (#18893); MCP tool support in hooks (#18385); **`codex_hooks` marked stable (#19012)** |
| v0.124.0 | 2026-04-23 | `apply_patch` emits hooks (#18391); Bash `PostToolUse` on `exec_command` (#18888); **regression: hooks broke at startup if config used map syntax (#19199)** |
| v0.125.0 | 2026-04 | (locally installed; current) |

The stable marker landed eight days before this report. mickn's rewrite
(repo timeline aligns with v5.0.0 around the same window) targets the
post-stable surface, not pre-release behavior.

### 4. Known issues that don't block adoption but warrant gating

**Issue #15266 — SessionStart + UserPromptSubmit fire simultaneously on
first prompt** ([github.com/openai/codex/issues/15266](https://github.com/openai/codex/issues/15266)).
Filed against v0.116.0 (March 2026). Closed, but the closing
commit/version is not visible in the page content. Behavior described:
on the first prompt of a session, both hooks fire concurrently rather
than `SessionStart` completing before `UserPromptSubmit`. On subsequent
prompts, only `UserPromptSubmit` fires correctly.

Implication for Taskmaster: if `taskmaster-session-start.sh` writes
state that `taskmaster-user-prompt-submit.sh` reads (e.g.,
seeding the per-session state file), there's a race on the first
prompt. mickn's `taskmaster-session-start.sh` is 27 LOC — small enough
to inspect for whether it depends on this ordering. We should verify
on 0.125.0 before merging.

**Issue #19199 — v0.124.0 hook config parsing regression**
([github.com/openai/codex/issues/19199](https://github.com/openai/codex/issues/19199)).
`codex-cli` failed to start when hooks were configured in
`config.toml` using map syntax (the documented form). Closed; resolution
version not shown. The local install is 0.125.0, which post-dates the
fix, so this is informational only — but it's a reminder that hook
config schemas are still in flux at the toml-vs-json boundary.

### 5. Third-party confirmation

Independent projects already shipping against Codex's native hooks:

- **`hatayama/codex-hooks`** — a hooks runner that reuses Claude
  Code's hooks settings against Codex CLI
  ([github.com/hatayama/codex-hooks](https://github.com/hatayama/codex-hooks)).
  Existence of this project confirms the surface is real and
  Claude-Code-compatible enough to be adapted.
- **`Yeachan-Heo/oh-my-codex` (OmX)** — a Codex enhancement framework
  with an active roadmap issue (#1307) about mapping its hook surfaces
  onto Codex's native hooks, indicating a community migration from
  bespoke wrappers to native is in progress.
- **ArcKit v4** — released March 2026 with first-class Codex hooks
  support
  ([medium.com/arckit/arckit-v4](https://medium.com/arckit/arckit-v4-first-class-codex-and-gemini-support-with-hooks-mcp-servers-and-native-policies-abdf9569e00e)).

The pattern across all three: bespoke PTY/wrapper hacks are being
deleted in favor of the native hook surface throughout April 2026.
mickn's rewrite is the same move applied to Taskmaster.

## Analysis

The fork review's §B1 set three preconditions for adopting mickn's
wholesale wrapper deletion. All three are satisfied:

1. **Codex CLI exposes SessionStart/UserPromptSubmit/Stop hooks**  
   in the version the user is on. Local install: `codex-cli 0.125.0`.
   Hook events documented since v0.122 stable; we are on 0.125.
   ✅ confirmed.

2. **The native `Stop` hook supports `decision: "block"` continuation**  
   in the same way Claude Code does. Documented verbatim in
   `developers.openai.com/codex/hooks`: "doesn't reject the turn.
   Instead, it tells Codex to continue and automatically creates a new
   continuation prompt." ✅ confirmed.

3. **`last_assistant_message` is populated by Codex on stop events.**  
   Documented as a Stop-event stdin field, with the qualifier "if
   available." This matches Claude Code's behavior, which also has
   cases where the field is empty (e.g., when the assistant emits no
   message text on stop). ⚠️ confirmed-with-caveat.

The caveat on (3) is meaningful but not blocking. The current fork's
detection is layered: `last_assistant_message` for primary detection,
transcript-grep for explicit `TASKMASTER_DONE::<session_id>` token as
fallback. That layering should survive the port unchanged — the
fallback handles the "if available" gap.

The PTY wrapper, expect bridge, and queue emitter become genuinely
redundant at 0.122+. They cost LOC, complexity, and a `expect` runtime
dependency. Their only remaining justification was as a portability
floor for Codex versions without native hooks — which now means
versions older than April 2026, a window users will only stay in
deliberately.

The right migration shape mirrors §B1's hedge: keep both code paths,
gate on `codex --version` or a feature probe (`codex --help | grep -q
hook` or test for the `~/.codex/hooks.json` schema), and let
`install.sh` choose. Default to native on detection, fall back to
wrapper on older Codex. Delete the wrapper path only after a deprecation
window where logs confirm zero installs are using it.

## Recommendations

Adopt mickn's native-hooks architecture, but stage it. Two safety
rails make this safe rather than risky:

1. **Version-gated install.** Probe Codex version in `install.sh`.  
   If `>= 0.122.0`, install native hooks; if `< 0.122.0` or no codex
   detected, install the existing wrapper path. The user's machine
   (0.125.0) gets the native path automatically.  
2. **Keep the wrapper path on disk.** Don't `git rm` the PTY wrapper,  
   expect bridge, or their tests in the same PR. Mark them
   `legacy/`-prefixed and have `install.sh` install from `legacy/`
   when version-gated. Plan to remove them after one minor release if
   no one reports using them.

The `last_assistant_message` + transcript-token layered detection
already in the fork is the right pattern and ports cleanly. Do not
collapse to a single detection mode.

## Punch List (for `/mei`)

Each item is a self-contained adoption decision. Numbered for
priority. Phase tags only — no time estimates.

1. **[Phase 1, HIGH] Add Codex version probe to `install.sh`.**  
   Detect `codex --version` and parse semver; expose as
   `$CODEX_HOOKS_NATIVE` (true if `>= 0.122.0`). Touches only
   `install.sh`. No behavior change yet — just the detection.

2. **[Phase 1, HIGH] Port `taskmaster-session-start.sh` from  
   `mickn:main`.** 27 LOC. Place at `hooks/taskmaster-session-start.sh`.
   Verify it does not depend on completing-before-`UserPromptSubmit`
   ordering (issue #15266). If it does, add a state-file lock that
   both hooks honor.

3. **[Phase 1, HIGH] Port `taskmaster-stop.sh` from `mickn:main`.**  
   356 LOC. Replaces the wrapper's stop-detection role. Must emit
   `decision: "block"` JSON with the shared compliance prompt as
   `reason`. Reuses `taskmaster-compliance-prompt.sh`. Keep the
   `last_assistant_message` → transcript-token fallback layered
   detection.

4. **[Phase 1, HIGH] Port `taskmaster-user-prompt-submit.sh` from  
   `mickn:main`.** 107 LOC. Implements per-turn external user prompt
   capture with `<hook_prompt>` filtering. This is pattern A1 from the
   fork review and the highest-value behavioral upgrade.

5. **[Phase 1, MEDIUM] Move existing wrapper artifacts to `legacy/`.**  
   `hooks/inject-continue-codex.sh`, `hooks/run-codex-expect-bridge.exp`,
   `run-taskmaster-codex.sh`, plus their tests in
   `tests/inject-continue-codex.test.sh` etc. Update `install.sh` to
   choose `hooks/` (native) or `legacy/` (wrapper) based on the
   version probe.

6. **[Phase 1, MEDIUM] Write `~/.codex/hooks.json` template** in  
   `install.sh` mapping the three event names to the three new
   `hooks/taskmaster-*.sh` scripts. Merge-safe with any existing
   user hooks (don't clobber).

7. **[Phase 2, MEDIUM] Add a feature smoke test:** create `taskmaster  
   selftest --codex-hooks` that fires a no-op session, asserts each of
   the three hooks executed via state-file markers, and reports OK/FAIL.
   Exercised in `install.sh --verify` and CI.

8. **[Phase 2, LOW] Document the version gate in  
   `docs/SPEC.md`.** Single section explaining the dual code paths,
   the 0.122.0 cutover, the issue-#15266 race awareness, and the
   deprecation plan for `legacy/`.

9. **[Phase 3, LOW] Sunset `legacy/` after one minor release** if no  
   reports of installs using it. Track via an `install.sh`
   instrumentation line that logs which path was selected. Drop after
   evidence justifies it.

10. **[Phase 3, LOW] Watch upstream issue #15266** for a definitive  
    fix-version. If the simultaneous-fire race is confirmed fixed in
    a known version, tighten `$CODEX_HOOKS_NATIVE` lower bound to
    that version and remove any race-mitigation lock added in (2).

## Sources

- [Hooks – Codex | OpenAI Developers](https://developers.openai.com/codex/hooks) — primary reference; documents all six hook events including `SessionStart`, `UserPromptSubmit`, `Stop`. Contains the verbatim specification of `decision: "block"` for `Stop` and the `last_assistant_message` field.
- [Changelog – Codex | OpenAI Developers](https://developers.openai.com/codex/changelog) — release timeline confirming hooks went stable in v0.122.0 (April 20, 2026) via PR #19012 "Mark codex_hooks stable."
- [Issue #15266 — UserPromptSubmit and SessionStart hooks fire simultaneously on first prompt](https://github.com/openai/codex/issues/15266) — known caveat, filed v0.116.0 (March 2026), closed.
- [Issue #19199 — codex-cli 0.124.0 fails to start when hook config is present and codex_hooks is enabled](https://github.com/openai/codex/issues/19199) — informational; not a blocker on 0.125.0.
- [PR #14867 — hooks: use a user message > developer message for prompt continuation](https://github.com/openai/codex/pull/14867) — early-development context for hook continuation semantics.
- [PR #15118 — hooks: turn_id extension for Stop & UserPromptSubmit](https://github.com/openai/codex/pull/15118) — confirms `turn_id` field added to the stdin payload of these specific hooks.
- [Discussion #2150 — Hook would be a great feature](https://github.com/openai/codex/discussions/2150) — historical context for how hooks landed.
- [hatayama/codex-hooks](https://github.com/hatayama/codex-hooks) — third-party hooks runner reusing Claude Code's hooks settings against Codex; corroborates Claude-compatible surface.
- [Yeachan-Heo/oh-my-codex issue #1307 — roadmap: map OMC hook surfaces onto OMX native Codex hooks](https://github.com/Yeachan-Heo/oh-my-codex/issues/1307) — community-wide migration pattern from bespoke wrappers to native hooks.
- [ArcKit v4: First-Class Codex and Gemini Support with Hooks](https://medium.com/arckit/arckit-v4-first-class-codex-and-gemini-support-with-hooks-mcp-servers-and-native-policies-abdf9569e00e) — independent third-party adoption of the same hook surface in March 2026.
- Local fork review: `docs/upstream-reviews/blader-taskmaster-forks.md` §B1 — the three preconditions verified by this report.
- Local Codex install: `codex-cli 0.125.0` (`/usr/local/bin/codex`) — three releases past the stable cutoff.
