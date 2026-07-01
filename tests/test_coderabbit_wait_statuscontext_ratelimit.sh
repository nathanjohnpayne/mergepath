#!/usr/bin/env bash
# Regression coverage for coderabbit-wait.sh's StatusContext fast-path vs a
# rate-limited CodeRabbit (#596).
#
# CodeRabbit flips its commit StatusContext ("CodeRabbit" context) to `success`
# even when it RATE-LIMITS and performs no review — typically ~1s AFTER posting
# the rate-limit notice. With trust_status_context_for_clearance:true the
# pre-loop fast-path trusts that success. The #446 guard is supposed to suppress
# it when the latest HEAD-referencing comment is a rate_limit/paused notice, but
# it previously required the comment to be at/after the status; the 1-second
# ordering (comment@T, status@T+1) defeated that and false-cleared (exit 0) —
# the #595 dogfood that merged with no CodeRabbit review.
#
# Runs the real helper from a temp repo with stubbed gh/date/sleep and a stub
# codex-review-request.sh, so it makes no GitHub writes. Verifies:
#   1. #596: status success @T+1 + a HEAD-referencing rate-limit comment @T
#      SUPPRESSES the fast-path -> the wait keeps going, fires the Codex
#      failover, and exits 5 (rate_limit_stalled), NOT 0 (cleared).
#   2. Control: status success + a genuine review comment (class=review) on HEAD
#      still CLEARS via the fast-path (exit 0). The fix must not over-suppress.
#
# Bash 3.2 portable. Mirrors tests/test_coderabbit_wait_codex_failover.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-wait-statusctx.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# head_time is the head-commit committer date; the CodeRabbit StatusContext
# success is stamped 1s LATER to reproduce the #595 comment-then-status race.
HEAD_TIME='2026-06-04T00:00:00Z'
STATUS_TIME='2026-06-04T00:00:01Z'

# A new-format rate-limit notice that REFERENCES the current HEAD (head-sha),
# so the HEAD-referencing branch of status_context_fast_path_blocked_by_comment
# is exercised.
RATE_LIMIT_BODY_HEADREF='<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->

> [!WARNING]
> ## Review limit reached
>
> Reviewing files that changed between the base and head-sha.
>
> **Next review available in:** **13 minutes**

<!-- end of auto-generated comment: rate limited by coderabbit.ai -->'

# A genuine clean review summary (class=review), no rate-limit marker.
REVIEW_BODY_CLEAN='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->

**Actionable comments posted: 0**

Reviewed everything up to head-sha. LGTM!'

# make_case <name> <comment_body> [status_time]
#   status_time overrides when the CodeRabbit StatusContext success was created
#   (default STATUS_TIME = 1s after the comment). Pass a far-later time to model
#   a genuine re-review success beyond the grace window.
make_case() {
  local name=$1 comment_body=$2 status_time=${3:-$STATUS_TIME}
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/coderabbit-wait.sh" "$dir/scripts/coderabbit-wait.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$dir/scripts/lib/reviewers-helpers.sh"
  chmod +x "$dir/scripts/coderabbit-wait.sh"

  printf '%s' "$comment_body" >"$dir/state/comment-body.txt"

  cat >"$dir/.github/review-policy.yml" <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
  max_wait_seconds: 300
  status_probe_enabled: false
  status_probe_wait_seconds: 0
  max_rate_limit_retries: 0
  codex_failover_on_rate_limit: true
  wallclock_freshness_window_seconds: 999999999
  trust_status_context_for_clearance: true
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

  # gh stub. The CodeRabbit StatusContext on head-sha is `success`, created 1s
  # AFTER the (persistent, same-id) issue comment served from comment-body.txt.
  cat >"$dir/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
bot='coderabbitai[bot]'
head_time='$HEAD_TIME'
status_time='$status_time'
state_dir=\${CODERABBIT_TEST_STATE_DIR:?}
[ "\${1:-}" = "api" ] || { echo "unexpected gh command: \$*" >&2; exit 99; }
shift
method="GET"
if [ "\${1:-}" = "--method" ]; then method=\${2:-}; shift 2; fi
if [ "\${1:-}" = "--paginate" ]; then shift; fi
endpoint=\${1:-}; shift || true
if [ "\$method" = "POST" ]; then
  case "\$endpoint" in
    repos/owner/repo/issues/999/comments)
      printf '{"id":9001,"created_at":"%s","body":"ack"}\n' "\$head_time" ;;
    *) echo "unexpected gh api POST endpoint: \$endpoint" >&2; exit 99 ;;
  esac
  exit 0
fi
case "\$endpoint" in
  repos/owner/repo/pulls/999) printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/commits/head-sha)
    if [ "\${1:-}" = "--jq" ]; then printf '%s\n' "\$head_time"
    else printf '{"commit":{"committer":{"date":"%s"}}}\n' "\$head_time"; fi ;;
  repos/owner/repo/commits/head-sha/statuses)
    jq -cn --arg bot "\$bot" --arg t "\$status_time" \
      '[{context:"CodeRabbit",creator:{login:\$bot},state:"success",created_at:\$t}]' ;;
  repos/owner/repo/issues/999/timeline) printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews) printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments) printf '[]\n' ;;
  repos/owner/repo/issues/999/comments)
    body=\$(cat "\$state_dir/comment-body.txt")
    jq -cn --arg bot "\$bot" --arg t "\$head_time" --arg body "\$body" \
      '[{id:7701,user:{login:\$bot},created_at:\$t,updated_at:\$t,body:\$body}]' ;;
  *) echo "unexpected gh api endpoint: \$endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  cat >"$dir/bin/codex-request-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'phase4a=%s args=[%s]\n' "${MERGEPATH_PHASE_4A_GATED:-unset}" "$*" >>"${CODEX_STUB_LOG:?}"
