#!/usr/bin/env bash
# tests/test_external_review_rename_protection.sh
#
# Regression coverage for mergepath#763 — protected-path matching must consider
# BOTH sides of a rename.
#
# GitHub's PR files API reports a rename's DESTINATION in `.filename` and its
# SOURCE in `.previous_filename`. external_review_fingerprint.sh previously read
# only `.filename`, so a PR that MOVED a protected file (for example
# `.github/workflows/foo.yml`) to an unprotected path did not trip
# protected-path matching: the protected path disappeared from the branch and
# nothing required external review. Both sides are now emitted everywhere the
# changed-path set is derived.
#
# Fully offline — the threshold is set high enough that ONLY protected-path
# matching can flip requires_review, so these cases cannot pass by accident via
# the line-count path. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINGERPRINT="$ROOT/scripts/workflow/external_review_fingerprint.sh"
[ -x "$FINGERPRINT" ] || { echo "missing $FINGERPRINT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/external-review-rename-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REPO="test-owner/test-repo"
PR=7
HEAD_SHA="1111111111111111111111111111111111111111"

# High threshold: only protected-path matching can set requires_review here.
CONFIG="$WORK/review-policy.yml"
cat > "$CONFIG" <<'YAML'
external_review_threshold: 100000
external_review_paths:
  - ".github/**"
codex:
  enabled: true
YAML

TREE_JSON="$WORK/tree.json"
printf '{"truncated":false,"tree":[{"path":"docs/moved.yml","type":"blob","mode":"100644","sha":"blob1"}]}\n' > "$TREE_JSON"

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
  repos/*/git/trees/*) emit "$(cat "$STUB_TREE_JSON")" ;;
  repos/*/commits/*)   emit '{"sha":"aaaa111122223333444455556666777788889999","commit":{"tree":{"sha":"t1"}}}' ;;
  repos/*/compare/*)   emit '{"merge_base_commit":{"sha":"bbbb1111222233334444555566667777888899 99"}}' ;;
  repos/*/pulls/*)     emit '{"base":{"sha":"cccc111122223333444455556666777788889999"}}' ;;
  *)                   emit '{}' ;;
esac
STUB
chmod +x "$GH_STUB"
export STUB_TREE_JSON="$TREE_JSON"
export PATH="$WORK:$PATH"
hash -r 2>/dev/null || true

run_fp() {
  OUT=$(bash "$FINGERPRINT" --repo "$REPO" --pr "$PR" --ref "$HEAD_SHA" \
        --config "$CONFIG" --files-json "$1" 2>"$WORK/err.txt") && RC=0 || RC=$?
}

# 1. THE BYPASS: a protected file renamed OUT to an unprotected path. Only
#    .previous_filename carries the protected path.
FILES_RENAME="$WORK/files-rename.json"
cat > "$FILES_RENAME" <<'JSON'
[{"filename":"docs/moved.yml","previous_filename":".github/workflows/foo.yml","additions":1,"deletions":1,"status":"renamed"}]
JSON
run_fp "$FILES_RENAME"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.requires_review')" = "true" ]; then
  pass "renaming a protected file to an unprotected path still requires external review (#763)"
else
  fail "protected-path rename bypassed external review (rc=$RC out=$OUT)"
fi

# 2. The protected source path is reported as a matched protected path, not just
#    counted — so the reason string names what actually tripped it.
if printf '%s' "$OUT" | jq -e '.protected_paths | index(".github/workflows/foo.yml")' >/dev/null 2>&1; then
  pass "the pre-rename protected path appears in protected_paths (#763)"
else
  fail "protected_paths did not include the pre-rename path: $(printf '%s' "$OUT" | jq -c '.protected_paths')"
fi

# 3. CONTROL: an ordinary rename touching no protected path must NOT require
#    review — proves the fix did not simply make every rename protected.
FILES_PLAIN="$WORK/files-plain.json"
cat > "$FILES_PLAIN" <<'JSON'
[{"filename":"docs/moved.yml","previous_filename":"docs/old.yml","additions":1,"deletions":1,"status":"renamed"}]
JSON
run_fp "$FILES_PLAIN"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.requires_review')" = "false" ]; then
  pass "an unprotected rename still does not require external review (#763 control)"
else
  fail "unprotected rename wrongly required review (rc=$RC out=$OUT)"
fi

# 4. A rename INTO a protected path is caught via .filename (pre-existing
#    behaviour) — pinned so the fix cannot regress the forward direction.
FILES_INTO="$WORK/files-into.json"
cat > "$FILES_INTO" <<'JSON'
[{"filename":".github/workflows/new.yml","previous_filename":"docs/old.yml","additions":1,"deletions":1,"status":"renamed"}]
JSON
run_fp "$FILES_INTO"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.requires_review')" = "true" ]; then
  pass "renaming INTO a protected path still requires external review (#763 control)"
else
  fail "rename into a protected path did not require review (rc=$RC out=$OUT)"
fi

echo
echo "== external_review rename protection (#763) tests: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
