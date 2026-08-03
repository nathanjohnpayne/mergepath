#!/usr/bin/env bash
# Regression coverage for coderabbit-wait.sh's timeout status probe (#417).
#
# Runs the real helper from a temp repo with stubbed gh/date/sleep so the
# timeout and rate-limit paths are deterministic and make no GitHub writes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-wait-status-probe.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

make_case() {
  local name=$1
  local max_wait=$2
  local probe_enabled=$3
  local probe_wait=$4
  local max_retries=$5
  # #814: the --probe cases pin this to 0 to prove the probe returns BEFORE
  # the resume-budget check, which would otherwise exit 6 with
  # skip_reason=paused on the first pause sighting. Defaults to the script's
  # own default so every pre-existing caller is unchanged.
  local max_resume_retries=${6:-2}
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/coderabbit-wait.sh" "$dir/scripts/coderabbit-wait.sh"
  cp "$ROOT/scripts/lib/gh-token-resolver.sh" "$dir/scripts/lib/gh-token-resolver.sh"
  cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$dir/scripts/lib/reviewers-helpers.sh"
  chmod +x "$dir/scripts/coderabbit-wait.sh"

  cat >"$dir/.github/review-policy.yml" <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
  max_wait_seconds: $max_wait
  status_probe_enabled: $probe_enabled
  status_probe_wait_seconds: $probe_wait
  max_rate_limit_retries: $max_retries
  max_resume_retries: $max_resume_retries
  wallclock_freshness_window_seconds: 999999999
  trust_status_context_for_clearance: false
EOF

  cat >"$dir/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=${CODERABBIT_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
if [ ! -f "$clock_file" ]; then
  printf '2000000000\n' >"$clock_file"
fi

if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
  cat "$clock_file"
  exit 0
fi

exec /bin/date "$@"
EOF
  chmod +x "$dir/bin/date"

  cat >"$dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=${CODERABBIT_TEST_STATE_DIR:?}
clock_file="$state_dir/fake-time"
if [ ! -f "$clock_file" ]; then
  printf '2000000000\n' >"$clock_file"
fi

duration=${1:-0}
case "$duration" in
  *.*) duration=${duration%%.*} ;;
esac
current=$(cat "$clock_file")
printf '%s\n' $((current + duration)) >"$clock_file"
EOF
  chmod +x "$dir/bin/sleep"

  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir=${CODERABBIT_TEST_STATE_DIR:?}
scenario=${CODERABBIT_TEST_SCENARIO:?}
bot='coderabbitai[bot]'
head_time='2026-06-04T00:00:00Z'
probe_time='2026-06-04T00:00:01Z'
reply_time='2026-06-04T00:00:06Z'

fake_now() {
  local clock_file="$state_dir/fake-time"
  if [ -f "$clock_file" ]; then
    cat "$clock_file"
  else
    printf '2000000000\n'
  fi
}

json_string() {
  jq -Rn --arg s "$1" '$s'
}

if [ "${1:-}" != "api" ]; then
  echo "unexpected gh command: $*" >&2
  exit 99
fi
shift

method="GET"
if [ "${1:-}" = "--method" ]; then
  method=${2:-}
  shift 2
fi

paginate=false
if [ "${1:-}" = "--paginate" ]; then
  paginate=true
  shift
fi

endpoint=${1:-}
shift || true

if [ "$method" = "POST" ]; then
  body=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f)
        case "${2:-}" in
          body=*) body=${2#body=} ;;
        esac
        shift 2
        ;;
      *) shift ;;
    esac
  done
  case "$endpoint" in
    repos/owner/repo/issues/999/comments)
      if [ "$scenario" = "probe_post_failure" ]; then
        echo "simulated probe post failure" >&2
        exit 42
      fi
      count=0
      if [ -f "$state_dir/probe-count" ]; then
        count=$(cat "$state_dir/probe-count")
      fi
      count=$((count + 1))
      printf '%s\n' "$count" >"$state_dir/probe-count"
      printf '%s\n' "$body" >>"$state_dir/probe-bodies"
      printf '{"id":900%s,"created_at":"%s","body":%s}\n' "$count" "$probe_time" "$(json_string "$body")"
      ;;
    *)
      echo "unexpected gh api POST endpoint: $endpoint" >&2
      exit 99
      ;;
  esac
  exit 0
fi

