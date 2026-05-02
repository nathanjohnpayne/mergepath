#!/usr/bin/env bash
# label-removal-guard.sh — PreToolUse hook for Claude Code.
#
# Blocks `gh pr edit ... --remove-label <label>` calls (and the
# add-label inverse for the same labels) for the human-action labels
# defined in REVIEW_POLICY.md § Agent prohibitions:
#
#   - needs-external-review
#   - needs-human-review
#   - policy-violation
#
# Rationale: agents must never remove these labels, even when a human
# authorizes it in chat. One-time chat authorization does not extrapolate
# into standing permission. The sanctioned path is
# `scripts/request-label-removal.sh <PR#> <label>`, which posts a
# templated ask + optional iMessage ping, after which the human clears
# the label from any device.
#
# This hook is mechanism enforcement — it makes the doctrinal rule
# unbreakable regardless of whether the agent read the policy doc.
#
# Architecture: same shape as scripts/hooks/gh-pr-guard.sh — read the
# Bash command from stdin (Claude Code passes JSON via stdin to
# PreToolUse hooks), tokenize with shlex (quote-aware), walk to find
# `gh ... pr edit`, then scan the edit subcommand's flags for
# --remove-label / --add-label whose value matches the prohibited set.
#
# A break-glass override is intentionally NOT provided. If a human
# genuinely needs the agent to act on the label, they remove it
# themselves; the agent can re-trigger merge after.
#
# Exit codes:
#   0 = allow
#   2 = block (hard stop)

set -eo pipefail

# Read stdin payload (Claude Code passes JSON; older harness passes raw
# command). Be permissive: if stdin parses as JSON with .tool_input.command,
# use that; otherwise treat stdin as the raw command.
INPUT=$(cat)
COMMAND=""
if echo "$INPUT" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    cmd = d.get("tool_input", {}).get("command", "")
    sys.stdout.write(cmd)
except Exception:
    sys.exit(1)
' > /tmp/lrg-cmd.$$ 2>/dev/null; then
  COMMAND=$(cat /tmp/lrg-cmd.$$)
  rm -f /tmp/lrg-cmd.$$
else
  COMMAND="$INPUT"
fi

# Empty command → allow (nothing to gate).
if [ -z "$COMMAND" ]; then exit 0; fi

# Cheap pre-check: if the command doesn't mention any prohibited label,
# skip the tokenize work entirely.
case "$COMMAND" in
  *needs-external-review*|*needs-human-review*|*policy-violation*) ;;
  *) exit 0 ;;
esac
case "$COMMAND" in
  *gh*pr*edit*|*gh*-R*pr*edit*|*gh*--repo*pr*edit*) ;;
  *) exit 0 ;;
esac

TMP_TOKENS=$(mktemp)
trap 'rm -f "$TMP_TOKENS"' EXIT
if ! printf '%s' "$COMMAND" | python3 -c '
import sys, shlex
try:
    for tok in shlex.split(sys.stdin.read()):
        sys.stdout.buffer.write(tok.encode("utf-8", errors="replace") + b"\x00")
except ValueError:
    sys.exit(1)
' > "$TMP_TOKENS" 2>/dev/null; then
  exit 0
fi

TOKENS=()
while IFS= read -r -d '' tok; do TOKENS+=("$tok"); done < "$TMP_TOKENS"

# Walk to find `gh ... pr edit`. We only need to know IF the command is
# `gh pr edit`; we don't need the full state machine that gh-pr-guard.sh
# uses for its merge-gate logic. A simple scan suffices because the
# label-value scan below operates on the entire token list anyway.
saw_gh=0
saw_pr=0
saw_edit=0
edit_index=-1
for i in "${!TOKENS[@]}"; do
  tok="${TOKENS[$i]}"
  if [ "$saw_gh" -eq 0 ]; then
    [ "$tok" = "gh" ] && saw_gh=1
    continue
  fi
  if [ "$saw_pr" -eq 0 ]; then
    if [ "$tok" = "pr" ]; then saw_pr=1; fi
    continue
  fi
  if [ "$saw_edit" -eq 0 ]; then
    if [ "$tok" = "edit" ]; then
      saw_edit=1
      edit_index=$i
    fi
    continue
  fi
done
[ "$saw_edit" -eq 1 ] || exit 0

# Scan tokens AFTER `edit` for --remove-label or --add-label values that
# match the prohibited set. Both forms are blocked: removing a label
# bypasses human gating; adding one (e.g. spuriously re-applying
# policy-violation) is also a human action.
PROHIBITED_RE='^(needs-external-review|needs-human-review|policy-violation)$'
walk_start=$((edit_index + 1))
SKIP_AS=""  # "" | "label-flag-value"
for j in "${!TOKENS[@]}"; do
  if [ "$j" -lt "$walk_start" ]; then continue; fi
  tok="${TOKENS[$j]}"
  if [ "$SKIP_AS" = "label-flag-value" ]; then
    SKIP_AS=""
    if [[ "$tok" =~ $PROHIBITED_RE ]]; then
      cat <<EOF >&2
BLOCKED: agents must not modify the '$tok' label on PRs.

Per REVIEW_POLICY.md § Agent prohibitions, the labels:
  - needs-external-review
  - needs-human-review
  - policy-violation
are HUMAN-ACTION labels. One-time chat authorization does not extend to
agent action on these labels.

If the PR is otherwise green and only this label is blocking merge:
  scripts/request-label-removal.sh <PR#> $tok

That helper posts a templated ask on the PR (and optionally iMessages
the human). The human clears the label from any device; auto-merge
fires immediately.
EOF
      exit 2
    fi
    continue
  fi
  case "$tok" in
    --remove-label|--add-label)
      SKIP_AS="label-flag-value"
      continue
      ;;
    --remove-label=*|--add-label=*)
      val="${tok#*=}"
      if [[ "$val" =~ $PROHIBITED_RE ]]; then
        cat <<EOF >&2
BLOCKED: agents must not modify the '$val' label on PRs.

Use: scripts/request-label-removal.sh <PR#> $val
See REVIEW_POLICY.md § Agent prohibitions.
EOF
        exit 2
      fi
      continue
      ;;
  esac
done

exit 0
