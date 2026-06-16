#!/usr/bin/env bash
# tests/test_codex_review_check_resolution.sh
#
# Regression coverage for the resolution-aware gate (c) filter in
# scripts/codex-review-check.sh (Option B on #460): a Codex P0/P1 finding on
# the latest review counts as UNADDRESSED only when its review thread is NOT
# resolved — aligning gate (c) with codex-p1-gate.sh and the weekly audit so
# the two required checks no longer contradict on a resolved P0/P1.
#
# The full gate (c) runs the entire codex-review-check flow (CI + gate (b) +
# reactions + reviewThreads), which test_merge_clearance_gate.sh stubs out;
# the resolution-join LOGIC is identical to codex-p1-gate.sh's (integration-
# tested in test_codex_p1_gate.sh via make_threads_fixture). This test pins
# (1) the structural presence of the join in the real script and (2) the
# join's jq logic inline — the inline-literal pattern used by
# scripts/ci/check_pr_audit_codex_clearance.
#
# Bash 3.2 portable. Runs without network.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-review-check.sh"
[ -r "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# 1. Structural: gate (c) fetches reviewThreads and filters UNADDRESSED_P01
#    by thread resolution (joined on comment_id), failing closed.
if grep -q "reviewThreads(first:100)" "$SCRIPT" \
   && grep -q "RESOLUTION_MAP" "$SCRIPT" \
   && grep -q "comment_id | tostring" "$SCRIPT" \
   && grep -qi "failing closed" "$SCRIPT" \
   && grep -q "#460" "$SCRIPT"; then
  pass "codex-review-check.sh gate (c) carries the resolution-aware reviewThreads filter (#460 Option B)"
else
  fail "codex-review-check.sh gate (c) is missing the resolution-aware filter (reviewThreads / RESOLUTION_MAP / comment_id join / fail-closed / #460)"
fi

# 2. Inline logic: the resolution-map filter excludes resolved findings,
#    keeps unresolved, and treats a finding ABSENT from the map as
#    unresolved (the fail-closed `// false` default). KEEP IN SYNC with the
#    `UNADDRESSED_P01 | jq(... $map ...)` filter in codex-review-check.sh.
UNADDRESSED='[{"path":"a","line":1,"comment_id":5001},{"path":"b","line":2,"comment_id":5002},{"path":"c","line":3,"comment_id":5003}]'
# 5001 resolved, 5002 unresolved, 5003 absent from the map (→ unresolved).
MAP='{"5001":true,"5002":false}'
FILTERED=$(echo "$UNADDRESSED" | jq --argjson map "$MAP" '
  [ .[] | . as $c | ($map[($c.comment_id | tostring)] // false) as $resolved | select($resolved != true) ]')
GOT=$(echo "$FILTERED" | jq -c '[.[].comment_id] | sort')
if [ "$GOT" = "[5002,5003]" ]; then
  pass "resolution filter: excludes resolved (5001), keeps unresolved (5002) and absent-from-map (5003, fail-closed)"
else
  fail "resolution filter wrong: expected [5002,5003], got $GOT"
fi

# 3. All-resolved → empty (gate (c) then clears via the review path).
MAP_ALL='{"5001":true,"5002":true,"5003":true}'
CNT=$(echo "$UNADDRESSED" | jq --argjson map "$MAP_ALL" '
  [ .[] | . as $c | ($map[($c.comment_id | tostring)] // false) as $r | select($r != true) ] | length')
if [ "$CNT" = "0" ]; then
  pass "resolution filter: all-resolved findings → 0 unaddressed (gate clears)"
else
  fail "resolution filter: all-resolved should yield 0, got $CNT"
fi

echo ""
echo "test_codex_review_check_resolution: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
