#!/usr/bin/env bash
# scripts/workflow/installation-budget.sh — the Actions installation-token
# budget guard. Sourced, never executed.
#
# The gate workflows spend the repository's Actions installation budget
# (secrets.GITHUB_TOKEN: 1,000 REST requests per hour, plus a separate GraphQL
# bucket). #2225 gave the Required Check Publisher a guard: read the remaining
# budget before spending it, stop at the first installation rate-limit failure,
# and back a rate-limit red off until the window resets. This file is that
# guard, extracted so the event-driven gate workflows (#2286) read the budget
# exactly the way the publisher does instead of each carrying its own reader.
#
# Callers:
#   .github/workflows/required-check-publisher.yml   (publish step)
#   .github/workflows/codex-feedback-archive-relay.yml
#   .github/workflows/codex-p1-gate.yml               (event-driven job)
#   .github/workflows/coderabbit-severity-gate.yml    (event job, issue_comment path)
#   .github/workflows/merge-clearance-gate.yml        (event-driven job)
#   .github/workflows/auto-clear-blocking-labels.yml  (event-driven job)
#
# Interface. Every function reads and writes these shell globals, the names the
# publisher has always used:
#   per_pr reserve gql_per_pr gql_reserve   the knobs (set by ib_read)
#   budget_known gql_known                  1 when that bucket was readable
#   rl_remaining rl_reset                   REST core bucket from GET /rate_limit
#   gql_remaining gql_reset                 GraphQL bucket from GET /rate_limit
#   RATE_LIMIT_RESET_ISO                    the REST reset as ISO-8601
#   spent                                   requests the caller already spent
#                                           against this snapshot (default 0)
#
#   ib_read PER_EVAL RESERVE GQL_PER_EVAL GQL_RESERVE
#       Reads GET /rate_limit once (it does not count against the limit). An
#       unreadable answer, or a malformed knob, leaves budget_known=0: every
#       caller then evaluates exactly as it would without the guard, with a
#       warning. That direction is deliberate (#2220, kept by #2286): an
#       unreadable /rate_limit is not evidence the budget is gone, and an
#       evaluation that does run into an exhausted bucket fails closed on its
#       own (a red, never a green).
#   ib_affordable N       exit 0 when BOTH buckets cover N evaluations plus
#                         their reserves (net of `spent`), or the budget is
#                         unknown.
#   ib_capacity           how many evaluations the budget covers beyond the
#                         reserves (1000000 when unknown).
#   ib_short_bucket_reset ISO reset of the bucket(s) that cannot cover one
#                         evaluation (the later one when both cannot).
#   ib_rate_limited TEXT  exit 0 when TEXT carries GitHub's installation
#                         rate-limit error (REST "rate limit exceeded for
#                         installation", GraphQL "rate limit already exceeded
#                         for installation").
#   ib_exhausted_reset [TEXT]
#                         ISO reset of the bucket that actually ran out, read
#                         from the X-RateLimit-* headers of a probe on the same
#                         token and bucket (see the function), falling back to
#                         GET /rate_limit. Prints nothing when neither answers.
#   ib_backoff_title CONTEXT RC [RESET_ISO]
#                         The red title the publisher's due() backs off on:
#                         "<context> — installation API budget exhausted
#                         (rc=N); re-evaluated after <reset>". Event passes
#                         leave such a context alone until the reset (at most
#                         one hour after the red), and the first pass after it
#                         re-evaluates the PR, with no manual rerun.

IB_RATE_LIMIT_MARK="installation API budget exhausted"
# Both bucket wordings; the publisher's stop rule has matched exactly this
# since #2225.
IB_RATE_LIMIT_RE='rate limit (already )?exceeded for installation'

ib_read() {
  per_pr="${1:-}"
  reserve="${2:-}"
  gql_per_pr="${3:-}"
  gql_reserve="${4:-}"
  budget_known=0
  gql_known=0
  rl_remaining=""
  rl_reset=""
  gql_remaining=""
  gql_reset=""
  RATE_LIMIT_RESET_ISO=""
  spent="${spent:-0}"
  local rl_line
  if rl_line=$(gh api rate_limit \
      --jq '[.resources.core.remaining, .resources.core.reset, (.resources.graphql.remaining // "-"), (.resources.graphql.reset // "-")] | map(tostring) | join("\t")'); then
    IFS=$'\t' read -r rl_remaining rl_reset gql_remaining gql_reset <<<"$rl_line" || true
  fi
  case "$rl_remaining:$rl_reset:$per_pr:$reserve" in
    *[!0-9:]*|:*|*::*|*:)
      echo "::warning::Could not read the installation budget from GET /rate_limit (or a budget knob is malformed); evaluating as before (#2220)."
      ;;
    *)
      budget_known=1
      # The GraphQL bucket is budgeted only when it was readable and its knobs
      # are well-formed; otherwise the core check stands alone (fail toward
      # evaluating).
      case "$gql_remaining:$gql_reset:$gql_per_pr:$gql_reserve" in
        *[!0-9:]*|:*|*::*|*:) echo "::warning::GraphQL budget unreadable; budgeting the REST core bucket only (#2220)." ;;
        *) gql_known=1 ;;
      esac
      RATE_LIMIT_RESET_ISO=$(jq -nr --argjson r "$rl_reset" '$r | todateiso8601' 2>/dev/null || true)
      echo "Installation budget: $rl_remaining REST request(s) and ${gql_remaining} GraphQL point(s) remaining; the REST window resets at ${RATE_LIMIT_RESET_ISO:-epoch $rl_reset}."
      ;;
  esac
  return 0
}

