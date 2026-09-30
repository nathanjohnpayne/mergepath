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
#
# Exit codes:
#   0    success (and, for pr comment / issue comment / pr review / pr edit /
#        pr merge, the written object read back under the reviewer login)
#   1    setup or invocation error
#   2    token verification failed
#   3    token lookup failed
#   5    byline readback failed or could not complete (#1057)
#   *    propagated from the wrapped command otherwise
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/gh-token-resolver.sh
. "$ROOT/scripts/lib/gh-token-resolver.sh"
# shellcheck source=lib/gh-write-readback.sh
. "$ROOT/scripts/lib/gh-write-readback.sh"

REVIEWER="$(gh_default_reviewer_identity)"

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

# Byline readback (#1057 A2 layer 3): the token was verified before the write;
# after it, re-read the object the write produced and check GitHub attributes
# it to $REVIEWER. A verb that needs a readback but cannot be prepared refuses
# to write rather than write unverified.
if ! gh_readback_prepare "$REVIEWER" "$TOKEN" "gh-as-reviewer" -- "$@"; then
  exit 5
fi

if [ "$GH_READBACK_KIND" = "none" ]; then
  set +e
  (
    unset GITHUB_TOKEN
    GH_TOKEN="$TOKEN" "$@"
  )
  WRAPPED_RC=$?
  set -e
  exit "$WRAPPED_RC"
fi

TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/gh-as-reviewer-out.XXXXXX")
trap 'rm -f "$TMP_OUT"' EXIT
set +e
(
  unset GITHUB_TOKEN
  GH_TOKEN="$TOKEN" "$@"
) | tee "$TMP_OUT"
WRAPPED_RC=${PIPESTATUS[0]}
set -e
if [ "$WRAPPED_RC" -ne 0 ]; then
  exit "$WRAPPED_RC"
fi
set +e
gh_readback_verify "$TMP_OUT"
VERIFY_RC=$?
set -e
exit "$VERIFY_RC"
