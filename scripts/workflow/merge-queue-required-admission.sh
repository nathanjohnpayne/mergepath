#!/usr/bin/env bash
# Required-workflow PR leg: prove an active native queue before admission.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: merge-queue-required-admission.sh --repo owner/repo --pr NUMBER \
  --head-sha SHA --head-ref REF --head-repo owner/repo --base-sha SHA \
  --base-ref BRANCH --default-branch BRANCH \
  --workflow-repository owner/repo --workflow-file-path PATH \
  --workflow-ref REF --workflow-sha SHA
EOF
  exit 2
}

REPO=""
PR_NUMBER=""
EVENT_HEAD_SHA=""
EVENT_HEAD_REF=""
EVENT_HEAD_REPOSITORY=""
EVENT_BASE_SHA=""
EVENT_BASE_REF=""
DEFAULT_BRANCH=""
WORKFLOW_REPOSITORY=""
WORKFLOW_FILE_PATH=""
WORKFLOW_REF=""
WORKFLOW_SHA=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; PR_NUMBER="$2"; shift 2 ;;
    --head-sha) [ "$#" -ge 2 ] || usage; EVENT_HEAD_SHA="$2"; shift 2 ;;
    --head-ref) [ "$#" -ge 2 ] || usage; EVENT_HEAD_REF="$2"; shift 2 ;;
    --head-repo)
      [ "$#" -ge 2 ] || usage; EVENT_HEAD_REPOSITORY="$2"; shift 2 ;;
    --base-sha) [ "$#" -ge 2 ] || usage; EVENT_BASE_SHA="$2"; shift 2 ;;
    --base-ref) [ "$#" -ge 2 ] || usage; EVENT_BASE_REF="$2"; shift 2 ;;
    --default-branch) [ "$#" -ge 2 ] || usage; DEFAULT_BRANCH="$2"; shift 2 ;;
    --workflow-repository)
      [ "$#" -ge 2 ] || usage; WORKFLOW_REPOSITORY="$2"; shift 2 ;;
    --workflow-file-path)
      [ "$#" -ge 2 ] || usage; WORKFLOW_FILE_PATH="$2"; shift 2 ;;
    --workflow-ref) [ "$#" -ge 2 ] || usage; WORKFLOW_REF="$2"; shift 2 ;;
    --workflow-sha) [ "$#" -ge 2 ] || usage; WORKFLOW_SHA="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$REPO" ] && [ -n "$PR_NUMBER" ] && [ -n "$EVENT_HEAD_SHA" ] \
  && [ -n "$EVENT_HEAD_REF" ] && [ -n "$EVENT_HEAD_REPOSITORY" ] \
  && [ -n "$EVENT_BASE_SHA" ] \
  && [ -n "$EVENT_BASE_REF" ] \
  && [ -n "$DEFAULT_BRANCH" ] && [ -n "$WORKFLOW_REPOSITORY" ] \
  && [ -n "$WORKFLOW_FILE_PATH" ] && [ -n "$WORKFLOW_REF" ] \
  && [ -n "$WORKFLOW_SHA" ] || usage
case "$REPO" in */*) ;; *) usage ;; esac
case "$EVENT_HEAD_REPOSITORY" in */*) ;; *) usage ;; esac
case "$PR_NUMBER" in *[!0-9]*|'') usage ;; esac
printf '%s' "$EVENT_HEAD_SHA" \
  | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' || usage
printf '%s' "$EVENT_BASE_SHA" \
  | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' || usage
printf '%s' "$WORKFLOW_SHA" \
  | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' || usage

# GitHub suppresses pull_request_target for some SHA-like head names. That
# event is the trusted path that records a queue-entry attestation, so admit no
# branch whose name could make enrollment silently unobservable.
if printf '%s' "$EVENT_HEAD_REF" \
  | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$'; then
  echo "merge-queue-required-admission: FAIL — SHA-like head branch names are not queue-safe" >&2
  exit 1
fi

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

die() {
  echo "merge-queue-required-admission: FAIL — $*" >&2
  exit 1
}

infra() {
  echo "merge-queue-required-admission: ERROR — $*" >&2
  exit 2
}

for tool in gh jq git; do
  command -v "$tool" >/dev/null 2>&1 \
    || infra "required tool '$tool' is unavailable"
done
[ -n "${GH_TOKEN:-}" ] || infra "GH_TOKEN is required"
[ -r "$ROOT/scripts/lib/gh-api-array.sh" ] \
  || infra "paginated API helper is unavailable"
