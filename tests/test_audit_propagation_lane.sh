#!/usr/bin/env bash
# Offline coverage for scripts/audit-propagation-lane.sh (#434) via its
# --check-files mode, which evaluates the same lane predicate the live
# per-consumer loop evaluates.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/audit-propagation-lane.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/lane-audit-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# A workflow file carrying the #434 default-ON lane marker, and one
# predating it. The marker literal must match the one in the REAL
# synced workflow — assert that first so the audit can't silently
# diverge from what pr-review-policy.yml actually ships.
MARKER='PROP_ENABLED=${PROP_ENABLED:-true}'
if grep -qF "$MARKER" "$ROOT/.github/workflows/pr-review-policy.yml"; then
  pass "lane default-ON marker present in the real pr-review-policy.yml"
else
  fail "lane default-ON marker missing from .github/workflows/pr-review-policy.yml — audit marker and workflow have diverged"
fi

WF_NEW="$WORKDIR/wf-new.yml"
printf 'jobs:\n  x:\n    run: |\n      %s\n' "$MARKER" >"$WF_NEW"
WF_OLD="$WORKDIR/wf-old.yml"
printf 'jobs:\n  x:\n    run: |\n      PROP_ENABLED=$(prop_field f propagation_prs enabled)\n' >"$WF_OLD"

POLICY_BARE="$WORKDIR/policy-bare.yml"        # no propagation_prs block (the fleet-wide #434 shape)
printf 'author_identity: nathanjohnpayne\n' >"$POLICY_BARE"
POLICY_ON="$WORKDIR/policy-on.yml"            # explicit enabled: true
printf 'propagation_prs:\n  enabled: true\nauthor_identity: nathanjohnpayne\n' >"$POLICY_ON"
POLICY_OFF="$WORKDIR/policy-off.yml"          # explicit opt-out
printf 'propagation_prs:\n  enabled: false\nauthor_identity: nathanjohnpayne\n' >"$POLICY_OFF"
POLICY_NO_AUTHOR="$WORKDIR/policy-no-author.yml"
printf 'propagation_prs:\n  enabled: true\n' >"$POLICY_NO_AUTHOR"
POLICY_ALT_PREFIX="$WORKDIR/policy-alt-prefix.yml"  # prefix that sync never opens
printf 'propagation_prs:\n  enabled: true\n  branch_prefix: "other-prefix/"\nauthor_identity: nathanjohnpayne\n' >"$POLICY_ALT_PREFIX"
POLICY_STD_PREFIX="$WORKDIR/policy-std-prefix.yml"  # explicit standard prefix
printf 'propagation_prs:\n  enabled: true\n  branch_prefix: "mergepath-sync/"\nauthor_identity: nathanjohnpayne\n' >"$POLICY_STD_PREFIX"
POLICY_WRONG_AUTHOR="$WORKDIR/policy-wrong-author.yml"  # author that sync never uses
printf 'propagation_prs:\n  enabled: true\nauthor_identity: nathanpayne-claude\n' >"$POLICY_WRONG_AUTHOR"
POLICY_CASED="$WORKDIR/policy-cased.yml"  # YAML-boolean-ish but not the lane's exact match
printf 'propagation_prs:\n  enabled: TRUE\nauthor_identity: nathanjohnpayne\n' >"$POLICY_CASED"

run_check() {  # <policy> <workflow> — sets OUT and RC
  set +e
  OUT=$("$SCRIPT" --check-files "$1" "$2" 2>&1)
  RC=$?
  set -e
}

run_check "$POLICY_BARE" "$WF_NEW"
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "default-ON"; then
  pass "absent propagation_prs block fires the lane under the default-ON workflow"
else
  fail "absent block should fire (rc=0, default-ON); got rc=$RC, out: $OUT"
fi

run_check "$POLICY_ON" "$WF_NEW"
if [ "$RC" = "0" ]; then
  pass "explicit enabled: true fires the lane"
else
  fail "explicit enabled: true should fire; got rc=$RC, out: $OUT"
fi

run_check "$POLICY_OFF" "$WF_NEW"
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "explicit opt-out"; then
  pass "explicit enabled: false is flagged as an opt-out and fails the audit"
else
  fail "explicit enabled: false should fail with opt-out message; got rc=$RC, out: $OUT"
fi

run_check "$POLICY_BARE" "$WF_OLD"
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "predates the #434"; then
  pass "pre-#434 workflow without the default-ON marker fails the audit"
else
  fail "pre-#434 workflow should fail with marker message; got rc=$RC, out: $OUT"
fi

run_check "$POLICY_NO_AUTHOR" "$WF_NEW"
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "no author_identity"; then
  pass "missing author_identity fails the audit"
else
  fail "missing author_identity should fail; got rc=$RC, out: $OUT"
fi

run_check "" "$WF_NEW"
if [ "$RC" = "1" ]; then
  pass "absent review-policy.yml fails the audit (no author fingerprint)"
else
  fail "absent review-policy.yml should fail; got rc=$RC, out: $OUT"
fi

run_check "$POLICY_ALT_PREFIX" "$WF_NEW"
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "never match a real sync PR"; then
  pass "overridden branch_prefix that sync never opens fails the audit"
else
  fail "non-sync branch_prefix should fail; got rc=$RC, out: $OUT"
fi

run_check "$POLICY_STD_PREFIX" "$WF_NEW"
if [ "$RC" = "0" ]; then
  pass "explicit standard branch_prefix fires the lane"
else
  fail "explicit mergepath-sync/ prefix should fire; got rc=$RC, out: $OUT"
fi

run_check "$POLICY_WRONG_AUTHOR" "$WF_NEW"
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "sync PRs are authored by"; then
  pass "author_identity that is not the sync actor fails the audit"
else
  fail "non-sync author_identity should fail; got rc=$RC, out: $OUT"
fi

run_check "$POLICY_CASED" "$WF_NEW"
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "only fires on exactly"; then
  pass "non-lowercase enabled value fails the audit (lane matches exactly 'true')"
else
  fail "enabled: TRUE should fail; got rc=$RC, out: $OUT"
fi

echo ""
echo "test_audit_propagation_lane: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
