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

# A PR-level summary that classifies as `review` and carries a blocking marker
# ONLY in the summary body — the #535 summary-only class. There are no inline
# findings on this head at all, so `count_potential_issues_for_sha` returns 0
# and only the summary surface can produce a `findings` verdict (#877).
REVIEW_BODY_SUMMARY_ONLY_MARKER='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->

**Actionable comments posted: 1**

<details>
<summary>scripts/foo.sh (1)</summary>

_🔒 Security & Privacy_ | _🟠 Major_ | _⚡ Quick win_

**Reject the diagnostic bypass in merge-gate callers.**

</details>'

# Two offsets from the wallclock the `date +%s` stub reports — epoch
# 2000000000, i.e. 2033-05-18T03:33:20Z. Used by the #891/#912 aged-notice
# cases: the notice sits 40 minutes in the past, outside a 1800s freshness
# floor, while the window it publishes (59 minutes) is still open.
NOTICE_AGED_TIME='2033-05-18T02:53:20Z'   # stubbed NOW - 2400s
STATUS_AFTER_NOTICE='2033-05-18T03:20:00Z'

# The same 40-minutes-ago instant as NOTICE_AGED_TIME, named for the surface it
# stamps in the #877 fast-path cases: a PR-level review SUMMARY that has sat
# unchanged on an unchanged head for longer than the 1800s wallclock freshness
# floor. Nothing about the head changed; only the clock moved.
SUMMARY_AGED_TIME='2033-05-18T02:53:20Z'   # stubbed NOW - 2400s
# A summary belonging to a PRIOR head: stamped BEFORE the head commit's own
# committer date, so it is stale by HEAD IDENTITY and not merely by wall clock.
SUMMARY_PRIOR_HEAD_TIME='2026-06-03T23:00:00Z'

# The #936 SELECTION case: a head-anchored blocking summary, then a LATER
# non-review notice, then a StatusContext success later still. The notice is
# newer than the summary (so it wins a class-blind "newest bot comment" pick)
# but was CREATED before the success (so the #446 arbitration reads it as stale
# and leaves the fast path unsuppressed) — the exact overlap in which the fast
# path grades the notice and never sees the summary underneath it.
SUMMARY_ON_HEAD_TIME='2026-06-04T00:00:10Z'
NOTICE_AFTER_SUMMARY_TIME='2026-06-04T00:00:20Z'
STATUS_AFTER_BOTH_TIME='2026-06-04T00:30:00Z'

# The live #891 / #912 notice: a 59-minute published window, longer than the
# 1800s wallclock freshness floor, so it ages out of the anchored comment scan
# while the rate limit it announces is still in force. No HEAD reference — the
# #596 HEAD-referencing branch must not be what saves this case.
RATE_LIMIT_BODY_LONG_WINDOW='<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->

> [!WARNING]
> ## Review limit reached
>
> **Next review available in:** **59 minutes**

<!-- end of auto-generated comment: rate limited by coderabbit.ai -->'