[ -r "$ROOT/scripts/lib/merge-queue-protection.sh" ] \
  || infra "merge-queue policy is unavailable"
[ -r "$ROOT/scripts/lib/review-policy-scalar.sh" ] \
  || infra "review-policy reader is unavailable"
[ -r "$ROOT/.github/review-policy.yml" ] \
  || infra "governing review policy is unavailable"

# shellcheck source=../lib/gh-api-array.sh
. "$ROOT/scripts/lib/gh-api-array.sh"
# shellcheck source=../lib/merge-queue-protection.sh
. "$ROOT/scripts/lib/merge-queue-protection.sh"
# shellcheck source=../lib/review-policy-scalar.sh
. "$ROOT/scripts/lib/review-policy-scalar.sh"

AUTHOR_IDENTITY=$(review_policy_scalar \
  "$ROOT/.github/review-policy.yml" author_identity) \
  || infra "governing author identity is unreadable"
[ -n "$AUTHOR_IDENTITY" ] || infra "governing policy names no author identity"

CHECKOUT_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) \
  || infra "could not identify the trusted target checkout"
[ "$CHECKOUT_SHA" = "$EVENT_BASE_SHA" ] \
  || die "trusted target checkout is $CHECKOUT_SHA, expected $EVENT_BASE_SHA"
[ "$DEFAULT_BRANCH" = "main" ] && [ "$EVENT_BASE_REF" = "$DEFAULT_BRANCH" ] \
  || die "required-workflow admission is enabled only for main"

# The pull-request files endpoint is mutable while it is paginated. A branch
# writer could otherwise move A -> B -> A around that read and make mixed pages
# look stable. The event SHAs name immutable trees, so this is the authority for
# the workflow-path freeze; the REST read below remains defense in depth.
RESOLVED_HEAD_SHA=$(
  git -C "$ROOT" rev-parse --verify "$EVENT_HEAD_SHA^{commit}" 2>/dev/null
) || infra "event head commit is unavailable in the trusted checkout"
[ "$RESOLVED_HEAD_SHA" = "$EVENT_HEAD_SHA" ] \
  || die "event head does not resolve to its exact commit"
if git -C "$ROOT" diff --quiet --no-ext-diff \
  "$EVENT_BASE_SHA" "$EVENT_HEAD_SHA" -- .github/workflows; then
  :
else
  diff_status=$?
  [ "$diff_status" -eq 1 ] \
    || infra "could not compare immutable base and head workflow trees"
  die "candidate changes a target workflow"
fi

ROLLOUT_CONFIG=$(mergepath_merge_queue_rollout_config \
  "$ROOT/.github/review-policy.yml") \
  || infra "merge-queue rollout configuration is malformed"
printf '%s' "$ROLLOUT_CONFIG" | jq -e '
  .mode == "canary" or .mode == "enabled"
' >/dev/null 2>&1 || die "merge-queue rollout is not enabled for admission"
mergepath_merge_queue_validate_required_workflow "$ROLLOUT_CONFIG" "$REPO" \
  "$WORKFLOW_REPOSITORY" "$WORKFLOW_FILE_PATH" "$WORKFLOW_REF" \
  "$WORKFLOW_SHA" \
  || die "runtime workflow identity does not match the predeclared organization rule"

