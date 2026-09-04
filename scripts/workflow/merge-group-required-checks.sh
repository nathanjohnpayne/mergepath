#!/usr/bin/env bash
# Re-evaluate the PR-only merge policy on a singleton merge-group commit.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: merge-group-required-checks.sh --repo owner/repo --head-sha SHA \
  --head-ref REF --base-sha SHA --base-ref REF --default-branch BRANCH \
  --workflow-repository owner/repo --workflow-file-path PATH \
  --workflow-ref REF --workflow-sha SHA --run-id ID --run-attempt NUMBER \
  --phase pre-audit|post-audit \
  [--final-audit-comment-id ID --final-audit-sha256 SHA256]
EOF
  exit 2
}

REPO=""
EVENT_HEAD_SHA=""
EVENT_HEAD_REF=""
EVENT_BASE_SHA=""
EVENT_BASE_REF=""
DEFAULT_BRANCH=""
WORKFLOW_REPOSITORY=""
WORKFLOW_FILE_PATH=""
WORKFLOW_REF=""
WORKFLOW_SHA=""
RUN_ID=""
RUN_ATTEMPT=""
PHASE=""
EXPECTED_FINAL_AUDIT_COMMENT_ID=""
EXPECTED_FINAL_AUDIT_SHA256=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --head-sha) [ "$#" -ge 2 ] || usage; EVENT_HEAD_SHA="$2"; shift 2 ;;
    --head-ref) [ "$#" -ge 2 ] || usage; EVENT_HEAD_REF="$2"; shift 2 ;;
    --base-sha) [ "$#" -ge 2 ] || usage; EVENT_BASE_SHA="$2"; shift 2 ;;
    --base-ref) [ "$#" -ge 2 ] || usage; EVENT_BASE_REF="$2"; shift 2 ;;
    --default-branch) [ "$#" -ge 2 ] || usage; DEFAULT_BRANCH="$2"; shift 2 ;;
    --workflow-repository)
      [ "$#" -ge 2 ] || usage; WORKFLOW_REPOSITORY="$2"; shift 2 ;;
    --workflow-file-path)
      [ "$#" -ge 2 ] || usage; WORKFLOW_FILE_PATH="$2"; shift 2 ;;
    --workflow-ref) [ "$#" -ge 2 ] || usage; WORKFLOW_REF="$2"; shift 2 ;;
    --workflow-sha) [ "$#" -ge 2 ] || usage; WORKFLOW_SHA="$2"; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
    --run-attempt) [ "$#" -ge 2 ] || usage; RUN_ATTEMPT="$2"; shift 2 ;;
    --phase) [ "$#" -ge 2 ] || usage; PHASE="$2"; shift 2 ;;
    --final-audit-comment-id)
      [ "$#" -ge 2 ] || usage
      EXPECTED_FINAL_AUDIT_COMMENT_ID="$2"
      shift 2
      ;;
    --final-audit-sha256)
      [ "$#" -ge 2 ] || usage
      EXPECTED_FINAL_AUDIT_SHA256="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$REPO" ] && [ -n "$EVENT_HEAD_SHA" ] && [ -n "$EVENT_HEAD_REF" ] \
  && [ -n "$EVENT_BASE_SHA" ] && [ -n "$EVENT_BASE_REF" ] \
  && [ -n "$DEFAULT_BRANCH" ] && [ -n "$WORKFLOW_REPOSITORY" ] \
  && [ -n "$WORKFLOW_FILE_PATH" ] && [ -n "$WORKFLOW_REF" ] \
  && [ -n "$WORKFLOW_SHA" ] && [ -n "$RUN_ID" ] \
  && [ -n "$RUN_ATTEMPT" ] && [ -n "$PHASE" ] || usage