# make_case <name> <comment_body> [status_time] [status_description]
#          [comment_time] [freshness_window]
#   status_time         when the CodeRabbit StatusContext success was created
#                       (default STATUS_TIME = 1s after the comment). Pass a
#                       far-later time to model a genuine re-review success
#                       beyond the grace window.
#   status_description  the status' `description` string (default: absent, the
#                       shape every pre-#891 fixture modelled). CodeRabbit
#                       publishes its rate-limited state AS a success and puts
#                       the truth only here.
#   comment_time        created_at/updated_at for the single issue comment
#                       (default HEAD_TIME).
#   freshness_window    coderabbit.wallclock_freshness_window_seconds (default
#                       999999999 = effectively never ages a comment out).
#   second_body         an OPTIONAL second issue comment (id 7702), served
#                       alongside the first. Empty (default) keeps the
#                       single-comment shape every earlier fixture models.
#   second_time         created_at/updated_at for that second comment (default
#                       HEAD_TIME). Stamp it after `comment_time` to model a
#                       later bot comment sitting ABOVE an earlier one.
#   An EMPTY comment_body serves an empty issue-comments list — the #897 shape,
#   where the status description is the ONLY evidence of the rate limit.
make_case() {
  local name=$1 comment_body=$2 status_time=${3:-$STATUS_TIME}
  local status_description=${4:-} comment_time=${5:-$HEAD_TIME}
  local freshness_window=${6:-999999999}
  local second_body=${7:-} second_time=${8:-$HEAD_TIME}
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/coderabbit-wait.sh" "$dir/scripts/coderabbit-wait.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$dir/scripts/lib/reviewers-helpers.sh"
  # Hard-required by coderabbit-wait.sh since #837: the potential-issue count
  # grades findings with the shared coderabbit_tier_of.
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"
  chmod +x "$dir/scripts/coderabbit-wait.sh"

  printf '%s' "$comment_body" >"$dir/state/comment-body.txt"
  printf '%s' "$second_body" >"$dir/state/comment-body-2.txt"

  cat >"$dir/.github/review-policy.yml" <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
  max_wait_seconds: 300
  status_probe_enabled: false
  status_probe_wait_seconds: 0
  max_rate_limit_retries: 0
  codex_failover_on_rate_limit: true
  wallclock_freshness_window_seconds: $freshness_window
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
status_description='$status_description'
comment_time='$comment_time'
second_time='$second_time'
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
    # An EMPTY status_description omits the key entirely — the shape every
    # pre-#891 fixture modelled, and the one the description guard must keep
    # clearing so the #221 fast path survives.
    if [ -n "\$status_description" ]; then
      jq -cn --arg bot "\$bot" --arg t "\$status_time" --arg d "\$status_description" \
        '[{context:"CodeRabbit",creator:{login:\$bot},state:"success",created_at:\$t,description:\$d}]'
    else
      jq -cn --arg bot "\$bot" --arg t "\$status_time" \
        '[{context:"CodeRabbit",creator:{login:\$bot},state:"success",created_at:\$t}]'
    fi ;;
  repos/owner/repo/issues/999/timeline) printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews) printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments) printf '[]\n' ;;
  repos/owner/repo/issues/999/comments)
    # CODERABBIT_TEST_FAIL_ISSUES_AFTER=<n>: serve the first n reads normally,
    # then fail. Models a transient API failure landing between the fast path's
    # notice scan and its summary-marker read.
    n=0
    if [ -f "\$state_dir/issues-read-count" ]; then n=\$(cat "\$state_dir/issues-read-count"); fi
    n=\$((n + 1)); printf '%s\n' "\$n" >"\$state_dir/issues-read-count"
    if [ -n "\${CODERABBIT_TEST_FAIL_ISSUES_AFTER:-}" ] && [ "\$n" -gt "\$CODERABBIT_TEST_FAIL_ISSUES_AFTER" ]; then
      echo "simulated issue-comments API failure" >&2
      exit 44
    fi
    # CODERABBIT_TEST_ISSUES_MALFORMED_AFTER=<n>: serve the first n reads
    # normally, then serve a well-formed JSON ARRAY whose elements are not
    # comment objects. fetch_api_array's own \`jq -s 'add // []'\` accepts it
    # (it is one array), so the read SUCCEEDS and the failure lands on the
    # per-comment jq that derives the summary body — the Codex P1 shape on #936.
    if [ -n "\${CODERABBIT_TEST_ISSUES_MALFORMED_AFTER:-}" ] && [ "\$n" -gt "\$CODERABBIT_TEST_ISSUES_MALFORMED_AFTER" ]; then
      printf '[42]\n'
      exit 0
    fi
    body=\$(cat "\$state_dir/comment-body.txt")
    body2=""
    if [ -f "\$state_dir/comment-body-2.txt" ]; then body2=\$(cat "\$state_dir/comment-body-2.txt"); fi
    if [ -z "\$body" ]; then printf '[]\n'; else
      jq -cn --arg bot "\$bot" --arg t "\$comment_time" --arg body "\$body" \
        --arg t2 "\$second_time" --arg body2 "\$body2" \
        '[{id:7701,user:{login:\$bot},created_at:\$t,updated_at:\$t,body:\$body}]
         + (if \$body2 == "" then []
            else [{id:7702,user:{login:\$bot},created_at:\$t2,updated_at:\$t2,body:\$body2}]
            end)'
    fi ;;
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

