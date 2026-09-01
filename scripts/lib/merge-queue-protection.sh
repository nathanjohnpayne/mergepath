# shellcheck shell=bash
# scripts/lib/merge-queue-protection.sh
#
# Side-effect-free rollout reader plus administrative topology proof for
# Mergepath's initial singleton merge queue. Trusted default-branch admission
# callers use the topology proof before preserving a native arm. The
# organization-ruleset required workflow performs public checks with its
# read-only target token, while a source-pinned handshake delegates the private
# administrative inventory proof to the protected target-base final auditor.

MERGEPATH_MERGE_QUEUE_ACTIONS_APP_ID=15368
MERGEPATH_MERGE_QUEUE_ENVIRONMENT=merge-queue-policy
readonly MERGEPATH_MERGE_QUEUE_ACTIONS_APP_ID
readonly MERGEPATH_MERGE_QUEUE_ENVIRONMENT

# mergepath_merge_queue_rollout_config POLICY_FILE
#
# Reads the trusted default-branch rollout fence. Missing keys are disabled.
# Canary mode binds one PR and one exact head; enabled mode deliberately
# rejects a leftover canary selector. Both live modes require an activation
# timestamp so a queue entry created before the audited rollout cannot be
# adopted after the fact.
mergepath_merge_queue_rollout_config() {
  [ "$#" -eq 1 ] || return 1
  local policy="$1" mode canary_pr canary_head promotion_pr
  local enabled_at repository_ruleset_id workflow_ruleset_id
  local target_repository_id workflow_repository
  local workflow_repository_id workflow_ref workflow_sha
  type review_policy_scalar >/dev/null 2>&1 || return 1
  [ -r "$policy" ] || return 1
  mode=$(review_policy_scalar "$policy" merge_queue_rollout_mode)
  canary_pr=$(review_policy_scalar "$policy" merge_queue_canary_pr)
  canary_head=$(review_policy_scalar "$policy" merge_queue_canary_head)
  promotion_pr=$(review_policy_scalar "$policy" merge_queue_promotion_pr)
  enabled_at=$(review_policy_scalar "$policy" merge_queue_enabled_at)
  repository_ruleset_id=$(review_policy_scalar "$policy" \
    merge_queue_repository_ruleset_id)
  workflow_ruleset_id=$(review_policy_scalar "$policy" \
    merge_queue_workflow_ruleset_id)
  target_repository_id=$(review_policy_scalar "$policy" \
    merge_queue_target_repository_id)
  workflow_repository=$(review_policy_scalar "$policy" \
    merge_queue_required_workflow_repository)
  workflow_repository_id=$(review_policy_scalar "$policy" \
    merge_queue_required_workflow_repository_id)
  workflow_ref=$(review_policy_scalar "$policy" \
    merge_queue_required_workflow_ref)
  workflow_sha=$(review_policy_scalar "$policy" \
    merge_queue_required_workflow_sha)
  [ -n "$mode" ] || mode=disabled
  [ -n "$canary_pr" ] || canary_pr=0
  [ -n "$promotion_pr" ] || promotion_pr=0
  [ -n "$repository_ruleset_id" ] || repository_ruleset_id=0
  [ -n "$workflow_ruleset_id" ] || workflow_ruleset_id=0
  [ -n "$target_repository_id" ] || target_repository_id=0
  [ -n "$workflow_repository_id" ] || workflow_repository_id=0
  case "$canary_pr" in *[!0-9]*|'') return 1 ;; esac
  case "$promotion_pr" in *[!0-9]*|'') return 1 ;; esac
  case "$repository_ruleset_id" in *[!0-9]*|'') return 1 ;; esac
  case "$workflow_ruleset_id" in *[!0-9]*|'') return 1 ;; esac
  case "$target_repository_id" in *[!0-9]*|'') return 1 ;; esac
  case "$workflow_repository_id" in *[!0-9]*|'') return 1 ;; esac
  case "$mode" in
    disabled)
      [ "$canary_pr" -eq 0 ] && [ -z "$canary_head" ] \
        && [ "$promotion_pr" -eq 0 ] \
        && [ -z "$enabled_at" ] \
        && [ "$repository_ruleset_id" -eq 0 ] \
        && [ "$workflow_ruleset_id" -eq 0 ] \
        && [ "$target_repository_id" -eq 0 ] \
        && [ -z "$workflow_repository" ] \
        && [ "$workflow_repository_id" -eq 0 ] \
        && [ -z "$workflow_ref" ] && [ -z "$workflow_sha" ] || return 1
      ;;
    canary)
      [ "$canary_pr" -gt 0 ] && [ "$promotion_pr" -gt 0 ] \
        && [ "$canary_pr" -ne "$promotion_pr" ] \
        && [ "$repository_ruleset_id" -gt 0 ] \
        && [ "$workflow_ruleset_id" -gt 0 ] \
        && [ "$repository_ruleset_id" -ne "$workflow_ruleset_id" ] \
        && [ "$target_repository_id" -gt 0 ] \
        && [ "$workflow_repository_id" -gt 0 ] || return 1
      case "$workflow_repository" in */*) ;; *) return 1 ;; esac
      [ "${workflow_repository#*/}" = "${workflow_repository##*/}" ] \
        || return 1
      printf '%s' "$canary_head" \
        | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' || return 1
      printf '%s' "$enabled_at" \
        | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
        || return 1
      printf '%s' "$workflow_ref" \
        | grep -Eq '^[^[:space:]]+$' || return 1
      printf '%s' "$workflow_sha" \
        | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' || return 1
      ;;
    enabled)
      [ "$canary_pr" -eq 0 ] && [ -z "$canary_head" ] \
        && [ "$promotion_pr" -eq 0 ] \
        && [ "$repository_ruleset_id" -gt 0 ] \
        && [ "$workflow_ruleset_id" -gt 0 ] \
        && [ "$repository_ruleset_id" -ne "$workflow_ruleset_id" ] \
        && [ "$target_repository_id" -gt 0 ] \
        && [ "$workflow_repository_id" -gt 0 ] || return 1
      case "$workflow_repository" in */*) ;; *) return 1 ;; esac
      [ "${workflow_repository#*/}" = "${workflow_repository##*/}" ] \
        || return 1
      printf '%s' "$enabled_at" \
        | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
        || return 1
      printf '%s' "$workflow_ref" \
        | grep -Eq '^[^[:space:]]+$' || return 1
      printf '%s' "$workflow_sha" \
        | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' || return 1
      ;;
    *) return 1 ;;
  esac
  jq -cnS --arg mode "$mode" --argjson canary_pr "$canary_pr" \
    --arg canary_head "$canary_head" --argjson promotion_pr "$promotion_pr" \
    --arg enabled_at "$enabled_at" \
    --argjson repository_ruleset_id "$repository_ruleset_id" \
    --argjson workflow_ruleset_id "$workflow_ruleset_id" \
    --argjson target_repository_id "$target_repository_id" \
    --arg workflow_repository "$workflow_repository" \
    --argjson workflow_repository_id "$workflow_repository_id" \
    --arg workflow_ref "$workflow_ref" --arg workflow_sha "$workflow_sha" \
    '{mode:$mode,canary_pr:$canary_pr,canary_head:$canary_head,
      promotion_pr:$promotion_pr,enabled_at:$enabled_at,
      repository_ruleset_id:$repository_ruleset_id,
      workflow_ruleset_id:$workflow_ruleset_id,
      target_repository_id:$target_repository_id,
      workflow_repository:$workflow_repository,
      workflow_repository_id:$workflow_repository_id,
      workflow_ref:$workflow_ref,workflow_sha:$workflow_sha}'
}

