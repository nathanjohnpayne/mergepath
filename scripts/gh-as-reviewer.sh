#!/usr/bin/env bash
# scripts/gh-as-reviewer.sh
#
# Run a `gh` command under a verified REVIEWER token without mutating
# the machine-global gh active account.
#
# Usage:
#   GH_AS_REVIEWER_IDENTITY=nathanpayne-codex \
#     scripts/gh-as-reviewer.sh -- gh pr review 123 --comment --body "..."
#
# Environment:
#   GH_AS_REVIEWER_IDENTITY   reviewer login to verify.
#   MERGEPATH_AGENT           fallback agent name; resolves to
#                             nathanpayne-$MERGEPATH_AGENT.
#   OP_PREFLIGHT_REVIEWER_PAT preferred cached reviewer token.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/gh-token-resolver.sh
. "$ROOT/scripts/lib/gh-token-resolver.sh"

if [ -n "${GH_AS_REVIEWER_IDENTITY:-}" ]; then
  REVIEWER="$GH_AS_REVIEWER_IDENTITY"
elif [ -n "${MERGEPATH_AGENT:-}" ]; then
  REVIEWER="nathanpayne-$MERGEPATH_AGENT"
else
  REVIEWER="nathanpayne-claude"
fi

[ "${1:-}" = "--" ] && shift

if [ "$#" -eq 0 ]; then
  echo "gh-as-reviewer: no wrapped command given." >&2
  echo "gh-as-reviewer: usage: scripts/gh-as-reviewer.sh -- gh pr review ..." >&2
  exit 1
fi

set +e
gh_resolve_token_for_identity "$REVIEWER" "OP_PREFLIGHT_REVIEWER_PAT" "gh-as-reviewer"
RESOLVE_RC=$?
set -e
if [ "$RESOLVE_RC" -ne 0 ]; then
  exit "$RESOLVE_RC"
fi

TOKEN="$GH_RESOLVED_TOKEN"
set +e
(
  unset GITHUB_TOKEN
  GH_TOKEN="$TOKEN" "$@"
)
WRAPPED_RC=$?
set -e
exit "$WRAPPED_RC"
