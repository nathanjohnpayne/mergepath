#!/usr/bin/env bash
# Move a GitHub Project v2 item (by issue number) to a named Status swimlane.
#
# Usage:
#   # Front-load the preflight, then run with the cached PAT.
#   eval "$(scripts/op-preflight.sh --agent claude --mode review)"
#   PROJECT=5 OWNER=nathanjohnpayne REPO=nathanjohnpayne/nathanpaynedotcom \
#     GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT" ./move-item.sh <issue_number> <status_name>
#
#   # Same, but add the issue to the board first if it is not on it yet.
#   ... ./move-item.sh --add-if-missing <issue_number> <status_name>
#
# (The earlier example showed `GH_TOKEN="$(op read ...)"`, which is the
# disallowed inline-secret-read pattern — caught by CodeRabbit on the
# 024e0da propagation wave, #272.)
#
# <status_name> is the human-readable option name, matched exactly (including
# case): Backlog, Ready, In progress, In review, Done (the canonical set
# mergepath's new-repo bootstrap creates), or whatever options exist on the
# project's Status field.
#
# The script discovers the project's node ID, Status field ID, and option IDs
# at runtime, so it works with any Project v2 that has a Status field.
#
# The item is resolved through the issue, not the board: ONE GraphQL query
# returns the project's ID and Status options together with the issue's own
# projectItems, and the item whose project is $OWNER's #$PROJECT is the one
# edited. The earlier form ran `gh project item-list --limit 2000` (plus
# `project view` and `project field-list`) on every call, which pages the
# whole board: ~950 items on Project #4, so a batch of lane moves spent the
# account's 5,000-point/hour GraphQL quota (2026-10-02). The query now costs
# one point whatever the board's size.
#
# An issue that is not on the board fails with a clear message, unless
# --add-if-missing is passed, in which case it is added (`gh project
# item-add`, which is idempotent) and then moved.

set -euo pipefail

usage() {
  echo "usage: move-item.sh [--add-if-missing] [--] <issue_number> <status_name>" >&2
}

# Options are read until `--` or the first positional. After that only
# --add-if-missing is still a flag, so a Status option whose name begins with
# a dash (`move-item.sh 211 -Blocked`) stays selectable, as it was when the
# script read $1 and $2 directly.
ADD_IF_MISSING=0
POSITIONAL=()
OPTIONS_DONE=0
for arg in "$@"; do
  if [ "$OPTIONS_DONE" = "1" ] || [ "${#POSITIONAL[@]}" -gt 0 ]; then
    case "$arg" in
      --add-if-missing)
        if [ "$OPTIONS_DONE" = "1" ]; then POSITIONAL+=("$arg"); else ADD_IF_MISSING=1; fi
        ;;
      *) POSITIONAL+=("$arg") ;;
    esac
    continue
  fi
  case "$arg" in
    --) OPTIONS_DONE=1 ;;
    --add-if-missing) ADD_IF_MISSING=1 ;;
    -h|--help) usage; exit 0 ;;
    -?*) echo "Error: unknown option: $arg" >&2; usage; exit 2 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
ISSUE_NUM="${POSITIONAL[0]:-}"
STATUS_NAME="${POSITIONAL[1]:-}"
if [ "${#POSITIONAL[@]}" -ne 2 ] || [ -z "$STATUS_NAME" ]; then
  echo "Error: expected <issue_number> and <status_name>, got ${#POSITIONAL[@]} argument(s)" >&2
  usage
  exit 2
fi

: "${REPO:?REPO must be set (owner/repo)}"
: "${OWNER:?OWNER must be set}"
: "${PROJECT:?PROJECT must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set to the author PAT with project scope (this script mutates project items)}"