case "$endpoint" in
  repos/owner/repo/pulls/999)
    printf '{"head":{"sha":"head-sha"}}\n'
    ;;
  repos/owner/repo/commits/head-sha)
    if [ "${1:-}" = "--jq" ]; then
      printf '%s\n' "$head_time"
    else
      printf '{"commit":{"committer":{"date":"%s"}}}\n' "$head_time"
    fi
    ;;
  repos/owner/repo/issues/999/timeline)
    printf '[]\n'
    ;;
  repos/owner/repo/commits/head-sha/statuses)
    # #814 matrix: the StatusContext surface. CODERABBIT_TEST_STATUS selects
    # the CodeRabbit context state so the sweep can drive the
    # trust_status_context_for_clearance path, which the hand-written cases
    # below never exercise. CODERABBIT_TEST_STATUS_TIME (#875 round 2)
    # positions the status in time — the temporal-correlation legs order it
    # against the finished comment and the head review object; it defaults
    # to head_time, which PREDATES reply_time-stamped evidence, so tests
    # exercising the correlated direction must set it explicitly.
    case "${CODERABBIT_TEST_STATUS:-absent}" in
      success|failure|pending)
        printf '[{"context":"CodeRabbit","state":"%s","created_at":"%s","updated_at":"%s","creator":{"login":"%s"}}]\n' \
          "${CODERABBIT_TEST_STATUS}" "${CODERABBIT_TEST_STATUS_TIME:-$head_time}" "${CODERABBIT_TEST_STATUS_TIME:-$head_time}" "$bot"
        ;;
      *) printf '[]\n' ;;
    esac
    ;;
  repos/owner/repo/pulls/999/reviews)
    case "$scenario" in
      review_arrives_during_probe)
        count=0
        if [ -f "$state_dir/probe-count" ]; then
          count=$(cat "$state_dir/probe-count")
        fi
        if [ "$count" -gt 0 ] && [ "$(fake_now)" -ge 2000000006 ]; then
          printf '[{"id":9901,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"}]\n' "$bot" "$reply_time"
        else
          printf '[]\n'
        fi
        ;;
      summary_marker_only)
        # #535.1: one CodeRabbit review on HEAD, no inline findings, but the
        # PR-level summary body carries a Potential issue marker.
        printf '[{"id":9921,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"}]\n' "$bot" "$head_time"
        ;;
      probe_review_on_head)
        # #814: a genuine CodeRabbit review already on HEAD. --probe must
        # return the SAME terminal verdict the polling mode does.
        printf '[{"id":9941,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"}]\n' "$bot" "$head_time"
        ;;
      probe_review_object_premerge_warning)
        printf '[{"id":9991,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"}]\n' "$bot" "$head_time"
        ;;
      probe_notice_after_review)
        # #814 round 9: HEAD review exists; the only later bot comment is a
        # rate-limit notice, so publication is NOT complete.
        printf '[{"id":9981,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"}]\n' "$bot" "$head_time"
        ;;
      probe_narration_after_review|probe_narration_over_notice)
        # #833: HEAD review exists; the later bot comments include a
        # status-probe narration reply (issues endpoint below).
        printf '[{"id":9983,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"}]\n' "$bot" "$head_time"
        ;;
      probe_review_finished_limit_note)
        # #869: the live #866 shape — TWO COMMENTED review objects pinned to
        # the exact head. The newest (9988) is the probe's evidence.
        printf '[{"id":9987,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha","state":"COMMENTED"},{"id":9988,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha","state":"COMMENTED"}]\n' "$bot" "$head_time" "$bot" "$reply_time"
        ;;
      finished_note_predates_head_object)
        # #875 round 2 P1-a: CodeRabbit just posted a review object for the
        # NEW head (reply_time) while the PRIOR head's finished reply
        # (issues endpoint, stamped head_time — BEFORE this object) is
        # still inside the freshness floor. Co-present, not correlated: the
        # object must not corroborate a claim that predates it.
        printf '[{"id":9996,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha","state":"COMMENTED"}]\n' "$bot" "$reply_time"
        ;;
      probe_summary_lands_during_probe_clean|probe_summary_lands_during_probe_marker)
        # #875 round 4 TOCTOU: a head-pinned review object; the PR-level
        # summary lands BETWEEN the probe's first issue-comments snapshot
        # and its status read (the issues endpoint below serves the two
        # snapshots by fetch count).
        printf '[{"id":9998,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha","state":"COMMENTED"}]\n' "$bot" "$reply_time"
        ;;
      finished_reply_shadows_marker_summary|finished_reply_shadows_clean_summary)
        # #875 round 5: a head-pinned review object; the issues endpoint
        # carries BOTH the real summarize-marker summary and a finished
        # actions reply edited AFTER it — the newest-first shadowing shape.
        printf '[{"id":9999,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha","state":"COMMENTED"}]\n' "$bot" "$reply_time"
        ;;
      poll_finished_then_summary_clean|poll_finished_then_summary_marker)
        # #875 round 6: a head-pinned review object; the genuine summary
        # publishes only on a LATER poll iteration (issues endpoint below,
        # by fetch count).
        printf '[{"id":10001,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha","state":"COMMENTED"}]\n' "$bot" "$reply_time"
        ;;
      poll_finished_prior_head_summary)
        # #875 round 6: a head-pinned review object at reply_time; the only
        # summarize-marker comment (issues endpoint) was last refreshed
        # BEFORE it — a PRIOR head summary inside the wallclock window.
        printf '[{"id":10003,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha","state":"COMMENTED"}]\n' "$bot" "$reply_time"
        ;;
      poll_finished_nonterminal_summary|poll_finished_no_summary_status_success|probe_summary_quotes_finished_phrases)
        # #875 round 7: a head-pinned review object at reply_time for all
        # three P1 cases — the corroboration anchor each one needs.
        printf '[{"id":10005,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha","state":"COMMENTED"}]\n' "$bot" "$reply_time"
        ;;
      finished_note_reviews_lookup_fails)
        # #875 round 3 P1-ii: the reviews lookup 5xxes while a finished
        # reply is being classified. The corroboration helper must deny
        # outright — NOT treat the failure as zero objects and fall to the
        # StatusContext leg, which the test makes deliberately satisfiable.
        echo "simulated reviews API failure (corroboration lookup)" >&2
        exit 44
        ;;
      finished_note_reviews_body_blank)
        # #875 round 7: the SILENT half of the same failure class — gh
        # exits 0 but writes nothing at all. A real array endpoint always
        # writes at least `[]`, so a blank body is an unreadable payload,
        # not a confirmed-empty array; normalizing it to `[]` would turn an
        # outage into outcome (b) and hand the claim to the satisfiable
        # StatusContext leg that outcome (a) denies. No output, exit 0.
        exit 0
        ;;
      probe_reviews_api_failure)
        # #814 / Phase 4b P2 on #823: the reviews fetch fails while the probe
        # is deciding. Must surface as rc 3 (infra), never as a clean rc 7.
        echo "simulated reviews API failure" >&2
        exit 44
        ;;
      probe_finding_predates_head)
        # #814: SHA-pinned evidence that predates the head committer date —
        # the shape a future-dated or metadata-rewritten head produces, and
        # also what an unchanged head looks like once a wall-clock freshness
        # floor has advanced past it. Selection is by commit_id alone, so it
        # must still read as reported.
        printf '[{"id":9971,"user":{"login":"%s"},"submitted_at":"2026-06-03T00:00:00Z","commit_id":"head-sha"}]\n' "$bot"
        ;;
      probe_stale_anchor)
        # #814 / Codex P1 on #823: CodeRabbit reviewed the PREVIOUS head only.
        # The review object is pinned to old-sha, so no HEAD-pinned evidence
        # exists — only the summary issue comment, which carries no SHA.
        printf '[{"id":9951,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"old-sha"}]\n' "$bot" "$head_time"
        ;;
      probe_summary_lags_review)
        # #814 / Phase 4b P1 on #823: mid-publication. A HEAD-pinned review
        # object EXISTS (submitted at reply_time), but the newest summary
        # passing HEAD_ANCHOR is the PRIOR head's, posted earlier. Existence
        # alone would clear; the summary must also be at least as recent as
        # the review it is credited to.
        printf '[{"id":9961,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"}]\n' "$bot" "$reply_time"
        ;;
      intermediate_review_head_pin)
        # #535.2: a NEWER review (later submitted_at) references an
        # intermediate commit, while the HEAD review is older. The
        # HEAD-pinned selection must pick the HEAD review (9931), not the
        # newer intermediate one (9932).
        printf '[{"id":9931,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"},{"id":9932,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"intermediate-sha"}]\n' "$bot" "$head_time" "$bot" "$reply_time"
        ;;
      *)
        printf '[]\n'
        ;;
    esac
    ;;
  repos/owner/repo/pulls/999/comments)
    case "$scenario" in
      probe_finding_predates_head)
        # created_at is BEFORE head_time, i.e. before HEAD_IDENTITY_ANCHOR.
        # The anchored counter drops it; the probe must not, because commit_id
        # already pins it to this head.
        printf '[{"id":9972,"user":{"login":"%s"},"created_at":"2026-06-03T00:00:00Z","updated_at":"2026-06-03T00:00:00Z","commit_id":"head-sha","pull_request_review_id":9971,"in_reply_to_id":null,"body":"_⚠️ Potential issue_ | _🟠 Major_\\n\\nFinding created before the head committer date."}]\n' "$bot"
        ;;
      review_arrives_during_probe)
        count=0
        if [ -f "$state_dir/probe-count" ]; then
          count=$(cat "$state_dir/probe-count")
        fi
        if [ "$count" -gt 0 ] && [ "$(fake_now)" -ge 2000000006 ]; then
          printf '[{"id":9902,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","commit_id":"head-sha","pull_request_review_id":9901,"in_reply_to_id":null,"body":"_⚠️ Potential issue_ | _🟠 Major_\\n\\nReview arrived during probe wait."}]\n' "$bot" "$reply_time" "$reply_time"
        else
          printf '[]\n'
        fi
        ;;
      summary_marker_only)
        # #535.1: no inline findings at all — the marker lives only in the
        # PR-level summary body (issues endpoint below).
        printf '[]\n'
        ;;
      intermediate_review_head_pin)
        # #535.2: the ⚠️ inline finding is tied to the HEAD review (9931).
        # The newer intermediate review (9932) has no inline findings, so
        # selecting it (the pre-fix freshness-only behavior) would clear.
        printf '[{"id":9933,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","commit_id":"head-sha","pull_request_review_id":9931,"in_reply_to_id":null,"body":"_⚠️ Potential issue_ | _🟠 Major_\\n\\nFinding on the HEAD review."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      *)
        printf '[]\n'
        ;;
    esac
    ;;
  repos/owner/repo/issues/999/comments)
    case "$scenario" in
      status_reply_after_delay)
        count=0
        if [ -f "$state_dir/probe-count" ]; then
          count=$(cat "$state_dir/probe-count")
        fi
        if [ "$count" -gt 0 ] && [ "$(fake_now)" -ge 2000000006 ]; then
          printf '[{"id":8801,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- CodeRabbit review command invocation: test -->\\n`@nathanjohnpayne`: Here is a summary of where things stand.\\n\\n### Open CodeRabbit Threads\\nNone yet."}]\n' "$bot" "$reply_time" "$reply_time"
        else
          printf '[]\n'
        fi
        ;;
      existing_status_probe_reply)
        printf '[{"id":8802,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- CodeRabbit review command invocation: prior -->\\n`@nathanjohnpayne`: Here is a summary of where things stand.\\n\\n### Open CodeRabbit Threads\\nStill checking."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      rate_limit)
        printf '[{"id":7701,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"Rate limit exceeded. Please wait 10 seconds before requesting another review."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      probe_paused)
        # #814: the #485 auto-pause NOTE, pinned to the stable
        # `review paused by coderabbit.ai` marker classify_comment keys on.
        printf '[{"id":7801,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: review paused by coderabbit.ai -->\\n\\n> [!NOTE]\\n> ## Reviews paused\\n\\nUse `@coderabbitai resume` to resume."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      probe_in_progress)
        printf '[{"id":7802,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"CodeRabbit review in progress; hold tight."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      probe_narration)
        # #814: a status-probe narration reply strictly AFTER the HEAD
        # anchor, so it survives the freshness filter and actually reaches
        # classify_comment. (The existing_status_probe_reply fixture sits ON
        # the anchor and is filtered out before classification, which is why
        # it cannot exercise this arm.)
        printf '[{"id":7804,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- CodeRabbit review command invocation: probe -->\\n`@nathanjohnpayne`: Here is a summary of where things stand.\\n\\n### Open CodeRabbit Threads\\nStill checking."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_review_on_head)
        printf '[{"id":7803,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 0**\\n\\nNothing to flag."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      probe_finding_predates_head)
        # Summary landed with the review, both older than the head committer
        # date, so the case isolates "aged evidence" from "publication
        # incomplete".
        printf '[{"id":7808,"user":{"login":"%s"},"created_at":"2026-06-03T00:00:01Z","updated_at":"2026-06-03T00:00:01Z","body":"**Actionable comments posted: 0**\\n\\nAged summary."}]\n' "$bot"
        ;;
      probe_stale_anchor)
        # The PRIOR head's summary. It classifies as `review` and passes the
        # fresh_at >= HEAD_ANCHOR filter because the new head's committer date
        # is older than this comment — the author-controlled-timestamp hole.
        printf '[{"id":7805,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 0**\\n\\nReviewed the previous head."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_lags_review)
        # Prior head's summary at head_time, i.e. BEFORE the HEAD review
        # object at reply_time. Clean body, so nothing else would block a
        # clear — only the temporal correlation check does.
        printf '[{"id":7806,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 0**\\n\\nPrior head summary."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      probe_notice_after_review)
        printf '[{"id":9982,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_review_finished_limit_note)
        # #869: CodeRabbit edited its actions reply in place — the block now
        # states the full review FINISHED — and appended the fair-use limit
        # note (carrying the rate-limit marker) to the SAME comment because
        # that review consumed the last allowance unit. Pre-fix this body
        # classified rate_limit and the publication scan held not-yet on a
        # head the bot had already reviewed (live on #866).
        printf '[{"id":9989,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached\\n\\nYour included review limit is currently reached under our Fair Usage Limits. Next review available in: 45 minutes."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_limit_note_only)
        # #869 control: ONLY the fair-use limit note — no actions block, no
        # completion claim. Must keep classifying rate_limit; the #714/#489
        # rate-limit paths depend on it.
        printf '[{"id":9990,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached\\n\\nYour included review limit is currently reached under our Fair Usage Limits. Next review available in: 45 minutes."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_triggered_limit_note)
        # #869 control: the PRE-completion wording of the same actions block.
        # A triggered-but-not-finished review states no completion, so it
        # still defers to the appended notice.
        printf '[{"id":9993,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"✅ Actions performed\\n\\nFull review triggered.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      finished_note_uncorroborated)
        # #875 P1-b: the PRIOR head's finished-review reply, admitted into
        # the scan by the wallclock freshness floor after a cherry-picked /
        # old-committer-date push. NO review object is pinned to this head
        # (the reviews endpoint falls to its [] default) and the head
        # StatusContext is driven by CODERABBIT_TEST_STATUS (absent unless a
        # test sets it), so by default the completion claim has NO head
        # anchor — it must fall through to rate_limit, or a genuine current
        # limit is masked by a stale completion.
        printf '[{"id":9994,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached\\n\\nYour included review limit is currently reached under our Fair Usage Limits. Next review available in: 45 minutes."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      finished_note_predates_head_object)
        # #875 round 2 P1-a: same finished+limit body, but stamped at
        # head_time — BEFORE the new head's review object at reply_time
        # (reviews endpoint above). Its fresh_at is inside the freshness
        # floor, so the polling scan still selects it; the ordering
        # conjunct is the only thing standing between this stale claim and
        # a false terminal on a head whose own publication is pending.
        printf '[{"id":9995,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached\\n\\nYour included review limit is currently reached under our Fair Usage Limits. Next review available in: 45 minutes."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      finished_note_reviews_lookup_fails)
        # #875 round 3 P1-ii: the same finished+limit body at reply_time.
        # The reviews endpoint (above) fails, and the StatusContext is set
        # success at head_time by the test — an ordering the status leg
        # WOULD accept (comment 00:00:06 at-or-after status 00:00:00) if
        # the failed lookup were wrongly read as zero objects.
        printf '[{"id":9997,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached\\n\\nYour included review limit is currently reached under our Fair Usage Limits. Next review available in: 45 minutes."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      finished_note_reviews_body_blank)
        # #875 round 7: the same finished+limit body at reply_time, paired
        # with a reviews endpoint that exits 0 writing NOTHING. Same
        # satisfiable status leg as the 5xx twin above, so a blank body
        # read as an empty array corroborates and classifies review;
        # read as a failed lookup it denies and stalls rc 5.
        printf '[{"id":9993,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached\\n\\nYour included review limit is currently reached under our Fair Usage Limits. Next review available in: 45 minutes."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      finished_reply_shadows_marker_summary)
        # #875 round 5 (a): the REAL summarize-marker summary at 00:00:07
        # carries the SOLE blocking marker; the finished actions reply was
        # edited at 00:00:09 — newer, so the newest-first scan reaches it
        # FIRST. Pre-fix the corroborated reply became summary_body, the
        # marker check read the clean reply, and both probe and polling
        # cleared past the blocking finding. Post-fix the reply attests
        # terminality only and the verdict is decided on the summary: rc 2.
        printf '[{"id":7940,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:07Z","updated_at":"2026-06-04T00:00:07Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n**Actionable comments posted: 1**\\n\\n_⚠️ Potential issue_\\n\\nCarried only by this summary."},{"id":7941,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:05Z","updated_at":"2026-06-04T00:00:09Z","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"}]\n' "$bot" "$bot"
        ;;
      finished_reply_shadows_clean_summary)
        # #875 round 5 (b): same shape, CLEAN real summary — and the
        # finished reply carries a decoy warning glyph, so a verdict read
        # off the reply would emit findings while the real summary clears.
        # rc 0 therefore proves the SUMMARY was the inspected body.
        printf '[{"id":7942,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:07Z","updated_at":"2026-06-04T00:00:07Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n**Actionable comments posted: 0**\\n\\nNothing to flag in this summary."},{"id":7943,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:05Z","updated_at":"2026-06-04T00:00:09Z","body":"✅ Actions performed\\n\\nFull review finished. ⚠️ Usage note attached.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"}]\n' "$bot" "$bot"
        ;;
      poll_finished_then_summary_clean|poll_finished_then_summary_marker)
        # #875 round 6, served by fetch count: iteration 1 (scan + summary
        # selection, fetches 1–2) sees ONLY the finished attestation — the
        # poll must keep polling, not clear. From fetch 3 (iteration 2) the
        # genuine summarize-marker summary for this head is up at 00:00:10,
        # clean or carrying the sole blocking marker per scenario.
        count=0
        if [ -f "$state_dir/issues-fetch-count" ]; then
          count=$(cat "$state_dir/issues-fetch-count")
        fi
        count=$((count + 1))
        printf '%s\n' "$count" >"$state_dir/issues-fetch-count"
        if [ "$count" -ge 3 ]; then
          if [ "$scenario" = "poll_finished_then_summary_marker" ]; then
            printf '[{"id":8001,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"},{"id":8002,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:10Z","updated_at":"2026-06-04T00:00:10Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n**Actionable comments posted: 1**\\n\\n_⚠️ Potential issue_\\n\\nPublished after the attestation."}]\n' "$bot" "$reply_time" "$reply_time" "$bot"
          else
            printf '[{"id":8001,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"},{"id":8002,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:10Z","updated_at":"2026-06-04T00:00:10Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n**Actionable comments posted: 0**\\n\\nPublished after the attestation, nothing to flag."}]\n' "$bot" "$reply_time" "$reply_time" "$bot"
          fi
        else
          printf '[{"id":8001,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"}]\n' "$bot" "$reply_time" "$reply_time"
        fi
        ;;
      poll_finished_prior_head_summary)
        # #875 round 6: the finished attestation (edited 00:00:09) plus a
        # CLEAN prior-head summarize-marker summary last refreshed at
        # 00:00:03 — BEFORE the head review object at 00:00:06 but inside
        # the wallclock window. Pre-fix the bare-anchor re-selection picked
        # it as verdict material and cleared a head whose own summary never
        # published; post-fix nothing qualifies and the poll runs out its
        # budget (advisory rc 4).
        printf '[{"id":8003,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:05Z","updated_at":"2026-06-04T00:00:09Z","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"},{"id":8004,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:03Z","updated_at":"2026-06-04T00:00:03Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n**Actionable comments posted: 0**\\n\\nPrior head, nothing to flag."}]\n' "$bot" "$bot"
        ;;
      poll_finished_nonterminal_summary)
        # #875 round 7 (Codex P1-b): the ONLY summarize-marker comment was
        # refreshed at 00:00:07 — AFTER the head review object at reply_time,
        # so marker identity plus the ordering floor both accept it — but it
        # carries the MID-REVIEW stanza, i.e. it is the same in-place comment
        # in a state that is not a verdict. A finished attestation edited at
        # 00:00:09 is the newest bot comment and drives the polling `review`
        # arm. Pre-fix the selector returned this body, found no blocking
        # marker, and cleared rc 0 before the real summary published.
        printf '[{"id":8007,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:07Z","updated_at":"2026-06-04T00:00:07Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n<!-- This is an auto-generated comment: review in progress by coderabbit.ai -->\\n\\n**Currently reviewing this pull request.**"},{"id":8008,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:05Z","updated_at":"2026-06-04T00:00:09Z","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"}]\n' "$bot" "$bot"
        ;;
      poll_finished_no_summary_status_success)
        # #875 round 7 (Codex P1-a): a corroborated finished attestation is
        # the ONLY bot comment — no summarize-marker comment exists at all —
        # while the per-SHA StatusContext reads success and the repo trusts
        # it. Pre-fix the attestation classified `review`, so it did not
        # suppress the StatusContext fast path, and emit_status_context_
        # verdict cleared rc 0 off an inline-only scan before any summary
        # published.
        printf '[{"id":8009,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:05Z","updated_at":"2026-06-04T00:00:09Z","body":"✅ Actions performed\\n\\nFull review finished.\\n\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"}]\n' "$bot"
        ;;
      probe_summary_quotes_finished_phrases)
        # #875 round 7 (Codex P1-c): a GENUINE summarize-marker summary that
        # happens to discuss the finished-attestation mechanism — a fenced
        # quote of the matcher plus prose naming both phrases, which is
        # exactly what CodeRabbit writes when it walks a diff that touches
        # this code. Pre-fix the two body-wide greps labelled it an
        # attestation, the probe skipped it at the exclusion branch, and the
        # blocking marker it carries alone (#535) was never inspected.
        printf '[{"id":8011,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:07Z","updated_at":"2026-06-04T00:00:07Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n**Actionable comments posted: 1**\\n\\n_⚠️ Potential issue_\\n\\nThe helper decides whether the actions-performed block states the review finished:\\n\\n```bash\\ngrep -qiE actions performed\\ngrep -qiE review finished\\n```\\n\\nCarried only by this summary."}]\n' "$bot"
        ;;
      probe_summary_lands_during_probe_clean|probe_summary_lands_during_probe_marker)
        # #875 round 4 TOCTOU, served by fetch count: the FIRST snapshot
        # predates the summary (only the prior-head summary from before the
        # review object exists), the SECOND — the post-success re-fetch —
        # carries the just-published summary for this head at 00:00:08,
        # after the review object at reply_time. The marker variant's
        # summary carries the #535 summary-only blocking marker; pre-fix
        # both variants emitted the rc-7 success payload off the stale
        # first snapshot and the barrier opened past the unscanned summary.
        count=0
        if [ -f "$state_dir/issues-fetch-count" ]; then
          count=$(cat "$state_dir/issues-fetch-count")
        fi
        count=$((count + 1))
        printf '%s\n' "$count" >"$state_dir/issues-fetch-count"
        if [ "$count" -ge 2 ]; then
          if [ "$scenario" = "probe_summary_lands_during_probe_marker" ]; then
            printf '[{"id":7931,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:08Z","updated_at":"2026-06-04T00:00:08Z","body":"**Actionable comments posted: 1**\\n\\n_⚠️ Potential issue_\\n\\nCarried only by this just-landed summary."}]\n' "$bot"
          else
            printf '[{"id":7930,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:08Z","updated_at":"2026-06-04T00:00:08Z","body":"**Actionable comments posted: 0**\\n\\nJust-landed summary for this head."}]\n' "$bot"
          fi
        else
          printf '[{"id":7929,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 0**\\n\\nPrior head summary."}]\n' "$bot" "$head_time" "$head_time"
        fi
        ;;
      probe_narration_after_review)
        # #833: the ONLY bot comment after the HEAD review object is a
        # status-probe narration reply. Pre-fix, the publication scan latched
        # classify_comment's status_probe class straight into probe.observed —
        # a value the documented enum deliberately excludes (seen live on
        # #852 while the summary publication lagged the review object).
        printf '[{"id":9984,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- CodeRabbit review command invocation: status -->\\n`@nathanjohnpayne`: Here is a summary of where things stand.\\n\\n### Open CodeRabbit Threads\\nStill checking."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_narration_over_notice)
        # #833 skip-not-blank: narration is the NEWEST row and a rate-limit
        # notice sits beneath it, both after the review object. The narration
        # skip must fall through to the notice, not blank the whole latch.
        printf '[{"id":9985,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n\\n> [!WARNING]\\n> ## Review limit reached"},{"id":9986,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:08Z","updated_at":"2026-06-04T00:00:08Z","body":"<!-- CodeRabbit review command invocation: status -->\\n`@nathanjohnpayne`: Here is a summary of where things stand.\\n\\n### Open CodeRabbit Threads\\nStill checking."}]\n' "$bot" "$reply_time" "$reply_time" "$bot"
        ;;
      probe_reviews_api_failure)
        # A classifiable summary, so the probe reaches the reviews fetch that
        # then fails.
        printf '[{"id":7807,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 0**\\n\\nSummary."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      review_arrives_during_probe)
        count=0
        if [ -f "$state_dir/probe-count" ]; then
          count=$(cat "$state_dir/probe-count")
        fi
        if [ "$count" -gt 0 ] && [ "$(fake_now)" -ge 2000000006 ]; then
          printf '[{"id":8803,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"CodeRabbit review completed. See inline findings."}]\n' "$bot" "$reply_time" "$reply_time"
        else
          printf '[]\n'
        fi
        ;;
      summary_marker_only)
        # #535.1: latest PR-level summary classifies as a review (not a
        # rate-limit/paused/in-progress/status-probe narration) and carries a
        # Potential issue marker in its body. The inline count is 0, so the
        # gate must rely on this summary-body marker to emit findings.
        printf '[{"id":8821,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 1**\\n\\n<details>\\n<summary>foo.sh (1)</summary>\\n\\n_⚠️ Potential issue_\\n\\nThis only appears in the summary body."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      intermediate_review_head_pin)
        # #535.2: a plain review-completed summary with NO Potential issue
        # marker, so clearance is decided purely by the HEAD-pinned inline
        # count (which finds the finding on the HEAD review).
        printf '[{"id":8831,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 1**\\n\\nSee inline findings on the latest HEAD review."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      probe_clean_incremental)
        # #851 fixtures: no review object (reviews endpoint falls to its []
        # default); the summarize comment is the only head evidence. Prior-head
        # tokens are `base-sha`, never `old-head-sha` — `-` is not hex, so the
        # boundary regex would accept `head-sha` inside `old-head-sha`, a
        # property real 40-hex SHAs do not have.
        printf '[{"id":7901,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\nNo actionable comments were generated in the recent review.\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha.\\n\\n<!-- This is an auto-generated comment: release notes by coderabbit.ai -->\\n## Summary by CodeRabbit\\n- Fixes\\n<!-- end of auto-generated comment: release notes by coderabbit.ai -->"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_clean_prior_head)
        # Range names ONLY prior heads: the SHA conjunct is the sole tie.
        printf '[{"id":7911,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\nNo actionable comments were generated in the recent review.\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and prior-sha.\\n\\n<!-- This is an auto-generated comment: release notes by coderabbit.ai -->\\n## Summary by CodeRabbit\\n- Fixes\\n<!-- end of auto-generated comment: release notes by coderabbit.ai -->"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_review_failed)
        # The live #790 shape: a failure stanza naming the CURRENT head.
        printf '[{"id":7912,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n<!-- This is an auto-generated comment: failure by coderabbit.ai -->\\n> [!CAUTION]\\n> Review failed. Between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha.\\n<!-- end of auto-generated comment: failure by coderabbit.ai -->"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_skip_review)
        # The live #797 shape: an explicit skip naming the head.
        printf '[{"id":7913,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n<!-- This is an auto-generated comment: skip review by coderabbit.ai -->\\n> Review skipped between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha.\\n<!-- end of auto-generated comment: skip review by coderabbit.ai -->"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_unknown_stanza)
        # A stanza KIND CodeRabbit has not shipped yet (anti-#593 posture).
        printf '[{"id":7914,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n<!-- This is an auto-generated comment: quota exhausted by coderabbit.ai -->\\n> Something new. Between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha.\\n<!-- end of auto-generated comment: quota exhausted by coderabbit.ai -->"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_legacy_ratelimit_prose)
        # Markerless legacy rate-limit prose in an AGED summary the anchored
        # triage never sees: the class conjunct is the sole rejection.
        printf '[{"id":7915,"user":{"login":"%s"},"created_at":"2026-06-03T00:00:00Z","updated_at":"2026-06-03T00:00:00Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\nRate limit exceeded. Please wait 10 minutes.\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha."}]\n' "$bot"
        ;;
      probe_summary_midreview)
        # The recovered #849 mid-review state: already names the new head.
        printf '[{"id":7916,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n<!-- This is an auto-generated comment: review in progress by coderabbit.ai -->\\n> Currently processing new changes in this PR. This may take a few minutes, please wait...\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha.\\n<!-- end of auto-generated comment: review in progress by coderabbit.ai -->"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_plus_chat_reply)
        # The live #794 shape: a NEWER chat reply embeds the head SHA. Marker
        # selection must credit 7917, never the newest candidate 7918.
        printf '[{"id":7917,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\nNo actionable comments were generated in the recent review.\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha."},{"id":7918,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:08Z","updated_at":"2026-06-04T00:00:08Z","body":"🧩 Analysis chain\\n\\n626:<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n\\nbetween aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha per gh pr view --json headRefOid.\\n\\nDone."}]\n' "$bot" "$reply_time" "$reply_time" "$bot"
        ;;
      probe_summary_chat_reply_only)
        # Same reply, prior-head summary: the reply alone is never evidence.
        printf '[{"id":7919,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\nNo actionable comments were generated in the recent review.\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and prior-sha."},{"id":7920,"user":{"login":"%s"},"created_at":"2026-06-04T00:00:08Z","updated_at":"2026-06-04T00:00:08Z","body":"🧩 Analysis chain\\n\\n626:<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n\\nbetween aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha per gh pr view --json headRefOid.\\n\\nDone."}]\n' "$bot" "$reply_time" "$reply_time" "$bot"
        ;;
      probe_summary_premerge_warning)
        # The only ⚠️ is a pre-merge hygiene row (3 of 5 live summaries).
        printf '[{"id":7921,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\nNo actionable comments were generated in the recent review.\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha.\\n\\n<!-- pre_merge_checks_walkthrough_start -->\\n| Docstring Coverage | ⚠️ Warning | 38.89%% |\\n<!-- pre_merge_checks_walkthrough_end -->"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_marker_outside_premerge)
        # A real blocking marker OUTSIDE the block; the strip must keep it.
        printf '[{"id":7922,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n_⚠️ Potential issue_ carried only by this summary.\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha.\\n\\n<!-- pre_merge_checks_walkthrough_start -->\\n| Docstring Coverage | ⚠️ Warning | 38.89%% |\\n<!-- pre_merge_checks_walkthrough_end -->"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_premerge_truncated)
        # Start delimiter without end: nothing stripped, fails toward rc 2.
        printf '[{"id":7923,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha.\\n\\n<!-- pre_merge_checks_walkthrough_start -->\\n_⚠️ Potential issue_ after a truncated block."}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      probe_summary_aged_clean)
        # Clean head-pinned summary predating the anchor (liveness case).
        printf '[{"id":7924,"user":{"login":"%s"},"created_at":"2026-06-03T00:00:00Z","updated_at":"2026-06-03T00:00:00Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\nNo actionable comments were generated in the recent review.\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha."}]\n' "$bot"
        ;;
      probe_summary_paused_aged)
        # Paused stanza in an AGED summary only the anchor-free selection
        # sees: the class conjunct alone must reject it (#593 precedent).
        printf '[{"id":7925,"user":{"login":"%s"},"created_at":"2026-06-03T00:00:00Z","updated_at":"2026-06-03T00:00:00Z","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n<!-- This is an auto-generated comment: review paused by coderabbit.ai -->\\n> [!NOTE]\\n> ## Reviews paused\\n<!-- end of auto-generated comment: review paused by coderabbit.ai -->\\n\\nReviewing files that changed from the base of the PR and between aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and head-sha."}]\n' "$bot"
        ;;
      probe_review_object_premerge_warning)
        # Review object ON head; the published summary's only ⚠️ is a
        # pre-merge hygiene row. The review-object rc-2 site must strip it
        # too (one helper, both sites) and emit reported, not findings.
        printf '[{"id":7926,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\nNo actionable comments were generated in the recent review.\\n\\n<!-- pre_merge_checks_walkthrough_start -->\\n| Docstring Coverage | ⚠️ Warning | 40 |\\n<!-- pre_merge_checks_walkthrough_end -->"}]\n' "$bot" "$reply_time" "$reply_time"
        ;;
      reply_poll_failure)
        count=0
        if [ -f "$state_dir/probe-count" ]; then
          count=$(cat "$state_dir/probe-count")
        fi
        if [ "$count" -gt 0 ]; then
          echo "simulated status-probe reply poll failure" >&2
          exit 43
        fi
        printf '[]\n'
        ;;
      *)
        printf '[]\n'
        ;;
    esac
    ;;
  *)
    echo "unexpected gh api endpoint: $endpoint" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  # #814: the #489 Codex failover is the one forbidden write probe_count
  # cannot see — it runs codex-review-request.sh as a SEPARATE PROCESS, not
  # through gh, so no gh-POST counter can observe it, and it posts under the
  # AUTHOR identity rather than the reviewer's. Record every invocation so
  # "a probe posts nothing" is actually asserted rather than assumed. Same
  # stub shape as tests/test_coderabbit_wait_codex_failover.sh.
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

