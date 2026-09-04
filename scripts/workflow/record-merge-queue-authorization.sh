#!/usr/bin/env bash
# Record one exact-head governing-author native auto-merge authorization.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: record-merge-queue-authorization.sh --repo owner/repo \
  --event-action auto_merge_enabled|enqueued --pr NUMBER \
  --head-sha SHA --head-repo owner/repo --base-sha SHA --base-ref BRANCH \
  --enabled-by LOGIN --pr-author LOGIN --default-branch BRANCH \
  --runtime-ref REF --runtime-sha SHA --runtime-workflow-ref REF \
  --runtime-workflow-sha SHA
EOF
  exit 2
}

REPO=""
EVENT_ACTION=""
PR_NUMBER=""
EVENT_HEAD_SHA=""
EVENT_HEAD_REPO=""
EVENT_BASE_SHA=""
EVENT_BASE_REF=""
EVENT_ENABLED_BY=""
EVENT_PR_AUTHOR=""
DEFAULT_BRANCH=""
RUNTIME_REF=""
RUNTIME_SHA=""
RUNTIME_WORKFLOW_REF=""
RUNTIME_WORKFLOW_SHA=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --event-action) [ "$#" -ge 2 ] || usage; EVENT_ACTION="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; PR_NUMBER="$2"; shift 2 ;;
    --head-sha) [ "$#" -ge 2 ] || usage; EVENT_HEAD_SHA="$2"; shift 2 ;;
    --head-repo) [ "$#" -ge 2 ] || usage; EVENT_HEAD_REPO="$2"; shift 2 ;;
    --base-sha) [ "$#" -ge 2 ] || usage; EVENT_BASE_SHA="$2"; shift 2 ;;
    --base-ref) [ "$#" -ge 2 ] || usage; EVENT_BASE_REF="$2"; shift 2 ;;
    --enabled-by) [ "$#" -ge 2 ] || usage; EVENT_ENABLED_BY="$2"; shift 2 ;;
    --pr-author) [ "$#" -ge 2 ] || usage; EVENT_PR_AUTHOR="$2"; shift 2 ;;
    --default-branch) [ "$#" -ge 2 ] || usage; DEFAULT_BRANCH="$2"; shift 2 ;;
    --runtime-ref) [ "$#" -ge 2 ] || usage; RUNTIME_REF="$2"; shift 2 ;;
    --runtime-sha) [ "$#" -ge 2 ] || usage; RUNTIME_SHA="$2"; shift 2 ;;
    --runtime-workflow-ref)
      [ "$#" -ge 2 ] || usage; RUNTIME_WORKFLOW_REF="$2"; shift 2 ;;
    --runtime-workflow-sha)
      [ "$#" -ge 2 ] || usage; RUNTIME_WORKFLOW_SHA="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$REPO" ] && [ -n "$EVENT_ACTION" ] && [ -n "$PR_NUMBER" ] \
  && [ -n "$EVENT_HEAD_SHA" ] \
  && [ -n "$EVENT_HEAD_REPO" ] && [ -n "$EVENT_BASE_SHA" ] \
  && [ -n "$EVENT_BASE_REF" ] && [ -n "$EVENT_PR_AUTHOR" ] \
  && [ -n "$DEFAULT_BRANCH" ] && [ -n "$RUNTIME_REF" ] \
  && [ -n "$RUNTIME_SHA" ] && [ -n "$RUNTIME_WORKFLOW_REF" ] \
  && [ -n "$RUNTIME_WORKFLOW_SHA" ] || usage
