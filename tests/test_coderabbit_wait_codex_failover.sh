#!/usr/bin/env bash
# Regression coverage for coderabbit-wait.sh's CodeRabbit→Codex rate-limit
# failover (#489).
#
# Runs the real helper from a temp repo with stubbed gh/date/sleep and a stub
# codex-review-request.sh (wired via CODERABBIT_WAIT_CODEX_REQUEST_CMD), so the
# rate-limit path is deterministic and makes no GitHub writes. Verifies:
#   - On a rate-limit notice with the knob ON, the helper invokes the Codex
#     request helper ONCE in --trigger-only mode with MERGEPATH_PHASE_4A_GATED
#     and surfaces codex_failover_requested:true in the JSON.
#   - With the knob OFF (codex_failover_on_rate_limit: false), it does NOT.
#   - When the Codex helper no-ops (exit 5, e.g. codex.enabled:false), the
#     failover stays unrecorded (codex_failover_requested:false).
#   - The failover is idempotent across a multi-retry run (FIRED latch): a
#     single trigger even when the loop keeps polling the same rate-limit NOTE.
#
# Bash 3.2 portable. Mirrors the harness shape of
# tests/test_coderabbit_wait_status_probe.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-wait-codex-failover.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Rate-limit comment bodies served by the gh stub. OLD is the original #138
# prose (no marker) — exercises classify_comment's legacy text fallback. NEW is
# CodeRabbit's adaptive "Fair Usage Limits" variant (#593 / observed on #591):
# the stable `rate limited by coderabbit.ai` marker + "Review limit reached"
# prose + a "Next review available in: **13 minutes**" window — none of which
# match the old text patterns. Before #593 this NEW body misclassified as a
# clean `review` and the script false-cleared (exit 0), merging #591 unreviewed.
OLD_RATE_LIMIT_BODY='Rate limit exceeded. Please wait 10 seconds before requesting another review.'
NEW_RATE_LIMIT_BODY='<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->

> [!WARNING]
> ## Review limit reached
>
> You have reached a temporary PR review limit under our Fair Usage Limits Policy.
>
> **Next review available in:** **13 minutes**

<!-- end of auto-generated comment: rate limited by coderabbit.ai -->'

# make_case <name> <max_wait> <max_retries> <failover> [rate_limit_body]
#   rate_limit_body defaults to the OLD format; pass NEW_RATE_LIMIT_BODY to
#   exercise the adaptive-limit variant.
make_case() {
  local name=$1 max_wait=$2 max_retries=$3 failover=$4
  local rate_limit_body=${5:-$OLD_RATE_LIMIT_BODY}
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  # The gh stub reads the served rate-limit comment body from here so a case
  # can pick OLD vs NEW format without regenerating the stub.
  printf '%s' "$rate_limit_body" >"$dir/state/ratelimit-body.txt"
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

  cat >"$dir/.github/review-policy.yml" <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
  max_wait_seconds: $max_wait
  status_probe_enabled: false
  status_probe_wait_seconds: 0
  max_rate_limit_retries: $max_retries
  codex_failover_on_rate_limit: $failover
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
printf '%s\n' "$*" >>"$state_dir/sleeps.log"
duration=${1:-0}
case "$duration" in *.*) duration=${duration%%.*} ;; esac
current=$(cat "$clock_file")
printf '%s\n' $((current + duration)) >"$clock_file"
EOF
  chmod +x "$dir/bin/sleep"

  # gh stub: serves the endpoints coderabbit-wait.sh hits on the rate-limit
  # path. issues/999/comments returns a persistent "Rate limit exceeded" NOTE
  # (same id 7701 every call), so a multi-retry run loops on the same NOTE
  # after the first detection — exactly the shape that must fire the failover
  # only once. POST to issues/999/comments (the `@coderabbitai, try again.`
  # retry trigger) is accepted and ignored.
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
bot='coderabbitai[bot]'
head_time='2026-06-04T00:00:00Z'
state_dir=${CODERABBIT_TEST_STATE_DIR:?}
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
method="GET"
if [ "${1:-}" = "--method" ]; then method=${2:-}; shift 2; fi
if [ "${1:-}" = "--paginate" ]; then shift; fi
endpoint=${1:-}; shift || true
if [ "$method" = "POST" ]; then
  printf '%s\n' "$endpoint" >>"$state_dir/posts.log"
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

  # Stub Codex request helper. Records each invocation (args + the
  # MERGEPATH_PHASE_4A_GATED env it was called with) to a log, emits the
  # documented trigger-only JSON, and exits CODEX_STUB_EXIT (0 = posted,
  # 5 = NO_TRIGGER_REQUESTED, i.e. Codex disabled / opted out).
  cat >"$dir/bin/codex-request-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'phase4a=%s auto=%s args=[%s]\n' "${MERGEPATH_PHASE_4A_GATED:-unset}" "${MERGEPATH_CODEX_AUTO_TRIGGER:-unset}" "$*" >>"${CODEX_STUB_LOG:?}"