# A target-local merge_group workflow starts as soon as GitHub creates the
# synthetic group, before this trusted group's authorization verdict exists.
# Such a workflow could explicitly request repository secrets even though the
# trusted bridge later rejects the merge. While the queue is active, workflow
# changes therefore use the disabled/manual maintenance lane and are rejected
# by this pinned admission leg before GitHub may enqueue the PR.
read_pr_core() {
  local rest graph stack_query
  rest=$(gh api "repos/$REPO/pulls/$PR_NUMBER") || return 1
  # shellcheck disable=SC2016 # GraphQL variables are intentionally literal.
  stack_query='query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){
      nameWithOwner
      pullRequest(number:$number){id stack{id}}
    }
  }'
  graph=$(gh api graphql -f query="$stack_query" -f owner="${REPO%%/*}" \
    -f name="${REPO#*/}" -F number="$PR_NUMBER") || return 1
  jq -cne --argjson rest "$rest" --argjson graph "$graph" '
    select((($graph.errors // []) | length) == 0) |
    $graph.data.repository as $repository |
    $repository.pullRequest as $pull_request |
    select(
      $repository != null and
      ($repository.nameWithOwner | type == "string" and length > 0) and
      $pull_request != null and
      ($pull_request.id | type == "string" and length > 0)
    ) |
    $rest | {
      number,state,draft,merged,
      head:.head.sha,head_ref:.head.ref,
      head_repository:.head.repo.full_name,
      base_ref:.base.ref,base_sha:.base.sha,
      base_repository:.base.repo.full_name,
      author:.user.login,changed_files,
      graphql_repository:$repository.nameWithOwner,
      pull_request_id:$pull_request.id,stack:$pull_request.stack
    }
  '
}

validate_pr_core() {
  printf '%s' "$1" | jq -e \
    --argjson pr "$PR_NUMBER" --arg repo "$REPO" \
    --arg head "$EVENT_HEAD_SHA" --arg head_ref "$EVENT_HEAD_REF" \
    --arg head_repo "$EVENT_HEAD_REPOSITORY" \
    --arg base "$EVENT_BASE_SHA" --arg branch "$DEFAULT_BRANCH" \
    --arg author "$AUTHOR_IDENTITY" '
      type == "object" and .number == $pr and
      .state == "open" and (.draft | type == "boolean") and .merged == false and
      .head == $head and .head_ref == $head_ref and
      .head_repository == $head_repo and
      .head_repository == $repo and
      .base_ref == $branch and .base_sha == $base and
      .base_repository == $repo and .graphql_repository == $repo and
      .author == $author and
      (.pull_request_id | type == "string" and length > 0) and
      .stack == null and
      (.changed_files | type == "number" and floor == . and . >= 0)
    ' >/dev/null 2>&1
}

pr_signature() {
  printf '%s' "$1" | jq -ceS .
}

read_changed_files() {
  gh_api_array "repos/$REPO/pulls/$PR_NUMBER/files?per_page=100" \
    "candidate changed files" || {
      echo "$GH_API_ARRAY_ERROR" >&2
      return 1
    }
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

initial_pr=$(read_pr_core) || infra "could not read the candidate PR"
validate_pr_core "$initial_pr" \
  || die "candidate PR identity, head, repository, author, or base is not queue-safe"
expected_file_count=$(printf '%s' "$initial_pr" | jq -er \
  '.changed_files | select(type == "number" and floor == . and . >= 0)') \
  || infra "candidate changed-file count is unreadable"
changed_files=$(read_changed_files) \
  || infra "could not read complete candidate changed files"
printf '%s' "$changed_files" | jq -e --argjson count "$expected_file_count" '
  def workflow_path:
    . == ".github/workflows" or startswith(".github/workflows/");
  type == "array" and length == $count and
  ([.[].filename] | length) == ([.[].filename] | unique | length) and
  all(.[];
    type == "object" and
    (.filename | type == "string" and length > 0) and
    (.status | type == "string" and length > 0) and
    ((has("previous_filename") | not) or
      (.previous_filename | type == "string" and length > 0)) and
    (.filename | workflow_path | not) and
    ((.previous_filename // "") | workflow_path | not))
' >/dev/null 2>&1 \
  || die "candidate changed-file evidence is incomplete, malformed, duplicated, or includes a target workflow"
after_files_pr=$(read_pr_core) \
  || infra "could not re-read the candidate PR after changed files"
validate_pr_core "$after_files_pr" \
  || die "candidate PR changed while workflow-path admission was evaluated"
[ "$(pr_signature "$after_files_pr")" = "$(pr_signature "$initial_pr")" ] \
  || die "candidate PR changed while workflow-path admission was evaluated"

effective_rules=$(read_effective_rules) \
  || infra "could not read complete effective default-branch rules"
mergepath_merge_queue_validate_effective_rules "$effective_rules" \
  "$ROLLOUT_CONFIG" "$REPO" \
  || die "active rules do not require the exact singleton queue and pinned workflows"

final_pr=$(read_pr_core) \
  || infra "could not perform the final candidate PR read"
validate_pr_core "$final_pr" \
  || die "candidate PR changed before admission completed"
[ "$(pr_signature "$final_pr")" = "$(pr_signature "$initial_pr")" ] \
  || die "candidate PR changed before admission completed"

draft_state=$(printf '%s' "$final_pr" | jq -r '.draft')
echo "merge-queue-required-admission: PASS — PR #$PR_NUMBER at $EVENT_HEAD_SHA changes no target workflow, is standalone, and the pinned queue rules govern $REPO:$DEFAULT_BRANCH (draft=$draft_state; final merge-group authorization still requires draft=false)"
