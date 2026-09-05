#!/usr/bin/env bash
# Publish head-pinned diagnostics for approval-continuation infrastructure
# failures. These are distinct from label-removal failures: an approved PR can
# legitimately have no needs-external-review label, so label-absence healing
# must never convert a continuation failure into a successful check-run.
#
# CONTINUATION_CLEAR_V1 (#1188): that invariant is preserved, but the diagnostic
# is no longer write-once. Before this marker existed the script had no success
# arm at all, so the check-run it posts had NO path back to green from any
# source — including a genuine later success of the very continuation it
# reports on. `mergeStateStatus` then sat at UNSTABLE for the life of the head
# and every affected PR became a break-glass decision with nothing actually
# wrong (observed on nathanjohnpayne/fiveacross#1108, whose failing run was
# re-run to success while the check-run stayed red).
#
# `--clear` closes that gap WITHOUT weakening the header's invariant, because
# it is deliberately narrow on both sides:
#
#   * Only this producer clears it. The caller runs `--clear` solely from the
#     continuation step's own clean-evaluation arm, so label-absence healing
#     (or any other unrelated path) still cannot convert a failure to success.
#   * It only ever supersedes a failure it can see. If the head carries no
#     `approval-merge-continuation` check-run, or its latest one is not a
#     failure, `--clear` writes nothing. Without that guard every approved PR
#     fleet-wide would grow a fresh check-run on every qualifying event.
#   * It UPDATES the run it selected rather than creating a newer success.
#     Creating one would re-enter the latest-run-wins race: a failure published
#     between the read and the write would be the newest evidence, and a fresh
#     success would bury it. Updating the selected run cannot bury anything.
#   * A verdict only clears a diagnostic from a stage it actually REACHED. The
#     continuation runs in two stages -- protective retraction, then the
#     author-token readiness continuation -- and a repo with no
#     AUTHOR_MERGE_TOKEN never reaches the second. Without the stage on both
#     sides, either a protective-only pass silently clears a failure from the
#     author-token stage it never ran, or (the mirror defect) a repo that can
#     only ever reach the protective stage can never clear a protective-stage
#     failure and keeps a permanently red head -- exactly the #1188 bug, for a
#     different population. Both sides are recorded, so neither happens.
#
# `--clear` therefore takes `PR:SHA:EPOCH`, not a bare PR number. Re-resolving
# the head at POST time is unsafe on its own: a push landing between the verdict
# and this call would let a clean result for head A publish success on head B,
# superseding a failure that belongs to B and was never evaluated. The SHA pins
# the write to the head the verdict was actually about, and the epoch keeps a
# failure published DURING or AFTER that verdict from being cleared by it --
# newer evidence outranks an older verdict even on the same head.
#
# The failure conclusion stays `failure` rather than softening to `neutral`.
# "We could not verify this is safe to merge" should block; the defect was the
# missing exit, not the severity.

set -euo pipefail

MODE=report
if [ "${1:-}" = "--clear" ]; then
  MODE=clear
  shift
fi

if [ "$#" -ne 3 ]; then
  echo "usage: report-approval-continuation-failures.sh [--clear] <owner/repo> <run-url> <space-separated-pr-numbers>" >&2
  exit 2
fi

