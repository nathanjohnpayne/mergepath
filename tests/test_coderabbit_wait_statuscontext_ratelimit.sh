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

# A blocking PR-level summary that QUOTES the pause marker inside a fenced code
# block — the shape a CodeRabbit summary takes whenever it quotes a diff hunk
# from this very file, whose classifier constants are that literal text.
# `classify_comment` is a fixed-string grep with no fence awareness, so it grades
# this body `paused`. It is nonetheless a real review summary carrying a real
# `_🟠 Major_` badge (CodeRabbit 🟠 Major on #936).
REVIEW_BODY_SUMMARY_QUOTING_PAUSE_MARKER='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->

**Actionable comments posted: 1**

<details>
<summary>scripts/coderabbit-wait.sh (1)</summary>

_🔒 Security & Privacy_ | _🟠 Major_ | _⚡ Quick win_

**The pause marker is compared case-sensitively.**

```
review paused by coderabbit.ai
```

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

# --- #968 fixtures: the summary's own commits range -------------------------
# Real 40-hex object names, because the live commits line is 40-hex on both
# ends and a placeholder head could model neither a match nor a mismatch.
# HEAD_SHA_40 is the head from the live #968 capture on PR #965; the other two
# stand in for the base and the PREVIOUSLY reviewed head of that same capture.
HEAD_SHA_40='f9c7847139881a1004e796d4ab8967b23e083baa'
PREV_HEAD_SHA_40='76e77a6db2c1f3a4e5b6c7d8e9f0a1b2c3d4e5f6'
BASE_SHA_40='75d6f8e9ff0a1b2c3d4e5f60718293a4b5c6d7e8'

# The edit timeline of the live capture, rebased onto this file's HEAD_TIME:
# CodeRabbit posted the summary BEFORE the push (so created_at is below the
# HEAD-committer-date floor), then edited it in place 53s AFTER the push. The
# edit is what carries the whole comment over the floor.
SUMMARY_CREATED_BEFORE_HEAD='2026-06-03T23:23:28Z'
SUMMARY_EDITED_AFTER_HEAD='2026-06-04T00:00:53Z'

# A clean CodeRabbit summary whose commits range names the PREVIOUS head. This
# is a verdict about a commit that is not the one being waited on.
SUMMARY_NAMES_PREVIOUS_HEAD="<!-- This is an auto-generated comment: summarize by coderabbit.ai -->

**Actionable comments posted: 0**

Reviewing files that changed from the base of the PR and between $BASE_SHA_40 and $PREV_HEAD_SHA_40.

<!-- This is an auto-generated comment: release notes by coderabbit.ai -->
## Summary by CodeRabbit
- Fixes
<!-- end of auto-generated comment: release notes by coderabbit.ai -->"

# The same summary, naming the CURRENT head. #824's rung: this must still clear
# even though its created_at predates the head committer date.
SUMMARY_NAMES_CURRENT_HEAD="<!-- This is an auto-generated comment: summarize by coderabbit.ai -->

**Actionable comments posted: 0**

Reviewing files that changed from the base of the PR and between $BASE_SHA_40 and $HEAD_SHA_40.

<!-- This is an auto-generated comment: release notes by coderabbit.ai -->
## Summary by CodeRabbit
- Fixes
<!-- end of auto-generated comment: release notes by coderabbit.ai -->"

# A benign CodeRabbit CHAT REPLY, posted AFTER the summary was edited. This is
# the #968 AC1 shape: it classifies `review` (no notice marker), carries no
# outcome stanza, and carries no commits range, so a demotion read off "the
# newest bot comment" finds no head claim and clears — while the summary two
# comments down is still a verdict about the PREVIOUS head. Modelled on the two
# live replies the script's SUMMARY_MARKER comment records (#794, #518),
# including the full 40-hex head SHA they lift from a `gh pr view` snippet, so
# the fixture also shows that carrying the SHA is not what makes evidence.
CHAT_REPLY_AFTER_SUMMARY="🧩 Analysis chain

Confirmed: the current head per gh pr view is $HEAD_SHA_40, and the helper is wired at the call site."

# After SUMMARY_EDITED_AFTER_HEAD, so the reply is the newest bot comment and
# wins any freshness-ordered pick.
CHAT_REPLY_TIME='2026-06-04T00:01:30Z'

# A clean summary carrying NO commits range at all — the shape whose freshness
# the `fresh_at >= HEAD_ANCHOR` floor alone must keep deciding (#968 AC3).
SUMMARY_NAMES_NO_SHA='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->

**Actionable comments posted: 0**

