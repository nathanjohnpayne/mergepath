#!/usr/bin/env bash
# Production rate-window parser and real polling/probe coverage. #2139 keeps
# window parsing for read-only refusal sensing, while polling immediately
# substitutes Codex or alerts the human. Fresh, expired, mutable, concurrent
# and malformed notices must never schedule a CodeRabbit retry.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-wait-rlwindow.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Extract the actual parser, rather than a second implementation of its grammar.
awk '/^parse_rate_limit_window\(\) \{/{copy=1} copy{print} copy && /^\}$/{exit}' \
  "$ROOT/scripts/coderabbit-wait.sh" >"$WORKDIR/parser.sh"
. "$WORKDIR/parser.sh"
parser_case() {
  local body=$1 expected=$2 actual rc=0
  actual=$(parse_rate_limit_window "$body") || rc=$?
  if [ "$expected" = "invalid" ]; then
    [ "$rc" -ne 0 ] && [ -z "$actual" ] || { fail "parser accepted unusable window: $body"; return; }
  else
    [ "$rc" -eq 0 ] && [ "$actual" = "$expected" ] || { fail "parser expected $expected, got '$actual' (rc=$rc): $body"; return; }
  fi
  pass "production window parser: $body"
}

parser_case 'Next included review available in 21 minutes.' 1260
parser_case '> **Next included review available in:** **13 minutes**.' 780
parser_case '<blockquote><strong>Next included review available in</strong>: <em>17 seconds</em>.</blockquote>' 17
parser_case 'Next included review available in 0 minutes.' 0
parser_case 'Next included review available in 1 minute and 2 seconds.' 62
parser_case 'Next included review available in **03 minutes and 02 seconds**.' 182
parser_case 'Next included review available in 1 minute and soon seconds.' invalid
parser_case 'Next included review available in 1 minute and 99999999999999999 seconds.' invalid
parser_case 'Next included review available in: 1 second.' 1
parser_case 'Next review available in: **3 minutes**.' 180
parser_case 'Next review available in: 9 seconds.' 9
parser_case 'Please wait **3 minutes and 2 seconds** before requesting another review.' 182
parser_case 'Please wait 12 seconds before requesting another review.' 12
parser_case 'Please wait 2 minutes before requesting another review.' 120
parser_case 'Next included review available in soon minutes.' invalid
parser_case 'Next included review available in -1 minutes.' invalid
parser_case 'Next included review available in 1.5 minutes.' invalid
parser_case 'Next included review available in 999999999999999999999999 minutes.' invalid
parser_case 'Next included review available in 5 minutes and will retry automatically.' invalid
parser_case 'Next included review available in 5 Minutes.' invalid

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
# make_case <name> <max_wait> <clock_offset> [seed_existing_trigger]
#   seed_existing_trigger=1 makes the comments endpoint ALSO serve an existing
#   `@coderabbitai, try again.` comment stamped at the notice time, modeling a
#   CONCURRENT coderabbit-wait run that already nudged this window (#829).
make_case() {
  local name=$1 max_wait=$2 clock_offset=$3 seed_trigger=${4:-0}
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  printf '%s' "$OLD_RATE_LIMIT_BODY" >"$dir/state/ratelimit-body.txt"
  printf '%s' "$COMMENT_TIME" >"$dir/state/comment-time.txt"
  printf '%s' "$seed_trigger" >"$dir/state/seed-trigger.txt"
  : >"$dir/state/posts.log"
  cp "$ROOT/scripts/coderabbit-wait.sh" "$dir/scripts/coderabbit-wait.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$dir/scripts/lib/reviewers-helpers.sh"
  # Hard-required by coderabbit-wait.sh since #1008: both fetch wrappers
  # delegate the paginated-list algorithm to the shared reader.
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"
  # Hard-required by coderabbit-wait.sh since #837: the potential-issue count
  # grades findings with the shared coderabbit_tier_of.
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"
  # #1178: hard-sourced by coderabbit-wait.sh, so the fixture must carry it.
  cp "$ROOT/scripts/lib/coderabbit-fence.sh" "$dir/scripts/lib/coderabbit-fence.sh"
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
available_reviewers:
  - nathanpayne-claude
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
notice_created=$(cat "$state_dir/notice-created-time.txt" 2>/dev/null || printf '%s' "$head_time")
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
method="GET"
if [ "${1:-}" = "--method" ]; then method=${2:-}; shift 2; fi
if [ "${1:-}" = "--paginate" ]; then shift; fi
endpoint=${1:-}; shift || true
if [ "$method" = "POST" ]; then
  # Record every write so a test can assert the retry trigger was NOT
  # re-posted when one already exists for this window (#829).
  printf '%s\n' "$endpoint" >>"$state_dir/posts.log"
  cat "$state_dir/fake-time" >>"$state_dir/post-times.log"
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
    seed=$(cat "$state_dir/seed-trigger.txt" 2>/dev/null || printf '0')
    case "$seed" in
      1)  # A concurrent run's nudge (TRUSTED reviewer identity, id > notice id).
        jq -cn --arg bot "$bot" --arg t "$head_time" --arg body "$rl_body" \
          '[{id:7701,user:{login:$bot},created_at:$t,updated_at:$t,body:$body},
            {id:7702,user:{login:"nathanpayne-claude"},created_at:$t,updated_at:$t,body:"@coderabbitai, try again."}]' ;;
      2)  # Same text from an UNTRUSTED participant — must NOT count as a nudge.
        jq -cn --arg bot "$bot" --arg t "$head_time" --arg body "$rl_body" \
          '[{id:7701,user:{login:$bot},created_at:$t,updated_at:$t,body:$body},
            {id:7702,user:{login:"random-drive-by"},created_at:$t,updated_at:$t,body:"@coderabbitai, try again."}]' ;;
      3)  # Trusted text but posted BEFORE the notice (lower id, same second) —
          # belongs to a PRIOR window, must NOT suppress this one.
        jq -cn --arg bot "$bot" --arg t "$head_time" --arg body "$rl_body" \
          '[{id:7700,user:{login:"nathanpayne-claude"},created_at:$t,updated_at:$t,body:"@coderabbitai, try again."},
            {id:7701,user:{login:$bot},created_at:$t,updated_at:$t,body:$body}]' ;;
      *)
        jq -cn --arg bot "$bot" --arg t "$head_time" --arg created "$notice_created" --arg body "$rl_body" \
          '[{id:7701,user:{login:$bot},created_at:$created,updated_at:$t,body:$body}]' ;;
    esac ;;
  *) echo "unexpected gh api endpoint: $endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1 rc=0
  shift
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      ./scripts/coderabbit-wait.sh "$@" 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