REPO="$1"
RUN_URL="$2"
PR_NUMBERS="$3"
CHECK_NAME='approval-merge-continuation'
# Machine-readable stage marker embedded in the diagnostic's summary. It is the
# only durable record of WHICH stage failed, and a clear consults it so a
# protective-only verdict cannot clear a full-continuation failure.
STAGE_MARKER_PREFIX='[continuation-stage: '
# When the diagnostic's evaluation happened, as opposed to when it was
# published. Concurrent triggers make these diverge: an older evaluation can
# fail and reach the reporter AFTER a newer clean evaluation already ran its
# clearing step, and `started_at` would then rank that stale failure as the
# newer evidence and keep the head red. On a consumer with
# `scheduled_sweep_enabled: false` no later event is guaranteed to arrive, so
# that is the #1188 bug once more. Recency is judged on this marker when it is
# present; selection still uses started_at, because publication order is what
# GitHub's own rollup gates on.
EVAL_MARKER_PREFIX='[continuation-evaluated-at: '
# Heading under which a superseded diagnostic is preserved, so the advance path
# can find and carry it forward rather than overwriting it.
PRESERVED_HEADING='Superseded diagnostic, preserved verbatim:'
# Set when a clear-side write fails. A failed clear leaves the merge-blocking
# diagnostic red while the workflow reports success, and on a consumer with
# scheduled_sweep_enabled: false nothing is guaranteed to retry it -- exactly
# the silently-preserved condition this script exists to heal, so it surfaces
# as a retryable failed run instead.
CLEAR_WRITE_FAILED=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/gh-retry-helpers.sh
source "$ROOT/scripts/lib/gh-retry-helpers.sh"

