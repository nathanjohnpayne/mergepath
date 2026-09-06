#!/usr/bin/env bash
# Revalidate live approval independence at the final stable-readiness boundary.

set -euo pipefail

usage() {
  echo "usage: approval-independence-check.sh --repo owner/repo --pr <number> --head <sha> --base-ref <ref> --base-sha <sha> --merge-login <login>" >&2
  exit 3
}

REPO=""
PR_NUMBER=""
EXPECTED_HEAD=""
EXPECTED_BASE_REF=""
EXPECTED_BASE_SHA=""
MERGE_LOGIN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; PR_NUMBER="$2"; shift 2 ;;
    --head) [ "$#" -ge 2 ] || usage; EXPECTED_HEAD="$2"; shift 2 ;;
    --base-ref) [ "$#" -ge 2 ] || usage; EXPECTED_BASE_REF="$2"; shift 2 ;;
    --base-sha) [ "$#" -ge 2 ] || usage; EXPECTED_BASE_SHA="$2"; shift 2 ;;
    --merge-login) [ "$#" -ge 2 ] || usage; MERGE_LOGIN="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$REPO" ] && [ -n "$PR_NUMBER" ] && [ -n "$EXPECTED_HEAD" ] \
  && [ -n "$EXPECTED_BASE_REF" ] && [ -n "$EXPECTED_BASE_SHA" ] \
  && [ -n "$MERGE_LOGIN" ] || usage
case "$PR_NUMBER" in *[!0-9]*|'') usage ;; esac

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DETECTOR="$ROOT/scripts/self-approval-detector.cjs"
PHASE_4_QUERY="$ROOT/scripts/merge-clearance-gate.sh"
POLICY_RESOLVER="$ROOT/scripts/workflow/resolve_base_policy.sh"

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
[ -r "$DETECTOR" ] || infra_error "canonical self-approval detector is unavailable: $DETECTOR"
[ -x "$PHASE_4_QUERY" ] || infra_error "Phase 4 requiredness provider is unavailable: $PHASE_4_QUERY"
[ -x "$POLICY_RESOLVER" ] || infra_error "base-policy resolver is unavailable: $POLICY_RESOLVER"
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

# Bind Phase 4 requiredness to the exact head/base snapshot handed off by the
# continuation. The query resolves its governing policy from that same PR API
# object and fails closed if any pin has already moved.
phase_err=$(mktemp "${TMPDIR:-/tmp}/approval-independence-phase.XXXXXX") \
  || infra_error "could not allocate Phase 4 diagnostic capture"
set +e
phase4=$(MERGE_CLEARANCE_EXPECTED_HEAD_SHA="$EXPECTED_HEAD" \
  MERGE_CLEARANCE_EXPECTED_BASE_REF="$EXPECTED_BASE_REF" \
  MERGE_CLEARANCE_EXPECTED_BASE_SHA="$EXPECTED_BASE_SHA" \
  MERGE_CLEARANCE_MATERIALIZE_DEFAULT_POLICY=true \
  bash "$PHASE_4_QUERY" --derive-phase-4-requiredness "$PR_NUMBER" "$REPO" 2>"$phase_err")
phase_rc=$?
set -e
phase_msg=$(cat "$phase_err" 2>/dev/null || true)
rm -f "$phase_err"
[ "$phase_rc" -eq 0 ] || infra_error "Phase 4 requiredness was indeterminate (rc=$phase_rc): ${phase_msg:-no diagnostic}"
case "$phase4" in
  true|false) ;;
  *) infra_error "Phase 4 provider returned an invalid value: '$phase4'" ;;
esac

fetch_reviews() {
  gh_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews"
}

validate_reviews_shape() {
  local label="$1" value="$2"
  if ! jq -e '
    type == "array" and
    all(.[];
      type == "object" and
      (.id | type == "number" and . > 0 and floor == .) and
      (.user | type == "object") and
      (.user.login | type == "string" and length > 0) and
      (.state | type == "string") and
      (.state as $state |
        (["APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED","PENDING"] | index($state)) != null) and
      ((.commit_id == null) or (.commit_id | type == "string" and length > 0)) and
      ((.submitted_at == null) or
       (.submitted_at |
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
        (try (fromdateiso8601 | type == "number") catch false))) and
      (.state as $state |
       if (["APPROVED","CHANGES_REQUESTED","DISMISSED"] | index($state)) != null
       then (.commit_id | type == "string" and length > 0) and
            (.submitted_at | type == "string" and length > 0)
       else true end)
    ) and
    ((map(.id) | length) == (map(.id) | unique | length))
  ' >/dev/null 2>&1 <<<"$value"; then
    infra_error "$label review history has an invalid or incomplete safety shape"
  fi
}

