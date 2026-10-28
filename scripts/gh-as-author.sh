#!/usr/bin/env bash
# scripts/gh-as-author.sh
#
# Run a `gh` command under a verified AUTHOR token without mutating the
# machine-global gh account selection. The wrapper keeps the historical
# public API while selecting attribution per command through GH_TOKEN.
#
# Usage:
#   scripts/gh-as-author.sh -- gh pr create --title ... --body-file pr-body.md
#   scripts/gh-as-author.sh -- gh pr merge 123 --squash --delete-branch --match-head-commit <full-current-head-sha>
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
# Transport: locally the wrapped gh command runs as given. On a cloud
# surface (MERGEPATH_AGENT_SURFACE claude-cloud / codex-cloud, or
# CLAUDE_CODE_REMOTE=true) every `gh pr` / `gh issue` subcommand is a GraphQL
# call the proxy refuses, so the wrapper runs the same write as REST calls
# under the verified token and reads its byline back, in one canonical argv
# form per verb; `gh pr merge` is refused there because the merge gates read
# GraphQL. MERGEPATH_GH_TRANSPORT=gh|rest|auto overrides the choice. See
# scripts/lib/gh-rest-transport.sh (#1057 item A).
#
# Environment:
#   GH_AS_AUTHOR_IDENTITY   author login to verify.
#                           Default: nathanjohnpayne
#   OP_PREFLIGHT_AUTHOR_PAT preferred cached author token.
#   MERGEPATH_GH_TRANSPORT  gh | rest | auto (default auto; see above).
#   GH_AS_AUTHOR_PUSH_REPO  owner/repo the git form must push to (required
#                           for it; from the caller's trusted input).
#   GH_AS_AUTHOR_TRACE_MARKER  optional path, created after every check
#                           passed and immediately before the gh write runs
#                           (never inherited by it); gh payloads only.
#   GH_AS_AUTHOR_ALLOW_DUPLICATE_LINK  comma-separated pull request numbers
#                           that may already link an issue this `gh pr create`
#                           body links (a deliberate split or stacked PR);
#                           any other open PR linking it refuses the create
#                           (#2562).
#
# Exit codes:
#   0    success
#   1    setup or invocation error
#   2    token verification failed
#   3    token lookup failed
#   5    post-create author verification failed or could not complete, or
#        the git push destination or repo config was refused, or (REST
#        transport) a write's byline could not be read back as the author
#   6    REST transport: `gh pr merge` is not run on a cloud surface
#   7    another open pull request already links an issue this PR body links
#        and GH_AS_AUTHOR_ALLOW_DUPLICATE_LINK does not name it (#2562)
#   70   GH_AS_AUTHOR_TRACE_MARKER could not be written; nothing ran
#   *    propagated from the wrapped command otherwise
#
# Bash 3.2 portable.

set -euo pipefail

SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[ "$SOURCE_DIR" != "${BASH_SOURCE[0]}" ] || SOURCE_DIR=.
ROOT="$(cd "$SOURCE_DIR/.." && pwd -P)"
# shellcheck source=lib/gh-token-resolver.sh
. "$ROOT/scripts/lib/gh-token-resolver.sh"
gh_wrapper_validate_path || exit 5
# shellcheck source=lib/pr-body-contract.sh
. "$ROOT/scripts/lib/pr-body-contract.sh"
# shellcheck source=lib/gh-command-classifier.sh
. "$ROOT/scripts/lib/gh-command-classifier.sh"
# shellcheck source=lib/gh-rest-transport.sh
. "$ROOT/scripts/lib/gh-rest-transport.sh"

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
# Arguments that would send the verified token elsewhere or replace it
# (--hostname, a host-qualified --repo, an Authorization header on gh api)
# are refused before any token is looked up (#1542).
if [ "$AUTHOR_PAYLOAD_KIND" = "gh" ]; then
  gh_payload_refuse_credential_overrides gh-as-author "$@" || exit 1
fi

# shellcheck source=lib/gh-comment-trigger-guard.sh
. "$ROOT/scripts/lib/gh-comment-trigger-guard.sh"
if [ "$AUTHOR_PAYLOAD_KIND" = gh ]; then
  # shellcheck disable=SC2034 # consumed by the sourced comment guard
  GH_COMMENT_GUARD_ROLE=author
  trap 'gh_comment_guard_cleanup' EXIT
  gh_comment_guard_prepare "$@" || exit 1
  set -- "${GH_COMMENT_GUARD_ARGS[@]}"
fi

set +e
gh_resolve_token_for_identity "$AUTHOR" "OP_PREFLIGHT_AUTHOR_PAT" "gh-as-author"
RESOLVE_RC=$?
set -e
if [ "$RESOLVE_RC" -ne 0 ]; then
  exit "$RESOLVE_RC"
fi
TOKEN="$GH_RESOLVED_TOKEN"
if [ "$AUTHOR_PAYLOAD_KIND" = gh ]; then
  gh_comment_guard_authorize || exit 1