# Count Codex-failover invocations. Any value above 0 in probe mode means the
# probe reached the failover and posted an author-attributed `@codex review`.
codex_invocations() {
  local dir=$1 count=0
  # `grep -c .` prints 0 AND exits 1 on an empty file, so a bare `|| printf 0`
  # emits a second zero and the caller compares against "0\n0". Capture, then
  # print one normalized value.
  if [ -f "$dir/state/codex-stub.log" ]; then
    count=$(grep -c . "$dir/state/codex-stub.log" 2>/dev/null || true)
  fi
  printf '%s\n' "${count:-0}"
}

run_case() {
  local dir=$1
  local scenario=$2
  local rc=0

  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_SCENARIO="$scenario" \
      ./scripts/coderabbit-wait.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?

  printf '%s\n' "$rc"
}

probe_count() {
  local dir=$1
  if [ -f "$dir/state/probe-count" ]; then
    cat "$dir/state/probe-count"
  else
    printf '0\n'
  fi
}

test_timeout_probe_posts_once_and_surfaces_reply() {
  local dir rc count posted reply_present waited status review body
  dir=$(make_case "timeout-probe-reply" 1 true 6 2)
  rc=$(run_case "$dir" status_reply_after_delay)
  count=$(probe_count "$dir")
  status=$(jq -r '.status' "$dir/out.json")
  posted=$(jq -r '.status_probe.posted' "$dir/out.json")
  reply_present=$(jq -r '.status_probe.reply_present' "$dir/out.json")
  waited=$(jq -r '.status_probe.waited_seconds' "$dir/out.json")
  review=$(jq -r '.review // "null"' "$dir/out.json")
  body=$(cat "$dir/state/probe-bodies")

  if [ "$rc" != "4" ]; then
    fail "timeout probe reply: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$status" != "timeout" ]; then
    fail "timeout probe reply: status=$status, expected timeout"
  elif [ "$count" != "1" ]; then
    fail "timeout probe reply: probe count $count, expected 1"
  elif [ "$body" != "@coderabbitai, how is the review going?" ]; then
    fail "timeout probe reply: unexpected probe body: $body"
  elif [ "$posted" != "true" ] || [ "$reply_present" != "true" ]; then
    fail "timeout probe reply: posted=$posted reply_present=$reply_present"
  elif [ "$waited" != "5" ]; then
    fail "timeout probe reply: status_probe.waited_seconds=$waited, expected 5"
  elif [ "$review" != "null" ]; then
    fail "timeout probe reply: status probe was treated as review: $review"
  elif ! jq -e '.status_probe.reply.body_excerpt | test("summary of where things stand")' "$dir/out.json" >/dev/null; then
    fail "timeout probe reply: reply excerpt missing status text; json=$(cat "$dir/out.json")"
  else
    pass "timeout path posts one status probe and surfaces reply without clearance"
  fi
}

test_existing_status_probe_reply_never_clears() {
  local dir rc count status posted review
  dir=$(make_case "existing-status-reply" 1 false 0 2)
  rc=$(run_case "$dir" existing_status_probe_reply)
  count=$(probe_count "$dir")
  status=$(jq -r '.status' "$dir/out.json")
  posted=$(jq -r '.status_probe.posted' "$dir/out.json")
  review=$(jq -r '.review // "null"' "$dir/out.json")

  if [ "$rc" != "4" ]; then
    fail "existing status reply: exit $rc, expected timeout 4; stderr=$(cat "$dir/err.log")"
  elif [ "$status" != "timeout" ]; then
    fail "existing status reply: status=$status, expected timeout"
  elif [ "$count" != "0" ] || [ "$posted" != "false" ]; then
    fail "existing status reply: probe count=$count posted=$posted, expected no new probe"
  elif [ "$review" != "null" ]; then
    fail "existing status reply: status reply was treated as review: $review"
  else
    pass "existing CodeRabbit status reply never clears the wait"
  fi
}

test_rate_limit_stalled_does_not_probe() {
  local dir rc count status posted review_id
  dir=$(make_case "rate-limit-no-probe" 30 true 6 0)
  rc=$(run_case "$dir" rate_limit)
  count=$(probe_count "$dir")
  status=$(jq -r '.status' "$dir/out.json")
  posted=$(jq -r '.status_probe.posted' "$dir/out.json")
  review_id=$(jq -r '.review.id' "$dir/out.json")

  if [ "$rc" != "5" ]; then
    fail "rate-limit no probe: exit $rc, expected 5; stderr=$(cat "$dir/err.log")"
  elif [ "$status" != "rate_limit_stalled" ]; then
    fail "rate-limit no probe: status=$status, expected rate_limit_stalled"
  elif [ "$count" != "0" ] || [ "$posted" != "false" ]; then
    fail "rate-limit no probe: probe count=$count posted=$posted, expected no probe"
  elif [ "$review_id" != "7701" ]; then
    fail "rate-limit no probe: review.id=$review_id, expected 7701"
  else
    pass "rate-limit stalled path does not fire status probe"
  fi
}

test_probe_post_failure_stays_timeout_advisory() {
  local dir rc count status posted reply_present review
  dir=$(make_case "probe-post-failure" 1 true 6 2)
  rc=$(run_case "$dir" probe_post_failure)
  count=$(probe_count "$dir")
  if [ "$rc" != "4" ]; then
    fail "probe post failure: exit $rc, expected advisory timeout 4; stderr=$(cat "$dir/err.log")"
    return
  elif [ ! -s "$dir/out.json" ]; then
    fail "probe post failure: missing timeout JSON output; stderr=$(cat "$dir/err.log")"
    return
  fi
  status=$(jq -r '.status' "$dir/out.json")
  posted=$(jq -r '.status_probe.posted' "$dir/out.json")
  reply_present=$(jq -r '.status_probe.reply_present' "$dir/out.json")
  review=$(jq -r '.review // "null"' "$dir/out.json")

  if [ "$status" != "timeout" ]; then
    fail "probe post failure: status=$status, expected timeout"
  elif [ "$count" != "0" ] || [ "$posted" != "false" ]; then
    fail "probe post failure: probe count=$count posted=$posted, expected no successful probe"
  elif [ "$reply_present" != "false" ]; then
    fail "probe post failure: reply_present=$reply_present, expected false"
  elif [ "$review" != "null" ]; then
    fail "probe post failure: probe failure was treated as review: $review"
  else
    pass "status probe post failure remains advisory timeout"
  fi
}

