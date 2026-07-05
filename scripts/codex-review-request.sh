#!/usr/bin/env bash
# scripts/codex-review-request.sh — Phase 4a automated external review trigger
#
# Triggers (or awaits) a review from the ChatGPT Codex Connector GitHub App
# on a pull request, polls for a response against the current HEAD commit,
# and emits a machine-parseable JSON summary of what Codex produced so a
# caller (e.g. an authoring agent) can reason over it.
#
# Usage:
#   scripts/codex-review-request.sh <PR_NUMBER> [REPO]
#
# Arguments:
#   PR_NUMBER  Required. The pull request number (integer).
#   REPO       Optional. Fully-qualified "owner/repo". Defaults to the
#              current repository detected by `gh repo view`.
#
# Environment:
#   GH_TOKEN                   Required for the read/polling calls. The
#                              load-bearing trigger comment is posted
#                              through gh-as-author.sh, which verifies and
#                              uses the author token for that write.
#   MERGEPATH_PHASE_4A_GATED   Optional. Set to true/1 by the caller when
#                              the PR independently qualifies for Phase 4a
#                              (lines >= external_review_threshold OR a file
#                              matches external_review_paths). Only consulted
#                              when codex.request_by_default is false; lets
#                              the threshold-gated PR still get a trigger
#                              under the pre-#486 behavior. Unset/false ⇒ the
#                              PR is treated as under-threshold.
#
# IMPORTANT: a plain push (`synchronize`) never re-triggers a Codex review —
# the Codex GitHub App reviews only on PR-open, ready-for-review, or an
# explicit `@codex review` comment. Every fix-push must re-run this script
# (or otherwise re-post the trigger) to re-arm HEAD-anchored clearance;
# nothing does it automatically, and a stale prior-HEAD verdict does not
# satisfy the merge gate (#631).
#
# Behavior:
#   0. Reads codex.enabled (default true) and codex.request_by_default
#      (default true, #486) and decides whether to request a Codex review
#      at all (the Phase 4a entry decision). When codex.enabled is false,
#      Phase 4a is off and the script exits 5 without triggering. When
#      request_by_default is true, the trigger is posted on EVERY PR; when
#      false, only on a PR the caller flagged via MERGEPATH_PHASE_4A_GATED.
#      request_by_default is orthogonal to enabled — it governs only WHEN
#      the trigger is posted, never WHETHER Codex participates.
#   1. Reads codex.review_timeout_seconds, codex.ack_wait_seconds,
#      codex.max_ack_retries, and codex.bot_login from
#      .github/review-policy.yml (defaults: 840 / 30 / 1 /
#      chatgpt-codex-connector[bot]; the 840s review_timeout and 30s
#      ack_wait are measured retunes — see #623 and the per-constant
#      comments below).
#   2. Fetches the PR's current HEAD commit SHA and committer date. Any
#      Codex review is only considered "current" if it is anchored on
#      this commit (commit_id == HEAD_SHA). Any Codex +1 reaction is
#      only considered "current" if created_at >= REACTION_THRESHOLD,
#      where REACTION_THRESHOLD = max(HEAD_PUSHED_AT, freshness floor):
#        - HEAD_PUSHED_AT is HEAD_COMMITTER_DATE advanced past any
#          `head_ref_force_pushed` event on this PR's timeline, which
#          is strictly PR-scoped. This closes the force-push-with-
#          old-commit false-clear path.
#        - freshness floor = NOW minus
#          `codex.reaction_freshness_window_seconds` (default 1800).
#          This closes the ordinary-push-with-old-committer-date
#          false-clear path by ensuring a stale 👍 from a prior HEAD
#          ages out of the window.
#      See codex-review-check.sh for the iteration history behind this
#      design and the residual hole it does NOT fully close.
#   3. Scans existing reviews, inline comments, issue reactions, and issue
#      comments (for a HEAD-anchored verdict, #609) for a Codex signal
#      already present on the current HEAD. If found, skips the trigger
#      comment and goes straight to emitting JSON — re-posting `@codex
#      review` when Codex has already responded can cause double-processing
#      or rate-limit pushback.
#   4. Otherwise posts `@codex review` as a PR comment, waits a short
#      bounded window for Codex's documented `eyes` acknowledgment on
#      that trigger comment, and re-posts the trigger up to
#      `max_ack_retries` if no acknowledgment appears. The eyes
#      acknowledgment is never treated as clearance.
#   5. Polls every 15 seconds for up to `review_timeout_seconds`
#      measured from the latest trigger comment, while accepting a
#      terminal response to any trigger posted in this run, for any of:
#        - a review from the Codex bot on the current HEAD, OR
#        - a +1 reaction from the Codex bot on the PR issue dated after
#          the current HEAD committer date, OR
#        - a HEAD-anchored Codex issue-comment verdict ("Codex Review:
#          Didn't find any major issues" + "Reviewed commit: <sha>") of
#          EITHER disposition — a non-affirmative verdict still ends the
#          poll (it is a real response), it just does not clear (#609).
#   6. Emits a JSON object to stdout summarizing what Codex produced.
#      The JSON shape is the contract with the caller; do not change
#      field names without also updating scripts/codex-review-check.sh
#      and the policy docs (CLAUDE.md, AGENTS.md, REVIEW_POLICY.md).
#
# Output JSON shape:
#   {
#     "pr_number": 123,
#     "repo": "owner/repo",
#     "head_sha": "<full sha>",
#     "head_committer_date": "<iso-8601>",
#     "bot_login": "chatgpt-codex-connector[bot]",
#     "review": null | {
#       "state": "COMMENTED",
#       "submitted_at": "<iso-8601>",
#       "commit_id": "<full sha>",
#       "body": "<top-level review body>"
#     },
#     "findings": [
#       { "path": "...", "line": N, "priority": "P0|P1|P2|P3",
#         "comment_id": N, "body": "<full finding body>",
#         "blocking": true|false }
#     ],
#     # `blocking` (#577) is derived from the resolved feedback_policy
#     # required-tier set (scripts/lib/feedback-policy-helpers.sh
#     # resolve_required_tiers) — true iff this finding's tier is one the
#     # codex-p1-gate would block merge on. Absent feedback_policy block ⇒
#     # only P1 is blocking. An unmarked (P?) finding is never blocking.
#     "reaction": null | {
#       "content": "+1",
#       "created_at": "<iso-8601>",
#       "reaction_id": N
#     },
#     "verdict": null | {
#       "created_at": "<iso-8601>",
#       "affirmative": true | false
#     },
#     # HEAD-anchored Codex issue-comment verdict (#600/#567), recognized by
#     # this poller as of #609. "affirmative" mirrors codex-review-check.sh's
#     # CODEX_HEAD_VERDICT_TIME matcher: true only for the stable "Codex
#     # Review: Didn't find any major issues" phrasing. A non-null,
#     # non-affirmative verdict is still a real Codex response (has_signal
#     # true) but does not clear (has_cleared_signal false) — fails closed.
#     "trigger_posted": true | false,
#     "trigger_requested": true | false,
#     "rounds_waited_seconds": N
#   }
#
# Exit codes:
#   0   Codex signal received on current HEAD. JSON on stdout.
#   3   API / infrastructure error. Error message on stderr.
#   4   FALLBACK_REQUIRED — timed out waiting for a Codex signal. The
#       caller should route to REVIEW_POLICY.md § Phase 4b. See #27 for
#       the explicit-review-required decision that mandates this path.
#   5   NO_TRIGGER_REQUESTED — the Phase 4a entry decision (#486) chose
#       NOT to request a Codex review on this PR: either codex.enabled is
#       false (route to Phase 4b), or codex.request_by_default is false
#       and the PR is not Phase-4a-gated (under-threshold, no protected
#       path). JSON on stdout with trigger_requested:false and all Codex
#       signals null. This is a deliberate skip, not an error or a
#       timeout.
#
# Design notes:
#   - Read-only against the PR except for the one `@codex review` trigger
#     comment. Does not push commits, does not modify labels, does not
#     merge.
#   - Idempotent. Re-running on the same PR with the same HEAD is safe:
#     it will see the existing Codex response and skip the trigger.
#   - JSON emission uses `jq` throughout. No ad-hoc string concatenation.
#
# References:
#   - Project #2 — External Review (Phase 4 Review)
#   - #34 — this script
#   - #29 — live observations behind the dual-endpoint / reaction polling
#   - #419 — eyes acknowledgment gate + bounded re-trigger
#   - REVIEW_POLICY.md § Phase 4a (canonical policy)

