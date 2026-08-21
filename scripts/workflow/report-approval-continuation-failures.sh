#!/usr/bin/env bash
# Publish head-pinned diagnostics for approval-continuation infrastructure
# failures. These are distinct from label-removal failures: an approved PR can
# legitimately have no needs-external-review label, so label-absence healing
# must never convert a continuation failure into a successful check-run.

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
    -f conclusion='failure' \
    -F "output[title]=Approval continuation hit an infrastructure error" \
    -F "output[summary]=PR #$PR could not complete its final merge-safety evaluation. See workflow run logs: $RUN_URL" \
    || echo "::warning::Failed to post the diagnostic check-run for PR #$PR; the workflow log still surfaces the failure."
  echo "::endgroup::"
done