test_probe_reply_poll_failure_stays_timeout_advisory() {
  local dir rc count status posted reply_present review
  dir=$(make_case "probe-reply-poll-failure" 1 true 6 2)
  rc=$(run_case "$dir" reply_poll_failure)
  count=$(probe_count "$dir")
  if [ "$rc" != "4" ]; then
    fail "probe reply poll failure: exit $rc, expected advisory timeout 4; stderr=$(cat "$dir/err.log")"
    return
  elif [ ! -s "$dir/out.json" ]; then
    fail "probe reply poll failure: missing timeout JSON output; stderr=$(cat "$dir/err.log")"
    return
  fi
  status=$(jq -r '.status' "$dir/out.json")
  posted=$(jq -r '.status_probe.posted' "$dir/out.json")
  reply_present=$(jq -r '.status_probe.reply_present' "$dir/out.json")
  review=$(jq -r '.review // "null"' "$dir/out.json")

  if [ "$status" != "timeout" ]; then
    fail "probe reply poll failure: status=$status, expected timeout"
  elif [ "$count" != "1" ] || [ "$posted" != "true" ]; then
    fail "probe reply poll failure: probe count=$count posted=$posted, expected one successful probe"
  elif [ "$reply_present" != "false" ]; then
    fail "probe reply poll failure: reply_present=$reply_present, expected false"
  elif [ "$review" != "null" ]; then
    fail "probe reply poll failure: probe failure was treated as review: $review"
  else
    pass "status probe reply poll failure remains advisory timeout"
  fi
}

test_review_during_probe_wait_emits_findings() {
  local dir rc count status posted potential review_endpoint
  dir=$(make_case "review-during-probe-wait" 1 true 6 2)
  rc=$(run_case "$dir" review_arrives_during_probe)
  count=$(probe_count "$dir")
  if [ "$rc" != "2" ]; then
    fail "review during probe wait: exit $rc, expected findings 2; stderr=$(cat "$dir/err.log")"
    return
  elif [ ! -s "$dir/out.json" ]; then
    fail "review during probe wait: missing findings JSON output; stderr=$(cat "$dir/err.log")"
    return
  fi
  status=$(jq -r '.status' "$dir/out.json")
  posted=$(jq -r '.status_probe.posted' "$dir/out.json")
  potential=$(jq -r '.potential_issue_count' "$dir/out.json")
  review_endpoint=$(jq -r '.review.endpoint' "$dir/out.json")

  if [ "$status" != "findings" ]; then
    fail "review during probe wait: status=$status, expected findings"
  elif [ "$count" != "1" ] || [ "$posted" != "true" ]; then
    fail "review during probe wait: probe count=$count posted=$posted, expected one probe"
  elif [ "$potential" != "1" ]; then
    fail "review during probe wait: potential_issue_count=$potential, expected 1"
  elif [ "$review_endpoint" != "issues" ]; then
    fail "review during probe wait: review.endpoint=$review_endpoint, expected issues"
  else
    pass "real review during status-probe wait emits findings instead of timeout"
  fi
}

# #535.1: the findings gate must also honor a PR-level summary-body marker.
# A CodeRabbit review on HEAD with ZERO inline findings but a "Potential
# issue"/⚠️ marker in its PR-level summary body must emit findings (exit 2),
# not false-clear. Pre-fix this cleared (exit 0) because count_potential_
# issues scans only the inline pulls/{pr}/comments list. max_wait is large
# so the first poll reaches the in-loop `review)` arm before any timeout.
test_535_1_summary_body_marker_emits_findings() {
  local dir rc status potential review_endpoint
  dir=$(make_case "summary-marker-only" 600 false 0 2)
  rc=$(run_case "$dir" summary_marker_only)
  if [ "$rc" != "2" ]; then
    fail "#535.1 summary-body marker: exit $rc, expected findings 2; stderr=$(cat "$dir/err.log")"
    return
  elif [ ! -s "$dir/out.json" ]; then
    fail "#535.1 summary-body marker: missing findings JSON output; stderr=$(cat "$dir/err.log")"
    return
  fi
  status=$(jq -r '.status' "$dir/out.json")
  potential=$(jq -r '.potential_issue_count' "$dir/out.json")
  review_endpoint=$(jq -r '.review.endpoint' "$dir/out.json")
  if [ "$status" != "findings" ]; then
    fail "#535.1 summary-body marker: status=$status, expected findings"
  elif [ "$potential" != "0" ]; then
    fail "#535.1 summary-body marker: potential_issue_count=$potential, expected 0 (marker is summary-only, inline count is 0)"
  elif [ "$review_endpoint" != "issues" ]; then
    fail "#535.1 summary-body marker: review.endpoint=$review_endpoint, expected issues"
  else
    pass "#535.1: PR-level summary-body Potential issue/⚠️ marker yields findings even with 0 inline findings"
  fi
}

# #535.2: latest-review selection must be pinned to the HEAD commit, not just
# freshness. A NEWER review (later submitted_at) that references an
# intermediate commit must not be chosen over the HEAD review. Here the HEAD
# review carries the only ⚠️ inline finding; the newer intermediate review
# has none. Pre-fix (freshness-only `submitted_at >= anchor`) selected the
# intermediate review and cleared (exit 0); with the commit_id == HEAD_SHA
# pin the HEAD review is selected and the finding is counted (exit 2).
test_535_2_head_pinned_review_selection_emits_findings() {
  local dir rc status potential
  dir=$(make_case "intermediate-review-head-pin" 600 false 0 2)
  rc=$(run_case "$dir" intermediate_review_head_pin)
  if [ "$rc" != "2" ]; then
    fail "#535.2 head-pinned review: exit $rc, expected findings 2; stderr=$(cat "$dir/err.log")"
    return
  elif [ ! -s "$dir/out.json" ]; then
    fail "#535.2 head-pinned review: missing findings JSON output; stderr=$(cat "$dir/err.log")"
    return
  fi
  status=$(jq -r '.status' "$dir/out.json")
  potential=$(jq -r '.potential_issue_count' "$dir/out.json")
  if [ "$status" != "findings" ]; then
    fail "#535.2 head-pinned review: status=$status, expected findings (HEAD review's inline finding must count)"
  elif [ "$potential" != "1" ]; then
    fail "#535.2 head-pinned review: potential_issue_count=$potential, expected 1"
  else
    pass "#535.2: latest-review selection pins to HEAD commit; a newer intermediate-commit review does not shadow the HEAD finding"
  fi
}

# #446: fast-path StatusContext clearance race. A NEWER rate-limit/
# in-progress comment than the StatusContext success must suppress the
# fast-path EVEN WHEN it does not reference the current HEAD — otherwise the
# wait can declare clearance while CodeRabbit has just announced it is
# rate-limited / re-reviewing. The full fast-path is gated on
# trust_status_context_for_clearance: true, which the scenario harness above
# disables, so this regression pairs a STRUCTURAL assertion on the real
# arbitration with an inline ordering-decision check (the inline-literal
# pattern used by scripts/ci/check_pr_audit_codex_clearance). The REAL
# runtime fast-path (trust enabled + StatusContext stub) — including the
# created-after-suppress and created-before-clear directions — is exercised
# end-to-end in scripts/ci/check_canonical_bugs_263caf3 "Bug 6".
test_446_newer_comment_suppresses_stale_status() {
  local script="$ROOT/scripts/coderabbit-wait.sh"

  # Structural: the no-HEAD-reference branch must consult comment freshness
  # (the #446 guard) rather than unconditionally return authoritative.
  if grep -q "#446" "$script" \
     && grep -q "StatusContext success suppressed because latest CodeRabbit comment" "$script"; then
    pass "#446: coderabbit-wait.sh carries the newer-comment freshness guard in the no-HEAD fast-path branch"
  else
    fail "#446: coderabbit-wait.sh is missing the newer-comment freshness guard (#446 marker / suppressed-log)"
  fi

  # Inline ordering decision mirroring the NO-HEAD-reference branch of
  # status_context_fast_path_blocked_by_comment: "block" (suppress the
  # fast-path) iff the comment is rate_limit/in_progress AND not older than the
  # StatusContext success (newer-or-equal). NB: since #596 the HEAD-referencing
  # branch instead uses a grace window (a success within
  # STATUS_SUCCESS_GRACE_SECONDS of a HEAD-referencing notice is suppressed;
  # a later one stays authoritative) — this model covers only the no-HEAD path
  # it asserts below. KEEP IN SYNC with the function.
  decide() {  # <class> <comment_fresh_at> <status_created_at> → block|authoritative
    case "$1" in
      rate_limit|in_progress)
        if [[ "$2" < "$3" ]]; then echo authoritative; else echo block; fi ;;
      *) echo authoritative ;;
    esac
  }
  local ok=1
  [[ "$(decide rate_limit  2026-06-04T00:10:00Z 2026-06-04T00:00:00Z)" == block ]]         || ok=0  # no-HEAD newer → block (#446)
  [[ "$(decide rate_limit  2026-06-03T23:50:00Z 2026-06-04T00:00:00Z)" == authoritative ]] || ok=0  # older → authoritative
  [[ "$(decide in_progress 2026-06-04T00:10:00Z 2026-06-04T00:00:00Z)" == block ]]         || ok=0  # in_progress newer → block
  [[ "$(decide normal      2026-06-04T00:10:00Z 2026-06-04T00:00:00Z)" == authoritative ]] || ok=0  # non-rate-limit → authoritative
  if [ "$ok" = 1 ]; then
    pass "#446: newer rate-limit/in-progress comment suppresses the fast-path; older or non-rate-limit does not"
  else
    fail "#446: fast-path newer-comment-vs-status ordering regressed"
  fi
}

# ---------------------------------------------------------------------------
# #814 — `--probe` read-only single-scan mode.
#
# These live in this file because the property they guard is this file's
# subject: --probe must never reach the status-probe POST emit_timeout
# performs. Every case asserts probe_count 0 — the same counter the timeout
# tests above assert is 1.
#
# The two dangerous inversions are the rate-limit and paused cases; both
# fixtures pin the matching retry budget to 0, so a probe falling through to
# the budget checks would exit 5 or 6. Exit 6 with skip_reason=paused is the
# worse of the two: the barrier reads it as WILL-NOT-REPORT and would let a
# Phase 4b review past a PR CodeRabbit has not reviewed.
# ---------------------------------------------------------------------------

# Same as run_case, but in --probe mode. `mode` selects how probe mode is
# requested so both documented entry points are covered.
run_probe_case() {  # <dir> <scenario> [flag|env]
  local dir=$1 scenario=$2 mode=${3:-flag} rc=0

  (
    cd "$dir"
    if [ "$mode" = "env" ]; then
      PATH="$dir/bin:$PATH" \
        GH_TOKEN=test-token \
        CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
        CODERABBIT_TEST_STATE_DIR="$dir/state" \
        CODERABBIT_TEST_SCENARIO="$scenario" \
        CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
        CODEX_STUB_LOG="$dir/state/codex-stub.log" \
        CODERABBIT_WAIT_PROBE=1 \
        ./scripts/coderabbit-wait.sh 999 owner/repo \
        >"$dir/out.json" 2>"$dir/err.log"
    else
      PATH="$dir/bin:$PATH" \
        GH_TOKEN=test-token \
        CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
        CODERABBIT_TEST_STATE_DIR="$dir/state" \
        CODERABBIT_TEST_SCENARIO="$scenario" \
        CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
        CODEX_STUB_LOG="$dir/state/codex-stub.log" \
        ./scripts/coderabbit-wait.sh --probe 999 owner/repo \
        >"$dir/out.json" 2>"$dir/err.log"
    fi
  ) || rc=$?

  printf '%s\n' "$rc"
}

