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
# Claude Code adds to the session's context. Setup is bounded to 60 seconds
# and the probe uses the remaining time within the hook's 120-second limit,
# leaving five seconds to print the summary. A setup or probe timeout is
# reported through the existing summary path. The timeout executable may be
# `timeout` or `gtimeout`; if neither exists, setup is skipped with a notice
# and the probe keeps its existing unbounded behavior.
#
# It never fails the session: every path exits 0. A probe that cannot run is
# reported in the summary, because a session that silently lacks the answer
# goes back to discovering its limits by failing, which is what #1057 removes.
#
# Bash 3.2 portable.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

# Keep this as a snapshot: assigning to SECONDS would reset Bash's timer.
hook_started=$SECONDS

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/scripts/agent-capability-probe.sh"
SETUP="$ROOT/scripts/cloud-setup.sh"

timeout_bin=""
if command -v timeout >/dev/null 2>&1; then
  timeout_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_bin=gtimeout
fi

# The setup bound is 60 seconds. MERGEPATH_CLOUD_SETUP_TIMEOUT may lower it to a
# whole number of seconds from 1 to 60; anything else keeps 60, so setup always
# leaves the probe time inside the hook's 120-second limit.
setup_bound=60
case "${MERGEPATH_CLOUD_SETUP_TIMEOUT:-}" in
  ''|*[!0-9]*) ;;
  *) [ "$MERGEPATH_CLOUD_SETUP_TIMEOUT" -ge 1 ] 2>/dev/null && [ "$MERGEPATH_CLOUD_SETUP_TIMEOUT" -le 60 ] 2>/dev/null \
       && setup_bound=$((10#$MERGEPATH_CLOUD_SETUP_TIMEOUT)) ;;
esac
if [ -n "${MERGEPATH_CLOUD_SETUP_TIMEOUT:-}" ] && [ "$setup_bound" != "$MERGEPATH_CLOUD_SETUP_TIMEOUT" ]; then
  echo "mergepath cloud session: MERGEPATH_CLOUD_SETUP_TIMEOUT must be a whole number of seconds from 1 to 60; using $setup_bound."
fi

if [ -r "$SETUP" ]; then
  if [ -z "$timeout_bin" ]; then
    echo "mergepath cloud session: tool setup skipped because timeout is not available to bound it; run bash scripts/cloud-setup.sh by hand."
  # stderr is the setup's whole report; stdout is unused.
  elif setup_log="$("$timeout_bin" "$setup_bound" bash "$SETUP" 2>&1 >/dev/null)"; then
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

probe_timeout=90
probe_timeout_input="${MERGEPATH_CLOUD_PROBE_TIMEOUT:-}"
probe_timeout_normalized="$probe_timeout_input"
case "$probe_timeout_input" in
  ''|*[!0-9]*) ;;
  *)
    # Cap input length before stripping zeroes, so hostile values cannot make
    # normalization quadratic or consume the hook's remaining time.
    if [ "${#probe_timeout_input}" -le 9 ]; then
      while [ "${probe_timeout_normalized#0}" != "$probe_timeout_normalized" ]; do
        probe_timeout_normalized="${probe_timeout_normalized#0}"
      done
      [ -n "$probe_timeout_normalized" ] || probe_timeout_normalized=0
      case "$probe_timeout_normalized" in
        [1-9]|[1-9][0-9]|10[0-9]|11[0-9]) probe_timeout="$probe_timeout_normalized" ;;
      esac
    else
      probe_timeout_normalized=invalid-length
    fi
    ;;
esac
if [ -n "$probe_timeout_input" ] && [ "$probe_timeout" != "$probe_timeout_normalized" ]; then
  echo "mergepath cloud session: MERGEPATH_CLOUD_PROBE_TIMEOUT must be a positive whole number below 120; using $probe_timeout."
fi

probe_elapsed=$((SECONDS - hook_started))
probe_remaining=$((120 - probe_elapsed - 5))
if [ -n "$timeout_bin" ] && [ "$probe_remaining" -gt 0 ]; then
  [ "$probe_timeout" -le "$probe_remaining" ] || probe_timeout="$probe_remaining"
  result="$("$timeout_bin" "$probe_timeout" "$PROBE" --quiet 2>/dev/null)" || result=""
elif [ -n "$timeout_bin" ]; then
  result=""
else
  result="$("$PROBE" --quiet 2>/dev/null)" || result=""
fi
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