No actionable comments were generated in the recent review.'

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
#   head_sha            the PR head SHA the stub serves (default `head-sha`,
#                       the placeholder every pre-#968 fixture used). The #968
#                       cases pass a real 40-hex object name because the
#                       summary's commits range is 40-hex on both ends in the
#                       live format, so a placeholder head could not model a
#                       range-end match or mismatch at all.
#   comment_updated_time  updated_at for the first issue comment (default:
#                       comment_time, i.e. never edited). #968 is the case
#                       where these differ: CodeRabbit edits its summary in
#                       place, which bumps updated_at without re-reviewing.
make_case() {
  local name=$1 comment_body=$2 status_time=${3:-$STATUS_TIME}
  local status_description=${4:-} comment_time=${5:-$HEAD_TIME}
  local freshness_window=${6:-999999999}
  local second_body=${7:-} second_time=${8:-$HEAD_TIME}
  local head_sha=${9:-head-sha}
  local comment_updated_time=${10:-$comment_time}
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
comment_updated_time='$comment_updated_time'
head_sha='$head_sha'
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
  repos/owner/repo/pulls/999) printf '{"head":{"sha":"%s"}}\n' "\$head_sha" ;;
  repos/owner/repo/commits/$head_sha)
    if [ "\${1:-}" = "--jq" ]; then printf '%s\n' "\$head_time"
    else printf '{"commit":{"committer":{"date":"%s"}}}\n' "\$head_time"; fi ;;
  repos/owner/repo/commits/$head_sha/statuses)
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
  repos/owner/repo/pulls/999/reviews)
    # CODERABBIT_TEST_FAIL_REVIEWS=1: the reviews read fails. This is the
    # entry fetch of the count_potential_issues chain
    # (count_potential_issues -> head_review_finding_bodies ->
    # latest_head_pinned_review_id -> latest_head_pinned_review), where an
    # unreadable list and a genuinely empty one are otherwise the same
    # observation: both leave the review id empty.
    if [ -n "\${CODERABBIT_TEST_FAIL_REVIEWS:-}" ]; then
      echo "simulated reviews API failure" >&2
      exit 44
    fi
    # CODERABBIT_TEST_REVIEWS_OBJECT=1 (#967): a 200 whose body is a JSON
    # OBJECT rather than a list. gh exits 0, so this is a SUCCESSFUL read of a
    # payload that is not an array — the third response mode, distinct from
    # CODERABBIT_TEST_FAIL_REVIEWS (non-zero exit, #831) and from a valid
    # empty '[]'. \`jq -s 'add // []'\` passes a lone object through unchanged,
    # and jq's \`.[]\` then iterates an EMPTY object's values (there are none),
    # so every downstream filter reads a confident "no reviews on this head".
    if [ -n "\${CODERABBIT_TEST_REVIEWS_OBJECT:-}" ]; then
      printf '{}\n'
      exit 0
    fi
    printf '[]\n' ;;
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
    # CODERABBIT_TEST_FAIL_ISSUES_ON=<n>: fail read n EXACTLY and serve every
    # other read normally — a transient blip, not an outage. The distinction is
    # what isolates #831: under a SUSTAINED failure the polling loop's later
    # summary read fails too and its own #936 guard stops the run, so a
    # sustained-failure fixture would pass against the unfixed script. Only a
    # single failed read leaves the wrapper under test as the sole cause.
    if [ -n "\${CODERABBIT_TEST_FAIL_ISSUES_ON:-}" ] && [ "\$n" = "\$CODERABBIT_TEST_FAIL_ISSUES_ON" ]; then
      echo "simulated transient issue-comments API failure on read \$n" >&2
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
    # CODERABBIT_TEST_ISSUES_MALFORMED_ON=<n>: serve the SAME non-object array
    # on read n EXACTLY and every other read normally. Transient, for the same
    # reason CODERABBIT_TEST_FAIL_ISSUES_ON is (#959): under a SUSTAINED
    # malformed payload the polling loop's own summary read breaks too and the
    # #936 guard stops the run, so the fixture would pass against the unfixed
    # script. Only a single bad read leaves the decode under test as the sole
    # cause of a different verdict.
    if [ -n "\${CODERABBIT_TEST_ISSUES_MALFORMED_ON:-}" ] && [ "\$n" = "\$CODERABBIT_TEST_ISSUES_MALFORMED_ON" ]; then
      printf '[42]\n'
      exit 0
    fi
    body=\$(cat "\$state_dir/comment-body.txt")
    body2=""
    if [ -f "\$state_dir/comment-body-2.txt" ]; then body2=\$(cat "\$state_dir/comment-body-2.txt"); fi
    if [ -z "\$body" ]; then printf '[]\n'; else
      jq -cn --arg bot "\$bot" --arg t "\$comment_time" --arg body "\$body" \
        --arg tu "\$comment_updated_time" \
        --arg t2 "\$second_time" --arg body2 "\$body2" \
        '[{id:7701,user:{login:\$bot},created_at:\$t,updated_at:\$tu,body:\$body}]
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

