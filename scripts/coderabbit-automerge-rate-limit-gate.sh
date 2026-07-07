#!/usr/bin/env bash
# scripts/coderabbit-automerge-rate-limit-gate.sh
#
# #489: decide whether a CodeRabbit rate-limit stall (coderabbit-wait.sh
# exit 5 / status=rate_limit_stalled) should BLOCK the auto-merge workflow
# (.github/workflows/agent-review.yml "Wait for CodeRabbit" step) or is a
# NON-BLOCKING note because the Codex failover engaged.
#
# Two conditions must BOTH hold to PROCEED (downgrade exit 5):
#
#   1. The Codex failover engaged — coderabbit-wait.sh's JSON reports
#      `codex_failover_requested: true` (it requested `@codex review`).
#   2. External-review protection exists for this head — either an active
#      merge-clearance external gate will hold the merge until Codex /
#      external clearance lands, or current-head Codex/Phase-4b clearance
#      is already satisfied. (Passed in as the second arg.)
#
# Why condition 2 (Codex P2 on #512 round 3): for UNDER-threshold PRs the
# merge-clearance gate passes *vacuously* (no Codex requirement), and the
# failover only *requests* Codex via `--trigger-only` (it does not wait for a
# review). So downgrading exit 5 on an under-threshold PR would let a
# rate-limited PR auto-merge with NEITHER CodeRabbit nor Codex having reviewed
# it. Under-threshold rate-limit stalls therefore keep BLOCKING, exactly as
# before this feature. Above-threshold/protected-path PRs are safe to
# proceed only when the external-review gate is active or the stronger
# external review has already cleared on this head (#713).
#
# Usage:
#   coderabbit-automerge-rate-limit-gate.sh '<coderabbit-wait-json>' <external-review-protected>
#
#     external-review-protected: "true" if the auto-merge workflow proved
#       either active downstream gate protection or already-satisfied
#       current-head external clearance. Anything else blocks.
#
# Exit 0 = PROCEED; exit 1 = BLOCK. Fail-closed: a missing flag, missing
# protection arg, or unparseable JSON BLOCKS, so a malformed input never
# silently lets a rate-limited PR through.

set -euo pipefail

WAIT_JSON="${1:-}"
EXTERNAL_REVIEW_PROTECTED="${2:-false}"

if [ -z "$WAIT_JSON" ]; then
  echo "rate-limit-gate: no coderabbit-wait JSON provided — blocking (fail-closed)" >&2
  exit 1
fi

# Gate 0: only downgrade an actual rate_limit_stalled status. A cleared or
# timeout status with codex_failover_requested: true must NOT proceed —
# the gate is exclusively for the exit-5 rate-limit-stalled path.
status=$(printf '%s' "$WAIT_JSON" | jq -r '.status // ""' 2>/dev/null || echo "")
if [ "$status" != "rate_limit_stalled" ]; then
  echo "rate-limit-gate: status=${status} (expected rate_limit_stalled) — block (fail-closed)" >&2
  exit 1
fi

# Gate 1: require a real JSON boolean true (not a string "true"). jq -e exits
# non-zero when the selected value is false or null, so a string "true" or an
# absent field produces a non-zero exit and we block.
if ! printf '%s' "$WAIT_JSON" | jq -e '.codex_failover_requested == true' >/dev/null 2>&1; then
  echo "rate-limit-gate: codex_failover_requested is not JSON boolean true — no failover engaged; block" >&2
  exit 1
fi

if [ "$EXTERNAL_REVIEW_PROTECTED" != "true" ]; then
  echo "rate-limit-gate: rate-limit stall + failover engaged but no active or already-satisfied external-review protection (external_review_protected=${EXTERNAL_REVIEW_PROTECTED}) — block (#512 r3, #713)" >&2
  exit 1
fi

echo "rate-limit-gate: rate-limit stall + failover engaged + external-review protection present — proceed" >&2
exit 0
