#!/usr/bin/env bash
# scripts/gh-as-author.sh
#
# Run a `gh` command under a verified AUTHOR token without mutating the
# machine-global gh account selection. The wrapper keeps the historical
# public API while selecting attribution per command through GH_TOKEN.
#
# Usage:
#   scripts/gh-as-author.sh -- gh pr create --title ...
#   scripts/gh-as-author.sh -- gh pr merge 123 --squash --delete-branch
#   scripts/gh-as-author.sh -- gh pr edit 123 --add-label foo
#
# Environment:
#   GH_AS_AUTHOR_IDENTITY   author login to verify.
#                           Default: nathanjohnpayne
#   OP_PREFLIGHT_AUTHOR_PAT preferred cached author token.
#
# Exit codes:
#   0    success
#   1    setup or invocation error
#   2    token verification failed
#   3    token lookup failed
#   5    post-create author verification failed or could not complete
#   *    propagated from the wrapped command otherwise
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/gh-token-resolver.sh
. "$ROOT/scripts/lib/gh-token-resolver.sh"

AUTHOR="${GH_AS_AUTHOR_IDENTITY:-nathanjohnpayne}"

[ "${1:-}" = "--" ] && shift

if [ "$#" -eq 0 ]; then
  echo "gh-as-author: no wrapped command given." >&2
  echo "gh-as-author: usage: scripts/gh-as-author.sh -- gh pr <create|merge|edit> ..." >&2
  exit 1
fi

set +e
gh_resolve_token_for_identity "$AUTHOR" "OP_PREFLIGHT_AUTHOR_PAT" "gh-as-author"
RESOLVE_RC=$?
set -e
if [ "$RESOLVE_RC" -ne 0 ]; then
  exit "$RESOLVE_RC"
fi
TOKEN="$GH_RESOLVED_TOKEN"

IS_PR_CREATE=0
if [ "${1:-}" = "gh" ] && [ "${2:-}" = "pr" ] && [ "${3:-}" = "create" ]; then
  IS_PR_CREATE=1
fi

run_with_author_token() {
  unset GITHUB_TOKEN
  GH_TOKEN="$TOKEN" "$@"
}

if [ "$IS_PR_CREATE" -eq 1 ]; then
  TMP_OUT=$(mktemp)
  trap 'rm -f "$TMP_OUT"' EXIT
  set +e
  run_with_author_token "$@" | tee "$TMP_OUT"
  WRAPPED_RC=${PIPESTATUS[0]}
  set -e
  if [ "$WRAPPED_RC" -ne 0 ]; then
    exit "$WRAPPED_RC"
  fi

  PR_URL=$(grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' "$TMP_OUT" | tail -1 || true)
  if [ -z "$PR_URL" ]; then
    echo "gh-as-author: ERROR could not extract PR URL from gh pr create output; refusing to treat the create as verified." >&2
    echo "gh-as-author: The PR may still have been created — check 'gh pr list --author $AUTHOR' and verify manually." >&2
    exit 5
  fi
  PR_NUM=$(basename "$PR_URL")
  PR_REPO=$(echo "$PR_URL" | sed -E 's|https://github\.com/([^/]+/[^/]+)/pull/[0-9]+|\1|')

  ACTUAL_AUTHOR=$(
    unset GITHUB_TOKEN
    GH_TOKEN="$TOKEN" gh pr view "$PR_NUM" --repo "$PR_REPO" --json author --jq .author.login 2>/dev/null || echo ""
  )
  if [ -z "$ACTUAL_AUTHOR" ]; then
    echo "gh-as-author: ERROR could not read PR author from gh pr view $PR_NUM --repo $PR_REPO; refusing to treat the create as verified." >&2
    echo "gh-as-author: Verify manually: GH_TOKEN=<author-token> gh pr view $PR_NUM --repo $PR_REPO --json author" >&2
    exit 5
  fi

  if [ "$ACTUAL_AUTHOR" != "$AUTHOR" ]; then
    echo "gh-as-author: ERROR PR #$PR_NUM on $PR_REPO landed under '$ACTUAL_AUTHOR', expected '$AUTHOR'." >&2
    echo "gh-as-author: This is the #241 mis-attribution class — the effective token did not match the intended author." >&2
    echo "gh-as-author: Recovery: close the PR and recreate from the same branch with a verified author token." >&2
    echo "gh-as-author:   scripts/gh-as-author.sh -- gh pr create --repo $PR_REPO --title '...' --body '...'" >&2
    echo "gh-as-author: See REVIEW_POLICY.md § Recovery: PR created under the wrong identity." >&2
    exit 5
  fi

  echo "gh-as-author: verified PR #$PR_NUM author=$ACTUAL_AUTHOR (matches expected $AUTHOR)" >&2
  exit 0
fi

set +e
run_with_author_token "$@"
WRAPPED_RC=$?
set -e
exit "$WRAPPED_RC"
