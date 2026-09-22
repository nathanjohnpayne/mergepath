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

crqe_ack_present() { # reactions-json bot trigger-time; caller binds comment ID
  printf '%s\n' "$1" | jq -r --arg bot "$2" --arg after "$3" '
    [.[] | select(.user.login == $bot) | select(.content == "eyes")
     | select(.created_at >= $after)] | length > 0
  '
}