# --- Test 5: #877 — the fast path clears past a summary-only blocking marker -
# StatusContext success, ZERO inline findings, and the only blocking marker is
# in the PR-level summary body (the #535 class). The comment classifies as
# `review`, so status_context_fast_path_blocked_by_comment — which suppresses
# only rate_limit/paused/in_progress — does not stop it, and the fast path's
# inline-only scan returns 0. Pre-fix: cleared, exit 0, on a head that yields
# `findings` (exit 2) through the polling `review` arm and both probe verdict
# sites.
test_summary_only_marker_is_findings_not_cleared() {
  local dir rc before=$FAIL
  dir=$(make_case "summary-only-marker" "$REVIEW_BODY_SUMMARY_ONLY_MARKER")
  rc=$(run_case "$dir")
  [ "$rc" != "0" ] || fail "5: fast-path FALSE-CLEARED (exit 0) over a summary-only blocking marker; err=$(tail -4 "$dir/err.log")"
  [ "$rc" = "2" ] || fail "5: expected exit 2 (findings), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "findings" ] || fail "5: status=$(jqf "$dir" '.status'), expected findings"
  [ "$(jqf "$dir" '.review.endpoint')" = "status_context" ] || fail "5: review.endpoint=$(jqf "$dir" '.review.endpoint'), expected status_context (the verdict must come from the fast path, not a later poll)"
  grep -q 'PR-level summary carries a blocking marker' "$dir/err.log" || fail "5: expected the #877 summary-marker log line; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "5: #877 — the StatusContext fast path applies the summary-only OR-sibling and emits findings (exit 2)"
}

# --- Test 6: #897 — success whose description is 'Review rate limited', with -
# NO rate-limit comment anywhere. The live #884 capture on head c00abf0: zero
# review objects, zero CodeRabbit comments, and the ONLY evidence of the rate
# limit is the status description. The #595/#596 guard keys on a notice
# COMMENT, so it never fired and the success sailed through the fast path.
test_ratelimited_description_without_notice_never_clears() {
  local dir rc before=$FAIL
  dir=$(make_case "desc-ratelimited-no-comment" "" "$STATUS_TIME" "Review rate limited")
  rc=$(run_case "$dir")
  [ "$rc" != "0" ] || fail "6: FALSE-CLEARED (exit 0) on a 'Review rate limited' success with no notice comment; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" != "cleared" ] || fail "6: status=cleared on a head CodeRabbit declined to review"
  [ "$rc" = "4" ] || fail "6: expected exit 4 (timeout — nothing else on the PR to verdict on), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'does not name a completed review' "$dir/err.log" || fail "6: expected the description-guard log line; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "6: #897 — a success described 'Review rate limited' is not clearance even with no notice comment"
}

# --- Test 7: description guard — an UNRECOGNIZED non-empty description ------
# The guard is a positive test (clear only on a completed-review description),
# not a deny-list of known refusals, because #891/#912 are exactly the failure
# of a guard with no scope over a wording it had never seen.
test_unknown_description_does_not_clear() {
  local dir rc before=$FAIL
  dir=$(make_case "desc-unknown" "" "$STATUS_TIME" "Review skipped")
  rc=$(run_case "$dir")
  [ "$rc" != "0" ] || fail "7: FALSE-CLEARED (exit 0) on an unrecognized status description; err=$(tail -4 "$dir/err.log")"
  [ "$rc" = "4" ] || fail "7: expected exit 4 (timeout), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "7: an unrecognized non-empty StatusContext description suppresses the fast path (positive test, not a deny-list)"
}

# --- Test 8: control — 'Review completed' still clears ----------------------
# The #912 capture of a genuine run (af8496f @03:06:48Z). Guarding the
# description must not cost the #221 fast path.
test_completed_description_still_clears() {
  local dir rc before=$FAIL
  dir=$(make_case "desc-completed" "$REVIEW_BODY_CLEAN" "$STATUS_TIME" "Review completed")
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "8: expected exit 0 (cleared) for a 'Review completed' success, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "8: status=$(jqf "$dir" '.status'), expected cleared"
  [ "$(jqf "$dir" '.review.endpoint')" = "status_context" ] || fail "8: expected the verdict to come from the fast path, got endpoint=$(jqf "$dir" '.review.endpoint')"
  [ "$FAIL" -ne "$before" ] || pass "8: control — a success described 'Review completed' still clears via the fast path"
}

