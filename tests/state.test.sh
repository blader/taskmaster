#!/usr/bin/env bash
#
# Tests for taskmaster-state.sh.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/taskmaster-state.sh"

# Isolate state under a temp dir
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/taskmaster-state-test.XXXXXX")"
trap 'rm -rf "$TEST_HOME"; rm -f "${TMPDIR:-/tmp}/taskmaster/sess-legacy-$$" "${TMPDIR:-/tmp}/taskmaster/sess-migrate-additive-$$" "${TMPDIR:-/tmp}/taskmaster/sess-overflow-$$"' EXIT
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

# --- Critical #1 regression: corrupted state file is preserved, not clobbered ---
SID5="sess-corrupt-$$"
PATH5="$(taskmaster_state_path "$SID5")"
mkdir -p "$(dirname "$PATH5")"
printf 'this is not json' > "$PATH5"
PRE_BYTES=$(wc -c < "$PATH5")
set +e
taskmaster_state_update "$SID5" '.stop_count = 99' 2>/dev/null
RC=$?
set -e
POST_BYTES=$(wc -c < "$PATH5")
[[ "$RC" != "0" ]] && ok "corrupted file: update returns non-zero" \
  || fail "corrupted file: update returns non-zero (got $RC)"
[[ "$POST_BYTES" == "$PRE_BYTES" ]] && ok "corrupted file: bytes preserved exactly" \
  || fail "corrupted file: bytes changed (pre=$PRE_BYTES, post=$POST_BYTES)"
if compgen -G "${PATH5}.tmp.*" >/dev/null; then
  fail "corrupted file: tmp file leaked: $(echo "${PATH5}".tmp.*)"
else
  ok "corrupted file: tmp file cleaned up"
fi

# --- Critical #2 regression: migrate is additive (doesn't rewind a peer increment) ---
LEGACY_DIR="${TMPDIR:-/tmp}/taskmaster"
mkdir -p "$LEGACY_DIR"
SID6="sess-migrate-additive-$$"
PATH6="$(taskmaster_state_path "$SID6")"
# Pre-populate state as if a peer had already migrated AND incremented
taskmaster_state_init "$SID6"
taskmaster_state_update "$SID6" '.stop_count = 100'
# Plant a legacy file simulating a stale handle
echo "5" > "$LEGACY_DIR/$SID6"
# Now migrate — should absorb additively and not rewind
taskmaster_state_migrate_legacy_counter "$SID6"
SC="$(jq -r .stop_count <"$PATH6")"
[[ "$SC" == "105" ]] && ok "migrate is additive (100 + 5 = 105)" \
  || fail "migrate is additive — expected 105, got $SC"
[[ ! -f "$LEGACY_DIR/$SID6" ]] && ok "additive migrate still removes legacy file" \
  || fail "additive migrate did not remove legacy file"

# --- Important #3 regression: oversize legacy counter is capped to 0 ---
SID7="sess-overflow-$$"
echo "999999999999999999999999999999" > "$LEGACY_DIR/$SID7"
taskmaster_state_migrate_legacy_counter "$SID7"
SC="$(jq -r .stop_count <"$(taskmaster_state_path "$SID7")")"
[[ "$SC" == "0" ]] && ok "oversize legacy counter capped to 0" \
  || fail "oversize legacy counter not capped (got $SC)"

# --- Important #6 regression: record_verifier_run rejects non-boolean complete ---
SID8="sess-verifier-$$"
taskmaster_state_init "$SID8"
set +e
taskmaster_state_record_verifier_run "$SID8" "hash1" '"true"' "ok" "next" 2>/dev/null
RC=$?
set -e
[[ "$RC" == "64" ]] && ok "record_verifier_run rejects string complete with EX_USAGE" \
  || fail "record_verifier_run accepted string complete (rc=$RC)"
# Sanity: bare true is accepted
taskmaster_state_record_verifier_run "$SID8" "hash2" 'true' "ok" "next"
COMPLETE="$(jq -r .last_verifier_run.complete <"$(taskmaster_state_path "$SID8")")"
[[ "$COMPLETE" == "true" ]] && ok "record_verifier_run accepts bare true" \
  || fail "record_verifier_run rejected bare true (got $COMPLETE)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
