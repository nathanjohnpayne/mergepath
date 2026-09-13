#!/usr/bin/env bash
#
# test_pr_review_policy_nudge.sh — regression suite for
# scripts/pr-review-policy-nudge.sh (#931).
#
# The guarantee under test is narrow: the script causes
# .github/workflows/pr-review-policy.yml to re-evaluate a PR, and publishes
# nothing itself. So the assertions are mostly about what it does NOT do — no
# check-run write, no edit once both contexts have reported, no body mutation
# beyond one marker, no edit that breaks a body it did not break.
#
# The subject runs from its real location; only its two seams are overridden
# (MERGEPATH_NUDGE_GH_AS_AUTHOR, MERGEPATH_NUDGE_VALIDATE_BIN) plus a `gh`
# stub on PATH. The inert-marker case deliberately uses the REAL
# scripts/validate-pr-body.sh: that the marker survives production validation
# is the load-bearing fact, and a stub cannot establish it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/pr-review-policy-nudge.sh"
REAL_VALIDATE="$ROOT/scripts/validate-pr-body.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-policy-nudge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1" >&2; FAILED=$((FAILED + 1)); }

[ -x "$SUBJECT" ] || { echo "FAIL: subject missing or not executable: $SUBJECT" >&2; exit 1; }
[ -x "$REAL_VALIDATE" ] || { echo "FAIL: real validator missing: $REAL_VALIDATE" >&2; exit 1; }

mkdir -p "$TMP/bin"

# --- stubs -----------------------------------------------------------------

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${STUB_GH_LOG:?}"
case "$*" in
  "repo view"*)
    printf '%s\n' "${STUB_REPO:-owner/repo}"; exit 0 ;;
  *check-runs*)
    if [ "${STUB_RUNS_RC:-0}" -ne 0 ]; then echo "check-runs read failed" >&2; exit "$STUB_RUNS_RC"; fi
    # The real command prints one name per line under this --jq.
    [ -n "${STUB_CHECK_NAMES:-}" ] && printf '%s\n' "$STUB_CHECK_NAMES"
    exit 0 ;;
  *"/pulls/"*)
    if [ "${STUB_PR_RC:-0}" -ne 0 ]; then echo "pull read failed" >&2; exit "$STUB_PR_RC"; fi
    cat "${STUB_PR_JSON_FILE:?}"; exit 0 ;;
esac
echo "unexpected gh call: $*" >&2
exit 90
STUB
chmod +x "$TMP/bin/gh"

# Stands in for scripts/gh-as-author.sh: records the wrapped command and
# captures exactly the bytes that would have been written to the PR body.
cat > "$TMP/bin/gh-as-author-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${STUB_EDIT_LOG:?}"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then cp "$a" "${STUB_WRITTEN_BODY:?}"; fi
  prev=$a
done
exit "${STUB_EDIT_RC:-0}"
STUB
chmod +x "$TMP/bin/gh-as-author-stub.sh"

# Passes any body without the marker and rejects any body with it: the exact
# shape the non-introduction invariant must refuse to write.
cat > "$TMP/bin/validate-hostile.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
body=$(cat)
case "$body" in
  *mergepath-recovery-nudge:*) echo "hostile validator rejects the marker" >&2; exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/validate-hostile.sh"

# Freezes the clock so the "same second as the last nudge" path is reachable
# without waiting for one.
cat > "$TMP/bin/frozen-date" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_FROZEN_STAMP:?}"
STUB
chmod +x "$TMP/bin/frozen-date"

VALID_BODY=$(printf 'Authoring-Agent: claude\n\n## Summary\n- a change\n\n## Self-Review\n- [x] Correctness: fine\n')

# --- harness ---------------------------------------------------------------