# --- Test 9: #891/#912 — an aged-out notice whose window is still OPEN ------
# The #909 capture. The notice is 40 minutes old — outside the 1800s wallclock
# freshness floor — so the anchored comment scan stops seeing it, while the
# 59-minute window it published is still in force. The status success predates
# nothing useful: it was set while rate-limited and never updated. The
# description here is DELIBERATELY the completed-review one, so this case
# isolates the window rule from the description guard: with only the
# description fix, the second run on #909 would still have cleared had
# CodeRabbit stamped its stale success differently.
test_aged_notice_with_open_window_suppresses() {
  local dir rc before=$FAIL
  dir=$(make_case "aged-open-window" "$RATE_LIMIT_BODY_LONG_WINDOW" \
    "$STATUS_AFTER_NOTICE" "Review completed" "$NOTICE_AGED_TIME" 1800)
  rc=$(run_case "$dir")
  [ "$rc" != "0" ] || fail "9: FALSE-CLEARED (exit 0) after the rate-limit notice aged out of the freshness window; err=$(tail -4 "$dir/err.log")"
  [ "$rc" = "5" ] || fail "9: expected exit 5 (rate_limit_stalled), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "rate_limit_stalled" ] || fail "9: status=$(jqf "$dir" '.status'), expected rate_limit_stalled"
  # #891 acceptance 4: the failover that compensates for a lost CodeRabbit
  # round came back `false` on the #909 false clear. It must still fire.
  [ "$(jqf "$dir" '.codex_failover_requested')" = "true" ] || fail "9: codex_failover_requested=$(jqf "$dir" '.codex_failover_requested'), expected true"
  [ "$(stub_calls "$dir")" = "1" ] || fail "9: Codex failover invoked $(stub_calls "$dir") time(s), expected 1"
  grep -q 'published window has NOT expired' "$dir/err.log" || fail "9: expected the published-window suppression log; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "9: #891/#912 — an aged-out notice with an OPEN published window still governs → no clear, failover fires, exit 5"
}

# --- Test 10: escape — an aged-out notice whose window has EXPIRED ----------
# The suppression is scoped by the PUBLISHED window, not by "a notice exists".
# Same aged timestamps as test 9, but a DIFFERENT notice body:
# RATE_LIMIT_BODY_HEADREF, whose published window is 13 minutes (780s + 30s
# buffer = 810s) and so long expired at 2400s elapsed. Because that body names
# HEAD_SHA, the #596 HEAD-referencing arbitration participates here too, and
# the head clears exactly as it did before — the boundary that keeps this rule
# from becoming an unbounded block.
test_aged_notice_with_expired_window_clears() {
  local dir rc before=$FAIL
  dir=$(make_case "aged-expired-window" "$RATE_LIMIT_BODY_HEADREF" \
    "$STATUS_AFTER_NOTICE" "Review completed" "$NOTICE_AGED_TIME" 1800)
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "10: expected exit 0 (cleared) once the published window expired, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "10: status=$(jqf "$dir" '.status'), expected cleared"
  [ "$(stub_calls "$dir")" = "0" ] || fail "10: failover should not fire once the window expired, fired $(stub_calls "$dir")"
  [ "$FAIL" -ne "$before" ] || pass "10: escape — an aged notice whose published window has EXPIRED no longer suppresses (the rule is window-scoped, not notice-scoped)"
}

# --- Test 11: #888 — a flag-shaped REPO positional is a usage error ---------
# The leading-flag scan ends at the first non-option argument, so
# `coderabbit-wait.sh 999 --probe` read `--probe` as REPO and died with
# `failed to fetch PR metadata: 404`. A repo name cannot begin with `-`.
test_trailing_probe_flag_is_usage_error() {
  local dir rc=0 before=$FAIL
  dir=$(make_case "trailing-probe-flag" "$REVIEW_BODY_CLEAN")
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      ./scripts/coderabbit-wait.sh 999 --probe \
      >"$dir/usage.out" 2>"$dir/usage.err"
  ) || rc=$?
  [ "$rc" = "3" ] || fail "11: expected exit 3 (usage), got $rc; err=$(tail -3 "$dir/usage.err")"
  grep -q 'flag-shaped argument' "$dir/usage.err" || fail "11: expected a usage error naming the flag-shaped argument; err=$(cat "$dir/usage.err")"
  grep -q -- '--probe <PR_NUMBER>' "$dir/usage.err" || fail "11: usage error should name the working form; err=$(cat "$dir/usage.err")"
  grep -q 'failed to fetch PR metadata' "$dir/usage.err" && fail "11: still reached the 404 path instead of failing on the argument"
  [ "$FAIL" -ne "$before" ] || pass "11: #888 — 'coderabbit-wait.sh 999 --probe' is a usage error naming the leading-flag form, not a 404"
}

