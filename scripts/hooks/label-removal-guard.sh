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
TMP_CMD=$(mktemp)
trap 'rm -f "$TMP_CMD" "${TMP_TOKENS:-}"' EXIT
if echo "$INPUT" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    cmd = d.get("tool_input", {}).get("command", "")
    sys.stdout.write(cmd)
except Exception:
    sys.exit(1)
' > "$TMP_CMD" 2>/dev/null; then
  COMMAND=$(cat "$TMP_CMD")
else
  COMMAND="$INPUT"
fi

# Empty command → allow (nothing to gate).
if [ -z "$COMMAND" ]; then exit 0; fi

# Cheap pre-check: if the command isn't `gh pr edit`, skip the tokenize
# work entirely. We deliberately do NOT pre-check for the prohibited
# label name as a substring — Codex P1 on PR #172 caught that the
# substring gate is bypassable when the label value is supplied via
# shell expansion (`--remove-label "$VAR"`) or ANSI-C quoting
# (`--remove-label $'needs-human-review'`). The token-walk below sees
# the EXPANDED value (because the harness passes the literal command
# string the agent intends to run) — which means the post-tokenize
# regex check is the source of truth, and any pre-check on label name
# would either let bypasses through (bug) or false-positive on
# unrelated commands. The `gh pr edit` form check is structural (the
# binary name + subcommand must be literal for the command to do
# anything), so it remains safe.
case "$COMMAND" in
  *gh*pr*edit*|*gh*-R*pr*edit*|*gh*--repo*pr*edit*) ;;
  *) exit 0 ;;
esac

TMP_TOKENS=$(mktemp)
trap 'rm -f "$TMP_CMD" "$TMP_TOKENS"' EXIT
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

# Scan tokens AFTER `edit` for --remove-label or --add-label values.
# Both forms are blocked: removing a label bypasses human gating;
# adding one (e.g. spuriously re-applying policy-violation) is also a
# human action.
#
# Two block triggers:
#   1. Literal value matches the prohibited set.
#   2. Value undergoes shell expansion (contains $, backtick, or starts
#      with $') — Codex P1 on PR #172. The hook receives the literal
#      command string before bash expands variables, so a value like
#      `--remove-label "$VAR"` would tokenize as the literal `$VAR`
#      and slip past a value-only regex check, even though the bash
#      that actually runs the command would expand it to a prohibited
#      label. Block any expansion-bearing value with a message
#      directing the agent to use a literal label name (so the hook
#      can see what's being modified) or scripts/request-label-removal.sh.
PROHIBITED_RE='^(needs-external-review|needs-human-review|policy-violation)$'
EXPANSION_RE='[$`]'
walk_start=$((edit_index + 1))
SKIP_AS=""  # "" | "label-flag-value"

# Codex r1 on PR #172 caught: gh accepts `--remove-label A,B` as a
# comma-separated list, but the regex above only matches the entire
# token. So `--remove-label needs-external-review,foo` would slip
# past — the joined value doesn't match `^needs-external-review$`,
# but bash splits and removes both labels. Check each comma-split
# segment instead of the whole value.
check_label_value() {
  local raw="$1"
  if [[ "$raw" =~ $EXPANSION_RE ]]; then block_expansion "$raw"; fi
  local IFS=','
  for sub in $raw; do
    sub="${sub# }"; sub="${sub% }"   # trim incidental whitespace
    [[ -z "$sub" ]] && continue
    if [[ "$sub" =~ $PROHIBITED_RE ]]; then block_prohibited "$sub"; fi
  done
}

block_prohibited() {
  local label="$1"
  cat <<EOF >&2
BLOCKED: agents must not modify the '$label' label on PRs.

Per REVIEW_POLICY.md § Agent prohibitions, the labels:
  - needs-external-review
  - needs-human-review
  - policy-violation
are HUMAN-ACTION labels. One-time chat authorization does not extend to
agent action on these labels.

If the PR is otherwise green and only this label is blocking merge:
  scripts/request-label-removal.sh <PR#> $label

That helper posts a templated ask on the PR (and optionally iMessages
the human). The human clears the label from any device; auto-merge
fires immediately.
EOF
  exit 2
}

block_expansion() {
  local val="$1"
  cat <<EOF >&2
BLOCKED: --add-label / --remove-label value '$val' contains shell
expansion (\$, backtick, or \$'…' quoting). The hook can't see what
this expands to until bash runs the command — so it cannot verify the
label isn't one of the prohibited set (needs-external-review,
needs-human-review, policy-violation).

Use a literal label name so the guard can verify it, OR — if you
intended to remove a prohibited label — run:
  scripts/request-label-removal.sh <PR#> <label>

See REVIEW_POLICY.md § Agent prohibitions.
EOF
  exit 2
}

for j in "${!TOKENS[@]}"; do
  if [ "$j" -lt "$walk_start" ]; then continue; fi
  tok="${TOKENS[$j]}"
  if [ "$SKIP_AS" = "label-flag-value" ]; then
    SKIP_AS=""
    check_label_value "$tok"
    continue
  fi
  case "$tok" in
    --remove-label|--add-label)
      SKIP_AS="label-flag-value"
      continue
      ;;
    --remove-label=*|--add-label=*)
      check_label_value "${tok#*=}"
      continue
      ;;
  esac
done

exit 0
