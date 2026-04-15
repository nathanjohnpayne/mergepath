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
#   GH_TOKEN   Required. GitHub token with pull_requests:write to post the
#              trigger comment and read reviews/comments/reactions. In the
#              standard template flow this is set to $OP_PREFLIGHT_AUTHOR_PAT
#              after running `scripts/op-preflight.sh`, or via inline
#              `op read` per REVIEW_POLICY.md § PAT lookup table.
#
# Behavior:
#   1. Reads codex.review_timeout_seconds and codex.bot_login from
#      .github/review-policy.yml (defaults: 600 / chatgpt-codex-connector[bot]).
#   2. Fetches the PR's current HEAD commit SHA and committer date. Any
#      Codex review/reaction is only considered "current" if it is
#      anchored on this commit (reviews) or created after its committer
#      date (reactions).
#   3. Scans existing reviews, inline comments, and issue reactions for
#      a Codex signal already present on the current HEAD. If found,
#      skips the trigger comment and goes straight to emitting JSON —
#      re-posting `@codex review` when Codex has already responded can
#      cause double-processing or rate-limit pushback.
#   4. Otherwise posts `@codex review` as a PR comment and polls every
#      15 seconds for up to `review_timeout_seconds` for either:
#        - a review from the Codex bot on the current HEAD, OR
#        - a +1 reaction from the Codex bot on the PR issue dated after
#          the current HEAD committer date.
#   5. Emits a JSON object to stdout summarizing what Codex produced.
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
#         "comment_id": N, "body": "<full finding body>" }
#     ],
#     "reaction": null | {
#       "content": "+1",
#       "created_at": "<iso-8601>",
#       "reaction_id": N
#     },
#     "trigger_posted": true | false,
#     "rounds_waited_seconds": N
#   }
#
# Exit codes:
#   0   Codex signal received on current HEAD. JSON on stdout.
#   3   API / infrastructure error. Error message on stderr.
#   4   FALLBACK_REQUIRED — timed out waiting for a Codex signal. The
#       caller should route to REVIEW_POLICY.md § Phase 4b. See #27 for
#       the explicit-review-required decision that mandates this path.
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
#   - REVIEW_POLICY.md § Phase 4a (canonical policy)

set -euo pipefail

# --- argument parsing -------------------------------------------------------

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <PR_NUMBER> [REPO]" >&2
  echo "  PR_NUMBER  pull request number (integer)" >&2
  echo "  REPO       owner/repo (optional; defaults to current repo)" >&2
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
      # Match "  field: value" or "  field: \"value\""
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

TIMEOUT_SECONDS=$(codex_field review_timeout_seconds)
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-600}
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.review_timeout_seconds must be an integer; got '$TIMEOUT_SECONDS'" >&2
  exit 3
fi

BOT_LOGIN=$(codex_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"chatgpt-codex-connector[bot]"}

POLL_INTERVAL_SECONDS=15

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

log "HEAD = $HEAD_SHA committed at $HEAD_COMMITTER_DATE"
log "bot_login = $BOT_LOGIN    timeout = ${TIMEOUT_SECONDS}s"

# --- Codex signal scan ------------------------------------------------------

# Scan for (a) a review from the bot on the current HEAD commit, (b) inline
# findings from the bot on the current HEAD, (c) a +1 reaction on the issue
# dated after the HEAD committer date. Returns a JSON object to stdout on
# success. Emits empty object { "review": null, "findings": [], "reaction": null }
# if nothing matches yet.
scan_codex_state() {
  local reviews comments reactions review findings reaction

  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")
  comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline comments")
  reactions=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/reactions" "reactions")

  # Latest review from the Codex bot on the current HEAD commit, if any.
  # Codex always uses COMMENTED state regardless of findings.
  review=$(echo "$reviews" | jq --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    [.[] | select(.user.login == $bot) | select(.commit_id == $sha)]
    | sort_by(.submitted_at) | last
    | if . == null then null
      else { state, submitted_at, commit_id, body }
      end
  ')

  # Inline findings from the bot on the current HEAD commit, with P0-P3
  # priority extracted from the ![P{0-3} Badge] markdown shortcode.
  findings=$(echo "$comments" | jq --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    [ .[]
      | select(.user.login == $bot)
      | select((.original_commit_id == $sha) or (.commit_id == $sha))
      | { path, line, comment_id: .id, body,
          priority: (
            (.body | capture("!\\[P(?<n>[0-3]) Badge\\]")? // {n: null}) | .n
            | if . == null then "P?" else "P" + . end
          )
        }
    ]
  ')

  # Most recent +1 reaction from the bot on the issue with created_at
  # strictly >= the HEAD committer date.
  reaction=$(echo "$reactions" | jq --arg bot "$BOT_LOGIN" --arg after "$HEAD_COMMITTER_DATE" '
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

  jq -n --argjson review "$review" --argjson findings "$findings" --argjson reaction "$reaction" '
    { review: $review, findings: $findings, reaction: $reaction }
  '
}

# Returns 0 iff the scan produced a review or reaction (signal received).
has_signal() {
  local scan=$1
  [ "$(echo "$scan" | jq -r '.review != null or .reaction != null')" = "true" ]
}

# --- pre-flight: is Codex already working on HEAD? --------------------------

log "checking for existing Codex signal on HEAD"
if ! INITIAL_SCAN=$(scan_codex_state); then
  die 3 "initial Codex scan failed"
fi

TRIGGER_POSTED=false

if has_signal "$INITIAL_SCAN"; then
  log "Codex has already responded on HEAD — skipping trigger comment"
else
  log "posting '@codex review' trigger comment"
  if ! gh pr comment "$PR_NUMBER" --repo "$REPO" --body "@codex review" >/dev/null 2>&1; then
    die 3 "failed to post '@codex review' comment"
  fi
  TRIGGER_POSTED=true
fi

# --- poll loop --------------------------------------------------------------

START_TS=$(date +%s)
DEADLINE=$((START_TS + TIMEOUT_SECONDS))
ELAPSED=0

FINAL_SCAN=$INITIAL_SCAN

while :; do
  if has_signal "$FINAL_SCAN"; then
    log "Codex signal received after ${ELAPSED}s"
    break
  fi

  NOW=$(date +%s)
  if [ "$NOW" -ge "$DEADLINE" ]; then
    log "TIMEOUT after ${ELAPSED}s — no Codex review or reaction on HEAD"
    log "emitting JSON with review=null, reaction=null; exit code 4 (FALLBACK_REQUIRED)"
    # Fall through to JSON emission so the caller still gets a structured
    # answer (all nulls), then exit 4.
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
    trigger_posted: $trigger_posted,
    rounds_waited_seconds: $elapsed
  }
'

# Exit 0 if a signal arrived; exit 4 (FALLBACK_REQUIRED) if we timed out.
if has_signal "$FINAL_SCAN"; then
  exit 0
else
  exit 4
fi