# --- Test 12: the description predicate, unit ------------------------------
# Extracted by sentinel and sourced directly, so the vocabulary boundaries are
# assertable without a whole stubbed run. Same extract-and-source pattern as
# tests/test_coderabbit_wait_status_probe.sh's helper units.
test_status_description_predicate_unit() {
  local snip="$WORKDIR/status-desc-helpers.sh" bad="" before=$FAIL
  awk '/^# BEGIN coderabbit_status_description_helpers$/{f=1;next} /^# END coderabbit_status_description_helpers$/{f=0} f' \
    "$ROOT/scripts/coderabbit-wait.sh" >"$snip"
  # shellcheck disable=SC1090
  . "$snip"
  # The permitted set: empty (the field is optional metadata; refusing it would
  # disable the #221 fast path for every status posted without one) and the
  # completed-review family in either casing.
  crw_status_description_permits_clearance ""                  || bad="$bad empty"
  crw_status_description_permits_clearance "Review completed"   || bad="$bad completed"
  crw_status_description_permits_clearance "review complete"    || bad="$bad complete-lower"
  # Surrounding whitespace is transport noise, not vocabulary.
  crw_status_description_permits_clearance "  Review completed  " || bad="$bad padded"
  # The three live refusal/pending descriptions.
  crw_status_description_permits_clearance "Review rate limited" && bad="$bad rate-limited"
  crw_status_description_permits_clearance "Review in progress"  && bad="$bad in-progress"
  crw_status_description_permits_clearance "Review queued"       && bad="$bad queued"
  # A wording nobody has shipped: unknown must NOT clear, or the guard is a
  # deny-list again.
  crw_status_description_permits_clearance "Review quota exhausted" && bad="$bad unknown"
  # Codex P1 on #936: the predicate matched `review complete` as a SUBSTRING,
  # so every one of these — two of which state the review did NOT happen, and
  # the third that it has not finished — satisfied the guard that exists to
  # reject them. An exact allowlist over the normalized string is the only
  # shape where a longer wording cannot inherit a shorter one's clearance.
  crw_status_description_permits_clearance "No review completed"     && bad="$bad negated"
  crw_status_description_permits_clearance "Review completely skipped" && bad="$bad adverb"
  crw_status_description_permits_clearance "Review completion pending" && bad="$bad pending"
  # The same failure from the other side: a prefix-anchored fix would still
  # accept anything that STARTS with the permitted phrase.
  crw_status_description_permits_clearance "Review complete — 0 files reviewed" && bad="$bad suffixed"
  [ -z "$bad" ] || fail "12: description predicate wrong on:$bad"
  [ "$FAIL" -ne "$before" ] || pass "12: crw_status_description_permits_clearance — only empty and the exact completed-review wordings clear; substring near-misses, refusals and unknown wordings do not"
}

# --- Test 15: a failed summary read must not read as "no summary finding" ---
# CodeRabbit 🟠 Major on #936. `summary_body_has_potential_issue_marker` is used
# as an `if` condition, and `fetch_api_array`'s `die 3` exits only its own
# command substitution — so a dead API left the helper grading an empty body,
# `summary_blocking_marker_present ""` returned false, and the fast path
# CLEARED. That is the same false clear on the very route #877 added the check
# to close. The read now propagates rc 3 and both call sites die 3.
#
# The stub serves the first issue-comments read (the fast path's notice scan,
# which finds a clean review comment and does not suppress) and fails every
# read after it — so the failure lands exactly on the summary-marker read.
test_failed_summary_read_does_not_clear() {
  local dir rc=0 before=$FAIL
  dir=$(make_case "summary-read-failure" "$REVIEW_BODY_CLEAN" "$STATUS_TIME" "Review completed")
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_FAIL_ISSUES_AFTER=1 \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  [ "$rc" != "0" ] || fail "15: FALSE-CLEARED (exit 0) after the summary read failed; err=$(tail -4 "$dir/err.log")"
  [ "$rc" = "3" ] || fail "15: expected exit 3 (infra), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'refusing to report a clearance' "$dir/err.log" || fail "15: expected the fail-closed summary-read message; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "15: a failed PR-level summary read is exit 3 (infra), never a clearance"
}

