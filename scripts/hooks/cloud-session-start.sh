#!/usr/bin/env bash
# scripts/hooks/cloud-session-start.sh — Claude Code SessionStart hook that
# tells a cloud session what it can do before it tries (#1057 item F).
#
# Wired in .claude/settings.json. SessionStart hooks run in local and cloud
# sessions alike, so this exits at once unless CLAUDE_CODE_REMOTE=true: a
# local session is never probed and never slowed down. In a cloud session it
# runs scripts/agent-capability-probe.sh (which caches its answer for
# `--check`) and prints a short summary on stdout, which Claude Code adds to
# the session's context.
#
# It never fails the session: every path exits 0. A probe that cannot run is
# reported in the summary, because a session that silently lacks the answer
# goes back to discovering its limits by failing, which is what #1057 removes.
#
# Bash 3.2 portable.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/scripts/agent-capability-probe.sh"

if [ ! -x "$PROBE" ]; then
  echo "mergepath cloud session: capability probe missing ($PROBE); capabilities unknown. See docs/agents/cloud-environments.md."
  exit 0
fi

result="$("$PROBE" --quiet 2>/dev/null)" || result=""
if [ -z "$result" ] || ! printf '%s' "$result" | jq -e . >/dev/null 2>&1; then
  echo "mergepath cloud session: the capability probe did not produce a result; capabilities unknown. Run scripts/agent-capability-probe.sh to see why. See docs/agents/cloud-environments.md."
  exit 0
fi

printf '%s\n' "$result" | jq -r '
  "mergepath cloud session on \(.surface) for \(.repo): capability tier `\(.tier)`" +
  (if .transient_failures then " (some checks failed transiently; re-run scripts/agent-capability-probe.sh)" else "" end) + ".",
  # A "no" is one of two different things (Codex on #1552): the proxy
  # ceilings (graphql, cross-repo, push-multi-branch) are properties of the
  # session, to hand off; every other "no" (author-writes, reviewer-writes,
  # read) is a credential or setup problem, to fix and re-probe.
  (.capabilities | to_entries[] |
    "- \(.key): \(if .value.granted then "yes" else "no" end), \(.value.reason)" +
    (if .value.granted then ""
     elif (.key == "graphql" or .key == "cross-repo" or .key == "push-multi-branch") then " (proxy ceiling: hand this step to a local session or CI)"
     else " (fix the credential or setup, then re-run scripts/agent-capability-probe.sh)" end)),
  "Writes go through scripts/gh-as-author.sh / scripts/gh-as-reviewer.sh. A no marked as a proxy ceiling is a property of this session: hand those steps to a local session or CI. Any other no is a credential or setup problem to fix first (docs/agents/cloud-environments.md, Credentials)."
' 2>/dev/null || echo "mergepath cloud session: capability summary could not be rendered; run scripts/agent-capability-probe.sh."
exit 0
