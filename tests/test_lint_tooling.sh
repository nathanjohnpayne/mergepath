#!/usr/bin/env bash
# tests/test_lint_tooling.sh
#
# Unit tests for scripts/lib/lint-tooling.sh — the optional-lint-tooling
# visibility helper (#588). Exercises BOTH the present-shellcheck and
# missing-shellcheck paths, plus the CI-strict vs warn-only decision and the
# MERGEPATH_REQUIRE_SHELLCHECK override. Hermetic: shellcheck presence is
# simulated with a controlled PATH (a fake shellcheck for the "present" case,
# a bin dir without one for the "missing" case), and CI / override are set
# per case so the result does not depend on the ambient environment.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/lint-tooling.sh"
[ -f "$LIB" ] || { echo "missing required lib: $LIB" >&2; exit 1; }
# shellcheck source=../scripts/lib/lint-tooling.sh
. "$LIB"

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lint-tooling-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Two controlled bin dirs: HAS_SC has a fake shellcheck, NO_SC does not. Both
# carry jq/awk so lint_tooling_report can run under the overridden PATH.
HAS_SC="$WORK/has-sc"; NO_SC="$WORK/no-sc"
mkdir -p "$HAS_SC" "$NO_SC"
for d in "$HAS_SC" "$NO_SC"; do
  ln -s "$(command -v jq)"   "$d/jq"
  ln -s "$(command -v awk)"  "$d/awk"
  ln -s "$(command -v env)"  "$d/env"
  ln -s "$(command -v bash)" "$d/bash"
done
cat > "$HAS_SC/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.0.0-fake\n'
  exit 0
fi
exit 0
SH
chmod +x "$HAS_SC/shellcheck"

# ===========================================================================
echo "lint_tooling_strict — strict/warn decision"
# ===========================================================================
chk_strict() { # chk_strict <label> <want> <env-setup...>
  local label="$1" want="$2"; shift 2
  local got; got="$(env "$@" bash -c '. "'"$LIB"'"; lint_tooling_strict')"
  [ "$got" = "$want" ] && pass "$label -> $got" || fail "$label -> $got (want $want)"
}
chk_strict "CI=true, no override"        true  -u MERGEPATH_REQUIRE_SHELLCHECK CI=true
chk_strict "CI unset, no override"       false -u CI -u MERGEPATH_REQUIRE_SHELLCHECK
chk_strict "CI=false"                    false -u MERGEPATH_REQUIRE_SHELLCHECK CI=false
chk_strict "override=1 beats CI unset"   true  -u CI MERGEPATH_REQUIRE_SHELLCHECK=1
chk_strict "override=0 beats CI=true"    false CI=true MERGEPATH_REQUIRE_SHELLCHECK=0
chk_strict "override=true"               true  -u CI MERGEPATH_REQUIRE_SHELLCHECK=true
chk_strict "override=no"                 false CI=true MERGEPATH_REQUIRE_SHELLCHECK=no

# ===========================================================================
echo "lint_tooling_require_shellcheck — present vs missing"
# ===========================================================================
# These capture an intentionally non-zero rc from the helper, so errexit is
# off for the remaining assertion blocks (each checks rc explicitly).
set +e
# Present: silent success regardless of strictness.
out="$( (export PATH="$HAS_SC"; CI=true lint_tooling_require_shellcheck) 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then
  pass "shellcheck present -> rc 0, no output (even in CI)"
else fail "shellcheck present (rc=$rc, out=[$out])"; fi

# Missing + local (no CI, no override): WARN, but returns 0 so local runs pass.
out="$( (export PATH="$NO_SC"; unset CI MERGEPATH_REQUIRE_SHELLCHECK; lint_tooling_require_shellcheck) 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "WARN" && printf '%s' "$out" | grep -q "shellcheck"; then
  pass "shellcheck missing + local -> rc 0 with loud WARN"
else fail "shellcheck missing local (rc=$rc, out=[$out])"; fi

# Missing + CI: hard FAIL (rc 1).
out="$( (export PATH="$NO_SC"; unset MERGEPATH_REQUIRE_SHELLCHECK; CI=true lint_tooling_require_shellcheck) 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "FAIL" && printf '%s' "$out" | grep -qi "required"; then
  pass "shellcheck missing + CI -> rc 1 with FAIL"
else fail "shellcheck missing CI (rc=$rc, out=[$out])"; fi

# Missing + CI + override=0: escape hatch back to warn-only.
out="$( (export PATH="$NO_SC"; CI=true MERGEPATH_REQUIRE_SHELLCHECK=0 lint_tooling_require_shellcheck) 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "WARN"; then
  pass "shellcheck missing + CI + override=0 -> rc 0 warn-only"
else fail "shellcheck missing CI override0 (rc=$rc, out=[$out])"; fi

# Missing + local + override=1: opt-in strict makes it a hard FAIL locally too.
out="$( (export PATH="$NO_SC"; unset CI; MERGEPATH_REQUIRE_SHELLCHECK=1 lint_tooling_require_shellcheck) 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "FAIL"; then
  pass "shellcheck missing + local + override=1 -> rc 1 FAIL"
else fail "shellcheck missing local override1 (rc=$rc, out=[$out])"; fi

# ===========================================================================
echo "lint_tooling_report — availability report"
# ===========================================================================
out="$( (export PATH="$HAS_SC"; unset CI MERGEPATH_REQUIRE_SHELLCHECK; lint_tooling_report) 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "\[ok\]      shellcheck 0.0.0-fake"; then
  pass "report lists shellcheck [ok] with version when present"
else fail "report present (rc=$rc, out=[$out])"; fi

out="$( (export PATH="$NO_SC"; CI=true MERGEPATH_REQUIRE_SHELLCHECK=1 lint_tooling_report) 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "\[MISSING\] shellcheck"; then
  pass "report flags shellcheck [MISSING] + rc 1 when required and absent"
else fail "report missing strict (rc=$rc, out=[$out])"; fi

out="$( (export PATH="$NO_SC"; unset CI MERGEPATH_REQUIRE_SHELLCHECK; lint_tooling_report) 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "\[warn\]    shellcheck"; then
  pass "report shows shellcheck [warn] + rc 0 when absent but not required"
else fail "report missing lenient (rc=$rc, out=[$out])"; fi

# ===========================================================================
echo "direct execution — repo setup-check entrypoint"
# ===========================================================================
out="$(bash "$LIB" 2>&1)"; rc=$?
if printf '%s' "$out" | grep -q "Optional lint tooling"; then
  pass "bash scripts/lib/lint-tooling.sh prints the availability report (rc=$rc)"
else fail "direct-run report (rc=$rc, out=[$out])"; fi

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
