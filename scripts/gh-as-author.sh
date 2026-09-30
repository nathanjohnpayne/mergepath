#!/usr/bin/env bash
# scripts/gh-as-author.sh
#
# Run a `gh` command under a verified AUTHOR token without mutating the
# machine-global gh account selection. The wrapper keeps the historical
# public API while selecting attribution per command through GH_TOKEN.
#
# Usage:
#   scripts/gh-as-author.sh -- gh pr create --title ... --body-file pr-body.md
#   scripts/gh-as-author.sh -- gh pr merge 123 --squash --delete-branch
#   scripts/gh-as-author.sh -- gh pr edit 123 --add-label foo
#   GH_AS_AUTHOR_PUSH_REPO=owner/repo scripts/gh-as-author.sh -- git -C <dir> push -u origin HEAD
#
# The payload must be gh itself, or exactly `git -C <dir> push -u origin HEAD`
# (bootstrap's initial push). A prefix such as env, sudo or command is
# refused: it could replace the verified token after the check. The git form
# requires a primary repository whose .git/config holds only the fixed,
# value-checked bootstrap allowlist, with remote.origin.url exactly
# https://github.com/$GH_AS_AUTHOR_PUSH_REPO.git (or its git@github.com:
# spelling, pushed over HTTPS). It runs with global and system config,
# ~/.netrc, injected config and hooks out of reach and gh's credential helper
# (the verified token) alone (#1541).
#
# Environment:
#   GH_AS_AUTHOR_IDENTITY   author login to verify.
#                           Default: nathanjohnpayne
#   OP_PREFLIGHT_AUTHOR_PAT preferred cached author token.
#   GH_AS_AUTHOR_PUSH_REPO  owner/repo the git form must push to (required
#                           for it; from the caller's trusted input).
#   GH_AS_AUTHOR_TRACE_MARKER  optional path, created after every check
#                           passed and immediately before the gh write runs
#                           (never inherited by it); gh payloads only.
#
# Exit codes:
#   0    success
#   1    setup or invocation error
#   2    token verification failed
#   3    token lookup failed
#   5    post-create author verification failed or could not complete, or
#        the git push destination or repo config was refused
#   70   GH_AS_AUTHOR_TRACE_MARKER could not be written; nothing ran
#   *    propagated from the wrapped command otherwise
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/gh-token-resolver.sh
. "$ROOT/scripts/lib/gh-token-resolver.sh"
# shellcheck source=lib/pr-body-contract.sh
. "$ROOT/scripts/lib/pr-body-contract.sh"
# shellcheck source=lib/gh-command-classifier.sh
. "$ROOT/scripts/lib/gh-command-classifier.sh"

AUTHOR="${GH_AS_AUTHOR_IDENTITY:-nathanjohnpayne}"

# Runtime byline pin (#438): this check runs IN the wrapper process,
# whose environment is the actual one the write will use — unlike the
# PreToolUse hook's static command-line analysis, it cannot be evaded
# by shell environment manipulation (env -u/-i, unset, export forms,
# eval'd assignments). If the repo declares author_identity in
# review-policy.yml, the resolved AUTHOR must match it; otherwise the
# write would land under the wrong byline no matter which token
# verifies.
# Resolve the policy from the wrapper's own repo root, not the
# caller's cwd — a subdirectory invocation must still load the pin
# (Codex P2 on PR #442 r20). $ROOT is computed from BASH_SOURCE at
# the top of this script; in consumers the wrapper is synced into the
# repo it writes to, so script root == target repo root.
WRAPPER_POLICY_AUTHOR=""
if [ -f "$ROOT/.github/review-policy.yml" ]; then
  WRAPPER_POLICY_AUTHOR=$(grep -m1 '^author_identity:' "$ROOT/.github/review-policy.yml" | awk '{print $2}' | sed -E "s/^[\"']//; s/[\"']\$//" || true)
fi
if [ -n "$WRAPPER_POLICY_AUTHOR" ] && [ "$AUTHOR" != "$WRAPPER_POLICY_AUTHOR" ]; then
  echo "gh-as-author: refusing to run as '$AUTHOR' — this repo's review-policy.yml declares author_identity: $WRAPPER_POLICY_AUTHOR (#438 runtime byline pin)." >&2
  echo "gh-as-author: unset GH_AS_AUTHOR_IDENTITY (or set it to $WRAPPER_POLICY_AUTHOR)." >&2
  exit 2
fi

[ "${1:-}" = "--" ] && shift

if [ "$#" -eq 0 ]; then
  echo "gh-as-author: no wrapped command given." >&2
  echo "gh-as-author: usage: scripts/gh-as-author.sh -- gh pr <create|merge|edit> ..." >&2
  exit 1
fi
# gh, or bootstrap's closed `git push` form (gh_author_payload_kind); any
# prefix that could replace the verified token is refused (#1541).
AUTHOR_PAYLOAD_KIND="$(gh_author_payload_kind "$@")" || exit 1
# GH_AS_AUTHOR_TRACE_MARKER: a path the wrapper creates after every check
# passed, immediately before the gh write runs, so a caller can tell "gh ran"
# from "the wrapper refused first" (bootstrap::author_gh_traced). It means the
# gh write ran, so it is not accepted with the git form.
TRACE_MARKER="${GH_AS_AUTHOR_TRACE_MARKER:-}"
unset GH_AS_AUTHOR_TRACE_MARKER
if [ -n "$TRACE_MARKER" ] && [ "$AUTHOR_PAYLOAD_KIND" != "gh" ]; then
  echo "gh-as-author: GH_AS_AUTHOR_TRACE_MARKER applies to gh writes only." >&2
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