# Latest check-run wins. Sorting by `started_at` (id as the tiebreak for runs
# that share a second) is not cosmetic: reading an arbitrary array element here
# reproduces the exact misdiagnosis this script exists to prevent — a
# superseded red read as current state.
# Reads the newest check-run on $1 and reports FACTS about it, leaving the
# judgement to each caller -- the two arms ask different questions of the same
# record and a shared verdict-shaped answer cannot serve both:
#
#   {"state":"none"}   the head carries no diagnostic at all
#   {"state":<conclusion>, "id":…, "stage":…, "summary":…, "at":<epoch>}
#
# `at` is WHEN THE RUN'S EVALUATION HAPPENED, not when it was published: the
# embedded marker if present, else publication time. Concurrent triggers make
# those diverge, and publication order is the wrong clock for "is this newer
# evidence than my verdict".
#
# `stage` records which stage produced the record. An unmarked one (posted
# before the marker existed) reads as "full", the conservative default.
latest_run() {
  local head_sha="$1" runs
  # `--paginate` is not belt-and-braces next to per_page=100:
  # docs/agents/shared-operating-rules.md names this exact endpoint, and a head
  # that has been through repeated scheduled-sweep re-evaluations has been
  # observed carrying 194 check-runs (#687). An unpaginated read returns page 1
  # cleanly, with no error and no signal that more exist, so the newest run can
  # sit on page 2 and this function would confidently answer with a superseded
  # one. gh applies `--jq` per page, so the result is a STREAM of objects that
  # `jq -s` slurps whole before selecting.
  runs=$(with_gh_retry gh api --paginate \
    "repos/$REPO/commits/$head_sha/check-runs?check_name=$CHECK_NAME&per_page=100" \
    --jq '.check_runs[] | {conclusion, started_at, id, summary: (.output.summary // "")}') || return 1
  # `split` on a literal string, never a regex: both markers begin with "[",
  # which opens a character class the moment it is concatenated into a pattern.
  # That already broke this file once.
  jq -cs --arg marker "$STAGE_MARKER_PREFIX" --arg evmarker "$EVAL_MARKER_PREFIX" '
    def marked_epoch(s): (s | split($evmarker)) as $p
      | if ($p | length) > 1 then ($p[1] | split("]")[0] | tonumber? ) else null end;
    sort_by(.started_at, .id) | last
    | if . == null then {state: "none"}
      else {
        state: (.conclusion // "none"),
        id: .id,
        # The CURRENT marker is the first one: a cleared diagnostic carries the
        # superseded summary verbatim, so the text also contains the OLD marker
        # of that record. `contains` searches the whole string and would classify
        # a full-stage watermark as protective purely because it preserved a
        # protective diagnostic -- reading history as if it were current state.
        # (No apostrophes here: this comment sits inside a single-quoted jq
        # program, where one would close the shell string mid-expression.)
        stage: ((.summary | split($marker)) as $sp
                | if ($sp | length) > 1 and ($sp[1] | split("]")[0]) == "protective"
                  then "protective" else "full" end),
        summary: .summary,
        at: (marked_epoch(.summary) // (.started_at | fromdateiso8601))
      } end' <<<"$runs"
}

# Emits the summary of the newest FAILURE on $1 whose evaluation is strictly
# newer than $2, or nothing. Used only for the read-after-write check below.
failure_newer_than() {
  local head_sha="$1" cutoff="$2" runs
  runs=$(with_gh_retry gh api --paginate \
    "repos/$REPO/commits/$head_sha/check-runs?check_name=$CHECK_NAME&per_page=100" \
    --jq '.check_runs[] | {conclusion, started_at, id, summary: (.output.summary // "")}') || return 1
  jq -rs --argjson cutoff "$cutoff" --arg evmarker "$EVAL_MARKER_PREFIX" '
    def marked_epoch(s): (s | split($evmarker)) as $p
      | if ($p | length) > 1 then ($p[1] | split("]")[0] | tonumber? ) else null end;
    [ .[]
      | select(.conclusion == "failure")
      | select((marked_epoch(.summary) // (.started_at | fromdateiso8601)) > $cutoff) ]
    | sort_by(.started_at, .id) | last | .summary // ""' <<<"$runs"
}

# A verdict from stage $1 may speak for a record from stage $2. A full
# continuation subsumes the protective stage it runs after; a protective-only
# pass does not speak for the author-token continuation it never reached.
stage_covers() {
  case "$1:$2" in
    full:*) return 0 ;;
    protective:protective) return 0 ;;
    *) return 1 ;;
  esac
}

for ENTRY in $PR_NUMBERS; do
  PR="${ENTRY%%:*}"
  # Deliberately plain interpolation: bash 4 case-modification expansions abort
  # stock macOS bash 3.2 with "bad substitution" before either arm can post, and
  # check_auto_clear_workflow greps this file to keep them out. Naming the
  # operator here would match that grep, so it is described rather than written.
  echo "::group::approval-continuation ($MODE) for PR #$PR"

  if [ "$MODE" = clear ]; then
    # Clear mode takes PR:SHA:EPOCH:STAGE. Every field is load-bearing and a
    # wrong clear is the dangerous direction, so a malformed entry is refused
    # rather than defaulted.
    case "$ENTRY" in
      *:*:*:*) ;;
      *)
        echo "::warning::PR #$PR reached --clear without an evaluated head, timestamp and stage; refusing to guess."
        echo "::endgroup::"
        continue
        ;;
    esac
    ENTRY_REST="${ENTRY#*:}"
    EVAL_HEAD="${ENTRY_REST%%:*}"
    ENTRY_REST="${ENTRY_REST#*:}"
    EVAL_STARTED="${ENTRY_REST%%:*}"
    VERDICT_STAGE="${ENTRY_REST#*:}"
    case "$EVAL_STARTED" in
      ''|*[!0-9]*)
        echo "::warning::PR #$PR carries a non-numeric verdict timestamp ($EVAL_STARTED); refusing to clear."
        echo "::endgroup::"
        continue
        ;;
    esac
    case "$VERDICT_STAGE" in
      protective|full) ;;
      *)
        echo "::warning::PR #$PR carries an unknown verdict stage ($VERDICT_STAGE); refusing to clear."
        echo "::endgroup::"
        continue
        ;;
    esac
    if ! HEAD_SHA=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid); then
      echo "::warning::Failed to resolve head SHA for PR #$PR; the workflow log remains authoritative."
      echo "::endgroup::"
      continue
    fi
    # The verdict describes $EVAL_HEAD. Re-resolving the head at write time is
    # the whole defect: a push landing between the verdict and this step would
    # let a clean result for head A publish success on head B, superseding a
    # failure that belongs to B and was never evaluated. If the PR has moved,
    # this verdict says nothing about the current head — stop.
    #
    # $EVAL_HEAD is the head the CONTINUATION reported evaluating (#1190), not a
    # head read just before it started. Those differ when a PR moves A→B and is
    # force-reset back to A within one run: an equality check against a pre-read
    # would pass while the evaluation actually saw B, clearing a diagnostic on a
    # head nothing examined. The helper is the only component that knows which
    # head it pinned, so it is the only one that may say.
    if [ "$HEAD_SHA" != "$EVAL_HEAD" ]; then
      echo "PR #$PR moved from $EVAL_HEAD to $HEAD_SHA since this verdict; a later completion event will re-evaluate the new head."
      echo "::endgroup::"
      continue
    fi
    if ! SELECTED=$(latest_run "$EVAL_HEAD"); then
      echo "::warning::Failed to read existing $CHECK_NAME check-runs for PR #$PR; leaving the head untouched."
      echo "::endgroup::"
      continue
    fi
    SEL_STATE=$(jq -r '.state' <<<"$SELECTED")
    SEL_ID=$(jq -r '.id // 0' <<<"$SELECTED")
    SEL_STAGE=$(jq -r '.stage // "full"' <<<"$SELECTED")
    SEL_SUMMARY=$(jq -r '.summary // ""' <<<"$SELECTED")
    SEL_AT=$(jq -r '.at // 0' <<<"$SELECTED")

    # A record whose evaluation is at least as recent as this verdict is newer
    # evidence and must survive it, whatever it says.
    # Strictly-greater on BOTH sides, deliberately. The two comparisons used to
    # disagree on an exact tie -- clear refused a same-second failure (>=) while
    # report declined to suppress it (>) -- so two invocations starting in the
    # same second could leave a permanent red that neither side would resolve.
    # Consistency matters more than which way the tie falls: these are
    # infrastructure diagnostics, not merge-safety failures, and a condition
    # that persists is re-posted by the next evaluation.
    if [ "$SEL_STATE" != none ] && [ "${SEL_AT%.*}" -gt "$EVAL_STARTED" ]; then
      echo "PR #$PR has a $CHECK_NAME record newer than this verdict on $EVAL_HEAD; leaving it alone."
      echo "::endgroup::"
      continue
    fi

    WATERMARK_SUMMARY="PR #$PR completed an approval continuation on $EVAL_HEAD at the $VERDICT_STAGE stage with no infrastructure error. ${STAGE_MARKER_PREFIX}${VERDICT_STAGE}] ${EVAL_MARKER_PREFIX}${EVAL_STARTED}] Clearing run: $RUN_URL"

    # No diagnostic to supersede — record the clean verdict instead of writing
    # nothing (#1191). Without a durable record of "a clean evaluation happened
    # at T", an OLDER evaluation that fails and reaches its reporter after this
    # step has nothing to be judged against, so it publishes a stale failure
    # that no later event is guaranteed to clear. That is the #1188 bug by a
    # narrower route, and it is why this writes a watermark rather than
    # returning early. It creates at most ONE check-run per head: every later
    # clean verdict PATCHes this same run rather than adding another.
    if [ "$SEL_STATE" = none ]; then
      with_gh_retry gh api "repos/$REPO/check-runs" \
        -X POST \
        -f name="$CHECK_NAME" \
        -f "head_sha=$EVAL_HEAD" \
        -f status='completed' \
        -f conclusion='success' \
        -F "output[title]=Approval continuation completed without infrastructure error" \
        -F "output[summary]=$WATERMARK_SUMMARY" \
        || echo "::warning::Failed to record the clean-verdict watermark for PR #$PR; a late stale failure on $EVAL_HEAD would have nothing to be judged against."
      # Read-after-write. This POST makes our watermark the newest run on the
      # head, so a failure published between the read above and this write is
      # now hidden beneath it. Left alone that trades #1188's fail-CLOSED bug
      # for a fail-OPEN one -- a merge-blocking diagnostic silently removed --
      # which is the wrong direction and worse than the gap being closed. If a
      # failure newer than this verdict exists, restore the block by turning
      # our own watermark into it, carrying its evidence.
      if BURIED=$(failure_newer_than "$EVAL_HEAD" "$EVAL_STARTED"); then
        if [ -n "$BURIED" ]; then
          if ! WM=$(latest_run "$EVAL_HEAD"); then
            echo "::error::PR #$PR may have buried a newer failure on $EVAL_HEAD and the head could not be re-read; the workflow log is authoritative."
          else
            WM_ID=$(jq -r '.id // 0' <<<"$WM")
            case "$WM_ID" in
              ''|0|*[!0-9]*) echo "::error::PR #$PR may have buried a newer failure on $EVAL_HEAD; no usable run id to restore it." ;;
              *)
                echo "::warning::A failure newer than this verdict appeared on $EVAL_HEAD while the watermark was being written; restoring it."
                with_gh_retry gh api "repos/$REPO/check-runs/$WM_ID" \
                  -X PATCH \
                  -f conclusion='failure' \
                  -F "output[title]=Approval continuation hit an infrastructure error" \
                  -F "output[summary]=$BURIED" \
                  || echo "::error::Failed to restore the newer failure on $EVAL_HEAD after writing a watermark."
                ;;
            esac
          fi
        fi
      else
        echo "::warning::Could not re-read $EVAL_HEAD after writing the watermark; a concurrently-published failure may be hidden beneath it."
      fi
      echo "::endgroup::"
      continue
    fi

    case "$SEL_ID" in
      ''|0|*[!0-9]*)
        echo "::warning::PR #$PR has a $CHECK_NAME record on $EVAL_HEAD but no usable run id; leaving it untouched."
        echo "::endgroup::"
        continue
        ;;
    esac

    # Advance an existing watermark so later stale failures keep being rejected.
    if [ "$SEL_STATE" != failure ]; then
      if ! stage_covers "$VERDICT_STAGE" "$SEL_STAGE"; then
        echo "PR #$PR carries a $SEL_STAGE-stage record and this verdict only reached the $VERDICT_STAGE stage; leaving it as is."
      else
        # Carry any preserved history forward. Advancing a watermark used to
        # replace the summary outright, so the diagnostic evidence appended by
        # an earlier clear vanished on the next clean pass -- on a five-minute
        # scheduled sweep, within minutes. That silently undid the preservation
        # this script does when it clears.
        CARRIED=""
        case "$SEL_SUMMARY" in
          *"$PRESERVED_HEADING"*) CARRIED="