# --- Test 14: the window rule is scoped to the arbitration's BLIND SPOT -----
# Same notice and status as test 9, but with a freshness window wide enough
# that the notice IS admitted to the anchored scan. The existing arbitration
# then governs and reaches its own answer — here the #446 branch, where an
# unscoped notice CREATED before the success is stale and does not suppress,
# so the head clears. A window rule that ignored the status timestamp would
# override that and suppress forever; scripts/ci/check_canonical_bugs_263caf3
# catches the same regression from the other side. The defect #891/#912 report
# is the notice going BLIND, not the arbitration being wrong.
test_open_window_inside_freshness_defers_to_arbitration() {
  local dir rc before=$FAIL
  dir=$(make_case "open-window-inside-freshness" "$RATE_LIMIT_BODY_LONG_WINDOW" \
    "$STATUS_AFTER_NOTICE" "Review completed" "$NOTICE_AGED_TIME" 999999999)
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "14: expected exit 0 (the #446 arbitration clears an unscoped pre-success notice), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "14: status=$(jqf "$dir" '.status'), expected cleared"
  grep -q 'remains authoritative' "$dir/err.log" || fail "14: expected the #446 arbitration to decide this, not the window rule; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  grep -q 'published window has NOT expired' "$dir/err.log" && fail "14: the window rule fired while the notice was inside the freshness floor — it must be scoped to the blind spot"
  [ "$FAIL" -ne "$before" ] || pass "14: the published-window rule applies ONLY when nothing survived the freshness floor; a visible notice is still arbitrated against the status"
}

# --- Test 13: #912 — the fast-path verdict carries the STATUS' own time -----
# The #909 false clear was hard to spot because the JSON looked head-anchored
# and current: `review.created_at` was the script's OBSERVATION time while the
# status it trusted had been sitting untouched for 40 minutes. `created_at` is
# now the status' own creation time and the observation time moves to the
# additive `observed_at`, so a reader sees the evidence's age AND when the
# helper looked.
test_status_context_verdict_carries_status_created_at() {
  local dir rc before=$FAIL
  dir=$(make_case "verdict-timestamps" "$REVIEW_BODY_CLEAN" "$STATUS_AFTER_NOTICE" "Review completed")
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "13: expected exit 0 (cleared), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.review.endpoint')" = "status_context" ] || fail "13: expected the fast-path verdict, got endpoint=$(jqf "$dir" '.review.endpoint')"
  [ "$(jqf "$dir" '.review.created_at')" = "$STATUS_AFTER_NOTICE" ] || fail "13: review.created_at=$(jqf "$dir" '.review.created_at'), expected the status' own created_at $STATUS_AFTER_NOTICE"
  [ "$(jqf "$dir" '.review.observed_at')" != "null" ] || fail "13: review.observed_at is null; the synthesis time must still be carried"
  [ "$(jqf "$dir" '.review.observed_at')" != "$STATUS_AFTER_NOTICE" ] || fail "13: review.observed_at equals the status time; it must be the observation time"
  [ "$FAIL" -ne "$before" ] || pass "13: #912 — the status_context verdict carries the status' own created_at, with the observation time in observed_at"
}

# --- Test 16: #877 — the summary surface must not AGE OUT of the fast path --
# Same fixture as test 5 (StatusContext success, zero inline findings, one
# PR-level summary carrying `_🟠 Major_`) with one difference: the summary is 40
# minutes old and the freshness window is the live 1800s, so the moving
# wallclock floor has advanced past it. Nothing about the head changed — only a
# clock advanced — and the fast path is the ONE site reached when nothing
# survives that floor, so selecting the summary through HEAD_ANCHOR meant no
# comment qualified, `summary_blocking_marker_present ""` returned false, and
# the head CLEARED. The inline sibling three lines above uses the floor-free
# HEAD_IDENTITY_ANCHOR for exactly this reason (#224), and `--probe` selects the
# summary anchor-free, so the two routes verdicted the same unchanged head
# differently: polling cleared while the probe reported findings.
#
# Operationally this is the merge gate: .github/workflows/agent-review.yml runs
# the waiter in polling mode at APPROVAL time, long after the CodeRabbit round,
# i.e. on precisely the aged head this cleared on.
test_aged_summary_only_marker_is_findings_not_cleared() {
  local dir rc before=$FAIL
  dir=$(make_case "aged-summary-marker" "$REVIEW_BODY_SUMMARY_ONLY_MARKER" \
    "$STATUS_AFTER_NOTICE" "Review completed" "$SUMMARY_AGED_TIME" 1800)
  rc=$(run_case "$dir")
  # Non-vacuity: the floor must actually govern the anchor here, or this is
  # test 5 again with different timestamps and proves nothing about aging.
  grep -q 'anchor = .*(source: wallclock floor' "$dir/err.log" \
    || fail "16: the wallclock floor did not govern the anchor — the fixture no longer reproduces the aged-summary state; err=$(grep 'anchor =' "$dir/err.log")"
  [ "$rc" != "0" ] || fail "16: fast-path FALSE-CLEARED (exit 0) over a summary-only blocking marker that had merely aged past the wallclock floor; err=$(tail -4 "$dir/err.log")"
  [ "$rc" = "2" ] || fail "16: expected exit 2 (findings), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "findings" ] || fail "16: status=$(jqf "$dir" '.status'), expected findings"
  [ "$(jqf "$dir" '.review.endpoint')" = "status_context" ] || fail "16: review.endpoint=$(jqf "$dir" '.review.endpoint'), expected status_context (the verdict must come from the fast path)"
  grep -q 'PR-level summary carries a blocking marker' "$dir/err.log" || fail "16: expected the #877 summary-marker log line; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "16: #877 — an unchanged head does not transition from findings to cleared because the wallclock floor advanced past its summary"
}

