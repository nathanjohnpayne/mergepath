#!/usr/bin/env bash
# Decide whether #1099 cleanup may leave one native auto-merge arm intact.

set -euo pipefail

usage() {
  echo "usage: merge-queue-arm-policy.sh <PR#> [owner/repo]" >&2
  exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
PR_NUMBER="$1"
REPO="${2:-${GITHUB_REPOSITORY:-}}"
case "$PR_NUMBER" in *[!0-9]*|'') usage ;; esac
case "$REPO" in */*) ;; *) usage ;; esac

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

inactive() {
  echo "merge-queue-arm-policy: inactive — $*"
  exit 4
}

not_eligible() {
  echo "merge-queue-arm-policy: not eligible — $*" >&2
  exit 5
}

infra() {
  echo "merge-queue-arm-policy: ERROR — $*" >&2
  exit 3
}

[ -r "$ROOT/scripts/lib/merge-queue-protection.sh" ] || infra "queue protection policy is unavailable"
[ -r "$ROOT/scripts/lib/review-policy-scalar.sh" ] || infra "review-policy reader is unavailable"
for tool in gh jq git; do
  command -v "$tool" >/dev/null 2>&1 || infra "required tool '$tool' is unavailable"
done
[ -n "${GH_TOKEN:-}" ] || infra "GH_TOKEN is required to bind the live PR base"
[ -n "${MERGEPATH_AUTHOR_TOKEN:-}" ] \
  || infra "MERGEPATH_AUTHOR_TOKEN is required to bind the author credential"
[ -n "${MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN:-}" ] \
  || infra "MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN is required to bind the policy source"
[ "$GH_TOKEN" != "$MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN" ] \
  || infra "queue-policy and queue-source credentials must be value-distinct"
[ "$MERGEPATH_AUTHOR_TOKEN" != "$GH_TOKEN" ] \
  && [ "$MERGEPATH_AUTHOR_TOKEN" != "$MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN" ] \
  || infra "author, queue-policy, and queue-source credentials must be pairwise value-distinct"
# shellcheck source=../lib/merge-queue-protection.sh
. "$ROOT/scripts/lib/merge-queue-protection.sh"
# shellcheck source=../lib/review-policy-scalar.sh
. "$ROOT/scripts/lib/review-policy-scalar.sh"

# Even disabled/future trusted code must bind cleanup to its own base before
# returning permission for the legacy disable path. Otherwise an in-flight old
# run can disable a newer arm after main activates the queue rollout.
CHECKOUT_SHA=$(git rev-parse HEAD 2>/dev/null) || infra "could not identify trusted checkout"
LIVE_BASE_SHA=$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .base.sha) \
  || infra "could not bind the live PR base"
printf '%s' "$LIVE_BASE_SHA" \
  | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' \
  || infra "live PR base is malformed"
[ "$CHECKOUT_SHA" = "$LIVE_BASE_SHA" ] \
  || not_eligible "trusted cleanup base is stale"

ROLLOUT_CONFIG=$(mergepath_merge_queue_rollout_config \
  "$ROOT/.github/review-policy.yml") \
  || infra "merge-queue rollout configuration is malformed"
ROLLOUT_NOW=${MERGEPATH_MERGE_QUEUE_NOW:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')} \
  || infra "could not read rollout clock"
set +e
mergepath_merge_queue_rollout_is_active "$ROLLOUT_CONFIG" "$ROLLOUT_NOW"
active_rc=$?
set -e
case "$active_rc" in
  0) ;;
  4) inactive "merge-queue rollout is disabled" ;;
  5) not_eligible "scheduled merge-queue rollout forbids mutation across activation" ;;
  *) infra "could not evaluate merge-queue rollout activation" ;;
esac

[ -r "$ROOT/scripts/lib/gh-api-array.sh" ] || infra "paginated API helper is unavailable"
[ -r "$ROOT/scripts/lib/blocking-labels.sh" ] || infra "blocking-label policy is unavailable"
[ -r "$ROOT/scripts/lib/merge-queue-authorization.sh" ] \
  || infra "queue authorization policy is unavailable"
# shellcheck source=../lib/gh-api-array.sh
. "$ROOT/scripts/lib/gh-api-array.sh"
# shellcheck source=../lib/blocking-labels.sh
. "$ROOT/scripts/lib/blocking-labels.sh"
# shellcheck source=../lib/merge-queue-authorization.sh
. "$ROOT/scripts/lib/merge-queue-authorization.sh"

AUTHOR_IDENTITY=$(review_policy_scalar "$ROOT/.github/review-policy.yml" author_identity)
[ -n "$AUTHOR_IDENTITY" ] || infra "governing policy names no author_identity"
TOKEN_LOGIN=$(gh api user --jq .login) || infra "could not verify queue-policy token"
[ "$TOKEN_LOGIN" = "$AUTHOR_IDENTITY" ] \
  || infra "queue-policy token identity '$TOKEN_LOGIN' is not '$AUTHOR_IDENTITY'"
AUTHOR_TOKEN_LOGIN=$(GH_TOKEN="$MERGEPATH_AUTHOR_TOKEN" gh api user --jq .login) \
  || infra "could not verify author token"
[ "$AUTHOR_TOKEN_LOGIN" = "$AUTHOR_IDENTITY" ] \
  || infra "author token identity '$AUTHOR_TOKEN_LOGIN' is not '$AUTHOR_IDENTITY'"
SOURCE_TOKEN_LOGIN=$(GH_TOKEN="$MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN" \
  gh api user --jq .login) || infra "could not verify queue-source token"
[ "$SOURCE_TOKEN_LOGIN" = "$AUTHOR_IDENTITY" ] \
  || infra "queue-source token identity '$SOURCE_TOKEN_LOGIN' is not '$AUTHOR_IDENTITY'"

REPO_OWNER=${REPO%%/*}
REPO_NAME=${REPO#*/}
case "$REPO_OWNER:$REPO_NAME" in :*|*:|*:*/*) usage ;; esac
# shellcheck disable=SC2016 # GraphQL variables are intentionally literal.
PR_QUERY='query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    nameWithOwner
    pullRequest(number:$number){
      state isDraft createdAt headRefOid baseRefName baseRefOid
      headRepository{nameWithOwner}
      baseRepository{nameWithOwner defaultBranchRef{name}}
      author{login}
      autoMergeRequest{enabledAt enabledBy{login} mergeMethod}
    }
  }
}'
read_arm_snapshot() {
  local raw pr labels
  raw=$(gh api graphql -f query="$PR_QUERY" -f owner="$REPO_OWNER" \
    -f name="$REPO_NAME" -F number="$PR_NUMBER") || return 1
  pr=$(printf '%s' "$raw" | jq -ce '
    select(((.errors // []) | length) == 0) |
    .data.repository as $repo |
    $repo.pullRequest as $pr |
    select($repo != null and $pr != null) |
    {
      repository:$repo.nameWithOwner,state:$pr.state,draft:$pr.isDraft,
      created_at:$pr.createdAt,
      head:$pr.headRefOid,head_repository:$pr.headRepository.nameWithOwner,
      base_ref:$pr.baseRefName,base_sha:$pr.baseRefOid,
      base_repository:$pr.baseRepository.nameWithOwner,
      default_branch:$pr.baseRepository.defaultBranchRef.name,
      author:$pr.author.login,auto_merge:$pr.autoMergeRequest
    }
  ') || return 1
  labels=$(gh_api_array "repos/$REPO/issues/$PR_NUMBER/labels?per_page=100" \
    "PR labels") || {
      echo "$GH_API_ARRAY_ERROR" >&2
      return 1
    }
  jq -cn --argjson pr "$pr" --argjson labels "$labels" \
    '$pr + {labels:([$labels[].name] | sort)}'
}

validate_arm_snapshot() {
  printf '%s' "$1" | jq -e \
  --arg repo "$REPO" --arg author "$AUTHOR_IDENTITY" \
  --arg activated "$(printf '%s' "$ROLLOUT_CONFIG" | jq -r .enabled_at)" '
    .repository == $repo and .state == "OPEN" and .draft == false and
    (.created_at | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    .head_repository == $repo and .base_repository == $repo and
    .base_ref == .default_branch and
    .default_branch == "main" and .author == $author and
    (.head | type == "string" and test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$")) and
    (.base_sha | type == "string" and test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$")) and
    .auto_merge.enabledBy.login == $author and
    (.auto_merge.mergeMethod == "MERGE" or
      .auto_merge.mergeMethod == "SQUASH" or
      .auto_merge.mergeMethod == "REBASE") and
    ((.auto_merge.enabledAt | fromdateiso8601) >=
      ($activated | fromdateiso8601)) and
    (.labels | type == "array") and
    all(.labels[]; type == "string" and length > 0)
  ' >/dev/null 2>&1
}

SNAPSHOT=$(read_arm_snapshot) || infra "could not read complete live PR state"
validate_arm_snapshot "$SNAPSHOT" \
  || not_eligible "PR or native arm is outside the governing-author queue lane"
BLOCKERS=$(printf '%s' "$SNAPSHOT" | jq -r '.labels[]' \
  | mergepath_blocking_labels_csv)
[ -z "$BLOCKERS" ] || not_eligible "blocking labels are present: $BLOCKERS"
HEAD_SHA=$(printf '%s' "$SNAPSHOT" | jq -r .head)
BASE_SHA=$(printf '%s' "$SNAPSHOT" | jq -r .base_sha)
BASE_REF=$(printf '%s' "$SNAPSHOT" | jq -r .base_ref)
[ "$CHECKOUT_SHA" = "$BASE_SHA" ] \
  || not_eligible "trusted checkout is not the live PR base"

set +e
ROLLOUT_ROLE=$(mergepath_merge_queue_rollout_role "$ROLLOUT_CONFIG" \
  "$PR_NUMBER" "$HEAD_SHA")
rollout_rc=$?
set -e
case "$rollout_rc" in
  0) ;;
  4) not_eligible "PR/head is outside the trusted rollout scope" ;;
  *) infra "could not evaluate trusted rollout scope" ;;
esac
ACTIVATED_AT=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er .enabled_at) \
  || infra "rollout activation timestamp is unreadable"
if [ "$ROLLOUT_ROLE" = "enabled" ]; then
  PR_CREATED_AT=$(printf '%s' "$SNAPSHOT" | jq -er .created_at) \
    || infra "live PR creation timestamp is unreadable"
  jq -en --arg created "$PR_CREATED_AT" --arg activated "$ACTIVATED_AT" '
    try (($created | fromdateiso8601) >= ($activated | fromdateiso8601))
    catch false
  ' >/dev/null 2>&1 || not_eligible "PR predates the enabled rollout epoch"
fi
if [ "$ROLLOUT_ROLE" = "promotion" ]; then
  TRANSITION_MODE=$(mergepath_merge_queue_verify_promotion_transition \
    "$ROLLOUT_CONFIG" "$REPO" "$HEAD_SHA") \
    || not_eligible "promotion head is not the exact canary-to-enabled transition"
  if [ "$TRANSITION_MODE" = "enabled" ]; then
    mergepath_merge_queue_verify_promotion_prerequisite "$ROLLOUT_CONFIG" \
      "$REPO" "$BASE_REF" "$AUTHOR_IDENTITY" "$BASE_SHA" \
      || not_eligible "exact canary head has not merged into the promotion base"
  fi
fi

REPOSITORY_RULESET_ID=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
  '.repository_ruleset_id | select(type == "number" and floor == . and . > 0)') \
  || infra "repository merge-queue ruleset id is unreadable"
WORKFLOW_RULESET_ID=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
  '.workflow_ruleset_id | select(type == "number" and floor == . and . > 0)') \
  || infra "organization required-workflow ruleset id is unreadable"
WORKFLOW_REPOSITORY_ID=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
  '.workflow_repository_id | select(type == "number" and floor == . and . > 0)') \
  || infra "required-workflow source repository id is unreadable"
TOPOLOGY=$(mergepath_merge_queue_read_topology "$REPO" "$BASE_REF" \
  "$REPOSITORY_RULESET_ID" "$WORKFLOW_RULESET_ID" \
  "$WORKFLOW_REPOSITORY_ID") \
  || infra "complete merge-queue topology is unreadable"
QUEUE_ID=$(printf '%s' "$TOPOLOGY" | jq -er \
  '.graph.explicit_queue.id | select(type == "string" and length > 0)') \
  || not_eligible "default branch has no readable queue"
QUEUE_CONFIG=$(printf '%s' "$TOPOLOGY" | jq -ec \
  '.graph.explicit_queue.configuration | select(type == "object")') \
  || not_eligible "queue configuration is unreadable"
mergepath_merge_queue_validate_topology "$TOPOLOGY" "$REPO" "$BASE_REF" \
  "$AUTHOR_IDENTITY" "$BASE_SHA" "$QUEUE_ID" "$QUEUE_CONFIG" \
  "$ROLLOUT_CONFIG" \
  || not_eligible "live queue/protection topology is not the exact no-bypass two-ruleset contract"
LIVE_MERGE_METHOD=$(printf '%s' "$SNAPSHOT" | jq -er .auto_merge.mergeMethod) \
  || infra "live native arm method is unreadable"
QUEUE_MERGE_METHOD=$(printf '%s' "$QUEUE_CONFIG" | jq -er .mergeMethod) \
  || infra "queue merge method is unreadable"
[ "$LIVE_MERGE_METHOD" = "$QUEUE_MERGE_METHOD" ] \
  || not_eligible "native arm method does not match the queue method"

ARM_ENABLED_AT=$(printf '%s' "$SNAPSHOT" | jq -er .auto_merge.enabledAt) \
  || infra "live native arm timestamp is unreadable"

read_arm_authorization() {
  local timeline comments markers
  timeline=$(mergepath_merge_queue_read_auth_timeline "$REPO" "$PR_NUMBER") \
    || return 1
  comments=$(gh_api_array \
    "repos/$REPO/issues/$PR_NUMBER/comments?per_page=100" \
    "queue authorization comments") || return 1
  markers=$(mergepath_merge_queue_decode_authorizations "$comments") \
    || return 1
  mergepath_merge_queue_select_arm_authorization "$markers" "$timeline" \
    "$REPO" "$PR_NUMBER" "$HEAD_SHA" "$BASE_REF" "$AUTHOR_IDENTITY" \
    "$ARM_ENABLED_AT" "$LIVE_MERGE_METHOD" "$ACTIVATED_AT"
}

AUTHORIZATION=$(read_arm_authorization) \
  || not_eligible "live arm has no unique current exact-head authorization marker"
AUTHORIZED_BASE=$(printf '%s' "$AUTHORIZATION" | jq -er .authorized_base) \
  || infra "arm authorization base is unreadable"
if [ "$AUTHORIZED_BASE" != "$BASE_SHA" ]; then
  AUTHORIZED_COMPARE=$(gh api \
    "repos/$REPO/compare/$AUTHORIZED_BASE...$BASE_SHA") \
    || infra "could not compare the authorized base to the live base"
  printf '%s' "$AUTHORIZED_COMPARE" | jq -e --arg base "$AUTHORIZED_BASE" '
    .status == "ahead" and .base_commit.sha == $base and
    .merge_base_commit.sha == $base
  ' >/dev/null 2>&1 \
    || not_eligible "live base is not descended from the authorized arm base"
fi

# Stable readback fence. Classification is read-only, but a stale success
# would let callers mistake a newer arm, blocker, marker set, or protection
# topology for the exact evidence above. Re-read every mutable input and end
# on a second complete topology proof immediately before PASS.
FINAL_SNAPSHOT=$(read_arm_snapshot) \
  || infra "could not re-read complete live PR state"
validate_arm_snapshot "$FINAL_SNAPSHOT" \
  || not_eligible "PR or native arm changed during queue classification"
[ "$(printf '%s' "$FINAL_SNAPSHOT" | jq -cS .)" = \
  "$(printf '%s' "$SNAPSHOT" | jq -cS .)" ] \
  || not_eligible "mutable PR or arm state changed during queue classification"
FINAL_AUTHORIZATION=$(read_arm_authorization) \
  || not_eligible "arm authorization changed during queue classification"
[ "$(printf '%s' "$FINAL_AUTHORIZATION" | jq -cS .)" = \
  "$(printf '%s' "$AUTHORIZATION" | jq -cS .)" ] \
  || not_eligible "arm authorization evidence drifted during queue classification"
FINAL_TOPOLOGY=$(mergepath_merge_queue_read_topology "$REPO" "$BASE_REF" \
  "$REPOSITORY_RULESET_ID" "$WORKFLOW_RULESET_ID" \
  "$WORKFLOW_REPOSITORY_ID") \
  || infra "could not re-read complete merge-queue topology"
mergepath_merge_queue_validate_topology "$FINAL_TOPOLOGY" "$REPO" "$BASE_REF" \
  "$AUTHOR_IDENTITY" "$BASE_SHA" "$QUEUE_ID" "$QUEUE_CONFIG" \
  "$ROLLOUT_CONFIG" \
  || not_eligible "live queue/protection topology changed during classification"
[ "$(mergepath_merge_queue_topology_signature "$FINAL_TOPOLOGY")" = \
  "$(mergepath_merge_queue_topology_signature "$TOPOLOGY")" ] \
  || not_eligible "merge-queue topology drifted during classification"

echo "merge-queue-arm-policy: PASS — preserve $ROLLOUT_ROLE arm for $REPO#$PR_NUMBER at $HEAD_SHA"
