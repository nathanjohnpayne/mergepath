#!/usr/bin/env bash
# scripts/lib/codex-failure-markers.sh — single source of truth for the
# Codex App account-/connection-level failure-marker regexes (#722) and the
# durable Phase 4a terminal-determination marker (#1085).
#
# The ChatGPT Codex Connector GitHub App answers a `@codex review` trigger
# with a plain PR comment — carrying NO findings, NO `Reviewed commit:`
# anchor, and NO reaction — in two failure states the live Phase 4a scripts
# could not previously recognize:
#
#   usage_limit    account-level quota exhaustion for code reviews. Real
#                  wording: "You have reached your Codex usage limits for
#                  code reviews. … upgrade your account or add credits …".
#                  No amount of waiting or re-triggering clears it — a human
#                  must upgrade / add credits.
#   not_connected  the Codex App is not connected / has no environment. Real
#                  wording: "To use Codex here, connect your GitHub account
#                  …". The trigger produced no review round at all (the #570
#                  dropped-trigger class).
#
# Because such a comment matched none of scan_codex_state()'s signal kinds
# (`review` / `reaction` / `verdict` all stay null), codex-review-request.sh
# ran out the full review_timeout_seconds window and exited 4 — the SAME
# exit as a genuinely slow review, with no root-cause context for the agent
# or the Phase 4b handoff (the failure reported in #722).
#
# scripts/audit-codex-latency.sh has detected both retrospectively for a
# while (its normalize phase classifies them as `rate_limit` /
# `dropped_trigger_marker` events), but that detection lived ONLY in the
# retrospective audit. This lib factors the two regexes out so the audit and
# the live scripts (codex-review-request.sh, codex-review-check.sh) test the
# IDENTICAL patterns instead of drifting (#722 proposal 1).
#
# Contract:
#   - CODEX_USAGE_LIMIT_MARKER_RE / CODEX_NOT_CONNECTED_MARKER_RE are the
#     canonical ERE pattern bodies, WITHOUT a leading `(?i)` inline flag and
#     WITHOUT anchors — every caller applies case-insensitivity explicitly
#     (jq `test($re; "i")`, grep `-iE`) and matches the marker wherever it
#     appears in a longer bot comment. Keeping the `(?i)` out of the stored
#     pattern is what lets jq's `test(re; "i")` and grep's `-i` share one
#     literal.
#   - usage_limit is checked BEFORE not_connected (a comment matching both
#     is quota-blocked first), and a caller that also recognizes verdicts
#     MUST classify a verdict comment as a verdict first — a marker is only a
#     marker on a NON-verdict bot comment (mirrors audit-codex-latency.sh's
#     normalize precedence: verdict → rate_limit → dropped_trigger_marker).
#   - codex_failure_marker_of <body> echoes `usage_limit`, `not_connected`,
#     or the empty string, and always returns 0. It does NOT exclude
#     verdicts — verdict precedence is the caller's job (see above).
#
# Sourced by scripts/audit-codex-latency.sh (hub-only) and, existence-
# guarded, by the two propagated live Phase 4a scripts. Sourcing has no side
# effects beyond defining constants and functions.

# Rate-limit / usage-limit / quota-exhaustion marker. Mirrors the pattern
# audit-codex-latency.sh's normalize phase has used for its `rate_limit`
# event kind; the alternation is grouped so `test(re; "i")` reads as one
# marker check.
CODEX_USAGE_LIMIT_MARKER_RE='(rate.?limit|usage.?limit|quota|limit (was|has been) (hit|reached)|try again (later|in))'

# Dropped-trigger / app-not-connected marker (#570 class): the Codex App was
# not connected or had no environment, so the trigger produced no round.
CODEX_NOT_CONNECTED_MARKER_RE='to use codex here'

# Classify a single comment body into a Codex failure-marker kind.
# Echoes: usage_limit | not_connected | "" (no marker). Always returns 0 so
# a no-match does not trip a caller's `set -e`.
codex_failure_marker_of() {
  local body=${1-}
  if printf '%s' "$body" | grep -iqE "$CODEX_USAGE_LIMIT_MARKER_RE"; then
    printf 'usage_limit'
  elif printf '%s' "$body" | grep -iqE "$CODEX_NOT_CONNECTED_MARKER_RE"; then
    printf 'not_connected'
  fi
  return 0
}

# A normal Phase 4a timeout is not a provider-authored failure marker: it is a
# conclusion reached by codex-review-request.sh after a confirmed trigger and
# the configured bounded wait. Before #1085 that conclusion existed only as
# one process' exit 4/stdout, so a later trusted-checkout Phase 4b invocation
# reconstructed the same head as ordinary pending and waited a second time.
#
# The timeline comment below is the durable handoff. Its exact grammar is
# intentionally narrow:
#   - versioned, provider- and outcome-named;
#   - pinned to a full SHA-1 or SHA-256 object id (never an abbreviation);
#   - bound to the concrete author-owned `@codex review` comment whose wait
#     expired.
#
# Consumers must also trust-scope the marker comment to author_identity and
# verify the referenced trigger in the same paginated issue-comment list.
# codex_phase4a_timeout_marker_state does all of that in one shared parser so
# the writer's readback and Phase 4b cannot drift on marker semantics.
CODEX_PHASE4A_TERMINAL_MARKER_PREFIX='<!-- mergepath-phase-4a-terminal:'
CODEX_PHASE4A_TIMEOUT_MARKER_RE='^<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=(?<head>(?:[0-9a-f]{40}|[0-9a-f]{64})) trigger_comment_id=(?<trigger>[1-9][0-9]*) -->$'