posted=true
if [ "${MERGEPATH_CODEX_AUTO_TRIGGER:-}" = true ]; then posted=false
elif [ "${CODEX_STUB_EXIT:-0}" = 0 ]; then touch "$CODEX_STUB_LOG.posted"; fi
jq -nc --argjson posted "$posted" --arg blocked "${CODEX_STUB_BLOCKED:-}" \
  '{trigger_only:true,trigger_posted:$posted,trigger_requested:true,blocked_reason:(if $blocked=="" then null else $blocked end)}'
exit "${CODEX_STUB_EXIT:-0}"
EOF
  chmod +x "$dir/bin/codex-request-stub.sh"

  printf '%s\n' "$dir"
}

# run_case <dir> <stub_exit>
run_case() {
  local dir=$1 stub_exit=${2:-0} rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      CODEX_STUB_EXIT="$stub_exit" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

stub_calls() {
  local dir=$1
  if [ -f "$dir/state/codex-stub.log" ]; then wc -l <"$dir/state/codex-stub.log" | tr -d ' '
  else printf '0\n'; fi
}

jqf() { jq -r "$2" "$1/out.json"; }

# --- Test A: knob ON → failover fires once, exit 5, requested:true ----------
test_failover_fires() {
  local dir rc before=$FAIL
  dir=$(make_case "fires" 300 0 true)
  rc=$(run_case "$dir" 0)
  [ "$rc" = "5" ] || fail "A: expected exit 5 (rate_limit_stalled), got $rc; err=$(cat "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "rate_limit_stalled" ] || fail "A: status=$(jqf "$dir" '.status'), expected rate_limit_stalled"
  [ "$(jqf "$dir" '.codex_failover_requested')" = "true" ] || fail "A: codex_failover_requested=$(jqf "$dir" '.codex_failover_requested'), expected true"
  [ "$(stub_calls "$dir")" = "1" ] || fail "A: Codex helper invoked $(stub_calls "$dir") time(s), expected 1"
  grep -q -- '--trigger-only' "$dir/state/codex-stub.log" || fail "A: Codex helper not called with --trigger-only; log=$(cat "$dir/state/codex-stub.log")"
  grep -q 'phase4a=true' "$dir/state/codex-stub.log" || fail "A: MERGEPATH_PHASE_4A_GATED not set true; log=$(cat "$dir/state/codex-stub.log")"
  # #2166: the requester refuses a head that does not look final (exit 8)
  # unless the caller allows a moving head. The failover must always be able
  # to hand a rate-limited head to Codex, so it passes the flag explicitly.
  grep -q -- '--allow-moving-head' "$dir/state/codex-stub.log" || fail "A: Codex helper not called with --allow-moving-head (#2166); log=$(cat "$dir/state/codex-stub.log")"
  grep -q '999' "$dir/state/codex-stub.log" || fail "A: PR number not forwarded; log=$(cat "$dir/state/codex-stub.log")"
  [ "$(jqf "$dir" '.disposition')" = proceed_on_codex_clearance ] || fail "A: missing proceed-on-Codex disposition"
  [ ! -s "$dir/state/sleeps.log" ] || fail "A: rate limit slept instead of handing off immediately"
  [ ! -s "$dir/state/posts.log" ] || fail "A: posted a CodeRabbit retry"
  [ "$FAIL" -ne "$before" ] || pass "A: rate-limit fires Codex failover once (--trigger-only, phase4a, PR#) → exit 5, requested:true"
}

