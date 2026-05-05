# Upstream Review: blader/taskmaster main

**Date:** 2026-02-25
**Compare URL:** https://github.com/micahstubbs/taskmaster/compare/main...blader:taskmaster:main
**Upstream:** blader/taskmaster@main
**Our fork:** micahstubbs/taskmaster@main
**Status:** diverged — 13 commits ahead in upstream

---

## Context

Our fork focuses on Claude Code stop hook behavior. The upstream (blader) has moved to
support OpenAI Codex TUI as a first-class target alongside Claude Code, using external
session-log monitoring and tmux/expect PTY injection instead of native hook registration.

This architectural divergence drives most of the ignore decisions below.

---

## Commit Decisions

### cbd9443e — chore: sync local skill updates
**Decision: IGNORE**

Adds the Codex integration layer:
- `hooks/check-completion-codex.sh` (237 lines, Codex monitor)
- `hooks/inject-continue-codex-tmux.sh` (307 lines, tmux transport)
- `hooks/run-codex-expect-bridge.exp` (91 lines, expect PTY bridge)
- `run-taskmaster-codex.sh` (364 lines, Codex session launcher)

Also rewrites README, SKILL.md, docs/SPEC.md, install.sh, and uninstall.sh from a Codex-first perspective.

Codex support is out of scope for this fork. Our focus is the Claude Code stop hook. Adding tmux/expect infrastructure would significantly increase complexity with no benefit to Claude Code users.

---

### 755d165f — chore: sync local skill updates
**Decision: IGNORE**

Refinements to the Codex layer introduced in cbd9443e: renames
`inject-continue-codex-tmux.sh` → `inject-continue-codex.sh`, simplifies
`run-taskmaster-codex.sh`, and trims docs.

Depends on Codex infrastructure we're not adopting.

---

### 88ffd335 — feat: support codex+claude auto install and cleanup docs
**Decision: IGNORE**

Rewrites `install.sh` to auto-detect and install for both Codex (`~/.codex`) and
Claude (`~/.claude`). The new installer is 215 lines vs our 83 lines. While
auto-detection is a nice concept, the upstream now defaults to the Codex path
and the Claude path is a secondary target. Our simpler installer is better
suited to this fork's Claude-only focus.

---

### 452417af — docs: rewrite README for clarity
**Decision: IGNORE**

README is rewritten to be Codex-first, describing the Codex session-log
monitoring approach. Our README is accurate and Claude-focused. Nothing to port.

---

### 4e5075fd — docs: add taskmaster philosophy and compliance rationale
**Decision: IGNORE**

Adds 35 lines to README covering Taskmaster's philosophy. The content is already
present in our `SKILL.md` (the 6-item checklist including HONESTY CHECK). Our
approach of keeping the compliance text in SKILL.md (always loaded as system
context) is architecturally correct for Claude Code — no need to duplicate it
in the README.

---

### 547bfa74 — refactor: remove monitor-only mode
**Decision: N/A (IGNORE)**

Removes `hooks/check-completion-codex.sh` (235 lines) which was added in
cbd9443e and which we never adopted. Also trims SPEC.md. No action needed.

---

### ca471bd8 — refactor: unify codex and claude compliance prompt
**Decision: IGNORE**

Extracts the compliance prompt into `taskmaster-compliance-prompt.sh`, which
`hooks/check-completion.sh` now sources. This allows the same prompt to be
shared between Claude and Codex hooks.

Our architecture keeps the compliance checklist in `SKILL.md`, which Claude Code
loads as system context on every turn — no shell file required. The upstream's
shell-based approach is a workaround for the lack of a native context mechanism
in Codex. We don't have this constraint.

*Note:* The compliance prompt text in the new file is essentially identical to
what we already have in `SKILL.md`. No content to cherry-pick.

---

### c04eeb18 — fix: restore long canonical compliance prompt
**Decision: IGNORE**

Restores the longer version of `taskmaster-compliance-prompt.sh`. Depends on
the file introduced in ca471bd8, which we're not adopting.

---

### c2475d9c — fix: default QUIET=1 in inject-continue-codex
**Decision: IGNORE**

One-line fix in `hooks/inject-continue-codex.sh` — a Codex-specific file we
don't have.

---

### 6814a3f5 — fix: symlink taskmaster-compliance-prompt.sh into hooks dir
**Decision: IGNORE**

Adds one line to `install.sh` to symlink `taskmaster-compliance-prompt.sh`
into the hooks directory. Depends on `taskmaster-compliance-prompt.sh` which
we're not adopting.

---

### 6598e99d — fix: expand tilde in transcript_path for done signal detection
**Decision: APPLY (rewrite to match our structure)**

**Bug:** Claude Code passes `transcript_path` with a leading `~` (e.g.,
`~/.claude/projects/.../session.jsonl`). Bash does not expand `~` inside
double-quoted strings, so `[ -f "$TRANSCRIPT" ]` always fails. The transcript
fallback never fires, and error detection (via `tail -40`) also silently fails.

**Fix:** Add `TRANSCRIPT="${TRANSCRIPT/#\~/$HOME}"` immediately after reading
`transcript_path` from the input JSON.

**Upstream patch (hooks/check-completion.sh):**
```diff
 TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path')
+# Expand leading ~ to $HOME (tilde not expanded inside quotes by bash)
+TRANSCRIPT="${TRANSCRIPT/#\~/$HOME}"
```

**Action:** Apply to both `check-completion.sh` (root) and `hooks/check-completion.sh`.

*See commit 6598e99d in blader/taskmaster for original.*

---

### 71ff69c4 — fix: check last_assistant_message for done signal before transcript
**Decision: ALREADY IMPLEMENTED**

This fix checks `last_assistant_message` from the hook input JSON before
falling back to transcript search. The transcript file may not be flushed yet
when the Stop hook fires.

**Status:** Our v2.3.0 release (commit 1ae2daf, 2026-02-23) independently
implemented this same fix. Both `check-completion.sh` files already check
`last_assistant_message` first. No action needed.

---

### 77c71bbf — fix: honor QUIET for transport banner
**Decision: IGNORE**

Fixes a QUIET flag check in `run-taskmaster-codex.sh` — a Codex-specific
wrapper we don't have.

---

## Summary

| Commit | Decision | Reason |
|--------|----------|--------|
| cbd9443e | IGNORE | Codex integration, out of scope |
| 755d165f | IGNORE | Codex refinements, depends on above |
| 88ffd335 | IGNORE | Codex+Claude installer, Codex-first design |
| 452417af | IGNORE | Codex-centric README |
| 4e5075fd | IGNORE | Already in our SKILL.md |
| 547bfa74 | N/A | Removes file we never added |
| ca471bd8 | IGNORE | Shell-based compliance prompt, workaround we don't need |
| c04eeb18 | IGNORE | Depends on ca471bd8 |
| c2475d9c | IGNORE | Codex-only file |
| 6814a3f5 | IGNORE | Depends on ca471bd8 |
| **6598e99d** | **APPLY** | Tilde expansion bug in transcript_path |
| 71ff69c4 | ALREADY DONE | Implemented in our v2.3.0 |
| 77c71bbf | IGNORE | Codex-only file |

**Net actions: 1 apply, 1 already done, 11 ignored**