jqf() { jq -r "$2" "$1/out.json"; }

# --- Test 1: already-elapsed window → sleep 0, no full re-wait ---------------
# Notice posted 1000s ago, window 180s + 30s buffer = 210s < 1000s elapsed, so
# the remaining sleep clamps to 0. Before #727 this slept a fresh 210s.
# #2139 supersedes the polling/retry policy from #727/#829/#2031. Keep the
# real parser controls above and every temporal/concurrent notice scenario,
# but require immediate refusal rather than a scheduled CodeRabbit retry.
assert_immediate_no_retry() {
  local dir=$1 label=$2 initial rc before=$FAIL
  initial=$(cat "$dir/state/fake-time")
  rc=$(run_case "$dir")
  [ "$rc" = 5 ] && [ "$(jqf "$dir" .status)" = rate_limit_stalled ] \
    || fail "$label: refusal was not surfaced immediately (rc=$rc)"
  [ "$(jqf "$dir" .disposition)" = human_attention_required ] \
    || fail "$label: opted-out Codex requires human attention"
  [ "$(cat "$dir/state/fake-time")" = "$initial" ] \
    || fail "$label: refusal advanced the clock by sleeping"
  [ ! -s "$dir/state/posts.log" ] || fail "$label: posted a CodeRabbit retry"
  [ "$FAIL" -ne "$before" ] || pass "$label: immediate refusal, no sleep or provider retry"
}

