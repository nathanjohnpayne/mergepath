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

crqe_ack_present() { # reactions-json bot trigger-time; caller binds comment ID
  printf '%s\n' "$1" | jq -r --arg bot "$2" --arg after "$3" '
    [.[] | select(.user.login == $bot) | select(.content == "eyes")
     | select(.created_at >= $after)] | length > 0
  '
}