# mergepath_merge_queue_validate_required_workflow CONFIG TARGET_REPO
#   WORKFLOW_REPOSITORY WORKFLOW_FILE_PATH WORKFLOW_REF WORKFLOW_SHA
#
# Binds the runtime job identity exposed by GitHub Actions to the source
# repository/path/ref/SHA that the target base predeclares. The target job's
# GITHUB_TOKEN is repository-scoped, so this runtime check deliberately never
# reads a private source repository through that token. The active ruleset
# separately binds the source repository's numeric id; administrator rollout
# proof binds that id to the same source name and its safe metadata.
mergepath_merge_queue_validate_required_workflow() {
  [ "$#" -eq 6 ] || return 1
  local config="$1" target="$2" workflow_repository="$3"
  local workflow_file_path="$4" workflow_ref="$5" workflow_sha="$6"
  local expected_repository expected_path expected_ref expected_sha
  local expected_target_id expected_source_id target_snapshot
  expected_repository=$(printf '%s' "$config" | jq -er '
    .workflow_repository | select(type == "string" and length > 0)
  ') || return 1
  expected_target_id=$(printf '%s' "$config" | jq -er '
    .target_repository_id | select(type == "number" and floor == . and . > 0)
  ') || return 1
  expected_source_id=$(printf '%s' "$config" | jq -er '
    .workflow_repository_id |
    select(type == "number" and floor == . and . > 0)
  ') || return 1
  expected_ref=$(printf '%s' "$config" | jq -er '
    .workflow_ref | select(type == "string" and length > 0)
  ') || return 1
  expected_sha=$(printf '%s' "$config" | jq -er '
    .workflow_sha |
    select(type == "string" and test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$"))
  ') || return 1
  expected_path='.github/workflows/mergepath-merge-queue-authorization.yml'
  [ "$workflow_repository" = "$expected_repository" ] \
    && [ "$workflow_repository" != "$target" ] \
    && [ "${workflow_repository%%/*}" = "${target%%/*}" ] \
    && [ "$expected_source_id" -ne "$expected_target_id" ] \
    && [ "$workflow_file_path" = "$expected_path" ] \
    && [ "$workflow_sha" = "$expected_sha" ] \
    && [ "$workflow_ref" = \
      "$workflow_repository/$workflow_file_path@$expected_ref" ] \
    || return 1
  target_snapshot=$(gh api "repos/$target") || return 1
  jq -en --argjson target "$target_snapshot" \
    --arg target_name "$target" --argjson target_id "$expected_target_id" '
      $target.id == $target_id and $target.full_name == $target_name and
      $target.owner.type == "Organization"
    ' >/dev/null 2>&1
}

# mergepath_merge_queue_validate_effective_rules RULES_JSON CONFIG REPO
#   [MERGE_METHOD]
#
# The effective-rules endpoint returns active rules only and needs metadata
# read permission. It cannot prove the private bypass list, so this runtime
# proof supplements rather than replaces the administrator rollout audit.
mergepath_merge_queue_validate_effective_rules() {
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] || return 1
  local rules="$1" config="$2" repo="$3" merge_method="${4:-}"
  local owner=${repo%%/*}
  case "$repo" in */*) ;; *) return 1 ;; esac
  case "$merge_method" in ''|MERGE|SQUASH|REBASE) ;; *) return 1 ;; esac
  printf '%s' "$rules" | jq -e \
    --arg owner "$owner" --arg repo "$repo" --arg method "$merge_method" \
    --argjson rollout "$config" '
      type == "array" and
      ([.[] | select(.type == "merge_queue")] | length) == 1 and
      ([.[] | select(.type == "workflows")] | length) == 1 and
      ([.[] | select(.type == "merge_queue")][0] as $rule |
        $rule.ruleset_id == $rollout.repository_ruleset_id and
        $rule.ruleset_source_type == "Repository" and
        $rule.ruleset_source == $repo and
        ($rule.parameters as $mq |
          $mq.grouping_strategy == "ALLGREEN" and
          $mq.max_entries_to_build == 1 and
          $mq.max_entries_to_merge == 1 and
          $mq.min_entries_to_merge == 1 and
          (($method == "" and
            (["MERGE","SQUASH","REBASE"] | index($mq.merge_method)) != null) or
           ($method != "" and $mq.merge_method == $method)) and
          ($mq.check_response_timeout_minutes | type == "number" and
            floor == . and . > 0) and
          ($mq.min_entries_to_merge_wait_minutes | type == "number" and
            floor == . and . >= 0))) and
      ([.[] | select(.type == "workflows")][0] as $rule |
        $rule.ruleset_id == $rollout.workflow_ruleset_id and
        $rule.ruleset_source_type == "Organization" and
        $rule.ruleset_source == $owner and
        ($rule.parameters as $wf |
          $wf.do_not_enforce_on_create == false and
          ($wf.workflows | type == "array" and length == 2) and
          all($wf.workflows[];
            .repository_id == $rollout.workflow_repository_id and
            .ref == $rollout.workflow_ref and .sha == $rollout.workflow_sha) and
          ([$wf.workflows[].path] | sort) == [
            ".github/workflows/mergepath-merge-queue-authorization.yml",
            ".github/workflows/mergepath-repo-lint.yml"
          ]))
    ' >/dev/null 2>&1
}

# mergepath_merge_queue_rollout_is_active CONFIG NOW
#
# rc 0: canary/enabled rollout whose activation instant has arrived.
# rc 4: valid disabled rollout.
# rc 5: valid canary/enabled rollout scheduled in the future. Cleanup callers
#       must not mutate across that activation boundary because disable has no
#       compare-and-swap precondition.
# rc 1: malformed config or clock. Cleanup callers use this distinction so an
#       active rollout can never fall through to an unconditional disable.
mergepath_merge_queue_rollout_is_active() {
  [ "$#" -eq 2 ] || return 1
  local config="$1" now="$2" mode enabled_at
  mode=$(printf '%s' "$config" \
    | jq -er '.mode | select(type == "string")') || return 1
  case "$mode" in
    disabled) return 4 ;;
    canary|enabled) ;;
    *) return 1 ;;
  esac
  enabled_at=$(printf '%s' "$config" \
    | jq -er '.enabled_at | select(type == "string")') || return 1
  printf '%s' "$now" | grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || return 1
  printf '%s' "$enabled_at" | grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || return 1
  jq -en --arg value "$now" '$value | fromdateiso8601' >/dev/null 2>&1 \
    || return 1
  jq -en --arg value "$enabled_at" '$value | fromdateiso8601' \
    >/dev/null 2>&1 || return 1
  jq -en --arg now "$now" --arg enabled "$enabled_at" '
    ($now | fromdateiso8601) >= ($enabled | fromdateiso8601)
  ' >/dev/null 2>&1 || return 5
}

