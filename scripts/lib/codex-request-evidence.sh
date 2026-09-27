#!/usr/bin/env bash
# Read-only selectors shared by request deduplication/ack and blocked evidence.
# A trigger qualifies by complete command body, author, and freshness, not an
# immutable commit anchor.
crqe_select_trigger() { # comments-json author since
  printf '%s\n' "$1" | jq -c --arg author "$2" --arg since "$3" '
    [.[] | select((.user.login // "") == $author)
     | select((.body // "") | test("\\A@codex review\\z"; "i"))
     | select(.created_at >= $since)]
    | max_by([.created_at, .id]) // null
  '
}

# Count the configured author's exact request commands across a whole PR.
# Comment IDs, rather than pages or timestamps, are the durable accounting
# unit: GitHub pagination can repeat an item, while a command can remain the
# only request evidence when Codex answers with a clean summary or reaction.
# A malformed qualifying command has no safe count and therefore fails the
# caller closed instead of being omitted from the budget.
crqe_count_triggers() { # comments-json author
  printf '%s\n' "$1" | jq -er --arg author "$2" '
    [ .[]
      | select((.user.login // "") == $author)
      | select((.body // "") | test("\\A@codex review\\z"; "i"))
      | .id
    ] as $ids
    | if all($ids[]; type == "number" and . > 0 and floor == .)
      then ($ids | unique | length)
      else error("qualifying Codex request comment lacks a positive integer id")
      end
  '
}

# Compute the request freshness anchor shared by the requester and Phase 4b
# cap sensing. Inputs are already-read evidence so each caller retains its own
# API failure action. Prints the full anchor record as JSON.
crqe_request_threshold() { # head-committer-date timeline-json freshness-seconds epoch-now
  local committed="$1" timeline="$2" seconds="$3" epoch="$4"
  local forced pushed source floor fresh threshold threshold_source
  case "$seconds:$epoch" in *[!0-9:]*) return 1 ;; esac
  forced=$(printf '%s' "$timeline" | jq -er \
    '[.[] | select(.event == "head_ref_force_pushed") | .created_at] | max // ""') \
    || return 1
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

# Resolve the request budget from the PR's governing base policy. The caller
# must already have sourced feedback-policy-helpers.sh (policy_yaml_to_json).
# Prints {author_identity,max_request_attempts,reaction_freshness_window_seconds};
# returns non-zero on every
# unreadable or malformed input. A materialized policy is removed here.
crqe_governing_budget() { # repo pr default-config candidate-author [resolver [base-ref base-sha default-branch]]
  local repo="$1" pr="$2" config="$3" candidate="$4"
  local resolver="${5:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/workflow/resolve_base_policy.sh}"
  local base_ref="${6:-}" base_sha="${7:-}" default_branch="${8:-}"
  local base_cfg="" base_json="" author="" cap="" freshness="" rc=0
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
  author=$(printf '%s' "$base_json" | jq -er '
    if type != "object" then error("policy")
    elif has("author_identity") then
      if ((.author_identity | type) == "string") and ((.author_identity | length) > 0)
      then .author_identity else error("author") end
    else "nathanjohnpayne" end') || return 1
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
  jq -nc --arg author "$author" --argjson cap "$cap" --argjson freshness "$freshness" \
    '{author_identity:$author,max_request_attempts:$cap,
      reaction_freshness_window_seconds:$freshness}'
}

crqe_ack_present() { # reactions-json bot trigger-time; caller binds comment ID
  printf '%s\n' "$1" | jq -r --arg bot "$2" --arg after "$3" '
    [.[] | select(.user.login == $bot) | select(.content == "eyes")
     | select(.created_at >= $after)] | length > 0
  '
}
