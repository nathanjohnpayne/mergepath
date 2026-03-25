#!/usr/bin/env bash
# gh-pr-guard.sh — PreToolUse hook for Claude Code
#
# Gates two operations:
#   1. gh pr create — blocks unless the command text includes
#      "Authoring-Agent:" and "## Self-Review"
#   2. gh pr merge --admin — blocks unless BREAK_GLASS_ADMIN=1
#      (human must explicitly authorize in chat)
#
# Exit codes:
#   0 = allow
#   2 = block (hard stop)

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only inspect gh pr commands
if ! echo "$COMMAND" | grep -qE '^\s*gh\s+pr\s+(create|merge)'; then
  exit 0
fi

# --- gh pr create ---
if echo "$COMMAND" | grep -qE '^\s*gh\s+pr\s+create'; then
  MISSING=""

  if ! echo "$COMMAND" | grep -qi 'Authoring-Agent:'; then
    MISSING="${MISSING}  - Missing 'Authoring-Agent:' in PR body\n"
  fi

  if ! echo "$COMMAND" | grep -qi '## Self-Review'; then
    MISSING="${MISSING}  - Missing '## Self-Review' section in PR body\n"
  fi

  if [[ -n "$MISSING" ]]; then
    echo "BLOCKED: PR description is missing required sections per REVIEW_POLICY.md:" >&2
    echo -e "$MISSING" >&2
    echo "Add these to the PR body before creating." >&2
    exit 2
  fi

  exit 0
fi

# --- gh pr merge --admin ---
if echo "$COMMAND" | grep -qE '^\s*gh\s+pr\s+merge'; then
  if echo "$COMMAND" | grep -q '\-\-admin'; then
    if [[ "${BREAK_GLASS_ADMIN:-}" == "1" ]]; then
      echo "BREAK-GLASS: --admin merge authorized by human." >&2
      exit 0
    fi
    echo "BLOCKED: --admin merge requires explicit human authorization." >&2
    echo "Ask the human to confirm break-glass, then retry with BREAK_GLASS_ADMIN=1." >&2
    exit 2
  fi
fi

exit 0
