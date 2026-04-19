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
#   GH_TOKEN   Required. GitHub token with pull_requests:write to post the
#              retry trigger and read comments. In the template flow this
#              is set to $OP_PREFLIGHT_AUTHOR_PAT after running preflight,
#              or via inline `op read` per REVIEW_POLICY.md § PAT lookup.
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
#   6. If total elapsed > max_wait_seconds: exit 4 (TIMEOUT), emit JSON
#      with status=timeout.
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
#   - Read-only except for retry-trigger comments. Does not push commits,
#     does not modify labels, does not merge.
#   - Idempotent across reruns on the same HEAD. A freshly-landed review
#     is detected on the next poll regardless of how many times the script
#     has been run.
#   - JSON emission uses `jq`. Pattern matching on CodeRabbit comment
#     bodies is intentionally heuristic — the bot's output format is not
#     versioned and may drift. See nathanjohnpayne/mergepath#138 for the
#     observed rate-limit string.

set -euo pipefail

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
  echo "ERROR: GH_TOKEN is required. See REVIEW_POLICY.md § PAT lookup table." >&2
  exit 3
fi

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

BOT_LOGIN="coderabbitai[bot]"
POLL_INTERVAL_SECONDS=15
RATE_LIMIT_BUFFER_SECONDS=30

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

# --- fetch PR metadata ------------------------------------------------------

log "PR $REPO#$PR_NUMBER — fetching HEAD commit metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) || die 3 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 3 "could not determine HEAD sha for PR #$PR_NUMBER"
fi

HEAD_COMMITTER_DATE=$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>&1) \
  || die 3 "failed to fetch commit date for $HEAD_SHA: $HEAD_COMMITTER_DATE"

log "HEAD = $HEAD_SHA committed at $HEAD_COMMITTER_DATE"
log "max_wait = ${MAX_WAIT_SECONDS}s   max_rate_limit_retries = $MAX_RATE_LIMIT_RETRIES"

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
#   rate_limit | in_progress | review
classify_comment() {
  local body=$1
  if echo "$body" | grep -qiE 'rate[- ]limit exceeded'; then
    echo "rate_limit"
    return
  fi
  if echo "$body" | grep -qiE 'review in progress|currently reviewing|commits? under review'; then
    echo "in_progress"
    return
  fi
  echo "review"
}

# Scan both comment endpoints for the latest CodeRabbit comment on or
# after HEAD_COMMITTER_DATE. Emits JSON to stdout. Sets LATEST_* globals.
# Empty JSON object {} if no qualifying comment found.
scan_latest_comment() {
  local issue_comments pulls_comments combined latest
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments")
  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments")

  combined=$(jq -s --arg bot "$BOT_LOGIN" --arg after "$HEAD_COMMITTER_DATE" '
    ( (.[0] // []) | map(. + {endpoint: "issues"}) ) +
    ( (.[1] // []) | map(. + {endpoint: "pulls"}) )
    | map(select(.user.login == $bot))
    | map(select(.created_at >= $after))
    | sort_by(.created_at)
  ' <(echo "$issue_comments") <(echo "$pulls_comments"))

  latest=$(echo "$combined" | jq 'last // null')
  if [ "$latest" = "null" ]; then
    echo '{}'
    return
  fi
  echo "$latest" | jq '{id, created_at, endpoint, body}'
}

# Count "Potential issue" / ⚠️ markers in the pulls inline comment list
# on or after HEAD_COMMITTER_DATE. Used for exit code 2 when a real
# review surfaces high-severity findings.
count_potential_issues() {
  local pulls_comments
  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments")
  echo "$pulls_comments" | jq --arg bot "$BOT_LOGIN" --arg after "$HEAD_COMMITTER_DATE" '
    [ .[]
      | select(.user.login == $bot)
      | select(.created_at >= $after)
      | select((.body // "") | test("Potential issue|⚠️"; "i"))
    ] | length
  '
}

post_retry_trigger() {
  local body='@coderabbitai, try again.'
  log "posting retry trigger comment to PR #$PR_NUMBER"
  gh api --method POST "repos/$REPO/issues/$PR_NUMBER/comments" \
    -f body="$body" >/dev/null 2>&1 \
    || die 3 "failed to post retry trigger comment"
}

# --- poll loop --------------------------------------------------------------

START_EPOCH=$(date +%s)
RATE_LIMIT_RETRIES=0
LAST_RATE_LIMIT_COMMENT_ID=""

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
      waited_seconds: $waited_seconds
    }'

  exit "$exit_code"
}

while :; do
  NOW_EPOCH=$(date +%s)
  ELAPSED=$((NOW_EPOCH - START_EPOCH))
  if [ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]; then
    log "max_wait_seconds ($MAX_WAIT_SECONDS) exceeded after ${ELAPSED}s — timing out"
    emit_json_and_exit "timeout" 4 "null" 0
  fi

  LATEST=$(scan_latest_comment)

  if [ "$(echo "$LATEST" | jq 'length')" = "0" ]; then
    log "no CodeRabbit comment yet (elapsed ${ELAPSED}s); sleeping ${POLL_INTERVAL_SECONDS}s"
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi

  COMMENT_ID=$(echo "$LATEST" | jq -r '.id')
  COMMENT_BODY=$(echo "$LATEST" | jq -r '.body')
  COMMENT_ENDPOINT=$(echo "$LATEST" | jq -r '.endpoint')
  COMMENT_CREATED=$(echo "$LATEST" | jq -r '.created_at')

  CLASS=$(classify_comment "$COMMENT_BODY")
  log "latest CodeRabbit comment id=$COMMENT_ID endpoint=$COMMENT_ENDPOINT class=$CLASS created=$COMMENT_CREATED"

  case "$CLASS" in
    rate_limit)
      if [ "$COMMENT_ID" = "$LAST_RATE_LIMIT_COMMENT_ID" ]; then
        # Same rate-limit comment as last iteration — still sleeping/waiting
        # through our own retry window. Don't double-count retries.
        log "still inside prior rate-limit window; sleeping ${POLL_INTERVAL_SECONDS}s"
        sleep "$POLL_INTERVAL_SECONDS"
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
      log "rate-limited; sleeping ${SLEEP_FOR}s (window=${WINDOW_SECONDS}s + ${RATE_LIMIT_BUFFER_SECONDS}s buffer)"
      sleep "$SLEEP_FOR"
      post_retry_trigger
      RATE_LIMIT_RETRIES=$((RATE_LIMIT_RETRIES + 1))
      continue
      ;;
    in_progress)
      log "CodeRabbit review in progress; sleeping ${POLL_INTERVAL_SECONDS}s"
      sleep "$POLL_INTERVAL_SECONDS"
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
