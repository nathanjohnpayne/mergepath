#!/usr/bin/env bash
# scripts/coderabbit-wait.sh — Phase 2.5 CodeRabbit wait + rate-limit retry
#
# Polls a pull request for a CodeRabbit review anchored on the current HEAD
# commit. Handles three CodeRabbit behaviors that the naive "just wait"
# pattern in AGENTS.md step 5 does not:
#
#   1. **Rate-limit state.** CodeRabbit posts a comment matching
#      "Rate limit exceeded" with a specific retry window
#      ("Please wait X minutes and Y seconds before requesting another
#      review") and then does NOT auto-retry when the window elapses.
#      This script detects that state, sleeps the window + buffer, posts
#      `@coderabbitai, try again.` to re-trigger, and continues polling.
#      See nathanjohnpayne/mergepath#138.
#
#   2. **Auto-pause state.** After N reviewed commits
#      (`reviews.auto_review.auto_pause_after_reviewed_commits`, default 5)
#      CodeRabbit auto-pauses incremental review and posts a "Reviews
#      paused" NOTE carrying the stable marker
#      `<!-- This is an auto-generated comment: review paused by
#      coderabbit.ai -->`. The platform does NOT auto-resume. Our agent
#      loop pushes many fix-up commits per PR, so long PRs cross the
#      threshold and silently stop being reviewed (confirmed on #485).
#      This script detects that marker, posts `@coderabbitai resume`
#      (NOT a one-shot `review`, which re-pauses after the next push),
#      and continues polling — bounded by `max_resume_retries`. Distinct
#      from the rate-limit and in-progress states. See
#      nathanjohnpayne/mergepath#490.
#
#   3. **HEAD freshness.** Auto-merge-on-approval workflows in downstream
#      repos race CodeRabbit: an internal reviewer can post APPROVED before
#      CodeRabbit's ~2–3 minute review lands, and the PR auto-merges
#      pre-review. The script only returns "cleared" when CodeRabbit has
#      posted a non-rate-limited, non-in-progress comment on or after the
#      HEAD committer date. See nathanjohnpayne/mergepath#136.
#
# It also surfaces — without re-invoking — the other detectable reasons
# CodeRabbit auto-review never fires: a PR base branch matched by none of
# the configured `base_branches` REGEX patterns (and not the repo default
# branch, which CodeRabbit always reviews), and a draft PR when
# `drafts: false`. These are reported in the JSON `skip_reason` field
# (paused / non-base-branch / draft) so the caller can act instead of
# waiting out a full timeout. The base-branch check evaluates each entry as
# a regex and fails SAFE (suppresses the skip) on an unparseable pattern.
# See nathanjohnpayne/mergepath#490.
#
# Usage:
#   scripts/coderabbit-wait.sh <PR_NUMBER> [REPO]
#
# Arguments:
#   PR_NUMBER  Required. The pull request number (integer).
#   REPO       Optional. Fully-qualified "owner/repo". Defaults to the
#              current repository detected by `gh repo view`.
#
# Environment:
#   GH_TOKEN   Required unless a fresh op-preflight cache is available.
#              Must resolve to the reviewer identity for retry-trigger
#              writes. In the template flow this helper auto-sources
#              $OP_PREFLIGHT_REVIEWER_PAT after preflight.
#
# Behavior:
#   1. Reads coderabbit.max_wait_seconds (default 300) and
#      coderabbit.max_rate_limit_retries (default 2) from
#      .github/review-policy.yml.
#   2. Fetches PR HEAD SHA + committer date.
#   0. Before polling, check the static skips that mean auto-review will
#      never fire on this PR: base branch matched by none of the
#      `base_branches` regex patterns AND not the repo default branch
#      (#490), and draft when `drafts: false`. On either, emit JSON with
#      the `skip_reason` set and exit 6 (SKIPPED) rather than burning the
#      whole budget on a review that cannot land.
#   3. Polls issue + review comments every 15s. For each CodeRabbit
#      comment newer than HEAD committer date, classifies as:
#        - rate_limit  — body matches /Rate limit exceeded/i
#        - paused      — body carries the "review paused by coderabbit.ai"
#                        auto-generated marker (the #485 auto-pause NOTE)
#        - in_progress — body matches /review in progress|currently reviewing/i
#        - review      — anything else authored by coderabbitai[bot]
#   4. On rate_limit: parse "X minutes and Y seconds" (or "X seconds"),
#      sleep that duration + 30s buffer, post `@coderabbitai, try again.`,
#      increment retry counter, continue polling.
#   4b. On paused: post `@coderabbitai resume` (a one-shot `review`
#      re-pauses after the next push, so resume is the correct verb),
#      increment a resume-retry counter, and continue polling. If
#      resume_retries > max_resume_retries: exit 6 (SKIPPED) with
#      status=paused and skip_reason=paused so the caller can raise
#      `auto_pause_after_reviewed_commits` or intervene.
#   5. On review (non-rate-limit, non-in-progress): emit JSON, exit 0.
#      Also scans inline diff comments for "Potential issue" / "⚠️"
#      markers and surfaces them in the JSON so callers can decide.
#   6. If total elapsed > max_wait_seconds: if a pause was OBSERVED during
#      polling (a durable same-id pause NOTE never advances the resume
#      budget to its cap), exit 6 (SKIPPED) with status=paused /
#      skip_reason=paused — a still-paused PR must not fall through to the
#      advisory timeout that agent-review.yml merges past. Otherwise
#      optionally post `@coderabbitai, how is the review going?`, wait a
#      short bounded status-probe window for CodeRabbit's reply, then exit 4
#      (TIMEOUT) with the reply excerpt surfaced in JSON. The probe is
#      narration only, never a review / clearance signal.
#   7. If rate_limit_retries > max_rate_limit_retries: exit 5 (STALLED),
#      emit JSON with status=rate_limit_stalled.
#
# Output JSON shape (stdout):
#   {
#     "pr_number": 123,
#     "repo": "owner/repo",
#     "head_sha": "<full sha>",
#     "head_committer_date": "<iso-8601>",
#     "bot_login": "coderabbitai[bot]",
#     "status": "cleared" | "findings" | "timeout" | "rate_limit_stalled"
#               | "paused" | "skipped",
#     "skip_reason": null | "paused" | "non-base-branch" | "draft",
#     "review": null | {
#       "id": N,
#       "created_at": "<iso-8601>",
#       "endpoint": "issues" | "pulls",
#       "body_excerpt": "<first 200 chars>"
#     },
#     "potential_issue_count": N,
#     # blocking_tier_unresolved (#577): count of unaddressed inline HEAD
#     # findings whose coderabbit_tier_of tier is in the resolved
#     # feedback_policy required set. null when the feedback_policy block is
#     # ABSENT (preserving the historical shape + exit-code contract) or on
#     # any non-findings/cleared terminal. Report-only — it never affects the
#     # exit code; the merge-blocking CodeRabbit gate is
#     # scripts/coderabbit-severity-gate.sh.
#     "blocking_tier_unresolved": null | N,
#     "rate_limit_retries": N,
#     "resume_retries": N,
#     "status_probe": {
#       "enabled": true | false,
#       "posted": true | false,
#       "reply_present": true | false,
#       "reply": null | {
#         "id": N,
#         "created_at": "<iso-8601>",
#         "updated_at": "<iso-8601>",
#         "fresh_at": "<iso-8601>",
#         "body_excerpt": "<first 500 chars>"
#       },
#       "waited_seconds": N
#     },
#     "waited_seconds": N
#   }
#
# Exit codes:
#   0   CodeRabbit posted a real review on current HEAD with no
#       "Potential issue"/⚠️ markers. Safe to proceed.
#   2   CodeRabbit posted a real review with at least one P0/P1-equivalent
#       marker. Caller should address before proceeding.
#   3   API / infrastructure error. Error on stderr.
#   4   Timeout — max_wait_seconds elapsed without a real review. Caller
#       may log a warning and proceed (CodeRabbit is advisory), or block.
#   5   Rate-limit stalled — max_rate_limit_retries exceeded. Distinct
#       from timeout so callers can alert the human instead of proceeding.
#   6   Auto-review skipped and not (re-)invocable. Either the static
#       skip — base branch ∉ base_branches, or draft when drafts:false —
#       or an auto-pause whose `@coderabbitai resume` retries are
#       exhausted (max_resume_retries). The JSON `skip_reason` field
#       names the cause (paused / non-base-branch / draft). Distinct from
#       a slow-review timeout (4): the review cannot land as-is, so the
#       caller should raise `auto_pause_after_reviewed_commits`, retarget
#       the base, mark the PR ready, or escalate — not merely log and
#       proceed. See nathanjohnpayne/mergepath#490.
#
# Design notes:
#   - Read-only except for retry-trigger comments, the auto-pause
#     `@coderabbitai resume` re-invocation, and timeout status-probe
#     comments. Does not push commits, does not modify labels, does not
#     merge.
#   - Idempotent across reruns on the same HEAD. A freshly-landed review
#     is detected on the next poll regardless of how many times the script
#     has been run.
#   - JSON emission uses `jq`. Pattern matching on CodeRabbit comment
#     bodies is intentionally heuristic — the bot's output format is not
#     versioned and may drift. See nathanjohnpayne/mergepath#138 for the
#     observed rate-limit string.

set -euo pipefail

# --- preflight auto-source (#282) ------------------------------------------
# If GH_TOKEN is unset and a fresh op-preflight cache exists for this
# agent, source it and export OP_PREFLIGHT_REVIEWER_PAT as GH_TOKEN.
# This lets agents drop the explicit `GH_TOKEN=...` prefix when their
# preflight cache is already warm. Preserves existing behavior when
# GH_TOKEN is already set. The existing
# `[ -z "${GH_TOKEN:-}" ] && exit 3` guard below still fires on a
# missing cache + missing env var (no regression).
__CODERABBIT_WAIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$__CODERABBIT_WAIT_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__CODERABBIT_WAIT_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi
if [ ! -r "$__CODERABBIT_WAIT_DIR/lib/gh-token-resolver.sh" ]; then
  echo "ERROR: gh-token-resolver helper missing: $__CODERABBIT_WAIT_DIR/lib/gh-token-resolver.sh" >&2
  exit 3
fi
# shellcheck source=lib/gh-token-resolver.sh
. "$__CODERABBIT_WAIT_DIR/lib/gh-token-resolver.sh"

# Shared available_reviewers reader (#453) — one strongest-form parser so
# the token-derived expected-identity allow-list (login_is_available_reviewer,
# used at write time) can't be weakened by a quoted/commented reviewer
# entry. Hard-require it: the token-login derivation is a fail-closed
# security check, so a missing helper must error, not silently degrade.
if [ ! -r "$__CODERABBIT_WAIT_DIR/lib/reviewers-helpers.sh" ]; then
  echo "ERROR: reviewers-helpers missing: $__CODERABBIT_WAIT_DIR/lib/reviewers-helpers.sh" >&2
  exit 3
fi
# shellcheck source=lib/reviewers-helpers.sh
. "$__CODERABBIT_WAIT_DIR/lib/reviewers-helpers.sh"

# --- argument parsing -------------------------------------------------------

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <PR_NUMBER> [REPO]" >&2
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
  echo "  - Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode all)\"" >&2
  echo "    so this helper auto-sources OP_PREFLIGHT_REVIEWER_PAT, OR" >&2
  echo "  - Set GH_TOKEN to the expected reviewer PAT." >&2
  exit 3
fi