fi

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
    # Byte-exact: command substitution would strip trailing newlines, and
    # the body sent must be the file's, as gh --body-file sends it.
    PR_BODY="$(cat "$body_file"; printf x)"
    PR_BODY="${PR_BODY%x}"
  }

  PR_CREATE_REPO=""
  PRE_VERB_REPO_PENDING=0
  while [ "$#" -gt 0 ]; do
    argument="$1"
    shift
    if [ "$COMMAND_INDEX" -le "$PR_CREATE_VERB_INDEX" ]; then
      # gh accepts the repository flag before the verb too (`gh --repo o/r pr
      # create`); the duplicate-link check must see it wherever it sits.
      if [ "$PRE_VERB_REPO_PENDING" -eq 1 ]; then
        PR_CREATE_REPO="$argument"
        PRE_VERB_REPO_PENDING=0
      else
        case "$argument" in
          -R|--repo) PRE_VERB_REPO_PENDING=1 ;;
          --repo=*) PR_CREATE_REPO="${argument#--repo=}" ;;
          -R?*) PR_CREATE_REPO="${argument#-R}"; PR_CREATE_REPO="${PR_CREATE_REPO#=}" ;;
        esac
      fi
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
        case "$argument" in -R|--repo) PR_CREATE_REPO="$1" ;; esac
        NORMALIZED_COMMAND+=("$argument" "$1")
        shift
        ;;
      --repo=*)
        PR_CREATE_REPO="${argument#--repo=}"
        NORMALIZED_COMMAND+=("$argument")
        ;;
      -R?*)
        PR_CREATE_REPO="${argument#-R}"
        PR_CREATE_REPO="${PR_CREATE_REPO#=}"
        NORMALIZED_COMMAND+=("$argument")
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

  # A pull request that links an issue another open pull request already
  # links is almost always a second implementation of the same ticket: two
  # sessions did that on mergepath#2534 and only a merge conflict told them
  # (#2562). Refuse it before the write, naming the other pull request, unless
  # GH_AS_AUTHOR_ALLOW_DUPLICATE_LINK names that number (a deliberate split
  # or a stacked PR). Links are the shared rule's own-line keyword forms, in
  # this repository only: `Closes OWNER/REPO#N` links an issue elsewhere and
  # is not checked. An open-PR list that cannot be read refuses, never passes.
  pr_body_issue_links() {
    printf '%s\n' "$1" \
      | grep -iE '^[[:space:]]*(closes?|closed|fix(es|ed)?|resolves?|resolved|refs?)[[:space:]]+#[0-9]+[[:space:]]*\.?[[:space:]]*$' \
      | sed -E 's/^.*#([0-9]+)[^0-9]*$/\1/' | sort -u || true
  }
  # pr_create_duplicate_links <body> <repo-or-empty>: prints one
  # "#<other> links #<n>" line per open pull request that links an issue the
  # body links; prints nothing when none does; returns 2 when the list is
  # unreadable. The read uses the verified author token through one fully
  # paginated REST path: the repository the command names, or, when it names
  # none, the one `gh repo view` resolves for the checkout (the cloud surface
  # requires the flag, so it never reaches the resolution). A capped list such
  # as `gh pr list --limit N` would hide every pull request past the cap.
  pr_create_duplicate_links() {
    local links open n repo
    links="$(pr_body_issue_links "$1")"
    [ -n "$links" ] || return 0
    repo="$2"
    if [ -z "$repo" ]; then
      repo="$(GH_TOKEN="$TOKEN" gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || return 2
      case "$repo" in */*) ;; *) return 2 ;; esac
    fi
    open="$(GH_TOKEN="$TOKEN" gh api --paginate --slurp "repos/$repo/pulls?state=open&per_page=100" 2>/dev/null)" || return 2
    open="$(printf '%s' "$open" | jq -c 'add // [] | map({number, body})' 2>/dev/null)" || return 2
    printf '%s' "$open" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
    while read -r n; do
      [ -n "$n" ] || continue
      printf '%s' "$open" | jq -r --arg n "$n" '
        .[] | select(type == "object" and (.number | type) == "number")
        | select(any((.body // "") | split("\n")[] | rtrimstr("\r");
                     test("^[ \\t]*(closes?|closed|fix(es|ed)?|resolves?|resolved|refs?)[ \\t]+#" + $n + "[ \\t]*\\.?[ \\t]*$"; "i")))
        | "#\(.number) links #\($n)"' 2>/dev/null || return 2
    done <<LINKS
$links
LINKS
  }
  set +e
  DUPLICATE_LINKS="$(pr_create_duplicate_links "$PR_BODY" "${PR_CREATE_REPO:-}")"
  DUPLICATE_RC=$?
  set -e
  if [ "$DUPLICATE_RC" -ne 0 ]; then
    echo "gh-as-author: could not list open pull requests to check whether another one already links this issue; retry once the list is readable. GH_AS_AUTHOR_ALLOW_DUPLICATE_LINK cannot bypass this: it names a duplicate this check found, and none could be read (#2562)." >&2
    exit 1
  fi
  if [ -n "$DUPLICATE_LINKS" ]; then
    UNNAMED_DUPLICATES=""
    while read -r duplicate_line; do
      [ -n "$duplicate_line" ] || continue
      other_number="${duplicate_line#\#}"
      other_number="${other_number%% *}"
      case ",${GH_AS_AUTHOR_ALLOW_DUPLICATE_LINK:-}," in
        *",$other_number,"*) ;;
        *) UNNAMED_DUPLICATES="$UNNAMED_DUPLICATES
  $duplicate_line" ;;
      esac
    done <<DUPLICATES
$DUPLICATE_LINKS
DUPLICATES
    if [ -n "$UNNAMED_DUPLICATES" ]; then
      echo "gh-as-author: another open pull request already links an issue this body links:$UNNAMED_DUPLICATES" >&2
      echo "  Refusing to open a second one (#2562). Read that pull request first; if this one is a deliberate split or a stacked tranche, name it in GH_AS_AUTHOR_ALLOW_DUPLICATE_LINK=<number>[,<number>] and say so in the body." >&2
      exit 7
    fi
  fi

  # The validated snapshot is the only body value passed to gh. This prevents
  # stdin or a mutable body file from changing between validation and creation.
  NORMALIZED_COMMAND+=(--body "$PR_BODY")
  set -- "${NORMALIZED_COMMAND[@]}"
fi

# Transport. On a cloud surface every `gh pr` / `gh issue` subcommand is a
# GraphQL call the proxy refuses, so the write runs as REST calls under the
# verified token and its byline is read back there; `gh pr merge` is refused
# there, because the merge gates below read GraphQL (#1057 item A). The
# validated PR-create body arrives as --body. Locally the wrapped command
# runs through gh, as before. See scripts/lib/gh-rest-transport.sh.
TRANSPORT="$(gh_transport_select)" || exit 1
gh_comment_guard_check_transport "$TRANSPORT" || exit 1
if [ "$TRANSPORT" = "rest" ]; then
  trap 'gh_comment_guard_cleanup; gh_rest_cleanup' EXIT
  # shellcheck disable=SC2034  # read by gh_rest_run (scripts/lib/gh-rest-transport.sh)
  GH_REST_TRACE_MARKER="$TRACE_MARKER"
  set +e
  gh_comment_guard_run_write gh_rest_run gh-as-author "$AUTHOR" "$TOKEN" "$@"
  WRAPPED_RC=$?
  set -e
  exit "$WRAPPED_RC"
fi

# The verified token goes to github.com only. Any other host gets the resolver's
# non-credential sentinel in place of an Enterprise token or stored login, so
# it can neither carry the write nor receive the PAT (see gh-token-resolver.sh).
run_with_author_token() {
  unset GITHUB_TOKEN
  # Classify actual argv through the same parser used by scoped admin
  # preparation. Only ordinary/deferred merges enter the fresh runtime;
  # other author writes keep their established direct transport and trace.
  MERGE_PAYLOAD_ACTION=$(python3 -I -S "$ROOT/scripts/workflow/owner-admin-override.py" classify "$@") || return $?
  case "$MERGE_PAYLOAD_ACTION" in
    ordinary|deferred)
      GH_TOKEN="$TOKEN" GH_AS_AUTHOR_RECORD_IDENTITY="$AUTHOR" \
        GH_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
        GITHUB_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
        python3 -I -S "$ROOT/scripts/workflow/merge-writer.py" "$TRACE_MARKER" "$@"
      return $?
      ;;
    ""|admin|retraction) ;;
    *) echo "gh-as-author: unknown merge classification; refusing the write." >&2; return 2 ;;
  esac
  if [ -n "$TRACE_MARKER" ] && ! : >"$TRACE_MARKER"; then
    echo "gh-as-author: cannot write the trace marker $TRACE_MARKER; refusing to run the write unrecorded." >&2
    exit 70
  fi
  # GH_HOST is pinned to github.com, where the token was verified: with it
  # unset, gh targets the only host in its hosts file (Phase 4b on #2178).
  GH_HOST=github.com GH_TOKEN="$TOKEN" GH_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
    GITHUB_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" "$@"
}

# Every admin merge records its scoped owner instruction before the write.
# The helper sees actual argv and runs only for an actual --admin flag.
(
  unset GITHUB_TOKEN
  GH_TOKEN="$TOKEN" GH_AS_AUTHOR_RECORD_IDENTITY="$AUTHOR" \
    GH_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
    GITHUB_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
    python3 -I -S "$ROOT/scripts/workflow/owner-admin-override.py" prepare "$@"
)

if [ "$IS_PR_CREATE" -eq 1 ]; then
  TMP_OUT=$(mktemp)
  trap 'gh_comment_guard_cleanup; rm -f "$TMP_OUT"' EXIT
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
    GH_HOST=github.com GH_TOKEN="$TOKEN" GH_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
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
# A claimed Codex trigger write (#1362) confirms its comment id before exit.
gh_comment_guard_run_write run_with_author_token "$@"
WRAPPED_RC=$?
set -e
exit "$WRAPPED_RC"
