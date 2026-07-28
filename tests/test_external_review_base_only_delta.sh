#!/usr/bin/env bash
# tests/test_external_review_base_only_delta.sh
#
# Regression coverage for mergepath#763 — the base-only delta predicate in
# external_review_carryforward.sh.
#
# A fingerprint match proves the PR's net content over its CURRENT changed-path
# set is byte-identical to what a prior affirmative Codex verdict reviewed.
# That constrains the ENDPOINTS but says nothing about the path between them.
# delta_is_base_only() adds the second half: every path whose content differs
# between the reviewed commit and the current head must be base-derived — it
# must not still be part of this PR's own net diff.
#
# Stub discriminator: external_review_fingerprint.sh calls the compare endpoint
# WITH `--jq` (to read .merge_base_commit.sha); the delta predicate calls it
# WITHOUT `--jq` (it reads .files itself). The stub keys on that so a simulated
# delta-compare failure can't be confused for a fingerprint merge-base failure.
#
# Fully offline. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARRYFORWARD="$ROOT/scripts/workflow/external_review_carryforward.sh"
[ -x "$CARRYFORWARD" ] || { echo "missing $CARRYFORWARD" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/external-review-delta-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REPO="test-owner/test-repo"
PR=42
HEAD_SHA="1111111111111111111111111111111111111111"
# Must be hex: the verdict anchor is scanned with [0-9a-f]{7,40}.
CANDIDATE_SHA="2222222222222222222222222222222222222222"

CONFIG="$WORK/review-policy.yml"
cat > "$CONFIG" <<'YAML'
external_review_threshold: 1
external_review_paths: []
codex:
  enabled: true
YAML

# The PR's own net diff touches exactly foo.txt.
FILES_JSON="$WORK/files.json"
printf '[{"filename":"foo.txt","additions":1,"deletions":0}]\n' > "$FILES_JSON"

TREE_JSON="$WORK/tree.json"
printf '{"truncated":false,"tree":[{"path":"foo.txt","type":"blob","mode":"100644","sha":"blobsha1"}]}\n' > "$TREE_JSON"

EMPTY_ARRAY="$WORK/empty.json"
printf '[]\n' > "$EMPTY_ARRAY"

# One affirmative Codex verdict anchored on a commit that is NOT the head, so
# the historical-candidate scan runs (rather than short-circuiting on a
# current-head signal).
COMMENTS_JSON="$WORK/comments.json"
cat > "$COMMENTS_JSON" <<JSON
[{"user":{"login":"chatgpt-codex-connector[bot]"},
  "created_at":"2026-01-01T00:00:00Z",
  "body":"Codex Review: Didn't find any major issues.\n\nReviewed commit: $CANDIDATE_SHA"}]
JSON

GH_STUB="$WORK/gh"
cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
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
emit() {
  if [ -n "$JQEXPR" ]; then printf '%s' "$1" | jq -r "$JQEXPR"; else printf '%s' "$1"; fi
  exit 0
}
case "$PATHARG" in
  repos/*/pulls/*/files)   emit "$(cat "$STUB_FILES_JSON")" ;;
  repos/*/issues/*/comments) emit "$(cat "$STUB_COMMENTS_JSON")" ;;
  repos/*/pulls/*/reviews) emit "$(cat "$STUB_REVIEWS_JSON")" ;;
  repos/*/git/trees/*)     emit "$(cat "$STUB_TREE_JSON")" ;;
  repos/*/commits/*)       emit "{\"sha\":\"$STUB_RESOLVED_SHA\",\"commit\":{\"tree\":{\"sha\":\"treeshafixed1\"}}}" ;;
  repos/*/compare/*)
    # WITH --jq  -> fingerprint's merge-base lookup.
    # WITHOUT    -> the #763 delta predicate.
    if [ -n "$JQEXPR" ]; then
      emit '{"merge_base_commit":{"sha":"mergebasesha1"}}'
    fi
    [ "${STUB_COMPARE_FAIL:-0}" != "1" ] || { echo "${STUB_COMPARE_FAILTEXT:-compare-boom}" >&2; exit 1; }
    emit "$(cat "$STUB_COMPARE_JSON")" ;;
  repos/*/pulls/*)         emit '{"base":{"sha":"basesha1"}}' ;;
  *)                       emit '{}' ;;
esac
STUB
chmod +x "$GH_STUB"

export STUB_FILES_JSON="$FILES_JSON" STUB_TREE_JSON="$TREE_JSON"
export STUB_COMMENTS_JSON="$COMMENTS_JSON" STUB_REVIEWS_JSON="$EMPTY_ARRAY"
export STUB_RESOLVED_SHA="$CANDIDATE_SHA"
export PATH="$WORK:$PATH"
hash -r 2>/dev/null || true

run_cf() {
  OUT=$(bash "$CARRYFORWARD" --repo "$REPO" --pr "$PR" --head "$HEAD_SHA" --config "$CONFIG" 2>"$1") && RC=0 || RC=$?
}

reset_stub_env() { unset STUB_COMPARE_FAIL STUB_COMPARE_FAILTEXT; }

# 1. Base-only delta: the only path that changed since the reviewed commit is
#    NOT part of the PR's net diff, so the clean verdict carries forward.
reset_stub_env
export STUB_COMPARE_JSON="$WORK/compare-base-only.json"
printf '{"files":[{"filename":"vendor/base-only.txt"}]}\n' > "$STUB_COMPARE_JSON"
run_cf "$WORK/d1.stderr"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.carried')" = "true" ] \
   && [ "$(printf '%s' "$OUT" | jq -r '.source_commit')" = "$CANDIDATE_SHA" ]; then
  pass "carry-forward accepted when the delta since the reviewed commit is base-only (#763)"
else
  fail "carry-forward should have been accepted for a base-only delta (rc=$RC out=$OUT)"
fi

# 2. Non-base delta: a path that changed since the reviewed commit is STILL in
#    the PR's own net diff, so its current content was never reviewed.
reset_stub_env
export STUB_COMPARE_JSON="$WORK/compare-offending.json"
printf '{"files":[{"filename":"foo.txt"}]}\n' > "$STUB_COMPARE_JSON"
run_cf "$WORK/d2.stderr"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.carried')" = "false" ] \
   && grep -q "still part of this PR's net diff" "$WORK/d2.stderr"; then
  pass "carry-forward refused when a changed-since-review path is still in the PR's net diff (#763)"
else
  fail "carry-forward should have been refused for a non-base delta (rc=$RC out=$OUT)"
fi

# 3. Fail closed: the delta comparison itself errors.
reset_stub_env
export STUB_COMPARE_JSON="$WORK/compare-base-only.json"
export STUB_COMPARE_FAIL=1 STUB_COMPARE_FAILTEXT="simulated compare failure zzz999"
run_cf "$WORK/d3.stderr"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.carried')" = "false" ] \
   && grep -q "could not compare" "$WORK/d3.stderr"; then
  pass "carry-forward fails closed when the delta comparison errors (#763)"
else
  fail "carry-forward should have failed closed on a compare error (rc=$RC out=$OUT)"
fi

# 4. Fail closed: a truncated (>=300 file) comparison cannot prove base-only.
reset_stub_env
export STUB_COMPARE_JSON="$WORK/compare-truncated.json"
jq -n '{files: [range(0;300) | {filename: ("pad/f\(.).txt")}]}' > "$STUB_COMPARE_JSON"
run_cf "$WORK/d4.stderr"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.carried')" = "false" ] \
   && grep -q "truncated" "$WORK/d4.stderr"; then
  pass "carry-forward fails closed on a truncated comparison (#763)"
else
  fail "carry-forward should have failed closed on a truncated comparison (rc=$RC out=$OUT)"
fi

echo
echo "== external_review base-only delta (#763) tests: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
