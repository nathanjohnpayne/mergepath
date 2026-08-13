#!/usr/bin/env bash
# scripts/coderabbit-automerge-rate-limit-gate.sh
#
# #489: decide whether a CodeRabbit rate-limit stall (coderabbit-wait.sh
# exit 5 / status=rate_limit_stalled) should BLOCK the auto-merge workflow
# (.github/workflows/agent-review.yml "Wait for CodeRabbit" step) or is a
# NON-BLOCKING note because the Codex failover engaged.
#
# The failover must ALWAYS have engaged to PROCEED (downgrade exit 5):
#
#   1. The Codex failover engaged — coderabbit-wait.sh's JSON reports
#      `codex_failover_requested: true` (it requested `@codex review`).
#
# On top of that, the head needs bot-review protection, satisfied by EITHER:
#
#   2a. External-review protection for this head — either an active
#       merge-clearance external gate will hold the merge until Codex /
#       external clearance lands, or current-head Codex/Phase-4b clearance
#       is already satisfied. (Passed in as the second arg.)
#   2b. #825: positive proof that the failover's Codex review has actually
#       CLEARED the current head — `codex-review-check.sh` returning 0 with
#       gate (b) HEAD-pinned and the Phase-4b substitute DISALLOWED, waited
#       for up to the clearance budget below. This is the same positive-proof
#       route #713 uses, applied to the PR class 2a can never cover.
#
# Why some form of condition 2 (Codex P2 on #512 round 3): for UNDER-threshold
# PRs the merge-clearance gate passes *vacuously* (no Codex requirement), and
# the failover only *requests* Codex via `--trigger-only` (it does not wait for
# a review). So downgrading exit 5 on the strength of the stall alone would let
# a rate-limited PR auto-merge with NEITHER CodeRabbit nor Codex having read the
# diff. That hole stays closed: 2b does not weaken the bar, it *verifies* it.
#
# Why 2b exists (#825): 2a is false for every under-threshold PR by
# construction — `--derive-rate-limit-protection` returns false as soon as
# external review does not apply — so the composition "CodeRabbit rate-limited
# + under-threshold PR" deadlocked auto-merge deterministically, and the red
# check tripped `gh-pr-guard.sh` into demanding a break-glass for an otherwise
# green, approved PR. Waiting longer for CodeRabbit cannot fix it (observed Fair
# Usage windows of 2109s/2398s against a 1245s ceiling), and the workflow's
# pre-wait #727 probe answers before the failover has even posted, so it always
# reads "no clearance". 2b re-asks AFTER the failover, giving the review it
# requested a bounded chance to land, and proceeds only on a real verdict.
#
# Usage:
#   coderabbit-automerge-rate-limit-gate.sh '<coderabbit-wait-json>' \
#     <external-review-protected> [PR_NUMBER] [REPO]
#
#     external-review-protected: "true" if the auto-merge workflow proved
#       either active downstream gate protection or already-satisfied
#       current-head external clearance. Anything else falls through to 2b.
#     PR_NUMBER / REPO: required for 2b. Omit them (the pre-#825 two-arg form)
#       and an unprotected head simply blocks, as it did before.
#
# Environment:
#   CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN
#       Path to codex-review-check.sh. Defaults to the sibling script next to
#       this one. Tests override it with a stub so the 2b dispatch and exit-code
#       mapping are exercised without re-deriving codex-review-check's behavior
#       (same seam as MERGE_CLEARANCE_CODEX_CHECK_BIN).
#   CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_WAIT_SECONDS
#       Total 2b budget in seconds. Default 840, matching the canonical
#       `codex.review_timeout_seconds` — how long a Codex review is expected to
#       take. 0 probes exactly once and never sleeps. The budget is spent on the
#       Codex verdict the failover just asked for, in place of the CodeRabbit
#       wait the rate limit already made unwinnable.
#   CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_POLL_SECONDS
#       Interval between 2b probes. Default 30.
#
# The checker inherits this process's working directory (the repo checkout) and
# GH_TOKEN, because it reads `.github/review-policy.yml` and the GitHub API.
#
# Exit 0 = PROCEED; exit 1 = BLOCK. Fail-closed everywhere: a missing flag,
# unparseable JSON, a missing/garbled PR or repo, an absent checker, a
# non-integer budget, or any checker exit other than 0/1 BLOCKS, so no
# malformed input silently lets a rate-limited PR through.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WAIT_JSON="${1:-}"
EXTERNAL_REVIEW_PROTECTED="${2:-false}"
PR_NUMBER="${3:-}"
REPO="${4:-}"

CODEX_CHECK_BIN="${CODERABBIT_RATE_LIMIT_GATE_CODEX_CHECK_BIN:-$SCRIPT_DIR/codex-review-check.sh}"
CLEARANCE_WAIT_SECONDS="${CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_WAIT_SECONDS:-840}"
CLEARANCE_POLL_SECONDS="${CODERABBIT_RATE_LIMIT_GATE_CLEARANCE_POLL_SECONDS:-30}"