# --- Test B: knob OFF → no failover, requested:false ------------------------
test_failover_opt_out() {
  local dir rc before=$FAIL
  dir=$(make_case "optout" 300 0 false)
  rc=$(run_case "$dir" 0)
  [ "$rc" = "5" ] || fail "B: expected exit 5, got $rc; err=$(cat "$dir/err.log")"
  [ "$(jqf "$dir" '.codex_failover_requested')" = "false" ] || fail "B: codex_failover_requested=$(jqf "$dir" '.codex_failover_requested'), expected false"
  [ "$(stub_calls "$dir")" = "0" ] || fail "B: Codex helper invoked $(stub_calls "$dir") time(s) with knob off, expected 0"
  [ "$(jqf "$dir" '.disposition')" = human_attention_required ] || fail "B: unavailable Codex did not request human attention"
  [ "$FAIL" -ne "$before" ] || pass "B: codex_failover_on_rate_limit:false suppresses the failover"
}

# --- Test C: Codex helper no-ops (exit 5) → requested:false -----------------
test_failover_codex_disabled() {
  local dir rc before=$FAIL
  dir=$(make_case "codexoff" 300 0 true)
  rc=$(run_case "$dir" 5)   # stub exits 5 = NO_TRIGGER_REQUESTED
  [ "$rc" = "5" ] || fail "C: expected exit 5, got $rc; err=$(cat "$dir/err.log")"
  [ "$(stub_calls "$dir")" = "1" ] || fail "C: Codex helper invoked $(stub_calls "$dir") time(s), expected 1 (attempted)"
  [ "$(jqf "$dir" '.codex_failover_requested')" = "false" ] || fail "C: codex_failover_requested=$(jqf "$dir" '.codex_failover_requested'), expected false (helper no-op)"
  [ "$FAIL" -ne "$before" ] || pass "C: helper exit 5 (Codex disabled) leaves codex_failover_requested:false"
}

# --- Test D: idempotent across a multi-retry run (FIRED latch) --------------
test_failover_idempotent_across_retries() {
  local dir rc before=$FAIL
  # max_retries=2 + a persistent same-id rate-limit NOTE: iteration 1 detects
  # the NOTE (fires the failover, posts a retry trigger, sleeps the window via
  # the fake clock), later iterations see the SAME comment id and just poll
  # until the max_wait budget elapses (exit 4). The failover must fire once.
  dir=$(make_case "idempotent" 300 2 true)
  rc=$(run_case "$dir" 0)
  [ "$rc" = "5" ] || fail "D: expected immediate exit 5 on persistent NOTE, got $rc; err=$(tail -3 "$dir/err.log")"
  [ "$(stub_calls "$dir")" = "1" ] || fail "D: Codex helper invoked $(stub_calls "$dir") time(s) across the run, expected exactly 1 (latch)"
  [ "$(jqf "$dir" '.codex_failover_requested')" = "true" ] || fail "D: codex_failover_requested=$(jqf "$dir" '.codex_failover_requested'), expected true"
  [ "$FAIL" -ne "$before" ] || pass "D: failover fires exactly once across a multi-poll run (idempotent FIRED latch)"
}

