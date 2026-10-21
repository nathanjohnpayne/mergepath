#!/usr/bin/env bash
# tests/test_check_mktemp_portability.sh
#
# Unit tests for scripts/ci/check_mktemp_portability. The check is a
# repo-wide grep; tests pivot it onto fixture files in a scratch dir
# via MERGEPATH_MKTEMP_SCAN_ROOT, then assert the violation detection.
#
# The compact-flag form (`mktemp -dt prefix`) is the specific
# regression #286 r2 closes per nathanpayne-codex Phase 4b.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_mktemp_portability"

[[ -x "$CHECK" ]] || { echo "missing or non-executable $CHECK" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/check-mktemp-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Helper: build a fixture file at a relative path under WORKDIR and
# run the check via MERGEPATH_MKTEMP_SCAN_ROOT. Returns the check's
# exit code via the OUT/RC vars.
run_check_on_fixture() {
  local rel="$1" content="$2"
  local dir
  dir="$WORKDIR/$(dirname "$rel")"
  mkdir -p "$dir"
  printf '%s' "$content" > "$WORKDIR/$rel"
  chmod +x "$WORKDIR/$rel"
  set +e
  OUT=$(MERGEPATH_MKTEMP_SCAN_ROOT="$WORKDIR" bash "$CHECK" 2>&1)
  RC=$?
  set -e
}

# Case 1: clean fixture (uses portable mktemp form) → PASS
run_check_on_fixture "clean.sh" '#!/usr/bin/env bash
foo=$(mktemp -d "${TMPDIR:-/tmp}/clean.XXXXXX")
'
if [ "$RC" = "0" ] && grep -q "PASS" <<<"$OUT"; then
  pass "clean fixture (portable form): exits 0 with PASS"
else
  fail "clean fixture: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/clean.sh"

# Case 2: BSD bare-t form → FAIL
run_check_on_fixture "bad-bare-t.sh" '#!/usr/bin/env bash
foo=$(mktemp -t mergepath-bad)
'
if [ "$RC" = "1" ] && grep -q "FAIL" <<<"$OUT"; then
  pass "bare -t form: caught (BSD-incompatible)"
else
  fail "bare -t form: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/bad-bare-t.sh"

# Case 3: BSD -d -t form → FAIL
run_check_on_fixture "bad-d-then-t.sh" '#!/usr/bin/env bash
foo=$(mktemp -d -t mergepath-bad)
'
if [ "$RC" = "1" ] && grep -q "FAIL" <<<"$OUT"; then
  pass "-d -t (separate) form: caught"
else
  fail "-d -t form: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/bad-d-then-t.sh"

# Case 4 (#286 r2): compact -dt form → FAIL. This is the specific
# regression nathanpayne-codex flagged — the prior regex missed it.
run_check_on_fixture "bad-compact-dt.sh" '#!/usr/bin/env bash
foo=$(mktemp -dt mergepath-bad)
'
if [ "$RC" = "1" ] && grep -q "FAIL" <<<"$OUT"; then
  pass "compact -dt form: caught (#286 r2 regression)"
else
  fail "compact -dt form: rc=$RC out=$OUT  (regex did not catch combined -dt)"
fi
rm -f "$WORKDIR/bad-compact-dt.sh"

# Case 5: compact -Pdt form (any leading flags before t) → FAIL
run_check_on_fixture "bad-compact-pdt.sh" '#!/usr/bin/env bash
foo=$(mktemp -Pdt mergepath-bad)
'
if [ "$RC" = "1" ] && grep -q "FAIL" <<<"$OUT"; then
  pass "compact -Pdt form: caught (any flags before t)"
else
  fail "compact -Pdt form: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/bad-compact-pdt.sh"

# Case 6: mktemp -d alone (no -t, no prefix-as-bare-token) → PASS.
# Regression net: don't false-flag `-d` only.
run_check_on_fixture "clean-d-only.sh" '#!/usr/bin/env bash
foo=$(mktemp -d "/tmp/keep.XXXXXX")
'
if [ "$RC" = "0" ] && grep -q "PASS" <<<"$OUT"; then
  pass "-d only with quoted template: passes"
else
  fail "-d only: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/clean-d-only.sh"

# Case 7: comment line referencing `mktemp -t foo` (docs/banner) → PASS.
# The check filters comment lines.
run_check_on_fixture "comment-mention.sh" '#!/usr/bin/env bash
# Never use: mktemp -t legacy-bsd-form
foo=$(mktemp -d "/tmp/safe.XXXXXX")
'
if [ "$RC" = "0" ] && grep -q "PASS" <<<"$OUT"; then
  pass "comment-line mention of -t: not flagged"
else
  fail "comment-line mention: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/comment-mention.sh"

# Case 8 (#286 r3): double-quoted bare-name prefix.
run_check_on_fixture "bad-quoted-bare.sh" '#!/usr/bin/env bash
foo=$(mktemp -t "prefix")
'
if [ "$RC" = "1" ] && grep -q "FAIL" <<<"$OUT"; then
  pass "double-quoted bare prefix: caught (#286 r3)"
else
  fail "double-quoted bare prefix: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/bad-quoted-bare.sh"

# Case 9: single-quoted bare-name prefix.
run_check_on_fixture "bad-squoted-bare.sh" '#!/usr/bin/env bash
foo=$(mktemp -t '"'"'prefix'"'"')
'
if [ "$RC" = "1" ] && grep -q "FAIL" <<<"$OUT"; then
  pass "single-quoted bare prefix: caught"
else
  fail "single-quoted bare prefix: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/bad-squoted-bare.sh"

# Case 10: double-quoted variable expansion prefix.
run_check_on_fixture "bad-quoted-var.sh" '#!/usr/bin/env bash
prefix=foo
foo=$(mktemp -t "$prefix")
'
if [ "$RC" = "1" ] && grep -q "FAIL" <<<"$OUT"; then
  pass "double-quoted variable prefix: caught (#286 r3)"
else
  fail "double-quoted variable prefix: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/bad-quoted-var.sh"

# Case 11: bare variable expansion prefix.
run_check_on_fixture "bad-bare-var.sh" '#!/usr/bin/env bash
prefix=foo
foo=$(mktemp -t $prefix)
'
if [ "$RC" = "1" ] && grep -q "FAIL" <<<"$OUT"; then
  pass "bare variable prefix: caught"
else
  fail "bare variable prefix: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/bad-bare-var.sh"

# Case 12: braced variable expansion prefix.
run_check_on_fixture "bad-braced-var.sh" '#!/usr/bin/env bash
prefix=foo
foo=$(mktemp -t ${prefix})
'
if [ "$RC" = "1" ] && grep -q "FAIL" <<<"$OUT"; then
  pass "braced variable prefix: caught"
else
  fail "braced variable prefix: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/bad-braced-var.sh"

# Case 13: portable quoted template (slashes inside quote) → PASS.
# This is the SHAPE we explicitly do NOT want to flag, even though
# it contains the literal `mktemp -t "..."` substring.
run_check_on_fixture "clean-quoted-template.sh" '#!/usr/bin/env bash
foo=$(mktemp -d "${TMPDIR:-/tmp}/safe.XXXXXX")
'
if [ "$RC" = "0" ] && grep -q "PASS" <<<"$OUT"; then
  pass "portable quoted template (slashes inside quotes): not flagged"
else
  fail "portable quoted template: rc=$RC out=$OUT"
fi
rm -f "$WORKDIR/clean-quoted-template.sh"

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_check_mktemp_portability: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_check_mktemp_portability: PASS ($TOTAL tests)"
exit 0
