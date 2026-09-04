# shellcheck shell=bash
# Shared, read-only authorization evidence for native merge-queue entries.

MERGEPATH_MERGE_QUEUE_AUTH_SCHEMA="mergepath-merge-queue-authorization/v1"
MERGEPATH_MERGE_QUEUE_AUTH_RE='<!-- mergepath-merge-queue-authorization:v1 (?<payload>[A-Za-z0-9+/=]+) -->'
readonly MERGEPATH_MERGE_QUEUE_AUTH_SCHEMA MERGEPATH_MERGE_QUEUE_AUTH_RE

# GitHub puts label, native auto-merge, and queue-add events in one ordered
# connection. That connection is the only safe ordering source when GitHub's
# DateTime values share one-second precision.
# shellcheck disable=SC2016 # GraphQL variables are intentionally literal.
MERGEPATH_MERGE_QUEUE_AUTH_TIMELINE_QUERY='query($owner:String!,$name:String!,$number:Int!,$after:String){
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
          ... on LabeledEvent{
            id createdAt actor{login} label{name}
          }
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
          ... on PullRequestCommit{
            id commit{oid}
          }
          ... on HeadRefForcePushedEvent{
            id createdAt actor{login} beforeCommit{oid} afterCommit{oid}
          }
          ... on HeadRefDeletedEvent{
            id createdAt actor{login} headRefName
          }
          ... on HeadRefRestoredEvent{
            id createdAt actor{login}
          }
          ... on AddedToMergeQueueEvent{
            id createdAt actor{login} enqueuer{login} mergeQueue{id}
          }
        }
      }
    }
  }
}'
readonly MERGEPATH_MERGE_QUEUE_AUTH_TIMELINE_QUERY

