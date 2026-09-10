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

# A benign CodeRabbit chat reply that QUOTES a commits range belonging to the
# PREVIOUS round — the shape a rebuttal takes when it cites what the earlier
# summary said, and the shape any reply quoting a diff hunk of this repository
# takes. The range is not CodeRabbit's own head claim about anything; it is
# text inside someone else's sentence. #1023: read as a claim, it vetoed a
# valid current-head summary and forced the advisory timeout.
CHAT_REPLY_QUOTING_OLD_RANGE="🧩 Analysis chain

You are right that the previous round said \"Reviewing files that changed from the base of the PR and between $BASE_SHA_40 and $PREV_HEAD_SHA_40.\" — that round is superseded."

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
  # Hard-required by coderabbit-wait.sh since #1008: both fetch wrappers
  # delegate the paginated-list algorithm to the shared reader.
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"
  # Hard-required by coderabbit-wait.sh since #837: the potential-issue count
  # grades findings with the shared coderabbit_tier_of.
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"
  # #1178: hard-sourced by the waiter, so the fixture must carry it too.
  cp "$ROOT/scripts/lib/coderabbit-fence.sh" "$dir/scripts/lib/coderabbit-fence.sh"
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
    # CODERABBIT_TEST_REVIEWS_RAW=<text> (#995): serve an arbitrary 200 body,
    # so the response modes \`add // []\` REWRITES rather than passes through
    # are drivable — a body of \`null\`, an EMPTY body, and a pagination stream
    # carrying a null page. Empty is spelled by the sentinel <EMPTY>, because a
    # set-but-empty variable is indistinguishable from an unset one here.
    if [ -n "\${CODERABBIT_TEST_REVIEWS_RAW:-}" ]; then
      if [ "\$CODERABBIT_TEST_REVIEWS_RAW" = "<EMPTY>" ]; then
        printf ''
      else
        printf '%s\n' "\$CODERABBIT_TEST_REVIEWS_RAW"
      fi
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

