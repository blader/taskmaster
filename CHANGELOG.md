# Changelog

All notable changes to Taskmaster are documented here.

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
  no user action required. The migration is flock-protected and
  additive (a peer's increments are not rewound).

### References
- Design: `docs/designs/2026-04-28-072245-fork-pattern-adoption.md`
- Plan: `docs/plans/2026-04-28-083546-t1-fork-pattern-adoption.md`
- Source review: `docs/upstream-reviews/blader-taskmaster-forks.md`

## [2.4.0] - 2026-03-30

### Changed
- Install script now also copies hook to `~/.claude/hooks/taskmaster-check-completion.sh`
  (user-level hooks directory), consistent with standard Claude Code hook layout.
- Settings.json registration now points to `~/.claude/hooks/` path by default.
- Uninstall script updated to clean up from both locations.

## [2.3.0] - 2026-02-25

### Changed
- Hook `reason` field now contains only the TASKMASTER_DONE signal token instead
  of the full completion checklist. This keeps user-visible terminal output
  minimal — one collapsed line rather than a wall of text.
- Full completion checklist lives exclusively in SKILL.md, which is always
  loaded as system context. The agent already has all instructions; the reason
  field no longer needs to duplicate them.
- Added `last_assistant_message` as the primary done-signal detection path
  (faster, no transcript file parsing required). Transcript-based check is
  retained as fallback.
- Removed `HAS_RECENT_ERRORS` / `stop_hook_active` escape-hatch logic in favor
  of the explicit TASKMASTER_DONE signal protocol.
- `hooks/check-completion.sh` brought in sync with root-level canonical source.

## [2.2.0] - 2026-02-19

### Changed
- Default `TASKMASTER_MAX` set to 100 (previously 0 / infinite).
- Moved full completion checklist from hook `reason` into SKILL.md system
  context (first pass; reason still contained a short prompt).
- `install.sh` made POSIX-portable (`sh` shebang, conditional `pipefail`).

### Fixed
- Resolved infinite loop caused by `set -euo pipefail` in sh-sourced contexts.

## [2.1.0]

### Added
- Session-scoped counter with configurable `TASKMASTER_MAX` escape hatch.
- Subagent skip: transcripts shorter than 20 lines are ignored.
- `TASKMASTER_DONE_PREFIX` env var for customising the done token prefix.

## [2.0.0]

### Added
- TASKMASTER_DONE signal protocol: stop is allowed only after the agent emits
  `TASKMASTER_DONE::<session_id>` in its response.
- Transcript-based done-signal detection.

## [1.0.0]

### Added
- Initial release: stop hook that blocks agent from stopping prematurely.
- Completion checklist injected via hook `reason` field.
- `TASKMASTER_MAX` loop guard.