# mergepath_merge_queue_read_auth_timeline REPO PR_NUMBER
#
# Prints one complete, connection-ordered timeline snapshot. Every page must
# agree on repository/PR identity and pagination must terminate without cursor
# reuse. `totalCount` describes the unfiltered timeline while `nodes` reflects
# `itemTypes`, so their lengths are deliberately not compared; unique filtered
# node ids plus cursor exhaustion are the completeness boundary available here.
mergepath_merge_queue_read_auth_timeline() {
  [ "$#" -eq 2 ] || return 1
  local repo="$1" pr="$2" owner name raw page snapshot="" cursor=""
  local next_cursor has_next page_static snapshot_static
  local seen_cursors='[]' page_count=0
  local -a gh_args
  case "$repo" in */*) ;; *) return 1 ;; esac
  owner=${repo%%/*}
  name=${repo#*/}
  case "$owner:$name" in :*|*:|*:*/*) return 1 ;; esac
  case "$pr" in *[!0-9]*|'') return 1 ;; esac
  while :; do
    page_count=$((page_count + 1))
    [ "$page_count" -le 100 ] || return 1
    gh_args=(api graphql -f query="$MERGEPATH_MERGE_QUEUE_AUTH_TIMELINE_QUERY" \
      -f owner="$owner" -f name="$name" -F number="$pr")
    if [ -n "$cursor" ]; then
      gh_args+=(-f after="$cursor")
    fi
    raw=$(gh "${gh_args[@]}") || return 1
    page=$(printf '%s' "$raw" | jq -ce '
      select(((.errors // []) | length) == 0) |
      .data.repository as $repo |
      $repo.pullRequest as $pr |
      select($repo != null and $pr != null) |
      {
        repository: $repo.nameWithOwner,
        pr_id: $pr.id,
        pr_number: $pr.number,
        total_count: $pr.timelineItems.totalCount,
        has_next: $pr.timelineItems.pageInfo.hasNextPage,
        end_cursor: $pr.timelineItems.pageInfo.endCursor,
        items: [$pr.timelineItems.nodes[] |
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
        (.has_next | type == "boolean") and
        (.items | type == "array")
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
    has_next=$(printf '%s' "$page" | jq -r '.has_next') || return 1
    [ "$has_next" = "true" ] || break
    next_cursor=$(printf '%s' "$page" | jq -er '
      .end_cursor | select(type == "string" and length > 0)
    ') || return 1
    if printf '%s' "$seen_cursors" \
      | jq -e --arg cursor "$next_cursor" 'index($cursor) != null' >/dev/null 2>&1; then
      return 1
    fi
    seen_cursors=$(printf '%s' "$seen_cursors" \
      | jq -c --arg cursor "$next_cursor" '. + [$cursor]') || return 1
    cursor="$next_cursor"
  done
  printf '%s' "$snapshot" | jq -ce '
    select(.has_next == false) |
    select((.items | map(.id) | length) == (.items | map(.id) | unique | length)) |
    del(.end_cursor)
  '
}

# mergepath_merge_queue_decode_authorizations COMMENTS_JSON
#
# Malformed/foreign envelopes are ignored. GitHub comment metadata is applied
# after the decoded payload so payload fields cannot spoof the author or id.
mergepath_merge_queue_decode_authorizations() {
  [ "$#" -eq 1 ] || return 1
  printf '%s' "$1" | jq -ce \
    --arg schema "$MERGEPATH_MERGE_QUEUE_AUTH_SCHEMA" \
    --arg marker_re "$MERGEPATH_MERGE_QUEUE_AUTH_RE" '
      select(type == "array") |
      [ .[] as $comment |
        select($comment | type == "object") |
        try (
          (($comment.body // "") | capture($marker_re).payload | @base64d | fromjson)
          + {
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

# mergepath_merge_queue_select_source_auto_event TIMELINE REPO PR ENABLED_AT
#   AUTHOR MERGE_METHOD
#
# Chooses the latest same-second event because connection order, not timestamp,
# distinguishes repeated native arm actions. It must also be the final arm and
# have no later blocking-label event at the time authorization is recorded.
mergepath_merge_queue_select_source_auto_event() {
  [ "$#" -eq 6 ] || return 1
  local timeline="$1" repo="$2" pr="$3" enabled_at="$4" author="$5"
  local merge_method="$6"
  jq -ecn --argjson timeline "$timeline" --arg repo "$repo" \
    --argjson pr "$pr" --arg enabled_at "$enabled_at" --arg author "$author" \
    --arg method "$merge_method" '
      def blocking_label:
        . == "human-hold" or . == "needs-external-review" or
        . == "needs-human-review" or . == "policy-violation";
      select($timeline.repository == $repo and $timeline.pr_number == $pr and
        $timeline.has_next == false and
        ($timeline.items | type == "array")) |
      [$timeline.items | to_entries[] | select(
        .value.kind == "auto_merge_enabled" and
        .value.created_at == $enabled_at and .value.enabler == $author and
        .value.method == $method
      )] as $matches |
      select(($matches | length) > 0) |
      $matches[-1] as $source |
      select(all($timeline.items | to_entries[];
        if .key > $source.key then
          (((.value.kind == "labeled" and (.value.label | blocking_label)) or
            .value.kind == "auto_merge_enabled" or
            .value.kind == "auto_merge_disabled" or
            .value.kind == "head_commit" or
            .value.kind == "head_force_pushed" or
            .value.kind == "head_deleted" or
            .value.kind == "head_restored") | not)
        else true end)) |
      {
        id:$source.value.id,
        created_at:$source.value.created_at,
        merge_method:$source.value.method,
        index:$source.key
      }
    '
}

# mergepath_merge_queue_select_entry_action TIMELINE REPO PR AUTHOR QUEUE_ID
#   ENTRY_ENQUEUED_AT ACTIVATED_AT QUEUE_METHOD
#
# Selects the unique live queue action by connection order. A direct enqueue
# must itself be performed by the governing author. An auto-merge enqueue may
# be system-delivered, but its latest preceding arm must be the governing
# author's exact method. Mutable or blocking events after that authorization
# invalidate the action; a later queue add always supersedes the older entry.
mergepath_merge_queue_select_entry_action() {
  [ "$#" -eq 8 ] || return 1
  local timeline="$1" repo="$2" pr="$3" author="$4" queue_id="$5"
  local enqueued_at="$6" activated_at="$7" queue_method="$8"
  jq -ecn --argjson timeline "$timeline" --arg repo "$repo" \
    --argjson pr "$pr" --arg author "$author" --arg queue "$queue_id" \
    --arg enqueued_at "$enqueued_at" --arg activated_at "$activated_at" \
    --arg queue_method "$queue_method" '
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def blocking_label:
        . == "human-hold" or . == "needs-external-review" or
        . == "needs-human-review" or . == "policy-violation";
      def invalidating:
        (.kind == "labeled" and (.label | blocking_label)) or
        .kind == "auto_merge_enabled" or .kind == "auto_merge_disabled" or
        .kind == "head_commit" or .kind == "head_force_pushed" or
        .kind == "head_deleted" or .kind == "head_restored" or
        .kind == "added_to_queue";
      select(($activated_at | timestamp) and ($enqueued_at | timestamp)) |
      select(($enqueued_at | fromdateiso8601) >=
        ($activated_at | fromdateiso8601)) |
      select($timeline.repository == $repo and $timeline.pr_number == $pr and
        $timeline.has_next == false and ($timeline.items | type == "array")) |
      select(([$timeline.items[].id] | length) ==
        ([$timeline.items[].id] | unique | length)) |
      $timeline.items as $items |
      [$items | to_entries[] | select(
        .value.kind == "added_to_queue" and
        .value.created_at == $enqueued_at and
        .value.enqueuer == $author and .value.queue_id == $queue)] as $adds |
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
          merge_method:$queue_method
        }
      else
        $arms[-1] as $source |
        select($source.value.kind == "auto_merge_enabled" and
          $source.value.enabler == $author and
          $source.value.method == $queue_method and
          ($source.value.created_at | fromdateiso8601) >=
            ($activated_at | fromdateiso8601)) |
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

# mergepath_merge_queue_select_entry_attestation MARKERS ACTION REPO PR HEAD
#   BASE_REF AUTHOR QUEUE_ID ENTRY_ID ENTRY_ENQUEUED_AT QUEUE_METHOD ENTRY_BASE
#   ROLLOUT
#
# Requires one author-attributed, post-enqueue administrative proof for the
# exact live MergeQueueEntry and the action selected above. The external
# required workflow cannot read private bypass lists, so this environment-
# protected attestation is the bridge from the admin audit to that read-only
# final gate.
mergepath_merge_queue_select_entry_attestation() {
  [ "$#" -eq 13 ] || return 1
  local markers="$1" action="$2" repo="$3" pr="$4" head="$5"
  local base_ref="$6" author="$7" queue_id="$8" entry_id="$9"
  local enqueued_at="${10}" queue_method="${11}" entry_base="${12}"
  local rollout="${13}"
  jq -ecn --argjson markers "$markers" --argjson action "$action" \
    --argjson rollout "$rollout" --arg repo "$repo" --argjson pr "$pr" \
    --arg head "$head" --arg base_ref "$base_ref" --arg author "$author" \
    --arg queue "$queue_id" --arg entry "$entry_id" \
    --arg enqueued_at "$enqueued_at" --arg method "$queue_method" \
    --arg entry_base "$entry_base" '
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def sha:
        type == "string" and
        test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$");
      select(($action.kind == "direct-queue" or
        $action.kind == "auto-merge") and
        $action.merge_method == $method and
        $action.queue_event_created_at == $enqueued_at) |
      [$markers[] | select(
        ._comment_author == $author and
        (._comment_id | type == "number" and floor == . and . > 0) and
        (._comment_created_at | timestamp) and
        .kind == "queue-entry-attestation" and
        .repository == $repo and .pr == $pr and .head == $head and
        .base_ref == $base_ref and .entry_base == $entry_base and
        .queue_id == $queue and .queue_entry_id == $entry and
        .queue_event_id == $action.queue_event_id and
        .queue_event_created_at == $action.queue_event_created_at and
        .authorization_kind == $action.kind and
        .action_event_id == $action.action_event_id and
        .action_event_created_at == $action.action_event_created_at and
        .merge_method == $method and
        .repository_ruleset_id == $rollout.repository_ruleset_id and
        .workflow_ruleset_id == $rollout.workflow_ruleset_id and
        .workflow_repository_id == $rollout.workflow_repository_id and
        .workflow_ref == $rollout.workflow_ref and
        .workflow_sha == $rollout.workflow_sha and
        .environment == "merge-queue-policy" and
        (.topology_sha256 | type == "string" and
          test("^[0-9a-f]{64}$")) and
        (.created_at | timestamp) and
        ((.created_at | fromdateiso8601) >=
          ($action.queue_event_created_at | fromdateiso8601)) and
        ((._comment_created_at | fromdateiso8601) >=
          ($action.queue_event_created_at | fromdateiso8601)) and
        (.entry_base | sha)
      )] as $matches |
      select(($matches | length) == 1) |
      $matches[0]
    '
}

# mergepath_merge_queue_select_final_audit MARKERS ACTION REPO PR HEAD
#   GROUP_HEAD GROUP_REF BASE_SHA BASE_REF AUTHOR QUEUE_ID ENTRY_ID
#   ENTRY_ENQUEUED_AT QUEUE_METHOD ENTRY_BASE ROLLOUT NONCE RUN_ID RUN_ATTEMPT
#   REQUESTED_AT REQUESTER_WORKFLOW_REPOSITORY REQUESTER_WORKFLOW_FILE_PATH
#   REQUESTER_WORKFLOW_REF REQUESTER_WORKFLOW_SHA AUDITOR_RUN_ID
#   AUDITOR_RUN_ATTEMPT AUDITOR_WORKFLOW_REF AUDITOR_WORKFLOW_SHA
#
# Selects one nonce-bound response from the protected default-branch
# repository_dispatch auditor. The request is emitted only after the required
# workflow has completed its substantive predicates, so this is the privileged
# topology proof coupled to the current merge-group run rather than a durable
# enrollment-era observation.
mergepath_merge_queue_select_final_audit() {
  [ "$#" -eq 28 ] || return 1
  local markers="$1" action="$2" repo="$3" pr="$4" head="$5"
  local group_head="$6" group_ref="$7" base_sha="$8" base_ref="$9"
  local author="${10}" queue_id="${11}" entry_id="${12}"
  local enqueued_at="${13}" queue_method="${14}" entry_base="${15}"
  local rollout="${16}" nonce="${17}" run_id="${18}"
  local run_attempt="${19}" requested_at="${20}"
  local requester_workflow_repository="${21}"
  local requester_workflow_file_path="${22}"
  local requester_workflow_ref="${23}" requester_workflow_sha="${24}"
  local auditor_run_id="${25}" auditor_run_attempt="${26}"
  local auditor_workflow_ref="${27}" auditor_workflow_sha="${28}"
  jq -ecn --argjson markers "$markers" --argjson action "$action" \
    --argjson rollout "$rollout" --arg repo "$repo" --argjson pr "$pr" \
    --arg head "$head" --arg group_head "$group_head" \
    --arg group_ref "$group_ref" --arg base_sha "$base_sha" \
    --arg base_ref "$base_ref" \
    --arg author "$author" --arg queue "$queue_id" --arg entry "$entry_id" \
    --arg enqueued_at "$enqueued_at" --arg method "$queue_method" \
    --arg entry_base "$entry_base" --arg nonce "$nonce" \
    --arg run_id "$run_id" --argjson run_attempt "$run_attempt" \
    --arg requested_at "$requested_at" \
    --arg requester_workflow_repository "$requester_workflow_repository" \
    --arg requester_workflow_file_path "$requester_workflow_file_path" \
    --arg requester_workflow_ref "$requester_workflow_ref" \
    --arg requester_workflow_sha "$requester_workflow_sha" \
    --arg auditor_run_id "$auditor_run_id" \
    --argjson auditor_run_attempt "$auditor_run_attempt" \
    --arg auditor_workflow_ref "$auditor_workflow_ref" \
    --arg auditor_workflow_sha "$auditor_workflow_sha" '
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def sha:
        type == "string" and
        test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$");
      select(($nonce | test("^[0-9a-f]{64}$")) and
        ($requested_at | timestamp) and
        ($run_id | test("^[1-9][0-9]*$")) and
        ($run_attempt | type == "number" and floor == . and . > 0) and
        ($action.kind == "direct-queue" or $action.kind == "auto-merge") and
        $action.merge_method == $method and
        $action.queue_event_created_at == $enqueued_at) |
      [$markers[] | select(
        ._comment_author == $author and
        (._comment_id | type == "number" and floor == . and . > 0) and
        (._comment_created_at | timestamp) and
        .kind == "final-admin-audit" and
        .repository == $repo and .pr == $pr and .head == $head and
        .group_head == $group_head and .group_ref == $group_ref and
        .base_sha == $base_sha and
        .base_ref == $base_ref and .entry_base == $entry_base and
        .queue_id == $queue and .queue_entry_id == $entry and
        .queue_event_id == $action.queue_event_id and
        .queue_event_created_at == $action.queue_event_created_at and
        .authorization_kind == $action.kind and
        .action_event_id == $action.action_event_id and
        .action_event_created_at == $action.action_event_created_at and
        .merge_method == $method and
        .repository_ruleset_id == $rollout.repository_ruleset_id and
        .workflow_ruleset_id == $rollout.workflow_ruleset_id and
        .workflow_repository_id == $rollout.workflow_repository_id and
        .workflow_repository == $rollout.workflow_repository and
        .workflow_ref == $rollout.workflow_ref and
        .workflow_sha == $rollout.workflow_sha and
        .environment == "merge-queue-policy" and
        .request_nonce == $nonce and .requester_run_id == $run_id and
        .requester_run_attempt == $run_attempt and
        .requested_at == $requested_at and
        .requester_workflow_repository == $requester_workflow_repository and
        .requester_workflow_file_path == $requester_workflow_file_path and
        .requester_workflow_ref == $requester_workflow_ref and
        .requester_workflow_sha == $requester_workflow_sha and
        .auditor_run_id == $auditor_run_id and
        .auditor_run_attempt == $auditor_run_attempt and
        .auditor_workflow_ref == $auditor_workflow_ref and
        .auditor_workflow_sha == $auditor_workflow_sha and
        (.topology_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.created_at | timestamp) and
        ((.created_at | fromdateiso8601) >=
          ($requested_at | fromdateiso8601)) and
        ((.created_at | fromdateiso8601) <=
          (._comment_created_at | fromdateiso8601)) and
        ((._comment_created_at | fromdateiso8601) >=
          ($requested_at | fromdateiso8601)) and
        (.head | sha) and (.group_head | sha) and (.base_sha | sha) and
        (.entry_base | sha) and (.requester_workflow_sha | sha) and
        (.auditor_workflow_sha | sha)
      )] as $matches |
      select(($matches | length) == 1) |
      $matches[0]
    '
}

# Counts every governing-author final-audit envelope in the nonce namespace,
# including malformed or stale variants that the exact selector rejects.
mergepath_merge_queue_count_final_audits() {
  [ "$#" -eq 9 ] || return 1
  local markers="$1" repo="$2" pr="$3" head="$4" group_head="$5"
  local author="$6" nonce="$7" run_id="$8" run_attempt="$9"
  jq -ecn --argjson markers "$markers" --arg repo "$repo" --argjson pr "$pr" \
    --arg head "$head" --arg group_head "$group_head" --arg author "$author" \
    --arg nonce "$nonce" --arg run_id "$run_id" \
    --argjson run_attempt "$run_attempt" '
      [$markers[] | select(
        ._comment_author == $author and .kind == "final-admin-audit" and
        (.request_nonce == $nonce or
          (.requester_run_id == $run_id and
            .requester_run_attempt == $run_attempt)))] |
      length
    '
}

# mergepath_merge_queue_select_arm_authorization MARKERS TIMELINE REPO PR
#   HEAD BASE_REF AUTHOR ENABLED_AT MERGE_METHOD ACTIVATED_AT
#
# Proves that the live durable arm has exactly one governing-author marker for
# its latest unsuperseded native enable event. This is the pre-queue form of
# the evidence that mergepath_merge_queue_select_authorization later binds to
# one native queue entry. The marker's authorized base is returned so callers
# can prove its ancestry to their independently read live base.
mergepath_merge_queue_select_arm_authorization() {
  [ "$#" -eq 10 ] || return 1
  local markers="$1" timeline="$2" repo="$3" pr="$4" head="$5"
  local base_ref="$6" author="$7" enabled_at="$8" merge_method="$9"
  local activated_at="${10}" source
  source=$(mergepath_merge_queue_select_source_auto_event "$timeline" "$repo" \
    "$pr" "$enabled_at" "$author" "$merge_method") || return 1
  jq -ecn --argjson markers "$markers" --argjson source "$source" \
    --arg repo "$repo" --argjson pr "$pr" --arg head "$head" \
    --arg base_ref "$base_ref" --arg author "$author" \
    --arg enabled_at "$enabled_at" --arg method "$merge_method" \
    --arg activated_at "$activated_at" '
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      select(($enabled_at | timestamp) and ($activated_at | timestamp)) |
      select(($enabled_at | fromdateiso8601) >=
        ($activated_at | fromdateiso8601)) |
      [$markers[] | select(
        ._comment_author == $author and
        (._comment_id | type == "number" and floor == . and . > 0) and
        (._comment_created_at | timestamp) and
        .kind == "auto-merge-authorization" and
        .repository == $repo and .pr == $pr and .head == $head and
        .base_ref == $base_ref and .enabled_by == $author and
        .merge_method == $method and
        .source_event_id == $source.id and
        .source_event_created_at == $source.created_at and
        (.authorized_base | type == "string" and
          test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$")) and
        (.created_at | timestamp) and
        ((.created_at | fromdateiso8601) >=
          ($source.created_at | fromdateiso8601)) and
        ((._comment_created_at | fromdateiso8601) >=
          ($source.created_at | fromdateiso8601))
      )] as $matches |
      select(($matches | length) == 1) |
      $matches[0] | {
        kind,
        source_event_id,
        source_event_created_at,
        authorized_base,
        merge_method,
        marker_created_at:.created_at,
        marker_comment_id:._comment_id,
        marker_comment_url:._comment_url,
        marker_comment_created_at:._comment_created_at
      }
    '
}

# mergepath_merge_queue_select_authorization MARKERS TIMELINE REPO PR HEAD
#   BASE_REF AUTHOR QUEUE_ID ENTRY_ENQUEUED_AT ACTIVATED_AT QUEUE_METHOD
#
# Prints the exact current authorization. A direct queue action is accepted
# when no native arm event precedes it or the latest preceding arm event is a
# disable. If the latest arm state is enabled, that exact event needs one
# exact-head author marker. Any later blocking label invalidates either path
# even if that label was later removed.
mergepath_merge_queue_select_authorization() {
  [ "$#" -eq 11 ] || return 1
  local markers="$1" timeline="$2" repo="$3" pr="$4" head="$5"
  local base_ref="$6" author="$7" queue_id="$8" enqueued_at="$9"
  local activated_at="${10}"
  local queue_method="${11}"
  jq -ecn --argjson markers "$markers" --argjson timeline "$timeline" \
    --arg repo "$repo" --argjson pr "$pr" --arg head "$head" \
    --arg base_ref "$base_ref" --arg author "$author" \
    --arg queue "$queue_id" --arg enqueued_at "$enqueued_at" \
    --arg activated_at "$activated_at" --arg queue_method "$queue_method" '
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def blocking_label:
        . == "human-hold" or . == "needs-external-review" or
        . == "needs-human-review" or . == "policy-violation";
      select(($activated_at | timestamp) and ($enqueued_at | timestamp)) |
      select(($enqueued_at | fromdateiso8601) >= ($activated_at | fromdateiso8601)) |
      select($timeline.repository == $repo and $timeline.pr_number == $pr and
        $timeline.has_next == false and
        ($timeline.items | type == "array")) |
      $timeline.items as $items |
      [range(0; $items | length) as $i |
        select($items[$i].kind == "added_to_queue" and
          $items[$i].created_at == $enqueued_at and
          $items[$i].enqueuer == $author and
          $items[$i].queue_id == $queue) | $i] as $added_indexes |
      select(($added_indexes | length) == 1) |
      $added_indexes[0] as $added_index |
      select((["MERGE","SQUASH","REBASE"] | index($queue_method)) != null) |
      [$items | to_entries[] |
        select(.key <= $added_index and
          (.value.kind == "auto_merge_enabled" or
           .value.kind == "auto_merge_disabled"))] as $arm_events |
      if ($arm_events | length) == 0 or
          $arm_events[-1].value.kind == "auto_merge_disabled" then
        # A direct queue authorization must be a fresh action actually
        # performed by the governing author. `enqueuer` alone can retain the
        # original owner across a system replay after an ejection.
        select($items[$added_index].actor == $author) |
        select(all($items | to_entries[];
          if .key > $added_index then
            (((.value.kind == "labeled" and (.value.label | blocking_label)) or
              .value.kind == "auto_merge_enabled" or
              .value.kind == "auto_merge_disabled" or
              .value.kind == "head_commit" or
              .value.kind == "head_force_pushed" or
              .value.kind == "head_deleted" or
              .value.kind == "head_restored" or
              .value.kind == "added_to_queue") | not)
          else true end)) |
        {
          kind:"direct-queue",
          source_event_id:$items[$added_index].id,
          source_event_created_at:$items[$added_index].created_at,
          authorized_base:null,
          merge_method:$queue_method
        }
      else
        $arm_events[-1] as $source |
        select($source.value.kind == "auto_merge_enabled") |
        select(($source.value.created_at | fromdateiso8601) >=
          ($activated_at | fromdateiso8601)) |
        select($source.value.method == $queue_method) |
        [$markers[] | select(
          ._comment_author == $author and
          (._comment_id | type == "number" and floor == . and . > 0) and
          (._comment_created_at | timestamp) and
          .kind == "auto-merge-authorization" and
          .repository == $repo and .pr == $pr and .head == $head and
          .base_ref == $base_ref and .enabled_by == $author and
          .merge_method == $source.value.method and
          .source_event_id == $source.value.id and
          .source_event_created_at == $source.value.created_at and
          (.authorized_base | type == "string" and
            test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$")) and
          (.created_at | timestamp) and
          ((.created_at | fromdateiso8601) >=
            ($source.value.created_at | fromdateiso8601)) and
          ((._comment_created_at | fromdateiso8601) >=
            ($source.value.created_at | fromdateiso8601))
        )] as $matches |
        select(($matches | length) == 1) |
        select(all($items | to_entries[];
          if .key > $source.key and .key < $added_index then
            (((.value.kind == "labeled" and (.value.label | blocking_label)) or
              .value.kind == "auto_merge_enabled" or
              .value.kind == "auto_merge_disabled" or
              .value.kind == "head_commit" or
              .value.kind == "head_force_pushed" or
              .value.kind == "head_deleted" or
              .value.kind == "head_restored" or
              .value.kind == "added_to_queue") | not)
          elif .key > $added_index then
            (((.value.kind == "labeled" and (.value.label | blocking_label)) or
              .value.kind == "auto_merge_enabled" or
              .value.kind == "auto_merge_disabled" or
              .value.kind == "head_commit" or
              .value.kind == "head_force_pushed" or
              .value.kind == "head_deleted" or
              .value.kind == "head_restored" or
              .value.kind == "added_to_queue") | not)
          else true end)) |
        $matches[0] | {
          kind:"auto-merge",
          source_event_id,
          source_event_created_at,
          authorized_base,
          merge_method,
          marker_comment_id:._comment_id,
          marker_comment_url:._comment_url
        }
      end
    '
}