CASE=0
# run_nudge <state> <head_sha> <body> <check_names> [extra env assignments...]
run_nudge() {
  local state=$1 head=$2 body=$3 names=$4; shift 4
  CASE=$((CASE + 1))
  D="$TMP/case-$CASE"; mkdir -p "$D"
  jq -n --arg s "$state" --arg h "$head" --arg b "$body" \
    '{state:$s, head:{sha:$h}, body:$b}' > "$D/pr.json"
  : > "$D/gh.log"; : > "$D/edit.log"; : > "$D/written.txt"
  set +e
  env PATH="$TMP/bin:$PATH" \
    STUB_GH_LOG="$D/gh.log" STUB_EDIT_LOG="$D/edit.log" \
    STUB_WRITTEN_BODY="$D/written.txt" STUB_PR_JSON_FILE="$D/pr.json" \
    STUB_CHECK_NAMES="$names" \
    MERGEPATH_NUDGE_GH_AS_AUTHOR="$TMP/bin/gh-as-author-stub.sh" \
    MERGEPATH_NUDGE_VALIDATE_BIN="$REAL_VALIDATE" \
    "$@" \
    bash "$SUBJECT" 7 owner/repo >"$D/out.txt" 2>"$D/err.txt"
  RC=$?
  set -e
  OUT=$(cat "$D/out.txt"); ERR=$(cat "$D/err.txt")
  WROTE=$(wc -c <"$D/edit.log" | tr -d ' ')
}

BOTH=$'Self-Review Required\nLabel Gate\nlint'
ONLY_GATE=$'Label Gate\nlint'
NEITHER=$'lint\nscope'

# --- 1: the recovery case --------------------------------------------------
echo; echo "--- 1: neither context reported -> nudge"
run_nudge open sha111 "$VALID_BODY" "$NEITHER"
if [ "$RC" = 0 ] && [ "$WROTE" != 0 ] && grep -q "gh pr edit 7 --repo owner/repo" "$D/edit.log"; then
  pass "a head missing both contexts is nudged through gh-as-author"
else
  fail "expected rc=0 and one wrapped edit; rc=$RC edit.log='$(cat "$D/edit.log")' err='$ERR'"
fi
MARKERS=$(grep -c "mergepath-recovery-nudge:" "$D/written.txt" || true)
if [ "$MARKERS" = 1 ]; then
  pass "the written body carries exactly one provenance marker"
else
  fail "expected exactly one marker in the written body; found $MARKERS"
fi

echo "--- 1b: the written body is still valid to the REAL validator"
if bash "$REAL_VALIDATE" <"$D/written.txt" >/dev/null 2>&1 \
  && bash "$REAL_VALIDATE" --self-review-only <"$D/written.txt" >/dev/null 2>&1; then
  pass "the marker is inert: production validation passes in both modes"
else
  fail "the marker broke production PR-body validation"
fi

echo "--- 1c: nothing was published"
# The script's whole claim is that it produces no check run. Any write verb on
# the check-runs endpoint, or any non-GET gh api call at all, breaks it.
if ! grep -Eq -- "-X|--method|--input|-f |check-runs.*POST" "$D/gh.log" \
  && [ "$(grep -c "check-runs" "$D/gh.log")" = 1 ]; then
  pass "no check-run is created: the only check-runs call is the single read"
else
  fail "the run made a non-GET gh api call or more than one check-runs call: $(cat "$D/gh.log")"
fi

# --- 2: one context missing is still a recovery case -----------------------
echo; echo "--- 2: only Label Gate reported -> still nudge"
run_nudge open sha222 "$VALID_BODY" "$ONLY_GATE"
if [ "$RC" = 0 ] && [ "$WROTE" != 0 ] && printf '%s' "$OUT" | grep -q "Self-Review Required"; then
  pass "a partially-reported head is nudged and names the missing context"
else
  fail "expected rc=0 naming the missing context; rc=$RC out='$OUT' err='$ERR'"
fi

# --- 3 and 4: refuse on PRESENCE, not on success ---------------------------
echo; echo "--- 3: both contexts reported -> refuse (rc 3), no write"
run_nudge open sha333 "$VALID_BODY" "$BOTH"
if [ "$RC" = 3 ] && [ "$WROTE" = 0 ]; then
  pass "both contexts present -> rc 3 and no edit"