set -euo pipefail

# --- preflight auto-source (#282) ------------------------------------------
# Auto-source the op-preflight cache when GH_TOKEN is unset and a fresh
# cache exists for this agent. No-op when GH_TOKEN is already set.
__CODEX_REQUEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$__CODEX_REQUEST_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__CODEX_REQUEST_DIR/lib/preflight-helpers.sh"
  # Author PAT is correct for this helper because the one write it may
  # perform is the `@codex review` trigger, which must be authored by
  # nathanjohnpayne. The wrapper verifies that token before posting.
  preflight_require_token author || true
fi

# --- argument parsing -------------------------------------------------------

# #489: --trigger-only posts (or confirms) the @codex review trigger and
# returns WITHOUT polling for clearance. coderabbit-wait.sh's rate-limit
# failover uses it so a rate-limited PR advances via Codex without the wait
# helper blocking on Codex's full review. Extract the flag, leave positionals.
TRIGGER_ONLY=false
__POSITIONAL=()
for __arg in "$@"; do
  case "$__arg" in
    --trigger-only) TRIGGER_ONLY=true ;;
    *) __POSITIONAL+=("$__arg") ;;
  esac
done
set -- ${__POSITIONAL[@]+"${__POSITIONAL[@]}"}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 [--trigger-only] <PR_NUMBER> [REPO]" >&2
  echo "  --trigger-only  post/confirm the @codex trigger, then exit 0 (no clearance poll)" >&2
  echo "  PR_NUMBER       pull request number (integer)" >&2
  echo "  REPO            owner/repo (optional; defaults to current repo)" >&2
  exit 3
fi

PR_NUMBER=$1
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: PR_NUMBER must be an integer; got '$PR_NUMBER'" >&2
  exit 3
fi

REPO=${2:-}
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  if [ -z "$REPO" ]; then
    echo "ERROR: could not detect current repo via 'gh repo view'. Pass REPO explicitly." >&2
    exit 3
  fi
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN is required. Either:" >&2
  echo "  - Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode review)\"" >&2
  echo "    so this helper auto-sources OP_PREFLIGHT_AUTHOR_PAT, OR" >&2
  echo "  - Set GH_TOKEN inline per REVIEW_POLICY.md § PAT lookup table." >&2
  exit 3
fi

# --- config readers ---------------------------------------------------------

CONFIG=".github/review-policy.yml"