# mergepath_merge_queue_rollout_role CONFIG PR HEAD
#
# Prints canary, promotion, or enabled. rc 4 is valid but disabled/out of scope.
mergepath_merge_queue_rollout_role() {
  [ "$#" -eq 3 ] || return 1
  local config="$1" pr="$2" head="$3"
  local mode canary_pr canary_head promotion_pr
  case "$pr" in *[!0-9]*|'') return 1 ;; esac
  printf '%s' "$head" \
    | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' || return 1
  mode=$(printf '%s' "$config" | jq -er '.mode | select(type == "string")') \
    || return 1
  canary_pr=$(printf '%s' "$config" \
    | jq -er '.canary_pr | select(type == "number" and floor == . and . >= 0)') \
    || return 1
  canary_head=$(printf '%s' "$config" \
    | jq -er '.canary_head | select(type == "string")') || return 1
  promotion_pr=$(printf '%s' "$config" \
    | jq -er '.promotion_pr | select(type == "number" and floor == . and . >= 0)') \
    || return 1
  case "$mode" in
    disabled) return 4 ;;
    canary)
      if [ "$pr" -eq "$canary_pr" ] && [ "$head" = "$canary_head" ]; then
        printf '%s\n' canary
      # The trusted base predeclares the promotion PR, while the later native
      # owner action binds its then-current exact head. Requiring the future
      # promotion commit hash here would make the canary base contain a hash
      # whose value depends on that same base commit.
      elif [ "$pr" -eq "$promotion_pr" ]; then
        printf '%s\n' promotion
      else
        return 4
      fi
      ;;
    enabled)
      [ "$canary_pr" -eq 0 ] && [ -z "$canary_head" ] \
        && [ "$promotion_pr" -eq 0 ] || return 1
      printf '%s\n' enabled
      ;;
    *) return 1 ;;
  esac
}

# mergepath_merge_queue_rollout_entry_scope CONFIG PR HEAD ENQUEUED_AT CREATED_AT
#
# Adds the activation-epoch check to rollout_role and prints the same role.
# Enabled mode also excludes PRs created before activation; the predeclared
# canary and transition slots are intentional exceptions.
mergepath_merge_queue_rollout_entry_scope() {
  [ "$#" -eq 5 ] || return 1
  local config="$1" pr="$2" head="$3" enqueued_at="$4" created_at="$5"
  local enabled_at role
  role=$(mergepath_merge_queue_rollout_role "$config" "$pr" "$head") || return $?
  enabled_at=$(printf '%s' "$config" \
    | jq -er '.enabled_at | select(type == "string")') || return 1
  jq -en --arg enabled "$enabled_at" --arg enqueued "$enqueued_at" '
    try (($enqueued | fromdateiso8601) >= ($enabled | fromdateiso8601))
    catch false
  ' >/dev/null 2>&1 || return 1
  if [ "$role" = "enabled" ]; then
    jq -en --arg enabled "$enabled_at" --arg created "$created_at" '
      try (($created | fromdateiso8601) >= ($enabled | fromdateiso8601))
      catch false
    ' >/dev/null 2>&1 || return 1
  fi
  printf '%s\n' "$role"
}