# --- Test 17: escape — the fast-path summary read is ANCHORED, not anchor-free
# The fix is a swap from the moving wallclock floor to HEAD_IDENTITY_ANCHOR (the
# head's own committer/force-push time), NOT the removal of the anchor. A
# summary stamped BEFORE the head commit exists belongs to a PRIOR head, and
# resurrecting it would block every push that follows a blocking review — the
# opposite failure, and one no push could clear. An anchor-free read fails here.
test_prior_head_summary_marker_does_not_block() {
  local dir rc before=$FAIL
  dir=$(make_case "prior-head-summary-marker" "$REVIEW_BODY_SUMMARY_ONLY_MARKER" \
    "$STATUS_AFTER_NOTICE" "Review completed" "$SUMMARY_PRIOR_HEAD_TIME" 1800)
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "17: expected exit 0 (cleared) — a summary predating the head commit is a PRIOR head's report, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "17: status=$(jqf "$dir" '.status'), expected cleared"
  [ "$(jqf "$dir" '.review.endpoint')" = "status_context" ] || fail "17: expected the fast-path verdict, got endpoint=$(jqf "$dir" '.review.endpoint')"
  grep -q 'PR-level summary carries a blocking marker' "$dir/err.log" && fail "17: a prior head's summary blocked this head — the fast-path summary read went anchor-free instead of head-identity-anchored"
  [ "$FAIL" -ne "$before" ] || pass "17: escape — the fast-path summary read is anchored to head identity; a prior head's blocking summary does not block this head"
}

# --- Test 18: #936 — a LATER notice must not mask the head-anchored summary --
# Codex P1 on #936, and a hazard this PR opened. summary_body_has_potential_
# issue_marker selects the newest head-anchored bot comment of ANY class. Its
# two POLL callers are safe by construction — each runs inside `case class in
# review)`, so the newest comment is already known to be a review summary and
# the helper re-picks that same comment. The StatusContext fast path added by
# this PR establishes no such precondition, so it feeds the helper an input it
# was never defined over.
#
# The fixture is the overlap where that matters. Three events on one head:
#   summary @00:00:10  a `review` comment carrying `_🟠 Major_` (the #535 class)
#   notice  @00:00:20  a rate-limit notice — newer, but NOT head-referencing
#   success @00:30:00  the StatusContext, created after both
# The #446 arbitration reads an unscoped notice CREATED BEFORE the success as
# stale and leaves the fast path unsuppressed (the `remains authoritative`
# branch — asserted below so this case cannot silently become a suppression
# test). The fast path then runs, and a class-blind pick grades the NOTICE,
# finds no badge in it, and clears — over a blocking summary two comments down
# that the polling `review` arm and `--probe` both report as findings.
test_later_notice_does_not_mask_head_summary() {
  local dir rc before=$FAIL
  dir=$(make_case "later-notice-masks-summary" "$REVIEW_BODY_SUMMARY_ONLY_MARKER" \
    "$STATUS_AFTER_BOTH_TIME" "Review completed" "$SUMMARY_ON_HEAD_TIME" 999999999 \
    "$RATE_LIMIT_BODY_LONG_WINDOW" "$NOTICE_AFTER_SUMMARY_TIME")
  rc=$(run_case "$dir")
  # Non-vacuity: the notice must be visible to the arbitration AND lose there,
  # or this is test 5 with an extra comment and proves nothing about selection.
  grep -q 'remains authoritative' "$dir/err.log" \
    || fail "18: the fast path was suppressed instead of entered — the fixture no longer reaches the selection; err=$(grep -i statuscontext "$dir/err.log" | tail -3)"
  [ "$rc" != "0" ] || fail "18: fast-path FALSE-CLEARED (exit 0) — a later non-review notice masked the head-anchored blocking summary; err=$(tail -4 "$dir/err.log")"
  [ "$rc" = "2" ] || fail "18: expected exit 2 (findings), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "findings" ] || fail "18: status=$(jqf "$dir" '.status'), expected findings"
  [ "$(jqf "$dir" '.review.endpoint')" = "status_context" ] || fail "18: review.endpoint=$(jqf "$dir" '.review.endpoint'), expected status_context (the verdict must come from the fast path)"
  grep -q 'PR-level summary carries a blocking marker' "$dir/err.log" || fail "18: expected the #877 summary-marker log line; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "18: #936 — the summary read selects the latest review SUMMARY, so a later rate-limit notice cannot mask a blocking one"
}

