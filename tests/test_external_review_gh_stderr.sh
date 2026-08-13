#!/usr/bin/env bash
# tests/test_external_review_gh_stderr.sh
#
# Regression coverage for mergepath#715/#716/#718.
#
# #715/#716: external_review_fingerprint.sh and
# external_review_carryforward.sh captured `gh api ... 2>&1`, merging
# stderr into the value later parsed as JSON with jq — a `gh`
# warning/notice on an otherwise-successful call corrupted the parse.
# Both scripts now route calls through a local gh_api_capture() helper
# that keeps stdout/stderr separate on success and preserves the real
# exit code (with combined text for the error message) on failure.
#
# #718: carryforward.sh's current-head Codex signal check only
# short-circuited when the latest signal was NON-affirmative; an
# affirmative signal still triggered the full historical-candidate scan
# (which re-invokes the fingerprint helper). It now returns early there
# too.
#
# #799: the third member of the same family, and the inverse of #715/#716.
# Those two were "stderr leaking INTO stdout"; this is "an HTTP ERROR BODY
# arriving ON stdout" — which `gh api --jq` really does, with the
# human-readable line on stderr and exit 1. Every `x=$(gh api … --jq … ||
# true); [ -z "$x" ] && fail` site therefore never failed. The scalar reads
# in both scripts now route through scripts/lib/gh-api-scalar.sh, whose
# contract is #831's: an unreadable response reaches the caller ONLY as a
# return status, never as data. Covered below at two levels — the helper's
# own contract (cases 7-16) and the two scripts driven end to end (17-20).
#
# Strategy: stub `gh` via PATH-prepend, table-driven by env vars so one
# stub covers both scripts. Fully offline. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINGERPRINT="$ROOT/scripts/workflow/external_review_fingerprint.sh"
CARRYFORWARD="$ROOT/scripts/workflow/external_review_carryforward.sh"
[ -x "$FINGERPRINT" ] || { echo "missing $FINGERPRINT" >&2; exit 1; }
[ -x "$CARRYFORWARD" ] || { echo "missing $CARRYFORWARD" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/external-review-stderr-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REPO="test-owner/test-repo"
PR=42
HEAD_SHA="1111111111111111111111111111111111111111"

CONFIG="$WORK/review-policy.yml"
cat > "$CONFIG" <<'YAML'
external_review_threshold: 1
external_review_paths: []
codex:
  enabled: true
YAML

# One changed file trips the deliberately-low threshold, so both
# scripts run their full gh-fetching path instead of short-circuiting
# on requires_review=false.
FILES_JSON="$WORK/files.json"
printf '[{"filename":"foo.txt","additions":1,"deletions":0}]\n' > "$FILES_JSON"
TREE_JSON="$WORK/tree.json"
printf '{"truncated":false,"tree":[{"path":"foo.txt","type":"blob","mode":"100644","sha":"blobsha1"}]}\n' > "$TREE_JSON"
EMPTY_ARRAY="$WORK/empty.json"
printf '[]\n' > "$EMPTY_ARRAY"
TREE_CALLS_LOG="$WORK/tree-calls.log"

GH_STUB="$WORK/gh"
cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
# Routes `gh api [--paginate] <path> [--jq EXPR]` by path prefix.
# STUB_<X>_STDERR/_FAIL/_FAILTEXT (X = FILES/COMMENTS/REVIEWS/TREE)
# control per-endpoint stderr chatter or a simulated failure.
[ "${1:-}" = "api" ] || { echo "{}"; exit 0; }
shift
JQEXPR=""; PATHARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --jq) JQEXPR="$2"; shift 2 ;;
    *) [ -n "$PATHARG" ] || PATHARG="$1"; shift ;;
  esac