case "$ISSUE_NUM" in ''|*[!0-9]*) echo "Error: issue number must be a positive integer, got '$ISSUE_NUM'" >&2; exit 2 ;; esac
case "$PROJECT" in ''|*[!0-9]*) echo "Error: PROJECT must be a project number, got '$PROJECT'" >&2; exit 2 ;; esac
case "$REPO" in */*) ;; *) echo "Error: REPO must be owner/repo, got '$REPO'" >&2; exit 2 ;; esac

# Required tooling: gh and python3 (used for parsing gh's JSON output below).
# CodeRabbit on PR #180 caught the missing python3 check — fail fast with a
# clear error rather than letting the python3 invocation crash mid-pipeline.
command -v gh      >/dev/null 2>&1 || { echo "Error: gh CLI not on PATH (install via 'brew install gh')." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 not on PATH (this script uses python3 to parse gh's JSON output; install python3 via your package manager)." >&2; exit 1; }

EXPECTED_IDENTITY="${GHP_EXPECTED_IDENTITY:-nathanjohnpayne}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/../identity-check.sh"
if [ "${GHP_SKIP_TOKEN_IDENTITY_CHECK:-0}" != "1" ]; then
  if [ ! -x "$CHECKER" ]; then
    echo "Error: identity-check helper missing or non-executable: $CHECKER" >&2
    exit 2
  fi
  if ! GH_TOKEN="$GH_TOKEN" "$CHECKER" --expect-write-identity "$EXPECTED_IDENTITY"; then
    echo "Error: GH_TOKEN must resolve to $EXPECTED_IDENTITY for project-item mutations." >&2
    exit 2
  fi
fi

# Pinned to github.com, the only host the write-identity check verifies: with
# a sole GHES host in hosts.yml a bare call would otherwise go there (#1541).
ghp_gh() (
  unset GITHUB_TOKEN
  GH_HOST=github.com gh "$@"
)

# `gh project --owner` accepts @me for the token's own account, but
# repositoryOwner(login:) needs a real login. Resolve it over REST, which does
# not draw on the GraphQL quota; `item-add` below still takes $OWNER as given.
OWNER_LOGIN="$OWNER"
if [ "$OWNER" = "@me" ]; then
  if ! OWNER_LOGIN=$(ghp_gh api user --jq .login) || [ -z "$OWNER_LOGIN" ]; then
    echo "failed to resolve OWNER=@me to the token's login" >&2
    exit 1
  fi
fi

# One query resolves everything the edit needs. The Status field is matched by
# exact name over the board's fields (not `field(name:)`), and the option by
# exact name, so the matching rules are the ones `field-list` gave before.
# projectItems is the issue's own membership list, so its size is the number
# of boards the issue is on, not the number of items on the board.
# shellcheck disable=SC2016 # $vars are GraphQL variables, not shell expansions
QUERY='
query($owner: String!, $repoOwner: String!, $repoName: String!, $number: Int!, $project: Int!) {
  repositoryOwner(login: $owner) {
    ... on ProjectV2Owner {
      projectV2(number: $project) {
        id
        fields(first: 100) {
          nodes {
            ... on ProjectV2FieldCommon { id name }
            ... on ProjectV2SingleSelectField { options { id name } }
          }
        }
      }
    }
  }
  repository(owner: $repoOwner, name: $repoName) {
    issue(number: $number) {
      url
      projectItems(first: 20) {
        pageInfo { hasNextPage }
        nodes { id isArchived project { id } }
      }
    }
  }
}'

# gh exits non-zero, with GitHub's own message on stderr, when the owner,
# project, repository, or issue does not resolve; that message is the error.
if ! RESOLVED_JSON=$(ghp_gh api graphql \
    -f query="$QUERY" \
    -f owner="$OWNER_LOGIN" \
    -f repoOwner="${REPO%%/*}" \
    -f repoName="${REPO#*/}" \
    -F number="$ISSUE_NUM" \
    -F project="$PROJECT"); then
  echo "failed to resolve issue #$ISSUE_NUM in $REPO on $OWNER's Project #$PROJECT (see the GraphQL error above)" >&2
  exit 1
fi

export STATUS_NAME
IFS='|' read -r PROJECT_ID STATUS_FIELD_ID OPT_ID ISSUE_URL ITEM_ID ITEM_STATE <<<"$(printf '%s' "$RESOLVED_JSON" | python3 -c "
import json, os, sys
name = os.environ['STATUS_NAME']
d = json.load(sys.stdin).get('data') or {}
project = (d.get('repositoryOwner') or {}).get('projectV2') or {}
project_id = project.get('id') or ''
field_id = ''
opt_id = ''
for f in (project.get('fields') or {}).get('nodes') or []:
    if (f or {}).get('name') == 'Status':
        field_id = f.get('id', '')
        for o in f.get('options') or []:
            if o.get('name') == name:
                opt_id = o.get('id', '')
                break
        break
issue = (d.get('repository') or {}).get('issue') or {}
items = issue.get('projectItems') or {}
item_id = ''
state = 'missing'
for it in items.get('nodes') or []:
    # Match on the project's node ID, not its number: another owner's board
    # can carry the same number.
    if project_id and ((it or {}).get('project') or {}).get('id') == project_id:
        item_id = it.get('id', '')
        state = 'archived' if it.get('isArchived') else 'found'
        break
if not item_id and (items.get('pageInfo') or {}).get('hasNextPage'):
    state = 'truncated'
print('|'.join([project_id, field_id, opt_id, issue.get('url') or '', item_id, state]))
")"

if [ -z "$PROJECT_ID" ] || [ -z "$STATUS_FIELD_ID" ] || [ -z "$OPT_ID" ]; then
  echo "failed to resolve project/field/option IDs (PROJECT_ID=$PROJECT_ID, STATUS_FIELD_ID=$STATUS_FIELD_ID, OPT_ID=$OPT_ID, STATUS_NAME=$STATUS_NAME)" >&2
  echo "Confirm the project has a 'Status' single-select field and that '$STATUS_NAME' is one of its options." >&2
  exit 1
fi

ISSUE_URL="${ISSUE_URL:-https://github.com/$REPO/issues/$ISSUE_NUM}"

case "$ITEM_STATE" in
  found) ;;
  archived)
    echo "$ISSUE_URL is archived on $OWNER's Project #$PROJECT; unarchive it on the board before moving it." >&2
    exit 1
    ;;
  truncated)
    echo "$ISSUE_URL is on more than 20 projects and $OWNER's Project #$PROJECT is not among the first 20 returned; move it on the board by hand." >&2
    exit 1
    ;;
  missing)
    if [ "$ADD_IF_MISSING" != "1" ]; then
      echo "$ISSUE_URL is not on $OWNER's Project #$PROJECT. Add it first, or rerun with --add-if-missing." >&2
      exit 1
    fi
    if ! ITEM_ID=$(ghp_gh project item-add "$PROJECT" --owner "$OWNER" --url "$ISSUE_URL" --format json \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('id') or '')") \
       || [ -z "$ITEM_ID" ]; then
      echo "failed to add $ISSUE_URL to $OWNER's Project #$PROJECT" >&2
      exit 1
    fi
    echo "added #$ISSUE_NUM to Project #$PROJECT"
    ;;
  *)
    echo "failed to resolve the project item for $ISSUE_URL (unexpected state '$ITEM_STATE')" >&2
    exit 1
    ;;
esac

ghp_gh project item-edit \
  --id "$ITEM_ID" \
  --project-id "$PROJECT_ID" \
  --field-id "$STATUS_FIELD_ID" \
  --single-select-option-id "$OPT_ID" > /dev/null

echo "moved #$ISSUE_NUM to '$STATUS_NAME'"
