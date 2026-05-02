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
#   GH_TOKEN must be set to a PAT with `repo` + `project` scopes.
#
# Placeholders in body files:
#   __PARENT_NUM__ — replaced with the parent issue number
#   __C1_NUM__ ... __C4_NUM__ — replaced with sibling child numbers (use when a
#     child body needs to reference another child; see examples/)

set -euo pipefail

: "${REPO:?REPO must be set (owner/repo)}"
: "${OWNER:?OWNER must be set}"
: "${PROJECT:?PROJECT must be set (v2 number)}"
: "${GH_TOKEN:?GH_TOKEN must be set to a PAT with repo + project scopes (CodeRabbit on PR #180: every helper here makes mutations on GitHub; failing fast at source-time is better than letting gh fall through to ambient auth and posting under the wrong identity)}"

GHP_TMPDIR="${GHP_TMPDIR:-$(mktemp -d)}"
export GHP_TMPDIR

# Add a created issue to the configured project.
add_to_project() {
  gh project item-add "$PROJECT" --owner "$OWNER" --url "$1" > /dev/null
}

# Link a child issue to its parent via GitHub's native sub-issue API.
# The parent_num is the integer issue number; child_id is the DB id (integer),
# not the issue number. Fetch with: gh api repos/$REPO/issues/$num --jq .id
link_sub_issue() {
  gh api -X POST "repos/$REPO/issues/$1/sub_issues" -F "sub_issue_id=$2" > /dev/null
}

# Substitute placeholders in a body file; write to a unique path under
# $GHP_TMPDIR and echo it. Two different source files whose basenames
# collide (e.g. phase-1/c1.md and phase-2/c1.md) get distinct output
# paths — using `basename` alone would overwrite.
# Usage: prep_body <src> <parent_num> [c1] [c2] [c3] [c4]
prep_body() {
  local src="$1" parent="$2" c1="${3:-}" c2="${4:-}" c3="${5:-}" c4="${6:-}"
  # Encode the full source path into the destination name by replacing
  # slashes with underscores, so distinct source paths map to distinct
  # destinations.
  local dst="$GHP_TMPDIR/$(echo "$src" | tr '/' '_')"
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
  url=$(gh issue create --repo "$REPO" --title "$title" --body-file "$body_file" --label "$label" | tail -1)
  add_to_project "$url"
  echo "$url"
}

# Create a child issue, add to project, link as sub-issue of parent.
# Echoes three space-separated fields: URL NUMBER DB_ID
# Usage: create_child <title> <body_file> <labels_csv> <parent_num>
create_child() {
  local title="$1" body_file="$2" label="$3" parent_num="$4"
  local url num id
  url=$(gh issue create --repo "$REPO" --title "$title" --body-file "$body_file" --label "$label" | tail -1)
  num="${url##*/}"
  id=$(gh api "repos/$REPO/issues/$num" --jq .id)
  add_to_project "$url"
  link_sub_issue "$parent_num" "$id"
  echo "$url $num $id"
}

# Set the Project v2 README from a local file.
# Usage: set_project_readme <file>
set_project_readme() {
  gh project edit "$PROJECT" --owner "$OWNER" --readme "$(cat "$1")" > /dev/null
  echo "Project #$PROJECT README updated from $1"
}

# Ensure a label exists in the repo (idempotent).
# Usage: ensure_label <name> <color_hex> <description>
ensure_label() {
  gh label create "$1" --color "$2" --description "$3" --repo "$REPO" --force > /dev/null
}
