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
#     failure, `--clear` posts nothing. Without that guard every approved PR
#     fleet-wide would grow a fresh check-run on every qualifying event.
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/gh-retry-helpers.sh
source "$ROOT/scripts/lib/gh-retry-helpers.sh"

# Latest check-run wins. Sorting by `started_at` (id as the tiebreak for runs
# that share a second) is not cosmetic: reading an arbitrary array element here
# reproduces the exact misdiagnosis this script exists to prevent — a
# superseded red read as current state.
latest_conclusion() {
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
    --jq '.check_runs[] | {conclusion, started_at, id}') || return 1
  jq -rs 'sort_by(.started_at, .id) | last | .conclusion // "none"' <<<"$runs"
}

for PR in $PR_NUMBERS; do
  # Deliberately plain interpolation: bash 4 case-modification expansions abort
  # stock macOS bash 3.2 with "bad substitution" before either arm can post, and
  # check_auto_clear_workflow greps this file to keep them out. Naming the
  # operator here would match that grep, so it is described rather than written.
  echo "::group::approval-continuation ($MODE) for PR #$PR"
  if ! HEAD_SHA=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid); then
    echo "::warning::Failed to resolve head SHA for PR #$PR; the workflow log remains authoritative."
    echo "::endgroup::"
    continue
  fi

  if [ "$MODE" = clear ]; then
    if ! CURRENT=$(latest_conclusion "$HEAD_SHA"); then
      echo "::warning::Failed to read existing $CHECK_NAME check-runs for PR #$PR; leaving the head untouched."
      echo "::endgroup::"
      continue
    fi
    if [ "$CURRENT" != failure ]; then
      echo "PR #$PR carries no failing $CHECK_NAME diagnostic on $HEAD_SHA (latest: $CURRENT); nothing to clear."
      echo "::endgroup::"
      continue
    fi
    with_gh_retry gh api "repos/$REPO/check-runs" \
      -X POST \
      -f name="$CHECK_NAME" \
      -f "head_sha=$HEAD_SHA" \
      -f status='completed' \
      -f conclusion='success' \
      -F "output[title]=Approval continuation completed without infrastructure error" \
      -F "output[summary]=PR #$PR was re-evaluated cleanly, superseding an earlier infrastructure diagnostic on this head. See workflow run logs: $RUN_URL" \
      || echo "::warning::Failed to post the clearing check-run for PR #$PR; the stale diagnostic remains on $HEAD_SHA."
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
    -F "output[summary]=PR #$PR could not complete its final merge-safety evaluation. See workflow run logs: $RUN_URL" \
    || echo "::warning::Failed to post the diagnostic check-run for PR #$PR; the workflow log still surfaces the failure."
  echo "::endgroup::"
done
