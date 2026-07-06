#!/usr/bin/env bash
# tests/test_check_template_substitution_wrapper.sh
#
# Unit tests for the hub-vs-consumer disambiguation logic in
# scripts/ci/check_template_substitution (the WRAPPER, not the lib it
# guards — the lib's own contract is covered by
# tests/test_template_substitution.sh).
#
# The wrapper resolves REPO_ROOT relative to its own on-disk location,
# so each case builds a throwaway repo layout under a scratch dir,
# copies the real check into <scratch>/scripts/ci/, and toggles the
# presence of three markers:
#
#   scripts/sync-to-downstream.sh   HUB-ONLY (never propagated)
#   .mergepath-sync.yml             HUB-ONLY manifest (never propagated)
#   scripts/lib/template-substitution.sh  PROPAGATED lib
#   tests/test_template_substitution.sh   PROPAGATED test (stubbed here)
#
# Regression coverage:
#   * #703  — hub that lost its manifest must FAIL (fail closed).
#   * #710  — that fail-closed must be keyed on the HUB-ONLY sync-script
#             marker, NOT the propagated lib, so it never fires on a
#             consumer checkout whose normal state is
#             "lib present + manifest absent".

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_template_substitution"

[[ -x "$CHECK" ]] || { echo "missing or non-executable $CHECK" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/check-templsub-wrapper.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a fixture repo layout under a fresh subdir of WORKDIR with the
# requested markers present, then run the copied check. Sets OUT/RC.
#
# Args: want_sync want_manifest want_lib  (each "1" to include, else omit)
# The stubbed test script always exits 0 with a recognizable marker, so
# a green run proves the wrapper reached "run the test", not that it
# short-circuited.
run_wrapper() {
  local want_sync="$1" want_manifest="$2" want_lib="$3"
  local repo
  repo="$(mktemp -d "$WORKDIR/repo.XXXXXX")"
  mkdir -p "$repo/scripts/ci" "$repo/scripts/lib" "$repo/tests"
  cp "$CHECK" "$repo/scripts/ci/check_template_substitution"
  chmod +x "$repo/scripts/ci/check_template_substitution"

  cat > "$repo/tests/test_template_substitution.sh" <<'STUB'
#!/usr/bin/env bash
echo "STUB_TEST_RAN"
exit 0
STUB
  chmod +x "$repo/tests/test_template_substitution.sh"

  [ "$want_sync" = "1" ] && printf '#!/usr/bin/env bash\n' > "$repo/scripts/sync-to-downstream.sh"
  [ "$want_manifest" = "1" ] && printf 'version: 1\n' > "$repo/.mergepath-sync.yml"
  [ "$want_lib" = "1" ] && printf '#!/usr/bin/env bash\n' > "$repo/scripts/lib/template-substitution.sh"

  set +e
  OUT=$(bash "$repo/scripts/ci/check_template_substitution" 2>&1)
  RC=$?
  set -e
}

# Case 1: mergepath (hub) state — sync script + manifest + lib all
# present → run the test and pass (exit 0).
run_wrapper 1 1 1
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "STUB_TEST_RAN"; then
  pass "hub state (sync+manifest+lib): runs the test, exits 0"
else
  fail "hub state: expected rc=0 + STUB_TEST_RAN, got rc=$RC out=$OUT"
fi

# Case 2 (#710): consumer state — lib + test present, NO sync script,
# NO manifest → must run the propagated test (exit 0), NOT fail-close.
run_wrapper 0 0 1
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "STUB_TEST_RAN"; then
  pass "consumer state (lib present, no sync/manifest): runs the test, exits 0"
else
  fail "consumer state: expected rc=0 + STUB_TEST_RAN (must NOT fail-close), got rc=$RC out=$OUT"
fi

# Case 3 (#703): hub lost its manifest — sync script present, manifest
# ABSENT → FAIL exit 1 (fail closed on the hub marker).
run_wrapper 1 0 1
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "FAIL:"; then
  pass "hub-lost-manifest (sync present, manifest absent): fails closed exit 1"
else
  fail "hub-lost-manifest: expected rc=1 + FAIL (fail closed), got rc=$RC out=$OUT"
fi

# Case 4: hub lost its lib — manifest present, lib absent → FAIL exit 1
# (existing lib-missing + manifest-present branch, #321).
run_wrapper 1 1 0
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "FAIL:"; then
  pass "hub-lost-lib (manifest present, lib absent): fails closed exit 1"
else
  fail "hub-lost-lib: expected rc=1 + FAIL, got rc=$RC out=$OUT"
fi

# Case 5: consumer that received the wrapper but not the lib — lib
# absent AND manifest absent AND no sync script → SKIP exit 0.
run_wrapper 0 0 0
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "check_template_substitution: SKIP"; then
  pass "consumer-no-lib (all markers absent): skipped, exit 0"
else
  fail "consumer-no-lib: expected rc=0 + skip, got rc=$RC out=$OUT"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -gt 0 ]; then
  echo "test_check_template_substitution_wrapper: FAIL ($FAIL/$TOTAL failed)"
  exit 1
fi
echo "test_check_template_substitution_wrapper: PASS ($TOTAL tests)"
exit 0
