#!/usr/bin/env bash
# Read-only selectors shared by request deduplication/ack and blocked evidence.
# A trigger qualifies by complete command body, author, and freshness, not an
# immutable commit anchor.
# Read the author from parsed governing policy, shared by the capture producer,
# request budget and merge checker. Only an absent key uses the legacy default.
crqe_policy_author() { # policy-json
  printf '%s' "$1" | jq -er '
    if type != "object" then error("policy")
    elif has("author_identity") then
      .author_identity | select(type == "string" and length > 0)
    else "nathanjohnpayne" end'
}

crqe_select_trigger() { # comments-json author since
  printf '%s\n' "$1" | jq -c --arg author "$2" --arg since "$3" '
    [.[] | select((.user.login // "") == $author)
     | select((.body // "") | test("\\A@codex review\\z"; "i"))
     | select(.created_at >= $since)]
    | max_by([.created_at, .id]) // null
  '
}

# A terminal refusal must answer the selected author request, not an earlier
# one. Equal timestamps need comment IDs; unreadable ordering is not absence.
# A newer active current-head summary likewise retains the pending-review hold.
crqe_filter_provider_block() { # block-json request-json [current-head-summary-json]
  jq -nc --argjson block "$1" --argjson request "${2:-null}" --argjson summary "${3:-null}" '
    def comment_id: .comment_id // .id;
    def valid_id: type == "number" and . > 0 and floor == .;
    $block
    | if . == null then null
      elif ($summary.status == "running" or $summary.status == "unknown")
           and ($summary.observed_at // "") >= .created_at then null
      elif $request == null then .
      elif (.created_at | type) != "string" or ($request.created_at | type) != "string"
           or .created_at == "" or $request.created_at == "" then error("unreadable provider/request time")
      elif .created_at < $request.created_at then null
      elif .created_at > $request.created_at then .
      elif ((comment_id | valid_id) and ($request.id | valid_id)) then
        if comment_id > $request.id then . else null end
      else error("same-second provider/request ordering needs comment IDs") end
  '
}

# Select the immutable comment-ID generation for the configured author's exact
# request commands across a whole PR. Comment IDs, rather than pages or
# timestamps, are the durable accounting unit: pagination can repeat an item,
# while a command can remain the only request evidence when Codex answers with
# a clean summary or reaction. A malformed qualifying command fails closed.
crqe_trigger_generation() { # comments-json author
  printf '%s\n' "$1" | jq -cer --arg author "$2" '
    [ .[]
      | select((.user.login // "") == $author)
      | select((.body // "") | test("\\A@codex review\\z"; "i"))
      | .id
    ] as $ids
    | if all($ids[]; type == "number" and . > 0 and floor == .)
      then ($ids | unique | sort)
      else error("qualifying Codex request comment lacks a positive integer id")
      end
  '
}

# The latest qualifying Codex request time by the configured author, or empty
# when there is none (#1598). The substitute merge gate uses it to refuse a
# Phase 4b approval that a newer request has superseded. A qualifying command
# without a timestamp fails closed.
crqe_latest_trigger_time() { # comments-json author
  printf '%s\n' "$1" | jq -er --arg author "$2" '
    [ .[]
      | select((.user.login // "") == $author)
      | select((.body // "") | test("\\A@codex review\\z"; "i"))
      | .created_at
    ] as $times
    | if all($times[]; type == "string" and length > 0)
      then ($times | max // "")
      else error("qualifying Codex request comment lacks created_at")
      end
  '
}

# The CodeRabbit rate-limit failover (#489) asks Codex to stand in for the
# CodeRabbit review the PR lost; it is not a deliberate Codex round, so it does
# not spend the request ceiling (#2534). `codex-review-request.sh --failover`
# records the trigger it just posted with one author-owned comment:
#
#   <!-- mergepath-codex-failover:v1 head=<full-sha> trigger_comment_id=<id> -->
#
# A trigger is exempt only when that marker is the whole body of an unedited
# configured-author comment that names an exact configured-author trigger,
# follows it within CRQE_FAILOVER_MARKER_WINDOW_SECONDS by GitHub's own
# timestamps, has no other author trigger between the two, and names a head
# this PR actually had (crqe_pr_head_set; #2553). So a marker cannot be added
# to an old request later, and at most one trigger per real head is exempt: a
# marker naming an invented head exempts nothing. Anything else, malformed or unreadable, leaves the trigger
# counted: a missing exemption costs a request slot, never the ceiling. The
# trigger stays in the request generation; only the ceiling skips it.
CRQE_FAILOVER_MARKER_WINDOW_SECONDS=300

crqe_failover_marker_body() { # full-head-sha trigger-comment-id
  [[ "${1-}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ && "${2-}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '<!-- mergepath-codex-failover:v1 head=%s trigger_comment_id=%s -->' "$1" "$2"
}

# True when any comment by <author> starts with the failover marker namespace,
# so callers read the PR's head set only when a marker could use it.
crqe_failover_markers_present() { # comments-json author
  printf '%s\n' "$1" | jq -e --arg author "$2" '
    any(.[]?; type == "object" and (.user.login // "") == $author
              and ((.body // "") | type) == "string"
              and ((.body // "") | startswith("<!-- mergepath-codex-failover:")))' >/dev/null 2>&1
}

# The heads this PR has had (#2553): <current-head>, every commit in the PR's
# commit list, the commits the timeline records (`committed` events and a
# `head_ref_force_pushed` event's commit_id when REST fills it), and the before
# and after commits of every force-push (<force-push-heads>, from
# crqe_force_push_heads; #2591). REST does not name the head a force-push
# replaced, so without that read a marker on a head that was later
# force-pushed away stops exempting its trigger: it counts, the safe side.
# Prints a sorted array of lowercase full SHAs. Fails on input that is not
# arrays and a full SHA; callers then use [] so that nothing is exempt.
crqe_pr_head_set() { # commits-json timeline-json current-head [force-push-heads-json]
  # Histories are unbounded. Stream each independently parsed document rather
  # than placing it in an exec argument (Linux caps one argument at 128 KiB).
  jq -nce --slurpfile c <(printf '%s\n' "$1") \
    --slurpfile t <(printf '%s\n' "$2") --arg h "$3" \
    --slurpfile f <(printf '%s\n' "${4-[]}") '
    def sha: select(type == "string") | ascii_downcase | select(test("^([0-9a-f]{40}|[0-9a-f]{64})$"));
    if ($c | length) != 1 or ($t | length) != 1 or ($f | length) != 1
    then error("head set") else . end
    | $c[0] as $c | $t[0] as $t | $f[0] as $f
    | if ($c | type) != "array" or ($t | type) != "array" or ($f | type) != "array"
       or (($h | ascii_downcase) | test("^([0-9a-f]{40}|[0-9a-f]{64})$") | not)
    then error("head set") else . end
    | [ ($h | sha),
        ($c[] | objects | .sha | sha),
        ($t[] | objects | select(.event == "committed") | .sha | sha),
        ($t[] | objects | select(.event == "head_ref_force_pushed")
             | .commit_id | sha),
        ($f[] | sha) ]
    | unique' 2>/dev/null
}

# The before and after commits of every force-push on <repo>#<pr>, from the
# GraphQL timeline (#2591): the REST event names neither. Prints a sorted array
# of lowercase SHAs. Fails when the read fails or a page has no timeline;
# callers then pass [], which only drops force-pushed heads from the set.
crqe_force_push_heads() { # repo pr
  local out
  out=$(gh api graphql --paginate -f owner="${1%%/*}" -f name="${1#*/}" -F number="$2" -f query='
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          timelineItems(itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT], first: 100, after: $endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on HeadRefForcePushedEvent { beforeCommit { oid } afterCommit { oid } } }
          }
        }
      }
    }' 2>/dev/null) || return 1
  printf '%s\n' "$out" | jq -sce '
    if length == 0 or any(.[]; (.data.repository.pullRequest.timelineItems.nodes | type) != "array")
    then error("force-push timeline") else . end
    | [ .[].data.repository.pullRequest.timelineItems.nodes[]
        | (.beforeCommit.oid, .afterCommit.oid)
        | select(type == "string") | ascii_downcase
        | select(test("^([0-9a-f]{40}|[0-9a-f]{64})$")) ]
    | unique' 2>/dev/null
}

# #2664: the time of the PR's latest force-push when that force-push put
# <head> in place, else empty. Every later change of head is a push that
# either moves away from <head> (the head is then no longer <head>) or
# returns to it from a descendant, which is itself a force-push. So when the
# latest force-push's afterCommit is <head>, <head> has been the head without
# a break since then. Fails when the GraphQL read fails or a page has no
# timeline; callers treat that as no tie.
crqe_head_force_push_tie_at() { # repo pr head
  local out
  out=$(gh api graphql --paginate -f owner="${1%%/*}" -f name="${1#*/}" -F number="$2" -f query='
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          timelineItems(itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT], first: 100, after: $endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on HeadRefForcePushedEvent { createdAt afterCommit { oid } } }
          }
        }
      }
    }' 2>/dev/null) || return 1
  printf '%s\n' "$out" | jq -sre --arg head "$3" '
    if length == 0 or any(.[]; (.data.repository.pullRequest.timelineItems.nodes | type) != "array")
    then error("force-push timeline") else . end
    | [ .[].data.repository.pullRequest.timelineItems.nodes[]
        | select((.createdAt | type) == "string" and (try (.createdAt | fromdateiso8601) catch null) != null) ]
    | (max_by(.createdAt) // null) as $latest
    | if $latest != null and (($latest.afterCommit.oid // "") | ascii_downcase) == ($head | ascii_downcase)
      then $latest.createdAt else "" end' 2>/dev/null
}

# Prints the sorted ids of the exempt failover triggers. <heads-json> is
# crqe_pr_head_set's output; absent or [] exempts nothing.
crqe_failover_trigger_ids() { # comments-json author [heads-json]
  printf '%s\n' "$1" | jq -cer --arg author "$2" --argjson window "$CRQE_FAILOVER_MARKER_WINDOW_SECONDS" \
    --argjson heads "${3:-[]}" '
    def epoch: try fromdateiso8601 catch null;
    [ .[] | select(type == "object" and (.user.login // "") == $author) ] as $mine
    | [ $mine[] | select((.body // "") | test("\\A@codex review\\z"; "i")) ] as $triggers
    | [ $mine[]
        | select((.body | type) == "string" and (.id | type) == "number"
                 and (.created_at | type) == "string" and .updated_at == .created_at)
        | . as $m
        | ($m.body | capture("\\A<!-- mergepath-codex-failover:v1 head=(?<head>[0-9a-f]{40}|[0-9a-f]{64}) trigger_comment_id=(?<trigger>[1-9][0-9]*) -->\\z"))
        | .head as $head
        | select($heads | index($head) != null)
        | (.trigger | tonumber) as $tid
        | ([ $triggers[] | select(.id == $tid) ] | first) as $t
        | select($t != null and ($t.created_at | type) == "string")
        | ($m.created_at | epoch) as $ma | ($t.created_at | epoch) as $ta
        | select($ma != null and $ta != null and $m.id > $tid and $ma >= $ta and $ma - $ta <= $window)
        | select([ $triggers[] | select(.id > $tid and .id < $m.id) ] | length == 0)
        | {head: $head, id: $tid} ]
    | group_by(.head) | map(min_by(.id).id) | unique'
}

# The requests that spend the ceiling: the generation less exempt failovers.
# Without <heads-json> nothing is exempt.
crqe_count_triggers() { # comments-json author [heads-json]
  local generation exempt
  generation=$(crqe_trigger_generation "$1" "$2") || return 1
  exempt=$(crqe_failover_trigger_ids "$1" "$2" "${3:-[]}") || return 1
  jq -ner --argjson g "$generation" --argjson x "$exempt" '[ $g[] | select(. as $i | $x | index($i) | not) ] | length'
}

# Latest trusted PR force-push transition, not an author-controlled commit date.
crqe_latest_head_transition() { # timeline-json
  printf '%s' "$1" | jq -er '
    if type != "array" then error("timeline") else
      [.[] | select(.event == "head_ref_force_pushed") | .created_at] as $times
      | if all($times[]; type == "string" and (try fromdateiso8601 catch null) != null)
        then $times | max // "" else error("head transition time") end
    end'
}

# Positive ordinary-push evidence only. Missing/delayed Events API rows do
# not prove anything. Bind the event to the source repository, branch and
# complete current head; never substitute a commit's author/committer date.
crqe_latest_matching_head_push() { # events-json repo repo-id branch head observed-at
  printf '%s' "$1" | jq -er --arg repo "$2" --argjson id "$3" \
    --arg ref "refs/heads/$4" --arg head "$5" --arg now "$6" '
    if type != "array" then error("push events") else
      [.[] | select(.type == "PushEvent" and .repo.id == $id)
       | select((.repo.name | ascii_downcase) == ($repo | ascii_downcase))
       | select(.payload.ref == $ref and .payload.head == $head)
       | if (.payload.before | type) != "string"
            or (.payload.before | test("^[0-9a-f]{40}$") | not)
            or .payload.before == "0000000000000000000000000000000000000000"
            or .payload.before == .payload.head
            or (.created_at | type) != "string"
            or (try (.created_at | fromdateiso8601 | todateiso8601) catch "") != .created_at
            or .created_at > $now
         then error("head push evidence") else .created_at end]
      | max // ""
    end'
}

# Compute the request freshness anchor shared by the requester and Phase 4b
# cap sensing. Inputs are already-read evidence so each caller retains its own
# API failure action. Prints the full anchor record as JSON.
crqe_request_threshold() { # head-committer-date timeline-json freshness-seconds epoch-now
  local committed="$1" timeline="$2" seconds="$3" epoch="$4"
  local forced pushed source floor fresh threshold threshold_source
  [ -n "$committed" ] || return 1
  case "$seconds" in ''|*[!0-9]*) return 1 ;; esac
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  forced=$(crqe_latest_head_transition "$timeline") || return 1
  pushed="$committed"
  source="HEAD committer date"
  if [ -n "$forced" ] && [[ "$forced" > "$pushed" ]]; then
    pushed="$forced"
    source="head_ref_force_pushed @ $forced"
  fi
  floor=$((epoch - seconds))
  fresh=$(date -u -r "$floor" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$floor" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1
  if [[ "$fresh" > "$pushed" ]]; then
    threshold="$fresh"
    threshold_source="freshness floor (NOW - ${seconds}s)"
  else
    threshold="$pushed"
    threshold_source="HEAD pushed-at anchor ($source)"
  fi
  jq -nc --arg pushed "$pushed" --arg source "$source" --arg fresh "$fresh" \
    --arg threshold "$threshold" --arg threshold_source "$threshold_source" \
    '{head_pushed_at:$pushed,anchor_source:$source,reaction_floor:$fresh,
      reaction_threshold:$threshold,reaction_threshold_source:$threshold_source}'
}

# Read one materialized governing policy for either timing or write authority.
# Timing must not validate a request cap: no-spend paths keep their existing
# exemption from cap validation (#1567).
crqe_governing_policy_json() { # repo pr default-config [resolver [base-ref base-sha default-branch]]
  local repo="$1" pr="$2" config="$3"
  local resolver="${4:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/workflow/resolve_base_policy.sh}"
  local base_ref="${5:-}" base_sha="${6:-}" default_branch="${7:-}"
  local base_cfg="" base_json="" rc=0
  command -v policy_yaml_to_json >/dev/null 2>&1 || return 1
  [ -x "$resolver" ] || return 1
  if [ -n "$base_ref$base_sha$default_branch" ]; then
    [ -n "$base_ref" ] && [ -n "$base_sha" ] && [ -n "$default_branch" ] || return 1
    base_cfg=$("$resolver" --repo "$repo" --base-ref "$base_ref" --base-sha "$base_sha" \
      --default-branch "$default_branch" --default-config "$config" --materialize-default 2>/dev/null) || return 1
  else
    base_cfg=$("$resolver" --repo "$repo" --pr "$pr" \
      --default-config "$config" --materialize-default 2>/dev/null) || return 1
  fi
  [ -n "$base_cfg" ] && [ -r "$base_cfg" ] || return 1
  base_json=$(policy_yaml_to_json "$base_cfg" 2>/dev/null) || rc=$?
  [ "$base_cfg" = "$config" ] || rm -f "$base_cfg" 2>/dev/null || true
  [ "$rc" -eq 0 ] && [ -n "$base_json" ] || return 1
  printf '%s' "$base_json" | jq -ce 'select(type == "object")' || return 1
}

# Shared freshness parser for the requester and the Phase 4b request budget.
crqe_policy_reaction_freshness() { # policy-json
  local base_json="$1" freshness
  freshness=$(printf '%s' "$base_json" | jq -r '
    if type != "object" then "__invalid__"
    elif (has("codex") | not) then "1800"
    elif ((.codex | type) != "object") then "__invalid__"
    elif (.codex | has("reaction_freshness_window_seconds")) then
      .codex.reaction_freshness_window_seconds
      | if (type == "string" or type == "number") then tostring else "__invalid__" end
    else "1800" end') || return 1
  case "$freshness" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#freshness}" -le 9 ] || return 1
  freshness=$(printf '%s' "$freshness" | sed 's/^0*//')
  [ -n "$freshness" ] || freshness=0
  printf '%s' "$freshness"
}

crqe_governing_freshness() { # repo pr default-config [resolver]
  local policy
  policy=$(crqe_governing_policy_json "$@") || return 1
  crqe_policy_reaction_freshness "$policy"
}

# Resolve the request budget from the PR's governing base policy. The caller
# must already have sourced feedback-policy-helpers.sh (policy_yaml_to_json).
# Prints {author_identity,max_request_attempts,max_blocking_reviews,
# reaction_freshness_window_seconds}, with max_blocking_reviews null when its
# governed value is invalid;
# returns non-zero on every
# unreadable or malformed input. A materialized policy is removed here.
crqe_governing_budget() { # repo pr default-config candidate-author [resolver [base-ref base-sha default-branch]]
  local repo="$1" pr="$2" config="$3" candidate="$4"
  local resolver="${5:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/workflow/resolve_base_policy.sh}"
  local base_ref="${6:-}" base_sha="${7:-}" default_branch="${8:-}"
  local base_json="" author="" cap="" blocking="" freshness=""
  base_json=$(crqe_governing_policy_json "$repo" "$pr" "$config" "$resolver" \
    "$base_ref" "$base_sha" "$default_branch") || return 1
  author=$(crqe_policy_author "$base_json") || return 1
  if [ "$author" != "$candidate" ]; then
    printf "candidate author_identity '%s' does not match the governing base policy author_identity '%s'\n" \
      "$candidate" "$author" >&2
    return 1
  fi
  cap=$(printf '%s' "$base_json" | jq -r '
    if type != "object" then "__invalid__"
    elif (has("codex") | not) then "10"
    elif ((.codex | type) != "object") then "__invalid__"
    elif (.codex | has("max_review_rounds")) then
      .codex.max_review_rounds
      | if (type == "string" or type == "number") then tostring else "__invalid__" end
    else "10" end') || return 1
  case "$cap" in ''|*[!0-9]*) return 1 ;; esac
  # Bound the raw decimal width before Bash arithmetic: an attacker-sized
  # policy scalar can overflow or make arithmetic evaluation fail.
  [ "${#cap}" -le 9 ] || return 1
  cap=$(printf '%s' "$cap" | sed 's/^0*//')
  [ -n "$cap" ] || cap=0
  # The blocking-review budget (#1560 slice 3): solicited blocking Codex
  # reviews a PR may accumulate before further requests stop for the human.
  # Same governing source, absent default and validation as the request cap.
  # 10 is a provisional policy choice recorded on #1560. An invalid value is
  # reported as null rather than failing the whole read, so a path that does
  # not use the budget (an acknowledgement retry, a request-ceiling read) keeps
  # its behaviour; every reader that uses it must refuse null.
  blocking=$(printf '%s' "$base_json" | jq -r '
    if type != "object" then "__invalid__"
    elif (has("codex") | not) then "10"
    elif ((.codex | type) != "object") then "__invalid__"
    elif (.codex | has("max_blocking_reviews")) then
      .codex.max_blocking_reviews
      | if (type == "string" or type == "number") then tostring else "__invalid__" end
    else "10" end') || return 1
  case "$blocking" in
    ''|*[!0-9]*) blocking=null ;;
    *)
      if [ "${#blocking}" -le 9 ]; then
        blocking=$(printf '%s' "$blocking" | sed 's/^0*//')
        [ -n "$blocking" ] || blocking=0
      else
        blocking=null
      fi
      ;;
  esac
  freshness=$(crqe_policy_reaction_freshness "$base_json") || return 1
  local fingerprint
  fingerprint=$(crqe_policy_fingerprint "$base_json") || return 1
  jq -nc --arg author "$author" --argjson cap "$cap" --argjson blocking "$blocking" \
    --argjson freshness "$freshness" --arg fp "$fingerprint" \
    '{author_identity:$author,max_request_attempts:$cap,max_blocking_reviews:$blocking,
      reaction_freshness_window_seconds:$freshness,policy_fingerprint:$fp}'
}

# crqe_policy_fingerprint <policy-json>
# A short identity for one parsed base-policy snapshot: the POSIX checksum and
# size of its canonical JSON (sorted keys, compact). Two reads of the same base
# revision agree; a base that moved between two reads almost always does not.
# It detects change, it is not a security hash: the base policy is the target
# branch's own file, not candidate-controlled input.
crqe_policy_fingerprint() {
  local canonical sum
  canonical=$(printf '%s' "$1" | jq -S -c . 2>/dev/null) || return 1
  [ -n "$canonical" ] || return 1
  sum=$(printf '%s' "$canonical" | cksum) || return 1
  printf '%s\n' "$sum" | awk 'NF == 2 { print $1 "-" $2; ok = 1 } END { exit !ok }'
}

crqe_ack_present() { # reactions-json bot trigger-time; caller binds comment ID
  printf '%s\n' "$1" | jq -r --arg bot "$2" --arg after "$3" '
    [.[] | select(.user.login == $bot) | select(.content == "eyes")
     | select(.created_at >= $after)] | length > 0
  '
}

# Select the newest marker-tagged Codex Review Summary whose Code Review row
# names the given head, as
# `{status, commit, observed_at, trigger, trigger_kind, comment_id}` or `null`
# (#1157).
#
# Codex creates this issue comment when a review starts and edits it in place
# as the review advances, so `updated_at` — not `created_at` — is the signal
# time. The row is exact-head evidence because its Commit cell carries a
# 7-to-40-character hexadecimal prefix. Status remains explicit: `running`
# proves liveness only, while `completed` can prove terminal delivery to a
# diagnostic caller. Neither status is an affirmative merge verdict. The row
# names no trigger comment, so it can show that a review of a head is in
# flight but never which request started it.
#
# `trigger` is the row's Review trigger cell verbatim (trimmed). `trigger_kind`
# classifies it (specs/codex_request_evidence.md § Codex provider surfaces):
# "manual" for `Manual request` (an `@codex review` run), "unsolicited" for
# `PR opened` or `New commits` (an App run nobody asked for), and "unknown"
# for any other text, which a caller must treat as a hold. "manual" still
# names no request; attributing the run to one needs the caller to rule out
# every other configured-author request in the window.
#
# Pure: jq over the passed strings only, no globals and no I/O. Shared by
# codex-review-check.sh (gate diagnostics) and codex-review-request.sh (#1550
# resume check).
crqe_select_codex_review_summary() { # issue-comments-json bot-login head-sha
  printf '%s\n' "${1:-[]}" | jq -c \
    --arg bot "${2:-}" --arg sha "${3:-}" '
    ($sha | ascii_downcase) as $head
    | [ .[]
      | select((.user.login // "") == $bot)
      | select((.body // "") | startswith("<!-- codex-pull-request-review-summary -->"))
      | . as $comment
      | ((.body // "")
          | capture("(?m)^\\|[[:space:]]*📝[[:space:]]*\\*\\*Code Review\\*\\*[[:space:]]*\\|[[:space:]]*(?<status>[^|]+)[[:space:]]*\\|[[:space:]]*`(?<commit>[0-9A-Fa-f]{7,40})`[[:space:]]*\\|[[:space:]]*(?<trigger>[^|]+)[[:space:]]*\\|[[:space:]]*$")?
          // null) as $row
      | select($row != null)
      | ($row.commit | ascii_downcase) as $commit
      | select($head | startswith($commit))
      | { status:
            (if ($row.status | test("\\*\\*Completed\\*\\*"; "i")) then "completed"
             elif ($row.status | test("\\*\\*Running\\*\\*"; "i")) then "running"
             else "unknown" end),
          commit: $commit,
          observed_at: ($comment.updated_at // $comment.created_at // ""),
          trigger: ($row.trigger | gsub("^[[:space:]]+|[[:space:]]+$"; "")),
          trigger_kind:
            ($row.trigger | gsub("^[[:space:]]+|[[:space:]]+$"; "") | ascii_downcase
             | if . == "manual request" then "manual"
               elif . == "pr opened" or . == "new commits" then "unsolicited"
               else "unknown" end),
          comment_id: ($comment.id // 0) }
    ]
    | max_by([.observed_at, .comment_id]) // null
  '
}

# #2664: the provider-run state of the request posted at <request-created-at>
# on <head>, read from Codex's Review Summary row and nothing else (never a
# check-run or status publisher). A row last updated before the request is an
# old placeholder and proves nothing about this request, so it reads as
# "none". "running" is an active run. "completed" says the run ended; with no
# qualifying result the caller treats it as inactive. "failed" and
# "canceled" are confirmed terminal failures. Any other status text is
# "unknown", which never authorizes a retry. retry_after_seconds is a retry
# window the provider states in that comment ("retry after N seconds", "try
# again in N minutes", hours or days, decimals rounded up), else null; a stated
# window it cannot read is a year, never a shorter guess.
#
# Pure: jq over the passed strings only, no globals and no I/O.
crqe_select_codex_run_state() { # issue-comments-json bot-login head-sha request-created-at
  printf '%s\n' "${1:-[]}" | jq -c \
    --arg bot "${2:-}" --arg sha "${3:-}" --arg since "${4:-}" '
    ($sha | ascii_downcase) as $head
    | if $since == "" then error("request time required") else . end
    | [ .[]
      | select((.user.login // "") == $bot)
      | select((.body // "") | startswith("<!-- codex-pull-request-review-summary -->"))
      | . as $comment
      | ((.body // "")
          | capture("(?m)^\\|[[:space:]]*📝[[:space:]]*\\*\\*Code Review\\*\\*[[:space:]]*\\|[[:space:]]*(?<status>[^|]+)[[:space:]]*\\|[[:space:]]*`(?<commit>[0-9A-Fa-f]{7,40})`[[:space:]]*\\|[[:space:]]*(?<trigger>[^|]+)[[:space:]]*\\|[[:space:]]*$")?
          // null) as $row
      | select($row != null)
      | select($head | startswith($row.commit | ascii_downcase))
      | ($comment.updated_at // $comment.created_at // "") as $observed
      | select($observed != "" and $observed >= $since)
      # A stated window whose length cannot be read (an unknown unit, or
      # words such as "a few minutes") reads as a year: longer than any
      # review deadline, so it never lets a retry post early.
      | ((.body // "")
          | [match("(?i)(?:retry[- ]after|try again in)[:[:space:]]*(?<rest>[^\\n]{0,40})"; "g")
             | .captures[0].string
             | (capture("^(?<n>[0-9]+(?:\\.[0-9]+)?)[[:space:]]*(?<u>[[:alpha:]]*)") // null) as $d
             | if $d == null then 31536000
               else ($d.u | ascii_downcase) as $u
                 | (if $u == "" or ($u | test("^(s|secs?|seconds?)$")) then 1
                    elif ($u | test("^(m|mins?|minutes?)$")) then 60
                    elif ($u | test("^(h|hrs?|hours?)$")) then 3600
                    elif ($u | test("^(d|days?)$")) then 86400
                    else null end) as $unit
                 | if $unit == null then 31536000 else ($d.n | tonumber) * $unit | ceil end
               end]
          | max // null) as $retry_after
      | { state:
            (if ($row.status | test("\\*\\*Completed\\*\\*"; "i")) then "completed"
             elif ($row.status | test("\\*\\*Running\\*\\*"; "i")) then "running"
             elif ($row.status | test("\\*\\*(Failed|Error|Errored)\\*\\*"; "i")) then "failed"
             elif ($row.status | test("\\*\\*Cancell?ed\\*\\*"; "i")) then "canceled"
             else "unknown" end),
          observed_at: $observed,
          comment_id: ($comment.id // 0),
          retry_after_seconds: $retry_after }
    ]
    | max_by([.observed_at, .comment_id]) // {state: "none", observed_at: null, comment_id: null, retry_after_seconds: null}
  '
}

# Parse every Codex-bot issue comment that is a verdict into
# {comment_id, created_at, reviewed_shas, affirmative}, oldest first. A
# verdict is a comment carrying a "Reviewed commit: <sha>" anchor or headed
# "Codex Review:" (an older format carries no sha; reviewed_shas is then []).
# The anchor scan and the affirmative test are the exact expressions
# codex-review-request.sh (scan_codex_state) and codex-review-check.sh
# (CODEX_VERDICT_JSON) use; tests/test_codex_review_ledger.sh pins all three
# copies byte-for-byte. Selection differs by design: those two keep only
# verdicts whose full SHA equals the current head and take the latest, while
# this reports every verdict and leaves selection to the caller.
crqe_verdicts() { # issue-comments-json bot-login
  printf '%s\n' "${1:-[]}" | jq -c --arg bot "${2:-}" '
    [ .[]
      | select((.user.login // "") == $bot)
      | . as $c
      | ( [ $c.body // ""
            | ascii_downcase
            | scan("reviewed commit[^0-9a-z_\\r\\n]{0,6}([^\\r\\n]*)")
            | .[0] | sub("^[`*[:space:]]+"; "") | sub("[`*[:space:]]+$"; "")
          ] ) as $fields
      | (if ($fields | length) == ([$c.body // "" | ascii_downcase | scan("reviewed commit")] | length)
               and all($fields[]; test("^[0-9a-f]{7,40}$")) then $fields else [] end) as $shas
      | select(($fields | length) > 0 or (($c.body // "") | test("(?im)^\\s*codex review:")))
      | { comment_id: .id, created_at: .created_at, reviewed_shas: $shas,
          affirmative: ((.body // "") | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b")) }
    ]
    | sort_by(.created_at, .comment_id)
  '
}

# Read-side normalization preserves raw malformed/ambiguous observations.
crqe_resolve_verdict_anchors() { # comments-json repository bot-login
  printf '%s\n' "$1" | python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")/../workflow" && pwd)/resolve-codex-verdict-anchors.py" --repo "$2" --bot "$3"
}

# One substantive head-review selector for requester and merge gate (#1543).
# A body-less wrapper around a threaded reply is not a completed review run.
crqe_select_head_review() { # reviews-json comments-json bot head
  printf '%s\n' "$1" "$2" | jq -s --arg bot "$3" --arg sha "$4" '
    .[0] as $reviews | .[1] as $comments
    | [$reviews[] | select(.user.login == $bot and .commit_id == $sha)
      | . as $r
      | [$comments[] | select(.pull_request_review_id == $r.id)] as $inline
      | select(any($inline[]; (.user.login == $bot) and (.in_reply_to_id == null))
               or (($r.body // "") | test("[^[:space:]]"))
               or ($inline | length) == 0)]
    | max_by(.submitted_at) // null
  '
}

# Same-agent approval substitute: returns its time or empty. Resolved P0/P1
# findings still require a fresh affirmative verdict or independent approval.
crqe_review_approval_time() { # selected-review-json comments-json bot head
  printf '%s\n' "$1" "$2" | jq -s -r --arg bot "$3" --arg sha "$4" '
    .[0] as $review | .[1] as $comments
    | if length == 2 and $review != null and $review.state == "COMMENTED"
        and ($sha | test("^[0-9a-f]{40}$")) and $review.commit_id == $sha
        and (($review.body // "") | test("!\\[P[01] Badge\\]|\\*\\*P[01]") | not)
        and ([ $comments[] | select(.user.login == $bot and .in_reply_to_id == null
          and .pull_request_review_id == $review.id)
          | select((.body // "") | test("!\\[P[01] Badge\\]|\\*\\*P[01]")) ] | length) == 0
      then $review.submitted_at else "" end
  '
}

# #2881: Codex findings in review format posted as a PR-level issue comment.
# Codex normally files findings as a review with inline comments, but it also
# posts the same `### 💡 Codex Review` body (priority badges and blob
# permalinks) as an issue comment, either right after a review or on its own
# (mergepath#1120 issuecomment-5447842730, five minutes after merge). The
# cloud-task reply format (`## Review Findings` / `### [P1] ...`) carries
# findings the same way. Neither has a `Codex review:` header or a
# `Reviewed commit` line, so crqe_verdicts does not see them.
#
# A comment qualifies only when the configured bot wrote it (a GitHub App bot
# login; a present `user.type` must be `Bot`), it is not the Review Summary,
# and it carries a priority marker: a `![Pn Badge]` image or a `[Pn]` heading
# or bold label, n in 0-3. It is never a clean signal. Its anchor is every
# commit named by a `/blob/<40-hex>/` permalink or a `Reviewed commit`
# field: `exact` when all of them equal <head>, `other` when all are valid
# and none does, `none` when there is no anchor, and `mixed` otherwise. A
# caller may drop only `other`; `none` and `mixed` are ambiguous negatives.
#
# Emits [{comment_id, created_at, updated_at, anchor}], oldest first.
# Pure: jq over the passed strings only, no globals and no I/O.
crqe_review_format_findings() { # issue-comments-json bot-login head-sha
  printf '%s\n' "${1:-[]}" | jq -c --arg bot "${2:-}" --arg sha "${3:-}" '
    ($sha | ascii_downcase) as $head
    | [ .[]
      | select((.user.login // "") == $bot and $bot != "")
      | select((.user.type // "Bot") == "Bot")
      | (.body // "") as $body
      | select($body | startswith("<!-- codex-pull-request-review-summary -->") | not)
      | select($body | test("!\\[P[0-3] Badge\\]|(?m)^[[:space:]]*(#{1,6}[[:space:]]*|\\*\\*)\\[P[0-3]\\]"))
      | ([ $body | ascii_downcase | scan("/blob/([0-9a-f]{40})/") | .[0] ]
         + [ $body | ascii_downcase
             | scan("reviewed commit[^0-9a-z_\\r\\n]{0,6}([^\\r\\n]*)")
             | .[0] | sub("^[`*[:space:]]+"; "") | sub("[`*[:space:]]+$"; "") ]) as $anchors
      | { comment_id: .id, created_at: (.created_at // ""),
          updated_at: (.updated_at // .created_at // ""),
          anchor: (if ($anchors | length) == 0 then "none"
                   elif all($anchors[]; . == $head) then "exact"
                   elif all($anchors[]; test("^[0-9a-f]{40}$")) and all($anchors[]; . != $head) then "other"
                   else "mixed" end) }
    ]
    | sort_by(.created_at, .comment_id)
  '
}

# #2881 option (c): is a Codex review still owed on <head>, and has the
# bounded wait for it run out? Emits one object:
#
#   {state, reason, request, terminal_at, running_since, anchor_at, expires_at}
#
#   none       no configured-author request, and no run in flight
#   answered   Codex produced a terminal outcome on <head> strictly after the
#              latest configured-author request (whole PR), and no Code
#              Review run on <head> started after that outcome
#   pending    otherwise, and the bounded wait has not run out
#   timed-out  otherwise, and now >= anchor + <timeout-seconds>. This is a
#              fallback to the independent Phase 4b approval, never a Codex
#              outcome: Codex may still be running and may post findings
#              after merge.
#   unreadable an author request lacks a positive id or a readable created_at
#
# The latest request counts across the whole PR. Using head transitions to
# exclude requests made on earlier heads would need ordinary-push evidence,
# which crqe_latest_head_transition does not have, so an earlier-head request
# simply waits for an exact-head outcome or its own timeout.
#
# Terminal outcomes on <head>, each timed by the object's own server field:
#   - a configured-bot review whose commit_id is <head> (submitted_at);
#   - a verdict comment whose every Reviewed commit anchor is <head>, and a
#     `Codex review:` comment with no anchor, such as "Something went wrong"
#     (created_at: a reply without a review still answers the request);
#   - a usage-limit or not-connected refusal (created_at);
#   - an exact-head review-format findings comment (created_at);
#   - a Review Summary whose `codex-review-state:v1` code_review names <head>
#     in full with status `completed`, timed by the run timestamp Codex
#     writes into the status cell (`<relative-time datetime=...>`). The
#     comment's own updated_at is not used: an unrelated edit must not make
#     an old completion look new. A row whose commit disagrees with the JSON,
#     or whose run time is unreadable or later than the comment's updated_at
#     plus 300 seconds, is not evidence.
# A Summary on <head> with status `running` contributes its run time as
# running_since.
#
# Ordering uses whole seconds, and an outcome must be strictly later than the
# request: a same-second outcome does not answer it. Different object types
# are ordered by time only, never by id. The timeout anchor is the latest
# request's server created_at, or, when only a run is in flight, that run's
# provider-written start time. A rerun of the gate cannot move either.
#
# Pure: jq over the passed strings only (on stdin, so a large PR cannot hit
# the argument-size limit); the caller supplies now.
crqe_codex_pending_state() { # comments-json reviews-json|{reviews,inline} author bot head timeout-seconds now-epoch [usage-re] [not-connected-re]
  printf '%s\n' "${1:-null}" "${2:-null}" | jq -sc \
    --arg author "${3:-}" --arg bot "${4:-}" --arg sha "${5:-}" \
    --arg timeout "${6:-}" --arg now "${7:-}" \
    --arg usage_re "${8:-}" --arg nc_re "${9:-}" '
    def secs: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")
              then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) else null end;
    def iso: if . == null then null else todate end;
    def is_bot: (.user.login // "") == $bot and $bot != "" and ((.user.type // "Bot") == "Bot");
    # Every commit a comment names: Reviewed commit fields and blob
    # permalinks, the same set crqe_review_format_findings classifies.
    def anchors: (.body // "") | ascii_downcase
      | [ (scan("reviewed commit[^0-9a-z_\\r\\n]{0,6}([^\\r\\n]*)") | .[0]
           | sub("^[`*[:space:]]+"; "") | sub("[`*[:space:]]+$"; "")),
          (scan("/blob/([0-9a-f]{40})/") | .[0]) ];
    (if length == 2 then .[0] else null end) as $comments
    | (if length == 2 then .[1] else null end) as $review_input
    # The second input is the reviews array, or {reviews, inline} with the
    # inline review comments that tell a reply wrapper from a review run.
    | (if ($review_input | type) == "object" then $review_input.reviews else $review_input end) as $reviews
    | (if ($review_input | type) == "object" then $review_input.inline else [] end) as $inline
    | ($sha | ascii_downcase) as $head
    | if ($comments | type) != "array" or ($reviews | type) != "array" or ($inline | type) != "array"
         or ($head | test("^[0-9a-f]{40}$") | not)
         or ($timeout | test("^[0-9]+$") | not) or ($now | test("^[0-9]+$") | not)
      then {state: "unreadable", reason: "invalid-input"}
      else
      ($timeout | tonumber) as $window | ($now | tonumber) as $t_now
      | [ $comments[]
          | select((.user.login // "") == $author)
          | select((.body // "") | test("\\A@codex review\\z"; "i")) ] as $requests
      | if any($requests[]; ((.id | type) != "number") or .id <= 0 or (.id | floor) != .id
                            or ((.created_at | secs) == null))
        then {state: "unreadable", reason: "request-unreadable"}
        else
        ($requests | max_by([(.created_at | secs), .id])) as $req
        | ($req.created_at | if . == null then null else secs end) as $req_at
        | [ $comments[] | select(is_bot) ] as $botc
        # Every Review Summary that may describe <head>: its JSON names <head>,
        # its row commit is a prefix of <head>, or it names no commit at all. A relevant summary that does not validate (JSON
        # missing or malformed, the row missing, the row commit or status
        # disagreeing with the JSON, a status outside completed / running /
        # failed / canceled, an unreadable run time, or one later than the
        # last edit of the comment plus 300 s) is `unreadable`: it never answers,
        # and it holds, bounded from its last edit (Phase 4b on #2886).
        # A Summary is recognized by its leading marker, its state marker or
        # its heading, so a Summary whose leading marker is missing or damaged
        # is held as unreadable rather than ignored (Phase 4b round 3 on #2886).
        | [ $botc[]
            | select((.body // "") | startswith("<!-- codex-pull-request-review-summary -->")
                     or contains("codex-review-state:v1") or test("(?m)^#+[[:space:]]*Codex Review Summary"))
            | . as $c
            # A missing or damaged marker must read as null, not as no value:
            # capture emits nothing on no match, which would drop the whole
            # summary (Codex P1 on #2886).
            | ([ (.body // "") | capture("<!-- codex-review-state:v1 (?<j>\\{[^\\n]*\\}) -->")? | .j ] | first) as $sj_raw
            | (if $sj_raw == null then null else (try ($sj_raw | fromjson) catch null) end) as $sj
            | ((.body // "") | capture("(?m)^\\|[[:space:]]*📝[[:space:]]*\\*\\*Code Review\\*\\*[[:space:]]*\\|[[:space:]]*(?<status>[^|]+)[[:space:]]*\\|[[:space:]]*`(?<commit>[0-9A-Fa-f]{7,40})`[[:space:]]*\\|[[:space:]]*(?<trigger>[^|]+)[[:space:]]*\\|[[:space:]]*$")? // null) as $row
            | (if ($sj | type) == "object" and ($sj.code_review | type) == "object"
                  and (($sj.code_review.commit_sha // "") | type) == "string"
                  and ($sj.code_review.commit_sha | ascii_downcase | test("^[0-9a-f]{40}$"))
               then ($sj.code_review.commit_sha | ascii_downcase) else null end) as $jc
            | (if $row == null then null else ($row.commit | ascii_downcase) end) as $rc
            # Relevant when either representation names <head>, or neither
            # names a commit: a JSON commit for another head beside a row for
            # <head> is a conflict that holds, never a drop (Phase 4b round 3
            # on #2886).
            | select($jc == $head or ($rc != null and ($head | startswith($rc))) or ($jc == null and $rc == null))
            | (if $row == null then null
               elif ($row.status | test("\\*\\*Completed\\*\\*"; "i")) then "completed"
               elif ($row.status | test("\\*\\*Running\\*\\*"; "i")) then "running"
               elif ($row.status | test("\\*\\*Failed\\*\\*"; "i")) then "failed"
               elif ($row.status | test("\\*\\*Cancell?ed\\*\\*"; "i")) then "canceled"
               else "unknown" end) as $rs
            | (if $row == null then null
               else (($row.status | capture("datetime=\"(?<d>[^\"]+)\"")? // null) | if . == null then null else (.d | secs) end) end) as $run
            | (($c.updated_at // $c.created_at) | secs) as $edited
            | if $jc == $head and $rc != null and ($head | startswith($rc))
                 and $rs != null and $rs != "unknown"
                 and (($sj.code_review.status // "") == $rs)
                 and $run != null and $edited != null and $run <= $edited + 300
              then {status: $rs, at: $run}
              else {status: "unreadable", at: $edited} end ] as $summaries
        # A review counts only when it is a review run, as in
        # crqe_select_head_review: a body-less wrapper whose inline comments
        # are all replies is not one (Phase 4b on #2886).
        | ( [ $reviews[] | select(is_bot) | select((.commit_id // "" | ascii_downcase) == $head)
              | . as $r
              | [ $inline[] | select(.pull_request_review_id == $r.id) ] as $own
              | select(any($own[]; ((.user.login // "") == $bot) and (.in_reply_to_id == null))
                       or (($r.body // "") | test("[^[:space:]]"))
                       or ($own | length) == 0)
              | (.submitted_at | secs) ]
          # A verdict answers only when every anchor it names is <head>; an
          # unanchored `Codex review:` reply (an error) answers without one.
          + [ $botc[]
              | select(((.body // "") | test("(?im)^\\s*codex review:"))
                       or ((.body // "") | ascii_downcase | test("reviewed commit")))
              | anchors as $a
              | select((($a | length) > 0 and all($a[]; . == $head))
                       or (($a | length) == 0 and ((.body // "") | test("(?im)^\\s*codex review:"))))
              | (.created_at | secs) ]
          + [ $botc[]
              | select(((.body // "") | test("(?im)^\\s*codex review:")) | not)
              | select(($usage_re != "" and ((.body // "") | test($usage_re; "i")))
                       or ($nc_re != "" and ((.body // "") | test($nc_re; "i"))))
              | (.created_at | secs) ]
          + [ $botc[]
              | select((.body // "") | startswith("<!-- codex-pull-request-review-summary -->") | not)
              | select((.body // "") | test("!\\[P[0-3] Badge\\]|(?m)^[[:space:]]*(#{1,6}[[:space:]]*|\\*\\*)\\[P[0-3]\\]"))
              | anchors as $a
              | select(($a | length) > 0 and all($a[]; . == $head))
              | (.created_at | secs) ]
          + [ $summaries[] | select(.status == "completed" or .status == "failed" or .status == "canceled") | .at ]
          | map(select(. != null)) | max ) as $terminal
        | ([ $summaries[] | select(.status == "running") | .at ] | max) as $running
        | ([ $summaries[] | select(.status == "unreadable") | .at ]) as $bad
        | (if $req_at != null and ($terminal == null or $terminal <= $req_at) then
             {anchor: $req_at, reason: "request-unanswered"}
           elif $running != null and ($terminal == null or $running > $terminal) then
             {anchor: $running, reason: "review-running"}
           elif any($bad[]; . == null) then {anchor: null, reason: "summary-unreadable"}
           elif any($bad[]; $terminal == null or . > $terminal) then
             {anchor: ($bad | max), reason: "summary-unreadable"}
           else null end) as $owed
        | {request: (if $req == null then null else {id: $req.id, created_at: $req.created_at} end),
           terminal_at: ($terminal | iso), running_since: ($running | iso)} as $base
        | if $owed != null and $owed.anchor == null then
            $base + {state: "unreadable", reason: "summary-unreadable-without-time", anchor_at: null, expires_at: null}
          elif $owed == null then
            $base + {state: (if $req == null then "none" else "answered" end),
                     reason: (if $req == null then "no-request" else "request-answered" end),
                     anchor_at: null, expires_at: null}
          else
            ($owed.anchor + $window) as $exp
            | $base + {state: (if $t_now >= $exp then "timed-out" else "pending" end),
                       reason: $owed.reason, anchor_at: ($owed.anchor | iso), expires_at: ($exp | iso)}
          end
        end
      end'
}

# #2881 (Phase 4b on #2886): every Codex comment that carries a verdict or
# findings, classified once with the complete anchor set so the gate's verdict
# ordering, its fresh-snapshot ordering and the owed-review check agree. A
# comment qualifies when the configured bot wrote it (a present user.type must
# be `Bot`), it is not the Review Summary, and it has a `Codex review:` header,
# a Reviewed commit field or a priority marker. Its anchors are every Reviewed
# commit field and every `/blob/<40-hex>/` permalink: `exact` (all name
# <head>), `other` (all are valid full SHAs and none is <head>), `none`, or
# `mixed`. It is `affirmative` only when its header is the clean verdict, it
# carries no priority marker, and its anchor is `exact`; anything else is a
# negative signal. `at` is its latest server time (created or edited); a
# qualifying comment that is not `other` and has no readable time fails the
# call, so an unreadable negative is never dropped.
#
# Emits [{comment_id, at, anchor, affirmative}], oldest first.
crqe_codex_comment_signals() { # issue-comments-json bot-login head-sha
  printf '%s\n' "${1:-[]}" | jq -c --arg bot "${2:-}" --arg sha "${3:-}" '
    def iso_ok: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$");
    ($sha | ascii_downcase) as $head
    | if type != "array" or ($head | test("^[0-9a-f]{40}$") | not) or $bot == "" then error("input") else . end
    | [ .[]
      | select((.user.login // "") == $bot and ((.user.type // "Bot") == "Bot"))
      | (.body // "") as $body
      | select($body | type == "string")
      | select($body | startswith("<!-- codex-pull-request-review-summary -->") | not)
      | ($body | test("!\\[P[0-3] Badge\\]|(?m)^[[:space:]]*(#{1,6}[[:space:]]*|\\*\\*)\\[P[0-3]\\]")) as $marked
      | ($body | test("(?im)^\\s*codex review:")) as $header
      | ($body | ascii_downcase | test("reviewed commit")) as $field
      | select($marked or $header or $field)
      | ($body | ascii_downcase
         | [ (scan("reviewed commit[^0-9a-z_\\r\\n]{0,6}([^\\r\\n]*)") | .[0]
              | sub("^[`*[:space:]]+"; "") | sub("[`*[:space:]]+$"; "")),
             (scan("/blob/([0-9a-f]{40})/") | .[0]) ]) as $a
      | (if ($a | length) == 0 then "none"
         elif all($a[]; . == $head) then "exact"
         elif all($a[]; test("^[0-9a-f]{40}$")) and all($a[]; . != $head) then "other"
         else "mixed" end) as $anchor
      | ([.created_at, .updated_at] | map(select(. != null))) as $times
      | if $anchor != "other" and (($times | length) == 0 or any($times[]; iso_ok | not))
        then error("unreadable time on a Codex verdict or findings comment") else . end
      | { comment_id: .id, at: ($times | max), anchor: $anchor,
          affirmative: ($anchor == "exact" and ($marked | not)
                        and ($body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b"))) }
    ]
    | sort_by(.at, .comment_id)
  '
}

# #2881 (Phase 4b on #2886): the newest Codex signal on <head> in one
# snapshot, for the substitute's latest-signal-wins guard, so the guard and
# crqe_codex_pending_state read the same evidence. Prints an ISO time or
# empty. Signals: the substantive head review (crqe_select_head_review) and
# every classified comment that is not anchored only to other commits, either
# disposition. Fails on unreadable input, including an unreadable time.
crqe_latest_codex_signal_time() { # comments-json reviews-json inline-json bot head
  local review comments
  review=$(crqe_select_head_review "$2" "$3" "$4" "$5") || return 1
  [ -n "$review" ] || return 1
  if [ "$review" != null ]; then
    review=$(printf '%s' "$review" | jq -er '.submitted_at | select(type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))') || return 1
  else
    review=""
  fi
  comments=$(crqe_codex_comment_signals "$1" "$4" "$5") || return 1
  comments=$(printf '%s' "$comments" | jq -er '[ .[] | select(.anchor != "other") | .at ] | max // ""') || return 1
  printf '%s\n%s\n' "$review" "$comments" | jq -Rsr 'split("\n") | map(select(length > 0)) | max // ""'
}
