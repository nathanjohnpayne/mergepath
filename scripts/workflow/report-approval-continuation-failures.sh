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
# ─────────────────────────────────────────────────────────────────────
# The contract — exactly five guarantees, and one accepted residual
# ─────────────────────────────────────────────────────────────────────
#
#   1. A later clean evaluation can clear an existing diagnostic from the same
#      head and stage that PREDATES that evaluation.
#   2. A clear is PATCH-by-id, and therefore cannot supersede a failure it did
#      not observe.
#   3. The emitted head and stage accurately describe what that invocation
#      actually evaluated.
#   4. Failures to perform the clear surface as failures, never as silent
#      greens.
#   5. Arbitrary concurrent ordering may leave a false RED. That is explicitly
#      acceptable.
#
# Nothing here answers "which invocation was really newer?". That question
# requires a happens-before relation between concurrent workflow invocations,
# the Checks API offers no primitive for one -- no conditional write, no
# compare-and-swap, a single mutable text field per run -- and every attempt to
# encode one here closed one interleaving while opening another. Five such
# mechanisms were implemented and removed on this branch: an evaluation-epoch
# marker, a clean-verdict watermark, a read-after-write reconciliation for the
# burial race that watermark created, evaluation-order arbitration across every
# run on the head, and a per-stage epoch re-stamp. #1191 owns that requirement
# and treats the state/serialization substrate as the design problem.
#
# A reviewer can therefore be entirely CORRECT about a concurrent execution
# that leaves a stale red, and the right disposition is still "valid, #1191, no
# code change". Validity and scope are separate questions here. A false red
# costs a re-run; a false green removes a merge-blocking safety diagnostic.
#
# ─────────────────────────────────────────────────────────────────────
# Why the clear is narrow
# ─────────────────────────────────────────────────────────────────────
#
#   * Only this producer clears it. The caller runs `--clear` solely from the
#     continuation step's own clean-evaluation arm, so label-absence healing
#     (or any other unrelated path) still cannot convert a failure to success.
#   * It only ever supersedes a failure it can see. If the head carries no
#     `approval-merge-continuation` check-run, or its latest one is not a
#     failure, `--clear` writes nothing.
#   * It UPDATES the run it selected rather than creating a newer success.
#     Creating one would re-enter the latest-run-wins race: a failure published
#     between the read and the write would be the newest evidence, and a fresh
#     success would bury it. A PATCH does not move a run's publication
#     position, so it cannot outrank anything published after it.
#   * It only clears a record that PREDATES this invocation. A failure
#     published after this invocation began belongs to an evaluation this
#     verdict does not speak for. This is the fail-safe guard, not an ordering
#     scheme: it asks "was this already there when I started", which each
#     invocation can answer alone, rather than "which evaluation is newer",
#     which it cannot.
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
# `--clear` therefore takes `PR:SHA:START:STAGE`, not a bare PR number. The SHA
# is the head the CONTINUATION reported evaluating (#1190), not one read just
# before it started: a PR that moves A→B and is force-reset back to A within a
# single run would defeat an equality check against a pre-read while the
# evaluation actually saw B. The helper is the only component that knows which
# head it pinned, so it is the only one that may say.
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
# Heading under which a superseded diagnostic is preserved. That run is the only
# record of the failure, so a clear must not overwrite the reason and run URL an
# operator needs to chase a recurring flake.
PRESERVED_HEADING='Superseded diagnostic, preserved verbatim:'
# Set when any step of a clear fails -- a prerequisite READ as much as the final
# write. A failed clear leaves the merge-blocking diagnostic red while the
# workflow reports success, and on a consumer with scheduled_sweep_enabled:
# false nothing is guaranteed to retry it -- exactly the silently-preserved
# condition this script exists to heal, so it surfaces as a retryable failed run
# instead.
CLEAR_FAILED=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/gh-retry-helpers.sh
source "$ROOT/scripts/lib/gh-retry-helpers.sh"

