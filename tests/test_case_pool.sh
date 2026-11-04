#!/usr/bin/env bash
# Regression coverage for tests/lib/case-pool.sh (#2990), the helper the
# codex-review-request suites use to run their cases concurrently. Each check
# runs a small suite in a child bash and asserts on its counters and output.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/case-pool-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# The timing report is asserted on and off below; an exported value from the
# caller must not decide the "off" case.
unset MERGEPATH_TEST_TIMINGS

# run_suite <jobs> <body>: run <body> as a suite that sources the pool, with
# MERGEPATH_TEST_JOBS=<jobs>. Its stdout, stderr and exit status land in
# $WORKDIR/{out,err,rc}.
run_suite() {
  local rc=0
  cat >"$WORKDIR/suite.sh" <<EOF
set -euo pipefail
PASS=0
FAIL=0
pass() { echo "PASS: \$*"; PASS=\$((PASS + 1)); }
fail() { echo "FAIL: \$*" >&2; FAIL=\$((FAIL + 1)); }
WORKDIR="$WORKDIR/suite-work"
mkdir -p "\$WORKDIR"
source "$ROOT/tests/lib/case-pool.sh"
$2
echo "Results: \$PASS passed, \$FAIL failed"
[ "\$FAIL" -eq 0 ]
EOF
  MERGEPATH_TEST_JOBS=$1 bash "$WORKDIR/suite.sh" >"$WORKDIR/out" 2>"$WORKDIR/err" || rc=$?
  printf '%s\n' "$rc" >"$WORKDIR/rc"
}

# shellcheck disable=SC2016 # case bodies, expanded by the child suite
COMMON_CASES='
slow() { sleep 0.3; pass "slow $1"; }
fast() { pass "fast $1"; }
both() { pass "both one"; fail "both two"; }
'

test_counts_and_order() {
  local jobs
  for jobs in 1 4; do
    run_suite "$jobs" "$COMMON_CASES
case_pool_add slow a
case_pool_add fast b
case_pool_add both
case_pool_add fast 'c d'
case_pool_wait"
    if [ "$(cat "$WORKDIR/rc")" != 1 ]; then
      fail "jobs=$jobs: exit $(cat "$WORKDIR/rc"), expected 1 for one failed assertion"
    elif ! grep -qx 'Results: 4 passed, 1 failed' "$WORKDIR/out"; then
      fail "jobs=$jobs: counters not merged: $(tail -1 "$WORKDIR/out")"
    elif [ "$(grep '^PASS' "$WORKDIR/out" | tr '\n' '|')" != 'PASS: slow a|PASS: fast b|PASS: both one|PASS: fast c d|' ]; then
      fail "jobs=$jobs: output not in queue order: $(grep '^PASS' "$WORKDIR/out" | tr '\n' '|')"
    elif ! grep -qx 'FAIL: both two' "$WORKDIR/err"; then
      fail "jobs=$jobs: a case's stderr was not replayed to stderr"
    else
      pass "jobs=$jobs: counts merge, output replays in queue order, arguments keep their words"
    fi
  done
}

test_aborted_case_fails_closed() {
  run_suite 4 "$COMMON_CASES
dies() { pass 'before the abort'; false; pass 'never reached'; }
exits() { exit 0; }
trapped() { trap 'exit 7' EXIT; pass 'counted, then the exit trap fails'; }
case_pool_add fast a
case_pool_add dies
case_pool_add exits
case_pool_add trapped
case_pool_wait"
  if [ "$(cat "$WORKDIR/rc")" != 1 ]; then
    fail "abort: exit $(cat "$WORKDIR/rc"), expected 1"
  elif ! grep -qx 'Results: 1 passed, 3 failed' "$WORKDIR/out"; then
    fail "abort: an aborted case's passes counted, or the abort did not count: $(tail -1 "$WORKDIR/out")"
  elif ! grep -q "case 'dies' exited with status 1 before reporting its counts" "$WORKDIR/err" \
       || ! grep -q "case 'exits' exited with status 0 before reporting its counts" "$WORKDIR/err" \
       || ! grep -q "case 'trapped' exited with status 7" "$WORKDIR/err"; then
    fail "abort: the failure does not name the case and its status: $(cat "$WORKDIR/err")"
  else
    pass "a case that dies (errexit), exits early or exits nonzero after reporting is one FAIL, and none of its passes count"
  fi
}