else
  fail "expected rc=3 with no edit; rc=$RC wrote=$WROTE err='$ERR'"
fi

echo "--- 4: both reported and one is RED -> still refuse (presence, not success)"
# There is no conclusion in the check-run names the script reads, which is the
# point: it cannot distinguish a red verdict from a green one and must not
# try. This case pins that it does not grow a conclusion-aware escape hatch —
# a red Label Gate is the canonical producer having run and having decided.
run_nudge open sha444 "$VALID_BODY" "$BOTH"
if [ "$RC" = 3 ] && [ "$WROTE" = 0 ] && ! grep -q "conclusion" "$D/gh.log"; then
  pass "a reported-and-failing context is not a recovery case, and no conclusion is consulted"
else
  fail "expected rc=3, no edit, no conclusion read; rc=$RC wrote=$WROTE log='$(cat "$D/gh.log")'"
fi

# --- 5: replace, not append ------------------------------------------------
echo; echo "--- 5: an existing marker is REPLACED, not appended"
SEEDED="$VALID_BODY"$'\n\n<!-- mergepath-recovery-nudge: 2020-01-01T00:00:00Z -->'
run_nudge open sha555 "$SEEDED" "$NEITHER"
MARKERS=$(grep -c "mergepath-recovery-nudge:" "$D/written.txt" || true)
if [ "$RC" = 0 ] && [ "$MARKERS" = 1 ] && ! grep -q "2020-01-01T00:00:00Z" "$D/written.txt"; then
  pass "the body records only the most recent nudge"
else
  fail "expected one fresh marker and no stale one; rc=$RC markers=$MARKERS body='$(cat "$D/written.txt")'"
fi

echo "--- 5b: nothing above the marker is touched"
# `printf '%s\n'`, not `%s`: VALID_BODY lost its trailing newline to the
# command substitution that built it, while the sed side emits one.
if diff <(printf '%s\n' "$VALID_BODY") \
  <(grep -v "mergepath-recovery-nudge:" "$D/written.txt" | sed -e :a -e '/^$/{$d;N;ba' -e '}') >/dev/null; then
  pass "the edit changes the marker line and nothing else"
else
  fail "the edit mutated body content outside the marker"
fi

# --- 6: the no-op guard ----------------------------------------------------
echo; echo "--- 6: a rebuilt marker identical to the current body -> refuse (rc 2)"
# Same second as the previous nudge. GitHub emits no `edited` event for an
# unchanged body, so writing it would report success having fired nothing.
FROZEN="2026-01-02T03:04:05Z"
SAME="$VALID_BODY"$'\n\n<!-- mergepath-recovery-nudge: '"$FROZEN"' -->'
CASE=$((CASE + 1)); D="$TMP/case-$CASE"; mkdir -p "$D"
jq -n --arg b "$SAME" '{state:"open", head:{sha:"sha666"}, body:$b}' > "$D/pr.json"
: > "$D/gh.log"; : > "$D/edit.log"; : > "$D/written.txt"
cp "$TMP/bin/frozen-date" "$TMP/bin/date"
set +e
env PATH="$TMP/bin:$PATH" STUB_FROZEN_STAMP="$FROZEN" \
  STUB_GH_LOG="$D/gh.log" STUB_EDIT_LOG="$D/edit.log" \
  STUB_WRITTEN_BODY="$D/written.txt" STUB_PR_JSON_FILE="$D/pr.json" \
  STUB_CHECK_NAMES="$NEITHER" \
  MERGEPATH_NUDGE_GH_AS_AUTHOR="$TMP/bin/gh-as-author-stub.sh" \
  MERGEPATH_NUDGE_VALIDATE_BIN="$REAL_VALIDATE" \
  bash "$SUBJECT" 7 owner/repo >"$D/out.txt" 2>"$D/err.txt"
RC=$?
set -e
rm -f "$TMP/bin/date"
if [ "$RC" = 2 ] && [ "$(wc -c <"$D/edit.log" | tr -d ' ')" = 0 ] \
  && grep -q "fire no event" "$D/err.txt"; then
  pass "an unchanged body is refused rather than written as a silent no-op"