# Extract a scalar field from the codex: block in review-policy.yml.
# Uses the state-machine awk pattern established in #54 (stops at the next
# top-level key, tolerates column-0 comments). Returns empty string if the
# field is not present, which the caller should turn into a default.
codex_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^codex:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block {
      # Match "  field: value" or a value wrapped in double OR single
      # quotes. Strip BOTH quote styles (\047 = single quote) so a
      # single-quoted boolean (valid YAML) survives the == "true"
      # entry-gate checks below. Matches the quote-tolerance of the
      # codex_field parser in scripts/codex-review-check.sh and the
      # workflow parser tests.
      if ($1 == field":") {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
        gsub(/^["\047]/, "", $0)
        gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
        gsub(/[[:space:]]*#.*$/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        print
        exit
      }
    }
  ' "$CONFIG"
}

# Extract a top-level scalar (column-0 key, no enclosing block) from
# review-policy.yml — e.g. author_identity. Same quoting/comment
# tolerance as codex_field.
policy_top_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^[^[:space:]#]/ && $1 == field":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      # Both YAML quote styles (Codex P2 on PR #442 r9) — matching the
      # quote-tolerance of the gh-pr-guard expected-author parser.
      gsub(/^["\x27]/, "", $0)
      gsub(/["\x27][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

# Author identity for the trigger comment write (#438): used to decide
# whether an ambient GH_TOKEN may be bridged into gh-as-author.sh.
AUTHOR_IDENTITY=$(policy_top_field author_identity)
AUTHOR_IDENTITY=${AUTHOR_IDENTITY:-nathanjohnpayne}

# review_timeout_seconds: foreground poll budget for a Codex terminal signal
# on HEAD. Default 840s is measured, not folklore (#623): the trigger→verdict
# distribution is p50 217s / p90 426s / p99 630s / max 830s (n=100), and the
# 👍-clearance endpoint this poll also breaks on is p99 829s (n=60, #646) —
# both from the committed extract docs/audits/data/codex-latency-2026-07/. The
# prior 600s sat BELOW p99(verdict)=630s, so the slowest ~1% of clean rounds
# (and the 830s max) timed out and routed to Phase 4b needlessly. 840s
# (= 56 × the 15s POLL_INTERVAL, so the final poll lands exactly on the
# deadline) covers the full observed clean-verdict tail and stays under the
# 900s phase-4b adapter ceiling. It is deliberately NOT sized to the
# dropped/rate-limited non-response tail (~19–21% of triggers, #570): that is
# not a slow verdict and no foreground wait can catch it — --trigger-only +
# event-driven pickup remains its escape path (#489).
TIMEOUT_SECONDS=$(codex_field review_timeout_seconds)
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-840}
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.review_timeout_seconds must be an integer; got '$TIMEOUT_SECONDS'" >&2
  exit 3
fi

BOT_LOGIN=$(codex_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"chatgpt-codex-connector[bot]"}

# --- blocking-tier surfacing (#577) -----------------------------------------
# Source the shared feedback-policy resolver so each emitted finding can
# carry `blocking: true|false` derived from the SAME resolve_required_tiers
# the codex-p1-gate uses. This is purely additive to the JSON contract — it
# never changes the exit-code behavior below. Absent feedback_policy block
# ⇒ blocking set {p1}, so only P1 findings are marked blocking (today's
# de-facto gate scope). rc 2 = malformed; a benign non-2 tail status (rc 1
# when the last tier isn't required) is ignored, mirroring codex-p1-gate.sh.
#
# The source is GUARDED (same posture as the preflight-helpers source
# above): in some test harnesses this script is copied to a scratch tree
# WITHOUT scripts/lib, so we degrade to the documented absent-block default
# ({p1}) rather than hard-erroring — surfacing is a best-effort convenience,
# not a merge gate. The gate scripts (codex-p1-gate.sh) always run from the
# full checkout and DO source the lib unconditionally.
__CODEX_REQ_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRED_TIERS_JSON='["p1"]'
if [ -r "$__CODEX_REQ_LIBDIR/lib/feedback-policy-helpers.sh" ]; then
  # shellcheck source=lib/feedback-policy-helpers.sh
  . "$__CODEX_REQ_LIBDIR/lib/feedback-policy-helpers.sh"
  set +e
  __REQUIRED_TIERS=$(resolve_required_tiers "$CONFIG")
  __RT_RC=$?
  set -e
  if [ "$__RT_RC" -eq 2 ]; then
    echo "ERROR: malformed feedback_policy block in $CONFIG (resolve_required_tiers exit 2)" >&2
    exit 3
  fi
  # JSON array of required tiers (lowercase p0..p3|nitpick) for jq
  # membership tests. Empty input ⇒ [].
  REQUIRED_TIERS_JSON=$(printf '%s\n' "$__REQUIRED_TIERS" \
    | jq -R . | jq -s 'map(select(. != ""))')
fi

# --- Phase 4a entry decision (#486) -----------------------------------------
# Two codex: block keys govern whether this run posts an `@codex review`
# trigger at all, BEFORE any of the per-HEAD signal scanning below:
#
#   codex.enabled            — whether Codex participates as a reviewer.
#                              Absent ⇒ true (matches codex-review-check.sh).
#                              When false, Phase 4a is OFF entirely: this
#                              script never triggers, regardless of
#                              request_by_default. The caller routes to
#                              Phase 4b.
#   codex.request_by_default — whether `@codex review` is requested on
#                              EVERY PR, not only the threshold/path-gated
#                              ones. Absent ⇒ true (owner-decided default,
#                              #486 / #483). When false, the trigger is
#                              gated on the caller's Phase 4a entry signal
#                              (MERGEPATH_PHASE_4A_GATED), restoring the
#                              pre-#486 threshold-only behavior.
#
# request_by_default is ORTHOGONAL to enabled: it only governs WHEN the
# trigger is posted and has no effect when Codex is disabled.
#
# MERGEPATH_PHASE_4A_GATED is how the caller (the authoring agent, or a
# workflow) tells this worker that the PR independently qualifies for
# Phase 4a (lines ≥ external_review_threshold OR a file matches
# external_review_paths). Set it to `true`/`1` for a gated PR. This
# script does not recompute the threshold itself — the entry decision
# upstream already did. When unset/false and request_by_default is also
# false, an under-threshold PR is skipped (exit 5, NO_TRIGGER_REQUESTED).
CODEX_ENABLED=$(codex_field enabled)
CODEX_ENABLED=${CODEX_ENABLED:-true}

REQUEST_BY_DEFAULT=$(codex_field request_by_default)
REQUEST_BY_DEFAULT=${REQUEST_BY_DEFAULT:-true}

# Normalize the caller's gate signal to a strict true/false. Accept the
# common truthy spellings; anything else (including unset) is false.
PHASE_4A_GATED=false
case "${MERGEPATH_PHASE_4A_GATED:-}" in
  true|TRUE|True|1|yes|YES) PHASE_4A_GATED=true ;;
esac

# Decide whether to request a Codex review on this PR. Returns 0 (request)
# or 1 (skip). Kept as a function so the decision is testable in one place
# and reads as a single boolean expression at the call site.
should_request_codex() {
  # Codex off ⇒ never trigger (orthogonality rule).
  [ "$CODEX_ENABLED" = "true" ] || return 1
  # request_by_default ⇒ trigger on every PR.
  [ "$REQUEST_BY_DEFAULT" = "true" ] && return 0
  # Otherwise trigger only when the caller flagged the PR as Phase-4a-gated.
  [ "$PHASE_4A_GATED" = "true" ]
}

REACTION_FRESHNESS_SECONDS=$(codex_field reaction_freshness_window_seconds)
REACTION_FRESHNESS_SECONDS=${REACTION_FRESHNESS_SECONDS:-1800}
if ! [[ "$REACTION_FRESHNESS_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.reaction_freshness_window_seconds must be an integer; got '$REACTION_FRESHNESS_SECONDS'" >&2
  exit 3
fi

# ack_wait_seconds: the 👀 eyes-ack window (#419). Default 30s aligned to the
# shipped policy value (#647) from the measured ack latency (#623): healthy
# acks land in p50 9s / p99 13s / max 13s (n=14, the full recorded ack
# corpus), so 30s is ~2.3× p99 — it clears every observed healthy ack with
# margin yet fails over fast on a dropped/rate-limited trigger. The measurement
# sizes the WINDOW; the retry COUNT (max_ack_retries) is unchanged, so the full
# failover budget is 30s × (1 + max_ack_retries) = 60s, halved from the prior
# 60s × 2 = 120s. Was 60s folklore.
ACK_WAIT_SECONDS=$(codex_field ack_wait_seconds)
ACK_WAIT_SECONDS=${ACK_WAIT_SECONDS:-30}
if ! [[ "$ACK_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.ack_wait_seconds must be an integer; got '$ACK_WAIT_SECONDS'" >&2
  exit 3
fi

MAX_ACK_RETRIES=$(codex_field max_ack_retries)
MAX_ACK_RETRIES=${MAX_ACK_RETRIES:-1}
if ! [[ "$MAX_ACK_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.max_ack_retries must be an integer; got '$MAX_ACK_RETRIES'" >&2
  exit 3
fi

POLL_INTERVAL_SECONDS=15
ACK_POLL_INTERVAL_SECONDS=5

# --- logging helpers --------------------------------------------------------

log() {
  echo "[codex-review-request] $*" >&2
}

die() {
  local code=$1
  shift
  echo "[codex-review-request] ERROR: $*" >&2
  exit "$code"
}

# Fetch a paginated GitHub REST API endpoint and return the flattened JSON
# array on stdout. `gh api --paginate` emits one JSON value per page
# concatenated into a single stream — `jq`'s default mode runs the filter
# once per input (per page), which miscounts and misfilters on multi-page
# PRs. Slurp with `-s` collects all inputs into an outer array, then `add`
# concatenates the per-page arrays into one flat array. Defaults to `[]`
# on empty input. Exits 3 on API or parse error.
fetch_api_array() {
  local endpoint=$1
  local label=$2
  local raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || die 3 "failed to fetch $label: $raw"
  echo "$raw" | jq -s 'add // []' 2>/dev/null \
    || die 3 "failed to flatten $label pagination output"
}

# --- Phase 4a entry gate (#486) ---------------------------------------------
# Evaluate the request decision BEFORE any PR fetch / signal scan / trigger
# write. When the decision is "skip", emit a minimal JSON object (same field
# names as the terminal output, all signals null) and exit 5
# (NO_TRIGGER_REQUESTED) so the caller can distinguish "deliberately did not
# request" from a timeout (4) or an API error (3).
if ! should_request_codex; then
  if [ "$CODEX_ENABLED" != "true" ]; then
    log "codex.enabled is false — Phase 4a is off; not requesting a Codex review (route to Phase 4b)"
  else
    log "codex.request_by_default is false and this PR is not Phase-4a-gated (MERGEPATH_PHASE_4A_GATED!=true) — not requesting a Codex review"
  fi
  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg bot_login "$BOT_LOGIN" '
    {
      pr_number: $pr_number,
      repo: $repo,
      head_sha: null,
      head_committer_date: null,
      bot_login: $bot_login,
      review: null,
      findings: [],
      reaction: null,
      verdict: null,
      trigger_posted: false,
      trigger_requested: false,
      rounds_waited_seconds: 0
    }
  '
  exit 5
fi

# --- fetch PR metadata ------------------------------------------------------

log "PR $REPO#$PR_NUMBER — fetching HEAD commit metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) || die 3 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 3 "could not determine HEAD sha for PR #$PR_NUMBER"
fi

# committer date, not author date — reactions are compared against commit
# arrival time at GitHub, not commit authorship
HEAD_COMMITTER_DATE=$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>&1) \
  || die 3 "failed to fetch commit date for $HEAD_SHA: $HEAD_COMMITTER_DATE"

# HEAD_PUSHED_AT + REACTION_THRESHOLD: mirrors codex-review-check.sh so
# that the pre-flight scan below does NOT treat a stale 👍 from a prior
# HEAD as a current signal (which would cause the trigger comment to be
# skipped and the caller to re-run gate (c) against the same stale
# reaction). See codex-review-check.sh for the full rationale; the short
# version: committer date is unreliable for force-push-of-old-commit
# and ordinary-push-of-old-committer-date. Layer 1 advances the anchor
# via `head_ref_force_pushed` events from the PR-scoped timeline; Layer
# 2 bounds residual exposure with a freshness floor.
HEAD_PUSHED_AT="$HEAD_COMMITTER_DATE"
ANCHOR_SOURCE="HEAD committer date"

TIMELINE_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/timeline" "PR timeline")

LATEST_FORCE_PUSH_TIME=$(echo "$TIMELINE_JSON" | jq -r '
  [ .[] | select(.event == "head_ref_force_pushed") | .created_at ]
  | max // ""
')

if [ -n "$LATEST_FORCE_PUSH_TIME" ] && [[ "$LATEST_FORCE_PUSH_TIME" > "$HEAD_PUSHED_AT" ]]; then
  HEAD_PUSHED_AT="$LATEST_FORCE_PUSH_TIME"
  ANCHOR_SOURCE="head_ref_force_pushed @ $LATEST_FORCE_PUSH_TIME"
fi

EPOCH_NOW=$(date +%s)
EPOCH_FLOOR=$((EPOCH_NOW - REACTION_FRESHNESS_SECONDS))
if REACTION_FLOOR_ISO=$(date -u -r "$EPOCH_FLOOR" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  :
else
  REACTION_FLOOR_ISO=$(date -u -d "@$EPOCH_FLOOR" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
    || die 3 "could not compute reaction freshness floor from epoch $EPOCH_FLOOR"
fi

if [[ "$REACTION_FLOOR_ISO" > "$HEAD_PUSHED_AT" ]]; then
  REACTION_THRESHOLD="$REACTION_FLOOR_ISO"
  REACTION_THRESHOLD_SOURCE="freshness floor (NOW - ${REACTION_FRESHNESS_SECONDS}s)"
else
  REACTION_THRESHOLD="$HEAD_PUSHED_AT"
  REACTION_THRESHOLD_SOURCE="HEAD pushed-at anchor ($ANCHOR_SOURCE)"
fi

log "HEAD = $HEAD_SHA committed at $HEAD_COMMITTER_DATE"
log "anchor = $HEAD_PUSHED_AT (source: $ANCHOR_SOURCE)"
log "reaction_threshold = $REACTION_THRESHOLD (source: $REACTION_THRESHOLD_SOURCE)"
log "bot_login = $BOT_LOGIN    timeout = ${TIMEOUT_SECONDS}s"
log "ack_wait = ${ACK_WAIT_SECONDS}s    max_ack_retries = $MAX_ACK_RETRIES"

# --- Codex signal scan ------------------------------------------------------

# Scan for (a) a review from the bot on the current HEAD commit, (b) inline
# findings from the bot on the current HEAD, (c) a +1 reaction on the issue
# dated after the HEAD committer date. Returns a JSON object to stdout on
# success. Emits empty object { "review": null, "findings": [], "reaction": null }
# if nothing matches yet.
scan_codex_state() {
  local reviews comments reactions issue_comments review findings reaction verdict

  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")
  comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline comments")
  reactions=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/reactions" "reactions")
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments")

  # Latest review from the Codex bot on the current HEAD commit, if any.
  # Codex always uses COMMENTED state regardless of findings. We also
  # capture the review id so the findings filter can scope to THIS
  # review only and not pick up stale findings from an earlier review
  # round on the same HEAD.
  review=$(echo "$reviews" | jq --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    [.[] | select(.user.login == $bot) | select(.commit_id == $sha)]
    | sort_by(.submitted_at) | last
    | if . == null then null
      else { id, state, submitted_at, commit_id, body }
      end
  ')

  # Get the LATEST Codex review id so findings are scoped to that
  # round only. nathanpayne-codex caught (swipewatch propagation
  # PR #33 round 2) that filtering by SHA alone keeps old P0/P1
  # comments from earlier reviews on the same HEAD forever — same
  # bug class as PR #65 round 1's gate (c) findings filter on
  # codex-review-check.sh.
  latest_review_id=$(echo "$review" | jq -r 'if . == null then "" else .id end')

  # Inline findings from the bot on the current HEAD commit, scoped
  # to the LATEST review round (via pull_request_review_id), with
  # P0-P3 priority extracted from EITHER the ![P{0-3} Badge] badge image OR
  # the **Pn text fallback Codex emits when the badge is absent — mirroring
  # codex_tier_of in scripts/lib/feedback-policy-helpers.sh so a fallback-only
  # finding is classified consistently (CodeRabbit Major on #590). The
  # alternation's leftmost match wins, matching codex_tier_of's first-marker
  # rule. If there's no current review, findings is empty.
  if [ -n "$latest_review_id" ] && [ "$latest_review_id" != "null" ]; then
    findings=$(echo "$comments" | jq \
      --arg bot "$BOT_LOGIN" \
      --argjson review_id "$latest_review_id" \
      --argjson required "$REQUIRED_TIERS_JSON" '
      [ .[]
        | select(.user.login == $bot)
        | select(.pull_request_review_id == $review_id)
        | ( (.body | capture("!\\[P(?<b>[0-3]) Badge\\]|\\*\\*P(?<f>[0-3])")? // {}) | (.b // .f) ) as $n
        | { path, line, comment_id: .id, body,
            priority: ( if $n == null then "P?" else "P" + $n end ),
            # blocking (#577): this finding sits in a `required` tier per the
            # resolved feedback_policy set. An unmarked finding ($n == null,
            # "P?") is never blocking. Membership test lowercases the
            # normalized tier (p0..p3) against $required (from
            # resolve_required_tiers) so the surfaced flag matches exactly
            # what the codex-p1-gate enforces at merge time.
            blocking: ( $n != null and ( ("p" + $n) as $t | $required | index($t) != null ) )
          }
      ]
    ')
  else
    findings='[]'
  fi

  # Most recent +1 reaction from the bot on the issue with created_at
  # strictly >= REACTION_THRESHOLD. Threshold = max(HEAD_PUSHED_AT,
  # freshness floor). See the anchor computation above and
  # codex-review-check.sh for the full rationale. Without the
  # freshness floor, a stale 👍 from a prior HEAD (where the new HEAD
  # is a normal push with an old committer date) would read as a
  # "current" signal here and cause the pre-flight scan to skip the
  # trigger comment, leaving the caller to re-evaluate gate (c)
  # against the same stale reaction.
  reaction=$(echo "$reactions" | jq --arg bot "$BOT_LOGIN" --arg after "$REACTION_THRESHOLD" '
    [.[]
      | select(.user.login == $bot)
      | select(.content == "+1")
      | select(.created_at >= $after)
    ]
    | sort_by(.created_at) | last
    | if . == null then null
      else { content, created_at, reaction_id: .id }
      end
  ')

  # HEAD-anchored Codex issue-comment verdict (#600/#567/#608, mirrored here
  # per #609). Codex can clear a round purely via this "Codex Review: Didn't
  # find any major issues" + "Reviewed commit: <sha>" ISSUE comment, with no
  # review object and no fresh reaction — codex-review-check.sh (the merge
  # gate) has recognized this since #600, but until #609 this poller did not,
  # so a verdict-only response ran the poll to timeout (exit 4) instead of
  # terminating on it. Select the LATEST HEAD-anchored verdict FIRST (any
  # disposition), THEN check whether that latest one is affirmative — so a
  # newer non-affirmative verdict on the same HEAD supersedes an older clean
  # one and fails closed (same #608 P1 shape as the merge gate). KEEP THIS
  # FILTER IN SYNC with CODEX_VERDICT_JSON in scripts/codex-review-check.sh.
  verdict=$(echo "$issue_comments" | jq -c \
    --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    ($sha | ascii_downcase) as $head
    | [ .[]
        | select(.user.login == $bot)
        | . as $c
        | ( [ $c.body
              | ascii_downcase
              | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
              | .[0]
            ] ) as $shas
        | select( ($shas | length) > 0
                  and ($shas | any(. as $s | $head | startswith($s))) )
        | { created_at: .created_at,
            affirmative: (.body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b")) }
      ]
    | max_by(.created_at) // null
  ')

  jq -n --argjson review "$review" --argjson findings "$findings" --argjson reaction "$reaction" --argjson verdict "$verdict" '
    { review: $review, findings: $findings, reaction: $reaction, verdict: $verdict }
  '
}

# Returns 0 iff the scan produced ANY signal (review, reaction, or
# HEAD-anchored issue-comment verdict). Used by the poll loop, which stops
# as soon as Codex has produced any response — even a review with P0/P1
# findings, or a non-affirmative verdict, counts because the caller will
# then process the response and decide what to do (#609: a verdict-only
# response must end the poll instead of running to timeout).
has_signal() {
  local scan=$1
  [ "$(echo "$scan" | jq -r '.review != null or .reaction != null or .verdict != null')" = "true" ]
}

# Returns 0 iff the scan produced a signal that should be treated as
# CLEARED (no further @codex review trigger needed). Cleared means one of:
#   - any +1 reaction on the PR issue (the no-findings happy path), OR
#   - a review on HEAD with zero blocking (required-tier) inline findings
#     (the reviewed-and-clean path; "blocking" reflects the resolved
#     feedback_policy required set, so this is P0/P1 by default), OR
#   - a HEAD-anchored AFFIRMATIVE issue-comment verdict AND zero blocking
#     findings on HEAD (#600/#609) — a NON-affirmative latest verdict does
#     NOT clear (fails closed, mirroring #608 P1 on codex-review-check.sh).
#
# A review with blocking findings does NOT count as cleared — the caller
# may have replied to the findings with a rebuttal and want Codex to
# re-evaluate. Earlier versions of this function used has_signal in
# the pre-flight, which caused the rebuttal-without-commit path to
# stall: re-running the script saw the existing P1-bearing review
# and skipped the trigger, so Codex was never asked to reconsider.
# Codex caught this on swipewatch propagation PR #33 — same shape as
# the manual `@codex review` workaround I had to use on template PR
# #73 during dry-run C.
has_cleared_signal() {
  local scan=$1
  # Latest-signal-wins among THREE signal types — 👍 reaction, COMMENTED
  # review, and issue-comment verdict — not whichever this function checks
  # first (#64, extended for the verdict in #609, mirroring the merge gate's
  # #600/#608 LATEST_SIGNAL_KIND decision in codex-review-check.sh). An older
  # 👍 or clean review must not mask a NEWER negative verdict, and a stale
  # verdict must not override a newer P1-bearing review — nathanpayne-codex
  # caught the two-way version of this bug on nathanpaynedotcom propagation
  # PR #180 round 2 (same shape as PR #65 round 1's gate (c) latest-state
  # rule). Ties resolve reaction < review < verdict (iteration order,
  # replace-on->=), matching the merge gate's tie-break so an ambiguous
  # same-second tie fails closed when the verdict is negative.
  [ "$(echo "$scan" | jq -r '
    def review_time: if .review == null then "" else .review.submitted_at end;
    def reaction_time: if .reaction == null then "" else .reaction.created_at end;
    def verdict_time: if .verdict == null then "" else .verdict.created_at end;
    # P0 ALWAYS blocks clearance (the absent-policy disposition default is
    # P0/P1), regardless of the resolved gate set — otherwise a consumer with
    # no feedback_policy block (resolve_required_tiers -> {p1}) would emit a
    # P0-only review as blocking:false and prematurely clear it, skipping the
    # re-request (Codex P2 round 2 on #590). On top of the always-blocking P0,
    # anything in the resolved `required` set (the `blocking` flag) also blocks.
    # findings is already HEAD-scoped (scan_codex_state), independent of
    # which signal is latest, so it gates the verdict path too.
    def review_clean: ([.findings[] | select(.priority == "P0" or .blocking == true)] | length) == 0;

    ( reduce ( [["reaction", reaction_time], ["review", review_time], ["verdict", verdict_time]] | .[] ) as $sig
        ({kind: "", time: ""};
         if ($sig[1] != "" and ($sig[1] >= .time)) then {kind: $sig[0], time: $sig[1]} else . end)
    ) as $latest
    | if $latest.kind == "reaction" then "true"
      elif $latest.kind == "review" then (review_clean | tostring)
      elif $latest.kind == "verdict" then
        ((.verdict.affirmative == true and review_clean) | tostring)
      else "false"
      end
  ')" = "true" ]
}

# Returns 0 iff the scan has a terminal Codex signal that is at least
# as recent as TRIGGER_SIGNAL_THRESHOLD (>=, not >). That threshold is
# the first trigger timestamp in this script run, while TRIGGER_POST_TIME
# tracks the latest trigger comment for eyes-ack polling. Keeping them
# separate lets a late response to the original trigger count even if a
# retry comment was posted before the response became visible.
#
# Uses >= because GitHub timestamps are second-precision and a legitimate
# Codex response in the same second as the trigger comment post would
# otherwise be classified as stale forever, forcing a Phase 4b timeout.
has_post_trigger_signal() {
  local scan=$1
  local after=${TRIGGER_SIGNAL_THRESHOLD:-$TRIGGER_POST_TIME}
  [ "$(echo "$scan" | jq -r --arg after "$after" '
    ((.review != null and .review.submitted_at >= $after)
     or (.reaction != null and .reaction.created_at >= $after)
     or (.verdict != null and .verdict.created_at >= $after))
  ')" = "true" ]
}

# #489: HEAD-pinned idempotency for the rate-limit failover. Returns 0 iff a
# VALID `@codex review` trigger already exists for the current HEAD — meaning a
# comment authored by the configured `author_identity` (the same identity
# `post_codex_trigger` writes as, via gh-as-author.sh) whose `created_at` is at
# or after `REACTION_THRESHOLD` (the PR-scoped pushed-at / freshness anchor,
# `max(HEAD_PUSHED_AT, freshness floor)`). Author + anchor scoping (Codex P2 on
# #512) is what makes this sound: a reviewer-authored `@codex review`, or a
# stale author trigger left on a prior head before a force-push of an
# old-committer-date commit, must NOT count as "Codex was requested for THIS
# SHA" — otherwise coderabbit-wait.sh would emit `codex_failover_requested:true`
# with no valid trigger sent. Lets --trigger-only skip a duplicate post when
# coderabbit-wait.sh fires the failover more than once for the same HEAD (e.g.
# a re-invocation). Fail-open: on a missing author identity or any read error it
# returns non-zero so the caller still posts (better to re-request Codex than to
# silently skip the failover).
existing_codex_trigger_on_head() {
  [ -n "$AUTHOR_IDENTITY" ] || return 1
  local comments
  comments=$(gh api --paginate "repos/$REPO/issues/$PR_NUMBER/comments" 2>/dev/null \
    | jq -s 'add // []' 2>/dev/null) || return 1
  [ -n "$comments" ] || return 1
  echo "$comments" | jq -e \
    --arg author "$AUTHOR_IDENTITY" \
    --arg since "$REACTION_THRESHOLD" '
    any(.[];
      ((.user.login // "") == $author)
      and ((.body // "") | test("@codex review"; "i"))
      and (.created_at >= $since))
  ' >/dev/null 2>&1
}

reset_review_wait_clock() {
  START_TS=$(date +%s)
  DEADLINE=$((START_TS + TIMEOUT_SECONDS))
  ELAPSED=0
}

post_codex_trigger() {
  # The Codex GitHub App ONLY monitors '@codex review' comments authored
  # by the repo's AUTHOR/human identity (nathanjohnpayne). A trigger
  # posted by a reviewer/bot identity (nathanpayne-claude/-codex/-cursor)
  # is silently ignored: empirically a reviewer-posted trigger sat
  # unanswered to the full 600s timeout while an author-posted one drew a
  # Codex review in ~20s (PR #405). Post it through gh-as-author.sh,
  # which verifies an author token and runs the write with process-local
  # GH_TOKEN. This SUPERSEDES the #284 `identity-check --expect-reviewer`
  # guard, which fail-closed on the WRONG identity for this particular
  # write.
  log "posting '@codex review' trigger comment (as author identity nathanjohnpayne)"
  AS_AUTHOR="$__CODEX_REQUEST_DIR/gh-as-author.sh"
  if [ ! -x "$AS_AUTHOR" ]; then
    echo "ERROR: gh-as-author.sh helper missing or non-executable: $AS_AUTHOR" >&2
    echo "       Refusing to post '@codex review' without author-token attribution" >&2
    echo "       (Codex ignores reviewer/bot-authored triggers — see comment above)." >&2
    die 3 "gh-as-author.sh helper unavailable"
  fi

  # Inline author-PAT bridging (#438): gh-as-author.sh's resolver
  # intentionally ignores ambient GH_TOKEN — it reads only
  # OP_PREFLIGHT_AUTHOR_PAT or a stored `gh auth token --user`. In a
  # CI/fresh shell with no preflight cache and no keyring, the
  # still-documented `GH_TOKEN=<author PAT> codex-review-request.sh`
  # invocation shape passed every read-side check and then failed the
  # trigger write despite holding a valid author token, forcing an
  # unnecessary Phase 4b fallback. Bridge the ambient token into the
  # wrapper's preferred env var ONLY after verifying it actually
  # resolves to the author identity; any other token (the common
  # reviewer-PAT session shape) is left alone so the wrapper's own
  # resolution proceeds unchanged and fails closed as before.
  BRIDGE_AUTHOR_PAT=""
  if [ -n "${GH_TOKEN:-}" ] && [ -z "${OP_PREFLIGHT_AUTHOR_PAT:-}" ]; then
    IDENTITY_CHECKER="$__CODEX_REQUEST_DIR/identity-check.sh"
    if [ -x "$IDENTITY_CHECKER" ] \
      && GH_TOKEN="$GH_TOKEN" "$IDENTITY_CHECKER" --expect-token-identity "$AUTHOR_IDENTITY" >/dev/null 2>&1; then
      log "ambient GH_TOKEN verifies as author identity $AUTHOR_IDENTITY — bridging it into gh-as-author.sh as OP_PREFLIGHT_AUTHOR_PAT"
      BRIDGE_AUTHOR_PAT="$GH_TOKEN"
    fi
  fi

  # Capture stdout+stderr so a failure surfaces the real gh error
  # (404 / 403 / 422) rather than a bare "failed to post". The comment
  # URL gh prints on success is still extractable downstream.
  # Pass the configured author identity on BOTH invocation branches:
  # the wrapper's hard default (nathanjohnpayne) would reject a valid
  # custom-author token in repos that override author_identity —
  # bridged-token case (Codex P2 on PR #442 r2) AND warm-preflight /
  # keyring case (Codex P2 on PR #442 r5). review-policy.yml is the
  # source of truth this script already reads, so it wins.
  if [ -n "$BRIDGE_AUTHOR_PAT" ]; then
    POST_OUTPUT=$(OP_PREFLIGHT_AUTHOR_PAT="$BRIDGE_AUTHOR_PAT" GH_AS_AUTHOR_IDENTITY="$AUTHOR_IDENTITY" "$AS_AUTHOR" -- gh pr comment "$PR_NUMBER" --repo "$REPO" --body "@codex review" 2>&1) \
      || die 3 "failed to post '@codex review' comment: $POST_OUTPUT"
  else
    POST_OUTPUT=$(GH_AS_AUTHOR_IDENTITY="$AUTHOR_IDENTITY" "$AS_AUTHOR" -- gh pr comment "$PR_NUMBER" --repo "$REPO" --body "@codex review" 2>&1) \
      || die 3 "failed to post '@codex review' comment: $POST_OUTPUT"
  fi
  TRIGGER_POSTED=true

  # Capture the post time so the poll loop can ignore stale signals
  # that were already on HEAD before the trigger fired. Without this,
  # `has_signal "$INITIAL_SCAN"` would return true on the very first
  # iteration of the poll loop and the script would exit with the
  # stale review/reaction without waiting for Codex's actual response
  # to the new trigger. Codex caught this on swipewatch propagation
  # PR #33 round 2 — same shape as the round-1 has_cleared_signal
  # bug, just on the post-trigger side.
  #
  # Use GitHub's authoritative timestamp from the just-posted comment
  # (extracted from the URL gh returns) rather than local wall-clock.
  # Local wall-clock can be ahead of or behind GitHub by a few seconds
  # due to NTP skew, and the strict `>` comparison would misclassify
  # a real Codex response as pre-trigger. Falls back to local wall-
  # clock minus a 60-second buffer if the comment ID can't be
  # extracted (e.g., gh output format change). Codex caught the
  # wall-clock issue on nathanpaynedotcom propagation PR #180 round 4.
  TRIGGER_COMMENT_ID=$(echo "$POST_OUTPUT" | grep -oE 'issuecomment-[0-9]+' | head -1 | sed 's/issuecomment-//' || true)
  if [ -n "$TRIGGER_COMMENT_ID" ]; then
    TRIGGER_POST_TIME=$(gh api "repos/$REPO/issues/comments/$TRIGGER_COMMENT_ID" --jq '.created_at' 2>/dev/null || true)
  fi
  if [ -z "$TRIGGER_POST_TIME" ]; then
    # Fallback: local wall-clock minus a 60-second buffer for
    # clock skew tolerance.
    EPOCH_NOW=$(date +%s)
    EPOCH_BUFFER=$((EPOCH_NOW - 60))
    if TRIGGER_POST_TIME=$(date -u -r "$EPOCH_BUFFER" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
      :
    else
      TRIGGER_POST_TIME=$(date -u -d "@$EPOCH_BUFFER" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || die 3 "could not compute fallback TRIGGER_POST_TIME")
    fi
  fi

  # Terminal Codex signals should be accepted if they respond to any
  # trigger posted in this script run. Retries still update
  # TRIGGER_POST_TIME for eyes-ack polling, but must not advance the
  # terminal-signal threshold past a valid response to an earlier trigger.
  if [ -z "$TRIGGER_SIGNAL_THRESHOLD" ]; then
    TRIGGER_SIGNAL_THRESHOLD="$TRIGGER_POST_TIME"
  fi

  # The review timeout belongs to the latest trigger comment, not to
  # the first missing-ack attempt. Without this reset, an unacknowledged
  # trigger can consume part of the retry's normal review window.
  reset_review_wait_clock
}

trigger_ack_present() {
  local reactions

  [ -n "$TRIGGER_COMMENT_ID" ] || return 1
  reactions=$(fetch_api_array "repos/$REPO/issues/comments/$TRIGGER_COMMENT_ID/reactions" "trigger comment reactions")
  [ "$(echo "$reactions" | jq -r --arg bot "$BOT_LOGIN" --arg after "$TRIGGER_POST_TIME" '
    [ .[]
      | select(.user.login == $bot)
      | select(.content == "eyes")
      | select(.created_at >= $after)
    ]
    | length > 0
  ')" = "true" ]
}

wait_for_trigger_ack() {
  local ack_start ack_deadline now remaining sleep_for

  if [ -z "$TRIGGER_COMMENT_ID" ]; then
    log "trigger comment id unavailable — skipping eyes-ack check and continuing normal poll"
    return 0
  fi

  ack_start=$(date +%s)
  ack_deadline=$((ack_start + ACK_WAIT_SECONDS))

  while :; do
    if trigger_ack_present; then
      log "Codex eyes acknowledgment received on trigger comment $TRIGGER_COMMENT_ID"
      return 0
    fi

    # If a terminal Codex signal arrives before the eyes reaction is
    # observable via REST, do not re-trigger. The terminal signal wins;
    # eyes is only an acknowledgment, never a clearance signal.
    if ! FINAL_SCAN=$(scan_codex_state); then
      die 3 "eyes-ack Codex scan failed"
    fi
    if has_post_trigger_signal "$FINAL_SCAN"; then
      log "Codex terminal signal arrived during eyes-ack wait — no re-trigger needed"
      return 0
    fi

    now=$(date +%s)
    if [ "$now" -ge "$ack_deadline" ] || [ "$now" -ge "$DEADLINE" ]; then
      log "no Codex eyes acknowledgment on trigger comment $TRIGGER_COMMENT_ID within ${ACK_WAIT_SECONDS}s"
      return 1
    fi

    remaining=$((ack_deadline - now))
    sleep_for=$ACK_POLL_INTERVAL_SECONDS
    if [ "$remaining" -lt "$sleep_for" ]; then
      sleep_for=$remaining
    fi
    sleep "$sleep_for"
    ELAPSED=$(( $(date +%s) - START_TS ))
  done
}

run_trigger_ack_gate() {
  local retries_used=0

  [ "$TRIGGER_POSTED" = "true" ] || return 0
  if [ -z "$TRIGGER_COMMENT_ID" ]; then
    log "trigger comment id unavailable — skipping eyes-ack gate and continuing normal poll"
    return 0
  fi

  while :; do
    if wait_for_trigger_ack; then
      return 0
    fi

    if [ "$retries_used" -ge "$MAX_ACK_RETRIES" ]; then
      log "eyes-ack retry cap reached (${retries_used}/${MAX_ACK_RETRIES}) — continuing normal review poll"
      return 0
    fi

    retries_used=$((retries_used + 1))
    log "re-posting '@codex review' because Codex did not acknowledge the trigger (${retries_used}/${MAX_ACK_RETRIES})"
    post_codex_trigger
  done
}

# --- pre-flight: is Codex already working on HEAD? --------------------------

log "checking for existing Codex signal on HEAD"
if ! INITIAL_SCAN=$(scan_codex_state); then
  die 3 "initial Codex scan failed"
fi

reset_review_wait_clock
TRIGGER_POSTED=false
TRIGGER_COMMENT_ID=""
TRIGGER_POST_TIME=""
TRIGGER_SIGNAL_THRESHOLD=""

if has_cleared_signal "$INITIAL_SCAN"; then
  log "Codex has already cleared on HEAD (reaction, no-blocking-tier review, or affirmative verdict comment) — skipping trigger comment"
elif [ "$TRIGGER_ONLY" = "true" ] && existing_codex_trigger_on_head; then
  log "trigger-only: @codex review already requested on HEAD — skipping duplicate trigger (idempotent, #489)"
else
  post_codex_trigger
fi

# #489 trigger-only: return immediately after posting (or confirming) the
# trigger — BEFORE run_trigger_ack_gate, which would otherwise re-post
# @codex up to max_ack_retries (the eyes-ack retry) and break the
# one-trigger-per-run contract the rate-limit failover relies on. No clearance
# poll; Codex's actual review/clearance is picked up later by the normal Phase
# 4a flow and the merge-clearance gate. trigger_posted is false when the
# idempotency check skipped a duplicate, or when Codex had already cleared.
if [ "$TRIGGER_ONLY" = "true" ]; then
  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg head_sha "$HEAD_SHA" \
    --arg head_committer_date "$HEAD_COMMITTER_DATE" \
    --arg bot_login "$BOT_LOGIN" \
    --argjson trigger_posted "$TRIGGER_POSTED" '
    {
      pr_number: $pr_number,
      repo: $repo,
      head_sha: $head_sha,
      head_committer_date: $head_committer_date,
      bot_login: $bot_login,
      review: null,
      findings: [],
      reaction: null,
      verdict: null,
      trigger_posted: $trigger_posted,
      trigger_requested: true,
      trigger_only: true,
      rounds_waited_seconds: 0
    }'
  exit 0
fi

if [ "$TRIGGER_POSTED" = "true" ]; then
  # We just posted a trigger. The INITIAL_SCAN data is now stale by
  # definition — Codex will respond with something new. Skip the
  # initial has_signal check; force the loop to actually poll.
  FINAL_SCAN='{"review":null,"findings":[],"reaction":null,"verdict":null}'
  run_trigger_ack_gate
else
  FINAL_SCAN=$INITIAL_SCAN
fi

# --- poll loop --------------------------------------------------------------

while :; do
  # If we just triggered a fresh review, only break on a signal
  # at or after the first trigger in this run. Otherwise (no trigger
  # sent), any existing signal is fine — that's the cleared-on-arrival
  # path.
  if [ "$TRIGGER_POSTED" = "true" ]; then
    if has_post_trigger_signal "$FINAL_SCAN"; then
      log "Codex signal received after ${ELAPSED}s (post-trigger)"
      break
    fi
  elif has_signal "$FINAL_SCAN"; then
    log "Codex signal received after ${ELAPSED}s"
    break
  fi

  NOW=$(date +%s)
  if [ "$NOW" -ge "$DEADLINE" ]; then
    # Final scan at the deadline (#465): a Codex signal that arrived between
    # the last poll and now must not be emitted as a stale timeout. Refresh
    # FINAL_SCAN so BOTH the JSON emission and the exit-code decision below
    # reflect current state — if a signal landed, has_*_signal sees it and
    # the script exits 0 instead of 4 (FALLBACK_REQUIRED) on stale data.
    if ! FINAL_SCAN=$(scan_codex_state); then
      die 3 "final timeout-path scan failed"
    fi
    log "deadline reached after ${ELAPSED}s — emitted scan is the final one; exit code decided below"
    break
  fi

  log "polling... (${ELAPSED}s / ${TIMEOUT_SECONDS}s)"
  sleep "$POLL_INTERVAL_SECONDS"
  ELAPSED=$(( $(date +%s) - START_TS ))

  if ! FINAL_SCAN=$(scan_codex_state); then
    die 3 "poll scan failed"
  fi
done

# --- emit final JSON --------------------------------------------------------

jq -n \
  --argjson pr_number "$PR_NUMBER" \
  --arg repo "$REPO" \
  --arg head_sha "$HEAD_SHA" \
  --arg head_committer_date "$HEAD_COMMITTER_DATE" \
  --arg bot_login "$BOT_LOGIN" \
  --argjson scan "$FINAL_SCAN" \
  --argjson trigger_posted "$TRIGGER_POSTED" \
  --argjson elapsed "$ELAPSED" '
  {
    pr_number: $pr_number,
    repo: $repo,
    head_sha: $head_sha,
    head_committer_date: $head_committer_date,
    bot_login: $bot_login,
    review: $scan.review,
    findings: $scan.findings,
    reaction: $scan.reaction,
    verdict: $scan.verdict,
    trigger_posted: $trigger_posted,
    trigger_requested: true,
    rounds_waited_seconds: $elapsed
  }
'

# Exit 0 if a signal arrived; exit 4 (FALLBACK_REQUIRED) if we timed
# out. When TRIGGER_POSTED=true, "a signal arrived" means a signal
# at or after the first trigger in this run — existing pre-trigger
# signals do not count, otherwise the script would exit 0 with stale
# findings the moment we time out polling for the new review.
if [ "$TRIGGER_POSTED" = "true" ]; then
  if has_post_trigger_signal "$FINAL_SCAN"; then
    exit 0
  else
    exit 4
  fi
elif has_signal "$FINAL_SCAN"; then
  exit 0
else
  exit 4
fi