# --- Test 19: #936 — a failed summary DERIVE is rc 3, not 'no marker' -------
# Codex P1 on #936, sibling of test 15. There the API read failed and
# fetch_api_array's `|| return 3` caught it. Here the read SUCCEEDS and the jq
# that derives the summary body fails instead — the stub serves `[42]`, a
# well-formed array whose elements are not comment objects, so `.user.login`
# errors. Every caller invokes this helper in an `if`/`||` context, which
# disables errexit inside it, so an unchecked assignment carried on with an
# empty body, `summary_blocking_marker_present ""` returned false, and the
# function returned 1 (`no marker`) — clearance from an unread summary. The
# derive is status-checked and returns 3, same as the fetch above it.
test_failed_summary_derive_does_not_clear() {
  local dir rc=0 before=$FAIL
  dir=$(make_case "summary-derive-failure" "$REVIEW_BODY_CLEAN" "$STATUS_TIME" "Review completed")
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_ISSUES_MALFORMED_AFTER=1 \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  [ "$rc" != "0" ] || fail "19: FALSE-CLEARED (exit 0) after the summary-body derive failed; err=$(tail -4 "$dir/err.log")"
  [ "$rc" = "3" ] || fail "19: expected exit 3 (infra), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'refusing to report a clearance' "$dir/err.log" || fail "19: expected the fail-closed summary-read message; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "19: a failed summary-body DERIVE (not just a failed fetch) is exit 3 (infra), never a clearance"
}

# --- Test 20: #936 — 'No review completed' is a refusal, end to end ---------
# Codex P1 on #936. The description predicate matched `*"review complete"*` as
# a SUBSTRING, so three wordings that state the review did NOT happen cleared
# the guard whose entire purpose is to reject them. Unit-asserted in test 12;
# this case proves the predicate is still WIRED, by running the whole script
# against a status whose description is one of them.
#
# The expected outcome is not "blocked" but "not cleared BY THE FAST PATH": the
# verdict falls through to the comment-driven poll, which reaches its own answer
# off the clean review comment. `review.endpoint` is the assertion that
# separates the two routes.
test_negated_completed_description_does_not_take_fast_path() {
  local dir rc before=$FAIL
  dir=$(make_case "desc-no-review-completed" "$REVIEW_BODY_CLEAN" "$STATUS_TIME" "No review completed")
  rc=$(run_case "$dir")
  grep -q 'does not name a completed review' "$dir/err.log" \
    || fail "20: the description guard did not fire on 'No review completed'; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$(jqf "$dir" '.review.endpoint')" != "status_context" ] \
    || fail "20: the fast path took a status describing NO completed review as clearance evidence"
  [ "$rc" = "0" ] || fail "20: expected the poll route to reach exit 0 off the clean review comment, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "20: 'No review completed' suppresses the fast path; the verdict comes from the comment-driven poll instead"
}

test_headref_ratelimit_suppresses_status
test_headref_review_still_clears
test_headref_later_success_clears
test_headref_within_published_window_suppresses
test_summary_only_marker_is_findings_not_cleared
test_ratelimited_description_without_notice_never_clears
test_unknown_description_does_not_clear
test_completed_description_still_clears
test_aged_notice_with_open_window_suppresses
test_aged_notice_with_expired_window_clears
test_trailing_probe_flag_is_usage_error
test_status_description_predicate_unit
test_status_context_verdict_carries_status_created_at
test_open_window_inside_freshness_defers_to_arbitration
test_failed_summary_read_does_not_clear
test_aged_summary_only_marker_is_findings_not_cleared
test_prior_head_summary_marker_does_not_block
test_later_notice_does_not_mask_head_summary
test_failed_summary_derive_does_not_clear
test_negated_completed_description_does_not_take_fast_path

echo "----"
echo "test_coderabbit_wait_statuscontext_ratelimit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