$PRESERVED_HEADING${SEL_SUMMARY#*"$PRESERVED_HEADING"}" ;;
        esac
        with_gh_retry gh api "repos/$REPO/check-runs/$SEL_ID" \
          -X PATCH \
          -f conclusion='success' \
          -F "output[title]=Approval continuation completed without infrastructure error" \
          -F "output[summary]=$WATERMARK_SUMMARY$CARRIED" \
          || echo "::warning::Failed to advance the clean-verdict watermark for PR #$PR."
      fi
      echo "::endgroup::"
      continue
    fi

    if ! stage_covers "$VERDICT_STAGE" "$SEL_STAGE"; then
      echo "PR #$PR has a $SEL_STAGE-stage diagnostic on $EVAL_HEAD and this verdict only reached the $VERDICT_STAGE stage; leaving it for a continuation that gets that far."
      echo "::endgroup::"
      continue
    fi
    # PATCH the run we actually selected, rather than POSTing a newer success.
    # Creating a run would re-enter the latest-run-wins race this script exists
    # to arbitrate: a failure published between the read above and the write
    # below would be the newest evidence, and a fresh success would bury it.
    # Updating run $SEL_ID cannot bury anything — a newer failure stays newer,
    # stays current, and keeps blocking. Both runs come from the same GitHub App
    # (this workflow's GITHUB_TOKEN), which is what permits the update.
    #
    # The superseded failure's own summary is carried into the replacement: this
    # is the only check-run record of that failure, so overwriting it outright
    # would erase the reason and the run URL an operator needs to chase a
    # recurring flake.
    with_gh_retry gh api "repos/$REPO/check-runs/$SEL_ID" \
      -X PATCH \
      -f conclusion='success' \
      -F "output[title]=Approval continuation completed without infrastructure error" \
      -F "output[summary]=$WATERMARK_SUMMARY

$PRESERVED_HEADING
$SEL_SUMMARY" \
      || { echo "::error::Failed to clear check-run $SEL_ID for PR #$PR; the stale diagnostic remains on $EVAL_HEAD."; CLEAR_WRITE_FAILED=1; }
    echo "::endgroup::"
    continue
  fi

  # Report mode takes PR, PR:STAGE or PR:STAGE:EPOCH. A missing stage defaults
  # to "full", the conservative reading: only a full verdict clears it. A
  # missing epoch omits the marker and disables the staleness check below.
  FAIL_STAGE=full
  FAIL_EPOCH=""
  REPORT_REST="${ENTRY#*:}"
  if [ "$REPORT_REST" != "$ENTRY" ]; then
    case "${REPORT_REST%%:*}" in
      protective|full) FAIL_STAGE="${REPORT_REST%%:*}" ;;
      *) echo "::warning::PR #$PR reported an unknown failure stage (${REPORT_REST%%:*}); recording it as full." ;;
    esac
    if [ "${REPORT_REST#*:}" != "$REPORT_REST" ]; then
      case "${REPORT_REST#*:}" in
        ''|*[!0-9]*) echo "::warning::PR #$PR reported a non-numeric evaluation epoch (${REPORT_REST#*:}); omitting it." ;;
        *) FAIL_EPOCH="${REPORT_REST#*:}" ;;
      esac
    fi
  fi
  EVAL_MARKER=""
  if [ -n "$FAIL_EPOCH" ]; then
    EVAL_MARKER=" ${EVAL_MARKER_PREFIX}${FAIL_EPOCH}]"
  fi
  if ! HEAD_SHA=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid); then
    echo "::warning::Failed to resolve head SHA for PR #$PR; the workflow log remains authoritative."
    echo "::endgroup::"
    continue
  fi

  # Do not publish a failure that a NEWER clean verdict has already spoken for
  # (#1191). Concurrent triggers let an older evaluation reach this point after
  # a newer clean one finished; without this check that stale failure lands and
  # no later event is guaranteed to clear it.
  #
  # Fails OPEN in every uncertain case — no epoch, an unreadable record, a
  # watermark from a stage that does not cover this failure — because
  # suppressing a real diagnostic is worse than publishing a redundant one.
  if [ -n "$FAIL_EPOCH" ]; then
    if EXISTING=$(latest_run "$HEAD_SHA"); then
      EX_STATE=$(jq -r '.state' <<<"$EXISTING")
      EX_AT=$(jq -r '.at // 0' <<<"$EXISTING")
      EX_STAGE=$(jq -r '.stage // "full"' <<<"$EXISTING")
      if [ "$EX_STATE" = success ] && [ "${EX_AT%.*}" -gt "$FAIL_EPOCH" ] && stage_covers "$EX_STAGE" "$FAIL_STAGE"; then
        echo "PR #$PR already has a clean $EX_STAGE-stage continuation on $HEAD_SHA newer than this evaluation; not publishing a superseded failure."
        echo "::endgroup::"
        continue
      fi
    else
      echo "::warning::Could not read existing $CHECK_NAME records for PR #$PR; publishing the diagnostic rather than suppressing it."
    fi
  fi

  with_gh_retry gh api "repos/$REPO/check-runs" \
    -X POST \
    -f name="$CHECK_NAME" \
    -f "head_sha=$HEAD_SHA" \
    -f status='completed' \
    -f conclusion='failure' \
    -F "output[title]=Approval continuation hit an infrastructure error" \
    -F "output[summary]=PR #$PR could not complete its final merge-safety evaluation. ${STAGE_MARKER_PREFIX}${FAIL_STAGE}]${EVAL_MARKER} See workflow run logs: $RUN_URL" \
    || echo "::warning::Failed to post the diagnostic check-run for PR #$PR; the workflow log still surfaces the failure."
  echo "::endgroup::"
done

# A clear that could not be written is not a success: the workflow must expose a
# retryable failed run rather than reporting green over a diagnostic that is
# still blocking the merge.
exit "$CLEAR_WRITE_FAILED"
