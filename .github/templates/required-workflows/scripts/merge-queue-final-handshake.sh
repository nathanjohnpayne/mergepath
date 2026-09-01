#!/usr/bin/env bash
# Dispatch and verify one final merge-queue audit from immutable policy code.
#
# This script deliberately has no target-repository code dependency. The only
# job that grants Contents write checks out the separately protected required-
# workflow source at job.workflow_sha and executes this file from that checkout.
# Every GitHub operation below is read-only except the single repository-
# dispatch request. An ambiguous dispatch is never retried.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: merge-queue-final-handshake.sh --repo owner/repo --head-sha SHA \
  --head-ref REF --base-sha SHA --base-ref REF --default-branch BRANCH \
  --workflow-repository owner/repo --workflow-file-path PATH \
  --workflow-ref REF --workflow-sha SHA --run-id ID --run-attempt NUMBER
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --head-sha) [ "$#" -ge 2 ] || usage; EVENT_HEAD_SHA="$2"; shift 2 ;;
    --head-ref) [ "$#" -ge 2 ] || usage; EVENT_HEAD_REF="$2"; shift 2 ;;
    --base-sha) [ "$#" -ge 2 ] || usage; EVENT_BASE_SHA="$2"; shift 2 ;;
    --base-ref) [ "$#" -ge 2 ] || usage; EVENT_BASE_REF="$2"; shift 2 ;;
    --default-branch)
      [ "$#" -ge 2 ] || usage; DEFAULT_BRANCH="$2"; shift 2 ;;
    --workflow-repository)
      [ "$#" -ge 2 ] || usage; WORKFLOW_REPOSITORY="$2"; shift 2 ;;
    --workflow-file-path)
      [ "$#" -ge 2 ] || usage; WORKFLOW_FILE_PATH="$2"; shift 2 ;;
    --workflow-ref) [ "$#" -ge 2 ] || usage; WORKFLOW_REF="$2"; shift 2 ;;
    --workflow-sha) [ "$#" -ge 2 ] || usage; WORKFLOW_SHA="$2"; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage; RUN_ID="$2"; shift 2 ;;
    --run-attempt) [ "$#" -ge 2 ] || usage; RUN_ATTEMPT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

for value in "$REPO" "$EVENT_HEAD_SHA" "$EVENT_HEAD_REF" \
  "$EVENT_BASE_SHA" "$EVENT_BASE_REF" "$DEFAULT_BRANCH" \
  "$WORKFLOW_REPOSITORY" "$WORKFLOW_FILE_PATH" "$WORKFLOW_REF" \
  "$WORKFLOW_SHA" "$RUN_ID" "$RUN_ATTEMPT"; do
  [ -n "$value" ] || usage
done

die() {
  echo "merge-queue-final-handshake: FAIL — $*" >&2
  exit 1
}

infra() {
  echo "merge-queue-final-handshake: ERROR — $*" >&2
  exit 2
}

sha_like() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$'
}

positive_integer() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ]
}

timestamp_like() {
  printf '%s' "$1" | grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

case "$REPO" in */*) ;; *) usage ;; esac
printf '%s' "$REPO" \
  | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || usage
REPO_OWNER=${REPO%%/*}
REPO_NAME=${REPO#*/}
case "$REPO_OWNER:$REPO_NAME" in :*|*:|*:*/*) usage ;; esac
case "$WORKFLOW_REPOSITORY" in */*) ;; *) usage ;; esac
printf '%s' "$WORKFLOW_REPOSITORY" \
  | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || usage
