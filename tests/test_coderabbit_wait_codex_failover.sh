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
printf 'phase4a=%s args=[%s]\n' "${MERGEPATH_PHASE_4A_GATED:-unset}" "$*" >>"${CODEX_STUB_LOG:?}"
echo '{"trigger_only":true,"trigger_posted":true,"trigger_requested":true}'
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
  grep -q '999' "$dir/state/codex-stub.log" || fail "A: PR number not forwarded; log=$(cat "$dir/state/codex-stub.log")"
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
  [ "$rc" = "4" ] || fail "D: expected exit 4 (timeout on persistent NOTE), got $rc; err=$(tail -3 "$dir/err.log")"
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
  [ "$rc" = "4" ] || fail "F: expected exit 4 (timeout after one retry), got $rc; err=$(tail -3 "$dir/err.log")"
  grep -q 'window=780s' "$dir/err.log" || fail "F: expected parsed window=780s (13 min); log=$(grep -i window "$dir/err.log" || echo none)"
  [ "$FAIL" -ne "$before" ] || pass "F: 'Next review available in: 13 minutes' parsed to a 780s window"
}

test_failover_fires
test_failover_opt_out
test_failover_codex_disabled
test_failover_idempotent_across_retries
test_newformat_fires
test_newformat_window_parsed

echo "----"
echo "test_coderabbit_wait_codex_failover: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