# Expected reviewer identity for helper-comment writes. When any of
# the explicit identity envs is set, honor it via
# gh_default_reviewer_identity. Otherwise — e.g. agent-review.yml
# passes only `GH_TOKEN: secrets.REVIEWER_ASSIGNMENT_TOKEN` with no
# MERGEPATH_AGENT / OP_PREFLIGHT_AGENT / GH_AS_REVIEWER_IDENTITY —
# leave it empty so verify_reviewer_write_identity derives the
# expected login from the token itself, constrained to
# available_reviewers (#438). The old behavior hard-defaulted to
# nathanpayne-claude, so a repo whose REVIEWER_ASSIGNMENT_TOKEN is a
# different allowed reviewer failed identity verification before
# posting a retry/status-probe comment — a rate-limited CodeRabbit
# run then exited as infra error instead of retrying.
if [ -n "${GH_AS_REVIEWER_IDENTITY:-}" ] || [ -n "${MERGEPATH_AGENT:-}" ] || [ -n "${OP_PREFLIGHT_AGENT:-}" ]; then
  EXPECTED_REVIEWER_IDENTITY="$(gh_default_reviewer_identity)"
else
  EXPECTED_REVIEWER_IDENTITY=""   # derived lazily from the token at write time
fi

gh_reviewer() (
  unset GITHUB_TOKEN
  # Pin reviewer writes to the reviewer PAT rather than inheriting ambient
  # creds (#533): prefer the preflight-cached reviewer PAT, falling back to
  # GH_TOKEN. Mirrors scripts/resolve-pr-threads.sh's PAT_GH_TOKEN pattern.
  GH_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-${GH_TOKEN:-}}" gh "$@"
)

# --- config readers ---------------------------------------------------------

CONFIG=".github/review-policy.yml"