codex_phase4a_full_sha_ok() {
  local head=${1-}
  case "$head" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#head}" -eq 40 ] || [ "${#head}" -eq 64 ]
}

codex_phase4a_comment_id_ok() {
  local id=${1-}
  case "$id" in ''|0|0*|*[!0-9]*) return 1 ;; esac
  return 0
}

# codex_phase4a_timeout_marker_body <full-head-sha> <trigger-comment-id>
# Prints the one canonical body. Invalid inputs produce no output and rc 1.
codex_phase4a_timeout_marker_body() {
  codex_phase4a_full_sha_ok "${1-}" || return 1
  codex_phase4a_comment_id_ok "${2-}" || return 1
  printf '<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=%s trigger_comment_id=%s -->' "$1" "$2"
}

# codex_phase4a_trigger_comment_present <author> <id> <comments-json>
# True only for the exact author-owned command. A reviewer-/bot-authored or
# prose-containing mention is not evidence that the App was requested.
codex_phase4a_trigger_comment_present() {
  local author=${1-} id=${2-} comments=${3-}
  [ -n "$author" ] || return 1
  codex_phase4a_comment_id_ok "$id" || return 1
  printf '%s' "$comments" | jq -e --arg who "$author" --argjson id "$id" '
    any(.[]?;
      (.id == $id)
      and ((.user.login // "") == $who)
      and ((.body // "") == "@codex review"))
  ' >/dev/null 2>&1
}

# codex_phase4a_timeout_marker_state <head> <author> <comments-json>
# Emits one JSON object with state:
#   current    at least one valid marker for <head>, bound to a preceding
#              exact author trigger; duplicate valid records are idempotent.
#   stale      valid marker grammar exists, but only for another head.
#   none       no trusted marker candidate exists (including forged/quoted).
#   malformed  a trusted marker candidate has unknown/bad grammar, or a
#              current-head record is not bound to its claimed trigger.
#
# A candidate must BEGIN with the hidden-marker namespace. That means quoting
# a marker in ordinary prose cannot create either evidence or a denial of
# service. Once the trusted author deliberately begins a comment with the
# namespace, however, malformed evidence fails closed rather than degrading to
# absence. A stale, parseable marker does not validate its old trigger because
# it cannot waive this head either way; this prevents obsolete damaged history
# from wedging every later head on the PR.
codex_phase4a_timeout_marker_state() {
  local head=${1-} author=${2-} comments=${3-}
  if ! codex_phase4a_full_sha_ok "$head" || [ -z "$author" ]; then
    jq -nc --arg r invalid-input '{state:"malformed",reason:$r}'
    return 0
  fi

  printf '%s' "$comments" | jq -c \
    --arg head "$head" \
    --arg who "$author" \
    --arg prefix "$CODEX_PHASE4A_TERMINAL_MARKER_PREFIX" \
    --arg re "$CODEX_PHASE4A_TIMEOUT_MARKER_RE" '
    if type != "array" then
      {state:"malformed",reason:"comments-json"}
    else
      . as $all
      | [ .[]?
          | select((.user.login // "") == $who)
          | . + {normalized_body: ((.body // "") | rtrimstr("\n") | rtrimstr("\r"))}
        ] as $trusted
      | [ $trusted[] | select(.normalized_body | startswith($prefix)) ] as $candidates
      | [ $candidates[]
          | . as $comment
          | ((try ($comment.normalized_body | capture($re)) catch null) // null) as $match
          | select($match != null)
          | {
              marker_id: ($comment.id // null),
              marker_created_at: ($comment.created_at // ""),
              head: $match.head,
              trigger_comment_id: ($match.trigger | tonumber)
            }
        ] as $parsed
      | [ $candidates[]
          | ((try (.normalized_body | capture($re)) catch null) // null) as $match
          | select($match == null)
          | (.id // null)
        ] as $bad_schema
      | [ $parsed[] | select(.head == $head) ] as $on_head
      | [ $on_head[]
          | . as $marker
          | select(
              ($marker.marker_created_at
                | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
              | not
              or ([ $all[]?
                    | select(
                        (.id == $marker.trigger_comment_id)
                        and ((.user.login // "") == $who)
                        and ((.body // "") == "@codex review")
                        and ((.created_at // "")
                          | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
                        and ((.created_at // "") <= $marker.marker_created_at)
                      )
                  ] | length == 0)
            )
        ] as $bad_binding
      | if ($bad_schema | length) > 0 then
          {state:"malformed",reason:"schema",comment_id:$bad_schema[0]}
        elif ($bad_binding | length) > 0 then
          {state:"malformed",reason:"trigger-binding",comment_id:$bad_binding[0].marker_id}
        elif ($on_head | length) > 0 then
          {state:"current",marker_id:$on_head[0].marker_id,trigger_comment_id:$on_head[0].trigger_comment_id}
        elif ($parsed | length) > 0 then
          {state:"stale"}
        else
          {state:"none"}
        end
    end
  ' 2>/dev/null || jq -nc --arg r comments-json '{state:"malformed",reason:$r}'
}