test_parallel_and_first() {
  local start elapsed
  start=$(date +%s)
  run_suite 4 "$COMMON_CASES
mark() { printf '%s\n' \"\$1\" >>\"$WORKDIR/started\"; sleep 1; pass \"mark \$1\"; }
case_pool_add mark one
case_pool_add mark two
case_pool_add mark three
case_pool_add mark four
case_pool_wait"
  elapsed=$(( $(date +%s) - start ))
  if [ "$(cat "$WORKDIR/rc")" != 0 ] || [ "$elapsed" -ge 4 ]; then
    fail "parallel: exit $(cat "$WORKDIR/rc") after ${elapsed}s, expected four 1 s cases to overlap"
  else
    pass "jobs=4 runs four 1 s cases side by side (${elapsed}s)"
  fi
  rm -f "$WORKDIR/started"
  run_suite 1 "$COMMON_CASES
case_pool_add fast a
case_pool_add --first fast b
case_pool_wait"
  [ "$(grep '^PASS' "$WORKDIR/out" | tr '\n' '|')" = 'PASS: fast a|PASS: fast b|' ] \
    || fail "--first: serial mode must keep queue order"
  # Two slots: c and a start together (in either order), and b waits for one
  # of them to finish. Without --first, c would be the one left waiting.
  run_suite 2 "
mark() { printf '%s\n' \"\$1\" >>\"$WORKDIR/started\"; sleep 1; pass \"mark \$1\"; }
case_pool_add mark a
case_pool_add mark b
case_pool_add --first mark c
case_pool_wait"
  if [ "$(tail -1 "$WORKDIR/started")" != b ]; then
    fail "--first: start order $(tr '\n' ' ' <"$WORKDIR/started"), expected c in the first wave and b last"
  elif [ "$(grep '^PASS' "$WORKDIR/out" | tr '\n' '|')" != 'PASS: mark a|PASS: mark b|PASS: mark c|' ]; then
    fail "--first: output must still replay in queue order"
  else
    pass "--first starts a case ahead of the others and keeps its output in queue order"
  fi
}

test_per_case_workdir() {
  run_suite 4 "
same() { mkdir \"\$WORKDIR/fixture\"; pass \"own \$WORKDIR\"; }
case_pool_add same
case_pool_add same
case_pool_wait"
  if [ "$(cat "$WORKDIR/rc")" != 0 ] || [ "$(grep -c '^PASS: own ' "$WORKDIR/out")" != 2 ] \
     || [ "$(grep '^PASS: own ' "$WORKDIR/out" | sort -u | wc -l | tr -d ' ')" != 2 ]; then
    fail "per-case WORKDIR: two cases shared one fixture directory: $(cat "$WORKDIR/out" "$WORKDIR/err")"
  else
    pass "each pooled case gets its own WORKDIR, so equal fixture names never collide"
  fi
}

test_rejects_bad_input() {
  local before=$FAIL
  run_suite 0 "case_pool_add pass x
case_pool_wait"
  grep -q 'MERGEPATH_TEST_JOBS must be a positive integer' "$WORKDIR/err" && [ "$(cat "$WORKDIR/rc")" != 0 ] \
    || fail "MERGEPATH_TEST_JOBS=0 must refuse"
  run_suite 2 "case_pool_add no_such_case"
  grep -q "'no_such_case' is not a defined function" "$WORKDIR/err" && [ "$(cat "$WORKDIR/rc")" != 0 ] \
    || fail "queuing an undefined function must refuse"
  [ "$FAIL" -ne "$before" ] || pass "a non-positive job count and an undefined case are refused"
}

test_timings_report() {
  local before=$FAIL
  MERGEPATH_TEST_TIMINGS=1 run_suite 2 "$COMMON_CASES
case_pool_add slow a
case_pool_add fast b
case_pool_wait"
  [ "$(cat "$WORKDIR/rc")" = 0 ] && grep -q '^case-pool timing: .*s  slow a$' "$WORKDIR/err" \
    && grep -q '^case-pool timing: .*s  fast b$' "$WORKDIR/err" && ! grep -q 'case-pool timing' "$WORKDIR/out" \
    || fail "MERGEPATH_TEST_TIMINGS=1: no per-case timing on stderr: $(cat "$WORKDIR/err")"
  run_suite 2 "$COMMON_CASES
case_pool_add fast a
case_pool_wait"
  ! grep -q 'case-pool timing' "$WORKDIR/err" || fail "timings printed without MERGEPATH_TEST_TIMINGS"
  [ "$FAIL" -ne "$before" ] || pass "MERGEPATH_TEST_TIMINGS=1 reports each case's wall time on stderr, and only when set"
}

# Bash older than 4.3 (the `bash` the suites run under) has no `wait -n`, so
# the pool runs every case in the suite's own shell, in queue order, whatever
# MERGEPATH_TEST_JOBS says. That shape has its own guarantees to check.
test_serial_fallback() {
  MERGEPATH_TEST_TIMINGS=1 run_suite 4 "
setg() { G=\$1; pass \"set \$1\"; }
case_pool_add setg a
case_pool_add --first setg b
case_pool_wait
[ \"\${G:-}\" = b ] || fail 'cases did not run in the suite shell in queue order'"
  if [ "$(cat "$WORKDIR/rc")" != 0 ] || [ "$(grep '^PASS' "$WORKDIR/out" | tr '\n' '|')" != 'PASS: set a|PASS: set b|' ]; then
    fail "serial fallback: exit $(cat "$WORKDIR/rc"), output $(cat "$WORKDIR/out" "$WORKDIR/err")"
  elif grep -q 'case-pool timing' "$WORKDIR/err"; then
    fail "serial fallback: printed pool timings, but no case ran in the pool"
  else
    pass "bash $(bash -c 'echo "${BASH_VERSION}"') runs every case in the suite shell, in queue order, at any job count"
  fi
}

# In the serial shape a case that leaves the suite shell ends the suite; it
# must end it as a failure that names the case, with the suite's own EXIT trap
# still run, and never as a pass.
test_serial_early_exit() {
  local before=$FAIL kind
  for kind in exits dies; do
    rm -f "$WORKDIR/trap-ran"
    run_suite 1 "$COMMON_CASES
trap 'echo ran >\"$WORKDIR/trap-ran\"' EXIT
exits() { exit 0; }
dies() { false; }
case_pool_add fast a
case_pool_add $kind
case_pool_add fast b
case_pool_wait"
    [ "$(cat "$WORKDIR/rc")" = 1 ] && [ "$(grep '^PASS' "$WORKDIR/out" | tr '\n' '|')" = 'PASS: fast a|' ] \
      || fail "serial $kind: exit $(cat "$WORKDIR/rc"), output $(tr '\n' '|' <"$WORKDIR/out"); expected exit 1 after case a"
    grep -q "case '$kind' exited with status $([ "$kind" = exits ] && echo 0 || echo 1) before reporting its counts" "$WORKDIR/err" \
      || fail "serial $kind: the failure does not name the case and its status: $(cat "$WORKDIR/err")"
    [ -s "$WORKDIR/trap-ran" ] || fail "serial $kind: the suite's own EXIT trap did not run"
  done
  run_suite 1 "$COMMON_CASES
trap 'echo ran >\"$WORKDIR/trap-ran\"' EXIT
case_pool_add fast a
case_pool_wait
case \"\$(trap -p EXIT)\" in *trap-ran*) ;; *) fail 'the suite EXIT trap was not restored after the cases' ;; esac"
  [ "$(cat "$WORKDIR/rc")" = 0 ] || fail "serial: a clean run did not restore the suite's EXIT trap: $(cat "$WORKDIR/err")"
  [ "$FAIL" -ne "$before" ] || pass "serially, a case that exits (even exit 0) or dies fails the suite, names itself, and keeps the suite's EXIT trap"
}

if bash -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }'; then
  test_counts_and_order
  test_timings_report
  test_aborted_case_fails_closed
  test_parallel_and_first
  test_per_case_workdir
  test_serial_early_exit
  test_rejects_bad_input
else
  echo "bash on PATH is $(bash -c 'echo "${BASH_VERSION}"'), older than 4.3: checking the serial fallback only"
  test_counts_and_order
  test_serial_fallback
  test_serial_early_exit
  test_rejects_bad_input
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
