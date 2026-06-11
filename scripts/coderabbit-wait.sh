#!/usr/bin/env bash
# scripts/coderabbit-wait.sh — Phase 2.5 CodeRabbit wait + rate-limit retry
#
# Polls a pull request for a CodeRabbit review anchored on the current HEAD
# commit. Handles two CodeRabbit behaviors that the naive "just wait"
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
#   2. **HEAD freshness.** Auto-merge-on-approval workflows in downstream
#      repos race CodeRabbit: an internal reviewer can post APPROVED before
#      CodeRabbit's ~2–3 minute review lands, and the PR auto-merges
#      pre-review. The script only returns "cleared" when CodeRabbit has
#      posted a non-rate-limited, non-in-progress comment on or after the
#      HEAD committer date. See nathanjohnpayne/mergepath#136.
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
#   3. Polls issue + review comments every 15s. For each CodeRabbit
#      comment newer than HEAD committer date, classifies as:
#        - rate_limit  — body matches /Rate limit exceeded/i
#        - in_progress — body matches /review in progress|currently reviewing/i
#        - review      — anything else authored by coderabbitai[bot]
#   4. On rate_limit: parse "X minutes and Y seconds" (or "X seconds"),
#      sleep that duration + 30s buffer, post `@coderabbitai, try again.`,
#      increment retry counter, continue polling.
#   5. On review (non-rate-limit, non-in-progress): emit JSON, exit 0.
#      Also scans inline diff comments for "Potential issue" / "⚠️"
#      markers and surfaces them in the JSON so callers can decide.
#   6. If total elapsed > max_wait_seconds: optionally post
#      `@coderabbitai, how is the review going?`, wait a short bounded
#      status-probe window for CodeRabbit's reply, then exit 4
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
#     "status": "cleared" | "findings" | "timeout" | "rate_limit_stalled",
#     "review": null | {
#       "id": N,
#       "created_at": "<iso-8601>",
#       "endpoint": "issues" | "pulls",
#       "body_excerpt": "<first 200 chars>"
#     },
#     "potential_issue_count": N,
#     "rate_limit_retries": N,
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
#
# Design notes:
#   - Read-only except for retry-trigger comments and timeout status-probe
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
  echo "  - Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode review)\"" >&2
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
  gh "$@"
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

# Read the available_reviewers list (one login per line). Same
# state-machine awk pattern as codex-review-check.sh's reader; handles
# quoted and unquoted list items. Used by the token-derived expected-
# identity path (#438) to keep the derivation fail-closed: only a
# login on this allow-list may become the expected reviewer.
read_available_reviewers() {
  [ -f "$CONFIG" ] || return 0
  awk '
    /^available_reviewers:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && /^ *-/ {print}
  ' "$CONFIG" | sed -E "s/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+#.*\$//; s/^[\"']//; s/[\"']\$//; s/[[:space:]]+\$//"
}

login_is_available_reviewer() {
  local login=$1 reviewer
  [ -n "$login" ] || return 1
  while IFS= read -r reviewer; do
    [ "$reviewer" = "$login" ] && return 0
  done <<< "$(read_available_reviewers)"
  return 1
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
  return 1
}

# Classify a CodeRabbit comment body. Emits one of:
#   rate_limit | in_progress | status_probe | review
classify_comment() {
  local body=$1
  if echo "$body" | grep -qiE 'rate[- ]limit exceeded'; then
    echo "rate_limit"
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
  latest_review_id=$(echo "$reviews" | jq --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" '
    [ .[]
      | select(.user.login == $bot)
      | select(.submitted_at >= $after)
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

status_context_fast_path_blocked_by_comment() {
  local status_created_at=$1
  local latest class comment_id comment_fresh_at comment_body
  latest=$(scan_latest_comment)
  if [ "$(echo "$latest" | jq 'length')" = "0" ]; then
    return 1
  fi

  class=$(classify_comment "$(echo "$latest" | jq -r '.body')")
  case "$class" in
    rate_limit|in_progress)
      comment_id=$(echo "$latest" | jq -r '.id')
      comment_fresh_at=$(echo "$latest" | jq -r '.fresh_at // .updated_at // .created_at')
      comment_body=$(echo "$latest" | jq -r '.body')
      if printf '%s' "$comment_body" | grep -Fq "$HEAD_SHA"; then
        if iso_on_or_after "$comment_fresh_at" "$status_created_at"; then
          log "StatusContext success ignored because latest CodeRabbit comment id=$comment_id class=$class explicitly references current HEAD $HEAD_SHA and fresh_at=$comment_fresh_at is not older than status_created=$status_created_at"
          return 0
        fi
        log "StatusContext success remains authoritative because latest CodeRabbit comment id=$comment_id class=$class explicitly references current HEAD $HEAD_SHA but fresh_at=$comment_fresh_at is older than status_created=$status_created_at"
        return 1
      fi
      log "StatusContext success remains authoritative because latest CodeRabbit comment id=$comment_id class=$class does not reference current HEAD $HEAD_SHA"
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
      if [ "$potential_issues" -gt 0 ]; then
        log "CodeRabbit review landed during status-probe wait with $potential_issues Potential issue/⚠️ marker(s) — emitting findings (exit 2)"
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
  run_status_probe_once
  emit_terminal_review_after_probe_if_present
  emit_json_and_exit "timeout" 4 "null" 0
}

# --- poll loop --------------------------------------------------------------

START_EPOCH=$(date +%s)
RATE_LIMIT_RETRIES=0
LAST_RATE_LIMIT_COMMENT_ID=""
STATUS_PROBE_RAN=false
STATUS_PROBE_JSON=$(jq -nc \
  --argjson enabled "$([ "$STATUS_PROBE_ENABLED" = "true" ] && echo true || echo false)" \
  '{enabled:$enabled, posted:false, reply_present:false, reply:null, waited_seconds:0}')

emit_json_and_exit() {
  local status=$1 exit_code=$2 review_json=$3 potential_issues=$4
  local now_epoch waited
  now_epoch=$(date +%s)
  waited=$((now_epoch - START_EPOCH))

  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg head_sha "$HEAD_SHA" \
    --arg head_committer_date "$HEAD_COMMITTER_DATE" \
    --arg bot_login "$BOT_LOGIN" \
    --arg status "$status" \
    --argjson review "$review_json" \
    --argjson potential_issue_count "$potential_issues" \
    --argjson rate_limit_retries "$RATE_LIMIT_RETRIES" \
    --argjson status_probe "$STATUS_PROBE_JSON" \
    --argjson waited_seconds "$waited" \
    '{
      pr_number: $pr_number,
      repo: $repo,
      head_sha: $head_sha,
      head_committer_date: $head_committer_date,
      bot_login: $bot_login,
      status: $status,
      review: $review,
      potential_issue_count: $potential_issue_count,
      rate_limit_retries: $rate_limit_retries,
      status_probe: $status_probe,
      waited_seconds: $waited_seconds
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
      if [ "$POTENTIAL_ISSUES" -gt 0 ]; then
        log "CodeRabbit review posted with $POTENTIAL_ISSUES Potential issue/⚠️ markers"
        emit_json_and_exit "findings" 2 "$REVIEW_JSON" "$POTENTIAL_ISSUES"
      else
        log "CodeRabbit review posted with no high-severity markers — cleared"
        emit_json_and_exit "cleared" 0 "$REVIEW_JSON" 0
      fi
      ;;
  esac
done