# --- Test 21: #936 — the class filter must never LOSE a blocking summary ----
# CodeRabbit 🟠 Major on the test-18 fix, confirmed by measurement rather than
# by reading: on this fixture the class-blind selection exits 2 (findings) and
# the review-class selection exits 0 (cleared). The class filter is therefore
# only safe if it can never subtract — a summary it fails to recognize must
# still be graded.
#
# `classify_comment` is a fixed-string grep over the whole body with no fence
# awareness, so a real summary that QUOTES `review paused by coderabbit.ai` —
# the shape produced whenever CodeRabbit quotes a diff hunk of this very file,
# whose classifier constants are that literal text — grades `paused` and was
# skipped, leaving no review-class candidate and a `no marker` return.
#
# The rule is now preference, not exclusion: the newest REVIEW-class body wins
# when one exists (test 18), and otherwise the helper grades the newest
# candidate, which is exactly what it did before the class filter existed. That
# makes the filter monotone — it can promote a summary over a later notice, and
# it can never demote one to nothing.
test_misclassified_summary_is_still_graded() {
  local dir rc before=$FAIL
  dir=$(make_case "quoting-summary" "$REVIEW_BODY_SUMMARY_QUOTING_PAUSE_MARKER" \
    "$STATUS_AFTER_BOTH_TIME" "Review completed" "$SUMMARY_ON_HEAD_TIME" 999999999)
  rc=$(run_case "$dir")
  # Non-vacuity: the body must actually be misclassified, or the class filter
  # selects it directly and this is test 5 with a longer fixture.
  grep -q 'class=paused' "$dir/err.log" \
    || fail "21: the fixture no longer misclassifies — classify_comment did not grade it paused; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  grep -q 'entering fast-path verdict' "$dir/err.log" \
    || fail "21: the fast path was suppressed instead of entered — the fixture no longer reaches the selection; err=$(grep -i statuscontext "$dir/err.log" | tail -3)"
  [ "$rc" != "0" ] || fail "21: FALSE-CLEARED (exit 0) — the class filter dropped a blocking summary it could not recognize; err=$(tail -4 "$dir/err.log")"
  [ "$rc" = "2" ] || fail "21: expected exit 2 (findings), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "findings" ] || fail "21: status=$(jqf "$dir" '.status'), expected findings"
  grep -q 'PR-level summary carries a blocking marker' "$dir/err.log" || fail "21: expected the #877 summary-marker log line; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "21: #936 — the review-class filter is a PREFERENCE, not an exclusion: a summary it misgrades is still graded"
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

# --- Test 22: #831/#957 — a failed COMMENT-LIST read is rc 3, not a verdict -
# The root #831 shape on the arm that matters most. `fetch_api_array` reports a
# failed read ONLY by returning non-zero — its old `die` ran inside a command
# substitution and killed just that subshell — and `scan_latest_comment` was
# the last wrapper in the file that dropped that status. The loop was then
# handed an empty object, `classify_comment ""` graded it `review` (the one
# class whose arm can emit a clearance), and the run reached
# `CodeRabbit review posted with no high-severity markers — cleared` on a head
# nobody read. Captured live on #936 head d361075.
#
# Asserted on the LOG LINE as well as the exit code, deliberately (#957
# acceptance 2). Pre-fix the process did not actually exit 0 — `jq --argjson
# review ""` rejected the empty evidence object and killed it rc 2 — so an
# exit-code-only assertion would pass against the unfixed script on an
# accident. The clearance decision is the defect; the crash is the mask.
#
# The control run is half the test: same fixture, no injected failure, a PR
# CodeRabbit never commented on. It must reach the advisory timeout, which is
# what proves the clearance below is manufactured by the failed read rather
# than by anything else in the fixture.
test_failed_comment_list_read_does_not_clear() {
  local dir rc=0 ctl ctlrc before=$FAIL
  ctl=$(make_case "comment-list-control" "" "$STATUS_TIME" "Review rate limited")
  ctlrc=$(run_case "$ctl")
  [ "$ctlrc" = "4" ] \
    || fail "22: control expected exit 4 (timeout) on a PR with no CodeRabbit comment at all, got $ctlrc; err=$(tail -4 "$ctl/err.log")"
  if grep -q 'no high-severity markers — cleared' "$ctl/err.log"; then
    fail "22: control reached a clearance verdict with an empty comment list — the fixture, not the injected failure, is doing the work"
  fi

  dir=$(make_case "comment-list-failure" "" "$STATUS_TIME" "Review rate limited")
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_FAIL_ISSUES_ON=1 \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  if grep -q 'no high-severity markers — cleared' "$dir/err.log"; then
    fail "22: the polling loop reached a CLEARANCE verdict off a read that had just failed; err=$(tail -4 "$dir/err.log")"
  fi
  [ "$rc" != "0" ] || fail "22: FALSE-CLEARED (exit 0) after the comment-list read failed"
  [ "$rc" = "3" ] || fail "22: expected exit 3 (infra), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'refusing to grade an unread head' "$dir/err.log" \
    || fail "22: expected the fail-closed comment-list message; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "22: a failed issue-comments read in the polling loop is exit 3 (infra) with no clearance verdict, never a graded 'review'"
}

# --- Test 23: #831 — a failed REVIEWS read is rc 3, not a zero finding count -
# The second #831 wrapper chain, reached from the polling `review` arm:
# count_potential_issues -> head_review_finding_bodies ->
# latest_head_pinned_review_id -> latest_head_pinned_review, whose fetch is the
# one that fails here. An unreadable reviews list and a genuinely empty one
# both leave the review id empty, so without the propagation the chain emits
# `[]`, the arm reads a confident zero, and the summary read (which succeeds)
# then clears the head — exit 0 on inline findings nobody counted.
#
# The comment fixture is a CLEAN review summary, so the summary surface cannot
# supply a `findings` verdict of its own: the only thing that can move this run
# off exit 0 is the failed read.
test_failed_reviews_read_does_not_clear() {
  local dir rc=0 before=$FAIL
  dir=$(make_case "reviews-read-failure" "$REVIEW_BODY_CLEAN" "$STATUS_TIME" "Review rate limited")
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_FAIL_REVIEWS=1 \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  if grep -q 'no high-severity markers — cleared' "$dir/err.log"; then
    fail "23: the review arm CLEARED on an inline finding count taken from an unreadable reviews list; err=$(tail -4 "$dir/err.log")"
  fi
  [ "$rc" != "0" ] || fail "23: FALSE-CLEARED (exit 0) after the reviews read failed"
  [ "$rc" = "3" ] || fail "23: expected exit 3 (infra), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'failed to fetch reviews' "$dir/err.log" \
    || fail "23: expected the failed reviews read to be named; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "23: a failed reviews read in the count_potential_issues chain is exit 3 (infra), never a finding count of zero"
}

# --- Test 24: #831 — the fast path's own read failure must not CLEAR ---------
# The third #831 wrapper, and the only one whose guard was already in the tree
# but unpinned: `status_context_fast_path_blocked_by_comment`. Its whole job is
# to decide whether a CodeRabbit StatusContext success is trustworthy, and it
# decides that by reading the comment list. An unchecked read failure hands it
# an empty list, so every classifier below it sees nothing adverse, and the
# function returns "not blocked" — the fast path then clears a head CodeRabbit
# has publicly said it is rate-limited on. The failure and the all-clear are
# the same observation, which is the #831 shape exactly.
#
# The fixture is test 1's, unchanged, and test 1 IS the control: same notice,
# same near-simultaneous success, no injected failure, exit 5. The single
# difference here is that the fast path's first issue-comments read fails, so
# nothing but that read can account for a different verdict.
#
# Non-vacuous by mutation: replacing the `|| { log …; return 0; }` guard at
# `status_context_fast_path_blocked_by_comment`'s fetch with a bare assignment
# turns this run into `StatusContext success and 0 blocking (p0/p1) inline
# findings — emitting cleared (exit 0)`. Asserted on that log line as well as
# the exit code, because the clearance DECISION is the defect (#957) — an
# exit-code-only assertion can be satisfied by an unrelated downstream crash.
test_failed_fast_path_comment_read_does_not_clear() {
  local dir rc=0 before=$FAIL
  dir=$(make_case "fast-path-read-failure" "$RATE_LIMIT_BODY_HEADREF")
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_FAIL_ISSUES_ON=1 \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  if grep -q 'emitting cleared' "$dir/err.log"; then
    fail "24: the StatusContext fast path CLEARED a rate-limited head off a comment-list read that had just failed; err=$(tail -4 "$dir/err.log")"
  fi
  [ "$rc" != "0" ] || fail "24: FALSE-CLEARED (exit 0) after the fast path's comment-list read failed"
  [ "$rc" = "5" ] || fail "24: expected exit 5 (rate_limit_stalled, same as the test-1 control), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "rate_limit_stalled" ] || fail "24: status=$(jqf "$dir" '.status'), expected rate_limit_stalled"
  grep -q 'the issue-comments read failed' "$dir/err.log" \
    || fail "24: expected the fast-path suppression message naming the failed read; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "24: a failed comment-list read inside the StatusContext fast path suppresses it (keep polling), never clears a rate-limited head"
}

# --- Test 25: #959 — the fast path's DECODE failure must not CLEAR either ----
# Test 24 above pins the FETCH. #936 hardened that half and left the jq that
# follows it bare, so a payload the fetch's own `add // []` accepts — a
# well-formed array whose elements are not comment objects — left `latest`
# EMPTY with status 0.
#
# Empty is not `{}`, and that is the whole mechanism: `echo "" | jq 'length'`
# runs the filter zero times, so it prints NOTHING and exits 0, and the guard
# `[ "$(…)" = "0" ]` — written for "no qualifying comment" — compares the empty
# string against "0" and does not fire. Control fell through to
# `classify_comment ""`, which grades `review`, which the
# `rate_limit|paused|in_progress` case does not match, so the function returned
# 1 ("not blocked") and the fast path cleared a head it had read nothing about.
#
# Same fixture and same control as test 24 (test 1: HEAD-referencing rate-limit
# notice, near-simultaneous success, exit 5). The single difference is that the
# fast path's issue-comments read SUCCEEDS and its decode fails, so nothing but
# that decode can account for a different verdict. Asserted on the clearance
# DECISION as well as the exit code, so an unrelated downstream crash cannot
# satisfy it — the issue's own capture notes the defect was masked by exactly
# such a crash.
test_failed_fast_path_comment_decode_does_not_clear() {
  local dir rc=0 before=$FAIL
  dir=$(make_case "fast-path-decode-failure" "$RATE_LIMIT_BODY_HEADREF")
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_ISSUES_MALFORMED_ON=1 \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  if grep -q 'emitting cleared' "$dir/err.log"; then
    fail "25: the StatusContext fast path CLEARED a rate-limited head off a comment-list DECODE that had just failed; err=$(tail -4 "$dir/err.log")"
  fi
  [ "$rc" != "0" ] || fail "25: FALSE-CLEARED (exit 0) after the fast path's comment-list decode failed"
  [ "$rc" = "5" ] || fail "25: expected exit 5 (rate_limit_stalled, same as the test-1 control), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "rate_limit_stalled" ] || fail "25: status=$(jqf "$dir" '.status'), expected rate_limit_stalled"
  grep -q 'could not be DECODED' "$dir/err.log" \
    || fail "25: expected the fast-path suppression message naming the failed decode; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "25: a failed comment-list DECODE inside the StatusContext fast path suppresses it (keep polling), never clears a rate-limited head"
}

# --- Test 26: #957/#959 — the POLLING loop's decode failure is infra, not a
# graded review.
#
# Test 22 pins the polling loop's FETCH; this pins the DECODE on the same arm,
# and this arm is the consequential one: the fast path is opt-in behind
# `trust_status_context_for_clearance`, the poll loop is what every caller
# reaches. `classify_comment ""` grades `review` — the one class whose arm can
# emit a clearance — so a failed decode did not stall the loop, it ADVANCED it
# to a verdict on a comment that does not exist. The live capture on #936 head
# d361075 is asserted directly, because it is the observable signature:
#
#   [coderabbit-wait] latest CodeRabbit comment id= endpoint= class=review created= fresh_at=
#   [coderabbit-wait] CodeRabbit review posted with no high-severity markers — cleared
#
# Same fixture as test 22's — an empty comment list and a `Review rate limited`
# description, so the fast path is suppressed at the description guard and
# never reads the comments. That makes read 1 the polling scan, and its control
# (below) exits 4 (timeout) with no clearance, so only the injected malformed
# payload can account for a different verdict.
test_failed_poll_comment_decode_does_not_clear() {
  local dir rc=0 ctl ctlrc before=$FAIL
  ctl=$(make_case "poll-decode-control" "" "$STATUS_TIME" "Review rate limited")
  ctlrc=$(run_case "$ctl")
  [ "$ctlrc" = "4" ] \
    || fail "26: control expected exit 4 (timeout) on a PR with no CodeRabbit comment at all, got $ctlrc; err=$(tail -4 "$ctl/err.log")"

  dir=$(make_case "poll-decode-failure" "" "$STATUS_TIME" "Review rate limited")
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_ISSUES_MALFORMED_ON=1 \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  if grep -q 'no high-severity markers — cleared' "$dir/err.log"; then
    fail "26: the polling review arm CLEARED on a comment list it had just failed to decode; err=$(tail -4 "$dir/err.log")"
  fi
  if grep -q 'class=review created= fresh_at=' "$dir/err.log"; then
    fail "26: the loop graded an EMPTY comment as class=review — the #957 live signature; err=$(tail -4 "$dir/err.log")"
  fi
  [ "$rc" != "0" ] || fail "26: FALSE-CLEARED (exit 0) after the comment-list decode failed"
  [ "$rc" = "3" ] || fail "26: expected exit 3 (infra) on the unreadable comment list, got $rc; err=$(tail -4 "$dir/err.log")"
  if ! grep -q 'refusing to grade an unread head as a review' "$dir/err.log"; then
    fail "26: expected the polling loop to name the unread comment list; err=$(tail -4 "$dir/err.log")"
  fi
  [ "$FAIL" -ne "$before" ] || pass "26: a failed comment-list DECODE in the polling loop is exit 3 (infra), never a graded 'review' on an empty comment"
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

# --- Test 27: #967 — a 200 whose body is a JSON OBJECT is an UNREAD list -----
# `fetch_api_array`'s flatten is `jq -s 'add // []'`, and `add` over a
# one-element stream returns that element unchanged — so a 200 carrying `{}`
# survives as an object and nothing downstream is told. jq's `.[]` then
# iterates an empty object's VALUES, of which there are none, so
# `latest_head_pinned_review` reads a confident "no CodeRabbit review on this
# head", `head_review_finding_bodies` emits `[]`, the inline count is 0, and
# the polling `review` arm CLEARS. That is the #831 false negative arrived at
# down a different road: #831 closed the failed-READ half (gh exits non-zero),
# this is a SUCCESSFUL read of a payload that is not a list.
#
# The fixture drives the POLLING path deliberately (a `Review rate limited`
# description refuses the fast path, exactly as in the live #968 capture),
# because that is the arm whose reviews read feeds count_potential_issues.
test_non_array_reviews_body_does_not_clear() {
  local dir rc=0 before=$FAIL
  dir=$(make_case "reviews-object-body" "$REVIEW_BODY_CLEAN" "$STATUS_TIME" "Review rate limited")
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_REVIEWS_OBJECT=1 \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  [ "$rc" != "0" ] || fail "27: FALSE-CLEARED (exit 0) on a reviews endpoint that returned a JSON object; err=$(tail -4 "$dir/err.log")"
  grep -q '"status": *"cleared"' "$dir/out.json" 2>/dev/null && fail "27: emitted a cleared verdict off a non-array reviews body"
  [ "$rc" = "3" ] || fail "27: expected exit 3 (infra), got $rc; err=$(tail -4 "$dir/err.log")"
  # The diagnostic must name BOTH the endpoint and the type actually received
  # (#967 acceptance 1) — a bare "could not read" would leave an operator
  # guessing which surface and which shape.
  grep -q 'came back as a JSON object, not a JSON array' "$dir/err.log" \
    || fail "27: expected a diagnostic naming the received type; err=$(tail -4 "$dir/err.log")"
  grep -q 'repos/owner/repo/pulls/999/reviews) came back as a JSON' "$dir/err.log" \
    || fail "27: the diagnostic should name the endpoint it read; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "27: #967 — a 200 whose body is a JSON object is an infra exit naming the type, never an empty result"
}

# --- Test 28: #967 escape — a genuine empty list still clears ---------------
# The control that keeps test 27 from passing for the wrong reason. Same
# fixture, same route, the ONLY difference being that the reviews endpoint
# serves a valid `[]`: an empty array is a real answer ("no reviews on this
# head") and must still reach the polling arm's clearance.
test_empty_reviews_array_still_clears() {
  local dir rc before=$FAIL
  dir=$(make_case "reviews-empty-array" "$REVIEW_BODY_CLEAN" "$STATUS_TIME" "Review rate limited")
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "28: expected exit 0 (cleared) for a genuinely empty reviews list, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "28: status=$(jqf "$dir" '.status'), expected cleared"
  [ "$FAIL" -ne "$before" ] || pass "28: #967 escape — a valid empty reviews array is still a readable answer and still clears"
}

# --- Test 29: #968 — an in-place summary EDIT is not a re-review ------------
# The live capture on PR #965: push lands head f9c7847 at 04:58:00Z; CodeRabbit
# edits its PREVIOUS head's summary in place at 04:58:53Z; `fresh_at` is
# max(created_at, updated_at), so the edit carries a verdict about commit N
# over the floor and the polling `review` arm clears for commit N+1 in two
# seconds. The body names its own subject — the commits range ends at the
# PREVIOUS head — and nothing looked at it.
#
# Non-vacuity is load-bearing here: the comment must actually clear the floor,
# or the case proves nothing about the edit path. Asserted below off the
# freshness log line, which prints fresh_at.
test_summary_naming_other_head_does_not_clear() {
  local dir rc before=$FAIL
  dir=$(make_case "summary-other-head" "$SUMMARY_NAMES_PREVIOUS_HEAD" "$STATUS_TIME" \
    "Review rate limited" "$SUMMARY_CREATED_BEFORE_HEAD" 999999999 "" "$HEAD_TIME" \
    "$HEAD_SHA_40" "$SUMMARY_EDITED_AFTER_HEAD")
  rc=$(run_case "$dir")
  # The comment DID survive the freshness floor — only the edit put it there.
  grep -q "fresh_at=$SUMMARY_EDITED_AFTER_HEAD" "$dir/err.log" \
    || fail "29: the edited summary never reached the poll arm, so the fixture no longer reproduces #968; err=$(grep -i 'latest CodeRabbit comment' "$dir/err.log" | tail -2)"
  [ "$rc" != "0" ] || fail "29: FALSE-CLEARED (exit 0) on a summary whose commits range names the PREVIOUS head; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" != "cleared" ] || fail "29: status=cleared on a verdict about a different commit"
  [ "$rc" = "4" ] || fail "29: expected exit 4 (timeout — nothing on this head to verdict on), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'names a different commit' "$dir/err.log" \
    || fail "29: expected a log line naming the SHA mismatch; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "29: #968 — a summary whose commits range names another commit cannot clear this head, however recently it was edited"
}

# --- Test 30: #968 AC2 — the #824 rung must not regress ---------------------
# Same edit timeline, same 40-hex head, one difference: the commits range ends
# at the CURRENT head. `created_at` still predates the head committer date, so
# only `fresh_at` admits it — and it must still clear. A demotion keyed on
# "created_at is old" rather than on the named SHA fails here.
test_summary_naming_current_head_still_clears() {
  local dir rc before=$FAIL
  dir=$(make_case "summary-current-head" "$SUMMARY_NAMES_CURRENT_HEAD" "$STATUS_TIME" \
    "Review rate limited" "$SUMMARY_CREATED_BEFORE_HEAD" 999999999 "" "$HEAD_TIME" \
    "$HEAD_SHA_40" "$SUMMARY_EDITED_AFTER_HEAD")
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "30: expected exit 0 (cleared) for a summary naming the current head, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "30: status=$(jqf "$dir" '.status'), expected cleared"
  grep -q 'names a different commit' "$dir/err.log" && fail "30: the SHA demotion fired on a summary that names THIS head"
  [ "$FAIL" -ne "$before" ] || pass "30: #968 AC2 — a summary naming the current head still clears with a created_at below the HEAD-committer floor (#824 rung intact)"
}

# --- Test 31: #968 AC3 — a summary naming NO SHA is unchanged --------------
# The demotion is scoped to bodies that make a head claim. A body carrying no
# commits range at all says nothing about which commit it covers, so the
# `fresh_at >= HEAD_ANCHOR` floor stays the only test — exactly as before.
test_summary_naming_no_sha_falls_through_to_floor() {
  local dir rc before=$FAIL
  dir=$(make_case "summary-no-sha" "$SUMMARY_NAMES_NO_SHA" "$STATUS_TIME" \
    "Review rate limited" "$SUMMARY_CREATED_BEFORE_HEAD" 999999999 "" "$HEAD_TIME" \
    "$HEAD_SHA_40" "$SUMMARY_EDITED_AFTER_HEAD")
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "31: expected exit 0 (cleared) for a summary that names no SHA, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "31: status=$(jqf "$dir" '.status'), expected cleared"
  grep -q 'names a different commit' "$dir/err.log" && fail "31: the SHA demotion fired on a body that makes no head claim"
  [ "$FAIL" -ne "$before" ] || pass "31: #968 AC3 — a summary carrying no commits range still falls through to the freshness floor unchanged"
}

# --- Test 32: #985 — emit_json_and_exit refuses an unusable review object ---
# `--argjson review "$review_json"` rejects an empty string by DYING inside jq:
# rc 2 (which every caller reads as `findings`) and NOTHING on stdout. On the
# live #957 capture that crash was the only reason a false clearance did not
# reach exit 0 — an accident, not a guard. Since #831/#942/#957/#959/#963/#965
# every reader feeding the emitter reports an unreadable surface as rc 3 with
# empty stdout, so the emitter can now be honest about the invariant instead.
#
# Extracted by sentinel and driven directly, because there is deliberately no
# live route left that reaches the emitter with an unusable value — the reader
# guards are what close them, and test 27 and the #957/#959 cases above assert
# that. This case asserts only what the emitter itself does when the invariant
# IS violated.
test_emit_json_invariant_unit() {
  local snip="$WORKDIR/emit-json.sh" harness="$WORKDIR/emit-harness.sh"
  local rc out before=$FAIL
  awk '/^# BEGIN coderabbit_emit_json$/{f=1;next} /^# END coderabbit_emit_json$/{f=0} f' \
    "$ROOT/scripts/coderabbit-wait.sh" >"$snip"
  [ -s "$snip" ] || { fail "32: the coderabbit_emit_json sentinel block is missing or empty"; return; }

  cat >"$harness" <<HARNESS
set -euo pipefail
log() { echo "[coderabbit-wait] \$*" >&2; }
die() { local code=\$1; shift; echo "[coderabbit-wait] ERROR: \$*" >&2; exit "\$code"; }
PR_NUMBER=999; REPO=owner/repo; HEAD_SHA=head-sha
HEAD_COMMITTER_DATE='$HEAD_TIME'; BOT_LOGIN='coderabbitai[bot]'
SKIP_REASON=""; FEEDBACK_POLICY_PRESENT=false; BLOCKING_TIER_UNRESOLVED=null
PROBE_MODE=false; PROBE_JSON=null; STATUS_PROBE_JSON='{"enabled":false}'
RATE_LIMIT_RETRIES=0; RESUME_RETRIES=0; CODEX_FAILOVER_REQUESTED=false
START_EPOCH=\$(date +%s)
. "$snip"
emit_json_and_exit "\$1" "\$2" "\$3" "\$4"
HARNESS

  # 1. Empty review object: exit 3 (infra), nothing on stdout, and a message
  #    naming the caller — never rc 2, which callers read as `findings`.
  rc=0; out=$(bash "$harness" cleared 0 "" 0 2>"$WORKDIR/emit-empty.err") || rc=$?
  [ "$rc" = "3" ] || fail "32: empty review object exited $rc, expected 3 (rc 2 is the jq crash that reads as findings)"
  [ -z "$out" ] || fail "32: empty review object still wrote to stdout: $out"
  grep -q 'emit_json_and_exit' "$WORKDIR/emit-empty.err" || fail "32: the refusal does not name the emitter; err=$(cat "$WORKDIR/emit-empty.err")"
  grep -qi 'jq: invalid JSON text' "$WORKDIR/emit-empty.err" && fail "32: still dying inside jq rather than refusing the invariant"

  # 2. Unparseable, non-empty: same refusal. Emptiness is not the invariant —
  #    `--argjson` usability is.
  rc=0; bash "$harness" cleared 0 'not json' 0 >"$WORKDIR/emit-bad.out" 2>"$WORKDIR/emit-bad.err" || rc=$?
  [ "$rc" = "3" ] || fail "32: unparseable review object exited $rc, expected 3"
  [ ! -s "$WORKDIR/emit-bad.out" ] || fail "32: unparseable review object still wrote JSON to stdout"

  # 2b. Codex P2 on #995: `jq empty` is a WEAKER question than the one
  #     `--argjson` asks, and the gap is not hypothetical — it exits 0 on a
  #     whitespace-only string (zero JSON values) and on two concatenated
  #     documents, both of which `--argjson` rejects. With the parse test alone
  #     the guard passed and the run still died inside jq: rc 2 with no stdout,
  #     the exact findings/infra misclassification #985 exists to remove. So
  #     the invariant is "exactly one JSON value", asserted from both sides.
  rc=0; bash "$harness" cleared 0 '   ' 0 >"$WORKDIR/emit-ws.out" 2>"$WORKDIR/emit-ws.err" || rc=$?
  [ "$rc" = "3" ] || fail "32: whitespace-only review object exited $rc, expected 3 (jq empty accepts it; --argjson does not)"
  [ ! -s "$WORKDIR/emit-ws.out" ] || fail "32: whitespace-only review object still wrote JSON to stdout"
  grep -qi 'jq: invalid JSON text' "$WORKDIR/emit-ws.err" && fail "32: whitespace-only still dying inside jq rather than refusing the invariant"
  rc=0; bash "$harness" cleared 0 '{} {}' 0 >"$WORKDIR/emit-multi.out" 2>"$WORKDIR/emit-multi.err" || rc=$?
  [ "$rc" = "3" ] || fail "32: two JSON documents exited $rc, expected 3 — each parses, but together they are not one value"
  [ ! -s "$WORKDIR/emit-multi.out" ] || fail "32: two JSON documents still wrote JSON to stdout"
  grep -qi 'jq: invalid JSON text' "$WORKDIR/emit-multi.err" && fail "32: multi-document still dying inside jq rather than refusing the invariant"

  # 3. A well-formed emission is unchanged — the guard must cost nothing on the
  #    path every caller actually takes, INCLUDING the literal `null` that the
  #    timeout / paused / skipped emits pass.
  rc=0; out=$(bash "$harness" cleared 0 '{"id":7701,"endpoint":"issues"}' 0 2>/dev/null) || rc=$?
  [ "$rc" = "0" ] || fail "32: a well-formed emission exited $rc, expected 0"
  [ "$(printf '%s' "$out" | jq -r '.review.id')" = "7701" ] || fail "32: the review object did not survive the emission: $out"
  [ "$(printf '%s' "$out" | jq -r '.status')" = "cleared" ] || fail "32: status did not survive the emission: $out"
  rc=0; out=$(bash "$harness" timeout 4 null 0 2>/dev/null) || rc=$?
  [ "$rc" = "4" ] || fail "32: the literal null review object exited $rc, expected 4 — a JSON null is a legal emission, not a violation"
  [ "$(printf '%s' "$out" | jq -r '.review')" = "null" ] || fail "32: review should emit as null, got $(printf '%s' "$out" | jq -c '.review')"

  [ "$FAIL" -ne "$before" ] || pass "32: #985 — emit_json_and_exit refuses an empty/unparseable review object with exit 3 and no stdout, and emits well-formed values (null included) unchanged"
}

# --- Test 33: #968 AC1 — a later chat reply must not restore the false clear -
# The residual the first #968 fix left: the demotion was evaluated against the
# NEWEST bot comment, not against the summary. Here the summary (id 7701) is
# the same edited, previous-head verdict test 29 uses, and a benign CodeRabbit
# chat reply (id 7702) sits above it. The reply classifies `review`, carries no
# blocking marker, and makes no head claim — so a demotion read off it is
# vacuous and the run clears in zero seconds on a verdict about another commit.
#
# Non-vacuity is asserted two ways: the poll arm must really be grading the
# REPLY (id=7702 in the freshness log, or the fixture has collapsed back into
# test 29), and the refusal must name the summary rather than that comment id.
test_later_chat_reply_does_not_restore_other_head_clear() {
  local dir rc before=$FAIL
  dir=$(make_case "summary-other-head-chat" "$SUMMARY_NAMES_PREVIOUS_HEAD" "$STATUS_TIME" \
    "Review rate limited" "$SUMMARY_CREATED_BEFORE_HEAD" 999999999 \
    "$CHAT_REPLY_AFTER_SUMMARY" "$CHAT_REPLY_TIME" "$HEAD_SHA_40" "$SUMMARY_EDITED_AFTER_HEAD")
  rc=$(run_case "$dir")
  grep -q 'latest CodeRabbit comment id=7702' "$dir/err.log" \
    || fail "33: the poll arm did not grade the chat reply, so the fixture no longer models the AC1 gap; err=$(grep -i 'latest CodeRabbit comment' "$dir/err.log" | tail -2)"
  [ "$rc" != "0" ] || fail "33: FALSE-CLEARED (exit 0) — a benign chat reply above the summary restored the #968 false clear; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" != "cleared" ] || fail "33: status=cleared on a verdict about a different commit"
  [ "$rc" = "4" ] || fail "33: expected exit 4 (timeout — nothing on this head to verdict on), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q "summary comment has no blocking markers, but its commits range names a different commit" "$dir/err.log" \
    || fail "33: the refusal is not sourced from the SUMMARY comment; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "33: #968 AC1 — the head claim is read from the marker-selected summary, so a later benign chat reply cannot clear another commit's verdict"
}