# <dir> <expected_rc> <expected_observed> <label> — the shared assertion:
# right rc, right observed surface, status=no_review_yet, skip_reason null,
# and ZERO posts.
assert_probe_not_yet() {
  local dir=$1 rc=$2 observed=$3 label=$4
  local got_status got_observed got_skip got_posts got_codex
  got_status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  got_observed=$(jq -r '.probe.observed // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  got_skip=$(jq -r '.skip_reason | tostring' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  got_posts=$(probe_count "$dir")
  got_codex=$(codex_invocations "$dir")
  if [ "$rc" = "7" ] && [ "$got_status" = "no_review_yet" ] \
     && [ "$got_observed" = "$observed" ] && [ "$got_skip" = "null" ] \
     && [ "$got_posts" = "0" ] && [ "$got_codex" = "0" ]; then
    pass "#814 probe: $label → rc 7, observed=$observed, skip_reason null, 0 gh posts, 0 codex triggers"
  else
    fail "#814 probe: $label → rc=$rc status=$got_status observed=$got_observed skip_reason=$got_skip posts=$got_posts codex=$got_codex"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_probe_no_comment_is_not_yet() {
  local dir rc
  dir=$(make_case probe-none 600 true 30 3 2)
  rc=$(run_probe_case "$dir" none)
  assert_probe_not_yet "$dir" "$rc" none "no CodeRabbit comment at all"
}

test_probe_rate_limit_is_not_yet_never_stalled() {
  local dir rc
  # max_rate_limit_retries: 0 — the polling mode exits 5 on the FIRST
  # sighting with this budget. A probe posts no retry, so it cannot have
  # exhausted the budget and must not escalate a human.
  dir=$(make_case probe-ratelimit 600 true 30 0 2)
  rc=$(run_probe_case "$dir" rate_limit)
  assert_probe_not_yet "$dir" "$rc" rate_limit "rate-limit notice with a 0 retry budget (must be 7, never 5)"
}

test_probe_paused_is_not_yet_never_skipped() {
  local dir rc
  # max_resume_retries: 0 — the polling mode exits 6 with
  # skip_reason=paused on the FIRST sighting. The barrier reads rc 6 +
  # skip_reason as WILL-NOT-REPORT, so returning it here would clear the
  # barrier for a PR CodeRabbit has not reviewed. This is the single most
  # dangerous mis-implementation of --probe.
  dir=$(make_case probe-paused 600 true 30 3 0)
  rc=$(run_probe_case "$dir" probe_paused)
  assert_probe_not_yet "$dir" "$rc" paused "auto-pause NOTE with a 0 resume budget (must be 7, never 6)"
}

# Sweep the state space CodeRabbit can actually present, rather than the
# arms this change happens to guard. The dimensions come from the script's
# own documented surfaces — the StatusContext state, whether the policy
# trusts it, and every class classify_comment can return — so a probe arm
# that was never written is a FAILURE here, not a silent gap. The
# hand-written cases above pin trust_status_context_for_clearance to false
# throughout and so never touch the StatusContext path at all.
#
# The asserted property is the barrier's contract, not this file's:
#   * a probe posts nothing, in every state — counted on BOTH surfaces: gh
#     POSTs, and invocations of codex-review-request.sh, which the #489
#     failover runs as a separate process under the AUTHOR identity and no
#     gh-POST counter can see;
#   * rc is one of 0 / 2 / 6 / 7 — never 4 (a probe waits out no budget)
#     and never 5 (a probe escalates no human);
#   * rc 6 carries skip_reason non-base-branch or draft, NEVER paused,
#     because the barrier reads rc 6 + skip_reason as WILL-NOT-REPORT and
#     would clear for a PR CodeRabbit has not reviewed;
#   * the emitted head_sha is the head the scan actually classified;
#   * `probe.observed` is the value the contract advertises for that state,
#     not merely SOME allowed value. The first version of this sweep asserted
#     only the exit-code set, which is too weak to notice an `observed` the
#     documented enum lists but no input can produce — a reviewer caught that
#     on #823 and the enum entry was wrong, not the code.
#
# expected_observed <trust> <status> <scenario> — the contract, stated
# independently of the implementation so a drift in either shows up as a
# mismatch.
expected_observed() {
  local trust=$1 status=$2 scenario=$3
  # The StatusContext is deliberately not consulted as EXISTENCE evidence,
  # at either trust setting: CodeRabbit emits a spurious success shortly
  # after a rate-limit notice, so it is not sound on its own. Its only
  # probe-mode roles are CONJUNCTIVE (#869 / P1 on #875): corroborating an
  # explicit finished-review claim in a comment body, and riding the rc-7
  # review-object JSON as probe.context_state — and no swept scenario
  # carries a finished claim or a head-pinned review object, so `observed`
  # stays status-independent here. Both dimensions are swept anyway, so a
  # future change that starts reading it elsewhere shows up as a mismatch;
  # the conjunctive paths are pinned by the dedicated #869/#875 cases below.
  : "$trust" "$status"
  case "$scenario" in
    none)                  printf 'none\n' ;;
    rate_limit)            printf 'rate_limit\n' ;;
    probe_paused)          printf 'paused\n' ;;
    probe_in_progress)     printf 'in_progress\n' ;;
    # Narration is filtered before classification, so it reads as nothing.
    probe_narration)       printf 'none\n' ;;
    probe_review_on_head)  printf 'terminal\n' ;;
    # #851: the head-pinned completed summary is terminal evidence; the
    # mid-review summary already naming the head is in_progress. Both at every
    # trust × StatusContext combination — the probe never consults the
    # StatusContext for either.
    probe_clean_incremental) printf 'terminal\n' ;;
    probe_summary_midreview) printf 'in_progress\n' ;;
    *)                     printf 'UNMAPPED\n' ;;
  esac
}

