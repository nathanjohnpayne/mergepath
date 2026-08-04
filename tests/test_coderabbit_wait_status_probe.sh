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
  # Hard-required by coderabbit-wait.sh since #837: the potential-issue count
  # grades findings with the shared coderabbit_tier_of.
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"
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
    # below never exercise. CODERABBIT_TEST_STATUS_TIME (#869) positions
    # the status in time — the barrier's temporal conjunct orders it
    # against the head review object; it defaults to head_time, which
    # PREDATES reply_time-stamped evidence, so tests exercising the
    # correlated direction must set it explicitly.
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
      badge_only_inline_finding)
        # #837: an ordinary review on HEAD. The interesting part is the FORMAT
        # of its inline finding (pulls endpoint below).
        printf '[{"id":9711,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"}]\n' "$bot" "$head_time"
        ;;
      badge_only_summary_finding)
        # #837 acceptance 2: the same format carried SOLELY by the PR-level
        # summary, which is the one verdict --probe makes.
        printf '[{"id":9721,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha"}]\n' "$bot" "$head_time"
        ;;
      future_dated_head_review)
        # #824: the review is pinned to THIS head (commit_id head-sha) but was
        # submitted BEFORE the head committer date — the shape a future-dated
        # or metadata-rewritten commit produces, since the committer date is
        # whatever the pusher wrote. Pre-fix the `submitted_at >= HEAD_ANCHOR`
        # conjunct discarded it and the finding below went uncounted.
        printf '[{"id":9731,"user":{"login":"%s"},"submitted_at":"2026-06-03T00:00:00Z","commit_id":"head-sha"}]\n' "$bot"
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
      probe_summary_lands_during_probe_clean|probe_summary_lands_during_probe_marker)
        # #869 TOCTOU: a head-pinned review object; the PR-level summary
        # lands BETWEEN the probe's first issue-comments snapshot and its
        # status read (the issues endpoint below serves the two snapshots
        # by fetch count).
        printf '[{"id":9998,"user":{"login":"%s"},"submitted_at":"%s","commit_id":"head-sha","state":"COMMENTED"}]\n' "$bot" "$reply_time"
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
      badge_only_inline_finding)
        # #837, verbatim from the live #835 finding (comment 3687972302): the
        # severity-badge prefix CodeRabbit emits today, plus the machine tag.
        # There is NO literal "Potential issue" and NO ⚠️ anywhere in the body,
        # so the retired `grep -iE 'Potential issue|⚠️'` counted zero and the
        # helper reported `cleared` on a Major security finding.
        printf '[{"id":9712,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","commit_id":"head-sha","pull_request_review_id":9711,"in_reply_to_id":null,"body":"_🔒 Security \\u0026 Privacy_ | _🟠 Major_ | _⚡ Quick win_\\n\\n**Reject the diagnostic bypass in merge-gate callers.**\\n\\nThe caller accepts a bypass flag that skips the gate.\\n\\n<!-- cr-indicator-types:potential_issue -->"}]\n' "$bot" "$head_time" "$head_time"
        ;;
      future_dated_head_review)
        # #824: an ordinary blocking finding on the SHA-matched review. Its
        # own timestamps predate the head committer date too, so nothing but
        # the commit_id ties it to this head.
        printf '[{"id":9732,"user":{"login":"%s"},"created_at":"2026-06-03T00:00:00Z","updated_at":"2026-06-03T00:00:00Z","commit_id":"head-sha","pull_request_review_id":9731,"in_reply_to_id":null,"body":"_⚠️ Potential issue_\\n\\nFinding on the SHA-matched review."}]\n' "$bot"
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
      probe_summary_lands_during_probe_clean|probe_summary_lands_during_probe_marker)
        # #869 TOCTOU, served by fetch count: the FIRST snapshot predates
        # the summary (only the prior-head summary from before the review
        # object exists), the SECOND — the post-success re-fetch — carries
        # the just-published summary for this head at 00:00:08, after the
        # review object at reply_time. The marker variant's summary carries
        # the #535 summary-only blocking marker; pre-fix both variants
        # emitted the rc-7 success payload off the stale first snapshot and
        # the barrier opened past the unscanned summary.
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
      badge_only_inline_finding|future_dated_head_review)
        # A marker-free summary, so the verdict can only come from the inline
        # count — the surface each of these two cases is actually about.
        printf '[{"id":8711,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 1**\\n\\nSee inline findings on the HEAD review."}]\n' "$bot" "$head_time" "$head_time"
        ;;
      badge_only_summary_finding)
        # #837 acceptance 2: the modern badge format carried ONLY by the
        # PR-level summary. No inline comment exists, so this is the #535
        # class — the finding no required gate dispositions — in the format
        # the retired grep could not see.
        printf '[{"id":8721,"user":{"login":"%s"},"created_at":"%s","updated_at":"%s","body":"**Actionable comments posted: 1**\\n\\n<details>\\n<summary>scripts/foo.sh (1)</summary>\\n\\n_🔒 Security \\u0026 Privacy_ | _🟠 Major_ | _⚡ Quick win_\\n\\n**Reject the diagnostic bypass in merge-gate callers.**\\n\\n<!-- cr-indicator-types:potential_issue -->"}]\n' "$bot" "$head_time" "$head_time"
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
  # probe-mode role is CONJUNCTIVE (#869): riding the rc-7 review-object
  # JSON as probe.context_state / context_updated_at — and no swept
  # scenario carries a head-pinned review object, so `observed` stays
  # status-independent here. Both dimensions are swept anyway, so a future
  # change that starts reading it elsewhere shows up as a mismatch; the
  # ride-along path is pinned by the dedicated #869 cases below.
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
  # #869 barrier-corroboration reconciliation: the barrier's rc-7
  # review-object channel does NOT reopen this hole. It requires
  # probe.context_state == "success" (refreshed at-or-after the object)
  # alongside the review object, and this fixture pins
  # trust_status_context_for_clearance: false, so the probe leaves
  # context_state null — asserted below — and the barrier stays not-yet on
  # exactly this JSON. The trust-enabled sampling directions live in
  # test_869_probe_awaiting_summary_context_state.
  local dir rc ctx
  dir=$(make_case probe-summary-lag 600 true 30 3 2)
  rc=$(run_probe_case "$dir" probe_summary_lags_review)
  assert_probe_not_yet "$dir" "$rc" awaiting-summary \
    "a review whose summary has not landed is publication-incomplete, not reported"
  ctx=$(jq -r '.probe.context_state | tostring' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$ctx" = "null" ]; then
    pass "#869 probe: with trust_status_context_for_clearance=false the awaiting-summary JSON carries context_state=null (barrier stays closed)"
  else
    fail "#869 probe: expected context_state=null under trust=false; got $ctx"
  fi
}

