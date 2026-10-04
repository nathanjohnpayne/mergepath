#!/usr/bin/env bash
# scripts/lib/graphql-ceiling.sh — recognise the cloud GraphQL ceiling and
# refuse with a message that says what it is (#1057 item A3).
#
# In an Anthropic-hosted Claude Code cloud session every GitHub request goes
# through a proxy that limits GraphQL. A request it does not serve is answered
# with a 403 whose message is one of
#
#   This GraphQL query is not enabled for this session
#   GitHub GraphQL is not available from Claude Code sessions; use the REST API ...
#
# (the first while the proxy served a pinned set of operations, the second
# since it serves none, observed 2026-10-04), and the proxy applies it whatever
# credential the request carries. Because the wording has already changed
# once, the refusal is also recognized by where it comes from: the proxy's
# refusals carry a `documentation_url` on docs.anthropic.com, which GitHub's
# own errors never do (theirs point at docs.github.com). graphql_ceiling_hit
# is the one place a caller should match any of this. So a
# helper that hits it has not met a credential gap, a transient error, or a
# bug: it has met a property of the session, and retrying, re-authenticating
# or provisioning a better token cannot change the answer. Before this lib the
# helpers reported it as an ordinary "GraphQL query failed" and exited with
# their generic failure code, which read as something to retry.
#
# GraphQL-only surface. These helpers need GraphQL operations GitHub exposes
# nowhere in REST, so they have no REST fallback to switch to:
#
#   scripts/resolve-pr-threads.sh   reviewThreads (read), resolveReviewThread
#                                   and addPullRequestReviewThreadReply
#                                   (mutations): thread resolution exists only
#                                   in GraphQL
#
# Whether a given operation is served is not documented, so helpers do not
# refuse in advance: they attempt the operation and classify the failure. scripts/agent-capability-probe.sh reports whether a basic
# GraphQL query is served at all (the `graphql` capability).
#
# Source this file, then:
#
#   graphql_ceiling_hit <text>
#     Exit 0 iff <text> (a captured gh stderr/stdout or response body) carries
#     one of the proxy's refusal wordings.
#
#   graphql_ceiling_refuse <helper> <what the helper was doing>
#     Prints the tier-aware explanation to stderr and exits
#     GRAPHQL_CEILING_EXIT (6). Call it only after graphql_ceiling_hit.
#
#   graphql_ceiling_install_trap
#     Call once from the helper's MAIN shell. A GraphQL call made inside a
#     command substitution runs in a subshell, where `exit 6` ends only that
#     subshell and the caller sees an ordinary failure. After this, a refusal
#     raised in any subshell also signals the main shell (USR1), which exits 6
#     as soon as the command it is waiting on returns. BASH_SUBSHELL (bash 3.0+)
#     tells the two apart, so the lib stays Bash 3.2 portable.
#
# Bash 3.2 portable; no top-level side effects.

GRAPHQL_CEILING_EXIT=6
# The pinned-set wording. Kept under its original name for callers that read it.
GRAPHQL_CEILING_PHRASE="not enabled for this session"
# The no-GraphQL wording. Matched on its distinctive clause, not the REST
# routes it goes on to suggest, which the proxy may reword independently.
GRAPHQL_CEILING_PHRASE_UNAVAILABLE="GraphQL is not available from Claude Code sessions"
# Provenance, for wordings not seen yet: the proxy's refusal bodies point at
# Anthropic's documentation. Callers pass only text from a failed GraphQL
# request, so a refusal from the proxy there is the ceiling.
# An ERE, not a literal: a pretty-printed body spaces the colon.
GRAPHQL_CEILING_PROXY_DOCS='"documentation_url"[[:space:]]*:[[:space:]]*"https://docs[.]anthropic[.]com/'

graphql_ceiling_hit() {
  case "${1:-}" in
    *"$GRAPHQL_CEILING_PHRASE"*|*"$GRAPHQL_CEILING_PHRASE_UNAVAILABLE"*) return 0 ;;
  esac
  # Unquoted on purpose: a quoted right-hand side is a literal in Bash 3.2+.
  [[ "${1:-}" =~ $GRAPHQL_CEILING_PROXY_DOCS ]] && return 0
  return 1
}

graphql_ceiling_refuse() {
  local helper="${1:-helper}" what="${2:-a GitHub GraphQL operation}"
  {
    echo "$helper: CEILING — $what needs a GitHub GraphQL operation this session's proxy does not serve (it answered 403: GraphQL is not enabled or not available for this session)."
    echo "$helper:   This is a property of the session (the Claude cloud GraphQL ceiling, mergepath#1057), not a credential gap: retrying or provisioning another token returns the same 403."
    echo "$helper:   Hand this step to a session that can reach GraphQL, with the state established here:"
    echo "$helper:     park it on the PR:   scripts/post-local-agent-handback.sh <PR#> --blocked graphql --next \"<command>\""
    echo "$helper:     thread resolution:   scripts/dispatch-thread-resolution-lane.sh <PR#>   (runs --resolve-actioned in CI and waits; reply on each thread first)"
  } >&2
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ] && [ -n "${GRAPHQL_CEILING_MAIN_PID:-}" ]; then
    kill -USR1 "$GRAPHQL_CEILING_MAIN_PID" 2>/dev/null || true
  fi
  exit "$GRAPHQL_CEILING_EXIT"
}

graphql_ceiling_install_trap() {
  GRAPHQL_CEILING_MAIN_PID=$$
  # shellcheck disable=SC2064  # expand GRAPHQL_CEILING_EXIT now, deliberately
  trap "exit $GRAPHQL_CEILING_EXIT" USR1
}