case "$REPO" in */*) ;; *) usage ;; esac
REPO_OWNER=${REPO%%/*}
REPO_NAME=${REPO#*/}
case "$REPO_OWNER:$REPO_NAME" in :*|*:|*:*/*) usage ;; esac
sha_like() { printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$'; }
if ! sha_like "$EVENT_HEAD_SHA" || ! sha_like "$EVENT_BASE_SHA" \
    || ! sha_like "$WORKFLOW_SHA"; then
  usage
fi
case "$RUN_ID" in *[!0-9]*|'') usage ;; esac
case "$RUN_ATTEMPT" in *[!0-9]*|'') usage ;; esac
[ "$RUN_ID" -gt 0 ] && [ "$RUN_ATTEMPT" -gt 0 ] || usage
canonical_positive_integer() {
  case "$1" in ''|0*|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}
case "$PHASE" in
  pre-audit)
    [ -z "$EXPECTED_FINAL_AUDIT_COMMENT_ID" ] \
      && [ -z "$EXPECTED_FINAL_AUDIT_SHA256" ] || usage
    ;;
  post-audit)
    canonical_positive_integer "$EXPECTED_FINAL_AUDIT_COMMENT_ID" || usage
    printf '%s' "$EXPECTED_FINAL_AUDIT_SHA256" \
      | grep -Eq '^[0-9a-f]{64}$' || usage
    ;;
  *) usage ;;
esac

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

die() {
  echo "merge-group-required-checks: FAIL — $*" >&2
  exit 1
}

infra() {
  echo "merge-group-required-checks: ERROR — $*" >&2
  exit 2
}

sha256_text() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$1" | sha256sum) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$1" | shasum -a 256) || return 1
  else
    return 1
  fi
  printf '%s\n' "${digest%% *}"
}

for tool in gh jq git; do
  command -v "$tool" >/dev/null 2>&1 || infra "required tool '$tool' is unavailable"
done
[ -n "${GH_TOKEN:-}" ] || infra "GH_TOKEN is required"
[ -r "$ROOT/scripts/lib/gh-api-array.sh" ] || infra "paginated API helper is unavailable"
[ -r "$ROOT/scripts/lib/blocking-labels.sh" ] || infra "blocking-label policy is unavailable"
[ -r "$ROOT/scripts/lib/merge-queue-authorization.sh" ] || infra "queue authorization policy is unavailable"
[ -r "$ROOT/scripts/lib/merge-queue-protection.sh" ] || infra "merge-queue rollout policy is unavailable"
[ -r "$ROOT/scripts/lib/review-policy-scalar.sh" ] || infra "review-policy reader is unavailable"
[ -r "$ROOT/.github/review-policy.yml" ] || infra "governing review policy is unavailable"

# shellcheck source=../lib/gh-api-array.sh
. "$ROOT/scripts/lib/gh-api-array.sh"
# shellcheck source=../lib/blocking-labels.sh
. "$ROOT/scripts/lib/blocking-labels.sh"
# shellcheck source=../lib/merge-queue-authorization.sh
. "$ROOT/scripts/lib/merge-queue-authorization.sh"
# shellcheck source=../lib/merge-queue-protection.sh
. "$ROOT/scripts/lib/merge-queue-protection.sh"
# shellcheck source=../lib/review-policy-scalar.sh
. "$ROOT/scripts/lib/review-policy-scalar.sh"

AUTHOR_IDENTITY=$(review_policy_scalar "$ROOT/.github/review-policy.yml" author_identity)
[ -n "$AUTHOR_IDENTITY" ] || infra "governing policy names no author_identity"

# The organization ruleset pins the workflow source repository, path, and
# immutable SHA. The workflow then checks out the event's base SHA, not the
# merge-group tree, so every authorization predicate runs on reviewed base
# code. Both phases are deliberately read-only. The intervening dispatch and
# nonce-bound response validation run only from the separately checked-out,
# source-pinned handshake job.
CHECKOUT_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) \
  || infra "could not identify the trusted checkout"
[ "$CHECKOUT_SHA" = "$EVENT_BASE_SHA" ] \
  || infra "trusted checkout is $CHECKOUT_SHA, expected event base $EVENT_BASE_SHA"
[ "$DEFAULT_BRANCH" = "main" ] || die "merge-group bridge is enabled only for main"
[ "$EVENT_BASE_REF" = "refs/heads/$DEFAULT_BRANCH" ] \
  || die "event base ref '$EVENT_BASE_REF' is not refs/heads/$DEFAULT_BRANCH"

# shellcheck disable=SC2016 # GraphQL variables are intentionally literal.
QUEUE_QUERY='query($owner:String!,$name:String!,$branch:String!,$after:String){
  repository(owner:$owner,name:$name){
    id nameWithOwner
    owner{__typename login}
    defaultBranchRef{name target{... on Commit{oid}}}
    mergeQueue(branch:$branch){
      id
      configuration{
        maximumEntriesToBuild maximumEntriesToMerge minimumEntriesToMerge
        mergeMethod mergingStrategy
      }
      entries(first:100,after:$after){
        totalCount pageInfo{hasNextPage endCursor}
        nodes{
          id baseCommit{oid} headCommit{oid} enqueuedAt enqueuer{login}
          jump solo state
          mergeQueue{id}
          pullRequest{
            id number state isDraft createdAt headRefOid baseRefName stack{id}
            author{login} autoMergeRequest{enabledAt enabledBy{login}}
          }
        }
      }
    }
  }
}'

read_queue_snapshot() {
  local raw page snapshot="" cursor="" next_cursor has_next
  local page_static snapshot_static seen_cursors='[]' page_count=0
  local -a gh_args
  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le 100 ] || return 1
    gh_args=(api graphql -f query="$QUEUE_QUERY" \
      -f owner="$REPO_OWNER" -f name="$REPO_NAME" \
      -f branch="$DEFAULT_BRANCH")
    if [ -n "$cursor" ]; then
      gh_args+=(-f after="$cursor")
    fi
    raw=$(gh "${gh_args[@]}") || return 1
    page=$(printf '%s' "$raw" | jq -ce '
      select(((.errors // []) | length) == 0) |
      .data.repository as $repo |
      $repo.mergeQueue as $queue |
      select($repo != null and $queue != null) |
      {
        repository_id: $repo.id,
        repository: $repo.nameWithOwner,
        owner_type: $repo.owner.__typename,
        owner_login: $repo.owner.login,
        default_branch: $repo.defaultBranchRef.name,
        live_base: $repo.defaultBranchRef.target.oid,
        queue: {
          id: $queue.id,
          configuration: $queue.configuration,
          total_count: $queue.entries.totalCount,
          has_next: $queue.entries.pageInfo.hasNextPage,
          end_cursor: $queue.entries.pageInfo.endCursor,
          entries: $queue.entries.nodes
        }
      } |
      select(
        (.queue.total_count | type == "number" and floor == . and . >= 0) and
        (.queue.has_next | type == "boolean") and
        (.queue.entries | type == "array")
      )
    ') || return 1

    if [ -z "$snapshot" ]; then
      snapshot="$page"
    else
      page_static=$(printf '%s' "$page" \
        | jq -cS 'del(.queue.has_next,.queue.end_cursor,.queue.entries)') || return 1
      snapshot_static=$(printf '%s' "$snapshot" \
        | jq -cS 'del(.queue.has_next,.queue.end_cursor,.queue.entries)') || return 1
      [ "$page_static" = "$snapshot_static" ] || return 1
      snapshot=$(jq -cn --argjson snapshot "$snapshot" --argjson page "$page" '
        $snapshot |
        .queue.entries += $page.queue.entries |
        .queue.has_next = $page.queue.has_next |
        .queue.end_cursor = $page.queue.end_cursor
      ') || return 1
    fi

    has_next=$(printf '%s' "$page" | jq -r '.queue.has_next') || return 1
    [ "$has_next" = "true" ] || break
    next_cursor=$(printf '%s' "$page" | jq -er '
      .queue.end_cursor |
      select(type == "string" and length > 0)
    ') || return 1
    if printf '%s' "$seen_cursors" \
      | jq -e --arg cursor "$next_cursor" 'index($cursor) != null' >/dev/null 2>&1; then
      return 1
    fi
    seen_cursors=$(printf '%s' "$seen_cursors" \
      | jq -c --arg cursor "$next_cursor" '. + [$cursor]') || return 1
    cursor="$next_cursor"
  done
  printf '%s' "$snapshot" | jq -ce 'del(.queue.end_cursor)'
}

validate_queue_snapshot() {
  local snapshot="$1"
  printf '%s' "$snapshot" | jq -e \
    --arg repo "$REPO" --arg branch "$DEFAULT_BRANCH" \
    --arg base "$EVENT_BASE_SHA" --arg author "$AUTHOR_IDENTITY" '
      type == "object" and
      (.repository_id | type == "string" and length > 0) and
      .repository == $repo and .owner_type == "Organization" and
      (.owner_login | type == "string" and length > 0) and
      .default_branch == $branch and
      .live_base == $base and
      (.queue.id | type == "string" and length > 0) and
      .queue.total_count == 1 and .queue.has_next == false and
      (.queue.entries | type == "array" and length == 1) and
      (.queue.configuration as $configuration |
        $configuration.maximumEntriesToBuild == 1 and
        $configuration.maximumEntriesToMerge == 1 and
        $configuration.minimumEntriesToMerge == 1 and
        $configuration.mergingStrategy == "ALLGREEN" and
        ((["MERGE","SQUASH","REBASE"] | index($configuration.mergeMethod)) != null)) and
      (.queue.entries[0] as $entry |
        ($entry.id | type == "string" and length > 0) and
        ($entry.baseCommit.oid | type == "string" and length > 0) and
        ($entry.headCommit.oid | type == "string" and length > 0) and
        ($entry.enqueuedAt | type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        $entry.enqueuer.login == $author and
        $entry.jump == false and
        ($entry.solo | type == "boolean") and
        ((["QUEUED","AWAITING_CHECKS","MERGEABLE","LOCKED"] |
          index($entry.state)) != null) and
        $entry.mergeQueue.id == .queue.id and
        ($entry.pullRequest.id | type == "string" and length > 0) and
        ($entry.pullRequest.number | type == "number" and floor == .) and
        $entry.pullRequest.state == "OPEN" and
        $entry.pullRequest.isDraft == false and
        ($entry.pullRequest.createdAt | type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        $entry.pullRequest.headRefOid == $entry.headCommit.oid and
        $entry.pullRequest.baseRefName == $branch and
        $entry.pullRequest.stack == null and
        $entry.pullRequest.author.login == $author and
        $entry.pullRequest.autoMergeRequest == null)
    ' >/dev/null 2>&1
}

queue_signature() {
  printf '%s' "$1" | jq -cS '{
    repository_id, repository, owner_type, owner_login, default_branch, live_base,
    queue: {
      id: .queue.id,
      configuration: .queue.configuration,
      total_count: .queue.total_count,
      has_next: .queue.has_next,
      entries: [.queue.entries[] | {
        id, base: .baseCommit.oid, head: .headCommit.oid,
        enqueued_at: .enqueuedAt, enqueuer: .enqueuer.login,
        jump, solo, queue: .mergeQueue.id,
        pr: {
          id: .pullRequest.id, number: .pullRequest.number,
          state: .pullRequest.state, draft: .pullRequest.isDraft,
          created_at: .pullRequest.createdAt,
          head: .pullRequest.headRefOid, base: .pullRequest.baseRefName,
          stack: .pullRequest.stack, author: .pullRequest.author.login,
          auto_merge: .pullRequest.autoMergeRequest
        }
      }]
    }
  }'
}

read_effective_rules() {
  local encoded
  encoded=$(jq -rn --arg branch "$DEFAULT_BRANCH" '$branch | @uri') \
    || return 1
  gh_api_array "repos/$REPO/rules/branches/$encoded?per_page=100" \
    "effective default-branch rules" || {
      echo "$GH_API_ARRAY_ERROR" >&2
      return 1
    }
}

initial_queue=$(read_queue_snapshot) || infra "could not read the live merge queue"
validate_queue_snapshot "$initial_queue" \
  || die "queue must be organization-owned and contain exactly one standalone PR under singleton ALLGREEN topology at the live main tip"
QUEUE_ID=$(printf '%s' "$initial_queue" | jq -r '.queue.id')
REPOSITORY_NODE_ID=$(printf '%s' "$initial_queue" | jq -er \
  '.repository_id | select(type == "string" and length > 0)') \
  || infra "queue returned no repository node id"
QUEUE_CONFIG=$(printf '%s' "$initial_queue" | jq -c '.queue.configuration')
QUEUE_METHOD=$(printf '%s' "$QUEUE_CONFIG" | jq -er .mergeMethod) \
  || infra "queue merge method is unreadable"
ENTRY_ID=$(printf '%s' "$initial_queue" | jq -r '.queue.entries[0].id')
ENTRY_BASE=$(printf '%s' "$initial_queue" | jq -r '.queue.entries[0].baseCommit.oid')
ENTRY_ENQUEUED_AT=$(printf '%s' "$initial_queue" | jq -r '.queue.entries[0].enqueuedAt')
PR_CREATED_AT=$(printf '%s' "$initial_queue" | jq -r '.queue.entries[0].pullRequest.createdAt')
PR_HEAD=$(printf '%s' "$initial_queue" | jq -r '.queue.entries[0].headCommit.oid')
PR_NUMBER=$(printf '%s' "$initial_queue" | jq -r '.queue.entries[0].pullRequest.number')
PR_NODE_ID=$(printf '%s' "$initial_queue" | jq -er \
  '.queue.entries[0].pullRequest.id | select(type == "string" and length > 0)') \
  || infra "queue returned no pull-request node id"
case "$PR_NUMBER" in *[!0-9]*|'') infra "queue returned an invalid PR number" ;; esac
if ! sha_like "$ENTRY_BASE" || ! sha_like "$PR_HEAD"; then
  infra "queue returned a malformed commit oid"
fi
ROLLOUT_CONFIG=$(mergepath_merge_queue_rollout_config \
  "$ROOT/.github/review-policy.yml") \
  || infra "merge-queue rollout configuration is malformed"
mergepath_merge_queue_validate_required_workflow "$ROLLOUT_CONFIG" "$REPO" \
  "$WORKFLOW_REPOSITORY" "$WORKFLOW_FILE_PATH" "$WORKFLOW_REF" \
  "$WORKFLOW_SHA" \
  || die "runtime workflow identity does not match the predeclared organization rule"
set +e
ROLLOUT_ROLE=$(mergepath_merge_queue_rollout_entry_scope "$ROLLOUT_CONFIG" \
  "$PR_NUMBER" "$PR_HEAD" "$ENTRY_ENQUEUED_AT" "$PR_CREATED_AT")
rollout_rc=$?
set -e
case "$rollout_rc" in
  0) ;;
  4) die "native queue entry is outside the trusted rollout scope" ;;
  *) infra "could not evaluate the trusted merge-queue rollout scope" ;;
esac
if [ "$ROLLOUT_ROLE" = "promotion" ]; then
  TRANSITION_MODE=$(mergepath_merge_queue_verify_promotion_transition \
    "$ROLLOUT_CONFIG" "$REPO" "$PR_HEAD") \
    || die "predeclared transition entry is neither an exact promotion nor rollback"
  if [ "$TRANSITION_MODE" = "enabled" ]; then
    mergepath_merge_queue_verify_promotion_prerequisite "$ROLLOUT_CONFIG" \
      "$REPO" "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$EVENT_BASE_SHA" \
      || die "promotion entry is unavailable until the exact canary head has merged"
  fi
else
  TRANSITION_MODE=""
fi
initial_effective_rules=$(read_effective_rules) \
  || infra "could not read complete effective default-branch rules"
mergepath_merge_queue_validate_effective_rules "$initial_effective_rules" \
  "$ROLLOUT_CONFIG" "$REPO" "$QUEUE_METHOD" \
  || die "active rules do not require this singleton queue and the pinned workflows"
case "$EVENT_HEAD_REF" in
  "refs/heads/gh-readonly-queue/$DEFAULT_BRANCH/pr-$PR_NUMBER-"*) ;;
  *) die "merge-group ref '$EVENT_HEAD_REF' does not identify the singleton queue PR #$PR_NUMBER" ;;
esac

read_group_ref() {
  gh api "repos/$REPO/git/ref/${EVENT_HEAD_REF#refs/}" | jq -ce '
    {
      ref: .ref,
      object_type: .object.type,
      object_sha: .object.sha
    }
  '
}

validate_group_ref() {
  printf '%s' "$1" | jq -e \
    --arg ref "$EVENT_HEAD_REF" --arg sha "$EVENT_HEAD_SHA" '
      type == "object" and .ref == $ref and
      .object_type == "commit" and .object_sha == $sha
    ' >/dev/null 2>&1
}

initial_group_ref=$(read_group_ref) || infra "could not read the live merge-group ref"
validate_group_ref "$initial_group_ref" \
  || die "live merge-group ref does not match the event head"

read_workflow_run() {
  [ "$#" -eq 1 ] || return 1
  gh api "repos/$REPO/actions/runs/$1"
}

validate_requester_run() {
  printf '%s' "$1" | jq -e \
    --arg repo "$REPO" --arg id "$RUN_ID" \
    --argjson attempt "$RUN_ATTEMPT" --arg head "$EVENT_HEAD_SHA" \
    --arg branch "${EVENT_HEAD_REF#refs/heads/}" '
      type == "object" and (.id | tostring) == $id and
      .run_attempt == $attempt and .repository.full_name == $repo and
      .event == "merge_group" and .status == "in_progress" and
      .conclusion == null and .head_sha == $head and
      .head_branch == $branch and .head_repository.full_name == $repo
    ' >/dev/null 2>&1
}

requester_run=$(read_workflow_run "$RUN_ID") \
  || infra "could not read the current required-workflow run"
validate_requester_run "$requester_run" \
  || die "current required-workflow run does not match the merge-group event"

fetch_comments() {
  gh_api_array "repos/$REPO/issues/$PR_NUMBER/comments?per_page=100" "PR marker comments" || {
    echo "$GH_API_ARRAY_ERROR" >&2
    return 1
  }
}

fetch_labels() {
  gh_api_array "repos/$REPO/issues/$PR_NUMBER/labels?per_page=100" "PR labels" || {
    echo "$GH_API_ARRAY_ERROR" >&2
    return 1
  }
}

decode_markers() {
  mergepath_merge_queue_decode_authorizations "$1"
}

legacy_controller_lineage_absent() {
  printf '%s' "$1" | jq -e --arg author "$AUTHOR_IDENTITY" \
    --arg repo "$REPO" --argjson pr "$PR_NUMBER" --arg head "$PR_HEAD" \
    --arg base_ref "$DEFAULT_BRANCH" --arg captured_base "$EVENT_BASE_SHA" \
    --arg repo_id "$REPOSITORY_NODE_ID" --arg pr_id "$PR_NODE_ID" '
      def marker_re:
        "<!-- mergepath-armed-base-freshness:v1 " +
        "(?<payload>[A-Za-z0-9+/=]+) -->";
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def sha:
        type == "string" and
        test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$");
      def generation:
        type == "string" and test("^abf-v1-[0-9a-f]{64}$");
      type == "array" and
      ([.[] as $comment |
        select($comment | type == "object") |
        try (
          (($comment.body // "") |
            capture(marker_re).payload | @base64d | fromjson) + {
              _comment_author:($comment.user.login // "")
            }
        ) catch empty |
        select(
          type == "object" and
          .schema == "mergepath-armed-base-freshness/v1" and
          .kind == "intent" and ._comment_author == $author and
          (.generation | generation) and (.arm_lineage | generation) and
          ((.rearm_after_comment_id == null) or
            (.rearm_after_comment_id | type == "string" and test("^[0-9]+$"))) and
          (.source_auto_merge_event_id | type == "string" and length > 0) and
          (.source_auto_merge_event_created_at | timestamp) and
          .repository == $repo and .repo_id == $repo_id and
          .pr == $pr and .pr_id == $pr_id and
          .pr_author == $author and .enabled_by == $author and
          (.enabled_at | timestamp) and
          (.merge_method == "MERGE" or .merge_method == "SQUASH" or
            .merge_method == "REBASE") and
          ((.commit_headline == null) or (.commit_headline | type == "string")) and
          ((.commit_body == null) or (.commit_body | type == "string")) and
          .original_head == $head and .base_ref == $base_ref and
          (.captured_base | sha) and .captured_base == $captured_base and
          (.created_at | timestamp)
        )] | length) == 0
    ' >/dev/null 2>&1
}

ATTESTATION_INTERVAL=${MERGEPATH_MERGE_QUEUE_ATTESTATION_INTERVAL_SECONDS:-5}
case "$ATTESTATION_INTERVAL" in *[!0-9]*|'') infra "attestation interval is malformed" ;; esac
[ "$ATTESTATION_INTERVAL" -le 60 ] \
  || infra "attestation wait is outside the bounded policy"
QUEUE_CHECK_TIMEOUT_MINUTES=$(printf '%s' "$initial_effective_rules" | jq -er \
  --argjson ruleset "$(printf '%s' "$ROLLOUT_CONFIG" | jq -r .repository_ruleset_id)" '
    [.[] | select(.type == "merge_queue" and .ruleset_id == $ruleset)] |
    select(length == 1) | .[0].parameters.check_response_timeout_minutes |
    select(type == "number" and floor == . and . > 0)
  ') || infra "queue check-response timeout is unreadable"
if [ "$ATTESTATION_INTERVAL" -eq 0 ]; then
  default_attestation_attempts=1
else
  default_attestation_attempts=$((
    (QUEUE_CHECK_TIMEOUT_MINUTES * 60) / ATTESTATION_INTERVAL + 1
  ))
fi
ATTESTATION_ATTEMPTS=${MERGEPATH_MERGE_QUEUE_ATTESTATION_ATTEMPTS:-$default_attestation_attempts}
case "$ATTESTATION_ATTEMPTS" in *[!0-9]*|'') infra "attestation attempts are malformed" ;; esac
[ "$ATTESTATION_ATTEMPTS" -gt 0 ] && [ "$ATTESTATION_ATTEMPTS" -le 100000 ] \
  || infra "attestation wait is outside the bounded policy"
attestation_wait_seconds=$(((ATTESTATION_ATTEMPTS - 1) * ATTESTATION_INTERVAL))
[ "$attestation_wait_seconds" -le $((QUEUE_CHECK_TIMEOUT_MINUTES * 60)) ] \
  || infra "attestation wait exceeds the queue check-response timeout"

wait_for_entry_attestation() {
  local attempt=1 comments markers timeline action attestation rc action_rc
  local queue group_ref labels blockers
  while [ "$attempt" -le "$ATTESTATION_ATTEMPTS" ]; do
    comments=$(fetch_comments) \
      || infra "could not read complete queue-attestation history"
    legacy_controller_lineage_absent "$comments" \
      || die "same-head legacy controller intent exists on this PR; refuse to adopt its queue entry"
    markers=$(decode_markers "$comments") \
      || infra "could not decode queue attestations"
    timeline=$(mergepath_merge_queue_read_auth_timeline "$REPO" "$PR_NUMBER") \
      || infra "could not read complete queue-action timeline"
    set +e
    action=$(mergepath_merge_queue_select_entry_action "$timeline" "$REPO" \
      "$PR_NUMBER" "$AUTHOR_IDENTITY" "$QUEUE_ID" "$ENTRY_ENQUEUED_AT" \
      "$(printf '%s' "$ROLLOUT_CONFIG" | jq -r .enabled_at)" \
      "$QUEUE_METHOD")
    action_rc=$?
    set -e
    rc=1
    attestation=""
    if [ "$action_rc" -eq 0 ] && [ -n "$action" ]; then
      set +e
      attestation=$(mergepath_merge_queue_select_entry_attestation "$markers" \
        "$action" "$REPO" "$PR_NUMBER" "$PR_HEAD" "$DEFAULT_BRANCH" \
        "$AUTHOR_IDENTITY" "$QUEUE_ID" "$ENTRY_ID" "$ENTRY_ENQUEUED_AT" \
        "$QUEUE_METHOD" "$ENTRY_BASE" "$ROLLOUT_CONFIG")
      rc=$?
      set -e
    fi
    if [ "$rc" -eq 0 ] && [ -n "$attestation" ]; then
      jq -cn --argjson action "$action" --argjson attestation "$attestation" \
        '{action:$action,attestation:$attestation}'
      return 0
    fi
    [ "$attempt" -lt "$ATTESTATION_ATTEMPTS" ] || return 1

    # The target pull_request_target attester and this external required
    # workflow start asynchronously. Wait only while every exact entry/group
    # fence remains unchanged and no blocker appears.
    queue=$(read_queue_snapshot) \
      || infra "could not re-read queue while awaiting attestation"
    validate_queue_snapshot "$queue" \
      || die "queue became unsafe while awaiting attestation"
    [ "$(queue_signature "$queue")" = \
      "$(queue_signature "$initial_queue")" ] \
      || die "queue entry changed while awaiting attestation"
    group_ref=$(read_group_ref) \
      || infra "could not re-read group ref while awaiting attestation"
    validate_group_ref "$group_ref" \
      || die "merge-group ref changed while awaiting attestation"
    labels=$(fetch_labels) \
      || infra "could not re-read labels while awaiting attestation"
    blockers=$(printf '%s' "$labels" | jq -r '.[].name' \
      | mergepath_blocking_labels_csv)
    [ -z "$blockers" ] \
      || die "blocking labels appeared while awaiting attestation: $blockers"
    sleep "$ATTESTATION_INTERVAL"
    attempt=$((attempt + 1))
  done
  return 1
}

ENTRY_PROOF=$(wait_for_entry_attestation) \
  || die "queue entry has no post-enqueue administrative attestation"
ACTION=$(printf '%s' "$ENTRY_PROOF" | jq -ec .action) \
  || infra "queue action proof is malformed"
ATTESTATION=$(printf '%s' "$ENTRY_PROOF" | jq -ec .attestation) \
  || infra "queue attestation proof is malformed"

# A deferred auto-merge authorization records the exact base at the owner
# action; a direct queue action starts at the entry base. In both cases GitHub
# must prove an unbroken lineage through the event base while retaining the
# reviewed pull-request head unchanged.
require_ancestor() {
  local ancestor="$1" descendant="$2" relationship="$3" compare
  compare=$(gh api "repos/$REPO/compare/$ancestor...$descendant") \
    || infra "could not compare $relationship"
  printf '%s' "$compare" | jq -e --arg ancestor "$ancestor" '
  (.status == "identical" or .status == "ahead") and
  .base_commit.sha == $ancestor and .merge_base_commit.sha == $ancestor
' >/dev/null 2>&1 || die "$relationship is not an intact ancestor lineage"
}
AUTHORIZED_BASE=$(printf '%s' "$ATTESTATION" | jq -r .entry_base)
require_ancestor "$AUTHORIZED_BASE" "$ENTRY_BASE" \
  "attested base to queue entry base"
require_ancestor "$ENTRY_BASE" "$EVENT_BASE_SHA" \
  "queue entry base to event base"

read_pr_snapshot() {
  local core labels
  core=$(gh api "repos/$REPO/pulls/$PR_NUMBER") || return 1
  labels=$(fetch_labels) || return 1
  jq -cn --argjson pr "$core" --argjson labels "$labels" '
    {
      state: $pr.state, draft: $pr.draft, head: $pr.head.sha,
      head_repository: $pr.head.repo.full_name, base_ref: $pr.base.ref,
      base_sha: $pr.base.sha, default_branch: $pr.base.repo.default_branch,
      author: $pr.user.login, body: ($pr.body // ""),
      auto_merge: $pr.auto_merge,
      labels: [$labels[].name]
    }
  '
}

validate_pr_snapshot() {
  local blockers
  printf '%s' "$1" | jq -e \
    --arg repo "$REPO" --arg head "$PR_HEAD" --arg base "$EVENT_BASE_SHA" \
    --arg branch "$DEFAULT_BRANCH" --arg author "$AUTHOR_IDENTITY" '
      .state == "open" and .draft == false and .head == $head and
      .head_repository == $repo and .base_ref == $branch and
      .base_sha == $base and .default_branch == $branch and
      .author == $author and (.body | type == "string") and
      .auto_merge == null and (.labels | type == "array") and
      all(.labels[]; type == "string" and length > 0)
    ' >/dev/null 2>&1 || return 1
  blockers=$(printf '%s' "$1" | jq -r '.labels[]' | mergepath_blocking_labels_csv)
  [ -z "$blockers" ] || return 1
}

pr_before=$(read_pr_snapshot) || infra "could not read the complete PR snapshot"
validate_pr_snapshot "$pr_before" \
  || die "PR identity, base, native arm, or blocking-label state is not queue-safe"

run_predicate() {
  local label="$1"
  shift
  echo "merge-group-required-checks: evaluating $label"
  "$@" || die "$label did not clear on the released PR head"
}

run_all_predicates() {
  local pr_body
  pr_body=$(jq -r .body <<<"$pr_before") \
    || infra "could not decode the PR body for predicate evaluation"
  "$ROOT/scripts/validate-pr-body.sh" --self-review-only <<<"$pr_body" \
    || die "PR body no longer satisfies Self-Review Required"
  run_predicate "complete feedback accounting" \
    "$ROOT/scripts/review-feedback-accounting.sh" "$PR_NUMBER" "$REPO"
  run_predicate "zero unresolved review conversations" \
    "$ROOT/scripts/resolve-pr-threads.sh" "$PR_NUMBER" --repo "$REPO" --list
  run_predicate "CodeRabbit blocking findings" \
    env REQUIRE_REVIEW_SUMMARY=true \
      "$ROOT/scripts/coderabbit-severity-gate.sh" "$PR_NUMBER" "$REPO"
  run_predicate "Codex required-tier findings" \
    env CODEX_P1_EXPECTED_HEAD_SHA="$PR_HEAD" \
      "$ROOT/scripts/codex-p1-gate.sh" "$PR_NUMBER" "$REPO"
  run_predicate "merge clearance" \
    env MERGE_CLEARANCE_EXPECTED_HEAD_SHA="$PR_HEAD" \
      MERGE_CLEARANCE_EXPECTED_BASE_REF="$DEFAULT_BRANCH" \
      MERGE_CLEARANCE_EXPECTED_BASE_SHA="$EVENT_BASE_SHA" \
      MERGE_CLEARANCE_MATERIALIZE_DEFAULT_POLICY=true \
      "$ROOT/scripts/merge-clearance-gate.sh" "$PR_NUMBER" "$REPO"
  run_predicate "approval independence" \
    "$ROOT/scripts/workflow/approval-independence-check.sh" \
      --repo "$REPO" --pr "$PR_NUMBER" --head "$PR_HEAD" \
      --base-ref "$DEFAULT_BRANCH" --base-sha "$EVENT_BASE_SHA" \
      --merge-login "$AUTHOR_IDENTITY"
}

FINAL_AUDIT=""
FINAL_AUDIT_NONCE=""
FINAL_AUDIT_REQUESTED_AT=""

audit_marker_candidate() {
  local markers="$1"
  printf '%s' "$markers" | jq -ec \
    --arg author "$AUTHOR_IDENTITY" --arg nonce "$FINAL_AUDIT_NONCE" \
    --arg run_id "$RUN_ID" --argjson run_attempt "$RUN_ATTEMPT" '
      [.[] | select(
        ._comment_author == $author and .kind == "final-admin-audit" and
        (.request_nonce == $nonce or
          (.requester_run_id == $run_id and
            .requester_run_attempt == $run_attempt)))] |
      select(length == 1) | .[0]
    '
}

requester_audit_candidate() {
  [ "$#" -eq 1 ] || return 1
  local markers="$1"
  printf '%s' "$markers" | jq -ec \
    --arg author "$AUTHOR_IDENTITY" --arg run_id "$RUN_ID" \
    --argjson run_attempt "$RUN_ATTEMPT" '
      [.[] | select(
        ._comment_author == $author and .kind == "final-admin-audit" and
        .requester_run_id == $run_id and
        .requester_run_attempt == $run_attempt)] |
      select(length == 1) | .[0]
    '
}

select_exact_final_audit() {
  [ "$#" -eq 2 ] || return 1
  local markers="$1" candidate="$2"
  local auditor_run_id auditor_run_attempt auditor_workflow_ref
  local auditor_workflow_sha
  auditor_run_id=$(printf '%s' "$candidate" | jq -er \
    '.auditor_run_id | select(type == "string" and test("^[1-9][0-9]*$"))') \
    || return 1
  auditor_run_attempt=$(printf '%s' "$candidate" | jq -er \
    '.auditor_run_attempt | select(type == "number" and floor == . and . > 0)') \
    || return 1
  auditor_workflow_ref=$(printf '%s' "$candidate" | jq -er \
    '.auditor_workflow_ref | select(type == "string" and length > 0)') \
    || return 1
  auditor_workflow_sha=$(printf '%s' "$candidate" | jq -er \
    '.auditor_workflow_sha | select(type == "string" and length > 0)') \
    || return 1
  mergepath_merge_queue_select_final_audit "$markers" "$ACTION" "$REPO" \
    "$PR_NUMBER" "$PR_HEAD" "$EVENT_HEAD_SHA" "$EVENT_HEAD_REF" \
    "$EVENT_BASE_SHA" "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$QUEUE_ID" \
    "$ENTRY_ID" "$ENTRY_ENQUEUED_AT" "$QUEUE_METHOD" "$ENTRY_BASE" \
    "$ROLLOUT_CONFIG" "$FINAL_AUDIT_NONCE" "$RUN_ID" "$RUN_ATTEMPT" \
    "$FINAL_AUDIT_REQUESTED_AT" "$WORKFLOW_REPOSITORY" \
    "$WORKFLOW_FILE_PATH" "$WORKFLOW_REF" "$WORKFLOW_SHA" \
    "$auditor_run_id" "$auditor_run_attempt" "$auditor_workflow_ref" \
    "$auditor_workflow_sha"
}

classify_auditor_run() {
  [ "$#" -eq 2 ] || return 2
  local run="$1" marker="$2" auditor_run_id auditor_run_attempt
  local auditor_workflow_ref marker_created_at
  auditor_run_id=$(printf '%s' "$marker" | jq -er .auditor_run_id) || return 2
  auditor_run_attempt=$(printf '%s' "$marker" | jq -er .auditor_run_attempt) \
    || return 2
  auditor_workflow_ref=$(printf '%s' "$marker" | jq -er .auditor_workflow_ref) \
    || return 2
  marker_created_at=$(printf '%s' "$marker" | jq -er \
    '._comment_created_at | select(type == "string" and length > 0)') \
    || return 2
  printf '%s' "$run" | jq -er \
    --arg repo "$REPO" --arg id "$auditor_run_id" \
    --argjson attempt "$auditor_run_attempt" --arg head "$EVENT_BASE_SHA" \
    --arg branch "$DEFAULT_BRANCH" \
    --arg path ".github/workflows/merge-queue-final-audit.yml" \
    --arg workflow_ref "$auditor_workflow_ref" \
    --arg requested "$FINAL_AUDIT_REQUESTED_AT" \
    --arg marker_created "$marker_created_at" '
      def matching_path:
        . == $path or . == ($path + "@refs/heads/main") or
        . == $workflow_ref;
      select(type == "object" and (.id | tostring) == $id and
        .run_attempt == $attempt and .repository.full_name == $repo and
        .event == "repository_dispatch" and .head_sha == $head and
        .head_branch == $branch and (.path | matching_path) and
        .head_repository.full_name == $repo and
        .actor.login == "github-actions[bot]" and
        .triggering_actor.login == "github-actions[bot]" and
        (.created_at | type == "string" and
          (try ((. | fromdateiso8601) >= ($requested | fromdateiso8601) and
            (. | fromdateiso8601) <= ($marker_created | fromdateiso8601))
           catch false)) and
        (.run_started_at | type == "string" and
          (try ((. | fromdateiso8601) >= ($requested | fromdateiso8601) and
            (. | fromdateiso8601) <= ($marker_created | fromdateiso8601))
           catch false))) |
      if .status != "completed" then "pending"
      elif .conclusion == "success" then "success"
      else "invalid" end
    '
}

load_final_audit_binding() {
  local comments markers candidate candidate_id canonical_candidate digest
  local conflict_count exact_audit auditor_run_id auditor_run auditor_state
  comments=$(fetch_comments) \
    || infra "could not load complete handshake audit history"
  markers=$(decode_markers "$comments") \
    || infra "could not decode handshake audit history"
  candidate=$(requester_audit_candidate "$markers") \
    || die "handshake-cleared final audit is absent or duplicate"
  candidate_id=$(printf '%s' "$candidate" | jq -er \
    '._comment_id | select(type == "number" and floor == . and . > 0) | tostring') \
    || die "handshake-cleared final audit has no canonical comment id"
  [ "$candidate_id" = "$EXPECTED_FINAL_AUDIT_COMMENT_ID" ] \
    || die "handshake-cleared final audit comment id changed"
  canonical_candidate=$(printf '%s' "$candidate" | jq -ceS .) \
    || infra "could not canonicalize the handshake-cleared final audit"
  digest=$(sha256_text "$canonical_candidate") \
    || infra "could not hash the handshake-cleared final audit"
  [ "$digest" = "$EXPECTED_FINAL_AUDIT_SHA256" ] \
    || die "handshake-cleared final audit content changed"

  FINAL_AUDIT_NONCE=$(printf '%s' "$candidate" | jq -er \
    '.request_nonce | select(type == "string" and test("^[0-9a-f]{64}$"))') \
    || die "handshake-cleared final audit nonce is malformed"
  FINAL_AUDIT_REQUESTED_AT=$(printf '%s' "$candidate" | jq -er \
    '.requested_at | select(type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))') \
    || die "handshake-cleared final audit timestamp is malformed"
  conflict_count=$(mergepath_merge_queue_count_final_audits "$markers" \
    "$REPO" "$PR_NUMBER" "$PR_HEAD" "$EVENT_HEAD_SHA" \
    "$AUTHOR_IDENTITY" "$FINAL_AUDIT_NONCE" "$RUN_ID" "$RUN_ATTEMPT") \
    || infra "could not classify the handshake-cleared final audit"
  [ "$conflict_count" -eq 1 ] \
    || die "handshake-cleared final audit namespace is not unique"
  exact_audit=$(select_exact_final_audit "$markers" "$candidate") \
    || die "handshake-cleared final audit does not bind the exact request"
  [ "$(printf '%s' "$exact_audit" | jq -cS .)" = "$canonical_candidate" ] \
    || die "handshake-cleared final audit selection changed"
  auditor_run_id=$(printf '%s' "$exact_audit" | jq -er .auditor_run_id) \
    || die "handshake-cleared final audit names no auditor run"
  auditor_run=$(read_workflow_run "$auditor_run_id") \
    || infra "could not load the handshake-cleared auditor run"
  auditor_state=$(classify_auditor_run "$auditor_run" "$exact_audit") \
    || die "handshake-cleared auditor run identity is invalid"
  [ "$auditor_state" = success ] \
    || die "handshake-cleared auditor run is not successful"
  FINAL_AUDIT=$exact_audit
}

# Re-read every mutable binding around the predicate set. The second call is
# deliberately the final operation before success: a gate may take long enough
# for queue state, labels, authorization, protection, or the group ref to move.
revalidate_binding() {
  local phase="$1" queue rules pr_snapshot live_comments live_markers
  local live_timeline live_action live_attestation group_ref transition_mode
  local final_conflict_count final_candidate live_final_audit
  local final_candidate_id canonical_final_candidate final_candidate_digest
  local final_auditor_run_id final_auditor_run
  mergepath_merge_queue_validate_required_workflow "$ROLLOUT_CONFIG" "$REPO" \
    "$WORKFLOW_REPOSITORY" "$WORKFLOW_FILE_PATH" "$WORKFLOW_REF" \
    "$WORKFLOW_SHA" \
    || die "required-workflow source identity became unsafe ($phase)"
  queue=$(read_queue_snapshot) || infra "could not re-read the live merge queue ($phase)"
  validate_queue_snapshot "$queue" \
    || die "queue topology or live main changed during evaluation ($phase)"
  [ "$(queue_signature "$queue")" = "$(queue_signature "$initial_queue")" ] \
    || die "queue entry identity, topology, or live main changed during evaluation ($phase)"

  rules=$(read_effective_rules) \
    || infra "could not re-read complete effective rules ($phase)"
  mergepath_merge_queue_validate_effective_rules "$rules" "$ROLLOUT_CONFIG" \
    "$REPO" "$QUEUE_METHOD" \
    || die "effective queue/required-workflow rules became unsafe ($phase)"
  [ "$(printf '%s' "$rules" | jq -cS .)" = \
    "$(printf '%s' "$initial_effective_rules" | jq -cS .)" ] \
    || die "effective queue/required-workflow rules changed during evaluation ($phase)"

  pr_snapshot=$(read_pr_snapshot) \
    || infra "could not re-read the complete PR snapshot ($phase)"
  validate_pr_snapshot "$pr_snapshot" \
    || die "PR state became unsafe during evaluation ($phase)"
  [ "$(printf '%s' "$pr_snapshot" | jq -cS .)" = \
    "$(printf '%s' "$pr_before" | jq -cS .)" ] \
    || die "mutable PR metadata changed during evaluation ($phase)"

  if [ "$ROLLOUT_ROLE" = "promotion" ]; then
    transition_mode=$(mergepath_merge_queue_verify_promotion_transition \
      "$ROLLOUT_CONFIG" "$REPO" "$PR_HEAD") \
      || die "predeclared transition head became invalid ($phase)"
    [ "$transition_mode" = "$TRANSITION_MODE" ] \
      || die "predeclared transition mode changed during evaluation ($phase)"
    if [ "$transition_mode" = "enabled" ]; then
      mergepath_merge_queue_verify_promotion_prerequisite "$ROLLOUT_CONFIG" \
        "$REPO" "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$EVENT_BASE_SHA" \
        || die "promotion prerequisite became invalid ($phase)"
    fi
  fi

  live_comments=$(fetch_comments) \
    || infra "could not re-read complete authorization history ($phase)"
  legacy_controller_lineage_absent "$live_comments" \
    || die "same-head legacy controller intent appeared during evaluation ($phase)"
  live_markers=$(decode_markers "$live_comments") \
    || infra "could not decode final queue authorizations ($phase)"
  live_timeline=$(mergepath_merge_queue_read_auth_timeline "$REPO" "$PR_NUMBER") \
    || infra "could not re-read complete queue-authorization timeline ($phase)"
  live_action=$(mergepath_merge_queue_select_entry_action "$live_timeline" \
    "$REPO" "$PR_NUMBER" "$AUTHOR_IDENTITY" "$QUEUE_ID" \
    "$ENTRY_ENQUEUED_AT" \
    "$(printf '%s' "$ROLLOUT_CONFIG" | jq -r .enabled_at)" \
    "$QUEUE_METHOD") \
    || die "governing queue action was revoked during evaluation ($phase)"
  [ "$(printf '%s' "$live_action" | jq -cS .)" = \
    "$(printf '%s' "$ACTION" | jq -cS .)" ] \
    || die "governing queue action changed during evaluation ($phase)"
  live_attestation=$(mergepath_merge_queue_select_entry_attestation \
    "$live_markers" "$live_action" "$REPO" "$PR_NUMBER" "$PR_HEAD" \
    "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$QUEUE_ID" "$ENTRY_ID" \
    "$ENTRY_ENQUEUED_AT" "$QUEUE_METHOD" "$ENTRY_BASE" \
    "$ROLLOUT_CONFIG") \
    || die "queue-entry attestation was revoked during evaluation ($phase)"
  [ "$(printf '%s' "$live_attestation" | jq -cS .)" = \
    "$(printf '%s' "$ATTESTATION" | jq -cS .)" ] \
    || die "queue-entry attestation changed during evaluation ($phase)"

  group_ref=$(read_group_ref) \
    || infra "could not re-read the live merge-group ref ($phase)"
  validate_group_ref "$group_ref" \
    || die "live merge-group ref changed during evaluation ($phase)"
  [ "$(printf '%s' "$group_ref" | jq -cS .)" = \
    "$(printf '%s' "$initial_group_ref" | jq -cS .)" ] \
    || die "live merge-group ref changed during evaluation ($phase)"

  if [ -n "$FINAL_AUDIT" ]; then
    final_conflict_count=$(mergepath_merge_queue_count_final_audits \
      "$live_markers" "$REPO" "$PR_NUMBER" "$PR_HEAD" "$EVENT_HEAD_SHA" \
      "$AUTHOR_IDENTITY" "$FINAL_AUDIT_NONCE" "$RUN_ID" "$RUN_ATTEMPT") \
      || infra "could not classify the final audit ($phase)"
    [ "$final_conflict_count" -eq 1 ] \
      || die "final audit became duplicate or unavailable ($phase)"
    final_candidate=$(audit_marker_candidate "$live_markers") \
      || die "final audit became malformed ($phase)"
    final_candidate_id=$(printf '%s' "$final_candidate" | jq -er \
      '._comment_id | select(type == "number" and floor == . and . > 0) | tostring') \
      || die "final audit lost its canonical comment id ($phase)"
    [ "$final_candidate_id" = "$EXPECTED_FINAL_AUDIT_COMMENT_ID" ] \
      || die "final audit comment id changed during evaluation ($phase)"
    canonical_final_candidate=$(printf '%s' "$final_candidate" | jq -ceS .) \
      || infra "could not canonicalize the final audit ($phase)"
    final_candidate_digest=$(sha256_text "$canonical_final_candidate") \
      || infra "could not hash the final audit ($phase)"
    [ "$final_candidate_digest" = "$EXPECTED_FINAL_AUDIT_SHA256" ] \
      || die "final audit content changed during evaluation ($phase)"
    live_final_audit=$(select_exact_final_audit "$live_markers" "$final_candidate") \
      || die "final audit no longer binds the exact request ($phase)"
    [ "$(printf '%s' "$live_final_audit" | jq -cS .)" = \
      "$(printf '%s' "$FINAL_AUDIT" | jq -cS .)" ] \
      || die "final audit changed during evaluation ($phase)"
    final_auditor_run_id=$(printf '%s' "$live_final_audit" | jq -er \
      .auditor_run_id) || die "final audit lost its auditor run ($phase)"
    final_auditor_run=$(read_workflow_run "$final_auditor_run_id") \
      || infra "could not re-read final-auditor workflow run ($phase)"
    [ "$(classify_auditor_run "$final_auditor_run" "$live_final_audit")" = \
      "success" ] || die "final-auditor run is no longer successful ($phase)"
  fi
}

case "$PHASE" in
  pre-audit)
    run_all_predicates
    revalidate_binding "first pre-audit fence"
    run_all_predicates
    revalidate_binding "handoff fence"
    ;;
  post-audit)
    load_final_audit_binding
    revalidate_binding "initial post-audit fence"
    run_all_predicates
    revalidate_binding "final post-audit fence"
    ;;
esac

echo "merge-group-required-checks: PASS — $PHASE for $REPO#$PR_NUMBER entry $ENTRY_ID attested after $(printf '%s' "$ACTION" | jq -r .kind) on merge group $EVENT_HEAD_SHA"
