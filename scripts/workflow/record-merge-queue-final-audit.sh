#!/usr/bin/env bash
# Record one nonce-bound final administrative audit for a live merge group.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: record-merge-queue-final-audit.sh \
  --dispatch-actor LOGIN --dispatch-action ACTION \
  --dispatch-repository owner/repo --dispatch-default-branch BRANCH \
  --dispatch-ref REF --dispatch-sha SHA \
  --repo owner/repo --pr NUMBER --head-sha SHA \
  --group-head-sha SHA --group-ref REF --base-sha SHA --base-ref BRANCH \
  --queue-id ID --queue-entry-id ID --entry-enqueued-at TIMESTAMP \
  --queue-method METHOD --entry-base-sha SHA --request-nonce HEX \
  --requester-run-id ID --requester-run-attempt NUMBER \
  --requested-at TIMESTAMP --requester-workflow-repository owner/repo \
  --requester-workflow-file-path PATH --requester-workflow-ref REF \
  --requester-workflow-sha SHA --auditor-run-id ID \
  --auditor-run-attempt NUMBER --auditor-workflow-ref REF \
  --auditor-workflow-sha SHA
EOF
  exit 2
}

DISPATCH_ACTOR=""
DISPATCH_ACTION=""
DISPATCH_REPOSITORY=""
DISPATCH_DEFAULT_BRANCH=""
DISPATCH_REF=""
DISPATCH_SHA=""
REPO=""
PR_NUMBER=""
HEAD_SHA=""
GROUP_HEAD_SHA=""
GROUP_REF=""
BASE_SHA=""
BASE_REF=""
QUEUE_ID=""
QUEUE_ENTRY_ID=""
ENTRY_ENQUEUED_AT=""
QUEUE_METHOD=""
ENTRY_BASE_SHA=""
REQUEST_NONCE=""
REQUESTER_RUN_ID=""
REQUESTER_RUN_ATTEMPT=""
REQUESTED_AT=""
REQUESTER_WORKFLOW_REPOSITORY=""
REQUESTER_WORKFLOW_FILE_PATH=""
REQUESTER_WORKFLOW_REF=""
REQUESTER_WORKFLOW_SHA=""
AUDITOR_RUN_ID=""
AUDITOR_RUN_ATTEMPT=""
AUDITOR_WORKFLOW_REF=""
AUDITOR_WORKFLOW_SHA=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dispatch-actor) [ "$#" -ge 2 ] || usage; DISPATCH_ACTOR="$2"; shift 2 ;;
    --dispatch-action) [ "$#" -ge 2 ] || usage; DISPATCH_ACTION="$2"; shift 2 ;;
    --dispatch-repository) [ "$#" -ge 2 ] || usage; DISPATCH_REPOSITORY="$2"; shift 2 ;;
    --dispatch-default-branch) [ "$#" -ge 2 ] || usage; DISPATCH_DEFAULT_BRANCH="$2"; shift 2 ;;
    --dispatch-ref) [ "$#" -ge 2 ] || usage; DISPATCH_REF="$2"; shift 2 ;;
    --dispatch-sha) [ "$#" -ge 2 ] || usage; DISPATCH_SHA="$2"; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; PR_NUMBER="$2"; shift 2 ;;
    --head-sha) [ "$#" -ge 2 ] || usage; HEAD_SHA="$2"; shift 2 ;;
    --group-head-sha) [ "$#" -ge 2 ] || usage; GROUP_HEAD_SHA="$2"; shift 2 ;;
    --group-ref) [ "$#" -ge 2 ] || usage; GROUP_REF="$2"; shift 2 ;;
    --base-sha) [ "$#" -ge 2 ] || usage; BASE_SHA="$2"; shift 2 ;;
    --base-ref) [ "$#" -ge 2 ] || usage; BASE_REF="$2"; shift 2 ;;
    --queue-id) [ "$#" -ge 2 ] || usage; QUEUE_ID="$2"; shift 2 ;;
    --queue-entry-id) [ "$#" -ge 2 ] || usage; QUEUE_ENTRY_ID="$2"; shift 2 ;;
    --entry-enqueued-at) [ "$#" -ge 2 ] || usage; ENTRY_ENQUEUED_AT="$2"; shift 2 ;;
    --queue-method) [ "$#" -ge 2 ] || usage; QUEUE_METHOD="$2"; shift 2 ;;
    --entry-base-sha) [ "$#" -ge 2 ] || usage; ENTRY_BASE_SHA="$2"; shift 2 ;;
    --request-nonce) [ "$#" -ge 2 ] || usage; REQUEST_NONCE="$2"; shift 2 ;;
    --requester-run-id) [ "$#" -ge 2 ] || usage; REQUESTER_RUN_ID="$2"; shift 2 ;;
    --requester-run-attempt) [ "$#" -ge 2 ] || usage; REQUESTER_RUN_ATTEMPT="$2"; shift 2 ;;
    --requested-at) [ "$#" -ge 2 ] || usage; REQUESTED_AT="$2"; shift 2 ;;
    --requester-workflow-repository) [ "$#" -ge 2 ] || usage; REQUESTER_WORKFLOW_REPOSITORY="$2"; shift 2 ;;
    --requester-workflow-file-path) [ "$#" -ge 2 ] || usage; REQUESTER_WORKFLOW_FILE_PATH="$2"; shift 2 ;;
    --requester-workflow-ref) [ "$#" -ge 2 ] || usage; REQUESTER_WORKFLOW_REF="$2"; shift 2 ;;
    --requester-workflow-sha) [ "$#" -ge 2 ] || usage; REQUESTER_WORKFLOW_SHA="$2"; shift 2 ;;
    --auditor-run-id) [ "$#" -ge 2 ] || usage; AUDITOR_RUN_ID="$2"; shift 2 ;;
    --auditor-run-attempt) [ "$#" -ge 2 ] || usage; AUDITOR_RUN_ATTEMPT="$2"; shift 2 ;;
    --auditor-workflow-ref) [ "$#" -ge 2 ] || usage; AUDITOR_WORKFLOW_REF="$2"; shift 2 ;;
    --auditor-workflow-sha) [ "$#" -ge 2 ] || usage; AUDITOR_WORKFLOW_SHA="$2"; shift 2 ;;
    *) usage ;;
  esac