# Arm 2b (#825): wait, bounded, for the failover's Codex review to clear the
# CURRENT head, and report whether it did. Echoes diagnostics to stderr (the
# step log); prints nothing to stdout. Returns 0 = cleared, 1 = not cleared.
#
# The probe is codex-review-check.sh under exactly the environment the #727
# post-clearance probe and the workflow's final re-verify already use:
#   SKIP_CI=1                     — CI greenness is a separate gate here.
#   REQUIRE_APPROVAL_ON_HEAD=1    — a stale earlier-head APPROVED cannot ride
#                                   a later push into clearance (#435).
#   ALLOW_PHASE_4B_SUBSTITUTE=false — LOAD-BEARING (#727, Codex P2 on #729):
#                                   without it gate (c) accepts the very
#                                   reviewer APPROVED that armed auto-merge as
#                                   a Phase-4b substitute, so an under-threshold
#                                   PR with NO bot review would "prove"
#                                   clearance and reopen the #512 r3 hole. With
#                                   it, clearance requires an actual Codex bot
#                                   signal (👍 / affirmative verdict / clean
#                                   review) anchored to this head.
# The checker resolves the LIVE head on every probe, so a push during the wait
# re-pins the question to the new head rather than clearing the old one; the
# workflow's final re-verify independently aborts on head drift.
await_codex_head_clearance() {
  local start now elapsed remaining sleep_for crc attempt=0

  if ! printf '%s' "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
    echo "rate-limit-gate: no usable PR number for the #825 Codex-clearance probe (got '${PR_NUMBER}') — block (fail-closed)" >&2
    return 1
  fi
  if ! printf '%s' "$REPO" | grep -qE '^[^/[:space:]]+/[^/[:space:]]+$'; then
    echo "rate-limit-gate: no usable owner/repo for the #825 Codex-clearance probe (got '${REPO}') — block (fail-closed)" >&2
    return 1
  fi
  if [ ! -f "$CODEX_CHECK_BIN" ]; then
    echo "rate-limit-gate: codex-review-check.sh not found at $CODEX_CHECK_BIN — cannot prove current-head Codex clearance; block (fail-closed)" >&2
    return 1
  fi
  if ! printf '%s' "$CLEARANCE_WAIT_SECONDS" | grep -qE '^[0-9]+$' \
    || ! printf '%s' "$CLEARANCE_POLL_SECONDS" | grep -qE '^[0-9]+$'; then
    echo "rate-limit-gate: clearance wait/poll budget must be non-negative integers (wait='${CLEARANCE_WAIT_SECONDS}' poll='${CLEARANCE_POLL_SECONDS}') — block (fail-closed)" >&2
    return 1
  fi

  echo "rate-limit-gate: unprotected head — waiting up to ${CLEARANCE_WAIT_SECONDS}s for the failover's Codex review to clear PR #${PR_NUMBER} on its current head (#825)" >&2
  start=$(date +%s)
  while :; do
    attempt=$((attempt + 1))
    set +e
    CODEX_REVIEW_CHECK_SKIP_CI=1 \
      CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 \
      CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE=false \
      bash "$CODEX_CHECK_BIN" "$PR_NUMBER" "$REPO" >&2
    crc=$?
    set -e
    case "$crc" in
      0)
        echo "rate-limit-gate: current-head Codex/Phase-4b clearance confirmed on probe ${attempt} — the failover really did review this head (#825)" >&2
        return 0
        ;;
      1) ;;
      *)
        # codex-review-check.sh's contract is 0 clear / 1 gate-fail / 3 infra.
        # Anything else is a config or infrastructure fault, which retrying
        # will not repair — and an unproven answer must never read as proof.
        echo "rate-limit-gate: codex-review-check.sh returned rc=${crc} (config/infrastructure error) on probe ${attempt} — clearance unproven; block (fail-closed)" >&2
        return 1
        ;;
    esac
    now=$(date +%s)
    elapsed=$((now - start))
    remaining=$((CLEARANCE_WAIT_SECONDS - elapsed))
    if [ "$remaining" -le 0 ]; then
      break
    fi
    sleep_for=$CLEARANCE_POLL_SECONDS
    if [ "$sleep_for" -gt "$remaining" ]; then sleep_for=$remaining; fi
    if [ "$sleep_for" -le 0 ]; then break; fi
    echo "rate-limit-gate: no Codex clearance on the current head yet (probe ${attempt}, ${elapsed}s elapsed of ${CLEARANCE_WAIT_SECONDS}s); sleeping ${sleep_for}s" >&2
    sleep "$sleep_for"
  done
  echo "rate-limit-gate: no current-head Codex clearance within ${CLEARANCE_WAIT_SECONDS}s (${attempt} probes) — block (fail-closed)" >&2
  return 1
}

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
  # Arm 2b (#825). Arm 2a is unreachable for under-threshold PRs, so ask the
  # only question that can still protect this head: did the review the failover
  # requested actually clear it? Nothing here is inferred — the answer comes
  # from codex-review-check.sh, and every other outcome blocks (#512 r3, #713).
  echo "rate-limit-gate: rate-limit stall + failover engaged but no active or already-satisfied external-review protection (external_review_protected=${EXTERNAL_REVIEW_PROTECTED}) — seeking current-head Codex clearance instead (#825)" >&2
  if await_codex_head_clearance; then
    echo "rate-limit-gate: rate-limit stall + failover engaged + the failover's Codex review cleared this head — proceed (#825)" >&2
    exit 0
  fi
  echo "rate-limit-gate: rate-limit stall + failover engaged, no external-review protection and no current-head Codex clearance — block (#512 r3, #713, #825)" >&2
  exit 1
fi

echo "rate-limit-gate: rate-limit stall + failover engaged + external-review protection present — proceed" >&2
exit 0