else
  fail "expected rc=2 with no edit and a no-event message; rc=$RC err='$(cat "$D/err.txt")'"
fi

# --- 7: the non-introduction invariant -------------------------------------
echo; echo "--- 7: an edit that would break validation is refused (rc 4), no write"
run_nudge open sha777 "$VALID_BODY" "$NEITHER" \
  MERGEPATH_NUDGE_VALIDATE_BIN="$TMP/bin/validate-hostile.sh"
if [ "$RC" = 4 ] && [ "$WROTE" = 0 ]; then
  pass "the nudge refuses to be the thing that invalidates a valid body"
else
  fail "expected rc=4 with no edit; rc=$RC wrote=$WROTE err='$ERR'"
fi

echo "--- 7b: an ALREADY-invalid body is still nudged (this is not a body fixer)"
# The invariant is non-introduction, not validity. A body that already fails
# must still reach the canonical producer, whose job is to report that failure.
run_nudge open sha778 "no self review here" "$NEITHER"
if [ "$RC" = 0 ] && [ "$WROTE" != 0 ]; then
  pass "an already-failing body is nudged: the verdict belongs to the producer"
else
  fail "expected rc=0 with an edit; rc=$RC wrote=$WROTE err='$ERR'"
fi

# --- 8-11: fail closed on every input it cannot trust ----------------------
echo; echo "--- 8: a closed PR -> rc 1, no write"
run_nudge closed sha888 "$VALID_BODY" "$NEITHER"
if [ "$RC" = 1 ] && [ "$WROTE" = 0 ]; then
  pass "a closed PR is refused"
else
  fail "expected rc=1 with no edit; rc=$RC wrote=$WROTE"
fi

echo "--- 9: the PR read fails -> rc 2, no write"
run_nudge open sha999 "$VALID_BODY" "$NEITHER" STUB_PR_RC=1
if [ "$RC" = 2 ] && [ "$WROTE" = 0 ]; then
  pass "an unreadable PR fails closed"
else
  fail "expected rc=2 with no edit; rc=$RC wrote=$WROTE"
fi

echo "--- 10: the check-runs read fails -> rc 2, no write"
run_nudge open shaaaa "$VALID_BODY" "$NEITHER" STUB_RUNS_RC=1
if [ "$RC" = 2 ] && [ "$WROTE" = 0 ]; then
  pass "an unreadable check-run list fails closed rather than assuming absence"
else
  fail "expected rc=2 with no edit; rc=$RC wrote=$WROTE"
fi

echo "--- 11: a missing validator -> rc 2, no write (the invariant is not skippable)"
run_nudge open shabbb "$VALID_BODY" "$NEITHER" \
  MERGEPATH_NUDGE_VALIDATE_BIN="$TMP/definitely-absent"
if [ "$RC" = 2 ] && [ "$WROTE" = 0 ]; then
  pass "an unavailable validator fails closed instead of skipping the check"
else
  fail "expected rc=2 with no edit; rc=$RC wrote=$WROTE"
fi

echo "--- 12: a failed edit is reported as a failure, not as a nudge"
run_nudge open shaccc "$VALID_BODY" "$NEITHER" STUB_EDIT_RC=1
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q "was not nudged"; then
  pass "a failed write does not report success"
else
  fail "expected rc=2 saying the workflow was not nudged; rc=$RC err='$ERR'"
fi

echo "--- 13: a non-numeric PR argument -> rc 1"
set +e
env PATH="$TMP/bin:$PATH" bash "$SUBJECT" not-a-number owner/repo >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" = 1 ]; then
  pass "a non-numeric PR number is a usage error"
else
  fail "expected rc=1 for a non-numeric PR number; got $RC"
fi

echo
echo "============================================"
echo "test_pr_review_policy_nudge.sh: $PASSED passed, $FAILED failed"
echo "============================================"
[ "$FAILED" -eq 0 ]