# Flip the fixture policy to trust_status_context_for_clearance: true — the
# same sed the state-space sweep uses. The #869 StatusContext sampling is
# trust-gated, and make_case pins trust false by default.
enable_trust_status_context() {
  sed -i.bak 's/^  trust_status_context_for_clearance: false$/  trust_status_context_for_clearance: true/' \
    "$1/.github/review-policy.yml" && rm -f "$1/.github/review-policy.yml.bak"
}

test_869_probe_awaiting_summary_context_state() {
  # #869: the awaiting-summary rc-7 JSON is the ONE state whose evidence is
  # a HEAD-pinned review object, and the barrier requires
  # probe.context_state == "success" WITH probe.context_updated_at
  # at-or-after review.submitted_at alongside it. Direction 1: a head
  # StatusContext success refreshed AFTER the object (the
  # wedged-but-complete #866 discriminator) — the probe emits state, its
  # refresh time, and the object's submitted_at, and the barrier may open.
  # This direction also exercises the still-absent arm of the TOCTOU
  # re-scan: the success triggers the one bounded re-fetch, the summary is
  # still absent on the second snapshot, and the rc-7 payload is kept.
  # Direction 2: with no status on the head the probe emits the sampled
  # "missing" — a bare just-posted review object whose summary (which can
  # carry the ONLY blocking marker, e.g. the auto-pause note) is still in
  # flight must NOT open the barrier. Direction 3: a success whose refresh
  # time PREDATES the object is the PREVIOUS same-SHA run's — the probe
  # reports it faithfully, and the emitted timestamps are exactly what
  # makes the barrier refuse it.
  local dir rc obs ep ctx ctxat subat
  dir=$(make_case probe-869-ctx-success 600 true 30 3 2)
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
    pass "#869 probe: awaiting-summary with a post-object StatusContext success emits correlated context_state/context_updated_at/submitted_at (barrier may open)"
  else
    fail "#869 probe: success direction → rc=$rc observed=$obs endpoint=$ep context_state=$ctx context_updated_at=$ctxat submitted_at=$subat"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi

  local dir2 rc2 obs2 ep2 ctx2 ctxat2
  dir2=$(make_case probe-869-ctx-absent 600 true 30 3 2)
  enable_trust_status_context "$dir2"
  rc2=$(run_probe_case "$dir2" probe_summary_lags_review)
  obs2=$(jq -r '.probe.observed // "MISSING"' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  ep2=$(jq -r '.review.endpoint // "MISSING"' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctx2=$(jq -r '.probe.context_state // "MISSING"' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctxat2=$(jq -r '.probe.context_updated_at | tostring' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc2" = "7" ] && [ "$obs2" = "awaiting-summary" ] && [ "$ep2" = "reviews" ] \
     && [ "$ctx2" = "missing" ] && [ "$ctxat2" = "null" ]; then
    pass "#869 probe: awaiting-summary with NO head status emits context_state=missing (a bare review object keeps the barrier closed)"
  else
    fail "#869 probe: absent direction → rc=$rc2 observed=$obs2 endpoint=$ep2 context_state=$ctx2 context_updated_at=$ctxat2"
    sed 's/^/      /' "$dir2/err.log" >&2 || true
  fi

  local dir3 rc3 ctx3 ctxat3 subat3
  dir3=$(make_case probe-869-ctx-stale 600 true 30 3 2)
  enable_trust_status_context "$dir3"
  # Default status time is head_time (00:00:00), which PREDATES the review
  # object at reply_time (00:00:06) — the same-SHA-rerun stale success.
  rc3=$(CODERABBIT_TEST_STATUS=success run_probe_case "$dir3" probe_summary_lags_review)
  ctx3=$(jq -r '.probe.context_state // "MISSING"' "$dir3/out.json" 2>/dev/null || echo PARSE_ERROR)
  ctxat3=$(jq -r '.probe.context_updated_at // "MISSING"' "$dir3/out.json" 2>/dev/null || echo PARSE_ERROR)
  subat3=$(jq -r '.review.submitted_at // "MISSING"' "$dir3/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc3" = "7" ] && [ "$ctx3" = "success" ] \
     && [ "$ctxat3" = "2026-06-04T00:00:00Z" ] && [ "$subat3" = "2026-06-04T00:00:06Z" ]; then
    pass "#869 probe: a pre-object (previous-run) success is emitted with its stale refresh time — the barrier's ordering conjunct refuses it"
  else
    fail "#869 probe: stale-success direction → rc=$rc3 context_state=$ctx3 context_updated_at=$ctxat3 submitted_at=$subat3"
    sed 's/^/      /' "$dir3/err.log" >&2 || true
  fi
}

test_869_probe_summary_landing_mid_probe_is_scanned() {
  # #869 TOCTOU (P1 on the lean PR): the probe's issue-comments snapshot
  # predates its status read, so the PR-level summary can land in the gap.
  # Pre-fix the probe emitted the rc-7 awaiting-summary payload with the
  # fresh success off the STALE snapshot, and the barrier opened past a
  # just-published summary it never scanned — including one carrying the
  # #535 summary-only blocking marker. Post-fix: after observing per-SHA
  # success with the summary unseen, the probe re-fetches the comments
  # exactly once; a summary found on the re-scan takes the normal
  # rc-0/rc-2 verdict, with the rc-7-only context fields cleared to null.
  local dir rc status observed id ctx fetches
  dir=$(make_case probe-869-toctou-clean 600 true 30 3 2)
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
    pass "#869 probe: a clean summary landing mid-probe is re-scanned and reported rc 0 (one bounded re-fetch, context fields null)"
  else
    fail "#869 probe: mid-probe clean summary → rc=$rc status=$status observed=$observed id=$id context_state=$ctx fetches=$fetches"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi

  local dir2 rc2 status2 fetches2
  dir2=$(make_case probe-869-toctou-marker 600 true 30 3 2)
  enable_trust_status_context "$dir2"
  rc2=$(CODERABBIT_TEST_STATUS=success CODERABBIT_TEST_STATUS_TIME=2026-06-04T00:00:07Z \
    run_probe_case "$dir2" probe_summary_lands_during_probe_marker)
  status2=$(jq -r '.status' "$dir2/out.json" 2>/dev/null || echo PARSE_ERROR)
  fetches2=$(cat "$dir2/state/issues-fetch-count" 2>/dev/null || echo 0)
  if [ "$rc2" = "2" ] && [ "$status2" = "findings" ] && [ "$fetches2" = "2" ]; then
    pass "#869 probe: a mid-probe summary carrying the #535 blocking marker escalates rc 2 instead of opening the barrier unscanned"
  else
    fail "#869 probe: mid-probe marker summary → rc=$rc2 status=$status2 fetches=$fetches2 (expected 2/findings/2)"
    sed 's/^/      /' "$dir2/err.log" >&2 || true
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

test_837_badge_only_inline_finding_is_counted() {
  # #837, the live #835 false clearance. A 🟠 Major security finding whose body
  # carries NO literal "Potential issue" and NO ⚠️ must still be counted, so the
  # run reports findings instead of `cleared`. The PR-level summary is
  # deliberately marker-free: only the inline count can produce this verdict, so
  # a regression cannot be masked by the #535 summary path.
  local dir rc status potential
  dir=$(make_case badge-only-inline 600 false 0 2)
  rc=$(run_case "$dir" badge_only_inline_finding)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  potential=$(jq -r '.potential_issue_count' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "2" ] && [ "$status" = "findings" ] && [ "$potential" = "1" ]; then
    pass "#837: a 🟠 Major finding with no Potential issue/⚠️ text is counted (rc 2, count 1)"
  else
    fail "#837: expected rc 2/findings/count 1 for the badge-only finding; got rc=$rc status=$status count=$potential"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_837_badge_only_summary_finding_probe_is_findings() {
  # #837 acceptance 2. --probe makes exactly one verdict — a blocking marker
  # carried solely by the PR-level summary (#535) — and it must recognize that
  # marker in CodeRabbit's current badge format, not just the retired literals.
  local dir rc status
  dir=$(make_case badge-only-summary 600 true 30 3 2)
  rc=$(run_probe_case "$dir" badge_only_summary_finding)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "2" ] && [ "$status" = "findings" ]; then
    pass "#837: --probe returns findings for a summary-only finding in the badge format"
  else
    fail "#837 probe: expected rc 2/findings for the badge-only summary; got rc=$rc status=$status"
    sed 's/^/      /' "$dir/err.log" >&2 || true
  fi
}

test_824_sha_matched_review_is_honored_regardless_of_timestamp() {
  # #824. The HEAD committer date is pusher-controlled; when it is dated ahead
  # of GitHub's clock, a review OF THIS EXACT SHA has submitted_at < the anchor.
  # Requiring both the SHA match and the timestamp let the weaker, spoofable
  # condition veto the stronger one, dropping the review — and with it every
  # finding scoped to it — until wall-clock caught up. commit_id alone selects
  # it now, so the finding is counted immediately.
  local dir rc status potential
  dir=$(make_case future-dated-head 600 false 0 2)
  rc=$(run_case "$dir" future_dated_head_review)
  status=$(jq -r '.status' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  potential=$(jq -r '.potential_issue_count' "$dir/out.json" 2>/dev/null || echo PARSE_ERROR)
  if [ "$rc" = "2" ] && [ "$status" = "findings" ] && [ "$potential" = "1" ]; then
    pass "#824: a SHA-matched review is honored though it predates the head committer date (rc 2, count 1)"
  else
    fail "#824: expected rc 2/findings/count 1 for the SHA-matched aged review; got rc=$rc status=$status count=$potential"
    sed 's/^/      /' "$dir/err.log" >&2 || true
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
  # The block's one external dependency (#837): the shared classifier the
  # blocking-marker predicate grades each line with. Sourced from the same
  # canonical lib the script hard-requires, so the unit assertions below run
  # against the real classifier rather than a test-local stand-in.
  # shellcheck source=../scripts/lib/feedback-policy-helpers.sh
  . "$ROOT/scripts/lib/feedback-policy-helpers.sh"
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

test_884_count_bodies_fails_closed_unit() {
  # #884: the counting path must never answer "0 blocking findings" for input
  # it could not read. The pre-fix code relied on `jq 'length'` failing loudly
  # on a dead upstream fetch; it does not — on EMPTY stdin jq prints nothing
  # and exits 0, the `while` condition errored (exempt from errexit), and the
  # function echoed 0 with status 0. That is a silent false-clear of exactly
  # the kind #837 fixes, so it is asserted directly on the pure helpers rather
  # than through the stub harness, which cannot produce a dead fetch.
  local snip="$WORKDIR/count-helpers.sh" bad="" out rc
  awk '/^# BEGIN coderabbit_summary_helpers$/{f=1;next} /^# END coderabbit_summary_helpers$/{f=0} f' \
    "$ROOT/scripts/coderabbit-wait.sh" >"$snip"
  awk '/^# BEGIN coderabbit_count_helpers$/{f=1;next} /^# END coderabbit_count_helpers$/{f=0} f' \
    "$ROOT/scripts/coderabbit-wait.sh" >>"$snip"
  # The real classifier the blocking predicate grades each line with, plus the
  # script's stderr logger, which crw_count_blocking_bodies calls on refusal.
  # shellcheck source=../scripts/lib/feedback-policy-helpers.sh
  . "$ROOT/scripts/lib/feedback-policy-helpers.sh"
  log() { echo "[coderabbit-wait] $*" >&2; }
  # shellcheck disable=SC1090
  . "$snip"

  # 1. A dead upstream fetch (empty string) must REFUSE, not report zero.
  rc=0; out=$(crw_count_blocking_bodies "" 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || bad="$bad empty-returned-success"
  [ "$out" != "0" ] || bad="$bad empty-reported-zero"

  # 2. A non-array JSON value is the same hazard by another route.
  rc=0; out=$(crw_count_blocking_bodies '{}' 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || bad="$bad object-returned-success"
  rc=0; out=$(crw_count_blocking_bodies '"a string"' 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || bad="$bad string-returned-success"

  # 3. A genuinely empty array is NOT an error — it is a real zero.
  rc=0; out=$(crw_count_blocking_bodies '[]' 2>/dev/null) || rc=$?
  { [ "$rc" -eq 0 ] && [ "$out" = "0" ]; } || bad="$bad empty-array-not-clean-zero"

  # 4. Valid arrays still count correctly: the badge-only Major of #837 counts,
  #    ordinary prose does not.
  rc=0
  out=$(crw_count_blocking_bodies \
    '["_🔒 Security & Privacy_ | _🟠 Major_ | _⚡ Quick win_","just a nitpick"]' 2>/dev/null) || rc=$?
  { [ "$rc" -eq 0 ] && [ "$out" = "1" ]; } || bad="$bad valid-array-count=$out/rc=$rc"

  if [ -z "$bad" ]; then
    pass "#884: crw_count_blocking_bodies fails closed on unreadable input, still counts valid arrays"
  else
    fail "#884 count fail-closed:$bad"
  fi
}

test_884_count_bodies_fails_closed_unit
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
test_869_probe_awaiting_summary_context_state
test_869_probe_summary_landing_mid_probe_is_scanned
test_probe_reviews_api_failure_is_infra_not_clean
test_probe_summary_only_marker_is_findings
test_probe_notice_after_review_is_not_complete
test_probe_narration_after_review_is_awaiting_summary
test_probe_narration_over_notice_surfaces_the_notice
test_probe_evidence_does_not_expire
test_probe_env_var_equals_flag
test_probe_terminal_review_matches_polling_verdict
test_probe_field_absent_on_polling_runs
test_probe_unknown_option_fails_closed
test_851_summary_evidence_matrix
test_851_review_object_premerge_shares_strip
test_851_summary_helpers_unit
test_837_badge_only_inline_finding_is_counted
test_837_badge_only_summary_finding_probe_is_findings
test_824_sha_matched_review_is_honored_regardless_of_timestamp

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
