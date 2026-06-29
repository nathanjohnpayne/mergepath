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
#   2. An external-review gate will ACTUALLY gate the merge on Codex —
#      i.e. the PR is ABOVE the external-review threshold, where
#      merge-clearance-gate.sh's external_review_gate blocks until Codex /
#      external clearance lands. (Passed in as the second arg.)
#
# Why condition 2 (Codex P2 on #512 round 3): for UNDER-threshold PRs the
# merge-clearance gate passes *vacuously* (no Codex requirement), and the
# failover only *requests* Codex via `--trigger-only` (it does not wait for a
# review). So downgrading exit 5 on an under-threshold PR would let a
# rate-limited PR auto-merge with NEITHER CodeRabbit nor Codex having reviewed
# it. Under-threshold rate-limit stalls therefore keep BLOCKING, exactly as
# before this feature. Above-threshold PRs are safe to proceed because the
# external-review gate still blocks the merge until Codex/external clears.
#
# Usage:
#   coderabbit-automerge-rate-limit-gate.sh '<coderabbit-wait-json>' <external-review-required>
#
#     external-review-required: "true" if the PR is above the external-review
#       threshold (the workflow derives this from the `needs-external-review`
#       label). Anything other than "true" is treated as under-threshold.
#
# Exit 0 = PROCEED; exit 1 = BLOCK. Fail-closed: a missing flag, missing
# threshold arg, or unparseable JSON BLOCKS, so a malformed input never
# silently lets a rate-limited PR through.

set -euo pipefail

WAIT_JSON="${1:-}"
EXTERNAL_REVIEW_REQUIRED="${2:-false}"

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

if [ "$EXTERNAL_REVIEW_REQUIRED" != "true" ]; then
  echo "rate-limit-gate: rate-limit stall + failover engaged but PR is under-threshold (external_review_required=${EXTERNAL_REVIEW_REQUIRED}) — no downstream Codex gate; block (#512 r3)" >&2
  exit 1
fi

echo "rate-limit-gate: rate-limit stall + failover engaged + external review required — merge-clearance gates Codex; proceed" >&2
exit 0
