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

crqe_count_triggers() { # comments-json author
  local generation
  generation=$(crqe_trigger_generation "$1" "$2") || return 1
  printf '%s\n' "$generation" | jq -er 'length'
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
# Prints {author_identity,max_request_attempts,max_blocking_reviews,
# reaction_freshness_window_seconds}, with max_blocking_reviews null when its
# governed value is invalid;
# returns non-zero on every
# unreadable or malformed input. A materialized policy is removed here.
crqe_governing_budget() { # repo pr default-config candidate-author [resolver [base-ref base-sha default-branch]]
  local repo="$1" pr="$2" config="$3" candidate="$4"
  local resolver="${5:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/workflow/resolve_base_policy.sh}"
  local base_ref="${6:-}" base_sha="${7:-}" default_branch="${8:-}"
  local base_cfg="" base_json="" author="" cap="" blocking="" freshness="" rc=0
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
# verdicts whose sha prefixes the current head and take the latest, while
# this reports every verdict and leaves selection to the caller.
crqe_verdicts() { # issue-comments-json bot-login
  printf '%s\n' "${1:-[]}" | jq -c --arg bot "${2:-}" '
    [ .[]
      | select((.user.login // "") == $bot)
      | . as $c
      | ( [ $c.body // ""
            | ascii_downcase
            | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
            | .[0]
          ] ) as $shas
      | select(($shas | length) > 0 or (($c.body // "") | test("(?im)^\\s*codex review:")))
      | { comment_id: .id, created_at: .created_at, reviewed_shas: $shas,
          affirmative: ((.body // "") | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b")) }
    ]
    | sort_by(.created_at, .comment_id)
  '
}