test_expired_window_refuses_immediately() {
  local dir
  dir=$(make_case elapsed 60 1000)
  assert_immediate_no_retry "$dir" expired-window
}

test_fresh_window_refuses_immediately() {
  local dir
  dir=$(make_case fresh 300 5)
  assert_immediate_no_retry "$dir" fresh-window
}

test_existing_trigger_suppresses_duplicate() {
  local dir
  dir=$(make_case dedupe 60 1000 1)
  assert_immediate_no_retry "$dir" concurrent-prior-trigger
}

test_absent_trigger_never_retries() {
  local dir
  dir=$(make_case nodedupe 60 1000 0)
  assert_immediate_no_retry "$dir" absent-prior-trigger
}

test_untrusted_trigger_never_retries() {
  local dir
  dir=$(make_case untrusted 60 1000 2)
  assert_immediate_no_retry "$dir" forged-prior-trigger
}

test_same_second_trigger_never_retries() {
  local dir
  dir=$(make_case tiebreak 60 1000 3)
  assert_immediate_no_retry "$dir" same-second-older-trigger
}

test_included_window() {
  local name=$1 body=$2 window=$3 seed=${4:-0} dir
  dir=$(make_case "$name" "$((window + 90))" 5 "$seed")
  printf '%s\n' "> [!IMPORTANT]
> ## Rate limit exceeded
> $body" >"$dir/state/ratelimit-body.txt"
  assert_immediate_no_retry "$dir" "$name"
}

test_unusable_window() {
  local name=$1 body=$2 dir rc before=$FAIL
  dir=$(make_case "$name" 300 5)
  printf '%s\n' "> [!IMPORTANT]
> ## Rate limit exceeded
> $body" >"$dir/state/ratelimit-body.txt"
  rc=$(run_case "$dir")
  [ "$rc" = "5" ] && [ "$(jqf "$dir" .status)" = "rate_limit_stalled" ] \
    || fail "$name: unusable published window must stall with exit5"
  [ ! -s "$dir/state/posts.log" ] || fail "$name: retried a refusing provider without a usable deadline"
  ! grep -Fq 'falling back to 60s' "$dir/err.log" || fail "$name: unsafe fallback remains"
  [ "$FAIL" -ne "$before" ] || pass "$name: no optimistic retry on an unusable refusal window"
}

test_mutable_included_window() {
  local dir
  dir=$(make_case mutable-included 1500 5)
  printf '%s\n' '> [!IMPORTANT]
> ## Rate limit exceeded
> Next included review available in 21 minutes.' >"$dir/state/ratelimit-body.txt"
  jq -nr --argjson t "$((COMMENT_EPOCH - 1000))" '$t | todateiso8601' >"$dir/state/notice-created-time.txt"
  assert_immediate_no_retry "$dir" mutable-included
}

test_aged_malformed_window() {
  local dir rc before=$FAIL
  dir=$(make_case aged-malformed 300 3600)
  sed 's/wallclock_freshness_window_seconds: 999999999/wallclock_freshness_window_seconds: 30/' \
    "$dir/.github/review-policy.yml" >"$dir/.github/policy.tmp"
  mv "$dir/.github/policy.tmp" "$dir/.github/review-policy.yml"
  grep -Fxq '  wallclock_freshness_window_seconds: 30' "$dir/.github/review-policy.yml" \
    || { fail 'aged-malformed: freshness fixture rewrite did not happen'; return; }
  printf '%s\n' '> [!IMPORTANT]
> ## Rate limit exceeded
> Next included review available in soon minutes.' >"$dir/state/ratelimit-body.txt"
  rc=$(run_case "$dir")
  [ "$rc" = "5" ] && [ "$(jqf "$dir" .status)" = "rate_limit_stalled" ] \
    || fail 'aged-malformed: freshness aging must not invent an expired deadline'
  [ ! -s "$dir/state/posts.log" ] || fail 'aged-malformed: refusal retried without an expiry proof'
  grep -Fq 'unknowns left on the published window' "$dir/err.log" \
    || fail 'aged-malformed: polling did not consume the null remaining duration'
  rc=$(run_case "$dir" --probe)
  [ "$rc" = "7" ] && [ "$(jqf "$dir" .probe.observed)" = "rate_limit" ] \
    || fail 'aged-malformed: real probe must retain the unusable-window refusal'
  grep -Fq 'unknowns left on its published window' "$dir/err.log" \
    || fail 'aged-malformed: probe did not consume the null remaining duration'
  [ ! -s "$dir/state/posts.log" ] || fail 'aged-malformed: probe posted a retry'
  [ "$FAIL" -ne "$before" ] || pass 'aged-malformed: recognized malformed availability remains held'
}

