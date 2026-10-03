#!/usr/bin/env bash
# Local Cockpit shell. Only an already-warm credential cache is consumed.
set +x
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COCKPIT_AGENT=codex
COCKPIT_PORT=0

usage() {
  echo "usage: cockpit.sh [--agent codex|claude|cursor] [--port 0..65535]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) [ "$#" -ge 2 ] || usage; COCKPIT_AGENT=$2; shift 2 ;;
    --port) [ "$#" -ge 2 ] || usage; COCKPIT_PORT=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
case "$COCKPIT_AGENT" in codex|claude|cursor) ;; *) usage ;; esac
[[ "$COCKPIT_PORT" =~ ^[0-9]{1,5}$ ]] || usage
[ "$((10#$COCKPIT_PORT))" -le 65535 ] || usage

# Capture before eval: command substitution's failure must not get swallowed.
# --check never invokes op or repairs the cache. Do not add a warming fallback.
if ! cockpit_exports=$("$ROOT/scripts/op-preflight.sh" --agent "$COCKPIT_AGENT" --check --print-exports); then
  unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT
  echo "Cockpit launch refused: the credential cache is unavailable. Complete the normal preflight before launching." >&2
  exit 1
fi
if ! eval "$cockpit_exports" || [ -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]; then
  unset cockpit_exports OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT
  echo "Cockpit launch refused: no cached reviewer credential." >&2
  exit 1
fi
unset cockpit_exports OP_PREFLIGHT_AUTHOR_PAT GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
cd "$ROOT"
exec python3 -I "$ROOT/mergepath/cockpit/__main__.py" --port "$COCKPIT_PORT"