fetch_pr() {
  local err rc body msg
  err=$(mktemp "${TMPDIR:-/tmp}/approval-independence-pr.XXXXXX") \
    || infra_error "could not allocate PR diagnostic capture"
  set +e
  body=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>"$err")
  rc=$?
  set -e
  msg=$(cat "$err" 2>/dev/null || true)
  rm -f "$err"
  [ "$rc" -eq 0 ] || infra_error "could not fetch live PR metadata: ${msg:-unknown API error}"
  printf '%s\n' "$body"
}

validate_pr_shape() {
  local value="$1"
  if ! jq -e '
    type == "object" and
    (.state | type == "string") and
    (.draft | type == "boolean") and
    (.head.sha | type == "string" and length > 0) and
    (.base.ref | type == "string" and length > 0) and
    (.base.sha | type == "string" and length > 0) and
    (.base.repo.default_branch | type == "string" and length > 0) and
    (.user.login | type == "string" and length > 0) and
    ((.body == null) or (.body | type == "string")) and
    (.labels | type == "array") and
    all(.labels[]; (.name | type == "string"))
  ' >/dev/null 2>&1 <<<"$value"; then
    infra_error "live PR metadata has an invalid or incomplete safety shape"
  fi
}

validate_pr_state() {
  local value="$1" state draft head base_ref base_sha blocking
  state=$(jq -r '.state' <<<"$value")
  draft=$(jq -r '.draft' <<<"$value")
  head=$(jq -r '.head.sha' <<<"$value")
  base_ref=$(jq -r '.base.ref' <<<"$value")
  base_sha=$(jq -r '.base.sha' <<<"$value")
  [ "$state" = "open" ] || [ "$state" = "OPEN" ] || not_ready "PR changed state to $state"
  [ "$draft" = "false" ] || not_ready "PR is draft"
  [ "$head" = "$EXPECTED_HEAD" ] || not_ready "head changed from $EXPECTED_HEAD to $head during evaluation"
  [ "$base_ref" = "$EXPECTED_BASE_REF" ] || not_ready "base ref changed from $EXPECTED_BASE_REF to $base_ref during evaluation"
  [ "$base_sha" = "$EXPECTED_BASE_SHA" ] || not_ready "base sha changed from $EXPECTED_BASE_SHA to $base_sha during evaluation"
  blocking=$(jq -r '.labels[].name' <<<"$value" | mergepath_blocking_labels_csv)
  [ -z "$blocking" ] || not_ready "blocking labels appeared during evaluation: $blocking"
}

