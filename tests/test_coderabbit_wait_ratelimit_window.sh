#!/usr/bin/env bash
# Regression coverage for coderabbit-wait.sh's rate-limit sleep computation
# (#727).
#
# The published CodeRabbit rate-limit window ("try again in N") is measured
# from when CodeRabbit POSTED the notice, not from when this helper first
# observes it. auto-merge-on-approval routinely starts the wait minutes after
# the notice landed (the reviewer approval that arms the job posts long after
# CodeRabbit rate-limited), so sleeping a fresh full window re-waits time that
# already elapsed. On PR #725 that cost a wasted 210s sleep for a window that
# had expired ~5 min earlier.
#
# The fix: sleep only the REMAINING window — (window + buffer) - already-elapsed
# — clamped to >= 0. This test aligns the fake clock with the served comment's
# post time (via jq fromdateiso8601) so `now - fresh_at` is meaningful, then
# verifies:
#   1. already-elapsed window (notice posted 1000s ago, window 180s) → sleeps 0s
#      and never re-waits the full 210s.
#   2. fresh window (notice posted 5s ago, window 180s) → still sleeps ~the full
#      window (205s), so the rate-limit contract is unchanged for the common
#      case.
#
# Runs the real helper from a temp repo with stubbed gh/date/sleep. Makes no
# GitHub writes. Bash 3.2 portable. Mirrors tests/test_coderabbit_wait_codex_failover.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-wait-rlwindow.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# The CodeRabbit rate-limit notice is served with this created_at/updated_at.
# The head committer date is stamped identically so the notice passes the
# HEAD-anchor freshness filter (fresh_at >= anchor, inclusive).
COMMENT_TIME='2026-06-04T00:00:00Z'
COMMENT_EPOCH=$(jq -rn --arg t "$COMMENT_TIME" '$t | fromdateiso8601')

# Old-format notice with a precise, easily-checked 180s window (3m0s), the same
# shape as the #725 notice.
OLD_RATE_LIMIT_BODY='> [!IMPORTANT]
> ## Rate limit exceeded
>
> @author has exceeded the limit for the number of commits or files that can be reviewed per hour.
>
> Please wait **3 minutes and 0 seconds** before requesting another review.'

# make_case <name> <max_wait> <clock_offset>
#   clock_offset is added to COMMENT_EPOCH to seed the fake clock, modeling how
#   long ago (in seconds) the rate-limit notice was posted relative to "now".
make_case() {
  local name=$1 max_wait=$2 clock_offset=$3
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  printf '%s' "$OLD_RATE_LIMIT_BODY" >"$dir/state/ratelimit-body.txt"
  printf '%s' "$COMMENT_TIME" >"$dir/state/comment-time.txt"
  cp "$ROOT/scripts/coderabbit-wait.sh" "$dir/scripts/coderabbit-wait.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$dir/scripts/lib/reviewers-helpers.sh"
  chmod +x "$dir/scripts/coderabbit-wait.sh"

  # Seed the fake clock so "now" is clock_offset seconds after the notice.
  printf '%s\n' "$((COMMENT_EPOCH + clock_offset))" >"$dir/state/fake-time"

  # max_retries=1 so the FIRST rate-limit iteration reaches the sleep
  # computation (retries 0 < 1) instead of stalling; later iterations loop on
  # the same-id NOTE to the max_wait timeout (exit 4). Failover off keeps the
  # test focused on the sleep and needs no Codex stub.
  cat >"$dir/.github/review-policy.yml" <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
  max_wait_seconds: $max_wait
  status_probe_enabled: false
  status_probe_wait_seconds: 0
  max_rate_limit_retries: 1
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

  # gh stub: the issues/999/comments GET returns a persistent same-id rate-limit
  # NOTE stamped at COMMENT_TIME (created_at == updated_at). The head committer
  # date is the same instant so the notice clears the freshness anchor. POST
  # (the `@coderabbitai, try again.` retry trigger) is accepted and ignored.
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
bot='coderabbitai[bot]'
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
head_time=$(cat "$state_dir/comment-time.txt")
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
method="GET"
if [ "${1:-}" = "--method" ]; then method=${2:-}; shift 2; fi
if [ "${1:-}" = "--paginate" ]; then shift; fi
endpoint=${1:-}; shift || true
if [ "$method" = "POST" ]; then
  case "$endpoint" in
    repos/owner/repo/issues/999/comments)
      printf '{"id":9001,"created_at":"%s","body":"ack"}\n' "$head_time" ;;
    *) echo "unexpected gh api POST endpoint: $endpoint" >&2; exit 99 ;;
  esac
  exit 0
fi
case "$endpoint" in
  repos/owner/repo/pulls/999) printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/commits/head-sha)
    if [ "${1:-}" = "--jq" ]; then printf '%s\n' "$head_time"
    else printf '{"commit":{"committer":{"date":"%s"}}}\n' "$head_time"; fi ;;
  repos/owner/repo/issues/999/timeline) printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews) printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments) printf '[]\n' ;;
  repos/owner/repo/issues/999/comments)
    rl_body=$(cat "$state_dir/ratelimit-body.txt")
    jq -cn --arg bot "$bot" --arg t "$head_time" --arg body "$rl_body" \
      '[{id:7701,user:{login:$bot},created_at:$t,updated_at:$t,body:$body}]' ;;
  *) echo "unexpected gh api endpoint: $endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1 rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

jqf() { jq -r "$2" "$1/out.json"; }

# --- Test 1: already-elapsed window → sleep 0, no full re-wait ---------------
# Notice posted 1000s ago, window 180s + 30s buffer = 210s < 1000s elapsed, so
# the remaining sleep clamps to 0. Before #727 this slept a fresh 210s.
test_elapsed_window_sleeps_zero() {
  local dir rc before=$FAIL
  dir=$(make_case "elapsed" 60 1000)
  rc=$(run_case "$dir")
  [ "$rc" = "4" ] || fail "1: expected exit 4 (timeout after one retry), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'rate-limited; sleeping 0s (window=180s + 30s buffer, 1000s already elapsed)' "$dir/err.log" \
    || fail "1: expected 'sleeping 0s ... 1000s already elapsed'; log=$(grep -i 'rate-limited; sleeping' "$dir/err.log" || echo none)"
  ! grep -q 'rate-limited; sleeping 210s' "$dir/err.log" \
    || fail "1: helper re-waited the full 210s window that had already elapsed (the #727 bug)"
  [ "$FAIL" -ne "$before" ] || pass "1: #727 — an already-expired rate-limit window sleeps 0s instead of re-waiting the full 210s"
}

# --- Test 2: fresh window → still sleeps ~the full window --------------------
# Notice posted 5s ago: remaining = 210 - 5 = 205s. The fix must not shorten a
# genuinely-fresh rate-limit wait.
test_fresh_window_sleeps_remaining() {
  local dir rc before=$FAIL
  dir=$(make_case "fresh" 300 5)
  rc=$(run_case "$dir")
  [ "$rc" = "4" ] || fail "2: expected exit 4, got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'rate-limited; sleeping 205s (window=180s + 30s buffer, 5s already elapsed)' "$dir/err.log" \
    || fail "2: expected 'sleeping 205s ... 5s already elapsed'; log=$(grep -i 'rate-limited; sleeping' "$dir/err.log" || echo none)"
  [ "$FAIL" -ne "$before" ] || pass "2: a fresh rate-limit window still sleeps ~the full window (205s of 210s) — contract unchanged for the common case"
}

test_elapsed_window_sleeps_zero
test_fresh_window_sleeps_remaining

echo "----"
echo "test_coderabbit_wait_ratelimit_window: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
