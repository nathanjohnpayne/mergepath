#!/usr/bin/env bash
# scripts/gh-as-reviewer.sh
#
# Run a `gh` command under a verified REVIEWER token without mutating
# machine-global gh account selection.
#
# Usage:
#   GH_AS_REVIEWER_IDENTITY=nathanpayne-codex \
#     scripts/gh-as-reviewer.sh -- gh pr review 123 --comment --body "..."
#
# Environment:
#   GH_AS_REVIEWER_IDENTITY   reviewer login to verify.
#   MERGEPATH_AGENT           fallback agent name; resolves to
#                             nathanpayne-$MERGEPATH_AGENT.
#   OP_PREFLIGHT_AGENT        fallback agent from op-preflight cache when
#                             MERGEPATH_AGENT is unset.
#   OP_PREFLIGHT_REVIEWER_PAT preferred cached reviewer token.
#   MERGEPATH_GH_TRANSPORT    gh | rest | auto (default auto). Locally the
#                             wrapped gh command runs as given. On a cloud
#                             surface the `gh pr` / `gh issue` subcommands
#                             are GraphQL and the proxy refuses them, so the
#                             wrapper runs the same write as REST calls under
#                             the verified token and reads its byline back
#                             (scripts/lib/gh-rest-transport.sh, #1057 A).
#
# Exit codes: 0 success; 1 setup, invocation or refused argv; 2 token
# verification failed; 3 token lookup failed; 5 (REST transport) a write's
# byline could not be read back as the reviewer; otherwise the wrapped
# command's status.
#
# Bash 3.2 portable.

set -euo pipefail

SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[ "$SOURCE_DIR" != "${BASH_SOURCE[0]}" ] || SOURCE_DIR=.
ROOT="$(cd "$SOURCE_DIR/.." && pwd -P)"
# shellcheck source=lib/gh-token-resolver.sh
. "$ROOT/scripts/lib/gh-token-resolver.sh"
gh_wrapper_validate_path || exit 5
# shellcheck source=lib/gh-rest-transport.sh
. "$ROOT/scripts/lib/gh-rest-transport.sh"

REVIEWER="$(gh_default_reviewer_identity)"

[ "${1:-}" = "--" ] && shift

if [ "$#" -eq 0 ]; then
  echo "gh-as-reviewer: no wrapped command given." >&2
  echo "gh-as-reviewer: usage: scripts/gh-as-reviewer.sh -- gh pr review ..." >&2
  exit 1
fi
gh_require_direct_gh_payload "gh-as-reviewer" "$@" || exit 1
# Arguments that would send the verified token elsewhere or replace it
# (--hostname, a host-qualified --repo, an Authorization header on gh api)
# are refused before any token is looked up (#1542).
gh_payload_refuse_credential_overrides gh-as-reviewer "$@" || exit 1
# shellcheck source=lib/gh-comment-trigger-guard.sh
. "$ROOT/scripts/lib/gh-comment-trigger-guard.sh"
# shellcheck disable=SC2034 # consumed by the sourced comment guard
GH_COMMENT_GUARD_ROLE=reviewer
trap 'gh_comment_guard_cleanup' EXIT
gh_comment_guard_prepare "$@" || exit 1
set -- "${GH_COMMENT_GUARD_ARGS[@]}"

set +e
gh_resolve_token_for_identity "$REVIEWER" "OP_PREFLIGHT_REVIEWER_PAT" "gh-as-reviewer"
RESOLVE_RC=$?
set -e
if [ "$RESOLVE_RC" -ne 0 ]; then
  exit "$RESOLVE_RC"
fi

TOKEN="$GH_RESOLVED_TOKEN"

# Transport. On a cloud surface every `gh pr` / `gh issue` subcommand is a
# GraphQL call the proxy refuses, so the write runs as REST calls under the
# verified token and its byline is read back there (#1057 item A). Locally
# the wrapped command runs through gh, as before. See
# scripts/lib/gh-rest-transport.sh.
TRANSPORT="$(gh_transport_select)" || exit 1
gh_comment_guard_check_transport "$TRANSPORT" || exit 1
if [ "$TRANSPORT" = "rest" ]; then
  trap 'gh_comment_guard_cleanup; gh_rest_cleanup' EXIT
  set +e
  gh_rest_run gh-as-reviewer "$REVIEWER" "$TOKEN" "$@"
  WRAPPED_RC=$?
  set -e
  exit "$WRAPPED_RC"
fi

set +e
# The verified token goes to github.com only. Any other host gets the resolver's
# non-credential sentinel in place of an Enterprise token or stored login, so
# it can neither carry the write nor receive the PAT (see gh-token-resolver.sh).
(
  unset GITHUB_TOKEN
  # GH_HOST is pinned to github.com, where the token was verified: with it
  # unset, gh targets the only host in its hosts file (Phase 4b on #2178).
  GH_HOST=github.com GH_TOKEN="$TOKEN" GH_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
    GITHUB_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" "$@"
)
WRAPPED_RC=$?
set -e
exit "$WRAPPED_RC"
