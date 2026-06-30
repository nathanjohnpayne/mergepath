#!/usr/bin/env bash
# Regression coverage for scripts/coderabbit-automerge-rate-limit-gate.sh (#489)
# — the auto-merge workflow's decision on whether a CodeRabbit rate-limit stall
# (coderabbit-wait.sh exit 5) blocks or proceeds. PROCEED requires BOTH the
# Codex failover engaged AND the PR being above the external-review threshold
# (where merge-clearance gates Codex). Under-threshold stalls keep blocking
# (Codex P2 on #512 r3). Verifies the engaged×threshold matrix + fail-closed
# edges the Phase-4b reviewer asked for.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/coderabbit-automerge-rate-limit-gate.sh"

[ -x "$GATE" ] || { echo "missing or non-executable $GATE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# assert_rc <desc> <expected-rc> <gate-args...>
assert_rc() {
  local desc=$1 want=$2; shift 2
  local rc=0
  bash "$GATE" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$desc"; else fail "$desc (expected rc $want, got $rc)"; fi
}

ENGAGED='{"status":"rate_limit_stalled","codex_failover_requested":true}'
NOT_ENGAGED='{"status":"rate_limit_stalled","codex_failover_requested":false}'

# --- the core engaged × threshold matrix ---
assert_rc "engaged + above-threshold → proceed" 0 "$ENGAGED" true
assert_rc "engaged + under-threshold → block (#512 r3: no downstream Codex gate)" 1 "$ENGAGED" false
assert_rc "not engaged + above-threshold → block" 1 "$NOT_ENGAGED" true
assert_rc "not engaged + under-threshold → block" 1 "$NOT_ENGAGED" false

# --- fail-closed edges ---
assert_rc "engaged + missing threshold arg → block (fail-closed)" 1 "$ENGAGED"
assert_rc "missing codex_failover_requested + above-threshold → block (fail-closed)" 1 \
  '{"status":"rate_limit_stalled"}' true
assert_rc "unparseable JSON + above-threshold → block (fail-closed)" 1 'not json at all' true
assert_rc "empty JSON arg + above-threshold → block (fail-closed)" 1 '' true
assert_rc "no arguments → block (fail-closed)" 1

# --- a realistic full payload ---
assert_rc "full rate_limit_stalled payload, engaged + above-threshold → proceed" 0 \
  '{"pr_number":1,"status":"rate_limit_stalled","rate_limit_retries":2,"codex_failover_requested":true,"waited_seconds":120}' true
assert_rc "full payload, engaged + under-threshold → block" 1 \
  '{"pr_number":1,"status":"rate_limit_stalled","rate_limit_retries":2,"codex_failover_requested":true,"waited_seconds":120}' false

# --- status gate (#554 fix 1): wrong/absent status blocks even with failover=true ---
assert_rc "status=cleared + failover=true + above-threshold → block (only rate_limit_stalled ok)" 1 \
  '{"status":"cleared","codex_failover_requested":true}' true
assert_rc "status=timeout + failover=true + above-threshold → block" 1 \
  '{"status":"timeout","codex_failover_requested":true}' true
assert_rc "absent status field + failover=true + above-threshold → block" 1 \
  '{"codex_failover_requested":true}' true

# --- boolean precision (#554 fix 1): string "true" must not satisfy the gate ---
assert_rc "codex_failover_requested as string-true + rate_limit_stalled → block (must be JSON boolean)" 1 \
  '{"status":"rate_limit_stalled","codex_failover_requested":"true"}' true

echo "----"
echo "test_coderabbit_automerge_rate_limit_gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
