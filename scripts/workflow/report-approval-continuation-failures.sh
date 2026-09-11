#!/usr/bin/env bash
# Publish head-pinned diagnostics for approval-continuation infrastructure
# failures. These are distinct from label-removal failures: an approved PR can
# legitimately have no needs-external-review label, so label-absence healing
# must never convert a continuation failure into a successful check-run.
#
# ─────────────────────────────────────────────────────────────────────
# Why `neutral` and not `failure` (#1188)
# ─────────────────────────────────────────────────────────────────────
#
# This check-run is a DIAGNOSTIC, not a gate. `approval-merge-continuation` is
# not a required status check on the hub or on any consumer, so GitHub never
# blocked a merge on it. What a `failure` conclusion did was drive
# `mergeStateStatus` to UNSTABLE, which made scripts/hooks/gh-pr-guard.sh demand
# a break-glass merge -- for a PR where every required context was green and
# nothing was actually wrong. That is the reflex #962 argues must not be
# trained.
#
# And it never healed. This script only ever posted `failure`; nothing anywhere
# posted a success for this name, so a head that hit one transient
# infrastructure error carried a red check-run permanently. A later success of
# the very continuation being reported on published nothing. Observed on
# nathanjohnpayne/fiveacross#1108, whose failing run was re-run to success while
# the check-run did not move; it took a re-cut of the whole propagation PR to
# escape.
#
# `neutral` keeps the diagnostic exactly as visible -- same name, same head,
# same summary, same run URL -- while removing the stranding. Nothing has to
# clear it, so there is no clearing path to get right.
#
# LOAD-BEARING ASSUMPTION, stated because the whole change rests on it: GitHub
# treats `neutral` as non-blocking. Its documented rule for required checks is
# that a "successful, skipped, or neutral conclusion" satisfies them, and this
# repo has direct evidence for the `skipped` half of that sentence -- a head
# carrying 46 skipped runs reached CLEAN and merged (fiveacross#1110). No
# `neutral` run exists anywhere in the fleet to sample directly, and the Checks
# API refuses classic PATs, so one could not be created to test. If the
# assumption is wrong the result is a head that stays UNSTABLE -- exactly
# today's behaviour, no worse -- and the fix is to revert this one word.
#
# The alternative was a clear arm that transitions the diagnostic back to green.
# That was built and abandoned (#1189): making a clear safe under concurrent
# invocations needs a happens-before relation the Checks API cannot express, and
# five successive mechanisms for it each closed one interleaving while opening
# another. Removing the state transition removes that entire problem rather than
# managing it.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: report-approval-continuation-failures.sh <owner/repo> <run-url> <space-separated-pr-numbers>" >&2
  exit 2
fi

REPO="$1"
RUN_URL="$2"
PR_NUMBERS="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/gh-retry-helpers.sh
source "$ROOT/scripts/lib/gh-retry-helpers.sh"

for PR in $PR_NUMBERS; do
  echo "::group::Posting approval-continuation failure for PR #$PR"
  if ! HEAD_SHA=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid); then
    echo "::warning::Failed to resolve head SHA for PR #$PR; the workflow log remains authoritative."
    echo "::endgroup::"
    continue
  fi
  with_gh_retry gh api "repos/$REPO/check-runs" \
    -X POST \
    -f name='approval-merge-continuation' \
    -f "head_sha=$HEAD_SHA" \
    -f status='completed' \
    -f conclusion='neutral' \
    -F "output[title]=Approval continuation hit an infrastructure error" \
    -F "output[summary]=PR #$PR could not complete its final merge-safety evaluation. See workflow run logs: $RUN_URL" \
    || echo "::warning::Failed to post the diagnostic check-run for PR #$PR; the workflow log still surfaces the failure."
  echo "::endgroup::"
done
