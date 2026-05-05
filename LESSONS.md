# Lessons Learned

Append-only log of debugging insights and non-obvious solutions.

---

## 2026-02-25T14:00 - Claude Code hook `reason` is dual-use: user-visible AND AI context

**Problem**: The taskmaster stop hook embedded a full 5-item completion checklist in the `reason` field of `{ "decision": "block", "reason": "..." }`. Every stop attempt printed the entire checklist to the user's terminal.

**Root Cause**: Claude Code's stop hook `reason` field serves two purposes simultaneously — it is displayed to the user in the terminal UI ("Stop hook error: ...") AND injected back into the AI conversation as context. Putting verbose instructions in `reason` to inform the AI caused them to also appear as user-visible output.

**Lesson**: The `reason` field is not a private AI channel. Anything in `reason` is shown to the human. Persistent AI instructions belong in SKILL.md (system context loaded at session start), not in transient hook `reason` values. The `reason` should carry only the minimum transient signal the agent needs right now.

**Code Issue**:
```bash
# Before (verbose — full checklist in reason, shown to user)
REASON="${LABEL}: ${PREAMBLE}

Before stopping, do each of these checks:
1. RE-READ THE ORIGINAL USER MESSAGE(S)...
2. CHECK THE TASK LIST...
[etc]"
jq -n --arg reason "$REASON" '{ decision: "block", reason: $reason }'

# After (minimal — only the done signal; checklist lives in SKILL.md)
DONE_SIGNAL="${DONE_PREFIX}::${SESSION_ID}"
jq -n --arg reason "$DONE_SIGNAL" '{ decision: "block", reason: $reason }'
```

**Solution**: Strip the checklist from `reason`. Put it only in SKILL.md, which is always loaded as system context. The `reason` now contains only the done signal token the agent must emit.

**Prevention**: When designing Claude Code hooks, ask: "Does this text need to be in the reason, or is it already in system context?" If it's in a skill file, it doesn't belong in `reason`.

---

## 2026-02-25T14:30 - `last_assistant_message` is faster than transcript scanning for done-signal detection

**Problem**: The hook was opening and scanning potentially large transcript JSON files on every stop attempt to detect whether the agent had emitted the done signal.

**Root Cause**: The hook relied exclusively on transcript-file parsing, which requires disk I/O and JSON scanning on every invocation.

**Lesson**: The Claude Code hook input JSON exposes `last_assistant_message` directly. Checking that field is O(1) and avoids the file read in the common case (agent just emitted the signal in its latest message).

**Code Issue**:
```bash
# Before (always scans transcript file)
if tail -400 "$TRANSCRIPT" 2>/dev/null | grep -Fq "$DONE_SIGNAL"; then
  HAS_DONE_SIGNAL=true
fi

# After (fast path via last_assistant_message, transcript as fallback)
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')
if [ -n "$LAST_MSG" ] && echo "$LAST_MSG" | grep -Fq "$DONE_SIGNAL" 2>/dev/null; then
  HAS_DONE_SIGNAL=true
fi
if [ "$HAS_DONE_SIGNAL" = false ] && [ -f "$TRANSCRIPT" ]; then
  if tail -400 "$TRANSCRIPT" 2>/dev/null | grep -Fq "$DONE_SIGNAL"; then
    HAS_DONE_SIGNAL=true
  fi
fi
```

**Prevention**: Always check `last_assistant_message` before falling back to transcript file parsing in stop hooks.

## 2026-05-05T06:02 - --force-with-lease rejection saves remote work after rebase divergence

**Problem**: After rebasing local `main` to ship v4.3.0, `git push --force-with-lease origin main` was rejected with "stale info" — even though the local view of origin/main looked correct based on the session summary noting "50 ahead, 15 behind." A blind retry with `--force` would have silently destroyed two commits and a `v2.4.0` annotated tag pushed to origin from a parallel session in the intervening hours.

**Root Cause**: `--force-with-lease` compares the *local view* of the remote ref against the *actual remote* at push time. When another session pushes between fetch and push, the lease is stale. The reflexive response is to fetch and retry — but fetching alone updates the remote-tracking ref without showing what changed. Without an explicit `git log origin/main --not main`, the new commits get absorbed into the local view and then overwritten by the next force-push.

**Lesson**: Treat `--force-with-lease` rejection as a signal to *enumerate* what's on the remote, not as friction to bypass. Run `git log origin/main --not main --oneline` after every fetch in a divergence-resolution flow, and classify each commit:
1. Earlier-SHA versions of commits already in local history (rebase artifacts — safe to discard)
2. Genuinely new work from another session (must cherry-pick before force-push)

When in doubt, cherry-pick. The cost of an unnecessary cherry-pick is one extra commit; the cost of a wrong force-push is unrecoverable lost work.

**Workflow**:
```bash
# 1. Fetch latest
git fetch origin

# 2. Enumerate what's on remote-not-local
git log origin/main --not main --oneline

# 3. For each commit: classify as rebase artifact vs new work
#    - Rebase artifact: same author + same message + similar timestamp = safe
#    - New work: different message or post-rebase timestamp = cherry-pick

# 4. Cherry-pick the new work onto local
git cherry-pick <sha>

# 5. Resolve conflicts mindfully — when an upstream commit predates a
#    major refactor, the conflict markers usually show obsolete machinery.
#    Take HEAD on the conflict and port only the genuinely-new behavior
#    (intent, not mechanics) into the equivalent post-refactor function.

# 6. Now push with lease
git push --force-with-lease origin main
```

**Prevention**:
- Never bypass `--force-with-lease` rejection with bare `--force` without first running the `--not` log enumeration.
- Treat tags pushed by other sessions (e.g. `[new tag] v2.4.0`) as load-bearing signals — they document a decision point that local history doesn't know about.
- When rebasing onto a base that's diverged from the public head, plan for cherry-pick reconciliation as part of the workflow, not as an exception.

## 2026-05-05T06:02 - Editing git conflict markers requires removing all three sigils

**Problem**: Resolving a CHANGELOG.md conflict via the Edit tool: replaced the `<<<<<<< HEAD` line and the `>>>>>>>` line, but left a stray `=======` separator a few lines below in the same hunk. The next `bash -n` on a sibling install.sh passed, but `git status` still showed the file as conflicted, and a follow-up grep revealed the orphan separator.

**Root Cause**: Git conflict blocks have three sigils — `<<<<<<<`, `=======`, `>>>>>>>` — and a partial edit that addresses only the open/close markers leaves the separator behind, which git still treats as an unresolved conflict marker. With nested or stacked conflicts in one file, an Edit-tool replacement can match the outer pair and miss inner separators.

**Lesson**: After every conflict resolution edit, grep for *all three* sigils as a single check, not just for `<<<<<<<`:

```bash
grep -n '<<<<<<<\|=======\|>>>>>>>' <file>
```

Pair this with `bash -n` (or language-equivalent syntax check) for the affected files before staging — the syntax check catches cases where conflict residue corrupts script structure even when the markers technically remain.

**Prevention**: Make the three-sigil grep a reflexive post-edit step in any conflict-resolution flow, exactly the same way `bash -n` is the post-edit step for shell-script changes.
