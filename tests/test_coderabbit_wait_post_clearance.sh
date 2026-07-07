#!/usr/bin/env bash
# Regression coverage for coderabbit-wait.sh's #727 post-clearance fast path.
#
# When auto-merge-on-approval has already confirmed a verified Codex / Phase-4b
# clearance AND a reviewer-identity APPROVED on HEAD, it sets
# CODERABBIT_WAIT_POST_CLEARANCE=1. The real blocking bot-review signal is
# already in, so coderabbit-wait.sh caps its poll budget to
# coderabbit.post_clearance_max_wait_seconds instead of the full
# max_wait_seconds — CodeRabbit stays advisory but still gets the capped window
# to land a review. This test drives the helper with NO CodeRabbit comment (so
# it polls to the timeout) and verifies the effective ceiling.
#
# Runs the real helper from a temp repo with stubbed gh/date/sleep. Makes no
# GitHub writes. Bash 3.2 portable. Mirrors
# tests/test_coderabbit_wait_ratelimit_window.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-wait-postclear.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

HEAD_TIME='2026-06-04T00:00:00Z'
# Seed the fake clock at the head-commit epoch so ELAPSED starts near 0 and the
# poll loop times out at exactly the (possibly capped) budget.
HEAD_EPOCH=$(jq -rn --arg t "$HEAD_TIME" '$t | fromdateiso8601')

# make_case <name> <max_wait> <post_clearance_wait>
make_case() {
  local name=$1 max_wait=$2 pc_wait=$3
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  printf '%s' "$HEAD_TIME" >"$dir/state/head-time.txt"
  cp "$ROOT/scripts/coderabbit-wait.sh" "$dir/scripts/coderabbit-wait.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$dir/scripts/lib/reviewers-helpers.sh"
  chmod +x "$dir/scripts/coderabbit-wait.sh"

  printf '%s\n' "$HEAD_EPOCH" >"$dir/state/fake-time"

  cat >"$dir/.github/review-policy.yml" <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
  max_wait_seconds: $max_wait
  post_clearance_max_wait_seconds: $pc_wait
  status_probe_enabled: false
  status_probe_wait_seconds: 0
  max_rate_limit_retries: 0
  codex_failover_on_rate_limit: false
  wallclock_freshness_window_seconds: 999999999
  trust_status_context_for_clearance: false
EOF

  cat >"$dir/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
[ -f "$clock_file" ] || printf '2000000000\n' >"$clock_file"
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then cat "$clock_file"; exit 0; fi
exec /bin/date "$@"
EOF
  chmod +x "$dir/bin/date"

  cat >"$dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
[ -f "$clock_file" ] || printf '2000000000\n' >"$clock_file"
duration=${1:-0}
case "$duration" in *.*) duration=${duration%%.*} ;; esac
current=$(cat "$clock_file")
printf '%s\n' $((current + duration)) >"$clock_file"
EOF
  chmod +x "$dir/bin/sleep"

  # gh stub: no CodeRabbit comment (issues/999/comments returns []), so the loop
  # polls until the (capped) max_wait budget elapses → exit 4 (advisory timeout).
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
head_time=$(cat "$state_dir/head-time.txt")
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
method="GET"
if [ "${1:-}" = "--method" ]; then method=${2:-}; shift 2; fi
if [ "${1:-}" = "--paginate" ]; then shift; fi
endpoint=${1:-}; shift || true
if [ "$method" = "POST" ]; then echo '{"id":9001}'; exit 0; fi
case "$endpoint" in
  repos/owner/repo/pulls/999) printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/commits/head-sha)
    if [ "${1:-}" = "--jq" ]; then printf '%s\n' "$head_time"
    else printf '{"commit":{"committer":{"date":"%s"}}}\n' "$head_time"; fi ;;
  repos/owner/repo/issues/999/timeline) printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews) printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments) printf '[]\n' ;;
  repos/owner/repo/issues/999/comments) printf '[]\n' ;;
  repos/owner/repo/commits/head-sha/statuses) printf '[]\n' ;;
  *) echo "unexpected gh api endpoint: $endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  printf '%s\n' "$dir"
}