test_probe_state_space_sweep() {
  local trust status scenario dir rc n=0 bad=0
  for trust in false true; do
    for status in absent success failure; do
      for scenario in none rate_limit probe_paused probe_in_progress probe_narration probe_review_on_head probe_clean_incremental probe_summary_midreview; do
        n=$((n + 1))
        dir=$(make_case "sweep-$trust-$status-$scenario" 600 true 30 0 0)
        # The sweep drives trust via the policy file the fixture writes.
        if [ "$trust" = "true" ]; then
          sed -i.bak 's/^  trust_status_context_for_clearance: false$/  trust_status_context_for_clearance: true/' \
            "$dir/.github/review-policy.yml" && rm -f "$dir/.github/review-policy.yml.bak"
        fi
        rc=0
        ( cd "$dir" && PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
            CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
            CODERABBIT_TEST_STATE_DIR="$dir/state" \
            CODERABBIT_TEST_SCENARIO="$scenario" \
            CODERABBIT_TEST_STATUS="$status" \
            CODERABBIT_WAIT_CODEX_REQUEST_CMD="$dir/bin/codex-request-stub.sh" \
            CODEX_STUB_LOG="$dir/state/codex-stub.log" \
            ./scripts/coderabbit-wait.sh --probe 999 owner/repo \
            >"$dir/out.json" 2>"$dir/err.log" ) || rc=$?
        local posts codex skip head obs want
        posts=$(probe_count "$dir")
        codex=$(codex_invocations "$dir")
        skip=$(jq -r '.skip_reason | tostring' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
        head=$(jq -r '.head_sha' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
        obs=$(jq -r '.probe.observed // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
        want=$(expected_observed "$trust" "$status" "$scenario")
        local why=""
        [ "$posts" = "0" ] || why="posted $posts"
        [ "$obs" = "$want" ] || why="${why:+$why; }observed=$obs want=$want"
        [ "$codex" = "0" ] || why="${why:+$why; }invoked codex-review-request $codex time(s)"
        case "$rc" in 0|2|6|7) ;; *) why="${why:+$why; }rc=$rc not in {0,2,6,7}" ;; esac
        [ "$rc" != "6" ] || [ "$skip" != "paused" ] || why="${why:+$why; }rc 6 with skip_reason=paused"
        [ "$head" = "head-sha" ] || why="${why:+$why; }head_sha=$head"
        if [ -n "$why" ]; then
          bad=$((bad + 1))
          echo "  sweep FAIL trust=$trust status=$status comment=$scenario → $why" >&2
        fi
      done
    done
  done
  if [ "$bad" = "0" ]; then
    pass "#814 probe: state-space sweep — $n states, all post nothing, none return 4/5, none return 6-with-paused"
  else
    fail "#814 probe: state-space sweep — $bad of $n states violate the barrier contract"
  fi
}

test_probe_summary_without_head_review_is_not_yet() {
  # Codex P1 on #823. A PR-level summary comment carries no commit SHA, so the
  # only thing tying it to this head is fresh_at >= HEAD_ANCHOR — and
  # HEAD_ANCHOR is the HEAD committer date, which whoever pushed controls. A
  # new head with an older committer date (cherry-pick, or a rebase preserving
  # committer dates) lets the PREVIOUS head's summary through, and
  # count_potential_issues then returns 0 for "no HEAD-pinned review" exactly
  # as it does for "reviewed, nothing found". Polling calls that advisory;
  # the barrier would call it REPORTED and approve a head nobody reviewed.
  #
  # Fixture: summary comment present and fresh, review object pinned to
  # old-sha. The probe must refuse on the absence of GitHub-owned HEAD
  # evidence rather than trust the timestamp.
  local dir rc
  dir=$(make_case probe-stale-anchor 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_stale_anchor)
  assert_probe_not_yet "$dir" "$rc" summary-without-head-review \
    "a prior-head summary with no HEAD-pinned review must not clear (author-controlled anchor)"
}

test_probe_summary_lagging_head_review_is_not_yet() {
  # Phase 4b P1 on #823. Existence of a HEAD-pinned review object is
  # necessary but not sufficient: CodeRabbit publishes the review object and
  # its PR-level summary as separate events. Mid-publication, a HEAD review
  # exists while the newest summary passing HEAD_ANCHOR is still the prior
  # head's — the inline count then reads the NEW review while the summary
  # marker check reads the OLD summary, so a finding carried only in the
  # forthcoming summary clears.
  #
  # Fixture: HEAD-pinned review at reply_time, prior-head summary at
  # head_time (earlier). The summary must be at least as recent as the
  # review it is credited to.
  # This expectation has moved twice and the current reason is the durable
  # one. A review object alone is not "has reported": CodeRabbit publishes the
  # object and its PR-level summary separately, and a blocking finding can be
  # carried SOLELY by the summary (#535). Releasing here would let Phase 4b
  # approve in that interval — and nothing downstream catches it, because
  # scripts/coderabbit-severity-gate.sh:330 fetches only pulls/{pr}/comments
  # and never the issue-comment summary. Verified, not assumed.
  #
  # #869 / P1 on #875 reconciliation: the barrier's rc-7 review-object
  # channel does NOT reopen this hole. It requires probe.context_state ==
  # "success" alongside the review object, and this fixture pins
  # trust_status_context_for_clearance: false, so the probe leaves
  # context_state null — asserted below — and the barrier stays not-yet on
  # exactly this JSON. The trust-enabled sampling directions live in
  # test_875_probe_awaiting_summary_context_state.
  local dir rc ctx
  dir=$(make_case probe-summary-lag 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_summary_lags_review)
  assert_probe_not_yet "$dir" "$rc" awaiting-summary \
    "a review whose summary has not landed is publication-incomplete, not reported"
  ctx=$(jq -r '.probe.context_state | tostring' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$ctx" = "null" ]; then
    pass "#875 probe: with trust_status_context_for_clearance=false the awaiting-summary JSON carries context_state=null (barrier stays closed)"
  else
    fail "#875 probe: expected context_state=null under trust=false; got $ctx"
  fi
}

test_probe_reviews_api_failure_is_infra_not_clean() {
  # Phase 4b P2 on #823. fetch_api_array's `die 3` runs in a SUBSHELL when the
  # call sits inside `[ -z "$(...)" ]`, so an API or jq failure collapsed to an
  # empty string and was reported as a clean rc 7 "no review yet" — a
  # transient outage read as a confident negative, which is the false-negative
  # class the barrier exists to prevent. The result is now captured and its
  # status checked, so infra failures stay rc 3.
  local dir rc=0
  dir=$(make_case probe-reviews-fail 600 true 30 3 2)
  ( cd "$dir" && PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 \
      CODERABBIT_TEST_STATE_DIR="$dir/state" \
      CODERABBIT_TEST_SCENARIO=probe_reviews_api_failure \
      ./scripts/coderabbit-wait.sh --probe 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log" ) || rc=$?
  if [ "$rc" = "3" ]; then
    pass "#814 probe: a reviews-API failure exits 3 (infra), not a clean 7"
  else
    fail "#814 probe: expected rc 3 on a reviews-API failure; got $rc"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_probe_evidence_does_not_expire() {
  # Evidence is SHA-pinned and must not age out. HEAD_ANCHOR carries a moving
  # wall-clock freshness floor and HEAD_IDENTITY_ANCHOR is the head committer
  # date, which the pusher controls; either would let a head that has been
  # sitting there stop reading as reported, deadlocking a barrier that
  # re-probes the same head. The probe selects on commit_id alone.
  #
  # Fixture: the review and its comment both predate the head committer date,
  # so any anchor-based filter would drop them.
  local dir rc status
  dir=$(make_case probe-old-evidence 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_finding_predates_head)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "0" ] && [ "$status" = "reported" ]; then
    pass "#814: a HEAD-pinned review predating the head committer date still reads as reported"
  else
    fail "#814: expected rc 0/reported for aged SHA-pinned evidence; got rc=$rc status=$status"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_probe_summary_only_marker_is_findings() {
  # #814 round 9 / #535. A blocking finding carried SOLELY by the PR-level
  # summary is dispositioned by NO required gate: coderabbit-severity-gate.sh
  # reads only pulls/{pr}/comments, the conversation gate covers threads, and
  # the Phase 4b adapter sees only the diff. Verified, not assumed — the
  # severity gate's single fetch is at scripts/coderabbit-severity-gate.sh:330.
  # So this is the one verdict the probe must make. Inline findings are NOT
  # counted here; the severity gate already owns those.
  local dir rc status
  dir=$(make_case probe-summary-marker 600 true 30 3 2)
  rc=$(run_probe_case "$dir" summary_marker_only)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "2" ] && [ "$status" = "findings" ]; then
    pass "#814: a summary-only blocking marker returns findings (rc 2) — no other gate would catch it"
  else
    fail "#814: expected rc 2/findings for a summary-only marker; got rc=$rc status=$status"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_probe_notice_after_review_is_not_complete() {
  # A non-terminal notice landing after the review object must not be mistaken
  # for the summary. Excluding narration alone was insufficient: a rate-limit,
  # paused, or in-progress comment updated after the review would otherwise
  # satisfy the publication check while the real summary is still pending.
  local dir rc
  dir=$(make_case probe-notice-after 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_notice_after_review)
  assert_probe_not_yet "$dir" "$rc" rate_limit \
    "a rate-limit notice after the review does not complete publication"
}

test_probe_narration_after_review_is_awaiting_summary() {
  # #833. The review-object publication scan classifies every later bot
  # comment, and classify_comment can return status_probe — so a narration
  # reply landing after the HEAD review object leaked
  # `probe.observed: "status_probe"`, a value the documented enum
  # deliberately excludes (observed live on #852 while the summary
  # publication lagged). Narration says nothing about publication state;
  # the contract value for review-present-summary-pending is
  # awaiting-summary.
  local dir rc
  dir=$(make_case probe-narration-after 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_narration_after_review)
  assert_probe_not_yet "$dir" "$rc" awaiting-summary \
    "narration after the review object reads awaiting-summary, never status_probe (#833)"
}

test_869_finished_review_with_limit_note_is_terminal() {
  # #869: a comment whose actions-performed block states the review FINISHED
  # must not read as rate_limit merely because the appended fair-use limit
  # note carries the rate-limit marker — completion evidence beats an
  # appended limit notice. Pre-fix the marker-first classification read the
  # body as rate_limit, the publication scan latched observed=rate_limit,
  # and the barrier held not-yet on a head coderabbitai[bot] had already
  # reviewed with two COMMENTED review objects (live on #866). Those two
  # HEAD-pinned objects are also what corroborates the completion claim
  # under the #875 head-anchoring rule (trust stays false here, so the
  # StatusContext leg never engages — the review-object leg alone carries
  # it, exactly as it did live).
  #
  # Reconciled by #875 round 5: the corroborated finished reply is
  # TERMINALITY evidence, never a verdict body — with no genuine
  # summarize-marker summary present it must NOT produce rc 0 off the
  # reply (whose body structurally carries no findings; see the shadowing
  # pair below), so this state now reads awaiting-summary on the reviews
  # evidence with the rate_limit latch still defeated. The #866 recovery
  # completes at the BARRIER, whose rc-7 conjuncts (completion-family
  # observed + correlated per-SHA success, both live on #866) are pinned
  # in tests/test_phase_4b_automation.sh; the polling arm's
  # wait-for-the-genuine-summary-then-clear flow for the same shape is
  # pinned by test_875_poll_finished_with_head_review_object_clears
  # (round 6).
  local dir rc ep id ctx
  dir=$(make_case probe-869-finished 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_review_finished_limit_note)
  assert_probe_not_yet "$dir" "$rc" awaiting-summary \
    "a finished-full-review reply with an appended limit note defeats the rate_limit latch and reads awaiting-summary (#869, refined by #875 round 5)"
  ep=$(jq -r '.review.endpoint // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  id=$(jq -r '.review.id // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctx=$(jq -r '.probe.context_state | tostring' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$ep" = "reviews" ] && [ "$id" = "9988" ] && [ "$ctx" = "null" ]; then
    pass "#869 probe: the rc-7 payload carries the newest head-pinned object (9988) with context null under trust=false — the barrier arbitrates"
  else
    fail "#869 probe: expected endpoint=reviews id=9988 context_state=null; got endpoint=$ep id=$id context_state=$ctx"
  fi
}

test_875e_finished_reply_cannot_shadow_the_real_summary() {
  # #875 round 5 shadowing pair. The finished actions reply was EDITED
  # (00:00:09) after the real summarize-marker summary (00:00:07), so the
  # newest-first scans reach the reply first in both modes.
  # (a) The real summary carries the SOLE blocking marker: pre-fix the
  # corroborated reply became summary_body / the marker-check body and both
  # modes cleared past the finding; post-fix both emit rc 2 findings.
  local dir rc status
  dir=$(make_case probe-875e-marker 600 true 30 3 2)
  rc=$(run_probe_case "$dir" finished_reply_shadows_marker_summary)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "2" ] && [ "$status" = "findings" ] \
     && [ "$(probe_count "$dir")" = "0" ] && [ "$(codex_invocations "$dir")" = "0" ]; then
    pass "#875 probe: a blocking marker in the real summary is found even when a newer finished reply shadows it (rc 2)"
  else
    fail "#875 probe: shadowed marker summary → rc=$rc status=$status (expected 2/findings)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi

  local pdir prc pstatus
  pdir=$(make_case poll-875e-marker 600 false 0 3 2)
  prc=$(run_case "$pdir" finished_reply_shadows_marker_summary)
  pstatus=$(jq -r '.status' "$pdir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$prc" = "2" ] && [ "$pstatus" = "findings" ]; then
    pass "#875 polling: the same shadowed blocking marker yields findings (rc 2) — marker-identity selection, not newest-first"
  else
    fail "#875 polling: shadowed marker summary → rc=$prc status=$pstatus (expected 2/findings)"
    sed 's/^/      /' "$pdir/err.log" >&2 || true
  fi

  # (b) The real summary is CLEAN and the reply carries a decoy warning
  # glyph: rc 0 in both modes proves the SUMMARY was the inspected body —
  # a verdict read off the reply would have emitted findings instead.
  local dir2 rc2 status2 observed2
  dir2=$(make_case probe-875e-clean 600 true 30 3 2)
  rc2=$(run_probe_case "$dir2" finished_reply_shadows_clean_summary)
  status2=$(jq -r '.status' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  observed2=$(jq -r '.probe.observed // "MISSING"' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc2" = "0" ] && [ "$status2" = "reported" ] && [ "$observed2" = "terminal" ]; then
    pass "#875 probe: a clean real summary beneath a decoy-glyph finished reply reports rc 0 off the summary"
  else
    fail "#875 probe: shadowed clean summary → rc=$rc2 status=$status2 observed=$observed2 (expected 0/reported/terminal)"
    sed 's/^/      /' "$dir2/err.log" >&2 || true
  fi

  local pdir2 prc2 pstatus2
  pdir2=$(make_case poll-875e-clean 600 false 0 3 2)
  prc2=$(run_case "$pdir2" finished_reply_shadows_clean_summary)
  pstatus2=$(jq -r '.status' "$pdir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$prc2" = "0" ] && [ "$pstatus2" = "cleared" ]; then
    pass "#875 polling: the same clean shadowed summary clears (rc 0) — the decoy glyph on the reply is never inspected"
  else
    fail "#875 polling: shadowed clean summary → rc=$prc2 status=$pstatus2 (expected 0/cleared)"
    sed 's/^/      /' "$pdir2/err.log" >&2 || true
  fi
}

test_869_limit_note_only_still_rate_limits() {
  # #869 control: a comment that is ONLY the fair-use limit note carries no
  # completion evidence and must keep classifying rate_limit — the #714/#489
  # paths depend on genuine rate-limit detection staying intact.
  local dir rc
  dir=$(make_case probe-869-noteonly 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_limit_note_only)
  assert_probe_not_yet "$dir" "$rc" rate_limit \
    "a comment that is ONLY a fair-use limit note still classifies rate_limit (#869 control)"
}

test_869_triggered_with_limit_note_still_rate_limits() {
  # #869 control: "Full review triggered." is the PRE-completion wording of
  # the same actions block — no completion is stated, so the appended limit
  # notice still names the operative state.
  local dir rc
  dir=$(make_case probe-869-triggered 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_triggered_limit_note)
  assert_probe_not_yet "$dir" "$rc" rate_limit \
    "Full review TRIGGERED (not finished) with a limit note appended stays rate_limit (#869 control)"
}

# Flip the fixture policy to trust_status_context_for_clearance: true — the
# same sed the state-space sweep uses. The #875 StatusContext-corroboration
# legs are trust-gated, and make_case pins trust false by default.
enable_trust_status_context() {
  sed -i.bak 's/^  trust_status_context_for_clearance: false$/  trust_status_context_for_clearance: true/' \
    "$1/.github/review-policy.yml" && rm -f "$1/.github/review-policy.yml.bak"
}

test_875_probe_finished_note_uncorroborated_is_rate_limit() {
  # #875 P1-b: the finished-review claim is a comment BODY with no head
  # identity. With a cherry-picked / old-committer-date new head the
  # wallclock freshness floor admits the PRIOR head's finished reply into
  # the scan; with NO head-pinned review object and NO head StatusContext
  # success, the completion claim must NOT beat the appended limit note —
  # the body falls through to rate_limit, exactly the pre-#869 class, so a
  # genuine current rate limit keeps driving the #714/#489 machinery.
  local dir rc
  dir=$(make_case probe-875-uncorrob 600 true 30 3 2)
  rc=$(run_probe_case "$dir" finished_note_uncorroborated)
  assert_probe_not_yet "$dir" "$rc" rate_limit \
    "a finished-review reply with NO head-anchored corroboration stays rate_limit (#875 P1-b)"
}

test_875_poll_finished_note_uncorroborated_stalls_rate_limit() {
  # #875 P1-b, polling side — the masked-rate-limit regression the finding
  # names. max_rate_limit_retries is 0, so if the prior-head finished reply
  # fell through to rate_limit (correct) the loop stalls immediately with
  # rc 5; if the unanchored completion claim had beaten the limit note, the
  # loop would have CLEARED (rc 0) a head CodeRabbit never reviewed.
  local dir rc status review_id
  dir=$(make_case poll-875-uncorrob 30 true 6 0 2)
  rc=$(run_case "$dir" finished_note_uncorroborated)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  review_id=$(jq -r '.review.id // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "5" ] && [ "$status" = "rate_limit_stalled" ] && [ "$review_id" = "9994" ]; then
    pass "#875 polling: an uncorroborated finished-review reply still drives the rate-limit path (rc 5 stall, never a clear)"
  else
    fail "#875 polling: uncorroborated finished reply → rc=$rc status=$status review.id=$review_id (expected 5/rate_limit_stalled/9994)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875_poll_finished_with_head_review_object_clears() {
  # #875 polling counterpart, reconciled by round 6: the corroborated
  # finished+limit body (trust stays false — the review-object leg alone
  # corroborates) defeats the rate_limit latch, but it is TERMINALITY
  # evidence, not a verdict body. With no genuine head summary published
  # the poll must KEEP POLLING (the 0 retry budget proves the body never
  # fell back to rate_limit — that would stall rc 5 instantly, and a
  # pre-round-6 clear would show waited_seconds 0); when the genuine
  # clean summarize-marker summary publishes on a later iteration, the
  # loop clears rc 0 on THAT body.
  local dir rc status waited fetches
  dir=$(make_case poll-875-corrob 600 false 0 0 2)
  rc=$(run_case "$dir" poll_finished_then_summary_clean)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  waited=$(jq -r '.waited_seconds' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  fetches=$(cat "$dir/state/issues-fetch-count" 2>/dev/null || echo 0)
  if [ "$rc" = "0" ] && [ "$status" = "cleared" ] \
     && [ "$waited" -ge 15 ] 2>/dev/null && [ "$fetches" -ge 3 ]; then
    pass "#875 polling: a corroborated attestation WAITS for the genuine summary, then clears rc 0 on it (waited=${waited}s, 0 retry budget untouched)"
  else
    fail "#875 polling: attestation-then-clean-summary → rc=$rc status=$status waited=$waited fetches=$fetches (expected 0/cleared, waited>=15, fetches>=3)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875f_poll_late_summary_with_marker_yields_findings() {
  # #875 round 6 negative twin: the summary that publishes AFTER the
  # attestation carries the sole blocking marker (#535). Pre-round-6 the
  # attestation cleared rc 0 on the first iteration, before this summary
  # existed to inspect; the wait-then-verdict flow must surface it as
  # findings rc 2 instead.
  local dir rc status waited
  dir=$(make_case poll-875f-marker 600 false 0 0 2)
  rc=$(run_case "$dir" poll_finished_then_summary_marker)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  waited=$(jq -r '.waited_seconds' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "2" ] && [ "$status" = "findings" ] && [ "$waited" -ge 15 ] 2>/dev/null; then
    pass "#875 polling: a blocking marker in the LATE-publishing summary yields findings rc 2 — the attestation never pre-cleared it"
  else
    fail "#875 polling: attestation-then-marker-summary → rc=$rc status=$status waited=$waited (expected 2/findings, waited>=15)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875f_poll_prior_head_summary_is_not_verdict_material() {
  # #875 round 6: the only summarize-marker comment was last refreshed
  # BEFORE the head review object — a PRIOR head summary that the
  # wallclock window still admits. It must never be selected as verdict
  # material for the new head: with the genuine summary never publishing,
  # the poll runs out its budget to the ADVISORY timeout (rc 4) — the
  # timeout-boundary gate included — instead of clearing on the stale
  # summary (the pre-fix bare-anchor re-selection behavior).
  local dir rc status
  dir=$(make_case poll-875f-priorhead 40 false 0 3 2)
  rc=$(run_case "$dir" poll_finished_prior_head_summary)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "4" ] && [ "$status" = "timeout" ]; then
    pass "#875 polling: a prior-head summary inside the wallclock window is never verdict material — the poll times out advisory (rc 4), never clears"
  else
    fail "#875 polling: prior-head summary → rc=$rc status=$status (expected 4/timeout)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875_probe_finished_note_status_corroborated_no_object() {
  # #875: StatusContext-success corroboration flips the CLASSIFICATION of a
  # finished reply (no longer rate_limit) but fabricates no probe EVIDENCE:
  # with no review object and no head-pinned summary the probe still answers
  # not-yet, on the issues endpoint, with observed=summary-without-head-review
  # — the same "nobody has spoken about THIS head" the barrier's trigger step
  # keys on. The ordering conjunct holds here (#875 round 2): the success
  # (default status time 00:00:00) PRECEDES the comment's fresh_at
  # (00:00:06), so the claim follows its evidence — the inverted direction
  # is pinned by test_875b_probe_status_postdating_finished_comment_
  # uncorroborated. context_state stays null because only the rc-7
  # review-object branch samples it, so the barrier cannot open on this
  # JSON either.
  local dir rc ep ctx
  dir=$(make_case probe-875-statuscorrob 600 true 30 3 2)
  enable_trust_status_context "$dir"
  rc=$(CODERABBIT_TEST_STATUS=success run_probe_case "$dir" finished_note_uncorroborated)
  assert_probe_not_yet "$dir" "$rc" summary-without-head-review \
    "a status-corroborated finished reply without a review object is still not head evidence (#875)"
  ep=$(jq -r '.review.endpoint // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctx=$(jq -r '.probe.context_state | tostring' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$ep" = "issues" ] && [ "$ctx" = "null" ]; then
    pass "#875 probe: status-corroborated finished reply carries issues-endpoint evidence and context_state=null (cannot open the barrier)"
  else
    fail "#875 probe: expected endpoint=issues context_state=null; got endpoint=$ep context_state=$ctx"
  fi
}

test_875_probe_awaiting_summary_context_state() {
  # #875 P1-a: the awaiting-summary rc-7 JSON is the ONE state whose
  # evidence is a HEAD-pinned review object, and the barrier requires
  # probe.context_state == "success" WITH probe.context_updated_at
  # at-or-after review.submitted_at alongside it. Direction 1: a head
  # StatusContext success refreshed AFTER the object (the
  # wedged-but-complete #866 discriminator) — the probe emits state, its
  # refresh time, and the object's submitted_at, and the barrier may open.
  # Since round 4 this direction also exercises the still-absent arm of
  # the TOCTOU re-scan: the success triggers the one bounded re-fetch, the
  # summary is still absent on the second snapshot, and the rc-7 payload
  # is kept.
  # Direction 2: with no status on the head the probe emits the sampled
  # "missing" — a bare just-posted review object whose summary (which can
  # carry the ONLY blocking marker, e.g. the auto-pause note) is still in
  # flight must NOT open the barrier. Direction 3 (#875 round 2): a
  # success whose refresh time PREDATES the object is the PREVIOUS
  # same-SHA run's — the probe reports it faithfully, and the emitted
  # timestamps are exactly what makes the barrier refuse it.
  local dir rc obs ep ctx ctxat subat
  dir=$(make_case probe-875-ctx-success 600 true 30 3 2)
  enable_trust_status_context "$dir"
  rc=$(CODERABBIT_TEST_STATUS=success CODERABBIT_TEST_STATUS_TIME=2026-06-04T00:00:07Z \
    run_probe_case "$dir" probe_summary_lags_review)
  obs=$(jq -r '.probe.observed // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  ep=$(jq -r '.review.endpoint // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctx=$(jq -r '.probe.context_state // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctxat=$(jq -r '.probe.context_updated_at // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  subat=$(jq -r '.review.submitted_at // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "7" ] && [ "$obs" = "awaiting-summary" ] && [ "$ep" = "reviews" ] \
     && [ "$ctx" = "success" ] && [ "$ctxat" = "2026-06-04T00:00:07Z" ] \
     && [ "$subat" = "2026-06-04T00:00:06Z" ] && [ "$(probe_count "$dir")" = "0" ]; then
    pass "#875 probe: awaiting-summary with a post-object StatusContext success emits correlated context_state/context_updated_at/submitted_at (barrier may open)"
  else
    fail "#875 probe: success direction → rc=$rc observed=$obs endpoint=$ep context_state=$ctx context_updated_at=$ctxat submitted_at=$subat"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi

  local dir2 rc2 obs2 ep2 ctx2 ctxat2
  dir2=$(make_case probe-875-ctx-absent 600 true 30 3 2)
  enable_trust_status_context "$dir2"
  rc2=$(run_probe_case "$dir2" probe_summary_lags_review)
  obs2=$(jq -r '.probe.observed // "MISSING"' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  ep2=$(jq -r '.review.endpoint // "MISSING"' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctx2=$(jq -r '.probe.context_state // "MISSING"' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctxat2=$(jq -r '.probe.context_updated_at | tostring' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc2" = "7" ] && [ "$obs2" = "awaiting-summary" ] && [ "$ep2" = "reviews" ] \
     && [ "$ctx2" = "missing" ] && [ "$ctxat2" = "null" ]; then
    pass "#875 probe: awaiting-summary with NO head status emits context_state=missing (a bare review object keeps the barrier closed)"
  else
    fail "#875 probe: absent direction → rc=$rc2 observed=$obs2 endpoint=$ep2 context_state=$ctx2 context_updated_at=$ctxat2"
    sed 's/^/      /' "$dir2/err.log" >&2 || true
  fi

  local dir3 rc3 ctx3 ctxat3 subat3
  dir3=$(make_case probe-875-ctx-stale 600 true 30 3 2)
  enable_trust_status_context "$dir3"
  # Default status time is head_time (00:00:00), which PREDATES the review
  # object at reply_time (00:00:06) — the same-SHA-rerun stale success.
  rc3=$(CODERABBIT_TEST_STATUS=success run_probe_case "$dir3" probe_summary_lags_review)
  ctx3=$(jq -r '.probe.context_state // "MISSING"' "$dir3/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctxat3=$(jq -r '.probe.context_updated_at // "MISSING"' "$dir3/out.json" 2>/dev/null || echo PARSE_ERROR)
  subat3=$(jq -r '.review.submitted_at // "MISSING"' "$dir3/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc3" = "7" ] && [ "$ctx3" = "success" ] \
     && [ "$ctxat3" = "2026-06-04T00:00:00Z" ] && [ "$subat3" = "2026-06-04T00:00:06Z" ]; then
    pass "#875 probe: a pre-object (previous-run) success is emitted with its stale refresh time — the barrier's ordering conjunct refuses it"
  else
    fail "#875 probe: stale-success direction → rc=$rc3 context_state=$ctx3 context_updated_at=$ctxat3 submitted_at=$subat3"
    sed 's/^/      /' "$dir3/err.log" >&2 || true
  fi
}

test_875b_poll_prior_head_finished_not_corroborated_by_new_object() {
  # #875 round 2 P1-a, polling side: the PRIOR head's finished reply
  # (fresh_at 00:00:00) is co-present with a review object CodeRabbit just
  # posted for the NEW head (submitted_at 00:00:06). The object postdates
  # the claim, so it cannot be what the claim reported on — corroboration
  # must be refused and the body falls through to rate_limit; with a 0
  # retry budget that is an immediate rc-5 stall, never a terminal clear
  # off a stale completion while the new head's publication is pending.
  local dir rc status review_id
  dir=$(make_case poll-875b-predates 30 true 6 0 2)
  rc=$(run_case "$dir" finished_note_predates_head_object)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  review_id=$(jq -r '.review.id // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "5" ] && [ "$status" = "rate_limit_stalled" ] && [ "$review_id" = "9995" ]; then
    pass "#875 polling: a finished reply PREDATING the new head review object is not corroborated by it (rc 5 stall, no stale terminal)"
  else
    fail "#875 polling: predating finished reply → rc=$rc status=$status review.id=$review_id (expected 5/rate_limit_stalled/9995)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875b_probe_prior_head_finished_with_new_object_awaits_summary() {
  # #875 round 2 P1-a, probe side of the same shape: the publication scan
  # only reads comments at-or-after the review object, so the stale
  # finished reply (00:00:00 < 00:00:06) never even reaches classification
  # — the state is awaiting-summary on the reviews evidence, with
  # context_state null (trust stays false here), which the barrier maps to
  # not-yet.
  local dir rc ep id ctx
  dir=$(make_case probe-875b-predates 600 true 30 3 2)
  rc=$(run_probe_case "$dir" finished_note_predates_head_object)
  assert_probe_not_yet "$dir" "$rc" awaiting-summary \
    "a prior-head finished reply beneath a fresh new-head object reads awaiting-summary (#875 round 2)"
  ep=$(jq -r '.review.endpoint // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  id=$(jq -r '.review.id // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctx=$(jq -r '.probe.context_state | tostring' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$ep" = "reviews" ] && [ "$id" = "9996" ] && [ "$ctx" = "null" ]; then
    pass "#875 probe: the evidence is the new object (9996) with context_state null — barrier stays closed"
  else
    fail "#875 probe: expected endpoint=reviews id=9996 context_state=null; got endpoint=$ep id=$id context_state=$ctx"
  fi
}

test_875c_poll_reviews_lookup_failure_denies_corroboration() {
  # #875 round 3 P1-ii: a TRANSIENT reviews-lookup failure is not "zero
  # objects". The finished reply here would corroborate on the status leg
  # (trust on, head success at 00:00:00, comment at 00:00:06) — but that
  # leg must not be consulted when the object question went UNANSWERED,
  # because on a same-SHA rerun the surviving success belongs to the
  # PREVIOUS run. Denied corroboration → rate_limit → immediate rc-5
  # stall on the 0 retry budget. A false corroboration would instead have
  # classified review and left rc 5 unreachable.
  local dir rc status review_id
  dir=$(make_case poll-875c-lookupfail 30 true 6 0 2)
  enable_trust_status_context "$dir"
  rc=$(CODERABBIT_TEST_STATUS=success run_case "$dir" finished_note_reviews_lookup_fails)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  review_id=$(jq -r '.review.id // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "5" ] && [ "$status" = "rate_limit_stalled" ] && [ "$review_id" = "9997" ]; then
    pass "#875 polling: a failed reviews lookup denies corroboration outright — the satisfiable status leg is not consulted (rc 5 stall)"
  else
    fail "#875 polling: lookup-failure corroboration → rc=$rc status=$status review.id=$review_id (expected 5/rate_limit_stalled/9997)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875h_poll_nonterminal_summary_is_not_verdict_material() {
  # #875 round 7 (Codex P1-b): the summarize marker names the ONE comment
  # CodeRabbit edits in place — it does not certify that the body currently
  # in it is a verdict. Here that comment was refreshed AFTER the head review
  # object (so marker identity and the ordering floor both accept it) while
  # carrying the mid-review stanza, and a finished attestation drives the
  # polling `review` arm. Selecting the mid-review body found no blocking
  # marker and cleared rc 0 ahead of the real summary — the same failure the
  # round-6 gate closed, reached through the selector instead. Validating the
  # candidate's CLASS leaves nothing selectable, so the poll runs out its
  # budget to the advisory timeout.
  local dir rc status
  dir=$(make_case poll-875h-nonterminal 40 false 0 3 2)
  rc=$(run_case "$dir" poll_finished_nonterminal_summary)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "4" ] && [ "$status" = "timeout" ]; then
    pass "#875 polling: a summarize-marker comment in a MID-REVIEW state is not verdict material — the poll times out advisory (rc 4), never clears"
  else
    fail "#875 polling: nonterminal summary → rc=$rc status=$status (expected 4/timeout)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875h_poll_attestation_blocks_status_fast_path() {
  # #875 round 7 (Codex P1-a): with trust_status_context_for_clearance on —
  # mergepath's own setting — the StatusContext fast path is a THIRD route to
  # rc 0, and #869 opened it by making a corroborated finished attestation
  # classify `review` instead of rate_limit. emit_status_context_verdict
  # scans INLINE findings only, so pre-fix this shape cleared rc 0 before any
  # summary existed to inspect, bypassing the round-6 gate on the poll arm
  # entirely. The fast path must be suppressed until a genuine head-anchored
  # summary publishes; with none ever published here, the poll times out.
  local dir rc status
  dir=$(make_case poll-875h-fastpath 40 false 0 3 2)
  enable_trust_status_context "$dir"
  rc=$(CODERABBIT_TEST_STATUS=success CODERABBIT_TEST_STATUS_TIME=2026-06-04T00:00:08Z \
    run_case "$dir" poll_finished_no_summary_status_success)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "4" ] && [ "$status" = "timeout" ]; then
    pass "#875 polling: a finished attestation with no published summary suppresses the StatusContext fast path (rc 4), never an inline-only rc 0"
  else
    fail "#875 polling: attestation + status success → rc=$rc status=$status (expected 4/timeout)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875h_probe_summary_quoting_the_phrases_is_not_an_attestation() {
  # #875 round 7 (Codex P1-c): the finished claim was matched by two
  # body-wide phrase greps, so any bot body DISCUSSING the mechanism matched
  # — including CodeRabbit's own walkthrough of a diff that touches this
  # code, which is the shape this very PR produces. Mislabelled, the genuine
  # summary is skipped at the probe's attestation-exclusion branch and the
  # blocking marker it carries alone (#535) is never inspected; a correlated
  # per-SHA success would then open the Phase 4b barrier over it. Matching
  # the generated stanza instead means this summary is read as a summary:
  # rc 2, the one verdict the probe makes.
  local dir rc obs
  dir=$(make_case probe-875h-quotes 600 false 0 0 0)
  rc=$(run_probe_case "$dir" probe_summary_quotes_finished_phrases)
  obs=$(jq -r '.probe.observed // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "2" ]; then
    pass "#875 probe: a genuine summary that QUOTES the finished phrases is a summary, not an attestation — its summary-only blocker surfaces as rc 2"
  else
    fail "#875 probe: summary quoting the phrases → rc=$rc observed=$obs (expected 2)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875g_poll_blank_reviews_body_denies_corroboration() {
  # #875 round 7: the silent twin of the lookup-failure case above. gh
  # exits 0 and writes NOTHING — the shape `jq -s 'add // []'` normalizes
  # to `[]`, which no downstream `type == "array"` check can tell from a
  # genuinely empty page. Read that way, the outage becomes outcome (b)
  # ("confirmed zero head objects") and the deliberately satisfiable
  # StatusContext leg corroborates the finished claim, classifying review.
  # Read correctly — a blank body is a failed read, because a REST array
  # endpoint always writes at least `[]` — corroboration is denied,
  # the body keeps its rate_limit class, and the 0 retry budget stalls
  # rc 5 immediately. Identical fixtures to the 5xx twin except HOW the
  # fetch fails, so rc 5 here is evidence about the blankness guard alone.
  local dir rc status review_id
  dir=$(make_case poll-875g-blankbody 30 true 6 0 2)
  enable_trust_status_context "$dir"
  rc=$(CODERABBIT_TEST_STATUS=success run_case "$dir" finished_note_reviews_body_blank)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  review_id=$(jq -r '.review.id // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "5" ] && [ "$status" = "rate_limit_stalled" ] && [ "$review_id" = "9993" ]; then
    pass "#875 polling: an exit-0 EMPTY reviews body is a failed read, not an empty array — corroboration denied (rc 5 stall)"
  else
    fail "#875 polling: blank reviews body → rc=$rc status=$status review.id=$review_id (expected 5/rate_limit_stalled/9993)"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_875d_probe_summary_landing_mid_probe_is_scanned() {
  # #875 round 4 TOCTOU: the probe's issue-comments snapshot predates its
  # status read, so the PR-level summary can land in the gap. Pre-fix the
  # probe emitted the rc-7 awaiting-summary payload with the fresh success
  # off the STALE snapshot, and the barrier opened past a just-published
  # summary it never scanned — including one carrying the #535 summary-only
  # blocking marker. Post-fix: after observing per-SHA success with the
  # summary unseen, the probe re-fetches the comments exactly once; a
  # summary found on the re-scan takes the normal rc-0/rc-2 verdict, with
  # the rc-7-only context fields cleared to null.
  local dir rc status observed id ctx fetches
  dir=$(make_case probe-875d-clean 600 true 30 3 2)
  enable_trust_status_context "$dir"
  rc=$(CODERABBIT_TEST_STATUS=success CODERABBIT_TEST_STATUS_TIME=2026-06-04T00:00:07Z \
    run_probe_case "$dir" probe_summary_lands_during_probe_clean)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  observed=$(jq -r '.probe.observed // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  id=$(jq -r '.review.id // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctx=$(jq -r '.probe.context_state | tostring' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  fetches=$(cat "$dir/state/issues-fetch-count" 2>/dev/null || echo 0)
  if [ "$rc" = "0" ] && [ "$status" = "reported" ] && [ "$observed" = "terminal" ] \
     && [ "$id" = "9998" ] && [ "$ctx" = "null" ] && [ "$fetches" = "2" ] \
     && [ "$(probe_count "$dir")" = "0" ]; then
    pass "#875 probe: a clean summary landing mid-probe is re-scanned and reported rc 0 (one bounded re-fetch, context fields null)"
  else
    fail "#875 probe: mid-probe clean summary → rc=$rc status=$status observed=$observed id=$id context_state=$ctx fetches=$fetches"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi

  local dir2 rc2 status2 fetches2
  dir2=$(make_case probe-875d-marker 600 true 30 3 2)
  enable_trust_status_context "$dir2"
  rc2=$(CODERABBIT_TEST_STATUS=success CODERABBIT_TEST_STATUS_TIME=2026-06-04T00:00:07Z \
    run_probe_case "$dir2" probe_summary_lands_during_probe_marker)
  status2=$(jq -r '.status' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  fetches2=$(cat "$dir2/state/issues-fetch-count" 2>/dev/null || echo 0)
  if [ "$rc2" = "2" ] && [ "$status2" = "findings" ] && [ "$fetches2" = "2" ]; then
    pass "#875 probe: a mid-probe summary carrying the #535 blocking marker escalates rc 2 instead of opening the barrier unscanned"
  else
    fail "#875 probe: mid-probe marker summary → rc=$rc2 status=$status2 fetches=$fetches2 (expected 2/findings/2)"
    sed 's/^/      /' "$dir2/err.log" >&2 || true
  fi
}

test_875b_probe_status_postdating_finished_comment_uncorroborated() {
  # #875 round 2, StatusContext leg ordering: a head success posted AFTER
  # the finished comment's last edit cannot be what that claim reported on
  # (the claim must follow its evidence, never precede it). The comment
  # (fresh_at 00:00:06) predates the success (00:10:00), so leg 2 refuses
  # and the body falls through to rate_limit.
  local dir rc
  dir=$(make_case probe-875b-latestatus 600 true 30 3 2)
  enable_trust_status_context "$dir"
  rc=$(CODERABBIT_TEST_STATUS=success CODERABBIT_TEST_STATUS_TIME=2026-06-04T00:10:00Z \
    run_probe_case "$dir" finished_note_uncorroborated)
  assert_probe_not_yet "$dir" "$rc" rate_limit \
    "a status success POSTDATING the finished comment does not corroborate it (#875 round 2)"
}

test_probe_narration_over_notice_surfaces_the_notice() {
  # #833 companion: the narration skip must not blank the whole latch. With
  # a rate-limit notice BENEATH the newest-row narration (both after the
  # review object), the observed class is the notice's — the same value the
  # narration-free probe_notice_after_review case pins.
  local dir rc
  dir=$(make_case probe-narration-over-notice 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_narration_over_notice)
  assert_probe_not_yet "$dir" "$rc" rate_limit \
    "narration atop a rate-limit notice still surfaces rate_limit (#833)"
}

test_probe_env_var_equals_flag() {
  local dir rc
  dir=$(make_case probe-envvar 600 true 30 3 2)
  rc=$(run_probe_case "$dir" none env)
  assert_probe_not_yet "$dir" "$rc" none "CODERABBIT_WAIT_PROBE=1 is equivalent to --probe"
}

test_probe_terminal_review_matches_polling_verdict() {
  local dir rc status observed posts
  dir=$(make_case probe-terminal 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_review_on_head)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  observed=$(jq -r '.probe.observed // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  posts=$(probe_count "$dir")
  if [ "$rc" = "0" ] && [ "$status" = "reported" ] && [ "$observed" = "terminal" ] && [ "$posts" = "0" ]; then
    pass "#814 probe: a review on HEAD exits 0/reported with observed=terminal and 0 posts"
  else
    fail "#814 probe: reported review → rc=$rc status=$status observed=$observed posts=$posts"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_probe_field_absent_on_polling_runs() {
  # The additive `probe` key must be null on every non-probe run, so the
  # historical JSON shape is unchanged for existing consumers.
  local dir rc probe_field
  dir=$(make_case probe-null-on-poll 600 false 30 3 2)
  rc=$(run_case "$dir" none)
  probe_field=$(jq -r '.probe | tostring' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "4" ] && [ "$probe_field" = "null" ]; then
    pass "#814 probe: the probe field is null on a polling run (additive, shape preserved)"
  else
    fail "#814 probe: expected rc 4 with probe=null on a polling run; got rc=$rc probe=$probe_field"
  fi
}

test_probe_unknown_option_fails_closed() {
  local dir rc=0
  dir=$(make_case probe-badopt 600 true 30 3 2)
  ( cd "$dir" && PATH="$dir/bin:$PATH" GH_TOKEN=test-token \
      CODERABBIT_TEST_STATE_DIR="$dir/state" CODERABBIT_TEST_SCENARIO=none \
      ./scripts/coderabbit-wait.sh --bogus 999 owner/repo >/dev/null 2>&1 ) || rc=$?
  if [ "$rc" = "3" ]; then
    pass "#814 probe: an unknown leading option exits 3 (usage), not silently ignored"
  else
    fail "#814 probe: expected rc 3 for an unknown option; got $rc"
  fi
}

# <dir> <rc> <expected_review_id> <label> — the #851 clean-summary terminal:
# rc 0, status reported, observed terminal, evidence on the ISSUES endpoint
# carrying the summarize comment's id (never a newer chat reply's), head_sha
# the head the scan classified, and ZERO writes on both counted surfaces.
assert_probe_reported_via_summary() {
  local dir=$1 rc=$2 want_id=$3 label=$4
  local got_status got_observed got_ep got_id got_head got_posts got_codex
  got_status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  got_observed=$(jq -r '.probe.observed // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  got_ep=$(jq -r '.review.endpoint // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  got_id=$(jq -r '.review.id // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  got_head=$(jq -r '.head_sha' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  got_posts=$(probe_count "$dir")
  got_codex=$(codex_invocations "$dir")
  if [ "$rc" = "0" ] && [ "$got_status" = "reported" ] \
     && [ "$got_observed" = "terminal" ] && [ "$got_ep" = "issues" ] \
     && [ "$got_id" = "$want_id" ] && [ "$got_head" = "head-sha" ] \
     && [ "$got_posts" = "0" ] && [ "$got_codex" = "0" ]; then
    pass "#851 probe: $label → rc 0 reported via summary $want_id, 0 writes"
  else
    fail "#851 probe: $label → rc=$rc status=$got_status observed=$got_observed endpoint=$got_ep id=$got_id head=$got_head posts=$got_posts codex=$got_codex"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

# The #851 scenario family, table-driven. Column 2 is the assertion:
#   reported:<id>      rc 0 via assert_probe_reported_via_summary, evidence id pinned
#   notyet:<observed>  rc 7 via assert_probe_not_yet
#   findings           rc 2 + status=findings (#535 parity on the new path)
# Each row is load-bearing for a specific mutation of the probe: the SHA
# conjunct (prior-head rows), the stanza allow-list (failed/skip/unknown), the
# class conjunct (legacy prose, aged past the anchor so only the anchor-free
# selection sees it), marker selection (the #794 chat-reply pair, with the
# evidence id proving WHICH comment was credited), anchor-free selection (the
# aged clean row), and the pre-merge strip (warning/outside/truncated rows).
test_851_summary_evidence_matrix() {
  local scenario expect label dir rc status
  while IFS='|' read -r scenario expect label; do
    [ -n "$scenario" ] || continue
    dir=$(make_case "probe-851-$scenario" 600 true 30 3 2)
    rc=$(run_probe_case "$dir" "$scenario")
    case "$expect" in
      reported:*)
        assert_probe_reported_via_summary "$dir" "$rc" "${expect#reported:}" "$label" ;;
      notyet:*)
        assert_probe_not_yet "$dir" "$rc" "${expect#notyet:}" "$label" ;;
      findings)
        status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
        if [ "$rc" = "2" ] && [ "$status" = "findings" ]; then
          pass "#851 probe: $label"
        else
          fail "#851 probe: $label -> rc=$rc status=$status"
          sed 's/^/      /' "$dir/err.log" >&2 || true
        fi ;;
    esac
  done <<'ROWS'
probe_clean_incremental|reported:7901|head-pinned completed summary with no review object is reported (the #849 defect)
probe_summary_aged_clean|reported:7924|clean summary older than the anchor still reads reported (anchor-free liveness)
probe_summary_premerge_warning|reported:7921|a pre-merge hygiene warning row is not a blocking finding
probe_summary_plus_chat_reply|reported:7917|with a newer SHA-quoting chat reply present, evidence is still the summary (#794)
probe_summary_clean_prior_head|notyet:summary-without-head-review|a clean summary naming only prior heads must not clear this one
probe_summary_review_failed|notyet:summary-without-head-review|a Review-failed stanza naming the head is an attempt, not a report (#790)
probe_summary_skip_review|notyet:summary-without-head-review|an explicit skip-review stanza naming the head is not a report (#797)
probe_summary_unknown_stanza|notyet:summary-without-head-review|a stanza KIND CodeRabbit has not shipped reads not-yet, never clean
probe_summary_legacy_ratelimit_prose|notyet:none|an aged summary with legacy rate-limit prose is rejected by class alone
probe_summary_paused_aged|notyet:none|an aged paused summary naming the head is rejected by class alone (#593)
probe_summary_midreview|notyet:in_progress|a mid-review summary that already names the head stays in_progress
probe_summary_chat_reply_only|notyet:summary-without-head-review|a SHA-quoting chat reply with a prior-head summary must not clear (#794)
probe_summary_marker_outside_premerge|findings|a blocking marker outside the pre-merge table escalates immediately as rc 2
probe_summary_premerge_truncated|findings|a truncated pre-merge block strips nothing and fails toward rc 2
ROWS
}

test_851_review_object_premerge_shares_strip() {
  # The review-object rc-2 site and Site E share one blocking-marker helper.
  # A head-pinned review whose summary carries only a pre-merge hygiene row
  # must read reported (endpoint=reviews), not findings — without the shared
  # strip, probe and polling disagreed about the same head.
  local dir rc status ep
  dir=$(make_case probe-851-robj-premerge 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_review_object_premerge_warning)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  ep=$(jq -r '.review.endpoint // "MISSING"' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "0" ] && [ "$status" = "reported" ] && [ "$ep" = "reviews" ]; then
    pass "#851 probe: review-object site strips the pre-merge table too (rc 0, endpoint=reviews)"
  else
    fail "#851 probe: review-object + pre-merge-only warning -> rc=$rc status=$status endpoint=$ep"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
  # And the POLLING path reads the same body the same way — its summary-marker
  # gate goes through the shared helper too, so probe and polling can never
  # disagree about one head over a hygiene row.
  local pdir prc pstatus
  pdir=$(make_case poll-851-robj-premerge 600 false 30 3 2)
  prc=$(run_case "$pdir" probe_review_object_premerge_warning)
  pstatus=$(jq -r '.status' "$pdir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$prc" = "0" ] && [ "$pstatus" = "cleared" ]; then
    pass "#851 polling: the same body clears in polling mode (shared strip, no divergence)"
  else
    fail "#851 polling: expected rc 0/cleared; got rc=$prc status=$pstatus"
    sed 's/^/      /' "$pdir/err.log" >&2 || true
  fi
}

test_851_summary_helpers_unit() {
  # The three predicates are pure; extract the sentinel block and source it so
  # the 40-hex token boundary and the zero-stanza vacuity guard are assertable
  # directly — the shared stub's head is the literal `head-sha`, which cannot
  # exercise either. Same extract-and-source pattern as
  # tests/test_audit_branch_protection.sh.
  local snip="$WORKDIR/summary-helpers.sh" h40 h64 bad=""
  local clean_body chat_body failure_body inside_body outside_body trunc_body
  eval "$(grep -E '^(CR_SUMMARY_BENIGN_STANZA_RE|CR_PRE_MERGE_BLOCK_START|CR_PRE_MERGE_BLOCK_END)=' \
    "$ROOT/scripts/coderabbit-wait.sh")"
  awk '/^# BEGIN coderabbit_summary_helpers$/{f=1;next} /^# END coderabbit_summary_helpers$/{f=0} f' \
    "$ROOT/scripts/coderabbit-wait.sh" >"$snip"
  # shellcheck disable=SC1090
  . "$snip"
  h40='0123456789abcdef0123456789abcdef01234567'
  b40='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  h64="deadbeef${h40}deadbeefdeadbeef"
  clean_body='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
No actionable comments.'
  chat_body='🧩 Analysis chain

head-sha is the current head per gh pr view.'
  failure_body="$clean_body
<!-- This is an auto-generated comment: failure by coderabbit.ai -->
Review failed.
<!-- end of auto-generated comment: failure by coderabbit.ai -->"
  bracket_body="$clean_body
<!-- This is an auto-generated comment: failure <head-changed> by coderabbit.ai -->
Review failed.
<!-- end of auto-generated comment: failure <head-changed> by coderabbit.ai -->"
  inside_body="$CR_PRE_MERGE_BLOCK_START
| Docstring Coverage | ⚠️ Warning | 38% |
$CR_PRE_MERGE_BLOCK_END"
  outside_body="_⚠️ Potential issue_
$inside_body"
  trunc_body="$CR_PRE_MERGE_BLOCK_START
_⚠️ Potential issue_ after truncation"
  inverted_body="$CR_PRE_MERGE_BLOCK_END
benign row
$CR_PRE_MERGE_BLOCK_START
_⚠️ Potential issue_ after an inverted pair"
  summary_stanzas_all_benign "$clean_body" || bad="$bad benign-clean"
  summary_stanzas_all_benign "$failure_body" && bad="$bad failure-passed"
  # A KIND carrying angle brackets must still REGISTER in the total — a
  # KIND-pattern count that excludes <> reads this refusing body as benign.
  summary_stanzas_all_benign "$bracket_body" && bad="$bad bracket-kind"
  # The vacuity guard: zero stanzas must be FALSE, or the two live chat
  # replies (#794, #518) that embed a head SHA read as completed summaries.
  summary_stanzas_all_benign "$chat_body" && bad="$bad vacuity"
  summary_names_head "between $b40 and $h40 today" "$h40" || bad="$bad sha-range-end"
  # The range START is the PREVIOUSLY-reviewed head; matching it would read a
  # later round's summary as this head's after a force-push back.
  summary_names_head "between $h40 and $b40 today" "$h40" && bad="$bad sha-range-start"
  # Refusal prose names the abandoned NEW head; only the range form counts.
  summary_names_head "changed during the review from $b40 to $h40" "$h40" && bad="$bad sha-refusal-prose"
  # A longer digest CONTAINING the head is not the head.
  summary_names_head "between $b40 and $h64 here" "$h40" && bad="$bad sha-superstring"
  summary_blocking_marker_present "$inside_body" && bad="$bad premerge-stripped"
  summary_blocking_marker_present "$outside_body" || bad="$bad real-marker"
  summary_blocking_marker_present "$trunc_body" || bad="$bad truncated"
  # END rendered before START is not a block; stripping to EOF from the
  # latched START would swallow the real marker after it.
  summary_blocking_marker_present "$inverted_body" || bad="$bad inverted-delims"
  if [ -z "$bad" ]; then
    pass "#851 helpers: stanza vacuity guard, 40-hex token boundary, pre-merge strip"
  else
    fail "#851 helpers:$bad"
  fi
}

test_446_newer_comment_suppresses_stale_status
test_timeout_probe_posts_once_and_surfaces_reply
test_existing_status_probe_reply_never_clears
test_rate_limit_stalled_does_not_probe
test_probe_post_failure_stays_timeout_advisory
test_probe_reply_poll_failure_stays_timeout_advisory
test_review_during_probe_wait_emits_findings
test_535_1_summary_body_marker_emits_findings
test_535_2_head_pinned_review_selection_emits_findings
test_probe_no_comment_is_not_yet
test_probe_rate_limit_is_not_yet_never_stalled
test_probe_paused_is_not_yet_never_skipped
test_probe_state_space_sweep
test_probe_summary_without_head_review_is_not_yet
test_probe_summary_lagging_head_review_is_not_yet
test_probe_reviews_api_failure_is_infra_not_clean
test_probe_summary_only_marker_is_findings
test_probe_notice_after_review_is_not_complete
test_probe_narration_after_review_is_awaiting_summary
test_probe_narration_over_notice_surfaces_the_notice
test_869_finished_review_with_limit_note_is_terminal
test_869_limit_note_only_still_rate_limits
test_869_triggered_with_limit_note_still_rate_limits
test_875_probe_finished_note_uncorroborated_is_rate_limit
test_875_poll_finished_note_uncorroborated_stalls_rate_limit
test_875_poll_finished_with_head_review_object_clears
test_875_probe_finished_note_status_corroborated_no_object
test_875_probe_awaiting_summary_context_state
test_875b_poll_prior_head_finished_not_corroborated_by_new_object
test_875b_probe_prior_head_finished_with_new_object_awaits_summary
test_875b_probe_status_postdating_finished_comment_uncorroborated
test_875c_poll_reviews_lookup_failure_denies_corroboration
test_875g_poll_blank_reviews_body_denies_corroboration
test_875h_poll_nonterminal_summary_is_not_verdict_material
test_875h_poll_attestation_blocks_status_fast_path
test_875h_probe_summary_quoting_the_phrases_is_not_an_attestation
test_875d_probe_summary_landing_mid_probe_is_scanned
test_875e_finished_reply_cannot_shadow_the_real_summary
test_875f_poll_late_summary_with_marker_yields_findings
test_875f_poll_prior_head_summary_is_not_verdict_material
test_probe_evidence_does_not_expire
test_probe_env_var_equals_flag
test_probe_terminal_review_matches_polling_verdict
test_probe_field_absent_on_polling_runs
test_probe_unknown_option_fails_closed
test_851_summary_evidence_matrix
test_851_review_object_premerge_shares_strip
test_851_summary_helpers_unit

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
