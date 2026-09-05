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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/gh-retry-helpers.sh
source "$ROOT/scripts/lib/gh-retry-helpers.sh"

# Latest check-run wins. Sorting by `started_at` (id as the tiebreak for runs
# that share a second) is not cosmetic: reading an arbitrary array element here
# reproduces the exact misdiagnosis this script exists to prevent — a
# superseded red read as current state.
# Selects the newest diagnostic on $1, judged against a verdict taken at $2, and
# emits a compact JSON object describing it:
#
#   {"state":"none"}                 the head carries no diagnostic at all
#   {"state":"newer-than-verdict"}   the newest run started at or after the
#                                    verdict — newer evidence outranks it
#   {"state":<conclusion>, "id":…, "stage":…, "summary":…}
#
# `stage` records WHICH stage produced the diagnostic, read back from the marker
# the failure arm writes. An unmarked diagnostic (anything posted before this
# marker existed) is treated as "full", which is the conservative direction:
# only a full verdict can clear it.
latest_run() {
  local head_sha="$1" cutoff="$2" runs
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
  # fromdateiso8601 keeps the comparison inside jq: converting timestamps in
  # shell would need date(1), whose flags differ between GNU and BSD — the
  # portability trap this script was fixed for once already.
  jq -cs --argjson cutoff "$cutoff" --arg marker "$STAGE_MARKER_PREFIX" --arg evmarker "$EVAL_MARKER_PREFIX" '
    # `split` on a literal string, never a regex: both markers begin with "[",
    # which opens a character class the moment it is concatenated into a
    # pattern. A literal split needs no escaping and cannot drift.
    def marked_epoch(s): (s | split($evmarker)) as $p
      | if ($p | length) > 1 then ($p[1] | split("]")[0] | tonumber? ) else null end;
    sort_by(.started_at, .id) | last
    | if . == null then {state: "none"}
      elif ((marked_epoch(.summary) // (.started_at | fromdateiso8601)) >= $cutoff) then {state: "newer-than-verdict"}
      else {
        state: (.conclusion // "none"),
        id: .id,
        # `contains`, not `test`: the marker literal begins with "[", which
        # opens a character class when concatenated into a regex. A substring
        # test needs no escaping and cannot drift from the writer.
        stage: (if (.summary | contains($marker + "protective]")) then "protective" else "full" end),
        summary: .summary
      } end' <<<"$runs"
}

# A verdict from stage $1 may clear a diagnostic from stage $2. A full
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
    # The verdict describes $EVAL_HEAD. Re-resolving the head at POST time is
    # the whole defect: a push landing between the verdict and this step would
    # let a clean result for head A publish success on head B, superseding a
    # failure that belongs to B and was never evaluated. If the PR has moved,
    # this verdict says nothing about the current head — stop.
    #
    # KNOWN LIMIT (#1190): $EVAL_HEAD is the head read immediately BEFORE the
    # continuation ran, not a head the continuation itself reported. If a PR
    # moves A→B and is force-reset back to A within one run, this check passes
    # while the evaluation actually saw B. Closing it needs the helper to report
    # the SHA it pinned; deferred deliberately, see #1190.
    if [ "$HEAD_SHA" != "$EVAL_HEAD" ]; then
      echo "PR #$PR moved from $EVAL_HEAD to $HEAD_SHA since this verdict; a later completion event will re-evaluate the new head."
      echo "::endgroup::"
      continue
    fi
    if ! SELECTED=$(latest_run "$EVAL_HEAD" "$EVAL_STARTED"); then
      echo "::warning::Failed to read existing $CHECK_NAME check-runs for PR #$PR; leaving the head untouched."
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
    case "$SEL_ID" in
      ''|0|*[!0-9]*)
        echo "::warning::PR #$PR has a failing $CHECK_NAME diagnostic on $EVAL_HEAD but no usable run id; leaving it untouched."
        echo "::endgroup::"
        continue
        ;;
    esac
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
      -F "output[summary]=PR #$PR was re-evaluated cleanly on $EVAL_HEAD at the $VERDICT_STAGE stage, superseding the $SEL_STAGE-stage infrastructure diagnostic this run originally recorded. Clearing run: $RUN_URL

Superseded diagnostic, preserved verbatim:
$SEL_SUMMARY" \
      || echo "::warning::Failed to clear check-run $SEL_ID for PR #$PR; the stale diagnostic remains on $EVAL_HEAD."
    echo "::endgroup::"
    continue
  fi

  # Report mode takes PR, PR:STAGE or PR:STAGE:EPOCH. A missing stage defaults
  # to "full", the conservative reading: only a full verdict clears it. A
  # missing epoch simply omits the marker, leaving recency judged on
  # publication time as before.
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
