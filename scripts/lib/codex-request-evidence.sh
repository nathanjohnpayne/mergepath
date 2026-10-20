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
# timestamps, and has no other author trigger between the two. So a marker
# cannot be added to an old request later, and at most one trigger per named
# head is exempt. Anything else, malformed or unreadable, leaves the trigger
# counted: a missing exemption costs a request slot, never the ceiling. The
# trigger stays in the request generation; only the ceiling skips it.
CRQE_FAILOVER_MARKER_WINDOW_SECONDS=300

crqe_failover_marker_body() { # full-head-sha trigger-comment-id
  [[ "${1-}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ && "${2-}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '<!-- mergepath-codex-failover:v1 head=%s trigger_comment_id=%s -->' "$1" "$2"
}

# Prints the sorted ids of the exempt failover triggers.
crqe_failover_trigger_ids() { # comments-json author
  printf '%s\n' "$1" | jq -cer --arg author "$2" --argjson window "$CRQE_FAILOVER_MARKER_WINDOW_SECONDS" '
    def epoch: try fromdateiso8601 catch null;
    [ .[] | select(type == "object" and (.user.login // "") == $author) ] as $mine
    | [ $mine[] | select((.body // "") | test("\\A@codex review\\z"; "i")) ] as $triggers
    | [ $mine[]
        | select((.body | type) == "string" and (.id | type) == "number"
                 and (.created_at | type) == "string" and .updated_at == .created_at)
        | . as $m
        | ($m.body | capture("\\A<!-- mergepath-codex-failover:v1 head=(?<head>[0-9a-f]{40}|[0-9a-f]{64}) trigger_comment_id=(?<trigger>[1-9][0-9]*) -->\\z"))
        | .head as $head
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
crqe_count_triggers() { # comments-json author
  local generation exempt
  generation=$(crqe_trigger_generation "$1" "$2") || return 1
  exempt=$(crqe_failover_trigger_ids "$1" "$2") || return 1
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
# names the given head, as `{status, commit, observed_at, trigger, comment_id}`
# or `null` (#1157).
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
# Pure: jq over the passed strings only, no globals and no I/O. Shared by
# codex-review-check.sh (gate diagnostics) and codex-review-request.sh (#1550
# resume check).
crqe_select_codex_review_summary() { # issue-comments-json bot-login head-sha
  echo "${1:-[]}" | jq -c \
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
          comment_id: ($comment.id // 0) }
    ]
    | max_by([.observed_at, .comment_id]) // null
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