# run_case <dir> <post_clearance_env> [post_clearance_sha]
#   post_clearance_env: value for CODERABBIT_WAIT_POST_CLEARANCE ("" = unset).
#   post_clearance_sha: value for CODERABBIT_WAIT_POST_CLEARANCE_SHA ("" = unset).
run_case() {
  local dir=$1 pc=${2:-} sha=${3:-} rc=0
  (
    cd "$dir"
    export PATH="$dir/bin:$PATH"
    export GH_TOKEN=test-token
    export CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1
    export CODERABBIT_TEST_STATE_DIR="$dir/state"
    [ -n "$pc" ] && export CODERABBIT_WAIT_POST_CLEARANCE="$pc"
    [ -n "$sha" ] && export CODERABBIT_WAIT_POST_CLEARANCE_SHA="$sha"
    ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

final_clock() { cat "$1/state/fake-time"; }

# --- Test 1: POST_CLEARANCE=1 caps the budget --------------------------------
# max_wait 1245, cap 30 → the loop times out at 30s, not 1245s.
test_post_clearance_caps() {
  local dir rc before=$FAIL waited
  dir=$(make_case "capped" 1245 30)
  rc=$(run_case "$dir" 1 head-sha)
  [ "$rc" = "4" ] || fail "1: expected exit 4 (advisory timeout), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'capping max_wait 1245s -> 30s' "$dir/err.log" \
    || fail "1: expected the cap log 'capping max_wait 1245s -> 30s'; log=$(grep -i 'max_wait' "$dir/err.log" | head -3)"
  grep -q 'max_wait = 30s' "$dir/err.log" \
    || fail "1: expected capped 'max_wait = 30s' in the run banner; log=$(grep -i 'max_wait =' "$dir/err.log")"
  waited=$(( $(final_clock "$dir") - HEAD_EPOCH ))
  [ "$waited" -le 45 ] || fail "1: helper waited ${waited}s (fake clock) — cap did not take effect (expected ~30s, not ~1245s)"
  [ "$FAIL" -ne "$before" ] || pass "1: #727 — CODERABBIT_WAIT_POST_CLEARANCE=1 caps the budget to post_clearance_max_wait_seconds (30s, not 1245s)"
}

# --- Test 2: no flag → full budget (no cap) ----------------------------------
# max_wait 45, cap 15, flag unset → must NOT cap; times out at 45s.
test_no_flag_full_budget() {
  local dir rc before=$FAIL
  dir=$(make_case "nocap" 45 15)
  rc=$(run_case "$dir" "")
  [ "$rc" = "4" ] || fail "2: expected exit 4, got $rc; err=$(tail -4 "$dir/err.log")"
  ! grep -q 'capping max_wait' "$dir/err.log" \
    || fail "2: cap engaged without CODERABBIT_WAIT_POST_CLEARANCE set"
  grep -q 'max_wait = 45s' "$dir/err.log" \
    || fail "2: expected full 'max_wait = 45s'; log=$(grep -i 'max_wait =' "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "2: without the flag the full max_wait_seconds budget is used (no cap)"
}

# --- Test 3: cap >= max_wait is a no-op --------------------------------------
# POST_CLEARANCE=1 but cap 240 >= max_wait 30 → never shortens; no cap log.
test_cap_noop_when_larger() {
  local dir rc before=$FAIL
  dir=$(make_case "noop" 30 240)
  rc=$(run_case "$dir" 1 head-sha)
  [ "$rc" = "4" ] || fail "3: expected exit 4, got $rc; err=$(tail -4 "$dir/err.log")"
  ! grep -q 'capping max_wait' "$dir/err.log" \
    || fail "3: cap log appeared even though post_clearance (240s) >= max_wait (30s)"
  grep -q 'max_wait = 30s' "$dir/err.log" \
    || fail "3: expected 'max_wait = 30s' unchanged; log=$(grep -i 'max_wait =' "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "3: the fast path only ever SHORTENS — a cap >= max_wait is a no-op"
}

# --- Test 4: a bad value with the flag UNSET must NOT break the wait ---------
# The core of the #729 CodeRabbit Major: unconditional validation would exit 3
# on a typo'd post_clearance_max_wait_seconds even in a policy that never
# engages the fast path, blocking auto-merge fleet-wide. The wait must run
# normally (exit 4) and never emit the exit-3 ERROR.
test_bad_value_unset_flag_does_not_break() {
  local dir rc before=$FAIL
  dir=$(make_case "badunset" 30 banana)
  rc=$(run_case "$dir" "")
  [ "$rc" = "4" ] || fail "4: a bad post_clearance value with the flag unset broke the wait (got rc=$rc, expected 4); err=$(tail -4 "$dir/err.log")"
  ! grep -q 'must be an integer' "$dir/err.log" \
    || fail "4: post_clearance validation ran even though the fast path was never engaged"
  ! grep -q 'capping max_wait' "$dir/err.log" || fail "4: unexpected cap with the flag unset"
  [ "$FAIL" -ne "$before" ] || pass "4: #729 — a bad post_clearance_max_wait_seconds does NOT break unrelated waits when the fast path is unused"
}

# --- Test 5: a bad value WITH the flag set disarms (full budget), never aborts -
# Even when armed, a non-integer must fail safe to the full budget with a
# warning, per the feature's "only ever shortens, never breaks the wait" invariant.
test_bad_value_set_flag_disarms() {
  local dir rc before=$FAIL
  dir=$(make_case "badset" 30 banana)
  rc=$(run_case "$dir" 1 head-sha)
  [ "$rc" = "4" ] || fail "5: a bad post_clearance value with the flag set aborted (got rc=$rc, expected 4/full-budget); err=$(tail -4 "$dir/err.log")"
  grep -q 'WARNING: coderabbit.post_clearance_max_wait_seconds must be an integer' "$dir/err.log" \
    || fail "5: expected the disarm WARNING; log=$(grep -i post_clearance "$dir/err.log" | head -2)"
  ! grep -q 'capping max_wait' "$dir/err.log" || fail "5: capped on a bad value instead of disarming"
  grep -q 'max_wait = 30s' "$dir/err.log" || fail "5: expected the full 'max_wait = 30s' budget after disarm"
  [ "$FAIL" -ne "$before" ] || pass "5: a bad post_clearance value with the flag set disarms to the full budget (warning), never aborts"
}

# --- Test 6: head-pin match caps ---------------------------------------------
# The caller pins the head it cleared. When it matches the live head (the gh
# stub serves head-sha), the cap applies.
test_head_pin_match_caps() {
  local dir rc before=$FAIL
  dir=$(make_case "pinmatch" 1245 30)
  rc=$(run_case "$dir" 1 head-sha)
  [ "$rc" = "4" ] || fail "6: expected exit 4, got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'capping max_wait 1245s -> 30s' "$dir/err.log" \
    || fail "6: expected the cap log with a matching head-pin; log=$(grep -i 'max_wait' "$dir/err.log" | head -3)"
  [ "$FAIL" -ne "$before" ] || pass "6: #729 — a matching post-clearance head-pin still caps the budget"
}

# --- Test 7: head-pin MISMATCH disarms (thread 985) --------------------------
# If a push landed between the caller's clearance probe and here, the pinned SHA
# no longer matches the live head — the clearance was for a stale head, so the
# cap must disarm to the full budget (the un-reviewed live head keeps the full
# CodeRabbit wait).
test_head_pin_mismatch_disarms() {
  local dir rc before=$FAIL
  dir=$(make_case "pinmiss" 1245 30)
  rc=$(run_case "$dir" 1 stale-other-sha)
  [ "$rc" = "4" ] || fail "7: expected exit 4, got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'does not match the live head' "$dir/err.log" \
    || fail "7: expected the head-pin disarm warning; log=$(grep -i 'post-clearance\|head' "$dir/err.log" | head -3)"
  ! grep -q 'capping max_wait' "$dir/err.log" \
    || fail "7: capped despite a head-pin mismatch (the #729 thread-985 race)"
  grep -q 'max_wait = 1245s' "$dir/err.log" \
    || fail "7: expected the full 'max_wait = 1245s' budget after a head-pin disarm; log=$(grep -i 'max_wait =' "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "7: #729 — a post-clearance head-pin mismatch disarms the cap (stale-head clearance not honored)"
}

# --- Test 8: EMPTY head-pin fails closed (r-comment on #729) ------------------
# If the caller could not resolve the head (transient API failure) it passes an
# empty CODERABBIT_WAIT_POST_CLEARANCE_SHA. Treating "absent" as "no pin needed"
# would let the cap apply to an unverified head — so an empty pin must FAIL
# CLOSED (full budget), exactly like a mismatch.
test_empty_head_pin_fails_closed() {
  local dir rc before=$FAIL
  dir=$(make_case "pinempty" 1245 30)
  rc=$(run_case "$dir" 1 "")
  [ "$rc" = "4" ] || fail "8: expected exit 4, got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'does not match the live head' "$dir/err.log" \
    || fail "8: expected the fail-closed warning for an empty pin; log=$(grep -i 'post-clearance\|head' "$dir/err.log" | head -3)"
  ! grep -q 'capping max_wait' "$dir/err.log" \
    || fail "8: capped with an EMPTY head-pin (must fail closed, r-comment on #729)"
  grep -q 'max_wait = 1245s' "$dir/err.log" \
    || fail "8: expected the full 'max_wait = 1245s' budget after an empty-pin disarm"
  [ "$FAIL" -ne "$before" ] || pass "8: #729 — an EMPTY post-clearance head-pin fails closed to the full budget (transient probe read failure)"
}

test_post_clearance_caps
test_no_flag_full_budget
test_cap_noop_when_larger
test_bad_value_unset_flag_does_not_break
test_bad_value_set_flag_disarms
test_head_pin_match_caps
test_head_pin_mismatch_disarms
test_empty_head_pin_fails_closed

echo "----"
echo "test_coderabbit_wait_post_clearance: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