# --- Test 27: #1008 — the two wrappers keep DIFFERENT failure contracts -----
# The paginated-list algorithm moved to scripts/lib/gh-api-array.sh, which
# returns ONE status (3) for every unreadable response. This file keeps two
# wrappers over it whose contracts are deliberately different: the strict one
# reports the infra status 3, the best-effort one reports 1, because its
# callers treat an unreadable surface as non-fatal and handing them 3 would
# make it fatal. Sharing the algorithm must not collapse that distinction —
# the failure ACTION is exactly the part each caller still owns.
#
# The best-effort wrapper also keeps two DISTINCT messages, one per failed
# step, which is why the lib reports which step failed rather than only that
# one did. Both messages are asserted, on both stubs, so a wrapper that
# always logged the fetch wording would fail here rather than silently
# mislabel every parse failure as a transport failure.
#
# Extracted by sed and driven directly against a PATH-shimmed `gh`: this is a
# unit over the composition (wrapper + shared reader), not a whole stubbed run.
test_fetch_wrapper_contracts_unit() {
  local dir="$WORKDIR/fetch-wrapper-contracts" before=$FAIL
  local fn_strict fn_best out err
  mkdir -p "$dir/bin"
  fn_strict=$(sed -n '/^fetch_api_array() {/,/^}/p' "$ROOT/scripts/coderabbit-wait.sh")
  fn_best=$(sed -n '/^fetch_api_array_best_effort() {/,/^}/p' "$ROOT/scripts/coderabbit-wait.sh")
  if [ -z "$fn_strict" ] || [ -z "$fn_best" ]; then
    fail "27: could not extract the fetch wrappers from scripts/coderabbit-wait.sh"
    return
  fi
  if [ ! -r "$ROOT/scripts/lib/gh-api-array.sh" ]; then
    fail "27: scripts/lib/gh-api-array.sh is missing (#1008)"
    return
  fi

  # (a) transport failure — gh exits non-zero, writing its one-line
  #     diagnostic to stderr and its HTTP error BODY to stdout.
  cat >"$dir/bin/gh" <<'STUB'
#!/bin/sh
printf '%s\n' '{"message":"Server Error","status":"500"}'
printf '%s\n' 'gh: HTTP 500 upstream boom' >&2
exit 1
STUB
  chmod +x "$dir/bin/gh"

  out=$(PATH="$dir/bin:$PATH" bash -c '
    set -euo pipefail
    log() { printf "[log] %s\n" "$*" >&2; }
    . "$1"
    eval "$2"
    eval "$3"
    strict=0; v=$(fetch_api_array "repos/o/r/x" "reviews") || strict=$?
    best=0;   w=$(fetch_api_array_best_effort "repos/o/r/x" "reviews") || best=$?
    printf "strict=%s best=%s v=[%s] w=[%s]\n" "$strict" "$best" "$v" "$w"
  ' _ "$ROOT/scripts/lib/gh-api-array.sh" "$fn_strict" "$fn_best" 2>"$dir/err.log")

  [ "$out" = "strict=3 best=1 v=[] w=[]" ] \
    || fail "27a: expected strict rc 3 / best-effort rc 1 with empty stdout on both; got: $out"
  err=$(cat "$dir/err.log")
  printf '%s' "$err" | grep -q 'ERROR: failed to fetch reviews' \
    || fail "27a: the strict wrapper did not name the failed fetch; err=$err"
  printf '%s' "$err" | grep -q 'HTTP 500 upstream boom' \
    || fail "27a: the gh stderr diagnostic was lost; err=$err"
  printf '%s' "$err" | grep -q 'best-effort fetch failed for reviews' \
    || fail "27a: the best-effort wrapper lost its own fetch wording; err=$err"

  # (b) parse failure — gh SUCCEEDS with a body that is not JSON, so the
  #     fetch is fine and the flatten is what fails.
  cat >"$dir/bin/gh" <<'STUB'
#!/bin/sh
printf '%s\n' 'this is not json'
STUB
  chmod +x "$dir/bin/gh"

  out=$(PATH="$dir/bin:$PATH" bash -c '
    set -euo pipefail
    log() { printf "[log] %s\n" "$*" >&2; }
    . "$1"
    eval "$2"
    eval "$3"
    strict=0; v=$(fetch_api_array "repos/o/r/x" "reviews") || strict=$?
    best=0;   w=$(fetch_api_array_best_effort "repos/o/r/x" "reviews") || best=$?
    printf "strict=%s best=%s v=[%s] w=[%s]\n" "$strict" "$best" "$v" "$w"
  ' _ "$ROOT/scripts/lib/gh-api-array.sh" "$fn_strict" "$fn_best" 2>"$dir/err2.log")

  [ "$out" = "strict=3 best=1 v=[] w=[]" ] \
    || fail "27b: expected strict rc 3 / best-effort rc 1 with empty stdout on both; got: $out"
  err=$(cat "$dir/err2.log")
  printf '%s' "$err" | grep -q 'ERROR: failed to flatten reviews pagination output' \
    || fail "27b: the strict wrapper did not name the failed flatten; err=$err"
  printf '%s' "$err" | grep -q 'best-effort fetch failed to flatten reviews pagination output' \
    || fail "27b: the best-effort wrapper collapsed its flatten wording into the fetch one; err=$err"

  # (c) the success escape: a genuinely empty page is a READ, not a failure,
  #     and both wrappers must hand it back as `[]` with status 0. Without
  #     this the two cases above would pass on a reader that failed always.
  #
  #     The stub writes benign stderr chatter on that SUCCESSFUL call — the
  #     deprecation / retry / token-scope prose real `gh` emits on healthy
  #     calls — because that is the drift reconciliation this extraction
  #     carries (#966 reaching the other seven copies). Under the old `2>&1`
  #     capture the chatter reached the `jq -s` slurp, the flatten failed, and
  #     a healthy read was reported as unreadable; here it must not reach the
  #     payload at all. Asserting `v`/`w` are exactly `[]` is what detects a
  #     regression back to the merged-stream form: rc 0 alone would not,
  #     since a contaminated payload could still be graded as a value.
  cat >"$dir/bin/gh" <<'STUB'
#!/bin/sh
printf '%s\n' 'gh: warning: this endpoint is deprecated; retrying (1/3)' >&2
printf '%s\n' '[]'
STUB
  chmod +x "$dir/bin/gh"

  out=$(PATH="$dir/bin:$PATH" bash -c '
    set -euo pipefail
    log() { printf "[log] %s\n" "$*" >&2; }
    . "$1"
    eval "$2"
    eval "$3"
    strict=0; v=$(fetch_api_array "repos/o/r/x" "reviews") || strict=$?
    best=0;   w=$(fetch_api_array_best_effort "repos/o/r/x" "reviews") || best=$?
    printf "strict=%s best=%s v=[%s] w=[%s]\n" "$strict" "$best" "$v" "$w"
  ' _ "$ROOT/scripts/lib/gh-api-array.sh" "$fn_strict" "$fn_best" 2>"$dir/err3.log")

  [ "$out" = "strict=0 best=0 v=[[]] w=[[]]" ] \
    || fail "27c: an empty page with benign gh stderr must still read as [] with status 0 on both wrappers; got: $out"
  err=$(cat "$dir/err3.log")
  if printf '%s' "$err" | grep -q 'failed to fetch reviews'; then
    fail "27c: benign stderr on a SUCCESSFUL read was graded as a fetch failure; err=$err"
  fi
  if printf '%s' "$err" | grep -q 'failed to flatten reviews'; then
    fail "27c: benign stderr on a SUCCESSFUL read reached the jq slurp; err=$err"
  fi

  [ "$FAIL" -ne "$before" ] || pass "27: #1008 — both wrappers share one algorithm while keeping their own statuses (3 vs 1), their own wordings, the empty-page escape, and stderr isolation on a successful read"
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
  grep -q 'came back as a stream of object values, not a stream of JSON arrays' "$dir/err.log" \
    || fail "27: expected a diagnostic naming the received type; err=$(tail -4 "$dir/err.log")"
  grep -q 'repos/owner/repo/pulls/999/reviews) came back as' "$dir/err.log" \
    || fail "27: the diagnostic should name the endpoint it read; err=$(tail -4 "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "27: #967 — a 200 whose body is a JSON object is an infra exit naming the type, never an empty result"
}

# --- Test 27b: #967 ordering — the fallback must not manufacture the array ---
# Codex P2 and the Phase 4b P1 on #995. Asserting the type of the FLATTENED
# value is too late: `add // []` REWRITES three unusable response modes into a
# valid empty array before anything judges them — a body of `null`, an EMPTY
# body, and a pagination stream carrying a null page (which `add` skips in
# silence, so a partially-unreadable read looks complete). Each one is a
# confident "no reviews on this head" manufactured by the fallback, which on
# the polling arm is a clearance. The judgement therefore has to be made on the
# RAW stream, and test 28 is the control that a genuine `[]` still clears.
test_fallback_manufactured_array_does_not_clear() {
  local dir rc mode before=$FAIL
  for mode in 'null' '<EMPTY>' '[]
null'; do
    rc=0
    dir=$(make_case "reviews-fallback-$(printf '%s' "$mode" | tr -dc 'a-zA-Z' | head -c 6)x" \
      "$REVIEW_BODY_CLEAN" "$STATUS_TIME" "Review rate limited")
    (
      cd "$dir"
      PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
        CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
        CODERABBIT_TEST_STATE_DIR="$dir/state" \
        CODERABBIT_TEST_REVIEWS_RAW="$mode" \
        CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
        CODEX_STUB_LOG="$dir/state/codex-stub.log" \
        ./scripts/coderabbit-wait.sh 999 owner/repo \
        >"$dir/out.json" 2>"$dir/err.log"
    ) || rc=$?
    [ "$rc" != "0" ] \
      || fail "27b: FALSE-CLEARED (exit 0) on a reviews body of [$mode] that the empty-list fallback rewrote into []; err=$(tail -4 "$dir/err.log")"
    grep -q '"status": *"cleared"' "$dir/out.json" 2>/dev/null \
      && fail "27b: emitted a cleared verdict off a manufactured empty array for [$mode]"
    [ "$rc" = "3" ] || fail "27b: expected exit 3 (infra) for [$mode], got $rc; err=$(tail -4 "$dir/err.log")"
    grep -q 'repos/owner/repo/pulls/999/reviews) came back as' "$dir/err.log" \
      || fail "27b: the diagnostic should name the endpoint it read for [$mode]; err=$(tail -4 "$dir/err.log")"
  done
  [ "$FAIL" -ne "$before" ] || pass "27b: #967 ordering — a null body, an empty body and a null page are failed reads, not the empty list 'add // []' would have made of them"
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

# --- Test 35: #1003/#1022 — the exact-SHA rung outranks the #968 demotion ----
# Test 29's fixture exactly — a summary edited after the push whose commits
# range ends at the PREVIOUS head — with ONE addition: a CodeRabbit review
# OBJECT pinned to this head by `commit_id`, carrying a clean report body. That
# is the ladder's first rung, and `commit_id` is immutable head identity that
# no in-place edit can move.
#
# Before the fix the third rung was evaluated unconditionally, so the demotion
# fired anyway and the run polled to the advisory exit 4 — the published order
# inverted, and a head CodeRabbit had demonstrably reviewed left unclearable
# for the whole `coderabbit.max_wait_seconds` budget.
test_head_pinned_run_outranks_stale_summary() {
  local dir rc=0 before=$FAIL reviews
  dir=$(make_case "head-run-outranks" "$SUMMARY_NAMES_PREVIOUS_HEAD" "$STATUS_TIME" \
    "Review rate limited" "$SUMMARY_CREATED_BEFORE_HEAD" 999999999 "" "$HEAD_TIME" \
    "$HEAD_SHA_40" "$SUMMARY_EDITED_AFTER_HEAD")
  reviews=$(jq -nc --arg sha "$HEAD_SHA_40" '[
    {id: 5501, user: {login: "coderabbitai[bot]"}, commit_id: $sha,
     submitted_at: "2026-06-04T00:01:00Z",
     body: "**Actionable comments posted: 0**\n\nReviewed everything up to the head."}
  ]')
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_REVIEWS_RAW="$reviews" \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  [ "$rc" = "0" ] \
    || fail "35: expected exit 0 (cleared) — an immutable head-pinned review run outranks a stale summary, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "35: status=$(jqf "$dir" '.status'), expected cleared"
  grep -q 'exact-SHA rung wins outright' "$dir/err.log" \
    || fail "35: the clearance is not attributed to the head-pinned run; err=$(tail -4 "$dir/err.log")"
  grep -q 'names a different commit' "$dir/err.log" \
    && fail "35: the #968 demotion still fired despite a head-pinned clean review run"
  [ "$FAIL" -ne "$before" ] || pass "35: #1003/#1022 — a head-pinned clean review run satisfies the exact-SHA rung, so a stale summary no longer inverts the published ladder"
}

# --- Test 36: #1003 negative — the #919 body-less ack must NOT outrank -------
# The control that keeps test 35 from having widened the gate to CodeRabbit
# ACTIVITY. Same fixture, but the only head-pinned review object is the
# body-LESS one GitHub wraps around a single inline reply — CodeRabbit's
# `🐇 ✅` acknowledgement of the `[mergepath-resolve:…]` tag reply the
# review-loop rules make us post on every finding thread. A reply starts no
# run, so the demotion must still decide and the run must still refuse.
test_bodyless_ack_does_not_outrank_stale_summary() {
  local dir rc=0 before=$FAIL reviews
  dir=$(make_case "bodyless-ack-no-outrank" "$SUMMARY_NAMES_PREVIOUS_HEAD" "$STATUS_TIME" \
    "Review rate limited" "$SUMMARY_CREATED_BEFORE_HEAD" 999999999 "" "$HEAD_TIME" \
    "$HEAD_SHA_40" "$SUMMARY_EDITED_AFTER_HEAD")
  reviews=$(jq -nc --arg sha "$HEAD_SHA_40" '[
    {id: 5502, user: {login: "coderabbitai[bot]"}, commit_id: $sha,
     submitted_at: "2026-06-04T00:01:00Z", body: ""}
  ]')
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_REVIEWS_RAW="$reviews" \
      CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
      CODEX_STUB_LOG="$dir/state/codex-stub.log" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  [ "$rc" != "0" ] \
    || fail "36: FALSE-CLEARED (exit 0) — a body-less inline-reply review object was taken as a review run; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" != "cleared" ] || fail "36: status=cleared on a verdict about a different commit"
  [ "$rc" = "4" ] || fail "36: expected exit 4 (timeout), got $rc; err=$(tail -4 "$dir/err.log")"
  grep -q 'names a different commit' "$dir/err.log" \
    || fail "36: expected the #968 demotion to still decide; err=$(tail -4 "$dir/err.log")"
  grep -q 'exact-SHA rung wins outright' "$dir/err.log" \
    && fail "36: a body-less acknowledgement was credited as satisfying the exact-SHA rung"
  [ "$FAIL" -ne "$before" ] || pass "36: #1003 negative — the #919 body-less acknowledgement still does not outrank the summary demotion"
}

# --- Test 37: #1023 — a QUOTED commits range is not CodeRabbit's head claim --
# The summary names THIS head, so the ladder says clear. Above it sits a benign
# chat reply that quotes the previous round's commits range. The removed second
# carrier applied the demotion predicate to `$COMMENT_BODY` — merely the newest
# bot comment — so that quotation vetoed a valid current-head summary and the
# run polled to the advisory exit 4.
#
# Non-vacuity is asserted the way test 33 does it: the poll arm must really be
# grading the reply (id=7702), or the fixture has collapsed into test 30.
test_quoted_range_in_chat_reply_does_not_veto_current_head() {
  local dir rc before=$FAIL
  dir=$(make_case "quoted-range-chat" "$SUMMARY_NAMES_CURRENT_HEAD" "$STATUS_TIME" \
    "Review rate limited" "$SUMMARY_CREATED_BEFORE_HEAD" 999999999 \
    "$CHAT_REPLY_QUOTING_OLD_RANGE" "$CHAT_REPLY_TIME" "$HEAD_SHA_40" "$SUMMARY_EDITED_AFTER_HEAD")
  rc=$(run_case "$dir")
  grep -q 'latest CodeRabbit comment id=7702' "$dir/err.log" \
    || fail "37: the poll arm did not grade the quoting reply, so the fixture no longer models #1023; err=$(grep -i 'latest CodeRabbit comment' "$dir/err.log" | tail -2)"
  [ "$rc" = "0" ] \
    || fail "37: expected exit 0 (cleared) — a quoted range in a chat reply is not CodeRabbit's own head claim, got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "cleared" ] || fail "37: status=$(jqf "$dir" '.status'), expected cleared"
  grep -q 'names a different commit' "$dir/err.log" \
    && fail "37: the demotion fired on a range quoted by a comment that is not the summary"
  [ "$FAIL" -ne "$before" ] || pass "37: #1023 — the demotion reads the marker-selected summary's OWN commits range, so a reply quoting an old range no longer forces a timeout"
}

# --- Test 38: #1005 — a rate-limit notice past the pipe buffer still suppresses
# The end-to-end half of the classifier sweep. `classify_comment` fed its body
# to `grep -q` through a producer pipe under `set -o pipefail`: once the body
# outran the 64 KiB pipe buffer and the marker sat near the start, the producer
# took SIGPIPE, the pipeline reported 141, and the notice fell out of
# `rate_limit` into the `review` default — the one class whose arm clears.
# Measured on the pre-fix idiom at 245894 bytes: rc 141, class `review`.
#
# The fixture is test 1's exactly, with a ~98 KiB tail appended. Two assertions
# beyond the exit code, because two predicates on this route share the idiom:
# the class must be `rate_limit` (classify_comment) AND the notice must be seen
# to reference HEAD (the fast-path's own `grep -Fq "$HEAD_SHA"`).
#
# The size sits inside a WINDOW, and both ends are asserted below. The lower
# bound is the 64 KiB pipe buffer, without which the case proves nothing. The
# upper bound is Linux's per-argument `MAX_ARG_STRLEN` — 32 pages, 131072 bytes
# — because the gh STUB hands this body to `jq --arg body`, which is an exec:
# a 200 KiB fixture passed on macOS and died on Linux CI with
# `/usr/bin/jq: Argument list too long`, turning a portability limit of the
# harness into three product-looking failures. It is the stub's marshalling
# that is bounded, not the predicate under test; the pure classifier unit in
# tests/test_coderabbit_wait_status_probe.sh drives 200 KiB through bash
# builtins and a here-string, where no exec boundary applies.
test_large_rate_limit_body_still_suppresses_status() {
  local dir rc before=$FAIL pad big
  pad=$(printf '%*s' 100000 '' | tr ' ' 'x')
  big="$RATE_LIMIT_BODY_HEADREF

$pad"
  [ "${#big}" -gt 65536 ] || fail "38: the fixture body is not past the pipe buffer (${#big} bytes)"
  [ "${#big}" -lt 131072 ] \
    || fail "38: the fixture body exceeds Linux MAX_ARG_STRLEN (${#big} bytes) — the gh stub's jq exec would die with 'Argument list too long' before the predicate is reached"
  dir=$(make_case "headref-rl-large" "$big")
  rc=$(run_case "$dir")
  [ "$rc" != "0" ] \
    || fail "38: FALSE-CLEARED (exit 0) — a HEAD-referencing rate-limit notice past the pipe buffer graded as a completed review; err=$(tail -4 "$dir/err.log")"
  [ "$rc" = "5" ] || fail "38: expected exit 5 (rate_limit_stalled after suppression), got $rc; err=$(tail -4 "$dir/err.log")"
  [ "$(jqf "$dir" '.status')" = "rate_limit_stalled" ] || fail "38: status=$(jqf "$dir" '.status'), expected rate_limit_stalled"
  grep -q 'class=rate_limit references current HEAD' "$dir/err.log" \
    || fail "38: the large notice was not classified rate_limit AND seen to reference HEAD; err=$(grep -i statuscontext "$dir/err.log" | tail -2)"
  [ "$FAIL" -ne "$before" ] || pass "38: #1005 — a rate-limit notice past the 64 KiB pipe buffer still classifies rate_limit and still suppresses the StatusContext fast path"
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
test_rate_limit_masking_a_blocking_marker_unit() {
  # #1178. classify_comment is marker-FIRST (#593), so a summarize comment that
  # CodeRabbit edited to add a rate-limit stanza reads `rate_limit` and
  # short-circuits the probe before summary_blocking_marker_present is ever
  # reached. That was harmless while every rate_limit read as not-yet at the
  # Phase 4b barrier — the budget expired and a human read the summary. #1178
  # lets a rate-limited head OPEN that barrier on a Codex report alone, so a
  # bare refusal now has to mean there is nothing unread behind it.
  #
  # Pure predicate, so assert it directly: extract the guard block plus the two
  # blocks it depends on, exactly as test_851_summary_helpers_unit does.
  local snip="$WORKDIR/rl-guard.sh" helpers="$WORKDIR/rl-summary-helpers.sh"
  local classifier="$WORKDIR/rl-classifier.sh" bad=""
  local plain_limit masked_limit table_only plain_review
  local h40='0123456789abcdef0123456789abcdef01234567'
  local b40='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  eval "$(grep -E '^(CR_SUMMARY_BENIGN_STANZA_RE|CR_PRE_MERGE_BLOCK_START|CR_PRE_MERGE_BLOCK_END|RATE_LIMIT_MARKER|PAUSED_MARKER|IN_PROGRESS_MARKER|SUMMARY_MARKER)=' \
    "$ROOT/scripts/coderabbit-wait.sh")"
  awk '/^# BEGIN coderabbit_summary_helpers$/{f=1;next} /^# END coderabbit_summary_helpers$/{f=0} f' \
    "$ROOT/scripts/coderabbit-wait.sh" >"$helpers"
  awk '/^# BEGIN coderabbit_comment_classifier$/{f=1;next} /^# END coderabbit_comment_classifier$/{f=0} f' \
    "$ROOT/scripts/coderabbit-wait.sh" >"$classifier"
  awk '/^# BEGIN coderabbit_rate_limit_marker_guard$/{f=1;next} /^# END coderabbit_rate_limit_marker_guard$/{f=0} f' \
    "$ROOT/scripts/coderabbit-wait.sh" >"$snip"
  [ -s "$snip" ] || { fail "1178: the coderabbit_rate_limit_marker_guard sentinel block is missing or empty"; return; }
  # shellcheck source=../scripts/lib/feedback-policy-helpers.sh
  . "$ROOT/scripts/lib/feedback-policy-helpers.sh"
  # The shared CommonMark fence reader the range predicates now go through.
  # shellcheck source=../scripts/lib/coderabbit-fence.sh
  . "$ROOT/scripts/lib/coderabbit-fence.sh"
  # shellcheck disable=SC1090
  . "$helpers"
  # shellcheck disable=SC1090
  . "$classifier"
  # shellcheck disable=SC1090
  . "$snip"

  plain_limit="$SUMMARY_MARKER
$RATE_LIMIT_MARKER
Review rate limited."
  masked_limit="$SUMMARY_MARKER
$RATE_LIMIT_MARKER
Review rate limited.

_⚠️ Potential issue_

The barrier can open over this."
  # A hygiene ⚠️ inside the pre-merge check table is NOT a finding — the
  # predicate this guard delegates to already strips that block, and 3 of 5
  # sampled summaries carry one. Asserted here so the guard cannot be
  # "fixed" later by reaching past summary_blocking_marker_present.
  table_only="$SUMMARY_MARKER
$RATE_LIMIT_MARKER
Review rate limited.
$CR_PRE_MERGE_BLOCK_START
| Docstring Coverage | ⚠️ Warning | 38% |
$CR_PRE_MERGE_BLOCK_END"
  plain_review="$SUMMARY_MARKER
_⚠️ Potential issue_"

  # The premise: both bodies classify rate_limit, marker-first, so the class
  # alone cannot tell them apart. Without this the rest proves nothing.
  [ "$(classify_comment "$plain_limit")" = rate_limit ]  || bad="$bad premise-plain"
  [ "$(classify_comment "$masked_limit")" = rate_limit ] || bad="$bad premise-masked"
  [ "$(classify_comment "$table_only")" = rate_limit ]   || bad="$bad premise-table"

  # A masked marker is caught; a bare refusal is not disturbed. No commits range
  # in any of these, which is the fail-CLOSED side of the demotion below.
  crw_rate_limit_masks_blocking_marker rate_limit "$masked_limit" || bad="$bad masked-missed"
  ! crw_rate_limit_masks_blocking_marker rate_limit "$plain_limit" || bad="$bad plain-flagged"
  ! crw_rate_limit_masks_blocking_marker rate_limit "$table_only"  || bad="$bad table-flagged"
  ! crw_rate_limit_masks_blocking_marker rate_limit ""             || bad="$bad empty-flagged"

  # Codex P1 round 4: the STALE-HEAD HOSTAGE, the inverse failure of the
  # two-comment case. CodeRabbit edits one summary in place across revisions, so
  # an old-head summary still carrying a marker can pick up a rate-limit stanza
  # after a push. Escalating on that forces the manual fallback for a PRIOR
  # head's finding — a false escalate that defeats the partial-quorum path
  # rather than a false clear.
  #
  # The demotion is `summary_names_only_other_head`, not a `summary_names_head`
  # requirement: a body with NO range at all must still escalate (asserted
  # above), because absence of a range proves nothing about which head the
  # marker belongs to.
  local rl_this_head rl_other_head
  rl_this_head="$RATE_LIMIT_MARKER
Review between $b40 and $h40.

_⚠️ Potential issue_"
  rl_other_head="$RATE_LIMIT_MARKER
Review between $b40 and $b40.

_⚠️ Potential issue_"
  crw_rate_limit_masks_blocking_marker rate_limit "$rl_this_head" "$h40" \
    || bad="$bad head-ranged-missed"
  ! crw_rate_limit_masks_blocking_marker rate_limit "$rl_other_head" "$h40" \
    || bad="$bad stale-head-hostage"
  # Belt and braces on the fail direction: an unrangeable masked body still
  # escalates even when a head is supplied.
  crw_rate_limit_masks_blocking_marker rate_limit "$masked_limit" "$h40" \
    || bad="$bad norange-demoted"

  # Codex P1 round 5: a QUOTED range must not demote. The demotion suppresses an
  # escalation, so a fenced `between <old> and <old>` that the raw grep counted
  # as the summary's own anchor was a fail-OPEN input — a masked finding
  # reported as a bare refusal, which the barrier then opens on. The gate's copy
  # of this predicate was hardened for the same shape on #886; this asserts the
  # waiter's copy now answers identically. Both fence characters, because a
  # backtick-only reader walks straight past a `~~~` quote.
  local rl_fenced_backtick rl_fenced_tilde
  rl_fenced_backtick="$RATE_LIMIT_MARKER
_⚠️ Potential issue_

\`\`\`
Review between $b40 and $b40.
\`\`\`"
  rl_fenced_tilde="$RATE_LIMIT_MARKER
_⚠️ Potential issue_

~~~
Review between $b40 and $b40.
~~~"
  crw_rate_limit_masks_blocking_marker rate_limit "$rl_fenced_backtick" "$h40" \
    || bad="$bad fenced-backtick-demoted"
  crw_rate_limit_masks_blocking_marker rate_limit "$rl_fenced_tilde" "$h40" \
    || bad="$bad fenced-tilde-demoted"
  # Control: the SAME range unfenced still demotes, so the assertions above are
  # about fencing rather than about the range never matching.
  ! crw_rate_limit_masks_blocking_marker rate_limit "$rl_other_head" "$h40" \
    || bad="$bad control-unfenced-not-demoted"

  # Pin the SIGN of the unreadable-body rung. This copy of the range predicate
  # is 0/1 while the severity gate's is three-rung (rc 3 = could not read), and
  # the demotion's `!` inverts a wrong-branch non-zero into a SUPPRESS. So
  # "unreadable" must reach `escalate`, not `suppress` — a body of pure fence
  # noise yields no unfenced range at all, which is the same path an unreadable
  # one takes. Without this, unifying the two predicates could flip the sign
  # invisibly at the call site.
  local rl_all_fenced
  rl_all_fenced="$RATE_LIMIT_MARKER
_⚠️ Potential issue_

\`\`\`\`
Review between $b40 and $b40.
\`\`\`\`"
  crw_rate_limit_masks_blocking_marker rate_limit "$rl_all_fenced" "$h40" \
    || bad="$bad unreadable-rung-suppressed"

  # Pin `scan`'s whole-body default in summary_blocking_marker_present, which is
  # the ACTUAL reason this guard is fail-closed when the #1038 pipeline loses its
  # delimiters — not the abort semantics it looks like, since `... || return 1`
  # suspends errexit for the whole call. Losing the delimiters WIDENS the scan
  # instead of blinding it. A #1038 fix that initialises `scan=""`, makes the
  # narrowed block the default, or adds `|| return 1` to the `s_line=`
  # assignment would flip this to a false clear, and nothing else would notice.
  #
  # A body with a marker and NO pre-merge delimiters at all takes exactly that
  # widened path.
  local rl_no_delims
  rl_no_delims="$RATE_LIMIT_MARKER
Review rate limited.

_⚠️ Potential issue_"
  case "$rl_no_delims" in
    *"$CR_PRE_MERGE_BLOCK_START"*) bad="$bad no-delims-fixture-has-delims" ;;
  esac
  crw_rate_limit_masks_blocking_marker rate_limit "$rl_no_delims" "$h40" \
    || bad="$bad scan-default-not-whole-body"

  # The rc-3 rung (Codex P1 round 6). Both guards consume a range predicate that
  # could not previously say "I could not read this", and their fail directions
  # on that answer were OPPOSITE and neither was chosen: the masking guard
  # inverts it (unreadable → escalate, safe by luck), while the head-summary
  # guard did not (unreadable → "belongs to another head" → SUPPRESS, which
  # opens the barrier past a published finding). Both must now report 3, so the
  # caller can treat it as infrastructure rather than as a verdict.
  #
  # Simulated by making the shared reader fail, which is the real failure mode —
  # a locale/encoding error or pathological input inside awk.
  # Built locally rather than reusing a fixture assigned further down this
  # function — the first attempt at this test referenced one before its
  # assignment and aborted on `unbound variable` instead of asserting anything.
  local _rc3_head_pinned _real_reader _rc
  _rc3_head_pinned="$SUMMARY_MARKER
Review between $b40 and $h40.

_⚠️ Potential issue_"
  _real_reader=$(declare -f crw_unfenced_body)
  crw_unfenced_body() { return 3; }
  _rc=0; crw_rate_limit_masks_blocking_marker rate_limit "$masked_limit" "$h40" || _rc=$?
  [ "$_rc" = 3 ] || bad="$bad masking-guard-rc3=$_rc"
  _rc=0; crw_head_summary_holds_blocking_marker "$h40" "$_rc3_head_pinned" || _rc=$?
  [ "$_rc" = 3 ] || bad="$bad head-summary-guard-rc3=$_rc"
  eval "$_real_reader"
  # Control: with the real reader back, the same inputs give real verdicts, so
  # the assertions above are about the rung and not about a wedged harness.
  crw_rate_limit_masks_blocking_marker rate_limit "$masked_limit" "$h40" \
    || bad="$bad reader-not-restored"

  # The marker scan itself must NOT be tri-state (Codex P1 round 7). Round 6
  # made summary_blocking_marker_present return 3 and audited only two of its
  # eight callers; six consume it as a boolean, so a reader failure became a
  # CLEAN result at three of them. It now falls back to scanning the RAW body —
  # strictly wider text, so the marker is still found and the answer is still
  # `true`, which is the fail-closed direction and needs no caller to change.
  crw_unfenced_body() { return 3; }
  _rc=0; summary_blocking_marker_present "$masked_limit" || _rc=$?
  [ "$_rc" = 0 ] || bad="$bad marker-scan-not-boolean-failclosed=$_rc"
  eval "$_real_reader"

  # Pre-merge delimiters are located in the UNFENCED text (Codex P1 round 7). A
  # fenced quote of the START delimiter above a genuine finding, with the real
  # table end below it, used to make the strip span from the quote to that end
  # and delete the finding in between. The marker here sits between the two, so
  # a raw-body delimiter scan loses it and this returns false.
  local rl_quoted_delim
  rl_quoted_delim="$RATE_LIMIT_MARKER
\`\`\`
$CR_PRE_MERGE_BLOCK_START
\`\`\`

_⚠️ Potential issue_

$CR_PRE_MERGE_BLOCK_START
| Docstring Coverage | ⚠️ Warning | 38% |
$CR_PRE_MERGE_BLOCK_END"
  summary_blocking_marker_present "$rl_quoted_delim" \
    || bad="$bad quoted-delimiter-stripped-real-finding"

  # The SAME body with the reader FAILING (Codex P1 round 8). Round 7's fallback
  # handed the raw body to the delimiter search, so the quoted start paired with
  # the real end and the strip deleted the genuine marker — the widened scan
  # reasoned to be fail-closed could delete more than it saw. The fallback must
  # skip structural stripping entirely, not merely widen its input.
  crw_unfenced_body() { return 3; }
  summary_blocking_marker_present "$rl_quoted_delim" \
    || bad="$bad reader-failure-strip-ate-the-finding"
  eval "$_real_reader"

  # Scoped to rate_limit ONLY. paused and in_progress still map to not-yet at
  # the barrier, so they keep reaching a human through the bounded wait;
  # widening the guard would turn their self-clearing holds into immediate
  # escalations for a hazard they do not have.
  ! crw_rate_limit_masks_blocking_marker paused "$masked_limit"      || bad="$bad paused-scoped"
  ! crw_rate_limit_masks_blocking_marker in_progress "$masked_limit" || bad="$bad inprogress-scoped"
  ! crw_rate_limit_masks_blocking_marker review "$plain_review"      || bad="$bad review-scoped"
  ! crw_rate_limit_masks_blocking_marker "" "$masked_limit"          || bad="$bad empty-class-scoped"

  # Codex P1 round 3: the TWO-COMMENT shape. The sibling predicate reads only
  # the newest notice, so a head-pinned summary holding the finding and a
  # separate later rate-limit notice slip past it — and the no-review-object
  # triage's probe_not_yet exits before the marker-selected summary scan that
  # would have caught it. crw_head_summary_holds_blocking_marker closes that.
  # Two distinct 40-hex SHAs: the head this probe is about, and an unrelated
  # one standing in for a PRIOR head, so the head-identity conjunct is tested
  # rather than assumed.
  local head_marked other_head_marked head_clean
  head_marked="$SUMMARY_MARKER
Review between $b40 and $h40.

_⚠️ Potential issue_"
  other_head_marked="$SUMMARY_MARKER
Review between $b40 and $b40.

_⚠️ Potential issue_"
  head_clean="$SUMMARY_MARKER
Review between $b40 and $h40.

No actionable comments."
  crw_head_summary_holds_blocking_marker "$h40" "$head_marked" || bad="$bad twocomment-missed"
  # Head identity is the whole safety of it: a PRIOR head's summary (#789) must
  # not hold this head hostage, and a clean head-pinned summary must not either.
  ! crw_head_summary_holds_blocking_marker "$h40" "$other_head_marked" || bad="$bad twocomment-otherhead"
  ! crw_head_summary_holds_blocking_marker "$h40" "$head_clean"        || bad="$bad twocomment-clean"
  ! crw_head_summary_holds_blocking_marker "$h40" ""                   || bad="$bad twocomment-empty"
  ! crw_head_summary_holds_blocking_marker "" "$head_marked"           || bad="$bad twocomment-nohead"
  # The class is deliberately unconstrained: a summary that ITSELF classifies
  # rate_limit is the very shape being guarded against, so requiring `review`
  # here would reopen the hole from the other side.
  crw_head_summary_holds_blocking_marker "$h40" "$RATE_LIMIT_MARKER
$head_marked" || bad="$bad twocomment-ratelimited-summary"

  # The CONSOLIDATED all-surfaces helper (#1178 round 9). Four rounds found the
  # same defect at four doors because each exit knew a different subset of
  # surfaces; this asks once, over all of them. The surface added last is the
  # review OBJECT's own body — which the spec calls the PRIMARY summary surface
  # and which none of the per-site blocks ever read.
  #
  # `comments` is passed empty so these assertions isolate the notice and
  # review-body surfaces without needing a marker-selected summary fixture.
  local _rob_clean _rob_marked
  _rob_clean="No actionable comments."
  _rob_marked="**Actionable comments posted: 1**

_🟠 Major_ something is wrong here."
  # review body carries the finding, notice is bare → escalate
  crw_rate_limit_hides_a_finding "$h40" "$plain_limit" "$_rob_marked" "" \
    || bad="$bad review-object-body-not-scanned"
  # both clean → bare refusal
  _rc=0; crw_rate_limit_hides_a_finding "$h40" "$plain_limit" "$_rob_clean" "" || _rc=$?
  [ "$_rc" = 1 ] || bad="$bad clean-surfaces-not-bare=$_rc"
  # notice itself masked → escalate even with a clean review body
  crw_rate_limit_hides_a_finding "$h40" "$masked_limit" "$_rob_clean" "" \
    || bad="$bad notice-surface-lost-in-consolidation"
  # A marker PAST BYTE 200 must still be found (#1178 round 10, found
  # independently by both reviewers). The first version of the review-object
  # surface was handed `.body_excerpt`, a 200-char logging field, so it scanned a
  # truncated document. This fixture puts the marker well past that boundary; it
  # fails if anyone reintroduces an excerpt at the call site or truncates inside
  # the helper.
  local _rob_late
  _rob_late="**Actionable comments posted: 1**

$(printf 'x%.0s' $(seq 1 400))

_🟠 Major_ the marker is past byte 200."
  [ "${#_rob_late}" -gt 400 ] || bad="$bad late-marker-fixture-too-short"
  crw_rate_limit_hides_a_finding "$h40" "$plain_limit" "$_rob_late" "" \
    || bad="$bad review-body-truncated-at-200"

  # An EMPTY review body must not read as "no finding on the primary surface"
  # (CodeRabbit Major, round 11). The call site now fails closed on an unusable
  # id or an empty round-trip, but the helper's own contract matters too: an
  # empty review_body means that surface was not read, so the verdict must come
  # from the OTHER surfaces rather than silently counting this one as clean.
  # Here the notice is masked, so the answer is escalate either way — the point
  # is that an empty review body neither suppresses nor manufactures a verdict.
  crw_rate_limit_hides_a_finding "$h40" "$masked_limit" "" "" \
    || bad="$bad empty-review-body-suppressed-notice-surface"
  _rc=0; crw_rate_limit_hides_a_finding "$h40" "$plain_limit" "" "" || _rc=$?
  [ "$_rc" = 1 ] || bad="$bad empty-review-body-manufactured-verdict=$_rc"

  # The CALL SITE's fail-closed guards for a body-bearing review with no usable
  # ID, and for an ID that does not round-trip (CodeRabbit Major, round 11).
  # crw_select_head_pinned_review_run permits a body-bearing review whose id is
  # missing, and the first version of the full-body re-read left rl_rbody empty
  # in that case — which the helper skips, so the PRIMARY surface silently went
  # unscanned.
  #
  # Asserted structurally rather than end-to-end, and the reason is worth
  # stating: both guards are `die 3` inside probe_emit_verdict, which the unit
  # harness cannot enter without a full probe fixture, and a behavioural test
  # that drove the whole probe would assert on the exit code rather than on
  # which branch produced it. The helper's own contract for an empty body IS
  # covered behaviourally above; this pins that the call site never reaches it
  # with an unread surface.
  local _src="$ROOT/scripts/coderabbit-wait.sh"
  grep -q "case \"\$rl_rid\" in" "$_src" \
    || bad="$bad callsite-missing-id-guard-absent"
  grep -q '\[ -n "\$rl_rbody" \] || die 3' "$_src" \
    || bad="$bad callsite-empty-body-guard-absent"
  # Control: the guards must sit BEFORE the helper call, not after it.
  if ! awk '/case "\$rl_rid" in/{a=NR} /crw_rate_limit_hides_a_finding "\$HEAD_SHA" "\$newest_body"/{b=NR} END{exit !(a && b && a < b)}' "$_src"; then
    bad="$bad callsite-guard-after-use"
  fi

  # reader failure anywhere → rc 3, never a verdict
  crw_unfenced_body() { return 3; }
  _rc=0; crw_rate_limit_hides_a_finding "$h40" "$masked_limit" "$_rob_clean" "" || _rc=$?
  [ "$_rc" = 3 ] || bad="$bad consolidated-rc3=$_rc"
  eval "$_real_reader"

  if [ -z "$bad" ]; then
    pass "1178: a masked rate-limit stanza AND the two-comment head-pinned-summary shape both escalate; bare refusals, hygiene tables, prior heads and non-rate_limit classes do not"
  else
    fail "1178: rate-limit marker guard wrong:$bad"
  fi
}

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
test_fallback_manufactured_array_does_not_clear
test_empty_reviews_array_still_clears
test_summary_naming_other_head_does_not_clear
test_summary_naming_current_head_still_clears
test_summary_naming_no_sha_falls_through_to_floor
test_later_chat_reply_does_not_restore_other_head_clear
test_later_chat_reply_over_current_head_summary_still_clears
test_head_pinned_run_outranks_stale_summary
test_bodyless_ack_does_not_outrank_stale_summary
test_quoted_range_in_chat_reply_does_not_veto_current_head
test_large_rate_limit_body_still_suppresses_status
test_emit_json_invariant_unit
test_fetch_wrapper_contracts_unit
test_rate_limit_masking_a_blocking_marker_unit

echo "----"
echo "test_coderabbit_wait_statuscontext_ratelimit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
