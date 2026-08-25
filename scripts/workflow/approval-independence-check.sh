#!/usr/bin/env bash
# Revalidate live approval independence immediately before a merge write.

set -euo pipefail

usage() {
  echo "usage: approval-independence-check.sh --repo owner/repo --pr <number> --head <sha> --policy <path>" >&2
  exit 3
}

REPO=""
PR_NUMBER=""
EXPECTED_HEAD=""
POLICY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; PR_NUMBER="$2"; shift 2 ;;
    --head) [ "$#" -ge 2 ] || usage; EXPECTED_HEAD="$2"; shift 2 ;;
    --policy) [ "$#" -ge 2 ] || usage; POLICY="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$REPO" ] && [ -n "$PR_NUMBER" ] && [ -n "$EXPECTED_HEAD" ] && [ -n "$POLICY" ] || usage
case "$PR_NUMBER" in *[!0-9]*|'') usage ;; esac

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DETECTOR="$ROOT/scripts/self-approval-detector.cjs"
PHASE_4_QUERY="$ROOT/scripts/merge-clearance-gate.sh"

infra_error() {
  echo "approval independence: ERROR — $*" >&2
  exit 3
}

not_ready() {
  echo "approval independence: not ready — $*" >&2
  exit 1
}

for tool in gh jq node; do
  command -v "$tool" >/dev/null 2>&1 || infra_error "required tool '$tool' is unavailable"
done
[ -r "$POLICY" ] || infra_error "governing policy is unreadable: $POLICY"
[ -r "$DETECTOR" ] || infra_error "canonical self-approval detector is unavailable: $DETECTOR"
[ -x "$PHASE_4_QUERY" ] || infra_error "Phase 4 requiredness provider is unavailable: $PHASE_4_QUERY"
[ -r "$ROOT/scripts/lib/gh-api-array.sh" ] || infra_error "paginated API reader is unavailable"
[ -r "$ROOT/scripts/lib/reviewers-helpers.sh" ] || infra_error "reviewer policy reader is unavailable"
[ -r "$ROOT/scripts/lib/review-policy-scalar.sh" ] || infra_error "review-policy scalar reader is unavailable"
[ -r "$ROOT/scripts/lib/blocking-labels.sh" ] || infra_error "blocking-label policy is unavailable"

# shellcheck source=../lib/gh-api-array.sh
. "$ROOT/scripts/lib/gh-api-array.sh"
# shellcheck source=../lib/reviewers-helpers.sh
. "$ROOT/scripts/lib/reviewers-helpers.sh"
# shellcheck source=../lib/review-policy-scalar.sh
. "$ROOT/scripts/lib/review-policy-scalar.sh"
# shellcheck source=../lib/blocking-labels.sh
. "$ROOT/scripts/lib/blocking-labels.sh"

reviewers=$(read_available_reviewers "$POLICY")
[ -n "$reviewers" ] || infra_error "governing policy names no available_reviewers"
author_identity=$(review_policy_scalar "$POLICY" author_identity)
[ -n "$author_identity" ] || infra_error "governing policy names no author_identity"
reviewers_json=$(printf '%s\n' "$reviewers" | jq -R -s -c 'split("\n") | map(select(length > 0))') \
  || infra_error "could not encode available_reviewers"

phase_err=$(mktemp "${TMPDIR:-/tmp}/approval-independence-phase.XXXXXX") \
  || infra_error "could not allocate Phase 4 diagnostic capture"
set +e
phase4=$(bash "$PHASE_4_QUERY" --derive-phase-4-requiredness "$PR_NUMBER" "$REPO" 2>"$phase_err")
phase_rc=$?
set -e
phase_msg=$(cat "$phase_err" 2>/dev/null || true)
rm -f "$phase_err"
[ "$phase_rc" -eq 0 ] || infra_error "Phase 4 requiredness was indeterminate (rc=$phase_rc): ${phase_msg:-no diagnostic}"
case "$phase4" in
  true|false) ;;
  *) infra_error "Phase 4 provider returned an invalid value: '$phase4'" ;;