SOURCE_OWNER=${WORKFLOW_REPOSITORY%%/*}
SOURCE_NAME=${WORKFLOW_REPOSITORY#*/}
case "$SOURCE_OWNER:$SOURCE_NAME" in :*|*:|*:*/*) usage ;; esac
[ "$WORKFLOW_REPOSITORY" != "$REPO" ] \
  || die "the write-authority source must be external to the target"
[ "$DEFAULT_BRANCH" = main ] \
  || die "the final handshake is enabled only for main"
[ "$EVENT_BASE_REF" = "refs/heads/$DEFAULT_BRANCH" ] \
  || die "event base ref is not the literal default branch"
[ "$WORKFLOW_FILE_PATH" = \
  '.github/workflows/mergepath-merge-queue-authorization.yml' ] \
  || die "runtime required-workflow path is unexpected"
if [[ "$EVENT_HEAD_REF" =~ ^refs/heads/gh-readonly-queue/main/pr-([1-9][0-9]*)-.+$ ]]; then
  PR_NUMBER=${BASH_REMATCH[1]}
else
  die "merge-group ref does not identify one main-queue pull request"
fi
if ! sha_like "$EVENT_HEAD_SHA" || ! sha_like "$EVENT_BASE_SHA" \
    || ! sha_like "$WORKFLOW_SHA"; then
  usage
fi
if ! positive_integer "$RUN_ID" || ! positive_integer "$RUN_ATTEMPT"; then
  usage
fi

WORKFLOW_PREFIX="$WORKFLOW_REPOSITORY/$WORKFLOW_FILE_PATH@"
case "$WORKFLOW_REF" in
  "$WORKFLOW_PREFIX"*) SOURCE_REF=${WORKFLOW_REF#"$WORKFLOW_PREFIX"} ;;
  *) die "runtime required-workflow ref is malformed" ;;
esac
case "$SOURCE_REF" in
  refs/heads/?*) ;;
  *) die "required-workflow source is not a protected branch ref" ;;
esac
git check-ref-format "$SOURCE_REF" >/dev/null 2>&1 \
  || die "runtime required-workflow ref is not a valid Git ref"

for tool in gh jq git date od tr grep sleep mktemp; do
  command -v "$tool" >/dev/null 2>&1 \
    || infra "required tool '$tool' is unavailable"
done
[ -n "${GH_TOKEN:-}" ] || infra "GH_TOKEN is required"

SOURCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) \
  || infra "could not resolve the policy-source checkout"
SOURCE_SCRIPT='scripts/workflow/merge-queue-final-handshake.sh'
CHECKOUT_ROOT=$(git -C "$SOURCE_ROOT" rev-parse --show-toplevel 2>/dev/null) \
  || infra "policy source is not a Git checkout"
[ "$CHECKOUT_ROOT" = "$SOURCE_ROOT" ] \
  || die "handshake is not executing from the policy-source root"
CHECKOUT_SHA=$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null) \
  || infra "could not identify the policy-source commit"
[ "$CHECKOUT_SHA" = "$WORKFLOW_SHA" ] \
  || die "policy source is $CHECKOUT_SHA, expected job.workflow_sha"
git -C "$SOURCE_ROOT" cat-file -e "$WORKFLOW_SHA^{commit}" 2>/dev/null \
  || die "job.workflow_sha is not an available source commit"
git -C "$SOURCE_ROOT" cat-file -e \
  "$WORKFLOW_SHA:$SOURCE_SCRIPT" 2>/dev/null \
  || die "the pinned source commit does not contain this handshake"
git -C "$SOURCE_ROOT" diff --quiet "$WORKFLOW_SHA" -- "$SOURCE_SCRIPT" \
  || die "the executing handshake differs from the pinned source blob"
git -C "$SOURCE_ROOT" diff --cached --quiet "$WORKFLOW_SHA" -- \
  "$SOURCE_SCRIPT" \
  || die "the staged handshake differs from the pinned source blob"
SOURCE_STATUS=$(git -C "$SOURCE_ROOT" status --porcelain \
  --untracked-files=all --ignore-submodules=none) \
  || infra "could not verify the policy-source worktree"
[ -z "$SOURCE_STATUS" ] || die "policy-source checkout is not pristine"
ORIGIN_URL=$(git -C "$SOURCE_ROOT" remote get-url origin 2>/dev/null) \
  || infra "policy-source checkout has no origin"
case "$ORIGIN_URL" in
  "https://github.com/$WORKFLOW_REPOSITORY.git") ;;
  *) die "policy-source origin does not match job.workflow_repository" ;;
esac

TMP_ROOT=$(mktemp -d) || infra "could not create private handshake state"
trap 'rm -rf "$TMP_ROOT"' EXIT

# REST list endpoints are always exhausted and then parsed as one array. A
# partial page is never treated as complete evidence.
fetch_api_array() {
  [ "$#" -eq 1 ] || return 1
  local endpoint="$1" raw="$TMP_ROOT/rest-$RANDOM-$RANDOM.json"
  gh api --paginate "$endpoint" > "$raw" || return 1
  jq -sc '
    select(length > 0 and all(.[]; type == "array")) |
    add
  ' "$raw"
}

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
          jump solo state mergeQueue{id}
          pullRequest{
            id number state isDraft createdAt headRefOid baseRefName baseRefOid
            headRepository{nameWithOwner}
            baseRepository{nameWithOwner defaultBranchRef{name}}
            author{login} stack{id} autoMergeRequest{enabledAt}
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
      .data.repository as $repo | $repo.mergeQueue as $queue |
      select($repo != null and $queue != null) |
      {
        repository_id:$repo.id,repository:$repo.nameWithOwner,
        owner_type:$repo.owner.__typename,owner_login:$repo.owner.login,
        default_branch:$repo.defaultBranchRef.name,
        live_base:$repo.defaultBranchRef.target.oid,
        queue:{
          id:$queue.id,configuration:$queue.configuration,
          total_count:$queue.entries.totalCount,
          has_next:$queue.entries.pageInfo.hasNextPage,
          end_cursor:$queue.entries.pageInfo.endCursor,
          entries:$queue.entries.nodes
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
        | jq -cS 'del(.queue.has_next,.queue.end_cursor,.queue.entries)') \
        || return 1
      snapshot_static=$(printf '%s' "$snapshot" \
        | jq -cS 'del(.queue.has_next,.queue.end_cursor,.queue.entries)') \
        || return 1
      [ "$page_static" = "$snapshot_static" ] || return 1
      snapshot=$(jq -cn --argjson snapshot "$snapshot" --argjson page "$page" '
        $snapshot |
        .queue.entries += $page.queue.entries |
        .queue.has_next = $page.queue.has_next |
        .queue.end_cursor = $page.queue.end_cursor
      ') || return 1
    fi
    has_next=$(printf '%s' "$page" | jq -r '.queue.has_next') || return 1
    [ "$has_next" = true ] || break
    next_cursor=$(printf '%s' "$page" | jq -er '
      .queue.end_cursor | select(type == "string" and length > 0)
    ') || return 1
    if printf '%s' "$seen_cursors" \
      | jq -e --arg cursor "$next_cursor" \
        'index($cursor) != null' >/dev/null 2>&1; then
      return 1
    fi
    seen_cursors=$(printf '%s' "$seen_cursors" \
      | jq -c --arg cursor "$next_cursor" '. + [$cursor]') || return 1
    cursor="$next_cursor"
  done
  printf '%s' "$snapshot" | jq -ce '
    select(.queue.has_next == false) |
    select((.queue.entries | map(.id) | length) ==
      (.queue.entries | map(.id) | unique | length)) |
    del(.queue.end_cursor)
  '
}

validate_queue_snapshot() {
  printf '%s' "$1" | jq -e \
    --arg repo "$REPO" --arg branch "$DEFAULT_BRANCH" \
    --arg base "$EVENT_BASE_SHA" --argjson pr "$PR_NUMBER" '
      type == "object" and
      (.repository_id | type == "string" and length > 0) and
      .repository == $repo and .owner_type == "Organization" and
      (.owner_login | type == "string" and length > 0) and
      .default_branch == $branch and .live_base == $base and
      (.queue.id | type == "string" and length > 0) and
      .queue.total_count == 1 and .queue.has_next == false and
      (.queue.entries | type == "array" and length == 1) and
      (.queue.configuration as $config |
        $config.maximumEntriesToBuild == 1 and
        $config.maximumEntriesToMerge == 1 and
        $config.minimumEntriesToMerge == 1 and
        $config.mergingStrategy == "ALLGREEN" and
        ((["MERGE","SQUASH","REBASE"] | index($config.mergeMethod)) != null)) and
      (.queue.entries[0] as $entry |
        ($entry.id | type == "string" and length > 0) and
        ($entry.baseCommit.oid | type == "string" and
          test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$")) and
        ($entry.headCommit.oid | type == "string" and
          test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$")) and
        ($entry.enqueuedAt | type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        ($entry.enqueuer.login | type == "string" and length > 0) and
        $entry.jump == false and ($entry.solo | type == "boolean") and
        ((["QUEUED","AWAITING_CHECKS","MERGEABLE","LOCKED"] |
          index($entry.state)) != null) and
        $entry.mergeQueue.id == .queue.id and
        ($entry.pullRequest.id | type == "string" and length > 0) and
        $entry.pullRequest.number == $pr and
        $entry.pullRequest.state == "OPEN" and
        $entry.pullRequest.isDraft == false and
        ($entry.pullRequest.createdAt | type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        $entry.pullRequest.headRefOid == $entry.headCommit.oid and
        $entry.pullRequest.baseRefName == $branch and
        $entry.pullRequest.baseRefOid == $base and
        $entry.pullRequest.headRepository.nameWithOwner == $repo and
        $entry.pullRequest.baseRepository.nameWithOwner == $repo and
        $entry.pullRequest.baseRepository.defaultBranchRef.name == $branch and
        ($entry.pullRequest.author.login | type == "string" and length > 0) and
        $entry.enqueuer.login == $entry.pullRequest.author.login and
        $entry.pullRequest.stack == null and
        $entry.pullRequest.autoMergeRequest == null)
    ' >/dev/null 2>&1
}

queue_signature() {
  printf '%s' "$1" | jq -ceS '
    .queue.entries |= map(del(.state)) |
    del(.queue.end_cursor)
  '
}

read_group_ref() {
  gh api "repos/$REPO/git/ref/${EVENT_HEAD_REF#refs/}" | jq -ce '
    {ref:.ref,object_type:.object.type,object_sha:.object.sha}
  '
}

validate_group_ref() {
  printf '%s' "$1" | jq -e --arg ref "$EVENT_HEAD_REF" \
    --arg head "$EVENT_HEAD_SHA" '
      .ref == $ref and .object_type == "commit" and .object_sha == $head
    ' >/dev/null 2>&1
}

validate_entry_base_lineage() {
  local entry_base="$1" compare
  [ "$entry_base" = "$EVENT_BASE_SHA" ] && return 0
  compare=$(gh api "repos/$REPO/compare/$entry_base...$EVENT_BASE_SHA") \
    || return 1
  printf '%s' "$compare" | jq -e --arg base "$entry_base" '
    .status == "ahead" and .base_commit.sha == $base and
    .merge_base_commit.sha == $base
  ' >/dev/null 2>&1
}

read_requester_run() {
  gh api "repos/$REPO/actions/runs/$RUN_ID"
}

validate_requester_run() {
  printf '%s' "$1" | jq -e \
    --arg repo "$REPO" --argjson id "$RUN_ID" \
    --argjson attempt "$RUN_ATTEMPT" --arg head "$EVENT_HEAD_SHA" \
    --arg branch "${EVENT_HEAD_REF#refs/heads/}" \
    --arg workflow_ref "$WORKFLOW_REF" --arg path "$WORKFLOW_FILE_PATH" \
    --arg workflow_repository "$WORKFLOW_REPOSITORY" \
    --arg source_ref "$SOURCE_REF" \
    --arg source_short_ref "${SOURCE_REF#refs/heads/}" \
    --arg source_sha "$WORKFLOW_SHA" '
      def matching_path:
        . == $workflow_ref or
        . == ($workflow_repository + "/" + $path + "@" +
          $source_short_ref);
      type == "object" and .id == $id and .run_attempt == $attempt and
      .event == "merge_group" and .status == "in_progress" and
      .conclusion == null and .head_sha == $head and
      .head_branch == $branch and .repository.full_name == $repo and
      .head_repository.full_name == $repo and
      (.referenced_workflows | type == "array" and length > 0) and
      any(.referenced_workflows[];
        (.path | type == "string" and matching_path) and
        .sha == $source_sha and .ref == $source_ref) and
      all((.referenced_workflows // [])[] | select(.path | matching_path);
        .sha == $source_sha and .ref == $source_ref)
    ' >/dev/null 2>&1
}

fetch_labels() {
  fetch_api_array "repos/$REPO/issues/$PR_NUMBER/labels?per_page=100"
}

validate_labels() {
  printf '%s' "$1" | jq -e '
    type == "array" and
    all(.[]; (.name | type == "string" and length > 0)) and
    ([.[].name] |
      map(select(
        . == "human-hold" or . == "needs-external-review" or
        . == "needs-human-review" or . == "policy-violation"
      )) | length == 0)
  ' >/dev/null 2>&1
}

# The write-capable job cannot import the target's authorization library. This
# source-pinned copy intentionally keeps only the timeline fields needed to
# derive the one live enqueue action that the target auditor must independently
# reproduce.
# shellcheck disable=SC2016 # GraphQL variables are intentionally literal.
TIMELINE_QUERY='query($owner:String!,$name:String!,$number:Int!,$after:String){
  repository(owner:$owner,name:$name){
    nameWithOwner
    pullRequest(number:$number){
      id number
      timelineItems(
        first:100,after:$after,
        itemTypes:[
          LABELED_EVENT,
          AUTO_MERGE_ENABLED_EVENT,
          AUTO_SQUASH_ENABLED_EVENT,
          AUTO_REBASE_ENABLED_EVENT,
          AUTO_MERGE_DISABLED_EVENT,
          PULL_REQUEST_COMMIT,
          HEAD_REF_DELETED_EVENT,
          HEAD_REF_FORCE_PUSHED_EVENT,
          HEAD_REF_RESTORED_EVENT,
          ADDED_TO_MERGE_QUEUE_EVENT
        ]
      ){
        totalCount pageInfo{hasNextPage endCursor}
        nodes{
          __typename
          ... on LabeledEvent{id createdAt actor{login} label{name}}
          ... on AutoMergeEnabledEvent{
            id createdAt actor{login} enabler{login}
          }
          ... on AutoSquashEnabledEvent{
            id createdAt actor{login} enabler{login}
          }
          ... on AutoRebaseEnabledEvent{
            id createdAt actor{login} enabler{login}
          }
          ... on AutoMergeDisabledEvent{
            id createdAt actor{login} disabler{login} reason reasonCode
          }
          ... on PullRequestCommit{id commit{oid}}
          ... on HeadRefForcePushedEvent{
            id createdAt actor{login} beforeCommit{oid} afterCommit{oid}
          }
          ... on HeadRefDeletedEvent{
            id createdAt actor{login} headRefName
          }
          ... on HeadRefRestoredEvent{id createdAt actor{login}}
          ... on AddedToMergeQueueEvent{
            id createdAt actor{login} enqueuer{login} mergeQueue{id}
          }
        }
      }
    }
  }
}'

read_timeline() {
  local raw page snapshot="" cursor="" next_cursor has_next
  local page_static snapshot_static seen_cursors='[]' page_count=0
  local -a gh_args
  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le 100 ] || return 1
    gh_args=(api graphql -f query="$TIMELINE_QUERY" \
      -f owner="$REPO_OWNER" -f name="$REPO_NAME" -F number="$PR_NUMBER")
    if [ -n "$cursor" ]; then
      gh_args+=(-f after="$cursor")
    fi
    raw=$(gh "${gh_args[@]}") || return 1
    page=$(printf '%s' "$raw" | jq -ce '
      select(((.errors // []) | length) == 0) |
      .data.repository as $repo | $repo.pullRequest as $pr |
      select($repo != null and $pr != null) |
      {
        repository:$repo.nameWithOwner,pr_id:$pr.id,pr_number:$pr.number,
        total_count:$pr.timelineItems.totalCount,
        has_next:$pr.timelineItems.pageInfo.hasNextPage,
        end_cursor:$pr.timelineItems.pageInfo.endCursor,
        items:[$pr.timelineItems.nodes[] |
          if .__typename == "LabeledEvent" then {
            kind:"labeled",id,created_at:.createdAt,
            actor:(.actor.login // ""),label:.label.name
          } elif .__typename == "AutoMergeEnabledEvent" then {
            kind:"auto_merge_enabled",id,created_at:.createdAt,
            actor:(.actor.login // ""),enabler:(.enabler.login // ""),
            method:"MERGE"
          } elif .__typename == "AutoSquashEnabledEvent" then {
            kind:"auto_merge_enabled",id,created_at:.createdAt,
            actor:(.actor.login // ""),enabler:(.enabler.login // ""),
            method:"SQUASH"
          } elif .__typename == "AutoRebaseEnabledEvent" then {
            kind:"auto_merge_enabled",id,created_at:.createdAt,
            actor:(.actor.login // ""),enabler:(.enabler.login // ""),
            method:"REBASE"
          } elif .__typename == "AutoMergeDisabledEvent" then {
            kind:"auto_merge_disabled",id,created_at:.createdAt,
            actor:(.actor.login // ""),disabler:(.disabler.login // ""),
            reason:(.reason // ""),reason_code:(.reasonCode // "")
          } elif .__typename == "PullRequestCommit" then {
            kind:"head_commit",id,oid:(.commit.oid // "")
          } elif .__typename == "HeadRefForcePushedEvent" then {
            kind:"head_force_pushed",id,created_at:.createdAt,
            actor:(.actor.login // ""),before:(.beforeCommit.oid // ""),
            after:(.afterCommit.oid // "")
          } elif .__typename == "HeadRefDeletedEvent" then {
            kind:"head_deleted",id,created_at:.createdAt,
            actor:(.actor.login // ""),head_ref:(.headRefName // "")
          } elif .__typename == "HeadRefRestoredEvent" then {
            kind:"head_restored",id,created_at:.createdAt,
            actor:(.actor.login // "")
          } elif .__typename == "AddedToMergeQueueEvent" then {
            kind:"added_to_queue",id,created_at:.createdAt,
            actor:(.actor.login // ""),enqueuer:(.enqueuer.login // ""),
            queue_id:(.mergeQueue.id // "")
          } else error("unexpected timeline item type") end]
      } |
      select(
        (.total_count | type == "number" and floor == . and . >= 0) and
        (.has_next | type == "boolean") and (.items | type == "array")
      )
    ') || return 1
    if [ -z "$snapshot" ]; then
      snapshot="$page"
    else
      page_static=$(printf '%s' "$page" \
        | jq -cS 'del(.has_next,.end_cursor,.items)') || return 1
      snapshot_static=$(printf '%s' "$snapshot" \
        | jq -cS 'del(.has_next,.end_cursor,.items)') || return 1
      [ "$page_static" = "$snapshot_static" ] || return 1
      snapshot=$(jq -cn --argjson snapshot "$snapshot" --argjson page "$page" '
        $snapshot |
        .items += $page.items |
        .has_next = $page.has_next |
        .end_cursor = $page.end_cursor
      ') || return 1
    fi
    has_next=$(printf '%s' "$page" | jq -r .has_next) || return 1
    [ "$has_next" = true ] || break
    next_cursor=$(printf '%s' "$page" | jq -er '
      .end_cursor | select(type == "string" and length > 0)
    ') || return 1
    if printf '%s' "$seen_cursors" \
      | jq -e --arg cursor "$next_cursor" \
        'index($cursor) != null' >/dev/null 2>&1; then
      return 1
    fi
    seen_cursors=$(printf '%s' "$seen_cursors" \
      | jq -c --arg cursor "$next_cursor" '. + [$cursor]') || return 1
    cursor="$next_cursor"
  done
  printf '%s' "$snapshot" | jq -ce '
    select(.has_next == false) |
    select((.items | map(.id) | length) ==
      (.items | map(.id) | unique | length)) |
    del(.end_cursor)
  '
}

select_entry_action() {
  local timeline="$1" author="$2" queue_id="$3" enqueued_at="$4"
  local method="$5"
  jq -ecn --argjson timeline "$timeline" --arg repo "$REPO" \
    --argjson pr "$PR_NUMBER" --arg author "$author" \
    --arg queue "$queue_id" --arg enqueued "$enqueued_at" \
    --arg method "$method" '
      def blocking_label:
        . == "human-hold" or . == "needs-external-review" or
        . == "needs-human-review" or . == "policy-violation";
      def invalidating:
        (.kind == "labeled" and (.label | blocking_label)) or
        .kind == "auto_merge_enabled" or .kind == "auto_merge_disabled" or
        .kind == "head_commit" or .kind == "head_force_pushed" or
        .kind == "head_deleted" or .kind == "head_restored" or
        .kind == "added_to_queue";
      select($timeline.repository == $repo and
        $timeline.pr_number == $pr and $timeline.has_next == false and
        ($timeline.pr_id | type == "string" and length > 0) and
        ($timeline.items | type == "array")) |
      select(([$timeline.items[].id] | length) ==
        ([$timeline.items[].id] | unique | length)) |
      $timeline.items as $items |
      [$items | to_entries[] | select(
        .value.kind == "added_to_queue" and
        .value.created_at == $enqueued and
        .value.enqueuer == $author and .value.queue_id == $queue
      )] as $adds |
      select(($adds | length) > 0) |
      $adds[-1] as $added |
      select(all($items | to_entries[];
        if .key > $added.key then (.value | invalidating | not)
        else true end)) |
      [$items | to_entries[] | select(
        .key <= $added.key and
        (.value.kind == "auto_merge_enabled" or
         .value.kind == "auto_merge_disabled"))] as $arms |
      if ($arms | length) == 0 or
          $arms[-1].value.kind == "auto_merge_disabled" then
        select($added.value.actor == $author) |
        {
          kind:"direct-queue",
          queue_event_id:$added.value.id,
          queue_event_created_at:$added.value.created_at,
          action_event_id:$added.value.id,
          action_event_created_at:$added.value.created_at,
          merge_method:$method
        }
      else
        $arms[-1] as $source |
        select($source.value.kind == "auto_merge_enabled" and
          $source.value.enabler == $author and
          $source.value.method == $method) |
        select(all($items | to_entries[];
          if .key > $source.key and .key < $added.key then
            (.value | invalidating | not)
          else true end)) |
        {
          kind:"auto-merge",
          queue_event_id:$added.value.id,
          queue_event_created_at:$added.value.created_at,
          action_event_id:$source.value.id,
          action_event_created_at:$source.value.created_at,
          merge_method:$source.value.method
        }
      end
  '
}

read_check_timeout_seconds() {
  local rules
  rules=$(fetch_api_array \
    "repos/$REPO/rules/branches/$DEFAULT_BRANCH?per_page=100") || return 1
  printf '%s' "$rules" | jq -er '
    [.[] | select(
      .type == "merge_queue" and
      .parameters.max_entries_to_build == 1 and
      .parameters.max_entries_to_merge == 1 and
      .parameters.min_entries_to_merge == 1 and
      .parameters.grouping_strategy == "ALLGREEN"
    )] |
    select(length == 1) |
    .[0].parameters.check_response_timeout_minutes |
    select(type == "number" and floor == . and . > 0) * 60
  '
}

read_live_state() {
  local queue group requester labels timeline action entry_base
  local author queue_id enqueued method
  queue=$(read_queue_snapshot) || infra "could not read the singleton queue"
  validate_queue_snapshot "$queue" \
    || die "live queue is not the singleton standalone ALLGREEN entry"
  group=$(read_group_ref) || infra "could not read the merge-group ref"
  validate_group_ref "$group" \
    || die "live merge-group ref no longer matches the event"
  requester=$(read_requester_run) || infra "could not read the requester run"
  validate_requester_run "$requester" \
    || die "requester run is not the exact live merge-group workflow"
  labels=$(fetch_labels) || infra "could not read complete PR labels"
  validate_labels "$labels" || die "a blocking or malformed label is present"

  entry_base=$(printf '%s' "$queue" | jq -er \
    '.queue.entries[0].baseCommit.oid') \
    || infra "queue entry has no base"
  validate_entry_base_lineage "$entry_base" \
    || die "queue-entry base is not an ancestor of the event base"
  author=$(printf '%s' "$queue" | jq -er \
    '.queue.entries[0].pullRequest.author.login') \
    || infra "queue entry has no author"
  queue_id=$(printf '%s' "$queue" | jq -er .queue.id) \
    || infra "queue has no identity"
  enqueued=$(printf '%s' "$queue" | jq -er \
    '.queue.entries[0].enqueuedAt') \
    || infra "queue entry has no enqueue time"
  method=$(printf '%s' "$queue" | jq -er .queue.configuration.mergeMethod) \
    || infra "queue has no merge method"
  timeline=$(read_timeline) || infra "could not read the complete action timeline"
  action=$(select_entry_action "$timeline" "$author" "$queue_id" \
    "$enqueued" "$method") \
    || die "queue entry has no exact unsuperseded governing action"

  jq -cn --argjson queue "$(queue_signature "$queue")" \
    --argjson group "$group" --argjson labels "$labels" \
    --argjson action "$action" '{
      queue:$queue,group:$group,
      labels:([$labels[].name] | sort),
      action:$action
    }'
}

state_signature() {
  printf '%s' "$1" | jq -ceS .
}

fetch_comments() {
  fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments?per_page=100"
}

decode_markers() {
  printf '%s' "$1" | jq -ce \
    --arg schema 'mergepath-merge-queue-authorization/v1' \
    --arg marker_re \
      '<!-- mergepath-merge-queue-authorization:v1 (?<payload>[A-Za-z0-9+/=]+) -->' '
      select(type == "array") |
      [.[] as $comment |
        select($comment | type == "object") |
        try (
          (($comment.body // "") |
            capture($marker_re).payload | @base64d | fromjson) + {
              _comment_id:$comment.id,
              _comment_url:($comment.html_url // ""),
              _comment_created_at:($comment.created_at // ""),
              _comment_author:($comment.user.login // "")
            }
        ) catch empty |
        select(type == "object" and .schema == $schema)
      ] | sort_by(._comment_id)
    '
}

count_audit_namespace() {
  local markers="$1" author="$2" nonce="$3"
  jq -ecn --argjson markers "$markers" --arg author "$author" \
    --arg nonce "$nonce" --arg run "$RUN_ID" \
    --argjson attempt "$RUN_ATTEMPT" '
      [$markers[] | select(
        ._comment_author == $author and .kind == "final-admin-audit" and
        (.request_nonce == $nonce or
          (.requester_run_id == $run and
            .requester_run_attempt == $attempt))
      )] | length
    '
}

select_exact_audit() {
  local markers="$1" action="$2" author="$3" nonce="$4"
  local requested_at="$5" queue_id="$6" entry_id="$7"
  local enqueued="$8" method="$9" entry_base="${10}" pr_head="${11}"
  jq -ecn --argjson markers "$markers" --argjson action "$action" \
    --arg author "$author" --arg nonce "$nonce" \
    --arg requested "$requested_at" --arg repo "$REPO" \
    --argjson pr "$PR_NUMBER" --arg head "$pr_head" \
    --arg group_head "$EVENT_HEAD_SHA" --arg group_ref "$EVENT_HEAD_REF" \
    --arg base "$EVENT_BASE_SHA" --arg branch "$DEFAULT_BRANCH" \
    --arg queue "$queue_id" --arg entry "$entry_id" \
    --arg enqueued "$enqueued" --arg method "$method" \
    --arg entry_base "$entry_base" --arg run "$RUN_ID" \
    --argjson attempt "$RUN_ATTEMPT" \
    --arg workflow_repo "$WORKFLOW_REPOSITORY" \
    --arg workflow_path "$WORKFLOW_FILE_PATH" \
    --arg workflow_ref "$WORKFLOW_REF" --arg source_ref "$SOURCE_REF" \
    --arg workflow_sha "$WORKFLOW_SHA" '
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def sha:
        type == "string" and
        test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$");
      [$markers[] | select(
        ._comment_author == $author and
        (._comment_id | type == "number" and floor == . and . > 0) and
        (._comment_created_at | timestamp) and
        .kind == "final-admin-audit" and
        .repository == $repo and .pr == $pr and .head == $head and
        .group_head == $group_head and .group_ref == $group_ref and
        .base_sha == $base and .base_ref == $branch and
        .entry_base == $entry_base and .queue_id == $queue and
        .queue_entry_id == $entry and
        .queue_event_id == $action.queue_event_id and
        .queue_event_created_at == $action.queue_event_created_at and
        .authorization_kind == $action.kind and
        .action_event_id == $action.action_event_id and
        .action_event_created_at == $action.action_event_created_at and
        .merge_method == $method and
        (.repository_ruleset_id | type == "number" and floor == . and . > 0) and
        (.workflow_ruleset_id | type == "number" and floor == . and . > 0) and
        (.workflow_repository_id | type == "number" and floor == . and . > 0) and
        .workflow_repository == $workflow_repo and
        .workflow_ref == $source_ref and .workflow_sha == $workflow_sha and
        .environment == "merge-queue-policy" and
        (.topology_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        .request_nonce == $nonce and .requester_run_id == $run and
        .requester_run_attempt == $attempt and .requested_at == $requested and
        .requester_workflow_repository == $workflow_repo and
        .requester_workflow_file_path == $workflow_path and
        .requester_workflow_ref == $workflow_ref and
        .requester_workflow_sha == $workflow_sha and
        (.auditor_run_id | type == "string" and test("^[1-9][0-9]*$")) and
        (.auditor_run_attempt | type == "number" and floor == . and . > 0) and
        .auditor_workflow_ref ==
          ($repo + "/.github/workflows/merge-queue-final-audit.yml@refs/heads/main") and
        .auditor_workflow_sha == $base and
        (.created_at | timestamp) and
        (($requested | fromdateiso8601) <= (.created_at | fromdateiso8601)) and
        ((.created_at | fromdateiso8601) <=
          (._comment_created_at | fromdateiso8601)) and
        (($requested | fromdateiso8601) <=
          (._comment_created_at | fromdateiso8601)) and
        (.head | sha) and (.group_head | sha) and (.base_sha | sha) and
        (.entry_base | sha) and (.requester_workflow_sha | sha) and
        (.auditor_workflow_sha | sha)
      )] |
      select(length == 1) | .[0]
    '
}

read_auditor_run() {
  gh api "repos/$REPO/actions/runs/$1"
}

classify_auditor_run() {
  local run="$1" marker="$2"
  local auditor_id auditor_attempt auditor_ref auditor_sha
  local marker_created comment_created
  auditor_id=$(printf '%s' "$marker" | jq -er .auditor_run_id) || return 2
  auditor_attempt=$(printf '%s' "$marker" | jq -er .auditor_run_attempt) \
    || return 2
  auditor_ref=$(printf '%s' "$marker" | jq -er .auditor_workflow_ref) \
    || return 2
  auditor_sha=$(printf '%s' "$marker" | jq -er .auditor_workflow_sha) \
    || return 2
  marker_created=$(printf '%s' "$marker" | jq -er .created_at) || return 2
  comment_created=$(printf '%s' "$marker" | jq -er ._comment_created_at) \
    || return 2
  printf '%s' "$run" | jq -er \
    --arg repo "$REPO" --argjson id "$auditor_id" \
    --argjson attempt "$auditor_attempt" --arg head "$auditor_sha" \
    --arg branch "$DEFAULT_BRANCH" \
    --arg path '.github/workflows/merge-queue-final-audit.yml' \
    --arg workflow_ref "$auditor_ref" --arg requested "$REQUESTED_AT" \
    --arg marker_created "$marker_created" \
    --arg comment_created "$comment_created" '
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def matching_path:
        . == $path or . == ($path + "@refs/heads/main") or
        . == $workflow_ref;
      select(type == "object" and .id == $id and
        .run_attempt == $attempt and .repository.full_name == $repo and
        .event == "repository_dispatch" and .head_sha == $head and
        .head_branch == $branch and (.path | matching_path) and
        .head_repository.full_name == $repo and
        .actor.login == "github-actions[bot]" and
        .triggering_actor.login == "github-actions[bot]" and
        (.created_at | timestamp) and (.run_started_at | timestamp) and
        (($requested | fromdateiso8601) <= (.created_at | fromdateiso8601)) and
        (($requested | fromdateiso8601) <=
          (.run_started_at | fromdateiso8601)) and
        ((.created_at | fromdateiso8601) <=
          ($marker_created | fromdateiso8601)) and
        ((.run_started_at | fromdateiso8601) <=
          ($marker_created | fromdateiso8601)) and
        ((.created_at | fromdateiso8601) <=
          ($comment_created | fromdateiso8601)) and
        ((.run_started_at | fromdateiso8601) <=
          ($comment_created | fromdateiso8601))) |
      if .status == "completed" and .conclusion == "success" then "success"
      elif (.status == "queued" or .status == "in_progress") and
          .conclusion == null then "pending"
      else "invalid" end
    '
}

INITIAL_STATE=$(read_live_state)
TIMEOUT_SECONDS=$(read_check_timeout_seconds) \
  || infra "could not derive the singleton queue check timeout"
positive_integer "$TIMEOUT_SECONDS" \
  || infra "queue check timeout is malformed"
INITIAL_INTERVAL=${MERGEPATH_MERGE_QUEUE_HANDSHAKE_INTERVAL_SECONDS:-2}
MAX_INTERVAL=${MERGEPATH_MERGE_QUEUE_HANDSHAKE_MAX_INTERVAL_SECONDS:-60}
if [ "$INITIAL_INTERVAL" = 0 ]; then
  DEFAULT_ATTEMPTS=1
else
  DEFAULT_ATTEMPTS=100000
fi
MAX_ATTEMPTS=${MERGEPATH_MERGE_QUEUE_HANDSHAKE_ATTEMPTS:-$DEFAULT_ATTEMPTS}
case "$INITIAL_INTERVAL" in ''|*[!0-9]*) infra "initial poll interval is malformed" ;; esac
case "$MAX_INTERVAL" in ''|*[!0-9]*) infra "maximum poll interval is malformed" ;; esac
case "$MAX_ATTEMPTS" in ''|*[!0-9]*) infra "poll-attempt bound is malformed" ;; esac
[ "$INITIAL_INTERVAL" -le "$MAX_INTERVAL" ] \
  && [ "$MAX_INTERVAL" -le 300 ] \
  && [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$MAX_ATTEMPTS" -le 100000 ] \
  || infra "handshake polling bounds are unsafe"

# The nonce exists only in this source-pinned process. It is masked before it
# is used, is never exported, and never crosses a job output or expression.
REQUEST_NONCE=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n') \
  || infra "could not create a request nonce"
printf '%s' "$REQUEST_NONCE" | grep -Eq '^[0-9a-f]{64}$' \
  || infra "request nonce is malformed"
echo "::add-mask::$REQUEST_NONCE"
REQUESTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ') \
  || infra "could not read the request clock"
timestamp_like "$REQUESTED_AT" || infra "request clock is malformed"

QUEUE_ID=$(printf '%s' "$INITIAL_STATE" | jq -er .queue.queue.id) \
  || infra "queue id is unavailable"
ENTRY_ID=$(printf '%s' "$INITIAL_STATE" | jq -er .queue.queue.entries[0].id) \
  || infra "entry id is unavailable"
ENTRY_BASE=$(printf '%s' "$INITIAL_STATE" \
  | jq -er .queue.queue.entries[0].baseCommit.oid) \
  || infra "entry base is unavailable"
ENTRY_ENQUEUED_AT=$(printf '%s' "$INITIAL_STATE" \
  | jq -er .queue.queue.entries[0].enqueuedAt) \
  || infra "entry enqueue time is unavailable"
PR_HEAD=$(printf '%s' "$INITIAL_STATE" \
  | jq -er .queue.queue.entries[0].headCommit.oid) \
  || infra "PR head is unavailable"
AUTHOR=$(printf '%s' "$INITIAL_STATE" \
  | jq -er .queue.queue.entries[0].pullRequest.author.login) \
  || infra "PR author is unavailable"
QUEUE_METHOD=$(printf '%s' "$INITIAL_STATE" \
  | jq -er .queue.queue.configuration.mergeMethod) \
  || infra "queue method is unavailable"
ACTION=$(printf '%s' "$INITIAL_STATE" | jq -ec .action) \
  || infra "queue action is unavailable"

PREDISPATCH_STATE=$(read_live_state)
[ "$(state_signature "$PREDISPATCH_STATE")" = \
  "$(state_signature "$INITIAL_STATE")" ] \
  || die "queue, group, labels, or action changed before dispatch"

DISPATCH_FILE="$TMP_ROOT/repository-dispatch.json"
jq -cn --arg event_type 'mergepath-final-queue-audit' \
  --arg repository "$REPO" --argjson pr "$PR_NUMBER" \
  --arg head "$PR_HEAD" --arg group_head "$EVENT_HEAD_SHA" \
  --arg group_ref "$EVENT_HEAD_REF" --arg base "$EVENT_BASE_SHA" \
  --arg base_ref "$DEFAULT_BRANCH" --arg queue "$QUEUE_ID" \
  --arg entry "$ENTRY_ID" --arg enqueued "$ENTRY_ENQUEUED_AT" \
  --arg method "$QUEUE_METHOD" --arg entry_base "$ENTRY_BASE" \
  --argjson action "$ACTION" --arg nonce "$REQUEST_NONCE" \
  --arg run "$RUN_ID" --argjson attempt "$RUN_ATTEMPT" \
  --arg requested "$REQUESTED_AT" \
  --arg workflow_repo "$WORKFLOW_REPOSITORY" \
  --arg workflow_path "$WORKFLOW_FILE_PATH" \
  --arg workflow_ref "$WORKFLOW_REF" --arg workflow_sha "$WORKFLOW_SHA" '{
    event_type:$event_type,
    client_payload:{request:{
      repository:$repository,pr:$pr,head_sha:$head,
      group_head_sha:$group_head,group_ref:$group_ref,
      base_sha:$base,base_ref:$base_ref,queue_id:$queue,
      queue_entry_id:$entry,entry_enqueued_at:$enqueued,
      queue_method:$method,entry_base_sha:$entry_base,
      authorization_kind:$action.kind,
      queue_event_id:$action.queue_event_id,
      queue_event_created_at:$action.queue_event_created_at,
      action_event_id:$action.action_event_id,
      action_event_created_at:$action.action_event_created_at,
      request_nonce:$nonce,requester_run_id:$run,
      requester_run_attempt:$attempt,requested_at:$requested,
      requester_workflow_repository:$workflow_repo,
      requester_workflow_file_path:$workflow_path,
      requester_workflow_ref:$workflow_ref,
      requester_workflow_sha:$workflow_sha
    }}
  }' > "$DISPATCH_FILE" \
  || infra "could not render the repository dispatch"

# This is the only write in the source-pinned process. Do not wrap it in a
# retry: after a transport failure the server-side outcome is unknowable.
set +e
gh api --method POST "repos/$REPO/dispatches" \
  --input "$DISPATCH_FILE" >/dev/null
DISPATCH_RC=$?
set -e

ATTEMPT=1
ELAPSED=0
WAIT_SECONDS=$INITIAL_INTERVAL
while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
  LIVE_STATE=$(read_live_state)
  [ "$(state_signature "$LIVE_STATE")" = \
    "$(state_signature "$INITIAL_STATE")" ] \
    || die "queue, group, labels, or action drifted during the audit"
  COMMENTS=$(fetch_comments) \
    || infra "could not read complete final-audit history"
  MARKERS=$(decode_markers "$COMMENTS") \
    || infra "could not decode final-audit history"
  COUNT=$(count_audit_namespace "$MARKERS" "$AUTHOR" "$REQUEST_NONCE") \
    || infra "could not count final-audit responses"
  [ "$COUNT" -le 1 ] || die "final audit produced duplicate responses"
  if [ "$COUNT" -eq 1 ]; then
    AUDIT=$(select_exact_audit "$MARKERS" "$ACTION" "$AUTHOR" \
      "$REQUEST_NONCE" "$REQUESTED_AT" "$QUEUE_ID" "$ENTRY_ID" \
      "$ENTRY_ENQUEUED_AT" "$QUEUE_METHOD" "$ENTRY_BASE" "$PR_HEAD") \
      || die "final audit response is malformed or does not bind the request"
    AUDITOR_ID=$(printf '%s' "$AUDIT" | jq -er .auditor_run_id) \
      || die "final audit names no auditor run"
    AUDITOR_RUN=$(read_auditor_run "$AUDITOR_ID") \
      || infra "could not read the target auditor run"
    set +e
    AUDITOR_STATE=$(classify_auditor_run "$AUDITOR_RUN" "$AUDIT")
    AUDITOR_RC=$?
    set -e
    [ "$AUDITOR_RC" -eq 0 ] \
      || die "target auditor run does not bind the response"
    case "$AUDITOR_STATE" in
      success)
        FINAL_STATE=$(read_live_state)
        [ "$(state_signature "$FINAL_STATE")" = \
          "$(state_signature "$INITIAL_STATE")" ] \
          || die "queue, group, labels, or action drifted at final readback"
        FINAL_COMMENTS=$(fetch_comments) \
          || infra "could not perform final audit-history readback"
        FINAL_MARKERS=$(decode_markers "$FINAL_COMMENTS") \
          || infra "could not decode final audit-history readback"
        FINAL_COUNT=$(count_audit_namespace "$FINAL_MARKERS" "$AUTHOR" \
          "$REQUEST_NONCE") || infra "could not count final audit readback"
        [ "$FINAL_COUNT" -eq 1 ] \
          || die "final audit was duplicated or removed before success"
        FINAL_AUDIT=$(select_exact_audit "$FINAL_MARKERS" "$ACTION" "$AUTHOR" \
          "$REQUEST_NONCE" "$REQUESTED_AT" "$QUEUE_ID" "$ENTRY_ID" \
          "$ENTRY_ENQUEUED_AT" "$QUEUE_METHOD" "$ENTRY_BASE" "$PR_HEAD") \
          || die "final audit changed before success"
        [ "$(printf '%s' "$FINAL_AUDIT" | jq -cS .)" = \
          "$(printf '%s' "$AUDIT" | jq -cS .)" ] \
          || die "final audit changed before success"
        FINAL_RUN=$(read_auditor_run "$AUDITOR_ID") \
          || infra "could not perform final auditor-run readback"
        [ "$(classify_auditor_run "$FINAL_RUN" "$FINAL_AUDIT")" = success ] \
          || die "target auditor run lost its successful binding"
        echo "merge-queue-final-handshake: PASS — unique final audit verified"
        exit 0
        ;;
      pending) ;;
      *) die "target auditor run did not complete successfully" ;;
    esac
  fi

  [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ] && [ "$ELAPSED" -lt "$TIMEOUT_SECONDS" ] \
    || break
  REMAINING=$((TIMEOUT_SECONDS - ELAPSED))
  [ "$WAIT_SECONDS" -le "$REMAINING" ] || WAIT_SECONDS=$REMAINING
  sleep "$WAIT_SECONDS"
  ELAPSED=$((ELAPSED + WAIT_SECONDS))
  if [ "$WAIT_SECONDS" -gt 0 ] && [ "$WAIT_SECONDS" -lt "$MAX_INTERVAL" ]; then
    WAIT_SECONDS=$((WAIT_SECONDS * 2))
    [ "$WAIT_SECONDS" -le "$MAX_INTERVAL" ] || WAIT_SECONDS=$MAX_INTERVAL
  fi
  ATTEMPT=$((ATTEMPT + 1))
done

if [ "$DISPATCH_RC" -ne 0 ]; then
  die "repository-dispatch outcome is unknown and no exact response arrived"
fi
die "final-audit response did not arrive within the queue timeout"
