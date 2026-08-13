#!/usr/bin/env bash
# Regression coverage for scripts/coderabbit-automerge-rate-limit-gate.sh (#489)
# — the auto-merge workflow's decision on whether a CodeRabbit rate-limit stall
# (coderabbit-wait.sh exit 5) blocks or proceeds. PROCEED requires BOTH the
# Codex failover engaged AND external-review protection for the head: either
# an active merge-clearance external gate or already-satisfied current-head
# Codex/Phase-4b clearance. Under-threshold/unprotected stalls keep blocking
# (Codex P2 on #512 r3, #713). Verifies the engaged×protection matrix +
# fail-closed edges the Phase-4b reviewer asked for.
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

# --- the core engaged × protection matrix ---
assert_rc "engaged + external-review protected → proceed" 0 "$ENGAGED" true
assert_rc "engaged + unprotected → block (#512 r3/#713: no active or satisfied external gate)" 1 "$ENGAGED" false
assert_rc "not engaged + protected → block" 1 "$NOT_ENGAGED" true
assert_rc "not engaged + unprotected → block" 1 "$NOT_ENGAGED" false

# --- fail-closed edges ---
assert_rc "engaged + missing protection arg → block (fail-closed)" 1 "$ENGAGED"
assert_rc "missing codex_failover_requested + protected → block (fail-closed)" 1 \
  '{"status":"rate_limit_stalled"}' true
assert_rc "unparseable JSON + protected → block (fail-closed)" 1 'not json at all' true
assert_rc "empty JSON arg + protected → block (fail-closed)" 1 '' true
assert_rc "no arguments → block (fail-closed)" 1

# --- a realistic full payload ---
assert_rc "full rate_limit_stalled payload, engaged + protected → proceed" 0 \
  '{"pr_number":1,"status":"rate_limit_stalled","rate_limit_retries":2,"codex_failover_requested":true,"waited_seconds":120}' true
assert_rc "full payload, engaged + unprotected → block" 1 \
  '{"pr_number":1,"status":"rate_limit_stalled","rate_limit_retries":2,"codex_failover_requested":true,"waited_seconds":120}' false

# --- status gate (#554 fix 1): wrong/absent status blocks even with failover=true ---
assert_rc "status=cleared + failover=true + protected → block (only rate_limit_stalled ok)" 1 \
  '{"status":"cleared","codex_failover_requested":true}' true
assert_rc "status=timeout + failover=true + protected → block" 1 \
  '{"status":"timeout","codex_failover_requested":true}' true
assert_rc "absent status field + failover=true + protected → block" 1 \
  '{"codex_failover_requested":true}' true

# --- boolean precision (#554 fix 1): string "true" must not satisfy the gate ---
assert_rc "codex_failover_requested as string-true + rate_limit_stalled → block (must be JSON boolean)" 1 \
  '{"status":"rate_limit_stalled","codex_failover_requested":"true"}' true

# --- #825: the under-threshold arm (2b) — current-head Codex clearance -------
#
# An under-threshold PR can never satisfy arm 2a: merge-clearance passes
# vacuously for it, so --derive-rate-limit-protection returns false by
# construction and every rate-limited under-threshold PR deadlocked. Arm 2b
# resolves it with POSITIVE proof instead of a bypass: the gate re-asks
# codex-review-check.sh whether the review the failover requested has actually
# cleared the current head. Both directions matter — clearance proceeds, and
# the identical PR without it still blocks (the #512 r3 property).
#
# The checker is stubbed through CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN so
# the dispatch and exit-code mapping are exercised hermetically, and the wait
# budget is pinned to 0 so every probe is single-shot (no sleeping in tests).
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

