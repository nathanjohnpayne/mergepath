#!/usr/bin/env bash
# scripts/lib/codex-failure-markers.sh — single source of truth for the
# Codex App account-/connection-level failure-marker regexes (#722).
#
# The ChatGPT Codex Connector GitHub App answers a `@codex review` trigger
# with a plain PR comment — carrying NO findings, NO `Reviewed commit:`
# anchor, and NO reaction — in two failure states the live Phase 4a scripts
# could not previously recognize:
#
#   usage_limit    account-level quota exhaustion for code reviews. Real
#                  wording: "You have reached your Codex usage limits for
#                  code reviews. … upgrade your account or add credits …".
#                  No amount of waiting or re-triggering clears it — a human
#                  must upgrade / add credits.
#   not_connected  the Codex App is not connected / has no environment. Real
#                  wording: "To use Codex here, connect your GitHub account
#                  …". The trigger produced no review round at all (the #570
#                  dropped-trigger class).
#
# Because such a comment matched none of scan_codex_state()'s signal kinds
# (`review` / `reaction` / `verdict` all stay null), codex-review-request.sh
# ran out the full review_timeout_seconds window and exited 4 — the SAME
# exit as a genuinely slow review, with no root-cause context for the agent
# or the Phase 4b handoff (the failure reported in #722).
#
# scripts/audit-codex-latency.sh has detected both retrospectively for a
# while (its normalize phase classifies them as `rate_limit` /
# `dropped_trigger_marker` events), but that detection lived ONLY in the
# retrospective audit. This lib factors the two regexes out so the audit and
# the live scripts (codex-review-request.sh, codex-review-check.sh) test the
# IDENTICAL patterns instead of drifting (#722 proposal 1).
#
# Contract:
#   - CODEX_USAGE_LIMIT_MARKER_RE / CODEX_NOT_CONNECTED_MARKER_RE are the
#     canonical ERE pattern bodies, WITHOUT a leading `(?i)` inline flag and
#     WITHOUT anchors — every caller applies case-insensitivity explicitly
#     (jq `test($re; "i")`, grep `-iE`) and matches the marker wherever it
#     appears in a longer bot comment. Keeping the `(?i)` out of the stored
#     pattern is what lets jq's `test(re; "i")` and grep's `-i` share one
#     literal.
#   - usage_limit is checked BEFORE not_connected (a comment matching both
#     is quota-blocked first), and a caller that also recognizes verdicts
#     MUST classify a verdict comment as a verdict first — a marker is only a
#     marker on a NON-verdict bot comment (mirrors audit-codex-latency.sh's
#     normalize precedence: verdict → rate_limit → dropped_trigger_marker).
#   - codex_failure_marker_of <body> echoes `usage_limit`, `not_connected`,
#     or the empty string, and always returns 0. It does NOT exclude
#     verdicts — verdict precedence is the caller's job (see above).
#
# Sourced by scripts/audit-codex-latency.sh (hub-only) and, existence-
# guarded, by the two propagated live Phase 4a scripts. Sourcing has no side
# effects beyond defining the two vars and the function.

# Rate-limit / usage-limit / quota-exhaustion marker. Mirrors the pattern
# audit-codex-latency.sh's normalize phase has used for its `rate_limit`
# event kind; the alternation is grouped so `test(re; "i")` reads as one
# marker check.
CODEX_USAGE_LIMIT_MARKER_RE='(rate.?limit|usage.?limit|quota|limit (was|has been) (hit|reached)|try again (later|in))'

# Dropped-trigger / app-not-connected marker (#570 class): the Codex App was
# not connected or had no environment, so the trigger produced no round.
CODEX_NOT_CONNECTED_MARKER_RE='to use codex here'

# Classify a single comment body into a Codex failure-marker kind.
# Echoes: usage_limit | not_connected | "" (no marker). Always returns 0 so
# a no-match does not trip a caller's `set -e`.
codex_failure_marker_of() {
  local body=${1-}
  if printf '%s' "$body" | grep -iqE "$CODEX_USAGE_LIMIT_MARKER_RE"; then
    printf 'usage_limit'
  elif printf '%s' "$body" | grep -iqE "$CODEX_NOT_CONNECTED_MARKER_RE"; then
    printf 'not_connected'
  fi
  return 0
}