if [ "$AUTHOR_PAYLOAD_KIND" = "git-push" ]; then
  shift
  set +e
  # GH_AS_AUTHOR_PUSH_REPO: the owner/repo bootstrap created, from its own
  # input; the repository's remote must be exactly that (#1541).
  gh_author_git_push "$TOKEN" "${GH_AS_AUTHOR_PUSH_REPO:-}" "$@"
  WRAPPED_RC=$?
  set -e
  exit "$WRAPPED_RC"
fi

is_pr_create_command() {
  gh_is_pr_create_command "$@"
}

IS_PR_CREATE=0
PR_CREATE_VERB_INDEX=-1
if is_pr_create_command "$@"; then
  IS_PR_CREATE=1
  PR_CREATE_VERB_INDEX=$GH_PR_CREATE_VERB_INDEX
fi

if [ "$IS_PR_CREATE" -eq 1 ]; then
  PR_BODY=""
  NORMALIZED_COMMAND=()
  COMMAND_INDEX=0

  read_pr_body_file() {
    local body_file="$1"
    local spelling="$2"
    if [ "$body_file" = "-" ]; then
      echo "gh-as-author: $spelling is unsupported because the body must be validated before the write; use /dev/stdin when stdin is intentional." >&2
      exit 1
    fi
    if [ ! -r "$body_file" ]; then
      echo "gh-as-author: PR body file is not readable: $body_file" >&2
      exit 1
    fi
    PR_BODY="$(cat "$body_file")"
  }

  while [ "$#" -gt 0 ]; do
    argument="$1"
    shift
    if [ "$COMMAND_INDEX" -le "$PR_CREATE_VERB_INDEX" ]; then
      NORMALIZED_COMMAND+=("$argument")
      COMMAND_INDEX=$((COMMAND_INDEX + 1))
      continue
    fi
    COMMAND_INDEX=$((COMMAND_INDEX + 1))
    case "$argument" in
      -e|--editor|-w|--web)
        echo "gh-as-author: interactive PR creation mode '$argument' is unsupported because it can mutate the body after validation." >&2
        exit 1
        ;;
      --body|-b)
        if [ "$#" -eq 0 ]; then
          echo "gh-as-author: PR creation flag is missing its body value." >&2
          exit 1
        fi
        PR_BODY="$1"
        shift
        ;;
      --body-file|-F)
        if [ "$#" -eq 0 ]; then
          echo "gh-as-author: PR creation flag is missing its body-file value." >&2
          exit 1
        fi
        read_pr_body_file "$1" "$argument -"
        shift
        ;;
      --body=*) PR_BODY="${argument#--body=}" ;;
      -b?*)
        PR_BODY="${argument#-b}"
        PR_BODY="${PR_BODY#=}"
        ;;
      --body-file=*)
        body_file="${argument#--body-file=}"
        read_pr_body_file "$body_file" "--body-file=-"
        ;;
      -F?*)
        body_file="${argument#-F}"
        body_file="${body_file#=}"
        read_pr_body_file "$body_file" "-F-"
        ;;
      -R|--repo|--hostname|-a|--assignee|-B|--base|-H|--head|-l|--label|-m|--milestone|-p|--project|--recover|-r|--reviewer|-T|--template|-t|--title)
        if [ "$#" -eq 0 ]; then
          echo "gh-as-author: PR creation flag '$argument' is missing its value." >&2
          exit 1
        fi
        NORMALIZED_COMMAND+=("$argument" "$1")
        shift
        ;;
      # ATTACHED value for another value-taking short option. `-tbug` is
      # `-t bug`, not a clustered `-b`; the catch-all below would otherwise
      # reject valid creates whose title/label/head merely contains b or F.
      # Letters are gh's value-taking pr-create shorthands EXCEPT -b/-F, which
      # are body flags handled above.
      -[TtalpmBHr]?*)
        NORMALIZED_COMMAND+=("$argument")
        ;;
      -[^-]*[bF][^-]*)
        echo "gh-as-author: ambiguous clustered short option '$argument' contains a PR body flag; pass -b or -F separately." >&2
        exit 1
        ;;
      *) NORMALIZED_COMMAND+=("$argument") ;;
    esac
  done

  if ! pr_body_validate "$PR_BODY" "$ROOT/.github/review-policy.yml"; then
    echo "gh-as-author: refusing to create a PR that Phase 4b cannot attribute." >&2
    exit 1
  fi

  # The validated snapshot is the only body value passed to gh. This prevents
  # stdin or a mutable body file from changing between validation and creation.
  NORMALIZED_COMMAND+=(--body "$PR_BODY")
  set -- "${NORMALIZED_COMMAND[@]}"
fi

# The verified token goes to github.com only. Any other host gets the resolver's
# non-credential sentinel in place of an Enterprise token or stored login, so
# it can neither carry the write nor receive the PAT (see gh-token-resolver.sh).
run_with_author_token() {
  unset GITHUB_TOKEN
  if [ -n "$TRACE_MARKER" ] && ! : >"$TRACE_MARKER"; then
    echo "gh-as-author: cannot write the trace marker $TRACE_MARKER; refusing to run the write unrecorded." >&2
    exit 70
  fi
  GH_TOKEN="$TOKEN" GH_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
    GITHUB_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" "$@"
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
    GH_TOKEN="$TOKEN" GH_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
      GITHUB_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" gh pr view "$PR_NUM" --repo "$PR_REPO" --json author --jq .author.login 2>/dev/null || echo ""
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