make_stub() { # make_stub <name> <exit-code>
  local path="$STUB_DIR/$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
printf 'stub codex-review-check: pr=%s repo=%s skip_ci=%s head_pin=%s substitute=%s\n' \
  "$1" "$2" "${CODEX_REVIEW_CHECK_SKIP_CI:-}" \
  "${CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD:-}" \
  "${CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE:-}" >&2
STUB
  printf 'exit %s\n' "$2" >> "$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

CLEARED_STUB=$(make_stub cleared.sh 0)
UNCLEARED_STUB=$(make_stub uncleared.sh 1)
INFRA_STUB=$(make_stub infra.sh 3)

# assert_rc_2b <desc> <expected-rc> <stub> <gate-args...>
assert_rc_2b() {
  local desc=$1 want=$2 stub=$3; shift 3
  local rc=0
  CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN="$stub" \
    CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_WAIT_SECONDS=0 \
    bash "$GATE" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$desc"; else fail "$desc (expected rc $want, got $rc)"; fi
}

assert_rc_2b "#825 under-threshold + unprotected + current-head Codex clearance → proceed" 0 \
  "$CLEARED_STUB" "$ENGAGED" false 42 owner/repo
assert_rc_2b "#825 under-threshold + unprotected + NO current-head Codex clearance → block" 1 \
  "$UNCLEARED_STUB" "$ENGAGED" false 42 owner/repo

# The clearance arm is reachable only through the earlier gates: a stall that
# never engaged the failover, or a non-rate_limit_stalled status, must block
# even when the checker would report clearance — the proof is about the head
# Codex was actually asked to review.
assert_rc_2b "#825 clearance present but failover NOT engaged → block (gate 1 still binds)" 1 \
  "$CLEARED_STUB" "$NOT_ENGAGED" false 42 owner/repo
assert_rc_2b "#825 clearance present but status=cleared → block (gate 0 still binds)" 1 \
  "$CLEARED_STUB" '{"status":"cleared","codex_failover_requested":true}' false 42 owner/repo

# Protection short-circuits: arm 2a proceeds without consulting the checker at
# all, so an above-threshold protected head never pays the clearance wait.
assert_rc_2b "#825 protected head proceeds without invoking the clearance probe" 0 \
  "$UNCLEARED_STUB" "$ENGAGED" true 42 owner/repo

# --- #825 fail-closed edges: an unproven answer is never proof ---------------
assert_rc_2b "#825 checker infra error (rc=3) → block (fail-closed, not retried into proof)" 1 \
  "$INFRA_STUB" "$ENGAGED" false 42 owner/repo
assert_rc_2b "#825 missing PR number → block (fail-closed)" 1 \
  "$CLEARED_STUB" "$ENGAGED" false "" owner/repo
assert_rc_2b "#825 non-numeric PR number → block (fail-closed)" 1 \
  "$CLEARED_STUB" "$ENGAGED" false 'ab' owner/repo
assert_rc_2b "#825 missing repo → block (fail-closed)" 1 \
  "$CLEARED_STUB" "$ENGAGED" false 42 ""
assert_rc_2b "#825 malformed repo (no owner/name) → block (fail-closed)" 1 \
  "$CLEARED_STUB" "$ENGAGED" false 42 'ownerrepo'
assert_rc_2b "#825 checker binary absent → block (fail-closed)" 1 \
  "$STUB_DIR/does-not-exist.sh" "$ENGAGED" false 42 owner/repo
assert_rc_2b "#825 two-arg legacy call on an unprotected head → block (unchanged pre-#825 behaviour)" 1 \
  "$CLEARED_STUB" "$ENGAGED" false

# A non-integer budget must not be coerced into a probe that happens to pass.
rc=0
CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN="$CLEARED_STUB" \
  CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_WAIT_SECONDS=abc \
  bash "$GATE" "$ENGAGED" false 42 owner/repo >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then pass "#825 non-integer clearance budget → block (fail-closed)"; else fail "#825 non-integer clearance budget → block (expected rc 1, got $rc)"; fi

# The probe must run codex-review-check.sh with the hardening that makes its
# answer proof: HEAD-pinned gate (b) and NO Phase-4b substitute. Without the
# latter, the reviewer APPROVED that armed auto-merge would satisfy gate (c)
# by itself and an unreviewed under-threshold PR would "prove" clearance —
# the #512 r3 hole this arm exists not to reopen (#727, Codex P2 on #729).
probe_env=$(CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN="$UNCLEARED_STUB" \
  CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_WAIT_SECONDS=0 \
  bash "$GATE" "$ENGAGED" false 42 owner/repo 2>&1 || true)
if printf '%s' "$probe_env" | grep -Fq 'pr=42 repo=owner/repo skip_ci=1 head_pin=1 substitute=false'; then
  pass "#825 clearance probe passes PR/repo and runs SKIP_CI + REQUIRE_APPROVAL_ON_HEAD + ALLOW_PHASE_4B_SUBSTITUTE=false"
else
  fail "#825 clearance probe environment (got: $(printf '%s' "$probe_env" | head -1))"
fi

# The budget is a real bound, not decoration: a never-clearing checker under a
# tiny budget still terminates in a block, and probes more than once.
#
# Elapsed time is driven by a stubbed `date`, not by the wall clock, and `sleep`
# is a no-op — otherwise a first probe that happened to cross a second boundary
# would make the gate compute zero remaining budget and skip the re-probe, so a
# correct gate could fail this test (CodeRabbit 🟡 on #960). The stub clock
# returns the same second for the loop's first two reads and then advances one
# second per read, which pins the probe count exactly:
#
#   probe 1 → now=T+0 → remaining 2 → sleep (no-op)
#   probe 2 → now=T+1 → remaining 1 → sleep (no-op)
#   probe 3 → now=T+2 → remaining 0 → break, block
CLOCK_DIR="$STUB_DIR/clockbin"
mkdir -p "$CLOCK_DIR"
cat > "$CLOCK_DIR/date" <<'CLOCKSTUB'
#!/usr/bin/env bash
# Deterministic `date +%s` for the bounded-wait test. Any other invocation
# falls through to the real date so the stub cannot silently change meaning.
if [ "${1:-}" != "+%s" ]; then
  exec /bin/date "$@"
fi
reads=0
if [ -f "$MERGEPATH_TEST_CLOCK_FILE" ]; then
  reads=$(cat "$MERGEPATH_TEST_CLOCK_FILE")
fi
reads=$((reads + 1))
printf '%s\n' "$reads" > "$MERGEPATH_TEST_CLOCK_FILE"
# Read 1 is the loop's `start`; read 2 closes probe 1 at the same second.
step=$((reads - 2))
if [ "$step" -lt 0 ]; then step=0; fi
printf '%s\n' "$((1000 + step))"
CLOCKSTUB
cat > "$CLOCK_DIR/sleep" <<'SLEEPSTUB'
#!/usr/bin/env bash
exit 0
SLEEPSTUB
chmod +x "$CLOCK_DIR/date" "$CLOCK_DIR/sleep"

probe_log=$(MERGEPATH_TEST_CLOCK_FILE="$STUB_DIR/clock.count" \
  PATH="$CLOCK_DIR:$PATH" \
  CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN="$UNCLEARED_STUB" \
  CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_WAIT_SECONDS=2 \
  CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_POLL_SECONDS=1 \
  bash "$GATE" "$ENGAGED" false 42 owner/repo 2>&1 || true)
probe_count=$(printf '%s\n' "$probe_log" | grep -c 'stub codex-review-check' || true)
if [ "$probe_count" -eq 3 ]; then
  pass "#825 bounded wait re-probes while budget remains, then blocks (3 probes)"
else
  fail "#825 bounded wait should probe exactly 3 times under a 2s stub clock (saw $probe_count)"
fi

echo "----"
echo "test_coderabbit_automerge_rate_limit_gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
