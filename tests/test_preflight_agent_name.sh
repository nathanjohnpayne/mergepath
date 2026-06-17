#!/usr/bin/env bash
# Regression coverage for preflight_agent() agent-name validation (#466).
#
# An unsafe MERGEPATH_AGENT / OP_PREFLIGHT_AGENT (path traversal or shell
# metacharacters) must never reach the cache-file path builder, which
# auto_source_preflight then SOURCES. An invalid name is treated as "no
# agent" (empty) so auto-source fails closed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/preflight-helpers.sh
. "$ROOT/scripts/lib/preflight-helpers.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Resolve preflight_agent for a given MERGEPATH_AGENT value, with an empty
# scratch cache dir so the single-file fallback can't interfere. The lib is
# already sourced, so the subshell inherits preflight_agent.
agent_for() {
  local val="$1" tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/pf-agent.XXXXXX")"
  ( unset OP_PREFLIGHT_AGENT
    export MERGEPATH_AGENT="$val" OP_PREFLIGHT_CACHE_DIR="$tmp"
    preflight_agent ) 2>/dev/null
  rm -rf "$tmp"
}

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label: got '$got' want '$want'"; fi
}

assert_eq "safe agent 'claude' passes"        "$(agent_for claude)"            "claude"
assert_eq "safe dash/underscore passes"       "$(agent_for my-agent_1)"        "my-agent_1"
assert_eq "path traversal rejected"           "$(agent_for '../../etc/evil')"  ""
assert_eq "bare slash rejected"               "$(agent_for 'a/b')"             ""
assert_eq "semicolon rejected"                "$(agent_for 'x;rm -rf')"        ""
assert_eq "space rejected"                    "$(agent_for 'a b')"             ""
assert_eq "command-substitution char rejected" "$(agent_for 'a$(id)')"         ""

echo ""
echo "test_preflight_agent_name: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
