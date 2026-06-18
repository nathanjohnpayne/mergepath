#!/usr/bin/env bash
# scripts/coderabbit-automerge-rate-limit-gate.sh
#
# #489: decide whether a CodeRabbit rate-limit stall (coderabbit-wait.sh
# exit 5 / status=rate_limit_stalled) should BLOCK the auto-merge workflow
# (.github/workflows/agent-review.yml "Wait for CodeRabbit" step) or is a
# NON-BLOCKING note because the Codex failover engaged.
#
# Contract: a stall is non-blocking IFF coderabbit-wait.sh's JSON reports
# `codex_failover_requested: true` — meaning the failover requested
# `@codex review`, so the PR advances via Codex (the real blocking gate) and
# the downstream `Codex P1 unresolved threads` / `Merge clearance gate` carry
# the merge. A stall with no failover (knob off, or codex.enabled:false, so
# there is nothing to fail over to) still hard-blocks.
#
# Usage:
#   coderabbit-automerge-rate-limit-gate.sh '<coderabbit-wait-json>'
#
# Exit 0 = PROCEED (failover engaged); exit 1 = BLOCK (no failover).
# Fail-closed: a missing flag or unparseable JSON BLOCKS (exit 1), so a
# malformed helper output never silently lets a rate-limited PR through.

set -euo pipefail

WAIT_JSON="${1:-}"

if [ -z "$WAIT_JSON" ]; then
  echo "rate-limit-gate: no coderabbit-wait JSON provided — blocking (fail-closed)" >&2
  exit 1
fi

failover=$(printf '%s' "$WAIT_JSON" | jq -r '.codex_failover_requested // false' 2>/dev/null || echo "false")

if [ "$failover" = "true" ]; then
  echo "rate-limit-gate: codex_failover_requested=true — Codex failover engaged; proceed" >&2
  exit 0
fi

echo "rate-limit-gate: codex_failover_requested=${failover} — no failover; block" >&2
exit 1