# --- Test E: NEW adaptive rate-limit format (#593) classifies as rate_limit ---
# The regression for #591. Before the fix, classify_comment saw neither
# "rate[- ]limit exceeded" nor the paused marker in this body and fell through
# to `review` → the script exited 0 (cleared) with NO failover, false-clearing
# the gate. With the marker-based classification it behaves exactly like the
# old format: failover fires once, exit 5, requested:true.
test_newformat_fires() {
  local dir rc before=$FAIL
  dir=$(make_case "newfmt-fires" 300 0 true "$NEW_RATE_LIMIT_BODY")
  rc=$(run_case "$dir" 0)
  [ "$rc" = "5" ] || fail "E: expected exit 5 on new-format rate-limit, got $rc; err=$(cat "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "rate_limit_stalled" ] || fail "E: status=$(jqf "$dir" '.status'), expected rate_limit_stalled"
  [ "$(jqf "$dir" '.codex_failover_requested')" = "true" ] || fail "E: codex_failover_requested=$(jqf "$dir" '.codex_failover_requested'), expected true"
  [ "$(stub_calls "$dir")" = "1" ] || fail "E: Codex helper invoked $(stub_calls "$dir") time(s), expected 1"
  [ "$FAIL" -ne "$before" ] || pass "E: new 'Review limit reached' format classifies as rate_limit → failover + exit 5 (not a false-clear)"
}

# --- Test F: NEW format window "Next review available in: N minutes" parsed ---
# max_retries=1 + a generous budget so the loop parses the window and sleeps it
# (logging window=Ns) before looping on the persistent NOTE to the timeout.
test_newformat_window_parsed() {
  local dir rc before=$FAIL
  dir=$(make_case "newfmt-window" 1800 1 true "$NEW_RATE_LIMIT_BODY")
  rc=$(run_case "$dir" 0)
  [ "$rc" = "5" ] || fail "F: expected immediate exit 5 without waiting a retry window, got $rc; err=$(tail -3 "$dir/err.log")"
  [ ! -s "$dir/state/sleeps.log" ] || fail "F: a 13-minute window caused a sleep"
  [ ! -s "$dir/state/posts.log" ] || fail "F: a CodeRabbit retry was posted"
  [ "$(jqf "$dir" '.disposition')" = proceed_on_codex_clearance ] || fail "F: current head was not handed to Codex"
  [ "$FAIL" -ne "$before" ] || pass "F: published 13-minute window never delays Codex substitution"
}