# mergepath_merge_queue_verify_promotion_prerequisite CONFIG REPO BRANCH
#   AUTHOR LIVE_BASE_SHA
#
# Promotion is predeclared before queue activation, but it is not eligible
# until the exact configured canary head has merged into this live base. This
# makes the later owner enqueue the explicit canary-to-enabled decision.
mergepath_merge_queue_verify_promotion_prerequisite() {
  [ "$#" -eq 5 ] || return 1
  local config="$1" repo="$2" branch="$3" author="$4" live_base="$5"
  local canary_pr canary_head snapshot merge_sha compare
  canary_pr=$(printf '%s' "$config" | jq -er '
    .canary_pr | select(type == "number" and floor == . and . > 0)
  ') || return 1
  canary_head=$(printf '%s' "$config" | jq -er '
    .canary_head |
    select(type == "string" and test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$"))
  ') || return 1
  snapshot=$(gh api "repos/$repo/pulls/$canary_pr") || return 1
  printf '%s' "$snapshot" | jq -e \
    --arg repo "$repo" --arg branch "$branch" --arg author "$author" \
    --arg head "$canary_head" '
      .merged == true and .state == "closed" and
      .head.sha == $head and .head.repo.full_name == $repo and
      .base.ref == $branch and .base.repo.full_name == $repo and
      .user.login == $author and
      (.merged_at | type == "string" and length > 0) and
      (.merge_commit_sha | type == "string" and
        test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$"))
    ' >/dev/null 2>&1 || return 1
  merge_sha=$(printf '%s' "$snapshot" | jq -r .merge_commit_sha) || return 1
  compare=$(gh api "repos/$repo/compare/$merge_sha...$live_base") || return 1
  printf '%s' "$compare" | jq -e --arg merge "$merge_sha" '
    (.status == "identical" or .status == "ahead") and
    .base_commit.sha == $merge and .merge_base_commit.sha == $merge
  ' >/dev/null 2>&1
}

# mergepath_merge_queue_verify_promotion_transition CONFIG REPO HEAD_SHA
#
# Reads the predeclared transition head as inert data and prints `enabled` or
# `disabled` only when it clears the canary selectors exactly. Promotion keeps
# the original activation instant; rollback clears it. The content is never
# executed. This lets the same predeclared slot finish or abort the canary.
mergepath_merge_queue_verify_promotion_transition() {
  [ "$#" -eq 3 ] || return 1
  local config="$1" repo="$2" head="$3" policy_file candidate rc=0
  case "$repo" in */*) ;; *) return 1 ;; esac
  printf '%s' "$head" \
    | grep -Eq '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$' || return 1
  printf '%s' "$config" | jq -e '.mode == "canary"' >/dev/null 2>&1 \
    || return 1
  type review_policy_scalar >/dev/null 2>&1 || return 1
  policy_file=$(mktemp) || return 1
  if ! gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$repo/contents/.github/review-policy.yml?ref=$head" \
    > "$policy_file"; then
    rm -f "$policy_file"
    return 1
  fi
  candidate=$(mergepath_merge_queue_rollout_config "$policy_file") || rc=1
  rm -f "$policy_file"
  [ "$rc" -eq 0 ] || return 1
  jq -ern --argjson base "$config" --argjson candidate "$candidate" '
    if $base.mode != "canary" or
      $candidate.canary_pr != 0 or $candidate.canary_head != "" or
      $candidate.promotion_pr != 0
    then empty
    elif $candidate.mode == "enabled" and
      $candidate.enabled_at == $base.enabled_at and
      $candidate.repository_ruleset_id == $base.repository_ruleset_id and
      $candidate.workflow_ruleset_id == $base.workflow_ruleset_id and
      $candidate.target_repository_id == $base.target_repository_id and
      $candidate.workflow_repository == $base.workflow_repository and
      $candidate.workflow_repository_id == $base.workflow_repository_id and
      $candidate.workflow_ref == $base.workflow_ref and
      $candidate.workflow_sha == $base.workflow_sha
    then "enabled"
    elif $candidate.mode == "disabled" and $candidate.enabled_at == ""
    then "disabled"
    else empty
    end
  '
}

# GitHub's live schema does not expose BranchProtectionRule.requiresMergeQueue.
# The administrative audit therefore binds the live queue twice (implicit and
# explicit branch lookup), the exact classic protection, one active repository
# ruleset that requires the singleton queue, and one active organization
# ruleset that requires the SHA-pinned workflows. Runtime merge-group
# authorization does not use this admin-only reader; GitHub's aggregated
# effective rules and required-workflow rule are its native gate.
# shellcheck disable=SC2016 # GraphQL variables are intentionally literal.
MERGEPATH_MERGE_QUEUE_TOPOLOGY_QUERY='query($owner:String!,$name:String!,$branch:String!){
  viewer{login}
  repository(owner:$owner,name:$name){
    databaseId nameWithOwner viewerPermission visibility
    owner{__typename login}
    defaultBranchRef{name prefix target{... on Commit{oid}}}
    implicitQueue:mergeQueue{
      id repository{nameWithOwner}
      configuration{
        maximumEntriesToBuild maximumEntriesToMerge minimumEntriesToMerge
        mergeMethod mergingStrategy
      }
    }
    explicitQueue:mergeQueue(branch:$branch){
      id repository{nameWithOwner}
      configuration{
        maximumEntriesToBuild maximumEntriesToMerge minimumEntriesToMerge
        mergeMethod mergingStrategy
      }
    }
    branchProtectionRules(first:2){
      totalCount pageInfo{hasNextPage endCursor}
      nodes{
        pattern
        matchingRefs(first:2){
          totalCount pageInfo{hasNextPage endCursor}
          nodes{id name prefix target{... on Commit{oid}}}
        }
      }
    }
  }
}'
readonly MERGEPATH_MERGE_QUEUE_TOPOLOGY_QUERY

mergepath_merge_queue_read_rulesets() {
  [ "$#" -eq 1 ] || return 1
  gh_api_array \
    "repos/$1/rulesets?includes_parents=true&targets=branch&per_page=100" \
    "repository and inherited rulesets" || {
      echo "$GH_API_ARRAY_ERROR" >&2
      return 1
    }
}

# mergepath_merge_queue_read_environment_branch_policies REPO
#
# The deployment-branch-policy endpoint paginates an object whose list lives
# under `branch_policies`, rather than returning the array stream handled by
# gh_api_array. Read every page, require stable advertised totals, and reject
# duplicate/missing rows before topology validation sees the result.
mergepath_merge_queue_read_environment_branch_policies() {
  [ "$#" -eq 1 ] || return 1
  local repo="$1" raw
  raw=$(gh api --paginate \
    "repos/$repo/environments/$MERGEPATH_MERGE_QUEUE_ENVIRONMENT/deployment-branch-policies?per_page=100") \
    || return 1
  printf '%s\n' "$raw" | jq -sce '
    select(length > 0) |
    select(all(.[];
      type == "object" and
      (.total_count | type == "number" and floor == . and . >= 0) and
      (.branch_policies | type == "array"))) |
    .[0].total_count as $total |
    select(all(.[]; .total_count == $total)) |
    {total_count:$total,
     branch_policies:[.[] | .branch_policies[]]} |
    select((.branch_policies | length) == .total_count) |
    select((.branch_policies | map(.id) | length) ==
      (.branch_policies | map(.id) | unique | length))
  '
}

# mergepath_merge_queue_read_secret_inventory ENDPOINT LABEL
#
# Actions secret-list endpoints paginate `{total_count,secrets:[...]}` objects.
# Values are never returned. This helper proves complete name placement so a
# repository/organization secret cannot silently shadow the protected
# environment when a workflow forgets or loses its environment binding.
mergepath_merge_queue_read_secret_inventory() {
  [ "$#" -eq 2 ] || return 1
  local endpoint="$1" label="$2" raw
  raw=$(gh api --paginate "$endpoint") || return 1
  printf '%s\n' "$raw" | jq -sce --arg label "$label" '
    select(length > 0) |
    select(all(.[];
      type == "object" and
      (.total_count | type == "number" and floor == . and . >= 0) and
      (.secrets | type == "array") and
      all(.secrets[];
        (.name | type == "string" and length > 0) and
        (.created_at | type == "string" and length > 0) and
        (.updated_at | type == "string" and length > 0)))) |
    .[0].total_count as $total |
    select(all(.[]; .total_count == $total)) |
    {inventory:$label,total_count:$total,secrets:[.[] | .secrets[]]} |
    select((.secrets | length) == .total_count) |
    select((.secrets | map(.name) | length) ==
      (.secrets | map(.name) | unique | length))
  '
}

# mergepath_merge_queue_validate_classic_protection PROTECTION_JSON
#
# rc 0: the complete classic protection object requires exactly the six
#       reviewed queue contexts, all pinned to GitHub Actions, with strict
#       base freshness, administrator enforcement, stale-review dismissal,
#       conversation resolution, and no pull-request-review bypass actors.
# rc 1: any field is missing, malformed, permissive, or different.
mergepath_merge_queue_validate_classic_protection() {
  [ "$#" -eq 1 ] || return 1
  printf '%s' "$1" | jq -e \
    --argjson actions_app_id "$MERGEPATH_MERGE_QUEUE_ACTIONS_APP_ID" '
      def queue_contexts: [
        "Label Gate",
        "Self-Review Required",
        "CodeRabbit unresolved blocking findings",
        "Codex P1 unresolved threads",
        "Merge clearance gate",
        "lint"
      ] | sort;
      type == "object" and
      (.required_status_checks | type == "object") and
      .required_status_checks.strict == true and
      (.required_status_checks.contexts | type == "array") and
      all(.required_status_checks.contexts[]; type == "string" and length > 0) and
      ([.required_status_checks.contexts[]] | sort) == queue_contexts and
      (.required_status_checks.checks | type == "array") and
      all(.required_status_checks.checks[];
        (.context | type == "string" and length > 0) and
        .app_id == $actions_app_id) and
      ([.required_status_checks.checks[].context] | sort) == queue_contexts and
      (.enforce_admins | type == "object") and
      .enforce_admins.enabled == true and
      (.required_pull_request_reviews | type == "object") and
      .required_pull_request_reviews.dismiss_stale_reviews == true and
      (.required_pull_request_reviews | has("bypass_pull_request_allowances")) and
      ((.required_pull_request_reviews.bypass_pull_request_allowances == null) or
        ((.required_pull_request_reviews.bypass_pull_request_allowances | type) == "object" and
         (.required_pull_request_reviews.bypass_pull_request_allowances.users | type) == "array" and
         (.required_pull_request_reviews.bypass_pull_request_allowances.users | length) == 0 and
         (.required_pull_request_reviews.bypass_pull_request_allowances.teams | type) == "array" and
         (.required_pull_request_reviews.bypass_pull_request_allowances.teams | length) == 0 and
         (.required_pull_request_reviews.bypass_pull_request_allowances.apps | type) == "array" and
         (.required_pull_request_reviews.bypass_pull_request_allowances.apps | length) == 0)) and
      (.required_conversation_resolution | type == "object") and
      .required_conversation_resolution.enabled == true
    ' >/dev/null 2>&1
}

# mergepath_merge_queue_read_topology REPO DEFAULT_BRANCH
#   REPOSITORY_RULESET_ID WORKFLOW_RULESET_ID WORKFLOW_REPOSITORY_ID
#
# rc 0: stdout is one JSON snapshot containing the same-response GraphQL
#       identity/queue/rule proof plus complete inherited rulesets, source
#       workflow state, and the classic branch-protection object.
# rc 1: any read, pagination, encoding, or JSON-shape step failed.
#
# Prerequisite: callers source scripts/lib/gh-api-array.sh first.
mergepath_merge_queue_read_topology() {
  [ "$#" -eq 5 ] || return 1
  local repo="$1" branch="$2" repository_ruleset_id="$3"
  local workflow_ruleset_id="$4" workflow_repository_id="$5"
  local owner name raw graph rulesets repository_ruleset workflow_ruleset
  local source_repo source_repo_name
  local source_authorization_workflow source_repo_lint_workflow
  local encoded protection source_token environment branch_policies
  local repository_secrets organization_secrets environment_secrets
  case "$repo" in */*) ;; *) return 1 ;; esac
  owner=${repo%%/*}
  name=${repo#*/}
  case "$owner:$name" in :*|*:|*:*/*) return 1 ;; esac
  [ -n "$branch" ] || return 1
  case "$repository_ruleset_id" in *[!0-9]*|'') return 1 ;; esac
  [ "$repository_ruleset_id" -gt 0 ] || return 1
  case "$workflow_ruleset_id" in *[!0-9]*|'') return 1 ;; esac
  [ "$workflow_ruleset_id" -gt 0 ] || return 1
  case "$workflow_repository_id" in *[!0-9]*|'') return 1 ;; esac
  [ "$workflow_repository_id" -gt 0 ] || return 1
  type gh_api_array >/dev/null 2>&1 || return 1
  source_token=${MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN:-}
  [ -n "$source_token" ] || return 1

  raw=$(gh api graphql -f query="$MERGEPATH_MERGE_QUEUE_TOPOLOGY_QUERY" \
    -f owner="$owner" -f name="$name" -f branch="$branch") || return 1
  graph=$(printf '%s' "$raw" | jq -ce '
    select(((.errors // []) | length) == 0) |
    .data.repository as $repo |
    select($repo != null) |
    {
      viewer_login: .data.viewer.login,
      repository_id: $repo.databaseId,
      repository: $repo.nameWithOwner,
      viewer_permission: $repo.viewerPermission,
      visibility: $repo.visibility,
      owner_type: $repo.owner.__typename,
      owner_login: $repo.owner.login,
      default_branch: {
        name: $repo.defaultBranchRef.name,
        prefix: $repo.defaultBranchRef.prefix,
        oid: $repo.defaultBranchRef.target.oid
      },
      implicit_queue: (if $repo.implicitQueue == null then null else {
        id: $repo.implicitQueue.id,
        repository: $repo.implicitQueue.repository.nameWithOwner,
        configuration: $repo.implicitQueue.configuration
      } end),
      explicit_queue: (if $repo.explicitQueue == null then null else {
        id: $repo.explicitQueue.id,
        repository: $repo.explicitQueue.repository.nameWithOwner,
        configuration: $repo.explicitQueue.configuration
      } end),
      protection_rules: {
        total_count: $repo.branchProtectionRules.totalCount,
        has_next: $repo.branchProtectionRules.pageInfo.hasNextPage,
        end_cursor: $repo.branchProtectionRules.pageInfo.endCursor,
        nodes: [$repo.branchProtectionRules.nodes[] | {
          pattern,
          matching_refs: {
            total_count: .matchingRefs.totalCount,
            has_next: .matchingRefs.pageInfo.hasNextPage,
            end_cursor: .matchingRefs.pageInfo.endCursor,
            nodes: [.matchingRefs.nodes[] | {
              id, name, prefix, oid: .target.oid
            }]
          }
        }]
      }
    }
  ') || return 1

  rulesets=$(mergepath_merge_queue_read_rulesets "$repo") || return 1
  repository_ruleset=$(gh api \
    "repos/$repo/rulesets/$repository_ruleset_id?includes_parents=false") \
    || return 1
  workflow_ruleset=$(gh api \
    "orgs/$owner/rulesets/$workflow_ruleset_id") || return 1
  source_repo=$(GH_TOKEN="$source_token" \
    gh api "repositories/$workflow_repository_id") || return 1
  source_repo_name=$(printf '%s' "$source_repo" | jq -er '
    .full_name | select(type == "string" and test("^[^/]+/[^/]+$"))
  ') || return 1
  source_authorization_workflow=$(GH_TOKEN="$source_token" gh api \
    "repos/$source_repo_name/actions/workflows/mergepath-merge-queue-authorization.yml") \
    || return 1
  source_repo_lint_workflow=$(GH_TOKEN="$source_token" gh api \
    "repos/$source_repo_name/actions/workflows/mergepath-repo-lint.yml") \
    || return 1
  encoded=$(jq -rn --arg branch "$branch" '$branch | @uri') || return 1
  [ -n "$encoded" ] || return 1
  protection=$(gh api "repos/$repo/branches/$encoded/protection") || return 1
  environment=$(gh api \
    "repos/$repo/environments/$MERGEPATH_MERGE_QUEUE_ENVIRONMENT") \
    || return 1
  branch_policies=$(mergepath_merge_queue_read_environment_branch_policies \
    "$repo") || return 1
  repository_secrets=$(mergepath_merge_queue_read_secret_inventory \
    "repos/$repo/actions/secrets?per_page=100" repository) || return 1
  organization_secrets=$(mergepath_merge_queue_read_secret_inventory \
    "repos/$repo/actions/organization-secrets?per_page=100" organization) \
    || return 1
  environment_secrets=$(mergepath_merge_queue_read_secret_inventory \
    "repos/$repo/environments/$MERGEPATH_MERGE_QUEUE_ENVIRONMENT/secrets?per_page=100" \
    environment) || return 1
  jq -cn --argjson graph "$graph" --argjson rulesets "$rulesets" \
    --argjson repository_ruleset "$repository_ruleset" \
    --argjson workflow_ruleset "$workflow_ruleset" \
    --argjson source_repo "$source_repo" \
    --argjson source_authorization_workflow "$source_authorization_workflow" \
    --argjson source_repo_lint_workflow "$source_repo_lint_workflow" \
    --argjson protection "$protection" --argjson environment "$environment" \
    --argjson environment_branch_policies "$branch_policies" \
    --argjson repository_secrets "$repository_secrets" \
    --argjson organization_secrets "$organization_secrets" \
    --argjson environment_secrets "$environment_secrets" \
    '{graph:$graph,rulesets:$rulesets,
      repository_ruleset:$repository_ruleset,
      workflow_ruleset:$workflow_ruleset,
      source_repository:$source_repo,
      source_authorization_workflow:$source_authorization_workflow,
      source_repo_lint_workflow:$source_repo_lint_workflow,
      protection:$protection,environment:$environment,
      environment_branch_policies:$environment_branch_policies,
      repository_secrets:$repository_secrets,
      organization_secrets:$organization_secrets,
      environment_secrets:$environment_secrets}'
}

# mergepath_merge_queue_validate_topology SNAPSHOT REPO DEFAULT_BRANCH AUTHOR
#   BASE_SHA QUEUE_ID QUEUE_CONFIG_JSON ROLLOUT_CONFIG_JSON
#
# Validates identity/permission before trusting a possibly permission-filtered
# rule inventory, then binds both queue aliases and the single matching ref to
# the caller's independently read live queue and event base.
mergepath_merge_queue_validate_topology() {
  [ "$#" -eq 8 ] || return 1
  local snapshot="$1" repo="$2" branch="$3" author="$4"
  local base_sha="$5" queue_id="$6" queue_config="$7" rollout="$8"
  local owner protection
  case "$repo" in */*) ;; *) return 1 ;; esac
  owner=${repo%%/*}
  printf '%s' "$snapshot" | jq -e \
    --arg repo "$repo" --arg owner "$owner" --arg branch "$branch" \
    --arg author "$author" \
    --arg base "$base_sha" --arg queue "$queue_id" \
    --argjson expected_config "$queue_config" --argjson rollout "$rollout" '
      type == "object" and
      .graph.viewer_login == $author and
      .graph.repository == $repo and
      (.graph.repository_id | type == "number" and floor == . and . > 0) and
      .graph.repository_id == $rollout.target_repository_id and
      .graph.viewer_permission == "ADMIN" and
      .graph.owner_type == "Organization" and
      (.graph.owner_login | type == "string" and length > 0) and
      $branch == "main" and
      .graph.default_branch.name == $branch and
      .graph.default_branch.prefix == "refs/heads/" and
      .graph.default_branch.oid == $base and
      ($expected_config | type == "object") and
      $expected_config.maximumEntriesToBuild == 1 and
      $expected_config.maximumEntriesToMerge == 1 and
      $expected_config.minimumEntriesToMerge == 1 and
      $expected_config.mergingStrategy == "ALLGREEN" and
      ($expected_config.mergeMethod as $method |
        (["MERGE","SQUASH","REBASE"] | index($method)) != null) and
      (.graph.implicit_queue | type == "object") and
      (.graph.explicit_queue | type == "object") and
      .graph.implicit_queue.id == $queue and
      .graph.explicit_queue.id == $queue and
      .graph.implicit_queue.repository == $repo and
      .graph.explicit_queue.repository == $repo and
      .graph.implicit_queue.configuration == $expected_config and
      .graph.explicit_queue.configuration == $expected_config and
      .graph.implicit_queue == .graph.explicit_queue and
      .graph.protection_rules.total_count == 1 and
      .graph.protection_rules.has_next == false and
      (.graph.protection_rules.nodes | type == "array" and length == 1) and
      .graph.protection_rules.nodes[0].pattern == $branch and
      (.graph.protection_rules.nodes[0].pattern |
        ((contains("*") or contains("?") or contains("[")) | not)) and
      .graph.protection_rules.nodes[0].matching_refs.total_count == 1 and
      .graph.protection_rules.nodes[0].matching_refs.has_next == false and
      (.graph.protection_rules.nodes[0].matching_refs.nodes |
        type == "array" and length == 1) and
      .graph.protection_rules.nodes[0].matching_refs.nodes[0].name == $branch and
      .graph.protection_rules.nodes[0].matching_refs.nodes[0].prefix == "refs/heads/" and
      .graph.protection_rules.nodes[0].matching_refs.nodes[0].oid == $base and
      (.graph.protection_rules.nodes[0].matching_refs.nodes[0].id |
        type == "string" and length > 0) and
      (.rulesets | type == "array") and
      ([.rulesets[] | select(
        .id == $rollout.repository_ruleset_id and
        .source_type == "Repository" and .source == $repo and
        .enforcement == "active")] | length) == 1 and
      ([.rulesets[] | select(
        .id == $rollout.workflow_ruleset_id and
        .source_type == "Organization" and .source == $owner and
        .enforcement == "active")] |
        length) == 1 and
      (.repository_ruleset | type == "object") and
      .repository_ruleset.id == $rollout.repository_ruleset_id and
      .repository_ruleset.source_type == "Repository" and
      .repository_ruleset.source == $repo and
      .repository_ruleset.target == "branch" and
      .repository_ruleset.enforcement == "active" and
      (.repository_ruleset.bypass_actors | type == "array" and length == 0) and
      (.repository_ruleset.conditions | type == "object") and
      (.repository_ruleset.conditions | keys) == ["ref_name"] and
      .repository_ruleset.conditions.ref_name.include == ["refs/heads/main"] and
      .repository_ruleset.conditions.ref_name.exclude == [] and
      (.repository_ruleset.rules | type == "array" and length == 1) and
      .repository_ruleset.rules[0].type == "merge_queue" and
      (.repository_ruleset.rules[0].parameters as $mq |
        $mq.grouping_strategy == "ALLGREEN" and
        $mq.max_entries_to_build == 1 and
        $mq.max_entries_to_merge == 1 and
        $mq.min_entries_to_merge == 1 and
        $mq.grouping_strategy == $expected_config.mergingStrategy and
        $mq.max_entries_to_build ==
          $expected_config.maximumEntriesToBuild and
        $mq.max_entries_to_merge ==
          $expected_config.maximumEntriesToMerge and
        $mq.min_entries_to_merge ==
          $expected_config.minimumEntriesToMerge and
        $mq.merge_method == $expected_config.mergeMethod and
        ($mq.check_response_timeout_minutes | type == "number" and floor == . and . > 0) and
        ($mq.min_entries_to_merge_wait_minutes | type == "number" and floor == . and . >= 0)) and
      (.workflow_ruleset | type == "object") and
      .workflow_ruleset.id == $rollout.workflow_ruleset_id and
      .workflow_ruleset.source_type == "Organization" and
      .workflow_ruleset.source == $owner and
      .workflow_ruleset.target == "branch" and
      .workflow_ruleset.enforcement == "active" and
      (.workflow_ruleset.bypass_actors | type == "array" and length == 0) and
      (.workflow_ruleset.conditions | type == "object") and
      (.workflow_ruleset.conditions | keys | sort) ==
        ["ref_name","repository_id"] and
      .workflow_ruleset.conditions.ref_name.include == ["refs/heads/main"] and
      .workflow_ruleset.conditions.ref_name.exclude == [] and
      .workflow_ruleset.conditions.repository_id.repository_ids ==
        [$rollout.target_repository_id] and
      (.workflow_ruleset.rules | type == "array" and length == 1) and
      .workflow_ruleset.rules[0].type == "workflows" and
      (.workflow_ruleset.rules[0].parameters as $wf |
        $wf.do_not_enforce_on_create == false and
        ($wf.workflows | type == "array" and length == 2) and
        all($wf.workflows[];
          .repository_id == $rollout.workflow_repository_id and
          .ref == $rollout.workflow_ref and .sha == $rollout.workflow_sha) and
        ([$wf.workflows[].path] | sort) == [
          ".github/workflows/mergepath-merge-queue-authorization.yml",
          ".github/workflows/mergepath-repo-lint.yml"
        ]) and
      .source_repository.id == $rollout.workflow_repository_id and
      .source_repository.full_name == $rollout.workflow_repository and
      .source_repository.owner.login == .graph.owner_login and
      .source_repository.owner.type == "Organization" and
      .source_repository.fork == false and
      .source_repository.archived == false and
      .source_repository.disabled == false and
      # The isolated handshake checks out this source with the target-scoped
      # GITHUB_TOKEN. Requiring a public source keeps that cross-repository
      # read independent of a broader source PAT for every target visibility.
      (.graph.visibility == "PUBLIC" or .graph.visibility == "INTERNAL" or
        .graph.visibility == "PRIVATE") and
      .source_repository.visibility == "public" and
      .source_authorization_workflow.path ==
        ".github/workflows/mergepath-merge-queue-authorization.yml" and
      .source_authorization_workflow.state == "disabled_manually" and
      .source_repo_lint_workflow.path ==
        ".github/workflows/mergepath-repo-lint.yml" and
      .source_repo_lint_workflow.state == "disabled_manually" and
      (.environment | type == "object") and
      .environment.name == "merge-queue-policy" and
      .environment.can_admins_bypass == false and
      (.environment.protection_rules | type == "array" and length == 1) and
      .environment.protection_rules[0].type == "branch_policy" and
      .environment.deployment_branch_policy == {
        protected_branches:false,custom_branch_policies:true
      } and
      (.environment_branch_policies | type == "object") and
      .environment_branch_policies.total_count == 1 and
      (.environment_branch_policies.branch_policies |
        type == "array" and length == 1) and
      (.environment_branch_policies.branch_policies[0] as $policy |
        ($policy.id | type == "number" and floor == . and . > 0) and
        ($policy.node_id | type == "string" and length > 0) and
        $policy.name == "main" and $policy.type == "branch") and
      (.repository_secrets | type == "object") and
      .repository_secrets.inventory == "repository" and
      (.repository_secrets.secrets | type == "array") and
      all(.repository_secrets.secrets[];
        .name as $name |
        (["AUTHOR_MERGE_TOKEN","MERGE_QUEUE_POLICY_TOKEN",
          "MERGE_QUEUE_SOURCE_TOKEN"] | index($name)) == null) and
      (.organization_secrets | type == "object") and
      .organization_secrets.inventory == "organization" and
      (.organization_secrets.secrets | type == "array") and
      all(.organization_secrets.secrets[];
        .name as $name |
        (["AUTHOR_MERGE_TOKEN","MERGE_QUEUE_POLICY_TOKEN",
          "MERGE_QUEUE_SOURCE_TOKEN"] | index($name)) == null) and
      (.environment_secrets | type == "object") and
      .environment_secrets.inventory == "environment" and
      (.environment_secrets.secrets | type == "array" and length == 3) and
      ([.environment_secrets.secrets[].name] | sort) == [
        "AUTHOR_MERGE_TOKEN",
        "MERGE_QUEUE_POLICY_TOKEN",
        "MERGE_QUEUE_SOURCE_TOKEN"
      ] and
      (.protection | type == "object")
    ' >/dev/null 2>&1 || return 1
  protection=$(printf '%s' "$snapshot" | jq -c '.protection') || return 1
  mergepath_merge_queue_validate_classic_protection "$protection"
}

# mergepath_merge_queue_topology_signature SNAPSHOT
mergepath_merge_queue_topology_signature() {
  [ "$#" -eq 1 ] || return 1
  # Fence only fields the validator treats as security state. REST response
  # timestamps, opaque node ids, array order, and unrelated inherited ruleset
  # summaries may change without changing the protected queue contract.
  printf '%s' "$1" | jq -ceS '
    . as $snapshot |
    {
      graph: {
        viewer_login:.graph.viewer_login,
        repository_id:.graph.repository_id,
        repository:.graph.repository,
        viewer_permission:.graph.viewer_permission,
        visibility:.graph.visibility,
        owner_type:.graph.owner_type,
        owner_login:.graph.owner_login,
        default_branch:.graph.default_branch,
        implicit_queue:.graph.implicit_queue,
        explicit_queue:.graph.explicit_queue,
        protection_rules: {
          total_count:.graph.protection_rules.total_count,
          has_next:.graph.protection_rules.has_next,
          nodes:[.graph.protection_rules.nodes[] | {
            pattern,
            matching_refs:{
              total_count:.matching_refs.total_count,
              has_next:.matching_refs.has_next,
              nodes:[.matching_refs.nodes[] | {name,prefix,oid}] |
                sort_by(.prefix,.name,.oid)
            }
          }] | sort_by(.pattern)
        }
      },
      rulesets:[.rulesets[] | select(
        .id == $snapshot.repository_ruleset.id or
        .id == $snapshot.workflow_ruleset.id) | {
          id,source_type,source,enforcement
        }] | sort_by(.id),
      repository_ruleset:(.repository_ruleset | {
        id,source_type,source,target,enforcement,bypass_actors,conditions,
        rules:[.rules[] | {
          type,
          parameters:(.parameters | {
            grouping_strategy,max_entries_to_build,max_entries_to_merge,
            min_entries_to_merge,merge_method,check_response_timeout_minutes,
            min_entries_to_merge_wait_minutes
          })
        }]
      }),
      workflow_ruleset:(.workflow_ruleset | {
        id,source_type,source,target,enforcement,bypass_actors,conditions,
        rules:[.rules[] | {
          type,
          parameters:{
            do_not_enforce_on_create:.parameters.do_not_enforce_on_create,
            workflows:[.parameters.workflows[] | {
              repository_id,path,ref,sha
            }] | sort_by(.path)
          }
        }]
      }),
      source_repository:(.source_repository | {
        id,full_name,owner:{login:.owner.login,type:.owner.type},
        visibility,fork,archived,disabled
      }),
      source_authorization_workflow:(.source_authorization_workflow | {path,state}),
      source_repo_lint_workflow:(.source_repo_lint_workflow | {path,state}),
      protection:(.protection | {
        required_status_checks:{
          strict:.required_status_checks.strict,
          contexts:(.required_status_checks.contexts | sort),
          checks:(.required_status_checks.checks | sort_by(.context,.app_id))
        },
        enforce_admins:{enabled:.enforce_admins.enabled},
        required_pull_request_reviews:{
          dismiss_stale_reviews:.required_pull_request_reviews.dismiss_stale_reviews,
          bypass_pull_request_allowances:{users:[],teams:[],apps:[]}
        },
        required_conversation_resolution:{
          enabled:.required_conversation_resolution.enabled
        }
      }),
      environment:{
        name:.environment.name,
        can_admins_bypass:.environment.can_admins_bypass,
        protection_rules:(.environment.protection_rules | map({type}) | sort_by(.type)),
        deployment_branch_policy:.environment.deployment_branch_policy
      },
      environment_branch_policies:{
        total_count:.environment_branch_policies.total_count,
        branch_policies:(.environment_branch_policies.branch_policies |
          map({name,type}) | sort_by(.type,.name))
      },
      repository_secrets:{
        inventory:.repository_secrets.inventory,
        names:([.repository_secrets.secrets[].name] | sort)
      },
      organization_secrets:{
        inventory:.organization_secrets.inventory,
        names:([.organization_secrets.secrets[].name] | sort)
      },
      environment_secrets:{
        inventory:.environment_secrets.inventory,
        names:([.environment_secrets.secrets[].name] | sort)
      }
    }
  '
}
