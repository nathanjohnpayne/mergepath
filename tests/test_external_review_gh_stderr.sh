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
  repos/*/commits/*)
    emit '{"sha":"resolvedsha1","commit":{"tree":{"sha":"treeshafixed1"}}}' "" 0 ;;
  repos/*/compare/*)
    emit '{"merge_base_commit":{"sha":"mergebasesha1"}}' "" 0 ;;
  repos/*/pulls/*)
    emit '{"base":{"sha":"basesha1"}}' "" 0 ;;
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

echo
echo "== external_review gh-stderr/#718 tests: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