done

for value in "$DISPATCH_ACTOR" "$DISPATCH_ACTION" "$DISPATCH_REPOSITORY" \
  "$DISPATCH_DEFAULT_BRANCH" "$DISPATCH_REF" "$DISPATCH_SHA" \
  "$REPO" "$PR_NUMBER" "$HEAD_SHA" \
  "$GROUP_HEAD_SHA" "$GROUP_REF" "$BASE_SHA" "$BASE_REF" "$QUEUE_ID" \
  "$QUEUE_ENTRY_ID" "$ENTRY_ENQUEUED_AT" "$QUEUE_METHOD" \
  "$ENTRY_BASE_SHA" "$REQUEST_NONCE" "$REQUESTER_RUN_ID" \
  "$REQUESTER_RUN_ATTEMPT" "$REQUESTED_AT" \
  "$REQUESTER_WORKFLOW_REPOSITORY" "$REQUESTER_WORKFLOW_FILE_PATH" \
  "$REQUESTER_WORKFLOW_REF" "$REQUESTER_WORKFLOW_SHA" "$AUDITOR_RUN_ID" \
  "$AUDITOR_RUN_ATTEMPT" "$AUDITOR_WORKFLOW_REF" "$AUDITOR_WORKFLOW_SHA"; do
  [ -n "$value" ] || usage
done

die() {
  echo "record-merge-queue-final-audit: FAIL — $*" >&2
  exit 1
}

infra() {
  echo "record-merge-queue-final-audit: ERROR — $*" >&2
  exit 2
}

sha_like() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$'
}