pr_signature() {
  jq -c '{state, draft, head: .head.sha, baseRef: .base.ref,
    baseSha: .base.sha, defaultBranch: .base.repo.default_branch,
    author: .user.login, body: (.body // ""), labels: (.labels | map(.name) | sort)}' <<<"$1"
}

# Bracket the mutable review history with two complete reads and finish each
# bracket with live PR metadata. A review transition during the evaluation
# defers; COMMENTED-only noise is ignored later by comparing the detector's
# latest opinionated approval summaries. The last remote read is PR metadata,
# so a concurrent body/base/label change is also observed.
set +e
reviews_before=$(fetch_reviews)
reviews_before_rc=$?
set -e
[ "$reviews_before_rc" -eq 0 ] || infra_error "failed to fetch the first complete review snapshot"
validate_reviews_shape "first" "$reviews_before"

pr_before=$(fetch_pr)
validate_pr_shape "$pr_before"
validate_pr_state "$pr_before"
default_branch=$(jq -r '.base.repo.default_branch' <<<"$pr_before")

policy_err=$(mktemp "${TMPDIR:-/tmp}/approval-independence-policy.XXXXXX") \
  || infra_error "could not allocate policy diagnostic capture"
set +e
policy=$(bash "$POLICY_RESOLVER" --repo "$REPO" \
  --base-ref "$EXPECTED_BASE_REF" --base-sha "$EXPECTED_BASE_SHA" \
  --default-branch "$default_branch" --materialize-default 2>"$policy_err")
policy_rc=$?
set -e
policy_msg=$(cat "$policy_err" 2>/dev/null || true)
rm -f "$policy_err"
[ "$policy_rc" -eq 0 ] && [ -r "$policy" ] \
  || infra_error "could not materialize the pinned governing policy: ${policy_msg:-no diagnostic}"
trap 'rm -f "$policy"' EXIT

reviewers=$(read_available_reviewers "$policy")
[ -n "$reviewers" ] || infra_error "governing policy names no available_reviewers"
author_identity=$(review_policy_scalar "$policy" author_identity)
[ -n "$author_identity" ] || infra_error "governing policy names no author_identity"
[ "$MERGE_LOGIN" = "$author_identity" ] \
  || infra_error "merge token resolves to $MERGE_LOGIN, but pinned base policy requires $author_identity"
reviewers_json=$(printf '%s\n' "$reviewers" | jq -R -s -c 'split("\n") | map(select(length > 0))') \
  || infra_error "could not encode available_reviewers"

set +e
reviews_after=$(fetch_reviews)
reviews_after_rc=$?
set -e
[ "$reviews_after_rc" -eq 0 ] || infra_error "failed to fetch the second complete review snapshot"
validate_reviews_shape "second" "$reviews_after"

pr_after=$(fetch_pr)
validate_pr_shape "$pr_after"
validate_pr_state "$pr_after"
[ "$(pr_signature "$pr_before")" = "$(pr_signature "$pr_after")" ] \
  || not_ready "mutable PR metadata changed during approval evaluation"

pr_author=$(jq -r '.user.login' <<<"$pr_after")
pr_body=$(jq -r '.body // ""' <<<"$pr_after")
input=$(jq -n -c \
  --arg prAuthor "$pr_author" \
  --arg authorIdentity "$author_identity" \
  --arg prBody "$pr_body" \
  --arg headSha "$EXPECTED_HEAD" \
  --argjson reviewerAccounts "$reviewers_json" \
  --argjson requiresExternalReview "$phase4" \
  '{prAuthor:$prAuthor, authorIdentity:$authorIdentity, prBody:$prBody,
    headSha:$headSha, requireHead:true, reviewerAccounts:$reviewerAccounts,
    requiresExternalReview:$requiresExternalReview}') \
  || infra_error "could not construct detector input"

payload=$(jq -n -c --argjson input "$input" \
  --argjson before "$reviews_before" --argjson after "$reviews_after" \
  '{input:$input, before:$before, after:$after}') \
  || infra_error "could not construct detector payload"

evaluation_err=$(mktemp "${TMPDIR:-/tmp}/approval-independence-detector.XXXXXX") \
  || infra_error "could not allocate detector diagnostic capture"
set +e
evaluation=$(printf '%s' "$payload" | node -e '
  const fs = require("fs");
  const detector = require(process.argv[1]);
  const payload = JSON.parse(fs.readFileSync(0, "utf8"));
  if (typeof detector.evaluateLatestApprovals !== "function") {
    throw new Error("evaluateLatestApprovals export is unavailable");
  }
  const before = detector.evaluateLatestApprovals({...payload.input, reviews: payload.before});
  const after = detector.evaluateLatestApprovals({...payload.input, reviews: payload.after});
  const normalized = value => String(value || "").trim().toLowerCase();
  process.stdout.write(JSON.stringify({
    stable: JSON.stringify(before.opinionatedReviews) === JSON.stringify(after.opinionatedReviews),
    sharedAuthor: normalized(payload.input.prAuthor) === normalized(payload.input.authorIdentity),
    requiresExternalReview: payload.input.requiresExternalReview,
    before,
    after,
  }));
' "$DETECTOR" 2>"$evaluation_err")
evaluation_rc=$?
set -e
evaluation_msg=$(cat "$evaluation_err" 2>/dev/null || true)
rm -f "$evaluation_err"
[ "$evaluation_rc" -eq 0 ] \
  || infra_error "canonical detector failed: ${evaluation_msg:-no diagnostic}"
if ! jq -e '
  type == "object" and (.stable | type == "boolean") and
  (.sharedAuthor | type == "boolean") and
  (.requiresExternalReview | type == "boolean") and
  (.after.eligibleApproval | type == "boolean") and
  (.after.independentApproval | type == "boolean") and
  (.after.blockingApprovals | type == "array") and
  (.after.approvals | type == "array") and
  (.after.opinionatedReviews | type == "array")
' >/dev/null 2>&1 <<<"$evaluation"; then
  infra_error "canonical detector returned an invalid result${evaluation_msg:+: $evaluation_msg}"
fi

printf '%s\n' "$evaluation"
[ "$(jq -r '.stable' <<<"$evaluation")" = "true" ] \
  || not_ready "latest opinionated review state changed during evaluation"
[ "$(jq -r '.after.blockingApprovals | length' <<<"$evaluation")" -eq 0 ] \
  || not_ready "a standing disallowed approval remains in GitHub's native approval set"
[ "$(jq -r '.after.eligibleApproval' <<<"$evaluation")" = "true" ] \
  || not_ready "no independent latest-state registered approval exists on $EXPECTED_HEAD"