done
emit() {  # $1=json $2=stderr-text $3=fail(0/1) $4=fail-text
  [ -z "$2" ] || echo "$2" >&2
  [ "$3" != "1" ] || { echo "${4:-boom}" >&2; exit 1; }
  if [ -n "$JQEXPR" ]; then printf '%s' "$1" | jq -r "$JQEXPR"; else printf '%s' "$1"; fi
  exit 0
}
# #799: emit an HTTP failure the way real `gh api --jq` does — error BODY on
# STDOUT with the --jq filter NOT applied, human-readable line on stderr. $1
# is the exit status, so the `0` variant models the pathological case where
# the payload arrives with a success status and only the shape predicate can
# catch it. This is the fixture correction #799 insists on: a stub that puts
# the body on stderr proves nothing, because the caller's 2>/dev/null then
# really does leave the variable empty and every dead guard fires.
emit_http_error() {  # $1=exit-status $2=body
  printf '%s' "$2"
  echo "gh: Not Found (HTTP 404)" >&2
  exit "$1"
}
case "$PATHARG" in
  repos/*/pulls/*/files)
    emit "$(cat "$STUB_FILES_JSON")" "${STUB_FILES_STDERR:-}" "${STUB_FILES_FAIL:-0}" "${STUB_FILES_FAILTEXT:-files-boom}" ;;
  repos/*/issues/*/comments)
    emit "$(cat "$STUB_COMMENTS_JSON")" "${STUB_COMMENTS_STDERR:-}" "${STUB_COMMENTS_FAIL:-0}" "${STUB_COMMENTS_FAILTEXT:-comments-boom}" ;;
  repos/*/pulls/*/reviews)
    emit "$(cat "$STUB_REVIEWS_JSON")" "${STUB_REVIEWS_STDERR:-}" "${STUB_REVIEWS_FAIL:-0}" "${STUB_REVIEWS_FAILTEXT:-reviews-boom}" ;;
  repos/*/git/trees/*)
    echo "tree" >> "$TREE_CALLS_LOG"
    emit "$(cat "$STUB_TREE_JSON")" "${STUB_TREE_STDERR:-}" "${STUB_TREE_FAIL:-0}" "${STUB_TREE_FAILTEXT:-tree-boom}" ;;
  # #799: the three sha-shaped fields below are LOWERCASE HEX, not prose. They
  # used to read `resolvedsha1` / `mergebasesha1` / `basesha1`, which no git
  # implementation can emit — the same unreality as the stderr-vs-stdout stub
  # #799 calls out, and it would now be rejected by `--shape sha` for a reason
  # that has nothing to do with the behaviour under test. `treeshafixed1` is
  # left alone: it flows through gh_api_capture + jq, never through a shape
  # predicate, and its literal value is what test 6's call-count assertion
  # keys the tree cache on.
  repos/*/commits/*)
    # #799: fail ONE named commit read, so a test can break the newer-signal
    # resolution while the candidate resolution still succeeds.
    if [ -n "${STUB_COMMIT_ERR_SHA:-}" ] && [ "${PATHARG##*/}" = "$STUB_COMMIT_ERR_SHA" ]; then
      emit_http_error "${STUB_COMMIT_ERR_RC:-1}" '{"message":"No commit found for SHA","status":"422"}'
    fi
    emit '{"sha":"c0ffee01","commit":{"tree":{"sha":"treeshafixed1"}}}' "" 0 ;;
  repos/*/compare/*)
    emit '{"merge_base_commit":{"sha":"de4dbee5"}}' "" 0 ;;
  repos/*/pulls/*)
    if [ -n "${STUB_PRMETA_ERR:-}" ]; then
      emit_http_error "${STUB_PRMETA_ERR_RC:-1}" '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
    fi
    emit '{"base":{"sha":"ba5e5ba0"}}' "" 0 ;;
  *)
    emit '{}' "" 0 ;;
esac
STUB
chmod +x "$GH_STUB"
export TREE_CALLS_LOG
export STUB_FILES_JSON="$FILES_JSON" STUB_TREE_JSON="$TREE_JSON"
export STUB_COMMENTS_JSON="$EMPTY_ARRAY" STUB_REVIEWS_JSON="$EMPTY_ARRAY"
export PATH="$WORK:$PATH"
hash -r 2>/dev/null || true

reset_stub_env() {
  unset STUB_FILES_STDERR STUB_FILES_FAIL STUB_FILES_FAILTEXT
  unset STUB_TREE_STDERR STUB_TREE_FAIL STUB_TREE_FAILTEXT
  unset STUB_COMMENTS_STDERR STUB_COMMENTS_FAIL STUB_COMMENTS_FAILTEXT
  unset STUB_REVIEWS_STDERR STUB_REVIEWS_FAIL STUB_REVIEWS_FAILTEXT
  unset STUB_PRMETA_ERR STUB_PRMETA_ERR_RC STUB_COMMIT_ERR_SHA STUB_COMMIT_ERR_RC
  export STUB_COMMENTS_JSON="$EMPTY_ARRAY" STUB_REVIEWS_JSON="$EMPTY_ARRAY"
  rm -f "$TREE_CALLS_LOG"
}

run_fp() { OUT=$(bash "$FINGERPRINT" --repo "$REPO" --pr "$PR" --ref "$HEAD_SHA" --config "$CONFIG" 2>"$1") && RC=0 || RC=$?; }
run_cf() { OUT=$(bash "$CARRYFORWARD" --repo "$REPO" --pr "$PR" --head "$HEAD_SHA" --config "$CONFIG" 2>"$1") && RC=0 || RC=$?; }

# 1. fingerprint.sh: stderr noise on the files AND tree fetches must not
#    corrupt the jq parse (#715).
reset_stub_env
export STUB_FILES_STDERR="npm warn config: some unrelated deprecation notice"
export STUB_TREE_STDERR="gh: a non-fatal informational notice on stderr"
run_fp "$WORK/fp1.stderr"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.requires_review')" = "true" ] \
   && [ -n "$(printf '%s' "$OUT" | jq -r '.fingerprint')" ]; then
  pass "external_review_fingerprint.sh parses JSON cleanly despite stderr noise on the files and tree fetches (#715)"
else
  fail "external_review_fingerprint.sh broke on stderr noise (rc=$RC out=$OUT)"
fi

# 2. fingerprint.sh: a REAL tree-fetch failure still fails closed and
#    surfaces the error text (not swallowed).
reset_stub_env
export STUB_TREE_FAIL=1 STUB_TREE_FAILTEXT="simulated tree fetch failure xyz123"
run_fp "$WORK/fp2.stderr"
if [ "$RC" -ne 0 ] && grep -q "simulated tree fetch failure xyz123" "$WORK/fp2.stderr"; then
  pass "external_review_fingerprint.sh still fails closed on a real tree-fetch error and surfaces the error text"
else
  fail "external_review_fingerprint.sh did not fail closed as expected (rc=$RC)"
fi

# 3. fingerprint.sh: a REAL files-fetch failure still fails closed.
reset_stub_env
export STUB_FILES_FAIL=1 STUB_FILES_FAILTEXT="simulated files fetch failure abc789"
run_fp "$WORK/fp3.stderr"
if [ "$RC" -ne 0 ] && grep -q "simulated files fetch failure abc789" "$WORK/fp3.stderr"; then
  pass "external_review_fingerprint.sh still fails closed on a real files-fetch error and surfaces the error text"
else
  fail "external_review_fingerprint.sh did not fail closed on files-fetch error (rc=$RC)"
fi

# 4. carryforward.sh: stderr noise on files/comments/reviews/tree fetches
#    must not corrupt any jq parse along the way (#716).
reset_stub_env
export STUB_FILES_STDERR="notice: files endpoint chatter"
export STUB_COMMENTS_STDERR="notice: comments endpoint chatter"
export STUB_REVIEWS_STDERR="notice: reviews endpoint chatter"
export STUB_TREE_STDERR="notice: tree endpoint chatter"
run_cf "$WORK/cf1.stderr"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.carried')" = "false" ]; then
  pass "external_review_carryforward.sh parses JSON cleanly despite stderr noise on all four fetches (#716)"
else
  fail "external_review_carryforward.sh broke on stderr noise (rc=$RC out=$OUT)"
fi

# 5. carryforward.sh: a REAL comments-fetch failure still fails closed.
reset_stub_env
export STUB_COMMENTS_FAIL=1 STUB_COMMENTS_FAILTEXT="simulated comments fetch failure def456"
run_cf "$WORK/cf2.stderr"
if [ "$RC" -ne 0 ] && grep -q "simulated comments fetch failure def456" "$WORK/cf2.stderr"; then
  pass "external_review_carryforward.sh still fails closed on a real comments-fetch error and surfaces the error text"
else
  fail "external_review_carryforward.sh did not fail closed on comments-fetch error (rc=$RC)"
fi

# 6. carryforward.sh (#718): an affirmative current-head Codex verdict must
#    short-circuit — no re-invocation of the fingerprint helper (no extra
#    tree fetches) for the historical-candidate scan.
reset_stub_env
AFFIRMATIVE_COMMENTS="$WORK/affirmative-comments.json"
cat > "$AFFIRMATIVE_COMMENTS" <<JSON
[{"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-01-01T00:00:00Z","body":"Codex Review: Didn't find any major issues. \n\nReviewed commit: $HEAD_SHA"}]
JSON
export STUB_COMMENTS_JSON="$AFFIRMATIVE_COMMENTS"
run_cf "$WORK/cf3.stderr"
TREE_CALL_COUNT=$(wc -l < "$TREE_CALLS_LOG" 2>/dev/null | tr -d ' '); TREE_CALL_COUNT=${TREE_CALL_COUNT:-0}
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.carried')" = "false" ] \
   && printf '%s' "$OUT" | jq -e '.reason | test("already affirmative")' >/dev/null \
   && [ "$TREE_CALL_COUNT" -eq 2 ]; then
  pass "external_review_carryforward.sh returns early on an affirmative current-head signal, no extra tree fetches (#718)"
else
  fail "external_review_carryforward.sh did not short-circuit on an affirmative signal (rc=$RC out=$OUT tree_calls=$TREE_CALL_COUNT)"
fi

# ===========================================================================
# #799 — gh api --jq writes HTTP error bodies to STDOUT
# ===========================================================================
#
# 7-16 pin scripts/lib/gh-api-scalar.sh's own contract; 17-20 drive the two
# scripts end to end through it. The unit-level stub is separate from the
# shared one above so it can answer ANY endpoint with one canned outcome.

SCALAR_LIB="$ROOT/scripts/lib/gh-api-scalar.sh"
[ -r "$SCALAR_LIB" ] || { echo "missing $SCALAR_LIB" >&2; exit 1; }

SCALAR_BIN="$WORK/scalar-bin"
mkdir -p "$SCALAR_BIN"
cat > "$SCALAR_BIN/gh" <<'STUB'
#!/usr/bin/env bash
# One canned outcome per invocation, selected by S799_MODE:
#   ok    — the value in S799_VALUE, exit 0 (a successful read)
#   err1  — error body on STDOUT + human line on stderr, exit 1 (REAL gh)
#   err0  — error body on STDOUT, exit 0 (the pathological variant: a payload
#           that reaches the caller with a SUCCESS status, which only a shape
#           predicate can catch)
#   empty — nothing at all, exit 0 (a genuinely absent/empty field)
case "${S799_MODE:-ok}" in
  ok)    printf '%s' "${S799_VALUE-c0ffeeba5e}" ; exit 0 ;;
  err1)  printf '%s' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
         echo "gh: Not Found (HTTP 404)" >&2 ; exit 1 ;;
  err0)  printf '%s' '{"message":"Server Error","status":"500"}' ; exit 0 ;;
  empty) exit 0 ;;
esac
echo "unexpected S799_MODE=${S799_MODE:-}" >&2 ; exit 99
STUB
chmod +x "$SCALAR_BIN/gh"

# Run one gh_api_scalar call in a child shell with the unit stub in front of
# PATH. Prints the captured stdout; sets SC_RC and writes stderr to $2.
scalar_call() {  # $1=S799_MODE $2=stderr-file ; rest = gh_api_scalar args
  local mode="$1" errfile="$2"; shift 2
  SC_OUT=$(
    PATH="$SCALAR_BIN:$PATH" S799_MODE="$mode" S799_VALUE="${S799_VALUE:-c0ffeeba5e}" \
    bash -c '
      . "$1"; shift
      gh_api_scalar "$@"
    ' _ "$SCALAR_LIB" "$@" 2>"$errfile"
  ) && SC_RC=0 || SC_RC=$?
}

# 7. THE CONTRACT. A real gh failure (body on stdout, exit 1) must reach the
#    caller as rc 3 with NOTHING on stdout — that is what makes the emptiness
#    inference at all fifteen #799 sites honest again.
scalar_call err1 "$WORK/s7.err" --shape sha "PR base sha" "repos/o/r/pulls/1" --jq .base.sha
if [ "$SC_RC" -eq 3 ] && [ -z "$SC_OUT" ] && grep -q 'could not read PR base sha' "$WORK/s7.err"; then
  pass "#799: gh_api_scalar turns an HTTP error body on stdout into rc 3 with empty stdout"
else
  fail "#799: gh_api_scalar leaked a failed read (rc=$SC_RC out='$SC_OUT')"
fi

# 8. The "before" half, so case 7 is not asserting against a stub that could
#    never have shown the bug: the SHAPE #799 describes really does hand the
#    caller a non-empty JSON blob with the guard passing.
LEGACY_OUT=$(PATH="$SCALAR_BIN:$PATH" S799_MODE=err1 \
  bash -c 'x="$(gh api repos/o/r/pulls/1 --jq ".base.sha" 2>/dev/null || true)"; printf "%s" "$x"')
if [ -n "$LEGACY_OUT" ] && printf '%s' "$LEGACY_OUT" | grep -q '"message"'; then
  pass "#799: the pre-fix shape really does capture the error body (guard-defeating input confirmed: ${#LEGACY_OUT} bytes)"
else
  fail "#799: the legacy-shape control did not reproduce the defect (out='$LEGACY_OUT')"
fi

# 9. Error body arriving with a SUCCESS status. The status check cannot see
#    this one; --shape is the only thing standing between the blob and a
#    caller that will treat it as a sha.
scalar_call err0 "$WORK/s9.err" --shape sha "PR base sha" "repos/o/r/pulls/1" --jq .base.sha
if [ "$SC_RC" -eq 3 ] && [ -z "$SC_OUT" ] && grep -q 'not a valid sha' "$WORK/s9.err"; then
  pass "#799: an error body delivered with exit 0 is rejected by --shape sha (rc 3, empty stdout)"
else
  fail "#799: --shape sha admitted an exit-0 error body (rc=$SC_RC out='$SC_OUT')"
fi

# 10. The honest limit of the status check, recorded rather than glossed:
#     WITHOUT a shape, an exit-0 error body passes through. This is why
#     --shape exists and why every sha/login/timestamp site names one.
scalar_call err0 "$WORK/s10.err" "PR body" "repos/o/r/pulls/1" --jq '.body // ""'
if [ "$SC_RC" -eq 0 ] && printf '%s' "$SC_OUT" | grep -q '"message"'; then
  pass "#799: --shape any passes an exit-0 payload through (documents why shaped sites must name a shape)"
else
  fail "#799: unexpected --shape any behaviour (rc=$SC_RC out='$SC_OUT')"
fi

# 11. An EMPTY successful read is not a failure. The whole point is that the
#     two are distinguishable, which needs this direction asserted too.
scalar_call empty "$WORK/s11.err" "PR body" "repos/o/r/pulls/1" --jq '.body // ""'
if [ "$SC_RC" -eq 0 ] && [ -z "$SC_OUT" ]; then
  pass "#799: a genuinely empty response is rc 0 with empty stdout, not a failure"
else
  fail "#799: an empty successful read was misreported (rc=$SC_RC out='$SC_OUT')"
fi

# 12. A good value survives unchanged.
S799_VALUE="1234567890abcdef1234567890abcdef12345678" \
  scalar_call ok "$WORK/s12.err" --shape sha "head sha" "repos/o/r/pulls/1" --jq .head.sha
if [ "$SC_RC" -eq 0 ] && [ "$SC_OUT" = "1234567890abcdef1234567890abcdef12345678" ]; then
  pass "#799: a valid 40-hex sha passes through byte-identical"
else
  fail "#799: a valid sha was mangled (rc=$SC_RC out='$SC_OUT')"
fi

# 13. An unknown --shape must fail closed and must NOT spend a request: a typo
#     turning into "no checking at all" would silently reopen the class.
SC_OUT=$(PATH="/nonexistent-so-gh-is-unavailable:$PATH" bash -c '
  . "$1"; gh_api_scalar --shape shaa "x" "repos/o/r/pulls/1" --jq .base.sha
' _ "$SCALAR_LIB" 2>"$WORK/s13.err") && SC_RC=0 || SC_RC=$?
if [ "$SC_RC" -eq 3 ] && [ -z "$SC_OUT" ] && grep -q 'unknown --shape shaa' "$WORK/s13.err"; then
  pass "#799: an unrecognised --shape fails closed before any request is made"
else
  fail "#799: an unrecognised --shape did not fail closed (rc=$SC_RC out='$SC_OUT')"
fi

# 14-16. The predicates themselves, as accept/reject tables. Driven directly
#     rather than through gh_api_scalar so a failure names the predicate.
predicate_table() {  # $1=fn  $2=space-separated accepts  $3=space-separated rejects
  local fn="$1" accepts="$2" rejects="$3" v bad=0
  for v in $accepts; do
    bash -c '. "$1"; "$2" "$3"' _ "$SCALAR_LIB" "$fn" "$v" \
      || { echo "  $fn REJECTS '$v', which it must accept" >&2; bad=$((bad + 1)); }
  done
  for v in $rejects; do
    if bash -c '. "$1"; "$2" "$3"' _ "$SCALAR_LIB" "$fn" "$v"; then
      echo "  $fn ACCEPTS '$v', which it must not" >&2; bad=$((bad + 1))
    fi
  done
  return "$bad"
}

# The rejects include the exact leading fragment of a gh error body, which is
# the payload the whole issue is about.
if predicate_table looks_like_sha \
     "abc123 def456 1234567890abcdef1234567890abcdef12345678 aaaa1111222233334444555566667777888899990000aaaabbbbccccddddeeee" \
     '{"message":"Not"} null NULL 1234567890ABCDEF abc ghijkl 12345678901234567890123456789012345678901234567890123456789012345'; then
  pass "#799: looks_like_sha accepts hex object names and rejects error bodies, null, uppercase and out-of-range lengths"
else
  fail "#799: looks_like_sha table mismatch"
fi

if predicate_table looks_like_login \
     "nathanjohnpayne nathanpayne-claude a A1 dependabot" \
     '{"message":"Not"} null -leading trailing- double--hyphen chatgpt-codex-connector[bot] aaaaaaaaaabbbbbbbbbbccccccccccddddddddddX'; then
  pass "#799: looks_like_login accepts GitHub account names and rejects error bodies, null and malformed hyphenation"
else
  fail "#799: looks_like_login table mismatch"
fi

if predicate_table looks_like_timestamp \
     "2026-07-29T10:00:00Z 1999-01-01T00:00:00Z" \
     '{"message":"Not"} null 2026-07-29T10:00:00 2026-07-29 2026-07-29T10:00:00.000Z'; then
  pass "#799: looks_like_timestamp accepts GitHub instants and rejects error bodies and near-misses"
else
  fail "#799: looks_like_timestamp table mismatch"
fi

# 17. END TO END — fingerprint.sh's PR base sha read, the highest-severity row
#     in #799's table. The blob used to be interpolated into the compare URL
#     on the very next line and then hashed into the fingerprint that decides
#     whether a prior external-review clearance carries to a new head (#705).
reset_stub_env
export STUB_PRMETA_ERR=1 STUB_PRMETA_ERR_RC=1
run_fp "$WORK/fp799a.stderr"
if [ "$RC" -eq 2 ] && grep -q 'failed to resolve PR base sha' "$WORK/fp799a.stderr"; then
  pass "#799: external_review_fingerprint.sh fails closed when the PR-metadata read returns an error body on stdout (exit 1)"
else
  fail "#799: fingerprint did not fail closed on an error-body PR-metadata read (rc=$RC out=$OUT)"
fi

# 18. Same read, exit 0. The status check is blind here; --shape sha is what
#     keeps the blob out of the fingerprint.
reset_stub_env
export STUB_PRMETA_ERR=1 STUB_PRMETA_ERR_RC=0
run_fp "$WORK/fp799b.stderr"
if [ "$RC" -eq 2 ] && grep -q 'failed to resolve PR base sha' "$WORK/fp799b.stderr"; then
  pass "#799: external_review_fingerprint.sh fails closed on an error body delivered with exit 0 (shape predicate)"
else
  fail "#799: fingerprint admitted an exit-0 error body as a base sha (rc=$RC out=$OUT)"
fi

# 19-20. END TO END — carryforward.sh's newer-signal resolution, the guard its
#     own comment calls "a small, safety-critical, machine-generated set where
#     failing closed is right". It was not failing closed: an unreadable read
#     left the error body in signal_resolved, the `[ -z ]` test passed, and
#     carry-forward proceeded past a newer non-affirmative Codex signal.
CF799_COMMENTS="$WORK/cf799-comments.json"
CF799_REVIEWS="$WORK/cf799-reviews.json"
CF799_SIGNAL_SHA="cccccccccccccccccccccccccccccccccccccccc"
cat > "$CF799_COMMENTS" <<JSON
[{"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-01-01T00:00:00Z","body":"Codex Review: Didn't find any major issues.\n\nReviewed commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]
JSON
cat > "$CF799_REVIEWS" <<JSON
[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"2026-02-01T00:00:00Z","commit_id":"$CF799_SIGNAL_SHA"}]
JSON

for cf_rc in 1 0; do
  reset_stub_env
  export STUB_COMMENTS_JSON="$CF799_COMMENTS" STUB_REVIEWS_JSON="$CF799_REVIEWS"
  export STUB_COMMIT_ERR_SHA="$CF799_SIGNAL_SHA" STUB_COMMIT_ERR_RC="$cf_rc"
  run_cf "$WORK/cf799-$cf_rc.stderr"
  if [ "$RC" -eq 2 ] && grep -q 'references unresolvable commit' "$WORK/cf799-$cf_rc.stderr"; then
    pass "#799: external_review_carryforward.sh refuses carry-forward when a newer signal's commit read returns an error body on stdout (exit $cf_rc)"
  else
    fail "#799: carryforward did not refuse on an error-body commit read, exit $cf_rc (rc=$RC out=$OUT)"
  fi
done
reset_stub_env

echo
echo "== external_review gh-stderr/#718/#799 tests: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