esac

# Fetch the complete current approval history before the LAST mutable PR read.
# If body/state/labels change while pagination is in flight, the final metadata
# read below sees that change instead of evaluating the earlier webhook body.
fetch_reviews() {
  gh_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews" || return $?
}
set +e
reviews=$(fetch_reviews)
reviews_rc=$?
set -e
[ "$reviews_rc" -eq 0 ] || infra_error "${GH_API_ARRAY_ERROR:-failed to fetch reviews}"

set +e
pr_json=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1)
pr_rc=$?
set -e
[ "$pr_rc" -eq 0 ] || infra_error "could not fetch live PR metadata: $pr_json"
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$pr_json"; then
  infra_error "live PR metadata was not a JSON object"
fi
live_state=$(jq -r '.state // ""' <<<"$pr_json")
live_draft=$(jq -r 'if has("draft") then .draft elif has("isDraft") then .isDraft else "" end' <<<"$pr_json")
live_head=$(jq -r '.head.sha // ""' <<<"$pr_json")
pr_author=$(jq -r '.user.login // ""' <<<"$pr_json")
pr_body=$(jq -r '.body // ""' <<<"$pr_json")
[ "$live_state" = "open" ] || [ "$live_state" = "OPEN" ] || not_ready "PR changed state to ${live_state:-unknown}"
[ "$live_draft" = "false" ] || not_ready "PR is draft or draft state is indeterminate"
[ -n "$live_head" ] || infra_error "live PR metadata lacks head.sha"
[ -n "$pr_author" ] || infra_error "live PR metadata lacks user.login"
[ "$live_head" = "$EXPECTED_HEAD" ] || not_ready "head changed from $EXPECTED_HEAD to $live_head during evaluation"
blocking_labels=$(jq -r '.labels[]?.name' <<<"$pr_json" | mergepath_blocking_labels_csv)
[ -z "$blocking_labels" ] || not_ready "blocking labels appeared during evaluation: $blocking_labels"

input=$(jq -n -c \
  --arg prAuthor "$pr_author" \
  --arg authorIdentity "$author_identity" \
  --arg prBody "$pr_body" \
  --arg headSha "$live_head" \
  --argjson reviewerAccounts "$reviewers_json" \
  --argjson reviews "$reviews" \
  --argjson requiresExternalReview "$phase4" \
  '{prAuthor:$prAuthor, authorIdentity:$authorIdentity, prBody:$prBody,
    headSha:$headSha, requireHead:true, reviewerAccounts:$reviewerAccounts,
    reviews:$reviews, requiresExternalReview:$requiresExternalReview}') \
  || infra_error "could not construct detector input"

set +e
evaluation=$(printf '%s' "$input" | node -e '
  const fs = require("fs");
  const detector = require(process.argv[1]);
  const input = JSON.parse(fs.readFileSync(0, "utf8"));
  if (typeof detector.evaluateLatestApprovals !== "function") {
    throw new Error("evaluateLatestApprovals export is unavailable");
  }
  process.stdout.write(JSON.stringify(detector.evaluateLatestApprovals(input)));
' "$DETECTOR" 2>&1)
evaluation_rc=$?
set -e
[ "$evaluation_rc" -eq 0 ] || infra_error "canonical detector failed: $evaluation"
if ! jq -e 'type == "object" and (.eligibleApproval | type == "boolean") and (.approvals | type == "array")' >/dev/null 2>&1 <<<"$evaluation"; then
  infra_error "canonical detector returned an invalid result"
fi

printf '%s\n' "$evaluation"
if [ "$(jq -r '.eligibleApproval' <<<"$evaluation")" != "true" ]; then
  not_ready "no independent latest-state registered approval exists on $live_head"
fi