timestamp_like() {
  printf '%s' "$1" | grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

canonical_positive_integer() {
  case "$1" in
    ''|0*|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
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

case "$REPO" in */*) ;; *) usage ;; esac
REPO_OWNER=${REPO%%/*}
REPO_NAME=${REPO#*/}
case "$REPO_OWNER:$REPO_NAME" in :*|*:|*:*/*) usage ;; esac
canonical_positive_integer "$PR_NUMBER" || usage
canonical_positive_integer "$REQUESTER_RUN_ID" || usage
canonical_positive_integer "$REQUESTER_RUN_ATTEMPT" || usage
canonical_positive_integer "$AUDITOR_RUN_ID" || usage
canonical_positive_integer "$AUDITOR_RUN_ATTEMPT" || usage
if ! sha_like "$DISPATCH_SHA" || ! sha_like "$HEAD_SHA" \
    || ! sha_like "$GROUP_HEAD_SHA" \
    || ! sha_like "$BASE_SHA" || ! sha_like "$ENTRY_BASE_SHA" \
    || ! sha_like "$REQUESTER_WORKFLOW_SHA" \
    || ! sha_like "$AUDITOR_WORKFLOW_SHA"; then
  usage
fi
if ! timestamp_like "$ENTRY_ENQUEUED_AT" \
    || ! timestamp_like "$REQUESTED_AT"; then
  usage
fi
printf '%s' "$REQUEST_NONCE" | grep -Eq '^[0-9a-f]{64}$' || usage
case "$QUEUE_METHOD" in MERGE|SQUASH|REBASE) ;; *) usage ;; esac
git check-ref-format "$GROUP_REF" >/dev/null 2>&1 || usage
case "$GROUP_REF" in
  "refs/heads/gh-readonly-queue/main/pr-$PR_NUMBER-"*) ;;
  *) usage ;;
esac

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
for tool in gh jq git date; do
  command -v "$tool" >/dev/null 2>&1 \
    || infra "required tool '$tool' is unavailable"
done
for path in \
  "$ROOT/.github/review-policy.yml" \
  "$ROOT/scripts/gh-as-author.sh" \
  "$ROOT/scripts/lib/blocking-labels.sh" \
  "$ROOT/scripts/lib/gh-api-array.sh" \
  "$ROOT/scripts/lib/merge-queue-authorization.sh" \
  "$ROOT/scripts/lib/merge-queue-protection.sh" \
  "$ROOT/scripts/lib/review-policy-scalar.sh"; do
  [ -r "$path" ] || infra "required policy component is unavailable: $path"
done
[ -x "$ROOT/scripts/gh-as-author.sh" ] \
  || infra "identity-checked author wrapper is not executable"

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
[ "$DISPATCH_ACTOR" = 'github-actions[bot]' ] \
  || die "dispatch actor is not github-actions[bot]"
[ "$DISPATCH_ACTION" = 'mergepath-final-queue-audit' ] \
  || die "dispatch action is not the final-audit event"
[ "$DISPATCH_REPOSITORY" = "$REPO" ] \
  && [ "$DISPATCH_DEFAULT_BRANCH" = main ] \
  && [ "$DISPATCH_REF" = refs/heads/main ] \
  && [ "$DISPATCH_SHA" = "$BASE_SHA" ] \
  && [ "$BASE_REF" = main ] \
  || die "dispatch repository or default branch is outside the supported target"

CHECKOUT_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) \
  || infra "could not identify the trusted checkout"
[ "$CHECKOUT_SHA" = "$BASE_SHA" ] \
  || die "trusted checkout is $CHECKOUT_SHA, expected authenticated base $BASE_SHA"
EXPECTED_AUDITOR_REF="$REPO/.github/workflows/merge-queue-final-audit.yml@refs/heads/main"
[ "$AUDITOR_WORKFLOW_REF" = "$EXPECTED_AUDITOR_REF" ] \
  && [ "$AUDITOR_WORKFLOW_SHA" = "$BASE_SHA" ] \
  || die "auditor workflow identity is not the exact target-base definition"

AUTHOR_TOKEN=${GH_TOKEN:-}
POLICY_TOKEN=${MERGEPATH_MERGE_QUEUE_POLICY_TOKEN:-}
SOURCE_TOKEN=${MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN:-}
[ -n "$AUTHOR_TOKEN" ] && [ -n "$POLICY_TOKEN" ] && [ -n "$SOURCE_TOKEN" ] \
  || infra "protected author, queue-policy, and queue-source credentials are required"
[ "${OP_PREFLIGHT_AUTHOR_PAT:-}" = "$AUTHOR_TOKEN" ] \
  || infra "author wrapper credential does not match GH_TOKEN"
[ "$AUTHOR_TOKEN" != "$POLICY_TOKEN" ] \
  && [ "$AUTHOR_TOKEN" != "$SOURCE_TOKEN" ] \
  && [ "$POLICY_TOKEN" != "$SOURCE_TOKEN" ] \
  || infra "author, queue-policy, and queue-source credentials must be pairwise value-distinct"
AUTHOR_LOGIN=$(gh api user --jq .login) || infra "could not verify author token"
POLICY_LOGIN=$(GH_TOKEN="$POLICY_TOKEN" gh api user --jq .login) \
  || infra "could not verify queue-policy token"
SOURCE_LOGIN=$(GH_TOKEN="$SOURCE_TOKEN" gh api user --jq .login) \
  || infra "could not verify queue-source token"
[ "$AUTHOR_LOGIN" = "$AUTHOR_IDENTITY" ] \
  && [ "$POLICY_LOGIN" = "$AUTHOR_IDENTITY" ] \
  && [ "$SOURCE_LOGIN" = "$AUTHOR_IDENTITY" ] \
  || infra "all three protected credentials must resolve to $AUTHOR_IDENTITY"

ROLLOUT_CONFIG=$(mergepath_merge_queue_rollout_config \
  "$ROOT/.github/review-policy.yml") \
  || infra "merge-queue rollout configuration is malformed"
ACTIVATED_AT=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
  '.enabled_at | select(type == "string" and length > 0)') \
  || infra "merge-queue activation instant is unavailable"
REPOSITORY_RULESET_ID=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
  '.repository_ruleset_id | select(type == "number" and floor == . and . > 0)') \
  || infra "repository queue-ruleset id is unreadable"
WORKFLOW_RULESET_ID=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
  '.workflow_ruleset_id | select(type == "number" and floor == . and . > 0)') \
  || infra "organization workflow-ruleset id is unreadable"
WORKFLOW_REPOSITORY_ID=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
  '.workflow_repository_id | select(type == "number" and floor == . and . > 0)') \
  || infra "required-workflow source id is unreadable"

GH_TOKEN="$POLICY_TOKEN" mergepath_merge_queue_validate_required_workflow \
  "$ROLLOUT_CONFIG" "$REPO" "$REQUESTER_WORKFLOW_REPOSITORY" \
  "$REQUESTER_WORKFLOW_FILE_PATH" "$REQUESTER_WORKFLOW_REF" \
  "$REQUESTER_WORKFLOW_SHA" \
  || die "requester workflow identity does not match the active organization rule"

NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || infra "could not read audit clock"
mergepath_merge_queue_rollout_is_active "$ROLLOUT_CONFIG" "$NOW" \
  || die "merge-queue rollout is not active at the audit instant"
jq -en --arg requested "$REQUESTED_AT" --arg now "$NOW" \
  --arg activated "$ACTIVATED_AT" '
    try (($requested | fromdateiso8601) <= ($now | fromdateiso8601) and
      ($requested | fromdateiso8601) >= ($activated | fromdateiso8601))
    catch false
  ' >/dev/null 2>&1 || die "audit request is future-dated or predates activation"

read_requester_run() {
  GH_TOKEN="$POLICY_TOKEN" gh api \
    "repos/$REPO/actions/runs/$REQUESTER_RUN_ID"
}

validate_requester_run() {
  local run="$1" started source_ref source_short_ref
  source_ref=$(printf '%s' "$ROLLOUT_CONFIG" | jq -er \
    '.workflow_ref | select(type == "string" and startswith("refs/heads/"))') \
    || return 1
  source_short_ref=${source_ref#refs/heads/}
  printf '%s' "$run" | jq -e \
    --arg repo "$REPO" --argjson id "$REQUESTER_RUN_ID" \
    --argjson attempt "$REQUESTER_RUN_ATTEMPT" --arg head "$GROUP_HEAD_SHA" \
    --arg branch "${GROUP_REF#refs/heads/}" \
    --arg workflow_ref "$REQUESTER_WORKFLOW_REF" \
    --arg workflow_path "$REQUESTER_WORKFLOW_FILE_PATH" \
    --arg workflow_repository "$REQUESTER_WORKFLOW_REPOSITORY" \
    --arg source_ref "$source_ref" --arg source_short_ref "$source_short_ref" \
    --arg workflow_sha "$REQUESTER_WORKFLOW_SHA" '
      def matching_source_path:
        . == $workflow_ref or
        . == ($workflow_repository + "/" + $workflow_path + "@" +
          $source_short_ref);
      type == "object" and .id == $id and .run_attempt == $attempt and
      .event == "merge_group" and .status == "in_progress" and
      .conclusion == null and .head_sha == $head and .head_branch == $branch and
      .repository.full_name == $repo and .head_repository.full_name == $repo and
      (.referenced_workflows | type == "array" and length > 0) and
      any(.referenced_workflows[];
        (.path | type == "string" and matching_source_path) and
        .sha == $workflow_sha and .ref == $source_ref) and
      all((.referenced_workflows // [])[] | select(.path | matching_source_path);
        .sha == $workflow_sha and .ref == $source_ref) and
      (.run_started_at | type == "string" and length > 0)
    ' >/dev/null 2>&1 || return 1
  started=$(printf '%s' "$run" | jq -er .run_started_at) || return 1
  jq -en --arg started "$started" --arg requested "$REQUESTED_AT" '
    try (($started | fromdateiso8601) <= ($requested | fromdateiso8601))
    catch false
  ' >/dev/null 2>&1
}

read_auditor_run() {
  local run_id="$1" attempt="$2"
  if [ "$run_id" = "$AUDITOR_RUN_ID" ] \
      && [ "$attempt" = "$AUDITOR_RUN_ATTEMPT" ]; then
    GH_TOKEN="$POLICY_TOKEN" gh api "repos/$REPO/actions/runs/$run_id"
  else
    GH_TOKEN="$POLICY_TOKEN" gh api \
      "repos/$REPO/actions/runs/$run_id/attempts/$attempt"
  fi
}

validate_auditor_run() {
  local run="$1" run_id="$2" attempt="$3" workflow_ref="$4"
  local workflow_sha="$5" mode="$6" marker_created="${7:-}"
  local marker_comment_created="${8:-}"
  printf '%s' "$run" | jq -e \
    --arg repo "$REPO" --argjson id "$run_id" --argjson attempt "$attempt" \
    --arg sha "$workflow_sha" --arg branch main \
    --arg path '.github/workflows/merge-queue-final-audit.yml' \
    --arg workflow_ref "$workflow_ref" --arg mode "$mode" \
    --arg requested "$REQUESTED_AT" --arg marker_created "$marker_created" \
    --arg marker_comment_created "$marker_comment_created" '
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def matching_path:
        . == $path or . == ($path + "@refs/heads/main") or
        . == $workflow_ref;
      type == "object" and .id == $id and .run_attempt == $attempt and
      .event == "repository_dispatch" and .repository.full_name == $repo and
      .head_repository.full_name == $repo and .head_branch == $branch and
      .head_sha == $sha and (.path | matching_path) and
      .actor.login == "github-actions[bot]" and
      .triggering_actor.login == "github-actions[bot]" and
      (.created_at as $created | .run_started_at as $started |
        ($created | timestamp) and ($started | timestamp) and
        (try (
          (($created | fromdateiso8601) >=
            ($requested | fromdateiso8601)) and
          (($started | fromdateiso8601) >=
            ($requested | fromdateiso8601)) and
          (if $marker_created == "" and $marker_comment_created == "" then
             true
           else
             ($marker_created | timestamp) and
             ($marker_comment_created | timestamp) and
             (($created | fromdateiso8601) <=
               ($marker_created | fromdateiso8601)) and
             (($started | fromdateiso8601) <=
               ($marker_created | fromdateiso8601)) and
             (($created | fromdateiso8601) <=
               ($marker_comment_created | fromdateiso8601)) and
             (($started | fromdateiso8601) <=
               ($marker_comment_created | fromdateiso8601))
           end)
        ) catch false)) and
      (if $mode == "current" then
         .status == "in_progress" and .conclusion == null
       else .status == "completed" and .conclusion == "success" end)
    ' >/dev/null 2>&1
}

REQUESTER_RUN=$(read_requester_run) \
  || infra "could not read the live requester workflow run"
validate_requester_run "$REQUESTER_RUN" \
  || die "requester run is not the exact active merge-group workflow"
AUDITOR_RUN=$(read_auditor_run "$AUDITOR_RUN_ID" "$AUDITOR_RUN_ATTEMPT") \
  || infra "could not read the current auditor workflow run"
validate_auditor_run "$AUDITOR_RUN" "$AUDITOR_RUN_ID" \
  "$AUDITOR_RUN_ATTEMPT" "$AUDITOR_WORKFLOW_REF" "$AUDITOR_WORKFLOW_SHA" \
  current || die "auditor run is not the exact protected dispatch responder"

# shellcheck disable=SC2016 # GraphQL variables are intentionally literal.
PR_QUERY='query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    nameWithOwner
    defaultBranchRef{name target{... on Commit{oid}}}
    pullRequest(number:$number){
      id number state isDraft createdAt headRefOid baseRefName baseRefOid
      headRepository{nameWithOwner}
      baseRepository{nameWithOwner defaultBranchRef{name}}
      author{login} stack{id} autoMergeRequest{enabledAt}
      mergeQueueEntry{
        id baseCommit{oid} headCommit{oid} enqueuedAt enqueuer{login}
        jump solo state mergeQueue{id}
      }
    }
  }
}'

fetch_labels() {
  GH_TOKEN="$POLICY_TOKEN" gh_api_array \
    "repos/$REPO/issues/$PR_NUMBER/labels?per_page=100" "PR labels" || {
      echo "$GH_API_ARRAY_ERROR" >&2
      return 1
    }
}

fetch_comments() {
  GH_TOKEN="$POLICY_TOKEN" gh_api_array \
    "repos/$REPO/issues/$PR_NUMBER/comments?per_page=100" \
    "final-audit comments" || {
      echo "$GH_API_ARRAY_ERROR" >&2
      return 1
    }
}

read_pr_snapshot() {
  local raw pr labels
  raw=$(GH_TOKEN="$POLICY_TOKEN" gh api graphql -f query="$PR_QUERY" \
    -f owner="$REPO_OWNER" -f name="$REPO_NAME" -F number="$PR_NUMBER") \
    || return 1
  pr=$(printf '%s' "$raw" | jq -ce '
    select(((.errors // []) | length) == 0) |
    .data.repository as $repo | $repo.pullRequest as $pr |
    select($repo != null and $pr != null) |
    {
      repository:$repo.nameWithOwner,
      live_default:{name:$repo.defaultBranchRef.name,sha:$repo.defaultBranchRef.target.oid},
      id:$pr.id,number:$pr.number,state:$pr.state,draft:$pr.isDraft,
      created_at:$pr.createdAt,head:$pr.headRefOid,
      head_repository:$pr.headRepository.nameWithOwner,
      base_ref:$pr.baseRefName,base_sha:$pr.baseRefOid,
      base_repository:$pr.baseRepository.nameWithOwner,
      default_branch:$pr.baseRepository.defaultBranchRef.name,
      author:$pr.author.login,stack:$pr.stack,auto_merge:$pr.autoMergeRequest,
      queue_entry:(if $pr.mergeQueueEntry == null then null else {
        id:$pr.mergeQueueEntry.id,base:$pr.mergeQueueEntry.baseCommit.oid,
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

validate_pr_snapshot() {
  local snapshot="$1" blockers
  printf '%s' "$snapshot" | jq -e \
    --arg repo "$REPO" --argjson pr "$PR_NUMBER" --arg head "$HEAD_SHA" \
    --arg base "$BASE_SHA" --arg branch "$BASE_REF" \
    --arg author "$AUTHOR_IDENTITY" --arg queue "$QUEUE_ID" \
    --arg entry "$QUEUE_ENTRY_ID" --arg entry_base "$ENTRY_BASE_SHA" \
    --arg enqueued "$ENTRY_ENQUEUED_AT" '
      type == "object" and .repository == $repo and .number == $pr and
      (.id | type == "string" and length > 0) and .state == "OPEN" and
      .draft == false and (.created_at | type == "string" and length > 0) and
      .head == $head and .head_repository == $repo and
      .base_ref == $branch and .base_sha == $base and
      .base_repository == $repo and .default_branch == $branch and
      .live_default == {name:$branch,sha:$base} and .author == $author and
      .stack == null and .auto_merge == null and
      (.queue_entry | type == "object") and .queue_entry.id == $entry and
      .queue_entry.base == $entry_base and .queue_entry.head == $head and
      .queue_entry.enqueued_at == $enqueued and
      .queue_entry.enqueuer == $author and .queue_entry.jump == false and
      (.queue_entry.solo | type == "boolean") and
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

pr_signature() {
  printf '%s' "$1" | jq -ceS '.queue_entry |= del(.state) | .labels |= sort'
}

read_group_ref() {
  GH_TOKEN="$POLICY_TOKEN" gh api \
    "repos/$REPO/git/ref/${GROUP_REF#refs/}" | jq -ce '
      {ref:.ref,object_type:.object.type,object_sha:.object.sha}
    '
}

validate_group_ref() {
  printf '%s' "$1" | jq -e --arg ref "$GROUP_REF" \
    --arg head "$GROUP_HEAD_SHA" '
      .ref == $ref and .object_type == "commit" and .object_sha == $head
    ' >/dev/null 2>&1
}

validate_entry_base_lineage() {
  local compare
  [ "$ENTRY_BASE_SHA" = "$BASE_SHA" ] && return 0
  compare=$(GH_TOKEN="$POLICY_TOKEN" gh api \
    "repos/$REPO/compare/$ENTRY_BASE_SHA...$BASE_SHA") || return 1
  printf '%s' "$compare" | jq -e --arg base "$ENTRY_BASE_SHA" '
    .status == "ahead" and .base_commit.sha == $base and
    .merge_base_commit.sha == $base
  ' >/dev/null 2>&1
}

read_topology() {
  GH_TOKEN="$POLICY_TOKEN" MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN="$SOURCE_TOKEN" \
    mergepath_merge_queue_read_topology "$REPO" "$BASE_REF" \
      "$REPOSITORY_RULESET_ID" "$WORKFLOW_RULESET_ID" \
      "$WORKFLOW_REPOSITORY_ID"
}

validate_rollout_scope() {
  local pr_snapshot="$1" role rc transition
  set +e
  role=$(mergepath_merge_queue_rollout_entry_scope "$ROLLOUT_CONFIG" \
    "$PR_NUMBER" "$HEAD_SHA" "$ENTRY_ENQUEUED_AT" \
    "$(printf '%s' "$pr_snapshot" | jq -r .created_at)")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return 1
  if [ "$role" = promotion ]; then
    transition=$(GH_TOKEN="$POLICY_TOKEN" \
      mergepath_merge_queue_verify_promotion_transition "$ROLLOUT_CONFIG" \
        "$REPO" "$HEAD_SHA") || return 1
    if [ "$transition" = enabled ]; then
      GH_TOKEN="$POLICY_TOKEN" \
        mergepath_merge_queue_verify_promotion_prerequisite "$ROLLOUT_CONFIG" \
          "$REPO" "$BASE_REF" "$AUTHOR_IDENTITY" "$BASE_SHA" || return 1
    fi
  fi
}

read_state() {
  local pr group timeline action topology topology_signature topology_sha
  local queue_config comments markers requester auditor
  pr=$(read_pr_snapshot) || infra "could not read complete live PR/entry state"
  validate_pr_snapshot "$pr" \
    || die "live PR is not the exact standalone, unarmed, blocker-free queue entry"
  validate_rollout_scope "$pr" || die "queue entry is outside the active rollout scope"
  group=$(read_group_ref) || infra "could not read the live merge-group ref"
  validate_group_ref "$group" || die "live merge-group ref does not match the request"
  validate_entry_base_lineage \
    || die "queue-entry base is not an ancestor of the live group base"
  timeline=$(GH_TOKEN="$POLICY_TOKEN" \
    mergepath_merge_queue_read_auth_timeline "$REPO" "$PR_NUMBER") \
    || infra "could not read the complete queue-action timeline"
  action=$(mergepath_merge_queue_select_entry_action "$timeline" "$REPO" \
    "$PR_NUMBER" "$AUTHOR_IDENTITY" "$QUEUE_ID" "$ENTRY_ENQUEUED_AT" \
    "$ACTIVATED_AT" "$QUEUE_METHOD") \
    || die "queue entry has no exact fresh governing-author action"
  topology=$(read_topology) || infra "could not read the complete administrative topology"
  queue_config=$(printf '%s' "$topology" | jq -ec \
    '.graph.explicit_queue.configuration | select(type == "object")') \
    || infra "live merge-queue configuration is unreadable"
  [ "$(printf '%s' "$queue_config" | jq -r .mergeMethod)" = "$QUEUE_METHOD" ] \
    || die "live merge method differs from the request"
  mergepath_merge_queue_validate_topology "$topology" "$REPO" "$BASE_REF" \
    "$AUTHOR_IDENTITY" "$BASE_SHA" "$QUEUE_ID" "$queue_config" \
    "$ROLLOUT_CONFIG" \
    || die "administrative topology is not the active no-bypass contract"
  topology_signature=$(mergepath_merge_queue_topology_signature "$topology") \
    || infra "could not canonicalize the administrative topology"
  topology_sha=$(sha256_text "$topology_signature") \
    || infra "could not fingerprint the administrative topology"
  printf '%s' "$topology_sha" | grep -Eq '^[0-9a-f]{64}$' \
    || infra "administrative topology fingerprint is malformed"
  requester=$(read_requester_run) || infra "could not re-read requester run"
  validate_requester_run "$requester" || die "requester run became unsafe"
  auditor=$(read_auditor_run "$AUDITOR_RUN_ID" "$AUDITOR_RUN_ATTEMPT") \
    || infra "could not re-read current auditor run"
  validate_auditor_run "$auditor" "$AUDITOR_RUN_ID" "$AUDITOR_RUN_ATTEMPT" \
    "$AUDITOR_WORKFLOW_REF" "$AUDITOR_WORKFLOW_SHA" current \
    || die "current auditor run became unsafe"
  comments=$(fetch_comments) || infra "could not read complete final-audit history"
  markers=$(mergepath_merge_queue_decode_authorizations "$comments") \
    || infra "could not decode final-audit history"
  jq -cn --argjson pr "$(pr_signature "$pr")" --argjson group "$group" \
    --argjson action "$action" --argjson topology "$topology_signature" \
    --arg topology_sha "$topology_sha" --argjson comments "$comments" \
    --argjson markers "$markers" '{
      pr:$pr,group:$group,action:$action,topology:$topology,
      topology_sha:$topology_sha,comments:$comments,markers:$markers
    }'
}

state_signature() {
  printf '%s' "$1" | jq -ceS 'del(.comments,.markers)'
}

select_exact_final_audit() {
  local markers="$1" action="$2" auditor_id="$3" auditor_attempt="$4"
  local auditor_ref="$5" auditor_sha="$6"
  mergepath_merge_queue_select_final_audit "$markers" "$action" "$REPO" \
    "$PR_NUMBER" "$HEAD_SHA" "$GROUP_HEAD_SHA" "$GROUP_REF" "$BASE_SHA" \
    "$BASE_REF" "$AUTHOR_IDENTITY" "$QUEUE_ID" "$QUEUE_ENTRY_ID" \
    "$ENTRY_ENQUEUED_AT" "$QUEUE_METHOD" "$ENTRY_BASE_SHA" \
    "$ROLLOUT_CONFIG" "$REQUEST_NONCE" "$REQUESTER_RUN_ID" \
    "$REQUESTER_RUN_ATTEMPT" "$REQUESTED_AT" \
    "$REQUESTER_WORKFLOW_REPOSITORY" "$REQUESTER_WORKFLOW_FILE_PATH" \
    "$REQUESTER_WORKFLOW_REF" "$REQUESTER_WORKFLOW_SHA" "$auditor_id" \
    "$auditor_attempt" "$auditor_ref" "$auditor_sha"
}

count_final_audits() {
  mergepath_merge_queue_count_final_audits "$1" "$REPO" "$PR_NUMBER" \
    "$HEAD_SHA" "$GROUP_HEAD_SHA" "$AUTHOR_IDENTITY" "$REQUEST_NONCE" \
    "$REQUESTER_RUN_ID" "$REQUESTER_RUN_ATTEMPT"
}

# rc 0 means a prior successful responder already wrote the exact proof; rc 1
# means this namespace is empty. Every other same-author marker is a conflict.
EXISTING_AUDIT=""
accept_existing_audit() {
  local state="$1" markers action count candidate auditor_id auditor_attempt
  local auditor_ref auditor_sha marker_created marker_comment_created
  local exact prior_run
  markers=$(printf '%s' "$state" | jq -ec .markers) || return 2
  action=$(printf '%s' "$state" | jq -ec .action) || return 2
  count=$(count_final_audits "$markers") || return 2
  [ "$count" -eq 0 ] && return 1
  [ "$count" -eq 1 ] || die "final-audit namespace contains duplicate author markers"
  candidate=$(printf '%s' "$markers" | jq -ce \
    --arg author "$AUTHOR_IDENTITY" --arg repo "$REPO" \
    --argjson pr "$PR_NUMBER" --arg head "$HEAD_SHA" \
    --arg group_head "$GROUP_HEAD_SHA" --arg nonce "$REQUEST_NONCE" \
    --arg run "$REQUESTER_RUN_ID" --argjson attempt "$REQUESTER_RUN_ATTEMPT" '
      [.[] | select(._comment_author == $author and
        .kind == "final-admin-audit" and .repository == $repo and
        .pr == $pr and .head == $head and .group_head == $group_head and
        (.request_nonce == $nonce or
         (.requester_run_id == $run and
          .requester_run_attempt == $attempt)))] |
      select(length == 1) | .[0]
    ') || die "final-audit namespace contains a malformed author marker"
  auditor_id=$(printf '%s' "$candidate" | jq -er \
    '.auditor_run_id | select(type == "string" and test("^[1-9][0-9]*$"))') \
    || die "existing final audit has a malformed auditor run id"
  auditor_attempt=$(printf '%s' "$candidate" | jq -er \
    '.auditor_run_attempt | select(type == "number" and floor == . and . > 0)') \
    || die "existing final audit has a malformed auditor run attempt"
  auditor_ref=$(printf '%s' "$candidate" | jq -er \
    '.auditor_workflow_ref | select(type == "string" and length > 0)') \
    || die "existing final audit has no auditor workflow ref"
  auditor_sha=$(printf '%s' "$candidate" | jq -er \
    '.auditor_workflow_sha | select(type == "string" and test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$"))') \
    || die "existing final audit has no auditor workflow SHA"
  [ "$auditor_ref" = "$EXPECTED_AUDITOR_REF" ] \
    && [ "$auditor_sha" = "$BASE_SHA" ] \
    || die "existing final audit is not bound to the exact target-base workflow"
  marker_created=$(printf '%s' "$candidate" | jq -er \
    '.created_at | select(type == "string" and length > 0)') \
    || die "existing final audit has no audit time"
  marker_comment_created=$(printf '%s' "$candidate" | jq -er \
    '._comment_created_at | select(type == "string" and length > 0)') \
    || die "existing final audit has no comment time"
  exact=$(select_exact_final_audit "$markers" "$action" "$auditor_id" \
    "$auditor_attempt" "$EXPECTED_AUDITOR_REF" "$BASE_SHA") \
    || die "same nonce or requester run has a conflicting final audit"
  [ "$(printf '%s' "$exact" | jq -r .topology_sha256)" = \
    "$(printf '%s' "$state" | jq -r .topology_sha)" ] \
    || die "existing final audit names a different administrative topology"
  prior_run=$(read_auditor_run "$auditor_id" "$auditor_attempt") \
    || infra "could not read the existing audit's workflow run"
  if [ "$auditor_id" = "$AUDITOR_RUN_ID" ] \
      && [ "$auditor_attempt" = "$AUDITOR_RUN_ATTEMPT" ]; then
    validate_auditor_run "$prior_run" "$auditor_id" "$auditor_attempt" \
      "$EXPECTED_AUDITOR_REF" "$BASE_SHA" current "$marker_created" \
      "$marker_comment_created" \
      || die "existing marker is not bound to this active auditor run"
  else
    validate_auditor_run "$prior_run" "$auditor_id" "$auditor_attempt" \
      "$EXPECTED_AUDITOR_REF" "$BASE_SHA" completed "$marker_created" \
      "$marker_comment_created" \
      || die "existing marker's auditor run did not complete successfully"
  fi
  EXISTING_AUDIT="$exact"
}

INITIAL_STATE=$(read_state)
set +e
accept_existing_audit "$INITIAL_STATE"
existing_rc=$?
set -e
case "$existing_rc" in
  0)
    echo "record-merge-queue-final-audit: PASS — exact nonce-bound audit already recorded in comment $(printf '%s' "$EXISTING_AUDIT" | jq -r ._comment_id)"
    exit 0
    ;;
  1) ;;
  *) infra "could not classify existing final audits" ;;
esac

# Re-read every live binding immediately before the only write. Queue state is
# deliberately omitted from the stable PR signature because GitHub advances it
# asynchronously; entry identity and every safety predicate remain exact.
PREWRITE_STATE=$(read_state)
[ "$(state_signature "$PREWRITE_STATE")" = \
  "$(state_signature "$INITIAL_STATE")" ] \
  || die "queue, group, action, or administrative topology changed before the write"
set +e
accept_existing_audit "$PREWRITE_STATE"
existing_rc=$?
set -e
case "$existing_rc" in
  0)
    echo "record-merge-queue-final-audit: PASS — concurrent exact audit already recorded in comment $(printf '%s' "$EXISTING_AUDIT" | jq -r ._comment_id)"
    exit 0
    ;;
  1) ;;
  *) infra "could not classify pre-write final audits" ;;
esac

ACTION=$(printf '%s' "$PREWRITE_STATE" | jq -ec .action) \
  || infra "governing queue action is malformed"
TOPOLOGY_SHA=$(printf '%s' "$PREWRITE_STATE" | jq -er .topology_sha) \
  || infra "administrative topology fingerprint is unavailable"
CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  || infra "could not read final-audit clock"
PAYLOAD=$(jq -cnS --arg schema "$MERGEPATH_MERGE_QUEUE_AUTH_SCHEMA" \
  --arg repo "$REPO" --argjson pr "$PR_NUMBER" --arg head "$HEAD_SHA" \
  --arg group_head "$GROUP_HEAD_SHA" --arg group_ref "$GROUP_REF" \
  --arg base "$BASE_SHA" --arg base_ref "$BASE_REF" \
  --arg entry_base "$ENTRY_BASE_SHA" --arg queue "$QUEUE_ID" \
  --arg entry "$QUEUE_ENTRY_ID" --arg method "$QUEUE_METHOD" \
  --argjson action "$ACTION" --argjson rollout "$ROLLOUT_CONFIG" \
  --arg nonce "$REQUEST_NONCE" --arg requester_run "$REQUESTER_RUN_ID" \
  --argjson requester_attempt "$REQUESTER_RUN_ATTEMPT" \
  --arg requested "$REQUESTED_AT" \
  --arg requester_repo "$REQUESTER_WORKFLOW_REPOSITORY" \
  --arg requester_path "$REQUESTER_WORKFLOW_FILE_PATH" \
  --arg requester_ref "$REQUESTER_WORKFLOW_REF" \
  --arg requester_sha "$REQUESTER_WORKFLOW_SHA" \
  --arg auditor_run "$AUDITOR_RUN_ID" \
  --argjson auditor_attempt "$AUDITOR_RUN_ATTEMPT" \
  --arg auditor_ref "$AUDITOR_WORKFLOW_REF" \
  --arg auditor_sha "$AUDITOR_WORKFLOW_SHA" \
  --arg topology_sha "$TOPOLOGY_SHA" --arg created "$CREATED_AT" '{
    schema:$schema,kind:"final-admin-audit",repository:$repo,pr:$pr,
    head:$head,group_head:$group_head,group_ref:$group_ref,
    base_sha:$base,base_ref:$base_ref,entry_base:$entry_base,
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
    workflow_repository:$rollout.workflow_repository,
    workflow_ref:$rollout.workflow_ref,workflow_sha:$rollout.workflow_sha,
    environment:"merge-queue-policy",topology_sha256:$topology_sha,
    request_nonce:$nonce,requester_run_id:$requester_run,
    requester_run_attempt:$requester_attempt,requested_at:$requested,
    requester_workflow_repository:$requester_repo,
    requester_workflow_file_path:$requester_path,
    requester_workflow_ref:$requester_ref,
    requester_workflow_sha:$requester_sha,
    auditor_run_id:$auditor_run,auditor_run_attempt:$auditor_attempt,
    auditor_workflow_ref:$auditor_ref,auditor_workflow_sha:$auditor_sha,
    created_at:$created
  }') || infra "could not build final-audit payload"
ENCODED=$(printf '%s' "$PAYLOAD" | jq -Rr '@base64') \
  || infra "could not encode final-audit payload"
BODY=$(jq -nr --arg encoded "$ENCODED" --arg group "$GROUP_HEAD_SHA" \
  --arg nonce "$REQUEST_NONCE" '
    "<!-- mergepath-merge-queue-authorization:v1 " + $encoded + " -->\n" +
    "**Merge queue final audit recorded.** Merge group `" + $group +
    "` passed the nonce-bound administrative audit `" + $nonce + "`."
  ') || infra "could not render final-audit comment"
REQUEST_FILE=$(mktemp) || infra "could not create final-audit request file"
trap 'rm -f "$REQUEST_FILE"' EXIT
jq -cn --arg body "$BODY" '{body:$body}' > "$REQUEST_FILE"
POSTED=$(GH_AS_AUTHOR_IDENTITY="$AUTHOR_IDENTITY" \
  "$ROOT/scripts/gh-as-author.sh" -- gh api --method POST \
    "repos/$REPO/issues/$PR_NUMBER/comments" --input "$REQUEST_FILE") \
  || infra "author-attributed final-audit write failed"
COMMENT_ID=$(printf '%s' "$POSTED" | jq -er \
  '.id | select(type == "number" and floor == . and . > 0)') \
  || infra "final-audit write returned no comment id"
READBACK=$(GH_AS_AUTHOR_IDENTITY="$AUTHOR_IDENTITY" \
  "$ROOT/scripts/gh-as-author.sh" -- gh api \
    "repos/$REPO/issues/comments/$COMMENT_ID") \
  || infra "identity-checked final-audit readback failed"
printf '%s' "$READBACK" | jq -e --arg author "$AUTHOR_IDENTITY" \
  --arg body "$BODY" '.user.login == $author and .body == $body' \
  >/dev/null 2>&1 || infra "final-audit readback did not match the write"

# The marker is usable only if every live fence still holds after the write and
# the complete comment set contains this exact comment as its unique proof.
POSTWRITE_STATE=$(read_state)
[ "$(state_signature "$POSTWRITE_STATE")" = \
  "$(state_signature "$PREWRITE_STATE")" ] \
  || die "queue, group, action, or administrative topology changed during the write"
POST_MARKERS=$(printf '%s' "$POSTWRITE_STATE" | jq -ec .markers) \
  || infra "post-write marker set is malformed"
POST_ACTION=$(printf '%s' "$POSTWRITE_STATE" | jq -ec .action) \
  || infra "post-write action is malformed"
POST_COUNT=$(count_final_audits "$POST_MARKERS") \
  || infra "could not count post-write final audits"
[ "$POST_COUNT" -eq 1 ] \
  || die "final-audit namespace is not unique after the write"
POST_AUDIT=$(select_exact_final_audit "$POST_MARKERS" "$POST_ACTION" \
  "$AUDITOR_RUN_ID" "$AUDITOR_RUN_ATTEMPT" "$AUDITOR_WORKFLOW_REF" \
  "$AUDITOR_WORKFLOW_SHA") \
  || die "posted final audit is not the unique exact proof"
[ "$(printf '%s' "$POST_AUDIT" | jq -r .topology_sha256)" = "$TOPOLOGY_SHA" ] \
  || die "posted final audit does not bind the audited topology"
[ "$(printf '%s' "$POST_AUDIT" | jq -r ._comment_id)" = "$COMMENT_ID" ] \
  || die "a concurrent final audit won the write race"

rm -f "$REQUEST_FILE"
trap - EXIT
echo "record-merge-queue-final-audit: PASS — recorded nonce $REQUEST_NONCE in comment $COMMENT_ID"
