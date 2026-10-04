#!/usr/bin/env bash
# scripts/hooks/cloud-session-start.sh — Claude Code SessionStart hook that
# tells a cloud session what it can do before it tries (#1057 item F).
#
# Wired in .claude/settings.json. SessionStart hooks run in local and cloud
# sessions alike, so this exits at once unless CLAUDE_CODE_REMOTE=true: a
# local session is never probed and never slowed down. In a cloud session it
# first runs scripts/cloud-setup.sh, which installs a missing or wrong tool
# (the Claude cloud image's `yq` is not mikefarah/yq v4) and does nothing when
# the tools are right, then runs scripts/agent-capability-probe.sh (which
# caches its answer for `--check`) and prints a short summary on stdout, which
# Claude Code adds to the session's context. Setup is bounded to 60 seconds so
# the probe still fits the hook's 120-second timeout; a setup that fails or
# times out is reported in the summary, and the probe runs regardless.
#
# It never fails the session: every path exits 0. A probe that cannot run is
# reported in the summary, because a session that silently lacks the answer
# goes back to discovering its limits by failing, which is what #1057 removes.
#
# Bash 3.2 portable.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/scripts/agent-capability-probe.sh"
SETUP="$ROOT/scripts/cloud-setup.sh"

if [ -r "$SETUP" ]; then
  bound=""
  command -v timeout >/dev/null 2>&1 && bound="timeout ${MERGEPATH_CLOUD_SETUP_TIMEOUT:-60}"
  # stderr is the setup's whole report; stdout is unused.
  if setup_log="$($bound bash "$SETUP" 2>&1 >/dev/null)"; then
    installed="$(printf '%s\n' "$setup_log" | sed -n 's/^cloud-setup: installed \([^ ]* [^ ]*\) .*/\1/p' | paste -sd, - | sed 's/,/, /g')"
    [ -z "$installed" ] || echo "mergepath cloud session: installed $installed (scripts/cloud-setup.sh)."
  else
    echo "mergepath cloud session: tool setup failed or timed out (bash scripts/cloud-setup.sh to see why): $(printf '%s\n' "$setup_log" | tail -1)"
  fi
fi

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
  # A "no" is classified from what the probe measured, never from the key
  # alone (Codex on #1552). A proxy ceiling needs proxy-specific evidence: a
  # documented denial or the probe GraphQL-ceiling reason, and is handed off.
  # A bare 403/404 is not that evidence (a token without access to the target
  # returns the same), so it is fixed first like any other "no". When the run
  # had a transient failure (a rate-limited 403, a 5xx), the remaining "no"
  # answers may be that failure, so they are re-probed before anything else.
  # An unverifiable token (a fine-grained PAT) is neither: no re-probe can
  # grant it, and the wrappers accept it (Codex on #1552).
  .transient_failures as $transient |
  (.capabilities | to_entries[] |
    "- \(.key): \(if .value.granted then "yes" else "no" end), \(.value.reason)" +
    (if .value.granted then ""
     elif (.value.basis == "documented")
          or ((.value.reason // "") | startswith("proxy GraphQL ceiling"))
       then " (proxy ceiling: hand this step to a local session or CI)"
     elif (.value.basis == "not-measured") then " (not measured)"
     elif (.value.basis == "unverifiable")
       then " (not provable: GitHub does not expose this token type\u0027s permissions; the wrappers still verify its identity before each write, so a re-probe will not change this)"
     elif $transient then " (may be transient: re-run scripts/agent-capability-probe.sh before acting on it)"
     else " (fix the credential, tools or setup, then re-run scripts/agent-capability-probe.sh)" end)),
  "Writes go through scripts/gh-as-author.sh / scripts/gh-as-reviewer.sh. Act on each no by its note, which is the only remediation: a proxy ceiling is a property of this session (hand the step to a local session or CI); a fix note is a credential or setup problem (docs/agents/cloud-environments.md, Credentials); may-be-transient means re-probe first; not provable and not measured need no repair."
' 2>/dev/null || echo "mergepath cloud session: capability summary could not be rendered; run scripts/agent-capability-probe.sh."
exit 0