test_unusable_window_failover() {
  local name=$1 enabled=$2 request_rc=$3 expected=$4 dir rc before=$FAIL
  dir=$(make_case "$name" 300 5)
  sed "s/codex_failover_on_rate_limit: false/codex_failover_on_rate_limit: $enabled/" \
    "$dir/.github/review-policy.yml" >"$dir/.github/policy.tmp"
  mv "$dir/.github/policy.tmp" "$dir/.github/review-policy.yml"
  grep -Fxq "  codex_failover_on_rate_limit: $enabled" "$dir/.github/review-policy.yml" \
    || { fail "$name: failover fixture rewrite did not happen"; return; }
  printf '%s\n' '> [!IMPORTANT]
> ## Rate limit exceeded
> Next included review available in soon minutes.' >"$dir/state/ratelimit-body.txt"
  printf '%s\n' "$request_rc" >"$dir/state/codex-request-rc"
  cat >"$dir/scripts/codex-review-request.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
printf '%s|%s\n' "${MERGEPATH_PHASE_4A_GATED:-}" "$*" >>"$state_dir/codex-requests.log"
echo '{"trigger_requested":true,"blocked_reason":null}'
exit "$(cat "$state_dir/codex-request-rc")"
EOF
  chmod +x "$dir/scripts/codex-review-request.sh"
  rc=$(run_case "$dir")
  [ "$rc" = "5" ] && [ "$(jqf "$dir" .status)" = "rate_limit_stalled" ] \
    || fail "$name: missing deadline must still stall"
  [ "$(jqf "$dir" .codex_failover_requested)" = "$expected" ] \
    || fail "$name: failover result misreported"
  if [ "$enabled" = "true" ]; then
    [ "$(wc -l <"$dir/state/codex-requests.log" | tr -d ' ')" = "1" ] \
      && grep -Fxq 'true|--trigger-only --failover --allow-moving-head 999 owner/repo' "$dir/state/codex-requests.log" \
      || fail "$name: expected one correctly gated trigger-only request"
  else
    [ ! -e "$dir/state/codex-requests.log" ] || fail "$name: opt-out invoked Codex"
  fi
  [ ! -s "$dir/state/posts.log" ] || fail "$name: posted a CodeRabbit retry"
  [ "$FAIL" -ne "$before" ] || pass "$name: unusable deadline retains truthful once-per-head failover"
}

test_included_window included21 'Next included review available in 21 minutes.' 1260
test_included_window included13 '> **Next included review available in:** **13 minutes**.' 780
test_included_window included-seconds '<blockquote>Next included review available in: <strong>17 seconds</strong>.</blockquote>' 17
test_included_window included-zero 'Next included review available in 0 minutes.' 0
test_included_window included-dedupe 'Next included review available in 21 minutes.' 1260 1
test_unusable_window malformed-included 'Next included review available in soon minutes.'
test_unusable_window missing-window 'The included-review allowance is exhausted; availability is unknown.'
test_mutable_included_window
test_aged_malformed_window
test_unusable_window_failover unusable-failover-success true 0 true
test_unusable_window_failover unusable-failover-failure true 5 false
test_unusable_window_failover unusable-failover-opt-out false 0 false

test_expired_window_refuses_immediately
test_fresh_window_refuses_immediately
test_existing_trigger_suppresses_duplicate
test_absent_trigger_never_retries
test_untrusted_trigger_never_retries
test_same_second_trigger_never_retries

echo "----"
echo "test_coderabbit_wait_ratelimit_window: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