# Reads the newest check-run on $1 and reports facts about it:
#
#   {"state":"none"}   the head carries no diagnostic at all
#   {"state":<conclusion>, "id":…, "stage":…, "summary":…, "published":<epoch>}
#
# "Newest" is publication order, which is what GitHub's own rollup gates on --
# so the selected run is the one actually blocking the merge. `published` is
# that run's own started_at, used only to ask whether it predates this
# invocation.
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
  jq -cs --arg marker "$STAGE_MARKER_PREFIX" '
    sort_by(.started_at, .id) | last
    | if . == null then {state: "none"}
      else {
        state: (.conclusion // "none"),
        id: .id,
        # `split`, never a regex: the marker begins with "[", which opens a
        # character class the moment it is concatenated into a pattern. The
        # FIRST occurrence is the current one -- a cleared record carries the
        # superseded summary verbatim and therefore holds the old marker too.
        stage: ((.summary | split($marker)) as $sp
                | if ($sp | length) > 1 and ($sp[1] | split("]")[0]) == "protective"
                  then "protective" else "full" end),
        summary: .summary,
        published: (.started_at | fromdateiso8601)
      } end' <<<"$runs"
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
    # PR:SHA:START:STAGE. Every field is load-bearing and a wrong clear is the
    # dangerous direction, so a malformed entry is refused rather than defaulted.
    case "$ENTRY" in
      *:*:*:*) ;;
      *)
        echo "::warning::PR #$PR reached --clear without an evaluated head, start time and stage; refusing to guess."
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
        echo "::warning::PR #$PR carries a non-numeric start time ($EVAL_STARTED); refusing to clear."
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
    # A prerequisite read that exhausts its retries is a FAILED clear, not a
    # skipped one: the stale diagnostic stays red and nothing is guaranteed to
    # retry it. Warning and exiting 0 would report success over exactly the
    # condition this script exists to heal.
    if ! HEAD_SHA=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid); then
      echo "::error::Failed to resolve head SHA for PR #$PR; the stale diagnostic on its head was not evaluated."
      CLEAR_FAILED=1
      echo "::endgroup::"
      continue
    fi
    if [ "$HEAD_SHA" != "$EVAL_HEAD" ]; then
      echo "PR #$PR moved from $EVAL_HEAD to $HEAD_SHA since this verdict; a later completion event will re-evaluate the new head."
      echo "::endgroup::"
      continue
    fi
    if ! SELECTED=$(latest_run "$EVAL_HEAD"); then
      echo "::error::Failed to read existing $CHECK_NAME check-runs for PR #$PR; any stale diagnostic on $EVAL_HEAD remains."
      CLEAR_FAILED=1
      echo "::endgroup::"
      continue
    fi
    SEL_STATE=$(jq -r '.state' <<<"$SELECTED")
    if [ "$SEL_STATE" != failure ]; then
      echo "PR #$PR carries no supersedable $CHECK_NAME diagnostic on $EVAL_HEAD (latest: $SEL_STATE); nothing to clear."
      echo "::endgroup::"
      continue
    fi
    SEL_ID=$(jq -r '.id // 0' <<<"$SELECTED")
    SEL_STAGE=$(jq -r '.stage // "full"' <<<"$SELECTED")
    SEL_SUMMARY=$(jq -r '.summary // ""' <<<"$SELECTED")
    SEL_PUBLISHED=$(jq -r '.published // 0' <<<"$SELECTED")
    case "$SEL_ID" in
      ''|0|*[!0-9]*)
        echo "::warning::PR #$PR has a failing $CHECK_NAME diagnostic on $EVAL_HEAD but no usable run id; leaving it untouched."
        echo "::endgroup::"
        continue
        ;;
    esac
    # The fail-safe guard. A record published at or after this invocation began
    # belongs to an evaluation this verdict does not speak for, so it is left
    # alone -- a stale red, which a later evaluation clears, in preference to a
    # false green, which nothing catches.
    if [ "${SEL_PUBLISHED%.*}" -ge "$EVAL_STARTED" ]; then
      echo "PR #$PR has a $CHECK_NAME diagnostic on $EVAL_HEAD published after this invocation began; leaving it for an evaluation that saw it."
      echo "::endgroup::"
      continue
    fi
    if ! stage_covers "$VERDICT_STAGE" "$SEL_STAGE"; then
      echo "PR #$PR has a $SEL_STAGE-stage diagnostic on $EVAL_HEAD and this verdict only reached the $VERDICT_STAGE stage; leaving it for a continuation that gets that far."
      echo "::endgroup::"
      continue
    fi
    with_gh_retry gh api "repos/$REPO/check-runs/$SEL_ID" \
      -X PATCH \
      -f conclusion='success' \
      -F "output[title]=Approval continuation completed without infrastructure error" \
      -F "output[summary]=PR #$PR was re-evaluated cleanly on $EVAL_HEAD at the $VERDICT_STAGE stage, superseding the $SEL_STAGE-stage infrastructure diagnostic this run originally recorded. Clearing run: $RUN_URL

$PRESERVED_HEADING
$SEL_SUMMARY" \
      || { echo "::error::Failed to clear check-run $SEL_ID for PR #$PR; the stale diagnostic remains on $EVAL_HEAD."; CLEAR_FAILED=1; }
    echo "::endgroup::"
    continue
  fi

  # Report mode takes PR or PR:STAGE. A missing stage defaults to "full", the
  # conservative reading: only a full verdict clears it.
  FAIL_STAGE=full
  REPORT_REST="${ENTRY#*:}"
  if [ "$REPORT_REST" != "$ENTRY" ]; then
    case "${REPORT_REST%%:*}" in
      protective|full) FAIL_STAGE="${REPORT_REST%%:*}" ;;
      *) echo "::warning::PR #$PR reported an unknown failure stage (${REPORT_REST%%:*}); recording it as full." ;;
    esac
  fi
  if ! HEAD_SHA=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid); then
    echo "::warning::Failed to resolve head SHA for PR #$PR; the workflow log remains authoritative."
    echo "::endgroup::"
    continue
  fi
  with_gh_retry gh api "repos/$REPO/check-runs" \
    -X POST \
    -f name="$CHECK_NAME" \
    -f "head_sha=$HEAD_SHA" \
    -f status='completed' \
    -f conclusion='failure' \
    -F "output[title]=Approval continuation hit an infrastructure error" \
    -F "output[summary]=PR #$PR could not complete its final merge-safety evaluation. ${STAGE_MARKER_PREFIX}${FAIL_STAGE}] See workflow run logs: $RUN_URL" \
    || echo "::warning::Failed to post the diagnostic check-run for PR #$PR; the workflow log still surfaces the failure."
  echo "::endgroup::"
done

# A clear that could not be completed is not a success -- whether it failed at a
# prerequisite read or at the write. The workflow must expose a retryable failed
# run rather than reporting green over a diagnostic that is still blocking the
# merge.
exit "$CLEAR_FAILED"