echo '{"trigger_only":true,"trigger_posted":true,"trigger_requested":true}'
exit 0
EOF
  chmod +x "$dir/bin/codex-request-stub.sh"

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
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

jqf() { jq -r "$2" "$1/out.json"; }
stub_calls() {
  local dir=$1
  if [ -f "$dir/state/codex-stub.log" ]; then wc -l <"$dir/state/codex-stub.log" | tr -d ' '
  else printf '0\n'; fi
}

# --- Test 1: #596 — HEAD-ref rate-limit @T + status success @T+1 → suppressed --
# Before the fix this exited 0 (cleared) via the fast-path with no failover.
test_headref_ratelimit_suppresses_status() {
  local dir rc before=$FAIL
  dir=$(make_case "headref-rl" "$RATE_LIMIT_BODY_HEADREF")
  rc=$(run_case "$dir")
  [ "$rc" != "0" ] || fail "1: fast-path FALSE-CLEARED (exit 0) over a HEAD-referencing rate-limit notice; err=$(cat "$dir/err.log")"
  [ "$rc" = "5" ] || fail "1: expected exit 5 (rate_limit_stalled after suppression), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "rate_limit_stalled" ] || fail "1: status=$(jqf "$dir" '.status'), expected rate_limit_stalled"
  [ "$(jqf "$dir" '.codex_failover_requested')" = "true" ] || fail "1: codex_failover_requested=$(jqf "$dir" '.codex_failover_requested'), expected true (failover fired after suppression)"
  [ "$(stub_calls "$dir")" = "1" ] || fail "1: Codex failover invoked $(stub_calls "$dir") time(s), expected 1"
  grep -q 'near-simultaneous rate-limit status flip' "$dir/err.log" || fail "1: expected the #596 suppression log line; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "1: #596 — near-simultaneous StatusContext success does not clear a HEAD-referencing rate-limit notice → failover + exit 5"
}

# --- Test 3: #596 escape — a genuinely LATER success (beyond grace) clears ----
# The comment is a HEAD-referencing rate-limit notice at T, but the success
# StatusContext lands 2h later — well beyond STATUS_SUCCESS_GRACE_SECONDS — so
# it is a genuine (possibly silent, per #221) re-review of HEAD and must clear.
test_headref_later_success_clears() {
  local dir rc before=$FAIL
  dir=$(make_case "headref-later" "$RATE_LIMIT_BODY_HEADREF" "2026-06-04T02:00:00Z")
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "3: expected exit 0 (cleared) for a genuine later success, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "3: status=$(jqf "$dir" '.status'), expected cleared"
  [ "$(stub_calls "$dir")" = "0" ] || fail "3: failover should not fire on a genuine-later clearance, fired $(stub_calls "$dir")"
  grep -q 'remains authoritative' "$dir/err.log" || fail "3: expected the authoritative-later-success log; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "3: #596 escape — a StatusContext success beyond the grace window (genuine later re-review) still clears"
}

# --- Test 2: control — genuine review + status success STILL clears ----------
test_headref_review_still_clears() {
  local dir rc before=$FAIL
  dir=$(make_case "headref-review" "$REVIEW_BODY_CLEAN")
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "2: expected exit 0 (cleared) for a genuine review + status success, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "2: status=$(jqf "$dir" '.status'), expected cleared"
  [ "$(stub_calls "$dir")" = "0" ] || fail "2: Codex failover should NOT fire on a clean clearance, fired $(stub_calls "$dir")"
  [ "$FAIL" -ne "$before" ] || pass "2: control — a genuine review comment + StatusContext success still clears via the fast-path (no over-suppression)"
}

# --- Test 4: #599 P2 — success past the base grace but INSIDE the published --
# rate-limit window is still suppressed. The HEAD-ref notice carries "Next
# review available in: 13 minutes" (780s), so the effective grace widens to
# 780+30=810s. A StatusContext success at T+121s is beyond the 120s base grace
# (a fixed grace would false-clear it) but well inside the promised window, so
# CodeRabbit cannot have reviewed yet → suppress → failover + exit 5.
test_headref_within_published_window_suppresses() {
  local dir rc before=$FAIL
  dir=$(make_case "headref-window" "$RATE_LIMIT_BODY_HEADREF" "2026-06-04T00:02:01Z")  # T+121s
  rc=$(run_case "$dir")
  [ "$rc" = "5" ] || fail "4: expected exit 5 (suppressed within published window), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "rate_limit_stalled" ] || fail "4: status=$(jqf "$dir" '.status'), expected rate_limit_stalled"
  grep -q 'within the 810s window' "$dir/err.log" || fail "4: expected the published-window (810s) suppression log; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "4: #599 — success past the 120s base grace but inside the published 13-minute window is still suppressed (window-aware grace)"
}

test_headref_ratelimit_suppresses_status
test_headref_review_still_clears
test_headref_later_success_clears
test_headref_within_published_window_suppresses

echo "----"
echo "test_coderabbit_wait_statuscontext_ratelimit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