# --- Test 34: #968 AC1 escape — the summary still governs when it is current -
# Same two-comment shape, one difference: the summary's commits range ends at
# THIS head. The summary read must permit the clearance, or the fix trades a
# false clear for a permanent stall on every PR CodeRabbit chats on.
test_later_chat_reply_over_current_head_summary_still_clears() {
  local dir rc before=$FAIL
  dir=$(make_case "summary-current-head-chat" "$SUMMARY_NAMES_CURRENT_HEAD" "$STATUS_TIME" \
    "Review rate limited" "$SUMMARY_CREATED_BEFORE_HEAD" 999999999 \
    "$CHAT_REPLY_AFTER_SUMMARY" "$CHAT_REPLY_TIME" "$HEAD_SHA_40" "$SUMMARY_EDITED_AFTER_HEAD")
  rc=$(run_case "$dir")
  [ "$rc" = "0" ] || fail "34: expected exit 0 (cleared) — the summary names this head, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "34: status=$(jqf "$dir" '.status'), expected cleared"
  grep -q 'names a different commit' "$dir/err.log" && fail "34: the summary-sourced demotion fired on a summary that names THIS head"
  [ "$FAIL" -ne "$before" ] || pass "34: #968 AC1 escape — a chat reply above a CURRENT-head summary still clears, so the summary read adds refusals without adding stalls"
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
test_misclassified_summary_is_still_graded
test_failed_summary_derive_does_not_clear
test_negated_completed_description_does_not_take_fast_path
test_failed_comment_list_read_does_not_clear
test_failed_reviews_read_does_not_clear
test_failed_fast_path_comment_read_does_not_clear
test_failed_fast_path_comment_decode_does_not_clear
test_failed_poll_comment_decode_does_not_clear
test_non_array_reviews_body_does_not_clear
test_empty_reviews_array_still_clears
test_summary_naming_other_head_does_not_clear
test_summary_naming_current_head_still_clears
test_summary_naming_no_sha_falls_through_to_floor
test_later_chat_reply_does_not_restore_other_head_clear
test_later_chat_reply_over_current_head_summary_still_clears
test_emit_json_invariant_unit

echo "----"
echo "test_coderabbit_wait_statuscontext_ratelimit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
