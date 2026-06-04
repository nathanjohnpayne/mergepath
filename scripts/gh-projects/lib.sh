#!/usr/bin/env bash
# Reusable helpers for creating phased GitHub Projects v2 issue trees.
#
# Source this from a driver script (one per multi-phase initiative). The driver
# declares the issues; this file does the mechanics (parent/child creation,
# native sub-issue linking, Project item-add).
#
# Required environment:
#   REPO     — owner/name, e.g. "nathanjohnpayne/nathanpaynedotcom"
#   OWNER    — Project owner login (user or org)
#   PROJECT  — Project v2 number (integer)
#
# Required auth:
#   GH_TOKEN must be set to an author PAT with `repo` + `project` scopes.
#
# Placeholders in body files:
#   __PARENT_NUM__ — replaced with the parent issue number
#   __C1_NUM__ ... __C4_NUM__ — replaced with sibling child numbers (use when a
#     child body needs to reference another child; see examples/)

set -euo pipefail

: "${REPO:?REPO must be set (owner/repo)}"
: "${OWNER:?OWNER must be set}"
: "${PROJECT:?PROJECT must be set (v2 number)}"
: "${GH_TOKEN:?GH_TOKEN must be set to the author PAT with repo + project scopes (every helper here mutates GitHub; failing fast at source-time is better than letting gh fall through to ambient auth and posting under the wrong identity)}"

GHP_EXPECTED_IDENTITY="${GHP_EXPECTED_IDENTITY:-nathanjohnpayne}"
GHP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GHP_CHECKER="$GHP_ROOT/scripts/identity-check.sh"
if [ "${GHP_SKIP_TOKEN_IDENTITY_CHECK:-0}" != "1" ]; then
  if [ ! -x "$GHP_CHECKER" ]; then
    echo "scripts/gh-projects/lib.sh: identity-check helper missing or non-executable: $GHP_CHECKER" >&2
    return 2 2>/dev/null || exit 2
  fi
  if ! GH_TOKEN="$GH_TOKEN" "$GHP_CHECKER" --expect-token-identity "$GHP_EXPECTED_IDENTITY"; then
    echo "scripts/gh-projects/lib.sh: GH_TOKEN must resolve to $GHP_EXPECTED_IDENTITY for project/issue mutations." >&2
    return 2 2>/dev/null || exit 2
  fi
fi

ghp_gh() (
  unset GITHUB_TOKEN
  gh "$@"
)

GHP_TMPDIR="${GHP_TMPDIR:-$(mktemp -d)}"
export GHP_TMPDIR

# Add a created issue to the configured project.
add_to_project() {
  ghp_gh project item-add "$PROJECT" --owner "$OWNER" --url "$1" > /dev/null
}

# Link a child issue to its parent via GitHub's native sub-issue API.
# The parent_num is the integer issue number; child_id is the DB id (integer),
# not the issue number. Fetch with: gh api repos/$REPO/issues/$num --jq .id
link_sub_issue() {
  ghp_gh api -X POST "repos/$REPO/issues/$1/sub_issues" -F "sub_issue_id=$2" > /dev/null
}

# Substitute placeholders in a body file; write to a unique path under
# $GHP_TMPDIR and echo it. Two different source files whose basenames
# collide (e.g. phase-1/c1.md and phase-2/c1.md) get distinct output
# paths — using `basename` alone would overwrite.
# Usage: prep_body <src> <parent_num> [c1] [c2] [c3] [c4]
prep_body() {
  local src="$1" parent="$2" c1="${3:-}" c2="${4:-}" c3="${5:-}" c4="${6:-}"
  # Preserve the full source path structure under $GHP_TMPDIR — the
  # earlier `tr '/' '_'` transform was still collision-prone (a source
  # like `phase-1/c1.md` mapped to `phase-1_c1.md`, which collided
  # with an actual `phase-1_c1.md` source). Mirroring the full path
  # eliminates any name-collision ambiguity. (CodeRabbit Major, #272.)
  #
  # Reject path-traversal: an absolute `src` or one containing a `..`
  # segment would let `dst=$GHP_TMPDIR/$src` write OUTSIDE $GHP_TMPDIR
  # entirely. The old `tr '/' '_'` form was incidentally
  # traversal-safe; preserving the path means restoring that
  # explicitly. Same slash-wrapped check as `check_sync_manifest`'s
  # repo-escape guard. (Codex P2 + CodeRabbit Major on PR #279.)
  case "$src" in
    /*)
      echo "prep_body: refusing absolute src '$src'" >&2
      return 2
      ;;
  esac
  case "/$src/" in
    */../*)
      echo "prep_body: refusing src '$src' (contains '..' segment; would escape \$GHP_TMPDIR)" >&2
      return 2
      ;;
  esac
  local dst="$GHP_TMPDIR/$src"
  mkdir -p "$(dirname "$dst")"
  sed \
    -e "s|__PARENT_NUM__|$parent|g" \
    -e "s|__C1_NUM__|$c1|g" \
    -e "s|__C2_NUM__|$c2|g" \
    -e "s|__C3_NUM__|$c3|g" \
    -e "s|__C4_NUM__|$c4|g" \
    "$src" > "$dst"
  echo "$dst"
}

# Create a parent issue and add it to the configured project.
# Side effects: calls `add_to_project` on the new issue.
# Echoes the issue URL.
# Usage: create_parent <title> <body_file> <labels_csv>
create_parent() {
  local title="$1" body_file="$2" label="$3"
  local url
  url=$(ghp_gh issue create --repo "$REPO" --title "$title" --body-file "$body_file" --label "$label" | tail -1)
  add_to_project "$url"
  echo "$url"
}

# Create a child issue, add to project, link as sub-issue of parent.
# Echoes three space-separated fields: URL NUMBER DB_ID
# Usage: create_child <title> <body_file> <labels_csv> <parent_num>
create_child() {
  local title="$1" body_file="$2" label="$3" parent_num="$4"
  local url num id
  url=$(ghp_gh issue create --repo "$REPO" --title "$title" --body-file "$body_file" --label "$label" | tail -1)
  num="${url##*/}"
  id=$(ghp_gh api "repos/$REPO/issues/$num" --jq .id)
  add_to_project "$url"
  link_sub_issue "$parent_num" "$id"
  echo "$url $num $id"
}

# Set the Project v2 README from a local file.
# Usage: set_project_readme <file>
set_project_readme() {
  ghp_gh project edit "$PROJECT" --owner "$OWNER" --readme "$(cat "$1")" > /dev/null
  echo "Project #$PROJECT README updated from $1"
}

# Ensure a label exists in the repo (idempotent).
# Usage: ensure_label <name> <color_hex> <description>
ensure_label() {
  ghp_gh label create "$1" --color "$2" --description "$3" --repo "$REPO" --force > /dev/null
}
