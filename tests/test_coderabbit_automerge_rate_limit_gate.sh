#!/usr/bin/env bash
# Regression coverage for scripts/coderabbit-automerge-rate-limit-gate.sh (#489)
# — the auto-merge workflow's decision on whether a CodeRabbit rate-limit stall
# (coderabbit-wait.sh exit 5) blocks or proceeds, based on whether the Codex
# failover engaged. Verifies the engaged-vs-not-engaged contract the
# Phase-4b reviewer asked for, plus the fail-closed edges.
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

# assert_disposition <desc> <expected-rc> <json-arg...>
assert_rc() {
  local desc=$1 want=$2; shift 2
  local rc=0
  bash "$GATE" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$desc"; else fail "$desc (expected rc $want, got $rc)"; fi
}

# Engaged → proceed (exit 0)
assert_rc "failover engaged (rate_limit_stalled + codex_failover_requested:true) → proceed" 0 \
  '{"status":"rate_limit_stalled","codex_failover_requested":true}'

# Not engaged → block (exit 1)
assert_rc "failover not engaged (codex_failover_requested:false) → block" 1 \
  '{"status":"rate_limit_stalled","codex_failover_requested":false}'

# Missing flag → block (fail-closed via // false)
assert_rc "missing codex_failover_requested → block (fail-closed)" 1 \
  '{"status":"rate_limit_stalled"}'

# Malformed JSON → block (fail-closed)
assert_rc "unparseable JSON → block (fail-closed)" 1 'not json at all'

# Empty arg → block (fail-closed)
assert_rc "empty JSON arg → block (fail-closed)" 1 ''

# No arg at all → block (fail-closed)
assert_rc "no argument → block (fail-closed)" 1

# A real-ish engaged payload (full coderabbit-wait JSON shape) → proceed
assert_rc "full rate_limit_stalled payload with failover → proceed" 0 \
  '{"pr_number":1,"status":"rate_limit_stalled","rate_limit_retries":2,"codex_failover_requested":true,"waited_seconds":120}'

echo "----"
echo "test_coderabbit_automerge_rate_limit_gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