ib_affordable() {
  [ "${budget_known:-0}" -eq 1 ] || return 0
  [ $(( rl_remaining - ${spent:-0} )) -ge $(( per_pr * $1 + reserve )) ] || return 1
  [ "${gql_known:-0}" -eq 1 ] || return 0
  [ "$gql_remaining" -ge $(( gql_per_pr * $1 + gql_reserve )) ]
}

ib_capacity() {
  local k g
  if [ "${budget_known:-0}" -ne 1 ] || [ "$per_pr" -eq 0 ]; then echo 1000000; return 0; fi
  k=$(( (rl_remaining - ${spent:-0} - reserve) / per_pr ))
  if [ "${gql_known:-0}" -eq 1 ] && [ "$gql_per_pr" -gt 0 ]; then
    g=$(( (gql_remaining - gql_reserve) / gql_per_pr ))
    [ "$g" -ge "$k" ] || k="$g"
  fi
  [ "$k" -ge 0 ] || k=0
  echo "$k"
}

ib_short_bucket_reset() {
  local r="$rl_reset" core_short=0 gql_short=0
  [ $(( rl_remaining - ${spent:-0} )) -ge $(( per_pr + reserve )) ] || core_short=1
  if [ "${gql_known:-0}" -eq 1 ] && [ "$gql_remaining" -lt $(( gql_per_pr + gql_reserve )) ]; then
    gql_short=1
  fi
  if [ "$gql_short" -eq 1 ] && { [ "$core_short" -eq 0 ] || [ "$gql_reset" -gt "$r" ]; }; then
    r="$gql_reset"
  fi
  jq -nr --argjson r "$r" '$r | todateiso8601' 2>/dev/null || true
}

ib_rate_limited() {
  grep -qiE "$IB_RATE_LIMIT_RE" <<<"${1:-}"
}

# The reset to stamp on a red after a call failed on the exhausted budget.
#
# GET /rate_limit is exempt from the limit, and its answer has read healthy
# while calls on the same token were being refused (a secondary-limit 403, and
# a PAT whose primary bucket was empty: the response headers of the refused
# call said remaining 0 while /rate_limit said 5000). So the authority is the
# X-RateLimit-* headers on a refused call. The call that failed ran inside a
# gate script, out of reach; this probe makes one more call on the same token
# against the same bucket, which an exhausted bucket refuses the same way. A
# refused request does not count against the limit, so at exhaustion the probe
# is free. The bucket comes from the error wording: GraphQL says "already
# exceeded", REST does not.
#
# Remaining 0 in the probe's headers gives the reset. Remaining above 0 means
# this bucket refills or was never the one that ran out; fall back to the
# exhausted bucket GET /rate_limit names (#2225), and print nothing when that
# is unreadable too (the caller's red then backs off for at most one hour).
ib_exhausted_reset() {
  local text="${1:-}" probe remaining reset fallback
  if grep -qiE 'already exceeded for installation' <<<"$text"; then
    probe=$(gh api -i graphql -f query='{rateLimit{remaining}}' 2>/dev/null || true)
  else
    probe=$(gh api -i "repos/${REPO:-}" 2>/dev/null || true)
  fi
  remaining=$(tr -d '\r' <<<"$probe" | awk 'tolower($1) == "x-ratelimit-remaining:" { print $2; exit }')
  reset=$(tr -d '\r' <<<"$probe" | awk 'tolower($1) == "x-ratelimit-reset:" { print $2; exit }')
  if [ "$remaining" = 0 ] && [[ "$reset" =~ ^[0-9]+$ ]]; then
    jq -nr --argjson r "$reset" '$r | todateiso8601' 2>/dev/null && return 0
  fi
  if fallback=$(gh api rate_limit --jq '[.resources.core, .resources.graphql] | map(select(. != null)) as $b | ($b | map(select(.remaining == 0))) as $out | (if ($out | length) > 0 then $out else $b end) | map(.reset) | max | todateiso8601' 2>/dev/null) \
      && [ -n "$fallback" ]; then
    printf '%s\n' "$fallback"
  fi
  return 0
}

ib_backoff_title() {
  local title="$1 — $IB_RATE_LIMIT_MARK (rc=$2)"
  if [ -n "${3:-}" ]; then
    title="$title; re-evaluated after $3"
  fi
  printf '%s\n' "$title"
}