# #2139: drive the actual full clearance checker, then the fixture approval
# step. CI is scoped out here; its production enforcement is covered separately.
test_exact_head_substitution_approval() {
  local fixture="$WORKDIR/substitution-approval" scenario rc expected reviewed before ordinary
  mkdir -p "$fixture"
mkdir -p "$fixture/bin"
mkdir -p "$fixture/scripts/workflow"
cp "$ROOT/scripts/codex-review-check.sh" "$fixture/scripts/codex-review-check.sh"
ln -s "$ROOT/scripts/lib" "$fixture/scripts/lib"
ln -s "$ROOT/scripts/workflow/resolve-codex-verdict-anchors.py" "$fixture/scripts/workflow/resolve-codex-verdict-anchors.py"
# A valid older-content carry-forward cannot satisfy exact-head substitution.
cat > "$fixture/scripts/workflow/external_review_carryforward.sh" <<'STUB'
#!/bin/sh
printf '%s\n' '{"carried":true,"source_time":"2026-06-01T00:01:00Z","source_commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","fingerprint":"same-content"}'
STUB
chmod +x "$fixture/scripts/workflow/external_review_carryforward.sh"
cat > "$fixture/policy.yml" <<'YAML'
author_identity: nathanjohnpayne
external_review_threshold: 300
available_reviewers:
  - nathanpayne-codex
  - nathanpayne-claude
codex:
  enabled: true
  bot_login: "chatgpt-codex-connector[bot]"
  allow_phase_4b_substitute: true
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: discretionary
YAML
cat > "$fixture/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$APPROVAL_FIXTURE/calls"
if [ "$1 $2" = 'pr review' ]; then touch "$APPROVAL_FIXTURE/approved"; exit 0; fi
shift
endpoint=""
for arg in "$@"; do case "$arg" in repos/*|graphql) endpoint="$arg"; break ;; esac; done
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "$endpoint" in
  repos/owner/repo/pulls/999) jq -nc --arg head "$head" '{user:{login:"nathanjohnpayne"},body:"Authoring-Agent: codex",head:{sha:$head,ref:"fix"},base:{ref:"main"},labels:[],additions:10,deletions:1}' ;;
  repos/owner/repo/commits/*) printf '2026-06-01T00:00:00Z' ;;
  repos/owner/repo/pulls/999/reviews)
    reviews=$(case "$CLEARANCE_SCENARIO" in
      clean-review|blocking-review) body='Completed clean review'; [ "$CLEARANCE_SCENARIO" != blocking-review ] || body='**P1** Real blocking finding'
        jq -nc --arg head "$head" --arg body "$body" '[{id:9,user:{login:"chatgpt-codex-connector[bot]"},submitted_at:"2026-06-01T00:01:00Z",commit_id:$head,state:"COMMENTED",body:$body}]' ;;
      substitute-only) jq -nc --arg head "$head" '[{id:9,user:{login:"nathanpayne-claude"},submitted_at:"2026-06-01T00:01:00Z",commit_id:$head,state:"APPROVED",body:"External review approval"}]' ;;
      *) printf '[]' ;;
    esac)
    case "${RE_REQUEST_CASE:-}" in
      review_*) response_time='2026-06-01T00:01:00Z'
        case "$RE_REQUEST_CASE" in *_recovered) response_time='2026-06-01T00:04:00Z' ;; esac
        reviews=$(jq -nc --arg head "$head" --arg t "$response_time" '[{id:9,user:{login:"chatgpt-codex-connector[bot]"},submitted_at:$t,commit_id:$head,state:"COMMENTED",body:"Completed clean review"}]') ;;
      verdict_*) reviews='[]' ;;
    esac
    if [ "${AUDIT_SCENARIO:-none}" = none ]; then printf '%s\n' "$reviews"; exit 0; fi
    jq -nc --argjson reviews "$reviews" --arg head "$head" --arg mode "$AUDIT_SCENARIO" '
      {id:7,user:{login:"nathanpayne-codex"},submitted_at:"2026-06-01T00:02:00Z",
       commit_id:$head,state:"APPROVED",body:("CodeRabbit rate-limited; cleared by Codex on `"+$head+"`.")} as $approval
      | ($approval
          | if $mode == "before" then .submitted_at="2026-06-01T00:00:30Z"
            elif $mode == "same-second" then .submitted_at="2026-06-01T00:01:00Z"
            elif $mode == "after-recovery" then .submitted_at="2026-06-01T00:05:00Z"
            elif $mode == "no-audit" then .body="Reviewed"
            elif $mode == "wrong-sha" then .body="CodeRabbit rate-limited; cleared by Codex on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb."
            elif $mode == "wrong-head" then .commit_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            elif $mode == "malformed-time" then .submitted_at="unreadable"
            elif $mode == "author" then .user.login="nathanjohnpayne"
            else . end) as $selected
      | $reviews+[$selected]
      | if $mode == "withdrawn" or $mode == "malformed-later-opinion" then
          .+[$approval|.id=8|.state="CHANGES_REQUESTED"
             |.submitted_at=(if $mode == "withdrawn" then "2026-06-01T00:03:00Z" else null end)]
        else . end' ;;
  repos/owner/repo/issues/999/comments)
    if [ -n "${RE_REQUEST_CASE:-}" ]; then
      kind=${RE_REQUEST_CASE%%_*};fault=${RE_REQUEST_CASE#*_}
      block_time='2026-06-01T00:03:00Z';response_time='2026-06-01T00:01:00Z';request_time='2026-06-01T00:02:00Z'
      body='You have reached your Codex usage limits for code reviews.'
      case "$fault" in
        not_connected) body='To use Codex here, create a Codex account and connect to GitHub.' ;;
        old-block) block_time='2026-06-01T00:00:30Z' ;;
        recovered) response_time='2026-06-01T00:04:00Z' ;;
        tie) block_time=$response_time;request_time=$response_time ;;
      esac
      jq -nc --arg kind "$kind" --arg head "$head" --arg response "$response_time" \
        --arg request "$request_time" --arg block "$block_time" --arg body "$body" '
        [{id:10,user:{login:"nathanjohnpayne"},created_at:$request,body:"@codex review"},
         {id:11,user:{login:"chatgpt-codex-connector[bot]"},created_at:$block,body:$body}]
        + (if $kind=="verdict" then [{id:8,user:{login:"chatgpt-codex-connector[bot]"},created_at:$response,body:("Codex Review: Didn\u0027t find any major issues.\nReviewed commit: "+$head)}] else [] end)'
      exit 0
    fi
    case "$CLEARANCE_SCENARIO" in clean-review|blocking-review|substitute-only) printf '[]'; exit 0 ;; esac
    case "$CLEARANCE_SCENARIO" in
      usage_limit) body='You have reached your Codex usage limits for code reviews.' ;;
      not_connected) body='To use Codex here, create a Codex account and connect to GitHub.' ;;
      *) body='' ;;
    esac
    if [ -n "$body" ]; then
      jq -nc --arg body "$body" '[{id:8,user:{login:"chatgpt-codex-connector[bot]"},created_at:"2026-06-01T00:01:00Z",body:$body}]'
      exit 0
    fi
    jq -nc --arg sha "${REVIEWED_HEAD:-$head}" '[{id:8,user:{login:"chatgpt-codex-connector[bot]"},created_at:"2026-06-01T00:01:00Z",body:("Codex Review: Didn\u0027t find any major issues.\nReviewed commit: " + $sha)}]' ;;
  repos/owner/repo/pulls/999/comments|repos/owner/repo/issues/999/timeline) printf '[]' ;;
  graphql) printf '{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviewThreads":{"nodes":[],"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' ;;
  *) echo "unexpected fixture endpoint: $endpoint" >&2; exit 99 ;;
esac
STUB
chmod +x "$fixture/bin/gh"
  for scenario in clean-verdict clean-review stale-verdict blocking-review substitute-only; do
    before=$FAIL; expected=0; reviewed=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    case "$scenario" in
      stale-verdict) expected=1; reviewed=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
      blocking-review|substitute-only) expected=1 ;;
    esac
    # Each case gets a separate marker; no actual GitHub writes occur.
    APPROVAL_FIXTURE="$fixture/$scenario"; export APPROVAL_FIXTURE
    mkdir -p "$APPROVAL_FIXTURE"
    rc=0
    GH_TOKEN=fixture-review-token CLEARANCE_SCENARIO="$scenario" REVIEWED_HEAD="$reviewed" \
      PATH="$fixture/bin:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$fixture/policy.yml" \
      CODEX_REVIEW_CHECK_SKIP_CI=1 \
      bash "$fixture/scripts/codex-review-check.sh" --require-codex-on-head 999 owner/repo \
      >"$APPROVAL_FIXTURE/out" 2>"$APPROVAL_FIXTURE/err" || rc=$?
    if [ "$rc" = 0 ]; then
      PATH="$fixture/bin:$PATH" gh pr review 999 --repo owner/repo --approve \
        --body 'CodeRabbit rate-limited; cleared by Codex on aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.'
    fi
    [ "$rc" = "$expected" ] || fail "substitution $scenario: wanted $expected, got $rc; $(tail -3 "$APPROVAL_FIXTURE/err")"
    if [ "$scenario" = stale-verdict ]; then
      ordinary=0
      GH_TOKEN=fixture-review-token CLEARANCE_SCENARIO="$scenario" REVIEWED_HEAD="$reviewed" \
        PATH="$fixture/bin:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$fixture/policy.yml" \
        CODEX_REVIEW_CHECK_SKIP_CI=1 CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 \
        bash "$fixture/scripts/codex-review-check.sh" 999 owner/repo \
        >"$APPROVAL_FIXTURE/control.out" 2>"$APPROVAL_FIXTURE/control.err" || ordinary=$?
      [ "$ordinary" = 0 ] || fail "substitution stale-verdict: known-bad carry-forward control did not clear"
    fi
    if [ "$expected" = 0 ]; then
      [ -f "$APPROVAL_FIXTURE/approved" ] \
        && grep -q 'CodeRabbit rate-limited; cleared by Codex on aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$APPROVAL_FIXTURE/calls" \
        || fail "substitution $scenario: exact-head clearance did not reach an auditable approval"
    else
      [ ! -e "$APPROVAL_FIXTURE/approved" ] || fail "substitution $scenario: invalid evidence reached approval"
    fi
    [ "$FAIL" -ne "$before" ] || pass "substitution $scenario: actual clearance checker controls reviewer approval"
  done
  # A refusal delivered after trigger-only returned must stop a live wait.
  cat > "$fixture/bin/sleep" <<'STUB'
#!/bin/sh
touch "$APPROVAL_FIXTURE/slept"
exit 99
STUB
  chmod +x "$fixture/bin/sleep"
  cat > "$fixture/bin/date" <<'STUB'
#!/bin/sh
if [ "$1" = +%s ]; then printf '1780272000\n'; else exec /bin/date "$@"; fi
STUB
  chmod +x "$fixture/bin/date"
  for scenario in usage_limit not_connected; do
    before=$FAIL;APPROVAL_FIXTURE="$fixture/late-$scenario";export APPROVAL_FIXTURE
    mkdir -p "$APPROVAL_FIXTURE";rc=0
    GH_TOKEN=fixture-review-token CLEARANCE_SCENARIO="$scenario" AUDIT_SCENARIO=before \
      PATH="$fixture/bin:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$fixture/policy.yml" \
      CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN="$fixture/scripts/codex-review-check.sh" \
      CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_WAIT_SECONDS=1800 \
      bash "$ROOT/scripts/coderabbit-automerge-rate-limit-gate.sh" \
        '{"status":"rate_limit_stalled","codex_failover_requested":true}' false 999 owner/repo \
        >"$APPROVAL_FIXTURE/out" 2>"$APPROVAL_FIXTURE/err" || rc=$?
    [ "$rc" = 1 ] || fail "late $scenario: wanted blocked exit 1, got $rc"
    grep -q human_attention_required "$APPROVAL_FIXTURE/err" || fail "late $scenario: missing immediate attention disposition"
    [ ! -f "$APPROVAL_FIXTURE/slept" ] || fail "late $scenario: slept after a provider refusal"
    [ "$FAIL" -ne "$before" ] || pass "late $scenario: real checker stops automatic substitution without sleeping"
  done
  # Existing response/request ordering decides whether a retained response
  # still carries this request. A resolved older block is ordinary pending.
  for scenario in review_usage_limit verdict_usage_limit review_not_connected verdict_not_connected review_old-block verdict_old-block review_recovered verdict_recovered review_tie; do
    before=$FAIL;expected=1;audit=after;attention=true
    case "$scenario" in *_old-block) attention=false ;; *_recovered) expected=0;audit=after-recovery;attention=false ;; esac
    APPROVAL_FIXTURE="$fixture/re-request-$scenario";export APPROVAL_FIXTURE
    mkdir -p "$APPROVAL_FIXTURE";rc=0
    GH_TOKEN=fixture-review-token CLEARANCE_SCENARIO=clean-verdict RE_REQUEST_CASE="$scenario" AUDIT_SCENARIO="$audit" \
      PATH="$fixture/bin:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$fixture/policy.yml" \
      CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN="$fixture/scripts/codex-review-check.sh" \
      CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_WAIT_SECONDS=1800 \
      CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_POLL_SECONDS=0 \
      bash "$ROOT/scripts/coderabbit-automerge-rate-limit-gate.sh" \
        '{"status":"rate_limit_stalled","codex_failover_requested":true}' false 999 owner/repo \
        >"$APPROVAL_FIXTURE/out" 2>"$APPROVAL_FIXTURE/err" || rc=$?
    [ "$rc" = "$expected" ] || fail "re-request $scenario: wanted $expected, got $rc; $(tail -4 "$APPROVAL_FIXTURE/err")"
    actual_attention=false;grep -q human_attention_required "$APPROVAL_FIXTURE/err" && actual_attention=true
    [ "$actual_attention" = "$attention" ] || fail "re-request $scenario: wanted attention=$attention, got $actual_attention"
    [ ! -f "$APPROVAL_FIXTURE/slept" ] || fail "re-request $scenario: unexpectedly slept"
    if [ "$attention" = true ]; then
      ordinary=0
      GH_TOKEN=fixture-review-token CLEARANCE_SCENARIO=clean-verdict RE_REQUEST_CASE="$scenario" AUDIT_SCENARIO="$audit" \
        PATH="$fixture/bin:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$fixture/policy.yml" \
        CODEX_REVIEW_CHECK_SKIP_CI=1 CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE=false \
        bash "$fixture/scripts/codex-review-check.sh" 999 owner/repo \
        >"$APPROVAL_FIXTURE/ordinary.out" 2>"$APPROVAL_FIXTURE/ordinary.err" || ordinary=$?
      [ "$ordinary" = 1 ] || fail "re-request $scenario: ordinary merge-gate contract changed to $ordinary"
    fi
    [ "$FAIL" -ne "$before" ] || pass "re-request $scenario: selected response/request ordering controls immediate refusal"
  done
  # The merge probe runs after approval; the agent probe above runs before it.
  for scenario in none before same-second after no-audit wrong-sha wrong-head withdrawn malformed-time malformed-later-opinion author; do
    before=$FAIL;expected=1;[ "$scenario" != after ] || expected=0
    APPROVAL_FIXTURE="$fixture/audit-$scenario";export APPROVAL_FIXTURE
    mkdir -p "$APPROVAL_FIXTURE";rc=0
    GH_TOKEN=fixture-review-token CLEARANCE_SCENARIO=clean-verdict AUDIT_SCENARIO="$scenario" \
      PATH="$fixture/bin:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$fixture/policy.yml" \
      CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN="$fixture/scripts/codex-review-check.sh" \
      CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_WAIT_SECONDS=0 \
      CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_POLL_SECONDS=0 \
      bash "$ROOT/scripts/coderabbit-automerge-rate-limit-gate.sh" \
        '{"status":"rate_limit_stalled","codex_failover_requested":true}' false 999 owner/repo \
        >"$APPROVAL_FIXTURE/out" 2>"$APPROVAL_FIXTURE/err" || rc=$?
    [ "$rc" = "$expected" ] || fail "approval audit $scenario: wanted $expected, got $rc; $(tail -3 "$APPROVAL_FIXTURE/err")"
    [ "$FAIL" -ne "$before" ] || pass "approval audit $scenario: real automatic gate enforces later audited approval"
  done
}

test_failover_exact_head_request_and_known_blocks() {
  local dir rc reason before=$FAIL
  dir=$(make_case "automatic-content-free" 300 0 true)
  rc=$(MERGEPATH_CODEX_AUTO_TRIGGER=true run_case "$dir" 0)
  [ "$rc" = 5 ] && [ -f "$dir/state/codex-stub.log.posted" ] \
    && grep -q 'auto=false' "$dir/state/codex-stub.log" \
    || fail "exact-head substitution was suppressed as content-free"
  [ "$FAIL" -ne "$before" ] || pass "automatic failover requests this head despite inherited carry-forward suppression"
  for reason in usage_limit not_connected; do
    before=$FAIL
    dir=$(make_case "known-$reason" 300 0 true)
    rc=$(CODEX_STUB_BLOCKED="$reason" run_case "$dir" 0)
    [ "$rc" = 5 ] && [ "$(jqf "$dir" '.codex_failover_requested')" = false ] \
      && [ "$(jqf "$dir" '.disposition')" = human_attention_required ] \
      && [ ! -s "$dir/state/sleeps.log" ] \
      || fail "known $reason block did not immediately require human attention"
    [ "$FAIL" -ne "$before" ] || pass "known $reason yields human attention despite a posted request"
  done
}

test_failover_exact_head_request_and_known_blocks
test_failover_fires
test_failover_opt_out
test_failover_codex_disabled
test_failover_idempotent_across_retries
test_newformat_fires
test_newformat_window_parsed
test_exact_head_substitution_approval

echo "----"
echo "test_coderabbit_wait_codex_failover: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
