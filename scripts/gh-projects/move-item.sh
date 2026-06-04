#!/usr/bin/env bash
# Move a GitHub Project v2 item (by issue number) to a named Status swimlane.
#
# Usage:
#   # Front-load the preflight, then run with the cached PAT.
#   eval "$(scripts/op-preflight.sh --agent claude --mode review)"
#   PROJECT=5 OWNER=nathanjohnpayne REPO=nathanjohnpayne/nathanpaynedotcom \
#     GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT" ./move-item.sh <issue_number> <status_name>
#
# (The earlier example showed `GH_TOKEN="$(op read ...)"`, which is the
# disallowed inline-secret-read pattern — caught by CodeRabbit on the
# 024e0da propagation wave, #272.)
#
# <status_name> is the human-readable option name: Todo, In Progress, In Review,
# Human, Done (or whatever options exist on the project's Status field).
#
# The script discovers the project's node ID, Status field ID, and option IDs
# at runtime, so it works with any Project v2 that has a Status field.

set -euo pipefail

ISSUE_NUM="${1:?issue number required}"
STATUS_NAME="${2:?status name required}"

: "${REPO:?REPO must be set (owner/repo)}"
: "${OWNER:?OWNER must be set}"
: "${PROJECT:?PROJECT must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set to the author PAT with project scope (this script mutates project items)}"

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
  if ! GH_TOKEN="$GH_TOKEN" "$CHECKER" --expect-token-identity "$EXPECTED_IDENTITY"; then
    echo "Error: GH_TOKEN must resolve to $EXPECTED_IDENTITY for project-item mutations." >&2
    exit 2
  fi
fi

ghp_gh() (
  unset GITHUB_TOKEN
  gh "$@"
)

export STATUS_NAME

# Resolve the project's node ID.
PROJECT_ID=$(ghp_gh project view "$PROJECT" --owner "$OWNER" --format json \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

# Resolve the Status field ID + the option ID for the requested status in a
# single pass over field-list output.
read -r STATUS_FIELD_ID OPT_ID <<<"$(ghp_gh project field-list "$PROJECT" --owner "$OWNER" --limit 100 --format json | python3 -c "
import json, os, sys
name = os.environ['STATUS_NAME']
d = json.load(sys.stdin)
field_id = ''
opt_id = ''
for f in d.get('fields', []):
    if f.get('name') == 'Status':
        field_id = f.get('id', '')
        for o in f.get('options', []):
            if o.get('name') == name:
                opt_id = o.get('id', '')
                break
        break
print(field_id, opt_id)
")"

if [ -z "$PROJECT_ID" ] || [ -z "$STATUS_FIELD_ID" ] || [ -z "$OPT_ID" ]; then
  echo "failed to resolve project/field/option IDs (PROJECT_ID=$PROJECT_ID, STATUS_FIELD_ID=$STATUS_FIELD_ID, OPT_ID=$OPT_ID, STATUS_NAME=$STATUS_NAME)" >&2
  echo "Confirm the project has a 'Status' single-select field and that '$STATUS_NAME' is one of its options." >&2
  exit 1
fi

# Resolve the project-level item ID for this issue.
export ISSUE_URL="https://github.com/$REPO/issues/$ISSUE_NUM"
ITEM_ID=$(ghp_gh project item-list "$PROJECT" --owner "$OWNER" --format json --limit 2000 | python3 -c "
import json, os, sys
url = os.environ['ISSUE_URL']
d = json.load(sys.stdin)
for it in d.get('items', []):
    content = it.get('content') or {}
    if content.get('url') == url:
        print(it['id']); break
")

if [ -z "$ITEM_ID" ]; then
  echo "could not find project item for $ISSUE_URL (is the issue in Project #$PROJECT?)" >&2
  exit 1
fi

ghp_gh project item-edit \
  --id "$ITEM_ID" \
  --project-id "$PROJECT_ID" \
  --field-id "$STATUS_FIELD_ID" \
  --single-select-option-id "$OPT_ID" > /dev/null

echo "moved #$ISSUE_NUM to '$STATUS_NAME'"