# Extract a scalar field from the coderabbit: block in review-policy.yml.
# Mirrors the state-machine pattern used by codex-review-request.sh: stops
# at the next top-level key, tolerates column-0 comments. Empty string if
# field missing — caller turns into default.
coderabbit_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^coderabbit:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block {
      if ($1 == field":") {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
        gsub(/^"/, "", $0)
        gsub(/"[[:space:]]*(#.*)?$/, "", $0)
        gsub(/[[:space:]]*#.*$/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        print
        exit
      }
    }
  ' "$CONFIG"
}

# read_available_reviewers + login_is_available_reviewer now live in
# scripts/lib/reviewers-helpers.sh (sourced above, #453). They default to
# $CONFIG, so the call sites below are unchanged. The token-derived
# expected-identity path (#438) still consumes login_is_available_reviewer
# to keep the derivation fail-closed.

# --- .coderabbit.yml readers (#490) -----------------------------------------
#
# The auto-review skip conditions (base_branches allow-list, drafts gate)
# live in CodeRabbit's own config, not review-policy.yml. Read them with the
# same dependency-free awk-state-machine style used for coderabbit_field so
# this helper picks up no new `yq` runtime dependency (it already requires
# only `gh`/`jq`). Both readers walk the nested
# `reviews:` → `auto_review:` block by indentation. Absent file / key →
# empty output, and the caller treats that as "no configured constraint"
# (the skip check is suppressed) so a consumer without the keys is never
# falsely reported as skipped.
CODERABBIT_YML=".coderabbit.yml"

# Emit each configured base branch (one per line) from
# reviews.auto_review.base_branches. Tolerates quotes, inline comments, and
# leading-dash list syntax. Empty output when the key is absent.
coderabbit_yml_base_branches() {
  [ -f "$CODERABBIT_YML" ] || return 0
  awk '
    # Track the two-level path into reviews: -> auto_review: -> base_branches:
    /^reviews:[[:space:]]*$/ { in_reviews=1; in_auto=0; in_list=0; next }
    in_reviews && /^[^[:space:]#]/ { in_reviews=0; in_auto=0; in_list=0 }
    in_reviews && /^  auto_review:[[:space:]]*$/ { in_auto=1; in_list=0; next }
    # A new 2-space key under reviews: closes auto_review:
    in_auto && /^  [^[:space:]#]/ && $0 !~ /^  auto_review:/ { in_auto=0; in_list=0 }
    in_auto && /^    base_branches:[[:space:]]*$/ { in_list=1; next }
    # A new 4-space key under auto_review: closes the base_branches list
    in_list && /^    [^[:space:]#-]/ { in_list=0 }
    in_list && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/[[:space:]]*#.*$/, "", line)
      gsub(/^["'"'"']/, "", line)
      gsub(/["'"'"'][[:space:]]*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") print line
    }
  ' "$CODERABBIT_YML"
}

# Emit the literal value of reviews.auto_review.drafts (true|false), or
# empty when the key is absent.
coderabbit_yml_drafts() {
  [ -f "$CODERABBIT_YML" ] || return 0
  awk '
    /^reviews:[[:space:]]*$/ { in_reviews=1; in_auto=0; next }
    in_reviews && /^[^[:space:]#]/ { in_reviews=0; in_auto=0 }
    in_reviews && /^  auto_review:[[:space:]]*$/ { in_auto=1; next }
    in_auto && /^  [^[:space:]#]/ && $0 !~ /^  auto_review:/ { in_auto=0 }
    in_auto && /^    drafts:[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*drafts:[[:space:]]*/, "", line)
      gsub(/[[:space:]]*#.*$/, "", line)
      gsub(/^["'"'"']/, "", line)
      gsub(/["'"'"'][[:space:]]*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$CODERABBIT_YML"
}

MAX_WAIT_SECONDS=$(coderabbit_field max_wait_seconds)
MAX_WAIT_SECONDS=${MAX_WAIT_SECONDS:-300}
if ! [[ "$MAX_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.max_wait_seconds must be an integer; got '$MAX_WAIT_SECONDS'" >&2
  exit 3
fi

MAX_RATE_LIMIT_RETRIES=$(coderabbit_field max_rate_limit_retries)
MAX_RATE_LIMIT_RETRIES=${MAX_RATE_LIMIT_RETRIES:-2}
if ! [[ "$MAX_RATE_LIMIT_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.max_rate_limit_retries must be an integer; got '$MAX_RATE_LIMIT_RETRIES'" >&2
  exit 3
fi

# Auto-pause (#490): how many times to post `@coderabbitai resume` before
# giving up and exiting 6 (skipped, status=paused). Mirrors
# max_rate_limit_retries but for the durable auto-pause state — a single
# resume can re-pause once more fix-up commits land, so a small cap keeps
# us from a resume↔pause ping-pong while still recovering the common case.
MAX_RESUME_RETRIES=$(coderabbit_field max_resume_retries)
MAX_RESUME_RETRIES=${MAX_RESUME_RETRIES:-2}
if ! [[ "$MAX_RESUME_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.max_resume_retries must be an integer; got '$MAX_RESUME_RETRIES'" >&2
  exit 3
fi

WALLCLOCK_FRESHNESS_WINDOW_SECONDS=$(coderabbit_field wallclock_freshness_window_seconds)
WALLCLOCK_FRESHNESS_WINDOW_SECONDS=${WALLCLOCK_FRESHNESS_WINDOW_SECONDS:-1800}
if ! [[ "$WALLCLOCK_FRESHNESS_WINDOW_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.wallclock_freshness_window_seconds must be an integer; got '$WALLCLOCK_FRESHNESS_WINDOW_SECONDS'" >&2
  exit 3
fi

BOT_LOGIN=$(coderabbit_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"coderabbitai[bot]"}
POLL_INTERVAL_SECONDS=15
STATUS_PROBE_POLL_INTERVAL_SECONDS=5
RATE_LIMIT_BUFFER_SECONDS=30

# #596: CodeRabbit flips its commit StatusContext to `success` while
# rate-limited, ~1s AFTER posting the rate-limit notice (the #595 spurious
# success). When the latest HEAD-referencing CodeRabbit comment is a
# non-review notice (rate_limit/paused/in_progress), a `success` that lands
# within this many seconds of it is treated as that near-simultaneous flip and
# suppressed (keep polling); a `success` that postdates the notice by MORE than
# this is a genuine later re-review — which per #221 can be silent (no new
# summary comment) — and stays authoritative. Comfortably above CodeRabbit's
# flip latency (seconds) yet below its minutes-long rate-limit windows, so the
# #595 false success is caught while a real recovery review still clears.
STATUS_SUCCESS_GRACE_SECONDS=120

# --- tier-aware classification (#577) ---------------------------------------
# Additive tier-awareness layered ON TOP of the existing binary
# `Potential issue`/⚠️ detector — it NEVER replaces the exit-code fast-paths
# below (HEAD-anchoring, rate-limit, auto-pause). When the feedback_policy
# block is PRESENT, this surfaces a `blocking_tier_unresolved` count (findings
# on HEAD whose coderabbit_tier_of tier is in the resolved required set) in
# the emitted JSON. When the block is ABSENT — or the shared lib is not on
# disk (some test harnesses stage this script without scripts/lib) —
# BLOCKING_TIER_UNRESOLVED stays `null` and the exit-code contract is
# byte-identical to before. Guarded source, same posture as the preflight
# helpers above: surfacing is best-effort, not a gate.
#
# NOTE: the merge-BLOCKING CodeRabbit gate is scripts/coderabbit-severity-gate.sh
# (a required check); this helper only REPORTS the count so the authoring
# agent can prioritize, mirroring codex-review-request.sh's per-finding
# `blocking` flag. It does not itself block.
BLOCKING_TIER_UNRESOLVED="null"
FEEDBACK_POLICY_PRESENT=false
if [ -f "$CONFIG" ] && grep -qE '^feedback_policy:' "$CONFIG" \
    && [ -r "$__CODERABBIT_WAIT_DIR/lib/feedback-policy-helpers.sh" ]; then
  # shellcheck source=lib/feedback-policy-helpers.sh
  . "$__CODERABBIT_WAIT_DIR/lib/feedback-policy-helpers.sh"
  set +e
  __CRW_REQUIRED_TIERS=$(resolve_required_tiers "$CONFIG")
  __CRW_RT_RC=$?
  set -e
  if [ "$__CRW_RT_RC" -eq 2 ]; then
    echo "ERROR: malformed feedback_policy block in $CONFIG (resolve_required_tiers exit 2)" >&2
    exit 3
  fi
  FEEDBACK_POLICY_PRESENT=true
fi

# Return 0 iff $1 (a tier like p0..p3|nitpick) is in the resolved set.
# Only meaningful when FEEDBACK_POLICY_PRESENT=true.
crw_tier_is_required() {
  local needle=$1 t
  [ -n "$needle" ] || return 1
  while IFS= read -r t; do
    [ "$t" = "$needle" ] && return 0
  done <<< "${__CRW_REQUIRED_TIERS:-}"
  return 1
}

# #489: CodeRabbit→Codex rate-limit failover. When CodeRabbit posts a
# rate-limit notice, request `@codex review` once so the PR advances via the
# real blocking gate (Codex) instead of idling on the advisory bot's hourly
# allowance. Composes with codex.request_by_default (#486) but fires regardless
# of it (MERGEPATH_PHASE_4A_GATED=true) for the duration of the stall. It is
# time-boxed and self-reverting: a single HEAD-pinned trigger per run, so once
# CodeRabbit recovers the steady-state posture returns with no permanent Codex
# pin. Default true (opt out with coderabbit.codex_failover_on_rate_limit:
# false). Only an explicit "false" disables it; a missing key keeps it on.
CODEX_FAILOVER_ON_RATE_LIMIT=$(coderabbit_field codex_failover_on_rate_limit)
CODEX_FAILOVER_ON_RATE_LIMIT=${CODEX_FAILOVER_ON_RATE_LIMIT:-true}
# The Codex request helper, invoked in --trigger-only mode on rate-limit.
# Overridable for tests via CODERABBIT_WAIT_CODEX_REQUEST_CMD.
CODEX_REQUEST_CMD="${CODERABBIT_WAIT_CODEX_REQUEST_CMD:-$__CODERABBIT_WAIT_DIR/codex-review-request.sh}"

# Stable marker CodeRabbit wraps its auto-pause "Reviews paused" NOTE in
# (#490 / #485). Keyed on directly — the prose ("## Reviews paused", the
# resume/review bullet list) is not versioned, but this HTML-comment marker
# is the same shape CodeRabbit emits for its other auto-generated notices
# (cf. the `rate limited by coderabbit.ai` marker on the same surface).
PAUSED_MARKER='review paused by coderabbit.ai'

# Stable marker CodeRabbit wraps its rate-limit notice in, on the same
# auto-generated surface as PAUSED_MARKER. Keyed on directly because the
# user-facing prose is NOT versioned and has already drifted: the original
# notice (#138) read "Rate limit exceeded" / "Please wait X minutes and Y
# seconds", but CodeRabbit's adaptive "Fair Usage Limits" variant reads
# "Review limit reached" / "Next review available in: N minutes" — matching
# NONE of the old text patterns. The HTML-comment marker is identical across
# both, so classify_comment() keys on it first (see #593: a drifted notice
# misclassified as a clean `review` false-cleared the gate and merged #591
# with no CodeRabbit review).
RATE_LIMIT_MARKER='rate limited by coderabbit.ai'

# CodeRabbit emits two distinct per-SHA signals:
#   1. Narrative review comment (issue/PR comment + inline diff comments).
#      The freshness-anchored polling loop watches for this. Posted only
#      when there's commentary to add — clean re-reviews on fix-up pushes
#      can skip it entirely.
#   2. `CodeRabbit` StatusContext check on the commit status API. Always
#      posted per-SHA, terminal state SUCCESS/FAILURE.
# The narrative comment alone is the historical terminal-state source,
# but on a fix-up push that genuinely cleared all prior findings, signal
# (2) flips to SUCCESS while signal (1) stays silent — and this script
# would burn its full MAX_WAIT_SECONDS budget waiting for a comment that
# never comes. Toggle off via `coderabbit.trust_status_context_for_clearance:
# false` in `.github/review-policy.yml` for repos that prefer the
# strict comment-driven gate. See nathanjohnpayne/mergepath#221.
TRUST_STATUS_CONTEXT=$(coderabbit_field trust_status_context_for_clearance)
TRUST_STATUS_CONTEXT=${TRUST_STATUS_CONTEXT:-true}
case "$TRUST_STATUS_CONTEXT" in
  true|false) ;;
  *)
    echo "ERROR: coderabbit.trust_status_context_for_clearance must be true|false; got '$TRUST_STATUS_CONTEXT'" >&2
    exit 3
    ;;
esac

STATUS_PROBE_ENABLED=$(coderabbit_field status_probe_enabled)
STATUS_PROBE_ENABLED=${STATUS_PROBE_ENABLED:-true}
case "$STATUS_PROBE_ENABLED" in
  true|false) ;;
  *)
    echo "ERROR: coderabbit.status_probe_enabled must be true|false; got '$STATUS_PROBE_ENABLED'" >&2
    exit 3
    ;;
esac

STATUS_PROBE_WAIT_SECONDS=$(coderabbit_field status_probe_wait_seconds)
STATUS_PROBE_WAIT_SECONDS=${STATUS_PROBE_WAIT_SECONDS:-60}
if ! [[ "$STATUS_PROBE_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.status_probe_wait_seconds must be an integer; got '$STATUS_PROBE_WAIT_SECONDS'" >&2
  exit 3
fi

# --- logging helpers --------------------------------------------------------

log() {
  echo "[coderabbit-wait] $*" >&2
}

die() {
  local code=$1
  shift
  echo "[coderabbit-wait] ERROR: $*" >&2
  exit "$code"
}

fetch_api_array() {
  local endpoint=$1
  local label=$2
  local raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || die 3 "failed to fetch $label: $raw"
  echo "$raw" | jq -s 'add // []' 2>/dev/null \
    || die 3 "failed to flatten $label pagination output"
}

fetch_api_array_best_effort() {
  local endpoint=$1
  local label=$2
  local raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || {
    log "best-effort fetch failed for $label: $raw"
    return 1
  }
  echo "$raw" | jq -s 'add // []' 2>/dev/null || {
    log "best-effort fetch failed to flatten $label pagination output"
    return 1
  }
}

# Fetch the CodeRabbit `StatusContext` check on the current HEAD SHA.
# Emits compact JSON with:
#   { "state": "success|failure|pending|error|missing", "created_at": "..." }
#
# `missing` covers both the no-statuses-yet case and any transient API
# hiccup (network, 5xx, etc.) — caller treats it as "fall through to
# the existing comment-driven path."
#
# Two defensive guards (CodeRabbit ⚠️ Critical on PR #224 round 1):
#
# 1. Filter by `creator.login == $BOT_LOGIN` in addition to context.
#    Anyone with write access to commit statuses can post a status
#    with the literal context string "CodeRabbit"; without the
#    creator filter, that's a spoof vector. The configured bot login
#    is the only signal we trust.
#
# 2. Use `sort_by(.created_at) | last` to pick the latest status, not
#    `head -n 1`. The /statuses endpoint does not guarantee chronological
#    ordering across calls, so `head` could return a stale status if
#    multiple have been posted on the same SHA (e.g., re-evaluation
#    after a CodeRabbit retry).
#
# Endpoint choice: `/commits/{sha}/statuses` (plural) returns each
# status object with full `creator` details. The singular
# `/commits/{sha}/status` rolls up state but omits per-status creator
# fields, which would defeat guard 1. Confirmed empirically — see
# PR #224 round 2.
check_status_context_record() {
  local resp
  # Pagination (CodeRabbit ⚠️ Minor @ line 267 on PR #224 round 2):
  # `/commits/{ref}/statuses` defaults to per_page=30 and returns
  # statuses in reverse chronological order. Without `--paginate`, a
  # commit with >30 statuses (e.g., long-running PR with retries)
  # could miss the latest CodeRabbit entry in the unpaginated first
  # page if non-CodeRabbit statuses crowd it out. `--paginate` plus
  # `jq -s 'add // []'` flattens all pages into a single array before
  # the context+creator filter runs.
  resp=$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/statuses" 2>/dev/null \
    | jq -s 'add // []' 2>/dev/null) || {
    jq -nc '{state: "missing", created_at: ""}'
    return
  }
  echo "$resp" | jq -c --arg bot "$BOT_LOGIN" '
    [ .[]?
      | select(.context == "CodeRabbit")
      | select((.creator.login // "") == $bot)
    ]
    | sort_by(.created_at)
    | last
    | if . == null then
        {state: "missing", created_at: ""}
      else
        {state: (.state // "missing"), created_at: (.created_at // "")}
      end
  '
}

check_status_context() {
  check_status_context_record | jq -r '.state'
}

# --- fetch PR metadata ------------------------------------------------------

log "PR $REPO#$PR_NUMBER — fetching HEAD commit metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) || die 3 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 3 "could not determine HEAD sha for PR #$PR_NUMBER"
fi

# Base branch + draft state for the #490 static-skip checks below. All
# come from the PR metadata already in hand — no extra API call. The
# repo default branch is needed because CodeRabbit always reviews PRs
# into the default branch even when it is not redundantly listed in
# base_branches, so the non-base-branch skip must never fire for it.
PR_BASE_REF=$(echo "$PR_JSON" | jq -r '.base.ref // ""')
PR_IS_DRAFT=$(echo "$PR_JSON" | jq -r 'if .draft == true then "true" else "false" end')
PR_DEFAULT_BRANCH=$(echo "$PR_JSON" | jq -r '.base.repo.default_branch // ""')

HEAD_COMMITTER_DATE=$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>&1) \
  || die 3 "failed to fetch commit date for $HEAD_SHA: $HEAD_COMMITTER_DATE"

# HEAD freshness anchor. Two stacked guards — committer date alone is
# unreliable:
#
#   Layer 1 (force-push): advance the anchor past any
#     `head_ref_force_pushed` event on this PR's timeline. Closes the
#     force-push-with-old-commit false-clear. See #140 round-2 Codex
#     finding (P1, line 270).
#
#   Layer 2 (wallclock floor): max the anchor with NOW - window.
#     Without this, an ordinary push of a commit with an old committer
#     date (cherry-pick, rebase with `--committer-date-is-author-date`,
#     or a commit whose metadata was rewritten) lets CodeRabbit comments
#     from a prior review round pass the filter and the script exits
#     cleared/findings without waiting for a real review on the new
#     HEAD. See #51/#52/#30/#35 round-3 Codex findings ("Anchor
#     CodeRabbit freshness to push time", "Gate reviews against a
#     fresh poll anchor", "Tie CodeRabbit freshness to push time",
#     "Filter CodeRabbit state by current HEAD SHA", "Gate on review
#     commit rather than comment timestamp").
#
# The two layers compose: force-push events get exact timestamps when
# available, and the wallclock floor bounds residual exposure for the
# ordinary-push path where the GitHub API does not expose a reliable
# per-push time for non-force pushes.
#
# Mirrors the REACTION_THRESHOLD computation in codex-review-request.sh,
# which uses `reaction_freshness_window_seconds` as its floor. Here the
# knob is `coderabbit.wallclock_freshness_window_seconds` (default
# 1800s / 30min — long enough for a typical Phase 2.5 cycle to land,
# short enough that cross-cycle staleness is caught).
HEAD_ANCHOR="$HEAD_COMMITTER_DATE"
ANCHOR_SOURCE="HEAD committer date"
TIMELINE_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/timeline" "PR timeline")
LATEST_FORCE_PUSH_TIME=$(echo "$TIMELINE_JSON" | jq -r '
  [ .[] | select(.event == "head_ref_force_pushed") | .created_at ]
  | max // ""
')
if [ -n "$LATEST_FORCE_PUSH_TIME" ] && [[ "$LATEST_FORCE_PUSH_TIME" > "$HEAD_ANCHOR" ]]; then
  HEAD_ANCHOR="$LATEST_FORCE_PUSH_TIME"
  ANCHOR_SOURCE="head_ref_force_pushed @ $LATEST_FORCE_PUSH_TIME"
fi
HEAD_IDENTITY_ANCHOR="$HEAD_ANCHOR"

# Layer 2 — wallclock freshness floor.
EPOCH_NOW=$(date +%s)
EPOCH_FLOOR=$((EPOCH_NOW - WALLCLOCK_FRESHNESS_WINDOW_SECONDS))
if FLOOR_ISO=$(date -u -r "$EPOCH_FLOOR" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  :
else
  FLOOR_ISO=$(date -u -d "@$EPOCH_FLOOR" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
    || die 3 "could not compute wallclock freshness floor from epoch $EPOCH_FLOOR"
fi
if [[ "$FLOOR_ISO" > "$HEAD_ANCHOR" ]]; then
  HEAD_ANCHOR="$FLOOR_ISO"
  ANCHOR_SOURCE="wallclock floor (NOW - ${WALLCLOCK_FRESHNESS_WINDOW_SECONDS}s)"
fi

log "HEAD = $HEAD_SHA committed at $HEAD_COMMITTER_DATE"
log "anchor = $HEAD_ANCHOR (source: $ANCHOR_SOURCE)"
log "max_wait = ${MAX_WAIT_SECONDS}s   max_rate_limit_retries = $MAX_RATE_LIMIT_RETRIES   freshness_window = ${WALLCLOCK_FRESHNESS_WINDOW_SECONDS}s"
log "status_probe_enabled = $STATUS_PROBE_ENABLED   status_probe_wait = ${STATUS_PROBE_WAIT_SECONDS}s"

# --- state machine ----------------------------------------------------------

# Parse a rate-limit wait window from a CodeRabbit comment body.
# Emits seconds on stdout. Returns 1 if no window found.
parse_rate_limit_window() {
  local body=$1
  # "Please wait X minutes and Y seconds before requesting another review"
  local mins secs total
  if [[ "$body" =~ [Pp]lease\ wait\ +\*?\*?([0-9]+)\*?\*?\ +minutes?\ +and\ +\*?\*?([0-9]+)\*?\*?\ +seconds? ]]; then
    mins=${BASH_REMATCH[1]}
    secs=${BASH_REMATCH[2]}
    total=$((mins * 60 + secs))
    echo "$total"
    return 0
  fi
  if [[ "$body" =~ [Pp]lease\ wait\ +\*?\*?([0-9]+)\*?\*?\ +seconds? ]]; then
    secs=${BASH_REMATCH[1]}
    echo "$secs"
    return 0
  fi
  if [[ "$body" =~ [Pp]lease\ wait\ +\*?\*?([0-9]+)\*?\*?\ +minutes? ]]; then
    mins=${BASH_REMATCH[1]}
    total=$((mins * 60))
    echo "$total"
    return 0
  fi
  # Adaptive "Fair Usage Limits" variant (#593): "Next review available in:
  # **N minutes**" (or "... N seconds"). CodeRabbit wraps the label and value
  # in markdown bold, so the star/space run between them varies — [* ]* absorbs
  # it. Held in a variable and matched unquoted so the literal spaces are part
  # of the regex, not shell word-split (bash 3.2 safe).
  local re_next_min='[Nn]ext review available in:[* ]*([0-9]+)[* ]*minutes?'
  if [[ "$body" =~ $re_next_min ]]; then
    mins=${BASH_REMATCH[1]}
    total=$((mins * 60))
    echo "$total"
    return 0
  fi
  local re_next_sec='[Nn]ext review available in:[* ]*([0-9]+)[* ]*seconds?'
  if [[ "$body" =~ $re_next_sec ]]; then
    secs=${BASH_REMATCH[1]}
    echo "$secs"
    return 0
  fi
  return 1
}

# Classify a CodeRabbit comment body. Emits one of:
#   rate_limit | paused | in_progress | status_probe | review
classify_comment() {
  local body=$1
  # #593: key on the stable auto-generated marker FIRST, before any prose
  # match, so a rate-limit notice is recognized regardless of CodeRabbit's
  # user-facing wording ("Rate limit exceeded" vs "Review limit reached" /
  # "Fair Usage Limits"). Fixed-string grep (-F) so the literal dots in
  # "coderabbit.ai" are not treated as regex wildcards, mirroring PAUSED_MARKER.
  if printf '%s' "$body" | grep -Fqi "$RATE_LIMIT_MARKER"; then
    echo "rate_limit"
    return
  fi
  # Legacy prose fallback: the original notice text, retained so a notice that
  # somehow lacks the marker (or an older cached body) still classifies.
  if echo "$body" | grep -qiE 'rate[- ]limit exceeded'; then
    echo "rate_limit"
    return
  fi
  # Auto-pause (#490 / #485): the "Reviews paused" NOTE carries a stable
  # auto-generated marker. Match the marker with a fixed-string grep so the
  # literal dots in "coderabbit.ai" are not treated as regex wildcards.
  # Checked before in_progress/review so the durable pause is never mistaken
  # for a slow review.
  if printf '%s' "$body" | grep -Fqi "$PAUSED_MARKER"; then
    echo "paused"
    return
  fi
  # CodeRabbit's free-form command replies, including
  # `@coderabbitai, how is the review going?`, are narration. They
  # summarize current state and may mention open threads, but they are
  # not a review on HEAD and must never clear the #136 freshness gate.
  if echo "$body" | grep -qiE 'CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits'; then
    echo "status_probe"
    return
  fi
  if echo "$body" | grep -qiE 'review in progress|currently reviewing|commits? under review'; then
    echo "in_progress"
    return
  fi
  echo "review"
}

# Scan the PR-level `issues/{pr}/comments` endpoint for the latest
# CodeRabbit comment on or after HEAD_ANCHOR. CodeRabbit edits its
# summary comment in place, so freshness is max(created_at, updated_at)
# rather than created_at alone. Emits JSON to stdout.
# Empty object {} if nothing qualifying yet.
#
# Only the issues endpoint is the terminal-state source. CodeRabbit's
# PR-level summary/status comments (walkthrough, "No actionable
# comments generated", rate-limit WARNING, in-progress markers) all
# land here. Inline `pulls/{pr}/comments` are per-line findings that
# CodeRabbit can emit BEFORE the PR-level summary lands during a
# single review cycle — treating an inline comment as terminal state
# could cause a "cleared"/"findings" exit while the bot is still
# writing more findings or still mid-walkthrough. See #140 round-3
# Codex finding (P1, line 285). Inline findings are instead scanned
# separately by count_potential_issues() only after this function
# reports a PR-level terminal state.
latest_comment_from_issue_comments() {
  local issue_comments=$1
  local latest
  latest=$(echo "$issue_comments" | jq --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" '
    def status_probe_reply:
      ((.body // "") | test("CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits"; "i"));
    [ .[]
      | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(.fresh_at >= $after)
      | select(status_probe_reply | not)
    ]
    | sort_by(.fresh_at)
    | last // null
  ')

  if [ "$latest" = "null" ]; then
    echo '{}'
    return
  fi
  echo "$latest" | jq '{id, created_at, updated_at, fresh_at, endpoint: "issues", body}'
}

scan_latest_comment() {
  local issue_comments
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments")
  latest_comment_from_issue_comments "$issue_comments"
}

scan_latest_comment_best_effort() {
  local issue_comments
  issue_comments=$(fetch_api_array_best_effort "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") || {
    echo '{}'
    return 0
  }
  latest_comment_from_issue_comments "$issue_comments"
}

# Count unaddressed "Potential issue" / ⚠️ markers in the pulls inline
# comment list, scoped to the LATEST CodeRabbit review on the current
# HEAD. The naive "all bot comments after HEAD_ANCHOR" shape would keep
# stale findings from an earlier review round (same HEAD, pre-retry) in
# the count forever, so a PR could stay permanently in the `findings`
# state even after the next review comes back clean. Mirror the latest-
# review-scoping pattern codex-review-request.sh uses via
# `pull_request_review_id`. See propagation-round Codex finding (P1)
# on device-platform-reporting#51.
#
# CodeRabbit may later reply to a finding thread with its hidden
# `review_comment_addressed` marker after an agent fixes/rebuts the
# finding. Treat that bot-authored marker as authoritative for this
# helper's advisory gate; ordinary human/agent replies do not clear a
# finding by themselves.
count_potential_issues() {
  local reviews pulls_comments latest_review_id
  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")
  # Pin the latest-review selection to the current HEAD commit
  # (`commit_id == HEAD_SHA`), not just freshness (`submitted_at >=
  # HEAD_ANCHOR`). A review submitted after the anchor but referencing an
  # intermediate commit (e.g. a rapid push sequence where CodeRabbit
  # reviewed an earlier SHA) must not be chosen as the HEAD review. Mirror
  # the HEAD-pinning in scripts/codex-review-check.sh (commit_id == $sha).
  latest_review_id=$(echo "$reviews" | jq --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" --arg head_sha "$HEAD_SHA" '
    [ .[]
      | select(.user.login == $bot)
      | select(.submitted_at >= $after)
      | select(.commit_id == $head_sha)
    ]
    | sort_by(.submitted_at) | last
    | if . == null then null else .id end
  ')

  if [ -z "$latest_review_id" ] || [ "$latest_review_id" = "null" ]; then
    echo "0"
    return
  fi

  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments")
  echo "$pulls_comments" | jq \
    --arg bot "$BOT_LOGIN" \
    --argjson review_id "$latest_review_id" '
    [ .[]
      | select(.user.login == $bot)
      | select(.in_reply_to_id != null)
      | select((.body // "") | test("review_comment_addressed"; "i"))
      | .in_reply_to_id
    ] as $addressed_root_ids
    | [ .[]
      | select(.user.login == $bot)
      | select(.pull_request_review_id == $review_id)
      | select(.in_reply_to_id == null)
      | select((.body // "") | test("Potential issue|⚠️"; "i"))
      | select(.id as $id | ($addressed_root_ids | index($id)) == null)
    ] | length
  '
}

# Count unaddressed inline findings on HEAD whose coderabbit_tier_of tier is
# in the resolved required set (#577). Tier-aware sibling of
# count_potential_issues: SAME latest-review-on-HEAD + review_comment_addressed
# scoping, but stage 1 (jq) emits the candidate finding BODIES and stage 2
# (bash) classifies each with the shared coderabbit_tier_of and keeps only
# required-tier ones — reusing the classifier rather than re-implementing its
# heuristic in jq. Additive/advisory only: the return value populates the
# JSON's blocking_tier_unresolved and NEVER feeds an exit code. Guarded by
# FEEDBACK_POLICY_PRESENT at the single call site, so it never runs (and the
# lib functions are never referenced) when the block is absent.
count_blocking_tier_issues() {
  local reviews pulls_comments latest_review_id candidates cand_count blocking body tier i
  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")
  latest_review_id=$(echo "$reviews" | jq --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" --arg head_sha "$HEAD_SHA" '
    [ .[]
      | select(.user.login == $bot)
      | select(.submitted_at >= $after)
      | select(.commit_id == $head_sha)
    ]
    | sort_by(.submitted_at) | last
    | if . == null then null else .id end
  ')

  if [ -z "$latest_review_id" ] || [ "$latest_review_id" = "null" ]; then
    echo "0"
    return
  fi

  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments")
  # Stage 1: same addressed-root exclusion + latest-review scoping as
  # count_potential_issues, but emit each candidate's body (NOT a count) so
  # stage 2 can tier-classify. We keep the `Potential issue|⚠️` prefilter OFF
  # here on purpose: coderabbit_tier_of also grades 🧹 Nitpick / Refactor
  # findings, which a required nitpick/p2 tier must be able to catch.
  candidates=$(echo "$pulls_comments" | jq -c \
    --arg bot "$BOT_LOGIN" \
    --argjson review_id "$latest_review_id" '
    [ .[]
      | select(.user.login == $bot)
      | select(.in_reply_to_id != null)
      | select((.body // "") | test("review_comment_addressed"; "i"))
      | .in_reply_to_id
    ] as $addressed_root_ids
    | [ .[]
      | select(.user.login == $bot)
      | select(.pull_request_review_id == $review_id)
      | select(.in_reply_to_id == null)
      | select(.id as $id | ($addressed_root_ids | index($id)) == null)
      | (.body // "")
    ]
  ')

  blocking=0
  cand_count=$(echo "$candidates" | jq 'length')
  i=0
  while [ "$i" -lt "$cand_count" ]; do
    body=$(echo "$candidates" | jq -r ".[$i]")
    tier=$(coderabbit_tier_of "$body")
    if crw_tier_is_required "$tier"; then
      blocking=$((blocking + 1))
    fi
    i=$((i + 1))
  done
  echo "$blocking"
}

# Returns 0 (true) if the latest PR-level CodeRabbit SUMMARY comment body
# carries a `Potential issue` / ⚠️ marker, else 1.
#
# count_potential_issues() scans only INLINE `pulls/{pr}/comments`. When
# CodeRabbit surfaces a finding solely in its PR-level summary body
# (issues/{pr}/comments) while the inline count is zero, the findings gate
# would otherwise wrongly clear. This OR-side check closes that gap (#535).
# Mirrors latest_comment_from_issue_comments: filter to the bot login,
# newest comment on/after the HEAD anchor (max of created_at/updated_at,
# since CodeRabbit edits the summary in place).
summary_body_has_potential_issue_marker() {
  local issue_comments latest_body
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments")
  # Mirror latest_comment_from_issue_comments: exclude status-probe narration
  # replies so a newer probe comment doesn't mask an earlier real summary that
  # contains a "Potential issue" marker (false-clear of the #535 gate).
  latest_body=$(echo "$issue_comments" | jq -r --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" '
    def status_probe_reply:
      ((.body // "") | test("CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits"; "i"));
    [ .[]
      | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(.fresh_at >= $after)
      | select(status_probe_reply | not)
    ]
    | sort_by(.fresh_at)
    | last
    | (.body // "")
  ')
  printf '%s' "$latest_body" | grep -qiE 'Potential issue|⚠️'
}

# SHA-scoped variant of count_potential_issues, used by the StatusContext
# fast-path. Counts CodeRabbit inline findings whose `commit_id` (the SHA
# GitHub considers the comment currently anchored to, after rebases / new
# commits) equals the given SHA and whose creation time is not older than
# HEAD_IDENTITY_ANCHOR.
#
# Why this is needed (codex CHANGES_REQUESTED on PR #224 round 2 +
# CodeRabbit ⚠️ Major @ line 581): the freshness-anchored count_potential_
# issues filters reviews with `submitted_at >= HEAD_ANCHOR`. Once the same
# unchanged HEAD sits longer than `coderabbit.wallclock_freshness_window_
# seconds` (default 1800s / 30 min), HEAD_ANCHOR advances past the prior
# CodeRabbit review's submitted_at, latest_review_id becomes null, and the
# helper returns 0 — false-clearing the fast-path even while the same SHA
# still has unresolved Potential issue/⚠️ inline findings. The fast-path is
# the only caller that has authoritative per-SHA scope (from the StatusContext
# check) and should leverage it.
#
# Why still keep a non-wallclock freshness floor: GitHub can preserve or
# remap inline review comments across a rebase/force-push so an old comment
# appears to have `commit_id == HEAD_SHA`. HEAD_IDENTITY_ANCHOR is captured
# before the moving wallclock floor is applied, so stale pre-head inline
# comments are ignored without losing genuine old-but-still-current findings
# on an unchanged head.
#
# Filter shape: root inline review comments where the bot author posted
# a comment whose `commit_id == HEAD_SHA` (i.e., GitHub still considers
# it applicable to HEAD after any rebases) and whose body contains a
# `Potential issue` / `⚠️` marker, excluding roots CodeRabbit itself
# later marked with `review_comment_addressed`. Resolved-thread state is
# not consulted directly; the explicit bot marker is the narrow signal
# that a current-head finding has been addressed without relying on
# GitHub conversation-resolution state.
count_potential_issues_for_sha() {
  local sha=$1
  local pulls_comments
  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments")
  echo "$pulls_comments" | jq \
    --arg bot "$BOT_LOGIN" \
    --arg sha "$sha" \
    --arg after "$HEAD_IDENTITY_ANCHOR" '
    [ .[]
      | select(.user.login == $bot)
      | select(.in_reply_to_id != null)
      | select((.body // "") | test("review_comment_addressed"; "i"))
      | .in_reply_to_id
    ] as $addressed_root_ids
    | [ .[]
      | select(.user.login == $bot)
      | select(.commit_id == $sha)
      | select((.created_at // "") >= $after)
      | select(.in_reply_to_id == null)
      | select((.body // "") | test("Potential issue|⚠️"; "i"))
      | select(.id as $id | ($addressed_root_ids | index($id)) == null)
    ] | length
  '
}

iso_on_or_after() {
  local lhs=$1 rhs=$2 rc
  if [ -z "$lhs" ] || [ "$lhs" = "null" ] || [ -z "$rhs" ] || [ "$rhs" = "null" ]; then
    return 0
  fi

  jq -en --arg lhs "$lhs" --arg rhs "$rhs" \
    '($lhs | fromdateiso8601) >= ($rhs | fromdateiso8601)' >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 0 ;;
  esac
}

# #596: return 0 (true) when `status` landed at most `grace` seconds after
# `comment` — i.e. status <= comment + grace. Used to recognize CodeRabbit's
# near-simultaneous rate-limit StatusContext flip (a `status` within `grace` of
# the notice) versus a genuinely later re-review (`status` well after it). Fails
# OPEN (true → suppress the fast-path) on unparseable input, matching the
# conservative posture of iso_on_or_after.
iso_within_seconds_after() {
  local comment=$1 status=$2 grace=$3 rc
  if [ -z "$comment" ] || [ "$comment" = "null" ] || [ -z "$status" ] || [ "$status" = "null" ]; then
    return 0
  fi
  jq -en --arg c "$comment" --arg s "$status" --argjson g "$grace" \
    '($s | fromdateiso8601) <= ($c | fromdateiso8601) + $g' >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 0 ;;
  esac
}

status_context_fast_path_blocked_by_comment() {
  local status_created_at=$1
  local latest class comment_id comment_created_at comment_fresh_at comment_body
  latest=$(scan_latest_comment)
  if [ "$(echo "$latest" | jq 'length')" = "0" ]; then
    return 1
  fi

  class=$(classify_comment "$(echo "$latest" | jq -r '.body')")
  case "$class" in
    rate_limit|paused|in_progress)
      # #490: `paused` joins rate_limit/in_progress here. An auto-pause NOTE
      # is durable and, like the rate-limit notice, does not reference HEAD;
      # a pause posted at/after a stale StatusContext success must suppress
      # the fast-path so the wait keeps polling (and re-invokes `resume`)
      # instead of false-clearing over a paused review.
      comment_id=$(echo "$latest" | jq -r '.id')
      comment_created_at=$(echo "$latest" | jq -r '.created_at // .fresh_at // .updated_at')
      comment_fresh_at=$(echo "$latest" | jq -r '.fresh_at // .updated_at // .created_at')
      comment_body=$(echo "$latest" | jq -r '.body')
      if printf '%s' "$comment_body" | grep -Fq "$HEAD_SHA"; then
        # #596: a HEAD-referencing rate_limit/paused/in_progress notice means
        # CodeRabbit has not (yet) completed a review of this HEAD. CodeRabbit
        # nonetheless flips its commit StatusContext to success while
        # rate-limited, ~1s AFTER posting the notice, so the previous
        # `iso_on_or_after comment_fresh_at status_created_at` gate treated that
        # 1s-newer success as authoritative and false-cleared (the #595 dogfood:
        # notice @07:49:36, status success @07:49:37, zero review). Distinguish
        # by latency rather than raw ordering: SUPPRESS a success that landed
        # within an effective grace window of the notice; TRUST a success that
        # postdates it by more (a genuine later re-review, which per #221 can be
        # silent, i.e. flip the status with no new summary comment).
        #
        # The effective grace is the base near-simultaneous-flip window
        # (STATUS_SUCCESS_GRACE_SECONDS), WIDENED to CodeRabbit's own published
        # wait window when the notice carries one. A rate-limit notice ("Next
        # review available in: N minutes") promises no review before
        # comment_created + N, so a success anywhere inside that window cannot be
        # a completed review no matter how far past the base grace it lands
        # (#599 Codex P2: with a fixed 120s grace, a success at 121s but still
        # mid-13-minute-window would false-clear). paused/in_progress notices
        # carry no parseable window, so they keep the base grace. The
        # RATE_LIMIT_BUFFER_SECONDS margin mirrors the retry-sleep path.
        local effective_grace=$STATUS_SUCCESS_GRACE_SECONDS
        local published_window
        published_window=$(parse_rate_limit_window "$comment_body" || echo "")
        if [ -n "$published_window" ]; then
          local windowed=$((published_window + RATE_LIMIT_BUFFER_SECONDS))
          if [ "$windowed" -gt "$effective_grace" ]; then
            effective_grace=$windowed
          fi
        fi
        if iso_within_seconds_after "$comment_fresh_at" "$status_created_at" "$effective_grace"; then
          log "StatusContext success ignored because latest CodeRabbit comment id=$comment_id class=$class references current HEAD $HEAD_SHA and the success (status_created=$status_created_at) is within the ${effective_grace}s window after the notice (fresh_at=$comment_fresh_at) — CodeRabbit has not completed a review of this HEAD (near-simultaneous rate-limit status flip, or a success still inside the published wait window)"
          return 0
        fi
        log "StatusContext success remains authoritative: it postdates the HEAD-referencing $class notice id=$comment_id ($HEAD_SHA) by more than ${effective_grace}s (fresh_at=$comment_fresh_at, status_created=$status_created_at) — a genuine later re-review of the current HEAD"
        return 1
      fi
      # #446: a rate_limit/paused/in_progress comment POSTED (created) at/after
      # the StatusContext flipped to success means CodeRabbit re-entered a
      # rate-limited / paused / in-progress state — the fast-path must not
      # declare clearance over it even though the notice does not reference
      # HEAD. Compare CREATED_AT, not fresh_at: an OLD comment from a prior
      # round that merely got edited after the success is stale and must NOT
      # suppress (the 263caf3 "Bug 6" regression — an unscoped non-HEAD
      # comment created before the success still clears). Only a comment
      # actually posted at/after the success suppresses.
      if iso_on_or_after "$comment_created_at" "$status_created_at"; then
        log "StatusContext success suppressed because latest CodeRabbit comment id=$comment_id class=$class created=$comment_created_at is at/after status_created=$status_created_at (no HEAD $HEAD_SHA reference, but a post-success rate-limit/paused/in-progress notice) — keep polling"
        return 0
      fi
      log "StatusContext success remains authoritative because latest CodeRabbit comment id=$comment_id class=$class does not reference current HEAD $HEAD_SHA and was created=$comment_created_at before status_created=$status_created_at"
      return 1
      ;;
  esac

  return 1
}

verify_reviewer_write_identity() {
  local purpose=$1
  # Identity check (#412): CodeRabbit helper comments are reviewer-token
  # writes. Fail closed BEFORE the REST mutation if the GH_TOKEN that
  # will sign the call does not resolve to the expected reviewer
  # identity. Opt-out via CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 for
  # tests only.
  #
  # r3 (#284): fail CLOSED if the helper is missing or non-executable.
  # The previous shape ANDed the opt-out and `[ -x "$CHECKER" ]` so a
  # rename / delete / chmod -x silently skipped the gate. Helper
  # presence is now a hard error inside the opt-out branch.
  if [ "${CODERABBIT_WAIT_SKIP_IDENTITY_CHECK:-0}" != "1" ]; then
    local checker="$(dirname "${BASH_SOURCE[0]}")/identity-check.sh"
    if [ ! -x "$checker" ]; then
      echo "ERROR: identity-check helper missing or non-executable: $checker" >&2
      echo "       Refusing to post $purpose comment without identity verification." >&2
      echo "       Restore the helper, or opt out via" >&2
      echo "       CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 (dev only)." >&2
      return 1
    fi
    # Lazy token-derived expected identity (#438): no explicit identity
    # env was set at startup, so derive the expected login from the
    # token that will sign this write — constrained to
    # available_reviewers. An unconstrained derivation would make the
    # check below a tautology; the allow-list keeps it fail-closed: a
    # non-reviewer token falls back to the static default and fails
    # verification exactly as before. Derived here (write time) rather
    # than at startup so read-only runs never pay the extra API call.
    if [ -z "$EXPECTED_REVIEWER_IDENTITY" ]; then
      local token_login
      token_login=$(gh_reviewer api user --jq .login 2>/dev/null || true)
      if login_is_available_reviewer "$token_login"; then
        EXPECTED_REVIEWER_IDENTITY="$token_login"
        log "derived expected reviewer identity '$token_login' from GH_TOKEN (allow-listed in available_reviewers)"
      else
        EXPECTED_REVIEWER_IDENTITY="$(gh_default_reviewer_identity)"
        log "GH_TOKEN login '${token_login:-<unresolvable>}' is not in available_reviewers; falling back to default expected reviewer '$EXPECTED_REVIEWER_IDENTITY'"
      fi
    fi
    GH_TOKEN="$GH_TOKEN" "$checker" --expect-token-identity "$EXPECTED_REVIEWER_IDENTITY" \
      || return 1
  fi
}

post_reviewer_comment() {
  local purpose=$1
  local body=$2
  local raw
  verify_reviewer_write_identity "$purpose" || return 1
  raw=$(gh_reviewer api --method POST "repos/$REPO/issues/$PR_NUMBER/comments" \
    -f body="$body" 2>&1) || {
    log "failed to post $purpose comment: $raw"
    return 1
  }
  printf '%s\n' "$raw"
}

post_retry_trigger() {
  # Strip the `[bot]` suffix that GitHub REST uses for App logins —
  # @-mentions address the user-facing handle (`@coderabbitai`), not
  # the API login (`coderabbitai[bot]`). Using the configured
  # BOT_LOGIN here instead of a hardcoded string means a repo that
  # overrides `coderabbit.bot_login` (e.g., to point at a fork or a
  # differently-named review bot) gets consistent polling and
  # triggering identities. See #140 round-3 Codex finding (P2, line 320).
  local mention="@${BOT_LOGIN%\[bot\]}"
  local body="${mention}, try again."
  log "posting retry trigger comment to PR #$PR_NUMBER as $mention"
  post_reviewer_comment "retry-trigger" "$body" >/dev/null \
    || die 3 "failed to post retry-trigger comment"
}

# Re-invoke CodeRabbit out of an auto-pause (#490). MUST be `resume`, not a
# one-shot `review`: the auto-pause is durable and a single `review`
# re-pauses after the next fix-up push, whereas `resume` re-enables
# incremental auto-review. Same BOT_LOGIN-derived mention as the retry
# trigger so a bot_login override stays consistent.
post_resume_trigger() {
  local mention="@${BOT_LOGIN%\[bot\]}"
  local body="${mention} resume"
  log "posting auto-pause resume trigger comment to PR #$PR_NUMBER as $mention"
  post_reviewer_comment "resume-trigger" "$body" >/dev/null \
    || die 3 "failed to post resume-trigger comment"
}

find_status_probe_reply() {
  local after=$1
  local issue_comments
  issue_comments=$(fetch_api_array_best_effort "repos/$REPO/issues/$PR_NUMBER/comments" "status probe reply issue comments") || return 1

  echo "$issue_comments" | jq --arg bot "$BOT_LOGIN" --arg after "$after" '
    def status_probe_reply:
      ((.body // "") | test("CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits"; "i"));
    [ .[]
      | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(.fresh_at >= $after)
      | select(status_probe_reply)
    ]
    | sort_by(.fresh_at)
    | last // null
  '
}

emit_terminal_review_after_probe_if_present() {
  local latest class potential_issues review_json
  latest=$(scan_latest_comment_best_effort)
  if [ "$(echo "$latest" | jq 'length')" = "0" ]; then
    return 0
  fi

  class=$(classify_comment "$(echo "$latest" | jq -r '.body')")
  case "$class" in
    review)
      potential_issues=$(count_potential_issues)
      review_json=$(echo "$latest" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
      # #535: also honor a PR-level summary-body marker (the inline count
      # scans only pulls/{pr}/comments) so the probe-wait clearance path
      # cannot false-clear over a summary-only finding either.
      if [ "$potential_issues" -gt 0 ]; then
        log "CodeRabbit review landed during status-probe wait with $potential_issues Potential issue/⚠️ marker(s) — emitting findings (exit 2)"
        emit_json_and_exit "findings" 2 "$review_json" "$potential_issues"
      elif summary_body_has_potential_issue_marker; then
        log "CodeRabbit review landed during status-probe wait with 0 inline markers but a Potential issue/⚠️ marker in the PR-level summary body — emitting findings (exit 2)"
        emit_json_and_exit "findings" 2 "$review_json" "$potential_issues"
      fi
      log "CodeRabbit review landed during status-probe wait with no high-severity markers — emitting cleared (exit 0)"
      emit_json_and_exit "cleared" 0 "$review_json" 0
      ;;
    *)
      log "latest CodeRabbit comment after status-probe wait is class=$class; continuing timeout"
      ;;
  esac
}

status_probe_no_reply_json() {
  local posted=$1
  local comment_id=$2
  local waited=$3
  jq -nc \
    --argjson posted "$posted" \
    --argjson comment_id "$comment_id" \
    --argjson waited "$waited" '
    {
      enabled: true,
      posted: $posted,
      reply_present: false,
      reply: null,
      waited_seconds: $waited
    } + (if $posted then {comment_id: $comment_id} else {} end)
  '
}

run_status_probe_once() {
  local mention body posted_json probe_comment_id probe_anchor probe_start probe_deadline
  local now remaining sleep_for reply waited

  [ "$STATUS_PROBE_RAN" = "false" ] || return 0
  STATUS_PROBE_RAN=true

  if [ "$STATUS_PROBE_ENABLED" != "true" ]; then
    log "status probe disabled — timeout JSON will include status_probe.posted=false"
    STATUS_PROBE_JSON=$(jq -nc '{enabled:false, posted:false, reply_present:false, reply:null, waited_seconds:0}')
    return 0
  fi

  mention="@${BOT_LOGIN%\[bot\]}"
  body="${mention}, how is the review going?"
  log "posting CodeRabbit status probe before timeout (${STATUS_PROBE_WAIT_SECONDS}s wait budget)"
  if ! posted_json=$(post_reviewer_comment "status-probe" "$body"); then
    log "status probe post failed; timeout remains advisory"
    STATUS_PROBE_JSON=$(status_probe_no_reply_json false null 0)
    return 0
  fi
  probe_comment_id=$(echo "$posted_json" | jq -r '.id // null' 2>/dev/null || echo "null")
  case "$probe_comment_id" in
    ""|null) probe_comment_id=null ;;
    *[!0-9]*) probe_comment_id=null ;;
  esac
  probe_anchor=$(echo "$posted_json" | jq -r '.created_at // empty' 2>/dev/null || true)
  if [ -z "$probe_anchor" ]; then
    probe_anchor=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi

  probe_start=$(date +%s)
  probe_deadline=$((probe_start + STATUS_PROBE_WAIT_SECONDS))
  reply='null'

  while :; do
    if ! reply=$(find_status_probe_reply "$probe_anchor"); then
      waited=$(( $(date +%s) - probe_start ))
      log "status probe reply poll failed; timeout remains advisory"
      STATUS_PROBE_JSON=$(status_probe_no_reply_json true "$probe_comment_id" "$waited")
      return 0
    fi
    if [ "$reply" != "null" ]; then
      break
    fi

    now=$(date +%s)
    if [ "$now" -ge "$probe_deadline" ]; then
      break
    fi

    remaining=$((probe_deadline - now))
    sleep_for=$STATUS_PROBE_POLL_INTERVAL_SECONDS
    if [ "$remaining" -lt "$sleep_for" ]; then
      sleep_for=$remaining
    fi
    [ "$sleep_for" -gt 0 ] || break
    sleep "$sleep_for"
  done

  waited=$(( $(date +%s) - probe_start ))
  if [ "$reply" != "null" ]; then
    log "CodeRabbit status probe reply received after ${waited}s: $(echo "$reply" | jq -r '(.body // "")[0:200] | gsub("[\r\n]+"; " ")')"
    STATUS_PROBE_JSON=$(echo "$reply" | jq \
      --argjson comment_id "$probe_comment_id" \
      --argjson waited "$waited" '
      {
        enabled: true,
        posted: true,
        comment_id: $comment_id,
        reply_present: true,
        reply: {
          id,
          created_at,
          updated_at,
          fresh_at,
          body_excerpt: ((.body // "")[0:500])
        },
        waited_seconds: $waited
      }
    ')
  else
    log "no CodeRabbit status probe reply within ${STATUS_PROBE_WAIT_SECONDS}s"
    STATUS_PROBE_JSON=$(status_probe_no_reply_json true "$probe_comment_id" "$waited")
  fi
}

emit_timeout() {
  local message=$1
  log "$message"
  # Once a pause has been observed, a timeout is a still-paused condition,
  # not an advisory timeout. Exit 6 (skip_reason=paused) so callers that
  # treat exit 4 as advisory (agent-review.yml) cannot merge past a PR that
  # CodeRabbit is still refusing to review. A durable same-id pause NOTE
  # never advances the resume budget to the cap, so without this latch the
  # loop would fall through to exit 4. See #490.
  if [ "${PAUSE_OBSERVED:-false}" = "true" ]; then
    log "timeout reached while CodeRabbit auto-review remains paused — reporting paused (exit 6), not advisory timeout (exit 4)"
    SKIP_REASON="paused"
    emit_json_and_exit "paused" 6 "null" 0
  fi
  run_status_probe_once
  emit_terminal_review_after_probe_if_present
  emit_json_and_exit "timeout" 4 "null" 0
}

# --- poll loop --------------------------------------------------------------

START_EPOCH=$(date +%s)
RATE_LIMIT_RETRIES=0
RESUME_RETRIES=0
LAST_RATE_LIMIT_COMMENT_ID=""
LAST_PAUSED_COMMENT_ID=""
# Latched the first time a "Reviews paused" NOTE is seen. Once a pause has
# been OBSERVED, the timeout path must NOT fall back to the advisory exit 4
# (which agent-review.yml treats as advisory and merges past) — a PR must
# never merge while CodeRabbit is still paused. When CodeRabbit leaves the
# SAME durable pause NOTE (unchanged comment id), the resume retry budget
# never advances and the loop would otherwise time out exit 4; with this
# latched, emit_timeout exits 6 (skip_reason=paused) instead. See #490.
PAUSE_OBSERVED=false
# Skip reason surfaced in the JSON. Empty for the normal review/timeout/
# rate-limit paths; set to paused / non-base-branch / draft on a #490 skip.
SKIP_REASON=""
STATUS_PROBE_RAN=false
# #489 rate-limit→Codex failover state. CODEX_FAILOVER_FIRED latches after the
# first attempt so retries within a run don't re-post. CODEX_FAILOVER_REQUESTED
# records whether Codex was actually engaged (the helper posted, or found an
# existing trigger on HEAD) — surfaced in the JSON so the caller can downgrade a
# rate_limit_stalled (exit 5) from a hard human-alert to a non-blocking note.
CODEX_FAILOVER_FIRED=false
CODEX_FAILOVER_REQUESTED=false
STATUS_PROBE_JSON=$(jq -nc \
  --argjson enabled "$([ "$STATUS_PROBE_ENABLED" = "true" ] && echo true || echo false)" \
  '{enabled:$enabled, posted:false, reply_present:false, reply:null, waited_seconds:0}')

emit_json_and_exit() {
  local status=$1 exit_code=$2 review_json=$3 potential_issues=$4
  local now_epoch waited skip_reason_json
  now_epoch=$(date +%s)
  waited=$((now_epoch - START_EPOCH))

  # skip_reason is null unless a #490 skip set it.
  if [ -n "$SKIP_REASON" ]; then
    skip_reason_json=$(jq -n --arg r "$SKIP_REASON" '$r')
  else
    skip_reason_json="null"
  fi

  # blocking_tier_unresolved (#577): lazily compute the required-tier finding
  # count ONLY when the feedback_policy block is present AND this is a
  # findings-relevant terminal (`findings` / `cleared`) — the statuses where
  # inline HEAD findings are meaningful and API access is in play. Every other
  # terminal (timeout / rate_limit_stalled / paused / skip / config error)
  # leaves it null, so no extra API calls are made on those paths and the
  # historical JSON shape is unchanged except for one additive null field.
  # This never affects $exit_code — the value is report-only.
  if [ "$FEEDBACK_POLICY_PRESENT" = true ] && [ "$BLOCKING_TIER_UNRESOLVED" = "null" ]; then
    case "$status" in
      findings|cleared)
        # Guard the advisory decoration so it can NEVER flip the terminal exit
        # code or break the JSON emit (nathanpayne-codex P2 on #590). Two
        # layers: `|| true` stops a die inside count_blocking_tier_issues from
        # aborting under set -e, and the numeric-or-null validation forces a
        # value the downstream `jq --argjson` accepts. The earlier `$(...) ||
        # VAR=null` was insufficient: when an internal fetch_api_array dies,
        # count_blocking_tier_issues can exit 0 with EMPTY output, so the `||`
        # never fired and the empty value broke `jq --argjson` — a hard failure
        # on an otherwise-terminal path. Validation catches empty/non-numeric.
        BLOCKING_TIER_UNRESOLVED=$(count_blocking_tier_issues 2>/dev/null || true)
        case "$BLOCKING_TIER_UNRESOLVED" in
          ''|*[!0-9]*) BLOCKING_TIER_UNRESOLVED=null ;;
        esac
        ;;
    esac
  fi

  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg head_sha "$HEAD_SHA" \
    --arg head_committer_date "$HEAD_COMMITTER_DATE" \
    --arg bot_login "$BOT_LOGIN" \
    --arg status "$status" \
    --argjson skip_reason "$skip_reason_json" \
    --argjson review "$review_json" \
    --argjson potential_issue_count "$potential_issues" \
    --argjson blocking_tier_unresolved "$BLOCKING_TIER_UNRESOLVED" \
    --argjson rate_limit_retries "$RATE_LIMIT_RETRIES" \
    --argjson resume_retries "$RESUME_RETRIES" \
    --argjson status_probe "$STATUS_PROBE_JSON" \
    --argjson waited_seconds "$waited" \
    --argjson codex_failover_requested "$CODEX_FAILOVER_REQUESTED" \
    '{
      pr_number: $pr_number,
      repo: $repo,
      head_sha: $head_sha,
      head_committer_date: $head_committer_date,
      bot_login: $bot_login,
      status: $status,
      skip_reason: $skip_reason,
      review: $review,
      potential_issue_count: $potential_issue_count,
      blocking_tier_unresolved: $blocking_tier_unresolved,
      rate_limit_retries: $rate_limit_retries,
      resume_retries: $resume_retries,
      status_probe: $status_probe,
      waited_seconds: $waited_seconds,
      codex_failover_requested: $codex_failover_requested
    }'

  exit "$exit_code"
}

# Sleep for up to `requested` seconds, clamped to the remaining
# max_wait_seconds budget. Without this guard, fixed 15s polling
# sleeps could overshoot the configured budget (caller sees
# `waited_seconds > max_wait_seconds`). An earlier version of this
# helper exited early whenever `requested >= remaining` to avoid the
# overshoot — but that shortens the effective budget by up to one
# poll interval (iterations at elapsed 286..299 exit immediately
# for a 300s budget, missing a review that lands right before the
# deadline). The right shape: sleep min(requested, remaining), then
# let the next iteration's top-of-loop check hit the exact-elapsed
# timeout. See #140 round-3 CodeRabbit finding (Major, line 380)
# and #140 round-4 Codex finding (P2, line 391).
sleep_or_timeout() {
  local requested=$1
  local now elapsed remaining actual
  now=$(date +%s)
  elapsed=$((now - START_EPOCH))
  remaining=$((MAX_WAIT_SECONDS - elapsed))
  if [ "$remaining" -le 0 ]; then
    emit_timeout "budget exhausted (remaining=${remaining}s) — timing out"
  fi
  actual=$requested
  if [ "$actual" -gt "$remaining" ]; then
    actual=$remaining
    log "clamping sleep from ${requested}s to remaining budget ${remaining}s"
  fi
  sleep "$actual"
}

emit_status_context_verdict() {
  local state=$1
  # CodeRabbit's StatusContext SUCCESS state means "review completed"
  # — NOT "no findings remain." With CodeRabbit's default
  # `request_changes_workflow: false`, the status flips to success
  # whenever the review finishes, even if Potential issue / ⚠️
  # comments were posted. Codex (chatgpt-codex-connector[bot]) caught
  # this on PR #224 round 1 (P1 finding, line 546). The fix: scan
  # inline `Potential issue` / `⚠️` markers anchored on HEAD before
  # declaring clearance.
  #
  # Round 2 sharpening (codex CHANGES_REQUESTED + CodeRabbit ⚠️ Major
  # @ line 581 on the round 1 fix): use `count_potential_issues_for_sha
  # "$HEAD_SHA"` rather than `count_potential_issues`. The latter is
  # filtered by HEAD_ANCHOR (wallclock freshness floor); after 30 min
  # on the same unchanged HEAD, anchor advances past prior reviews and
  # the count drops to 0 — false-clearing the fast-path. The
  # SHA-scoped variant ignores the wallclock anchor entirely and counts
  # findings whose `commit_id == HEAD_SHA`, which is the right scope
  # given the fast-path already has authoritative SHA-level evidence
  # from the StatusContext check.
  local potential_issues synthetic
  potential_issues=$(count_potential_issues_for_sha "$HEAD_SHA")
  # Keep the synthetic review object compatible with the documented
  # contract at the top of this file: `{ id, created_at, endpoint,
  # body_excerpt }`. The fast-path has no underlying GitHub review,
  # so `id` is null and `created_at` is the synthesis time — but a
  # caller reading `review.id` or `review.created_at` no longer hits
  # a missing key and breaks. `endpoint` keeps the new
  # "status_context" value (a documented extension for this path); the
  # extra `head_sha` / `context_state` / `potential_issue_count`
  # fields are additive. (CodeRabbit Major, #272.)
  synthetic=$(jq -nc \
    --arg sha "$HEAD_SHA" \
    --arg state "$state" \
    --argjson p "$potential_issues" \
    '{
      id: null,
      created_at: (now | todateiso8601),
      endpoint: "status_context",
      head_sha: $sha,
      context_state: $state,
      potential_issue_count: $p,
      body_excerpt: ("CodeRabbit StatusContext = " + $state + " on " + $sha + " (potential_issue_count=" + ($p | tostring) + ")")
    }')
  if [ "$potential_issues" -gt 0 ]; then
    log "StatusContext $state but $potential_issues Potential issue/⚠️ marker(s) on HEAD — emitting findings (exit 2)"
    emit_json_and_exit "findings" 2 "$synthetic" "$potential_issues"
  fi
  log "StatusContext $state and 0 Potential issue/⚠️ markers — emitting cleared (exit 0)"
  emit_json_and_exit "cleared" 0 "$synthetic" 0
}

# --- static skip checks (#490) ----------------------------------------------
#
# Two configured conditions mean CodeRabbit auto-review will NEVER fire on
# this PR, so there is nothing to poll for. Detect them up front and exit 6
# (skipped) with the reason in JSON rather than burning the whole
# max_wait_seconds budget on a review that cannot land:
#
#   1. base branch ∉ reviews.auto_review.base_branches — a PR onto a base
#      CodeRabbit isn't configured to review (stacked / non-main bases).
#   2. draft PR when reviews.auto_review.drafts: false — drafts aren't
#      reviewed until marked ready.
#
# Both are read from .coderabbit.yml. When the relevant key is absent (a
# consumer that doesn't constrain bases, or doesn't set drafts), the reader
# yields nothing and the corresponding check is suppressed — no false skip.
# Neither is re-invocable (resume/review won't help), so the JSON surfaces
# the reason and the caller decides (retarget the base, mark ready, escalate).
#
# base_branches semantics: CodeRabbit documents each entry as a REGEX
# pattern that names ADDITIONAL non-default bases to review, and it ALWAYS
# reviews the repo default branch regardless of whether the default is
# listed. So the non-base-branch skip must (a) always allow the default
# branch, and (b) match each configured entry as a regex (anchored — the
# whole base ref must match), not as a fixed string. A repo configuring
# `base_branches: ["release/.*"]` must NOT skip a PR into `release/2026`,
# and a default-branch PR must NOT skip just because the default is not
# redundantly listed. Fail SAFE: if an entry is not a valid regex, suppress
# the skip rather than risk a false skip that blocks review/merge.
CONFIGURED_BASE_BRANCHES=$(coderabbit_yml_base_branches)
if [ -n "$CONFIGURED_BASE_BRANCHES" ] && [ -n "$PR_BASE_REF" ]; then
  base_is_allowed=no
  # The repo default branch is always reviewed by CodeRabbit, listed or not.
  if [ -n "$PR_DEFAULT_BRANCH" ] && [ "$PR_BASE_REF" = "$PR_DEFAULT_BRANCH" ]; then
    base_is_allowed=yes
  fi
  if [ "$base_is_allowed" = "no" ]; then
    while IFS= read -r base_pattern; do
      [ -n "$base_pattern" ] || continue
      # Anchor the pattern so the whole base ref must match (CodeRabbit's
      # base_branches regexes are full-match). grep exits 2 on a malformed
      # ERE (vs 0/1 for match/no-match). An entry we cannot evaluate is one
      # we cannot reason about, so fail SAFE (allow) rather than risk a
      # false skip that blocks review/merge. The `|| grep_rc=$?` captures
      # grep's status without `set -e`/`pipefail` aborting on the
      # no-match (1) or bad-regex (2) cases.
      grep_rc=0
      printf '%s\n' "$PR_BASE_REF" | grep -Eq -e "^(${base_pattern})\$" >/dev/null 2>&1 || grep_rc=$?
      case "$grep_rc" in
        0)
          base_is_allowed=yes
          break
          ;;
        1)
          : # valid pattern, this base simply did not match — keep checking
          ;;
        *)
          log "base_branches entry '$base_pattern' is not a valid regex — suppressing non-base-branch skip (fail-safe)"
          base_is_allowed=yes
          break
          ;;
      esac
    done <<EOF
$CONFIGURED_BASE_BRANCHES
EOF
  fi
  if [ "$base_is_allowed" = "no" ]; then
    SKIP_REASON="non-base-branch"
    log "PR base branch '$PR_BASE_REF' matches no configured base_branches regex and is not the default branch — CodeRabbit auto-review will not fire (skip)"
    emit_json_and_exit "skipped" 6 "null" 0
  fi
fi

CONFIGURED_DRAFTS=$(coderabbit_yml_drafts)
if [ "$CONFIGURED_DRAFTS" = "false" ] && [ "$PR_IS_DRAFT" = "true" ]; then
  SKIP_REASON="draft"
  log "PR is a draft and reviews.auto_review.drafts is false — CodeRabbit auto-review will not fire until marked ready (skip)"
  emit_json_and_exit "skipped" 6 "null" 0
fi

# Pre-loop fast-path. If CodeRabbit posted SUCCESS on this SHA before
# the script started polling, we can short-circuit immediately and
# avoid the first 15s sleep. See #221 — the historical comment-driven
# poll burned the full 300s budget on every clean fix-up push because
# CodeRabbit doesn't re-narrate when there's nothing new to flag.
if [ "$TRUST_STATUS_CONTEXT" = "true" ]; then
  INITIAL_CTX_RECORD=$(check_status_context_record)
  INITIAL_CTX=$(echo "$INITIAL_CTX_RECORD" | jq -r '.state')
  INITIAL_CTX_CREATED=$(echo "$INITIAL_CTX_RECORD" | jq -r '.created_at')
  log "initial CodeRabbit StatusContext = $INITIAL_CTX on $HEAD_SHA"
  if [ "$INITIAL_CTX" = "success" ]; then
    if ! status_context_fast_path_blocked_by_comment "$INITIAL_CTX_CREATED"; then
      log "StatusContext success — entering fast-path verdict (scans inline findings before clearance)"
      emit_status_context_verdict "$INITIAL_CTX"
    fi
  fi
fi

while :; do
  NOW_EPOCH=$(date +%s)
  ELAPSED=$((NOW_EPOCH - START_EPOCH))
  if [ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]; then
    emit_timeout "max_wait_seconds ($MAX_WAIT_SECONDS) exceeded after ${ELAPSED}s — timing out"
  fi

  # In-loop fast-path — same intent as the pre-loop check, for the case
  # where CodeRabbit posts SUCCESS while we're already polling. Cheaper
  # API call than `scan_latest_comment` so it's worth doing first each
  # iteration; falls through to the comment scan if not success/failure.
  if [ "$TRUST_STATUS_CONTEXT" = "true" ]; then
    LOOP_CTX_RECORD=$(check_status_context_record)
    LOOP_CTX=$(echo "$LOOP_CTX_RECORD" | jq -r '.state')
    LOOP_CTX_CREATED=$(echo "$LOOP_CTX_RECORD" | jq -r '.created_at')
    if [ "$LOOP_CTX" = "success" ]; then
      if ! status_context_fast_path_blocked_by_comment "$LOOP_CTX_CREATED"; then
        log "CodeRabbit StatusContext flipped to success mid-loop on $HEAD_SHA — entering fast-path verdict"
        emit_status_context_verdict "$LOOP_CTX"
      fi
    fi
  fi

  LATEST=$(scan_latest_comment)

  if [ "$(echo "$LATEST" | jq 'length')" = "0" ]; then
    log "no CodeRabbit comment yet (elapsed ${ELAPSED}s); sleeping ${POLL_INTERVAL_SECONDS}s"
    sleep_or_timeout "$POLL_INTERVAL_SECONDS"
    continue
  fi

  COMMENT_ID=$(echo "$LATEST" | jq -r '.id')
  COMMENT_BODY=$(echo "$LATEST" | jq -r '.body')
  COMMENT_ENDPOINT=$(echo "$LATEST" | jq -r '.endpoint')
  COMMENT_CREATED=$(echo "$LATEST" | jq -r '.created_at')
  COMMENT_FRESH_AT=$(echo "$LATEST" | jq -r '.fresh_at // .updated_at // .created_at')

  CLASS=$(classify_comment "$COMMENT_BODY")
  log "latest CodeRabbit comment id=$COMMENT_ID endpoint=$COMMENT_ENDPOINT class=$CLASS created=$COMMENT_CREATED fresh_at=$COMMENT_FRESH_AT"

  case "$CLASS" in
    rate_limit)
      if [ "$COMMENT_ID" = "$LAST_RATE_LIMIT_COMMENT_ID" ]; then
        # Same rate-limit comment as last iteration — still sleeping/waiting
        # through our own retry window. Don't double-count retries.
        log "still inside prior rate-limit window; sleeping ${POLL_INTERVAL_SECONDS}s"
        sleep_or_timeout "$POLL_INTERVAL_SECONDS"
        continue
      fi
      LAST_RATE_LIMIT_COMMENT_ID=$COMMENT_ID

      # #489: fire the Codex failover once, on the first rate-limit notice, so
      # Codex (the real blocking gate) reviews in parallel instead of the PR
      # idling on CodeRabbit's hourly allowance. Fired BEFORE the stall checks
      # below so a budget/retry stall still leaves Codex engaged. Idempotent +
      # HEAD-pinned: --trigger-only posts at most one @codex trigger per HEAD
      # (its own scan dedupes across runs); the FIRED latch prevents re-posting
      # across this run's retries. MERGEPATH_PHASE_4A_GATED=true forces the
      # request even when codex.request_by_default is false; if Codex is
      # disabled/opted out the helper no-ops and the failover stays unrecorded.
      if [ "$CODEX_FAILOVER_ON_RATE_LIMIT" != "false" ] && [ "$CODEX_FAILOVER_FIRED" != "true" ]; then
        CODEX_FAILOVER_FIRED=true
        log "codex failover: CodeRabbit rate-limited — requesting @codex review (trigger-only)"
        if MERGEPATH_PHASE_4A_GATED=true "$CODEX_REQUEST_CMD" --trigger-only "$PR_NUMBER" "$REPO" >&2; then
          CODEX_FAILOVER_REQUESTED=true
          log "codex failover: @codex review requested (or already present) on HEAD"
        else
          log "codex failover: codex-review-request did not post (Codex disabled/opted out or read error) — continuing CodeRabbit retry"
        fi
      fi

      if [ "$RATE_LIMIT_RETRIES" -ge "$MAX_RATE_LIMIT_RETRIES" ]; then
        log "max_rate_limit_retries ($MAX_RATE_LIMIT_RETRIES) exceeded — stalling"
        RATE_LIMIT_REVIEW=$(echo "$LATEST" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
        emit_json_and_exit "rate_limit_stalled" 5 "$RATE_LIMIT_REVIEW" 0
      fi

      WINDOW_SECONDS=$(parse_rate_limit_window "$COMMENT_BODY" || echo "")
      if [ -z "$WINDOW_SECONDS" ]; then
        log "could not parse rate-limit window from comment; falling back to 60s"
        WINDOW_SECONDS=60
      fi
      SLEEP_FOR=$((WINDOW_SECONDS + RATE_LIMIT_BUFFER_SECONDS))
      # Clamp against remaining budget — if the published rate-limit
      # window exceeds max_wait_seconds anyway, there's no point
      # burning through the entire sleep. Surface it as the same hard
      # rate-limit stalled state callers already treat as non-advisory
      # instead of a generic timeout that auto-merge may skip past.
      # See #140 round-2 Codex finding (P2, line 392), then #386.
      NOW_EPOCH=$(date +%s)
      ELAPSED=$((NOW_EPOCH - START_EPOCH))
      REMAINING=$((MAX_WAIT_SECONDS - ELAPSED))
      if [ "$SLEEP_FOR" -ge "$REMAINING" ]; then
        log "rate-limit window (${SLEEP_FOR}s) exceeds remaining budget (${REMAINING}s) — stalling"
        RATE_LIMIT_REVIEW=$(echo "$LATEST" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
        emit_json_and_exit "rate_limit_stalled" 5 "$RATE_LIMIT_REVIEW" 0
      fi
      log "rate-limited; sleeping ${SLEEP_FOR}s (window=${WINDOW_SECONDS}s + ${RATE_LIMIT_BUFFER_SECONDS}s buffer)"
      sleep "$SLEEP_FOR"
      post_retry_trigger
      RATE_LIMIT_RETRIES=$((RATE_LIMIT_RETRIES + 1))
      continue
      ;;
    paused)
      # Auto-pause (#490 / #485). Re-invoke with `@coderabbitai resume`
      # (NOT a one-shot `review` — that re-pauses after the next push),
      # bounded by max_resume_retries, then resume polling. Distinct from
      # rate_limit (no published wait window; the resume verb differs) and
      # from in_progress (durable, never self-clears).
      #
      # Latch PAUSE_OBSERVED on EVERY pause sighting — including the
      # same-id branch below. If CodeRabbit leaves the SAME durable pause
      # NOTE (unchanged id) the resume budget never advances to the cap, so
      # the loop would otherwise time out exit 4 (advisory) and let
      # agent-review.yml merge past a still-paused PR. With the latch set,
      # emit_timeout converts that timeout into exit 6 / skip_reason=paused.
      PAUSE_OBSERVED=true
      if [ "$COMMENT_ID" = "$LAST_PAUSED_COMMENT_ID" ]; then
        # Same pause NOTE as last iteration — our resume hasn't taken
        # effect yet. Keep polling without re-posting / double-counting.
        log "still inside prior auto-pause (same NOTE id=$COMMENT_ID); sleeping ${POLL_INTERVAL_SECONDS}s"
        sleep_or_timeout "$POLL_INTERVAL_SECONDS"
        continue
      fi
      LAST_PAUSED_COMMENT_ID=$COMMENT_ID

      if [ "$RESUME_RETRIES" -ge "$MAX_RESUME_RETRIES" ]; then
        log "max_resume_retries ($MAX_RESUME_RETRIES) exceeded — CodeRabbit auto-review remains paused (skip)"
        SKIP_REASON="paused"
        PAUSED_REVIEW=$(echo "$LATEST" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
        emit_json_and_exit "paused" 6 "$PAUSED_REVIEW" 0
      fi
      log "CodeRabbit auto-review paused; posting @coderabbitai resume (retry $((RESUME_RETRIES + 1))/$MAX_RESUME_RETRIES) and continuing to poll"
      post_resume_trigger
      RESUME_RETRIES=$((RESUME_RETRIES + 1))
      sleep_or_timeout "$POLL_INTERVAL_SECONDS"
      continue
      ;;
    in_progress)
      log "CodeRabbit review in progress; sleeping ${POLL_INTERVAL_SECONDS}s"
      sleep_or_timeout "$POLL_INTERVAL_SECONDS"
      continue
      ;;
    status_probe)
      log "CodeRabbit status-probe reply is narration, not clearance; sleeping ${POLL_INTERVAL_SECONDS}s"
      sleep_or_timeout "$POLL_INTERVAL_SECONDS"
      continue
      ;;
    review)
      POTENTIAL_ISSUES=$(count_potential_issues)
      REVIEW_JSON=$(echo "$LATEST" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
      # #535: the inline count scans only pulls/{pr}/comments. Also honor a
      # PR-level summary-body marker so a finding surfaced solely in the
      # summary body still yields findings instead of false-clearing.
      if [ "$POTENTIAL_ISSUES" -gt 0 ]; then
        log "CodeRabbit review posted with $POTENTIAL_ISSUES Potential issue/⚠️ markers"
        emit_json_and_exit "findings" 2 "$REVIEW_JSON" "$POTENTIAL_ISSUES"
      elif summary_body_has_potential_issue_marker; then
        log "CodeRabbit review posted with 0 inline markers but a Potential issue/⚠️ marker in the PR-level summary body — findings"
        emit_json_and_exit "findings" 2 "$REVIEW_JSON" "$POTENTIAL_ISSUES"
      else
        log "CodeRabbit review posted with no high-severity markers — cleared"
        emit_json_and_exit "cleared" 0 "$REVIEW_JSON" 0
      fi
      ;;
  esac
done