case "$REPO" in */*) ;; *) usage ;; esac
REPO_OWNER=${REPO%%/*}
REPO_NAME=${REPO#*/}
case "$REPO_OWNER:$REPO_NAME" in :*|*:|*:*/*) usage ;; esac
case "$PR_NUMBER" in *[!0-9]*|'') usage ;; esac
sha_like() { printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$'; }
sha_like "$EVENT_HEAD_SHA" && sha_like "$EVENT_BASE_SHA" \
  && sha_like "$RUNTIME_SHA" && sha_like "$RUNTIME_WORKFLOW_SHA" || usage
case "$EVENT_ACTION" in auto_merge_enabled|enqueued) ;; *) usage ;; esac
if [ "$EVENT_ACTION" = "auto_merge_enabled" ] \
    && [ -z "$EVENT_ENABLED_BY" ]; then
  usage
fi

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

die() {
  echo "record-merge-queue-authorization: FAIL — $*" >&2
  exit 1
}

skip() {
  echo "record-merge-queue-authorization: SKIP — $*"
  exit 0
}

infra() {
  echo "record-merge-queue-authorization: ERROR — $*" >&2
  exit 2
}

for tool in jq git; do
  command -v "$tool" >/dev/null 2>&1 || infra "required tool '$tool' is unavailable"
done
[ -r "$ROOT/scripts/lib/merge-queue-protection.sh" ] || infra "queue rollout policy is unavailable"
[ -r "$ROOT/scripts/lib/review-policy-scalar.sh" ] || infra "review-policy reader is unavailable"

# shellcheck source=../lib/merge-queue-protection.sh
. "$ROOT/scripts/lib/merge-queue-protection.sh"
# shellcheck source=../lib/review-policy-scalar.sh
. "$ROOT/scripts/lib/review-policy-scalar.sh"

AUTHOR_IDENTITY=$(review_policy_scalar "$ROOT/.github/review-policy.yml" author_identity)
[ -n "$AUTHOR_IDENTITY" ] || infra "governing policy names no author_identity"
[ "$EVENT_PR_AUTHOR" = "$AUTHOR_IDENTITY" ] \
  && [ "$EVENT_HEAD_REPO" = "$REPO" ] \
  || skip "event is not a same-repository governing-author arm"
if [ "$EVENT_ACTION" = "auto_merge_enabled" ]; then
  [ "$EVENT_ENABLED_BY" = "$AUTHOR_IDENTITY" ] \
    || skip "native arm was not enabled by the governing author"
fi
[ "$EVENT_BASE_REF" = "$DEFAULT_BRANCH" ] && [ "$DEFAULT_BRANCH" = "main" ] \
  || skip "event does not target the supported default branch"
CHECKOUT_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) \
  || infra "could not identify trusted checkout"
[ "$CHECKOUT_SHA" = "$EVENT_BASE_SHA" ] \
  || infra "trusted checkout is $CHECKOUT_SHA, expected event base $EVENT_BASE_SHA"

ROLLOUT_CONFIG=$(mergepath_merge_queue_rollout_config \
  "$ROOT/.github/review-policy.yml") \
  || infra "merge-queue rollout configuration is malformed"
set +e
ROLLOUT_ROLE=$(mergepath_merge_queue_rollout_role "$ROLLOUT_CONFIG" \
  "$PR_NUMBER" "$EVENT_HEAD_SHA")
rollout_rc=$?
set -e
case "$rollout_rc" in
  0) ;;
  4) skip "auto-merge event is outside the trusted rollout scope" ;;
  *) infra "could not evaluate the trusted rollout scope" ;;
esac

EXPECTED_RUNTIME_WORKFLOW_REF="$REPO/.github/workflows/merge-queue-authorization.yml@refs/heads/main"
[ "$RUNTIME_REF" = refs/heads/main ] \
  && [ "$RUNTIME_SHA" = "$EVENT_BASE_SHA" ] \
  && [ "$RUNTIME_WORKFLOW_REF" = "$EXPECTED_RUNTIME_WORKFLOW_REF" ] \
  && [ "$RUNTIME_WORKFLOW_SHA" = "$EVENT_BASE_SHA" ] \
  || infra "runtime workflow identity is not the exact event-base definition"

# Disabled consumers intentionally reach the skip above without an author
# secret. Only an in-scope rollout may require the privileged evidence/write
# path below.
command -v gh >/dev/null 2>&1 || infra "required tool 'gh' is unavailable"
[ -n "${GH_TOKEN:-}" ] || infra "GH_TOKEN is required for an active rollout"
POLICY_TOKEN=${MERGEPATH_MERGE_QUEUE_POLICY_TOKEN:-}
SOURCE_TOKEN=${MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN:-}
[ -n "$POLICY_TOKEN" ] && [ -n "$SOURCE_TOKEN" ] \
  || infra "active rollout requires protected queue-policy and source credentials"
[ "$GH_TOKEN" != "$POLICY_TOKEN" ] \
  && [ "$GH_TOKEN" != "$SOURCE_TOKEN" ] \
  && [ "$POLICY_TOKEN" != "$SOURCE_TOKEN" ] \
  || infra "author, queue-policy, and queue-source credentials must be pairwise value-distinct"
[ -r "$ROOT/scripts/lib/gh-api-array.sh" ] \
  || infra "paginated API helper is unavailable"
[ -r "$ROOT/scripts/lib/blocking-labels.sh" ] \
  || infra "blocking-label policy is unavailable"
[ -r "$ROOT/scripts/lib/merge-queue-authorization.sh" ] \
  || infra "queue authorization policy is unavailable"
[ -x "$ROOT/scripts/gh-as-author.sh" ] \
  || infra "identity-checked author wrapper is unavailable"
# shellcheck source=../lib/gh-api-array.sh
. "$ROOT/scripts/lib/gh-api-array.sh"
# shellcheck source=../lib/blocking-labels.sh
. "$ROOT/scripts/lib/blocking-labels.sh"
# shellcheck source=../lib/merge-queue-authorization.sh
. "$ROOT/scripts/lib/merge-queue-authorization.sh"
TOKEN_LOGIN=$(gh api user --jq .login) || infra "could not verify author token"
[ "$TOKEN_LOGIN" = "$AUTHOR_IDENTITY" ] \
  || infra "write token identity '$TOKEN_LOGIN' is not '$AUTHOR_IDENTITY'"
POLICY_LOGIN=$(GH_TOKEN="$POLICY_TOKEN" gh api user --jq .login) \
  || infra "could not verify queue-policy token"
[ "$POLICY_LOGIN" = "$AUTHOR_IDENTITY" ] \
  || infra "queue-policy token identity '$POLICY_LOGIN' is not '$AUTHOR_IDENTITY'"
SOURCE_LOGIN=$(GH_TOKEN="$SOURCE_TOKEN" gh api user --jq .login) \
  || infra "could not verify queue-source token"
[ "$SOURCE_LOGIN" = "$AUTHOR_IDENTITY" ] \
  || infra "queue-source token identity '$SOURCE_LOGIN' is not '$AUTHOR_IDENTITY'"

if [ "$ROLLOUT_ROLE" = "promotion" ]; then
  TRANSITION_MODE=$(mergepath_merge_queue_verify_promotion_transition \
    "$ROLLOUT_CONFIG" "$REPO" "$EVENT_HEAD_SHA") \
    || die "predeclared transition head is neither an exact promotion nor rollback"
  if [ "$TRANSITION_MODE" = "enabled" ]; then
    mergepath_merge_queue_verify_promotion_prerequisite "$ROLLOUT_CONFIG" \
      "$REPO" "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$EVENT_BASE_SHA" \
      || die "promotion is unavailable until the exact canary head has merged"
  fi
fi
ACTIVATED_AT=$(printf '%s' "$ROLLOUT_CONFIG" | jq -r .enabled_at)

fetch_labels() {
  gh_api_array "repos/$REPO/issues/$PR_NUMBER/labels?per_page=100" "PR labels" || {
    echo "$GH_API_ARRAY_ERROR" >&2
    return 1
  }
}

fetch_comments() {
  gh_api_array "repos/$REPO/issues/$PR_NUMBER/comments?per_page=100" \
    "queue authorization comments" || {
    echo "$GH_API_ARRAY_ERROR" >&2
    return 1
  }
}

# REST and the pull_request_target payload expose the arm identity and method,
# but not the authoritative enabledAt value. Read the live PullRequest object
# through GraphQL so the exact event can be selected from the ordered timeline.
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
      mergeQueueEntry{
        id baseCommit{oid} headCommit{oid} enqueuedAt enqueuer{login}
        jump solo state mergeQueue{id}
      }
    }
  }
}'

read_live_snapshot() {
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
      author:$pr.author.login,auto_merge:$pr.autoMergeRequest,
      queue_entry:(if $pr.mergeQueueEntry == null then null else {
        id:$pr.mergeQueueEntry.id,
        base:$pr.mergeQueueEntry.baseCommit.oid,
        head:$pr.mergeQueueEntry.headCommit.oid,
        enqueued_at:$pr.mergeQueueEntry.enqueuedAt,
        enqueuer:$pr.mergeQueueEntry.enqueuer.login,
        jump:$pr.mergeQueueEntry.jump,solo:$pr.mergeQueueEntry.solo,
        state:$pr.mergeQueueEntry.state,
        queue_id:$pr.mergeQueueEntry.mergeQueue.id
      } end)
    }
  ') || return 1
  labels=$(fetch_labels) || return 1
  jq -cn --argjson pr "$pr" --argjson labels "$labels" \
    '$pr + {labels:([$labels[].name] | sort)}'
}

validate_live_snapshot() {
  local blockers
  printf '%s' "$1" | jq -e \
    --arg repo "$REPO" --arg head "$EVENT_HEAD_SHA" \
    --arg branch "$DEFAULT_BRANCH" --arg author "$AUTHOR_IDENTITY" \
    '
      .repository == $repo and .state == "OPEN" and .draft == false and
      (.created_at | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .head == $head and .head_repository == $repo and
      .base_repository == $repo and .base_ref == $branch and
      .default_branch == $branch and .author == $author and
      (.base_sha | type == "string" and
        test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$")) and
      .auto_merge.enabledBy.login == $author and
      (.auto_merge.enabledAt | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      (.auto_merge.mergeMethod == "MERGE" or
        .auto_merge.mergeMethod == "SQUASH" or
        .auto_merge.mergeMethod == "REBASE") and
      (.labels | type == "array") and
      all(.labels[]; type == "string" and length > 0)
    ' >/dev/null 2>&1 || return 1
  blockers=$(printf '%s' "$1" | jq -r '.labels[]' | mergepath_blocking_labels_csv)
  [ -z "$blockers" ]
}

require_base_lineage() {
  local live_base="$1" compare
  [ "$live_base" = "$EVENT_BASE_SHA" ] && return 0
  compare=$(gh api "repos/$REPO/compare/$EVENT_BASE_SHA...$live_base") || return 1
  printf '%s' "$compare" | jq -e --arg base "$EVENT_BASE_SHA" '
    .status == "ahead" and .base_commit.sha == $base and
    .merge_base_commit.sha == $base
  ' >/dev/null 2>&1
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

validate_enqueued_snapshot() {
  local snapshot="$1" queue_id="$2" blockers
  printf '%s' "$snapshot" | jq -e \
    --arg repo "$REPO" --arg head "$EVENT_HEAD_SHA" \
    --arg base "$EVENT_BASE_SHA" --arg branch "$DEFAULT_BRANCH" \
    --arg author "$AUTHOR_IDENTITY" --arg queue "$queue_id" '
      .repository == $repo and .state == "OPEN" and .draft == false and
      (.created_at | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .head == $head and .head_repository == $repo and
      .base_repository == $repo and .base_ref == $branch and
      .base_sha == $base and .default_branch == $branch and
      .author == $author and .auto_merge == null and
      (.queue_entry | type == "object") and
      (.queue_entry.id | type == "string" and length > 0) and
      .queue_entry.base == $base and .queue_entry.head == $head and
      (.queue_entry.enqueued_at | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .queue_entry.enqueuer == $author and
      .queue_entry.jump == false and (.queue_entry.solo | type == "boolean") and
      (.queue_entry.state as $state |
        (["QUEUED","AWAITING_CHECKS","MERGEABLE","LOCKED"] |
          index($state)) != null) and
      .queue_entry.queue_id == $queue and
      (.labels | type == "array") and
      all(.labels[]; type == "string" and length > 0)
    ' >/dev/null 2>&1 || return 1
  blockers=$(printf '%s' "$snapshot" | jq -r '.labels[]' \
    | mergepath_blocking_labels_csv)
  [ -z "$blockers" ]
}

validate_pending_enqueued_snapshot() {
  local snapshot="$1" queue_method="$2" blockers
  printf '%s' "$snapshot" | jq -e \
    --arg repo "$REPO" --arg head "$EVENT_HEAD_SHA" \
    --arg base "$EVENT_BASE_SHA" --arg branch "$DEFAULT_BRANCH" \
    --arg author "$AUTHOR_IDENTITY" --arg method "$queue_method" \
    --arg activated "$ACTIVATED_AT" '
      .repository == $repo and .state == "OPEN" and .draft == false and
      (.created_at | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .head == $head and .head_repository == $repo and
      .base_repository == $repo and .base_ref == $branch and
      .base_sha == $base and .default_branch == $branch and
      .author == $author and .queue_entry == null and
      (.auto_merge == null or (
        .auto_merge.enabledBy.login == $author and
        .auto_merge.mergeMethod == $method and
        (.auto_merge.enabledAt | type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
          ((fromdateiso8601) >= ($activated | fromdateiso8601))))) and
      (.labels | type == "array") and
      all(.labels[]; type == "string" and length > 0)
    ' >/dev/null 2>&1 || return 1
  blockers=$(printf '%s' "$snapshot" | jq -r '.labels[]' \
    | mergepath_blocking_labels_csv)
  [ -z "$blockers" ]
}

enrollment_identity_signature() {
  # GitHub may expose the just-consumed autoMergeRequest until the queue entry
  # materializes. Each pending read validates that arm exactly; omit only that
  # transient representation so its expected clear cannot look like PR drift.
  printf '%s' "$1" | jq -ceS \
    'del(.auto_merge,.queue_entry) | .labels |= sort'
}

enqueued_snapshot_signature() {
  printf '%s' "$1" | jq -ceS '
    .queue_entry |= del(.state) | .labels |= sort
  '
}

count_author_entry_attestations() {
  [ "$#" -eq 3 ] || return 1
  local markers="$1" entry_id="$2" queue_event_id="$3"
  printf '%s' "$markers" | jq -er \
    --arg author "$AUTHOR_IDENTITY" --arg repo "$REPO" \
    --argjson pr "$PR_NUMBER" --arg head "$EVENT_HEAD_SHA" \
    --arg entry "$entry_id" --arg queue_event "$queue_event_id" '
      [.[] | select(.kind == "queue-entry-attestation" and
        ._comment_author == $author and
        (.queue_entry_id == $entry or .queue_event_id == $queue_event))] |
      length
    '
}

read_admin_topology() {
  GH_TOKEN="$POLICY_TOKEN" \
    MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN="$SOURCE_TOKEN" \
    mergepath_merge_queue_read_topology "$REPO" "$DEFAULT_BRANCH" \
      "$REPOSITORY_RULESET_ID" "$WORKFLOW_RULESET_ID" \
      "$WORKFLOW_REPOSITORY_ID"
}

record_entry_attestation() {
  local initial="$1" topology queue_id queue_config queue_method
  local topology_signature topology_sha timeline action comments markers
  local entry_id enqueued_at existing conflict_count final final_topology
  local final_timeline final_action created payload encoded body request_file
  local posted comment_id readback wait_snapshot wait_topology
  local action_interval action_max_interval action_attempts action_attempt
  local default_action_attempts
  local check_timeout_minutes action_rc prewrite_comments prewrite_markers
  local prewrite_existing prewrite_rc post_snapshot post_topology post_timeline
  local post_action post_comments post_markers post_attestation
  local identity_signature entry_signature="" elapsed=0 wait_seconds remaining

  REPOSITORY_RULESET_ID=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
    '.repository_ruleset_id | select(type == "number" and floor == . and . > 0)') \
    || infra "repository queue-ruleset id is unreadable"
  WORKFLOW_RULESET_ID=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
    '.workflow_ruleset_id | select(type == "number" and floor == . and . > 0)') \
    || infra "organization workflow-ruleset id is unreadable"
  WORKFLOW_REPOSITORY_ID=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
    '.workflow_repository_id | select(type == "number" and floor == . and . > 0)') \
    || infra "required-workflow source id is unreadable"

  topology=$(read_admin_topology) \
    || infra "complete post-enqueue administrative topology is unreadable"
  queue_id=$(printf '%s' "$topology" | jq -er \
    '.graph.explicit_queue.id | select(type == "string" and length > 0)') \
    || die "default branch has no exact queue id"
  queue_config=$(printf '%s' "$topology" | jq -ec \
    '.graph.explicit_queue.configuration | select(type == "object")') \
    || die "default branch queue configuration is unreadable"
  mergepath_merge_queue_validate_topology "$topology" "$REPO" \
    "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$EVENT_BASE_SHA" "$queue_id" \
    "$queue_config" "$ROLLOUT_CONFIG" \
    || die "post-enqueue topology is not the exact no-bypass, protected-environment contract"
  queue_method=$(printf '%s' "$queue_config" | jq -er .mergeMethod) \
    || infra "queue merge method is unreadable"
  topology_signature=$(mergepath_merge_queue_topology_signature "$topology") \
    || infra "could not canonicalize the administrative topology"
  topology_sha=$(sha256_text "$topology_signature") \
    || infra "could not fingerprint the administrative topology"
  printf '%s' "$topology_sha" | grep -Eq '^[0-9a-f]{64}$' \
    || infra "administrative topology fingerprint is malformed"

  # The pull_request_target enqueued event, MergeQueueEntry, and GraphQL
  # timeline are eventually consistent. Retry a missing entry or action with
  # exponential backoff only while the immutable PR identity remains exact.
  # The expensive private topology is sampled periodically and then reread in
  # full immediately before and after the write.
  check_timeout_minutes=$(printf '%s' "$topology" | jq -er '
    .repository_ruleset.rules[0].parameters.check_response_timeout_minutes |
    select(type == "number" and floor == . and . > 0)
  ') || infra "queue check-response timeout is unreadable"
  action_interval=${MERGEPATH_MERGE_QUEUE_ATTESTATION_INTERVAL_SECONDS:-5}
  case "$action_interval" in *[!0-9]*|'') infra "entry-action interval is malformed" ;; esac
  [ "$action_interval" -le 60 ] || infra "entry-action wait is outside the bounded policy"
  action_max_interval=${MERGEPATH_MERGE_QUEUE_ATTESTATION_MAX_INTERVAL_SECONDS:-60}
  case "$action_max_interval" in *[!0-9]*|'') infra "entry-action max interval is malformed" ;; esac
  [ "$action_interval" -le "$action_max_interval" ] \
    && [ "$action_max_interval" -le 300 ] \
    || infra "entry-action max interval is outside the bounded policy"
  if [ "$action_interval" -eq 0 ]; then
    default_action_attempts=1
  else
    default_action_attempts=100000
  fi
  action_attempts=${MERGEPATH_MERGE_QUEUE_ATTESTATION_ATTEMPTS:-$default_action_attempts}
  case "$action_attempts" in *[!0-9]*|'') infra "entry-action attempts are malformed" ;; esac
  [ "$action_attempts" -gt 0 ] && [ "$action_attempts" -le 100000 ] \
    || infra "entry-action wait is outside the bounded policy"
  if validate_enqueued_snapshot "$initial" "$queue_id"; then
    :
  else
    validate_pending_enqueued_snapshot "$initial" "$queue_method" \
      || die "live PR is not the exact unarmed, blocker-free enrollment event"
  fi
  identity_signature=$(enrollment_identity_signature "$initial") \
    || infra "could not canonicalize the enrollment identity"
  action_attempt=1
  action=""
  wait_seconds=$action_interval
  while [ "$action_attempt" -le "$action_attempts" ]; do
    if [ "$action_attempt" -eq 1 ]; then
      wait_snapshot=$initial
    else
      wait_snapshot=$(read_live_snapshot) \
        || infra "could not re-read the pending queue entry"
    fi
    [ "$(enrollment_identity_signature "$wait_snapshot")" = \
      "$identity_signature" ] \
      || die "PR identity changed while awaiting its queue entry"
    if printf '%s' "$wait_snapshot" | jq -e '.queue_entry != null' \
        >/dev/null 2>&1; then
      validate_enqueued_snapshot "$wait_snapshot" "$queue_id" \
        || die "queue entry became unsafe while awaiting its timeline event"
      if [ -z "$entry_signature" ]; then
        initial=$wait_snapshot
        entry_signature=$(enqueued_snapshot_signature "$initial") \
          || infra "could not canonicalize the queue entry"
        entry_id=$(printf '%s' "$initial" | jq -er \
          '.queue_entry.id | select(type == "string" and length > 0)') \
          || infra "live queue entry id is unreadable"
        enqueued_at=$(printf '%s' "$initial" | jq -er \
          '.queue_entry.enqueued_at') \
          || infra "live queue entry timestamp is unreadable"
      else
        [ "$(enqueued_snapshot_signature "$wait_snapshot")" = \
          "$entry_signature" ] \
          || die "queue-entry identity changed while awaiting its timeline event"
      fi
      timeline=$(mergepath_merge_queue_read_auth_timeline "$REPO" "$PR_NUMBER") \
        || infra "could not read the complete queue-action timeline"
      set +e
      action=$(mergepath_merge_queue_select_entry_action "$timeline" "$REPO" \
        "$PR_NUMBER" "$AUTHOR_IDENTITY" "$queue_id" "$enqueued_at" \
        "$ACTIVATED_AT" "$queue_method")
      action_rc=$?
      set -e
      if [ "$action_rc" -eq 0 ] && [ -n "$action" ]; then
        break
      fi
    else
      validate_pending_enqueued_snapshot "$wait_snapshot" "$queue_method" \
        || die "PR became unsafe before its queue entry appeared"
    fi
    [ "$action_attempt" -lt "$action_attempts" ] \
      && [ "$elapsed" -lt $((check_timeout_minutes * 60)) ] \
      || die "current queue entry has no fresh governing-author action"
    if [ $((action_attempt % 10)) -eq 0 ]; then
      wait_topology=$(read_admin_topology) \
        || infra "could not periodically re-read queue topology"
      mergepath_merge_queue_validate_topology "$wait_topology" "$REPO" \
        "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$EVENT_BASE_SHA" "$queue_id" \
        "$queue_config" "$ROLLOUT_CONFIG" \
        || die "administrative topology became unsafe while awaiting the queue event"
      [ "$(mergepath_merge_queue_topology_signature "$wait_topology")" = \
        "$topology_signature" ] \
        || die "administrative topology changed while awaiting the queue event"
    fi
    remaining=$((check_timeout_minutes * 60 - elapsed))
    [ "$wait_seconds" -le "$remaining" ] || wait_seconds=$remaining
    sleep "$wait_seconds"
    elapsed=$((elapsed + wait_seconds))
    if [ "$wait_seconds" -gt 0 ] \
        && [ "$wait_seconds" -lt "$action_max_interval" ]; then
      wait_seconds=$((wait_seconds * 2))
      [ "$wait_seconds" -le "$action_max_interval" ] \
        || wait_seconds=$action_max_interval
    fi
    action_attempt=$((action_attempt + 1))
  done
  comments=$(fetch_comments) \
    || infra "could not read complete queue-attestation history"
  markers=$(mergepath_merge_queue_decode_authorizations "$comments") \
    || infra "could not decode queue-attestation history"
  set +e
  existing=$(mergepath_merge_queue_select_entry_attestation "$markers" \
    "$action" "$REPO" "$PR_NUMBER" "$EVENT_HEAD_SHA" "$DEFAULT_BRANCH" \
    "$AUTHOR_IDENTITY" "$queue_id" "$entry_id" "$enqueued_at" \
    "$queue_method" "$EVENT_BASE_SHA" "$ROLLOUT_CONFIG")
  existing_rc=$?
  set -e
  conflict_count=$(count_author_entry_attestations "$markers" "$entry_id" \
    "$(printf '%s' "$action" | jq -r .queue_event_id)") \
    || infra "could not classify existing queue-entry attestations"
  if [ "$existing_rc" -eq 0 ] && [ -n "$existing" ]; then
    [ "$conflict_count" -eq 1 ] \
      || die "queue entry has a duplicate or malformed attestation"
    echo "record-merge-queue-authorization: PASS — exact queue-entry attestation already recorded"
    return 0
  fi
  [ "$conflict_count" -eq 0 ] \
    || die "queue entry has a duplicate or malformed attestation"

  # Re-read the exact entry, timeline, and full admin topology immediately
  # before the only write. A dequeue/re-enqueue changes the entry/event ids;
  # ruleset, environment, or secret-placement drift changes the topology.
  final=$(read_live_snapshot) || infra "could not re-read the live queue entry"
  validate_enqueued_snapshot "$final" "$queue_id" \
    || die "queue entry changed before attestation"
  [ "$(enqueued_snapshot_signature "$final")" = \
    "$(enqueued_snapshot_signature "$initial")" ] \
    || die "queue-entry identity or safety state changed during attestation"
  final_topology=$(read_admin_topology) \
    || infra "could not re-read final administrative topology"
  mergepath_merge_queue_validate_topology "$final_topology" "$REPO" \
    "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$EVENT_BASE_SHA" "$queue_id" \
    "$queue_config" "$ROLLOUT_CONFIG" \
    || die "administrative topology changed before attestation"
  [ "$(mergepath_merge_queue_topology_signature "$final_topology")" = \
    "$topology_signature" ] || die "administrative topology changed during attestation"
  final_timeline=$(mergepath_merge_queue_read_auth_timeline "$REPO" "$PR_NUMBER") \
    || infra "could not re-read final queue-action timeline"
  final_action=$(mergepath_merge_queue_select_entry_action "$final_timeline" \
    "$REPO" "$PR_NUMBER" "$AUTHOR_IDENTITY" "$queue_id" "$enqueued_at" \
    "$ACTIVATED_AT" "$queue_method") \
    || die "governing queue action changed before attestation"
  [ "$(printf '%s' "$final_action" | jq -cS .)" = \
    "$(printf '%s' "$action" | jq -cS .)" ] \
    || die "governing queue action changed during attestation"

  # Close the common replay window before rendering the write. A concurrent
  # trusted run that already posted the unique exact proof wins; malformed or
  # duplicate author proofs remain fail-closed.
  prewrite_comments=$(fetch_comments) \
    || infra "could not re-read queue-attestation history before the write"
  prewrite_markers=$(mergepath_merge_queue_decode_authorizations \
    "$prewrite_comments") || infra "could not decode pre-write attestations"
  set +e
  prewrite_existing=$(mergepath_merge_queue_select_entry_attestation \
    "$prewrite_markers" "$action" "$REPO" "$PR_NUMBER" "$EVENT_HEAD_SHA" \
    "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$queue_id" "$entry_id" \
    "$enqueued_at" "$queue_method" "$EVENT_BASE_SHA" "$ROLLOUT_CONFIG")
  prewrite_rc=$?
  set -e
  conflict_count=$(count_author_entry_attestations "$prewrite_markers" \
    "$entry_id" "$(printf '%s' "$action" | jq -r .queue_event_id)") \
    || infra "could not classify pre-write queue-entry attestations"
  if [ "$prewrite_rc" -eq 0 ] && [ -n "$prewrite_existing" ]; then
    [ "$conflict_count" -eq 1 ] \
      || die "queue entry gained a duplicate or malformed attestation before the write"
    echo "record-merge-queue-authorization: PASS — exact queue-entry attestation already recorded"
    return 0
  fi
  [ "$conflict_count" -eq 0 ] \
    || die "queue entry gained a duplicate or malformed attestation before the write"

  created=$(date -u '+%Y-%m-%dT%H:%M:%SZ') \
    || infra "could not read attestation clock"
  payload=$(jq -cnS --arg schema "$MERGEPATH_MERGE_QUEUE_AUTH_SCHEMA" \
    --arg repo "$REPO" --argjson pr "$PR_NUMBER" \
    --arg head "$EVENT_HEAD_SHA" --arg base_ref "$DEFAULT_BRANCH" \
    --arg entry_base "$EVENT_BASE_SHA" --arg queue "$queue_id" \
    --arg entry "$entry_id" --arg method "$queue_method" \
    --arg topology_sha "$topology_sha" --arg created "$created" \
    --argjson action "$action" --argjson rollout "$ROLLOUT_CONFIG" '{
      schema:$schema,kind:"queue-entry-attestation",repository:$repo,pr:$pr,
      head:$head,base_ref:$base_ref,entry_base:$entry_base,
      queue_id:$queue,queue_entry_id:$entry,
      queue_event_id:$action.queue_event_id,
      queue_event_created_at:$action.queue_event_created_at,
      authorization_kind:$action.kind,
      action_event_id:$action.action_event_id,
      action_event_created_at:$action.action_event_created_at,
      merge_method:$method,
      repository_ruleset_id:$rollout.repository_ruleset_id,
      workflow_ruleset_id:$rollout.workflow_ruleset_id,
      workflow_repository_id:$rollout.workflow_repository_id,
      workflow_ref:$rollout.workflow_ref,workflow_sha:$rollout.workflow_sha,
      environment:"merge-queue-policy",topology_sha256:$topology_sha,
      created_at:$created
    }') || infra "could not build queue-entry attestation"
  encoded=$(printf '%s' "$payload" | jq -Rr '@base64') \
    || infra "could not encode queue-entry attestation"
  body=$(jq -nr --arg encoded "$encoded" --arg head "$EVENT_HEAD_SHA" \
    --arg entry "$entry_id" '
      "<!-- mergepath-merge-queue-authorization:v1 " + $encoded + " -->\n" +
      "**Merge queue entry attested.** Exact head `" + $head +
      "` is bound to queue entry `" + $entry + "` after the live admin audit."
    ') || infra "could not render queue-entry attestation"
  request_file=$(mktemp) || infra "could not create attestation request file"
  trap 'rm -f "$request_file"' EXIT
  jq -cn --arg body "$body" '{body:$body}' > "$request_file"
  posted=$(GH_AS_AUTHOR_IDENTITY="$AUTHOR_IDENTITY" \
    "$ROOT/scripts/gh-as-author.sh" -- gh api --method POST \
      "repos/$REPO/issues/$PR_NUMBER/comments" --input "$request_file") \
    || infra "author-attributed queue-entry attestation failed"
  comment_id=$(printf '%s' "$posted" | jq -er \
    '.id | select(type == "number" and . > 0)') \
    || infra "attestation write returned no comment id"
  readback=$(gh api "repos/$REPO/issues/comments/$comment_id") \
    || infra "could not read back queue-entry attestation"
  printf '%s' "$readback" | jq -e --arg author "$AUTHOR_IDENTITY" \
    --arg body "$body" '.user.login == $author and .body == $body' \
    >/dev/null 2>&1 || infra "queue-entry attestation readback did not match"

  # A successful POST is not a successful attestation until the exact entry,
  # action, topology, and complete author-comment set are still singular.
  post_snapshot=$(read_live_snapshot) \
    || infra "could not read the post-write queue entry"
  validate_enqueued_snapshot "$post_snapshot" "$queue_id" \
    || die "queue entry became unsafe after attestation"
  [ "$(enqueued_snapshot_signature "$post_snapshot")" = \
    "$(enqueued_snapshot_signature "$initial")" ] \
    || die "queue-entry identity changed during the attestation write"
  post_topology=$(read_admin_topology) \
    || infra "could not read the post-write administrative topology"
  mergepath_merge_queue_validate_topology "$post_topology" "$REPO" \
    "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$EVENT_BASE_SHA" "$queue_id" \
    "$queue_config" "$ROLLOUT_CONFIG" \
    || die "administrative topology became unsafe after attestation"
  [ "$(mergepath_merge_queue_topology_signature "$post_topology")" = \
    "$topology_signature" ] \
    || die "administrative topology changed during the attestation write"
  post_timeline=$(mergepath_merge_queue_read_auth_timeline "$REPO" "$PR_NUMBER") \
    || infra "could not read the post-write queue-action timeline"
  post_action=$(mergepath_merge_queue_select_entry_action "$post_timeline" \
    "$REPO" "$PR_NUMBER" "$AUTHOR_IDENTITY" "$queue_id" "$enqueued_at" \
    "$ACTIVATED_AT" "$queue_method") \
    || die "governing queue action became unsafe after attestation"
  [ "$(printf '%s' "$post_action" | jq -cS .)" = \
    "$(printf '%s' "$action" | jq -cS .)" ] \
    || die "governing queue action changed during the attestation write"
  post_comments=$(fetch_comments) \
    || infra "could not read complete post-write attestation history"
  post_markers=$(mergepath_merge_queue_decode_authorizations "$post_comments") \
    || infra "could not decode post-write attestation history"
  post_attestation=$(mergepath_merge_queue_select_entry_attestation \
    "$post_markers" "$action" "$REPO" "$PR_NUMBER" "$EVENT_HEAD_SHA" \
    "$DEFAULT_BRANCH" "$AUTHOR_IDENTITY" "$queue_id" "$entry_id" \
    "$enqueued_at" "$queue_method" "$EVENT_BASE_SHA" "$ROLLOUT_CONFIG") \
    || die "queue-entry attestation is not unique after the write"
  conflict_count=$(count_author_entry_attestations "$post_markers" "$entry_id" \
    "$(printf '%s' "$action" | jq -r .queue_event_id)") \
    || infra "could not classify post-write queue-entry attestations"
  [ "$conflict_count" -eq 1 ] \
    || die "queue entry has duplicate or malformed attestations after the write"
  [ "$(printf '%s' "$post_attestation" | jq -r ._comment_id)" = \
    "$comment_id" ] || die "a concurrent attestation won the write race"
  rm -f "$request_file"
  trap - EXIT
  echo "record-merge-queue-authorization: PASS — attested queue entry $entry_id"
}

initial=$(read_live_snapshot) || infra "could not read complete live PR state"
if [ "$EVENT_ACTION" = "enqueued" ]; then
  record_entry_attestation "$initial"
  exit 0
fi
validate_live_snapshot "$initial" \
  || die "live PR no longer matches the exact governing-author arm event"
EVENT_ENABLED_AT=$(printf '%s' "$initial" | jq -er .auto_merge.enabledAt) \
  || infra "live native arm has no enabledAt"
EVENT_MERGE_METHOD=$(printf '%s' "$initial" | jq -er .auto_merge.mergeMethod) \
  || infra "live native arm has no merge method"
jq -en --arg event "$EVENT_ENABLED_AT" --arg activated "$ACTIVATED_AT" '
  try (($event | fromdateiso8601) >= ($activated | fromdateiso8601))
  catch false
' >/dev/null 2>&1 || die "native arm predates the rollout activation epoch"
if [ "$ROLLOUT_ROLE" = "enabled" ]; then
  PR_CREATED_AT=$(printf '%s' "$initial" | jq -er .created_at) \
    || infra "live PR has no creation timestamp"
  jq -en --arg created "$PR_CREATED_AT" --arg activated "$ACTIVATED_AT" '
    try (($created | fromdateiso8601) >= ($activated | fromdateiso8601))
    catch false
  ' >/dev/null 2>&1 || die "PR predates the enabled rollout epoch"
fi
LIVE_BASE=$(printf '%s' "$initial" | jq -r .base_sha)
sha_like "$LIVE_BASE" || infra "live base SHA is malformed"
require_base_lineage "$LIVE_BASE" \
  || die "live base is not descended from the event base"
timeline=$(mergepath_merge_queue_read_auth_timeline "$REPO" "$PR_NUMBER") \
  || infra "could not read complete authorization timeline"
SOURCE=$(mergepath_merge_queue_select_source_auto_event "$timeline" "$REPO" \
  "$PR_NUMBER" "$EVENT_ENABLED_AT" "$AUTHOR_IDENTITY" "$EVENT_MERGE_METHOD") \
  || die "arm event was superseded by a blocker or newer arm"
SOURCE_ID=$(printf '%s' "$SOURCE" | jq -r .id)
SOURCE_AT=$(printf '%s' "$SOURCE" | jq -r .created_at)

comments=$(fetch_comments) || infra "could not read complete authorization comments"
markers=$(mergepath_merge_queue_decode_authorizations "$comments") \
  || infra "could not decode authorization comments"
exact_count=$(printf '%s' "$markers" | jq -r \
  --arg author "$AUTHOR_IDENTITY" --arg repo "$REPO" \
  --argjson pr "$PR_NUMBER" --arg head "$EVENT_HEAD_SHA" \
  --arg base_ref "$DEFAULT_BRANCH" --arg base "$EVENT_BASE_SHA" \
  --arg source "$SOURCE_ID" --arg source_at "$SOURCE_AT" \
  --arg method "$EVENT_MERGE_METHOD" '
    def timestamp:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    [.[] | select(
      ._comment_author == $author and
      (._comment_id | type == "number" and floor == . and . > 0) and
      (._comment_created_at | timestamp) and
      .kind == "auto-merge-authorization" and
      .repository == $repo and .pr == $pr and .head == $head and
      .base_ref == $base_ref and .authorized_base == $base and
      .enabled_by == $author and .merge_method == $method and
      .source_event_id == $source and .source_event_created_at == $source_at and
      (.created_at | timestamp) and
      ((.created_at | fromdateiso8601) >= ($source_at | fromdateiso8601)) and
      ((._comment_created_at | fromdateiso8601) >=
        ($source_at | fromdateiso8601))
    )] | length
  ') || infra "could not classify existing authorizations"
case "$exact_count" in
  1)
    echo "record-merge-queue-authorization: PASS — exact authorization already recorded"
    exit 0
    ;;
  0) ;;
  *) die "exact authorization marker is duplicated" ;;
esac

# Re-read immediately before the only write. Later changes are harmless: the
# merge-group bridge validates this source event and exact head again.
final=$(read_live_snapshot) || infra "could not re-read live PR state"
validate_live_snapshot "$final" \
  || die "live PR changed before authorization could be recorded"
[ "$(printf '%s' "$final" | jq -cS .)" = "$(printf '%s' "$initial" | jq -cS .)" ] \
  || die "mutable PR state changed during authorization"
final_timeline=$(mergepath_merge_queue_read_auth_timeline "$REPO" "$PR_NUMBER") \
  || infra "could not re-read authorization timeline"
FINAL_SOURCE=$(mergepath_merge_queue_select_source_auto_event "$final_timeline" \
  "$REPO" "$PR_NUMBER" "$EVENT_ENABLED_AT" "$AUTHOR_IDENTITY" \
  "$EVENT_MERGE_METHOD") \
  || die "arm event was superseded before authorization could be recorded"
[ "$(printf '%s' "$FINAL_SOURCE" | jq -cS .)" = \
  "$(printf '%s' "$SOURCE" | jq -cS .)" ] \
  || die "source arm event changed during authorization"

CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  || infra "could not read authorization clock"
PAYLOAD=$(jq -cnS --arg schema "$MERGEPATH_MERGE_QUEUE_AUTH_SCHEMA" \
  --arg repo "$REPO" --argjson pr "$PR_NUMBER" --arg head "$EVENT_HEAD_SHA" \
  --arg base_ref "$DEFAULT_BRANCH" --arg base "$EVENT_BASE_SHA" \
  --arg author "$AUTHOR_IDENTITY" --arg method "$EVENT_MERGE_METHOD" \
  --arg source "$SOURCE_ID" \
  --arg source_at "$SOURCE_AT" --arg created "$CREATED_AT" '{
    schema:$schema,kind:"auto-merge-authorization",repository:$repo,pr:$pr,
    head:$head,base_ref:$base_ref,authorized_base:$base,
    enabled_by:$author,merge_method:$method,source_event_id:$source,
    source_event_created_at:$source_at,created_at:$created
  }') || infra "could not build authorization payload"
ENCODED=$(printf '%s' "$PAYLOAD" | jq -Rr '@base64') \
  || infra "could not encode authorization payload"
BODY=$(jq -nr --arg encoded "$ENCODED" --arg head "$EVENT_HEAD_SHA" \
  --arg source "$SOURCE_ID" '
    "<!-- mergepath-merge-queue-authorization:v1 " + $encoded + " -->\n" +
    "**Merge queue authorization recorded.** Exact head `" + $head +
    "` is bound to native auto-merge event `" + $source + "`."
  ') || infra "could not render authorization comment"
REQUEST_FILE=$(mktemp) || infra "could not create authorization request file"
trap 'rm -f "$REQUEST_FILE"' EXIT
jq -cn --arg body "$BODY" '{body:$body}' > "$REQUEST_FILE"
POSTED=$(GH_AS_AUTHOR_IDENTITY="$AUTHOR_IDENTITY" \
  "$ROOT/scripts/gh-as-author.sh" -- gh api --method POST \
    "repos/$REPO/issues/$PR_NUMBER/comments" --input "$REQUEST_FILE") \
  || infra "author-attributed authorization comment failed"
COMMENT_ID=$(printf '%s' "$POSTED" | jq -er '.id | select(type == "number" and . > 0)') \
  || infra "authorization write returned no comment id"
READBACK=$(gh api "repos/$REPO/issues/comments/$COMMENT_ID") \
  || infra "could not read back authorization comment"
printf '%s' "$READBACK" | jq -e --arg author "$AUTHOR_IDENTITY" \
  --arg body "$BODY" '.user.login == $author and .body == $body' \
  >/dev/null 2>&1 || infra "authorization comment readback did not match the write"

echo "record-merge-queue-authorization: PASS — recorded exact head $EVENT_HEAD_SHA"
