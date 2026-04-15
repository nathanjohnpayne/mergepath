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

REACTION_FRESHNESS_SECONDS=$(codex_field reaction_freshness_window_seconds)
REACTION_FRESHNESS_SECONDS=${REACTION_FRESHNESS_SECONDS:-1800}
if ! [[ "$REACTION_FRESHNESS_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.reaction_freshness_window_seconds must be an integer; got '$REACTION_FRESHNESS_SECONDS'" >&2
  exit 3
fi

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
  # P0-P3 priority extracted from the ![P{0-3} Badge] markdown
  # shortcode. If there's no current review, findings is empty.
  if [ -n "$latest_review_id" ] && [ "$latest_review_id" != "null" ]; then
    findings=$(echo "$comments" | jq \
      --arg bot "$BOT_LOGIN" \
      --argjson review_id "$latest_review_id" '
      [ .[]
        | select(.user.login == $bot)
        | select(.pull_request_review_id == $review_id)
        | { path, line, comment_id: .id, body,
            priority: (
              (.body | capture("!\\[P(?<n>[0-3]) Badge\\]")? // {n: null}) | .n
              | if . == null then "P?" else "P" + . end
            )
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

  jq -n --argjson review "$review" --argjson findings "$findings" --argjson reaction "$reaction" '
    { review: $review, findings: $findings, reaction: $reaction }
  '
}

# Returns 0 iff the scan produced ANY signal (review or reaction).
# Used by the poll loop, which stops as soon as Codex has produced
# any response — even a review with P0/P1 findings counts because
# the caller will then process the findings and decide what to do.
has_signal() {
  local scan=$1
  [ "$(echo "$scan" | jq -r '.review != null or .reaction != null')" = "true" ]
}

# Returns 0 iff the scan produced a signal that should be treated as
# CLEARED (no further @codex review trigger needed). Cleared means
# EITHER:
#   - any +1 reaction on the PR issue (the no-findings happy path), OR
#   - a review on HEAD with zero P0/P1 inline findings (the
#     reviewed-and-clean path)
#
# A review with P0/P1 findings does NOT count as cleared — the caller
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
  # Latest-signal-wins: when both a reaction and a review exist on
  # HEAD, the more recent one is authoritative. Otherwise an older
  # 👍 from a prior round can mask a later P1-bearing review and
  # skip a needed retrigger. nathanpayne-codex caught this on
  # nathanpaynedotcom propagation PR #180 round 2 — same shape as
  # PR #65 round 1's gate (c) latest-state rule on
  # codex-review-check.sh.
  #
  # Cleared iff EITHER:
  #   - reaction exists AND (review is null OR reaction is newer
  #     than review), OR
  #   - review exists AND review is newer than (or only signal vs)
  #     reaction AND review has zero P0/P1 findings (the findings
  #     array is already scoped to the latest review's id by the
  #     pull_request_review_id filter in scan_codex_state)
  [ "$(echo "$scan" | jq -r '
    def review_time: if .review == null then "" else .review.submitted_at end;
    def reaction_time: if .reaction == null then "" else .reaction.created_at end;
    def review_clean: ([.findings[] | select(.priority == "P0" or .priority == "P1")] | length) == 0;

    if .reaction == null and .review == null then "false"
    elif .reaction != null and .review == null then "true"
    elif .reaction == null and .review != null then
      (review_clean | tostring)
    elif (reaction_time > review_time) then "true"
    else
      (review_clean | tostring)
    end
  ')" = "true" ]
}

# --- pre-flight: is Codex already working on HEAD? --------------------------

log "checking for existing Codex signal on HEAD"
if ! INITIAL_SCAN=$(scan_codex_state); then
  die 3 "initial Codex scan failed"
fi

TRIGGER_POSTED=false
TRIGGER_POST_TIME=""

if has_cleared_signal "$INITIAL_SCAN"; then
  log "Codex has already cleared on HEAD (reaction or no-P0/P1 review) — skipping trigger comment"
else
  log "posting '@codex review' trigger comment"
  # Capture stderr (and stdout) into a diagnostic variable so a failure
  # here surfaces the actual gh error — e.g. "404" from a nonexistent
  # PR, "403" from a token without comment scope, or "422" from a closed
  # PR — rather than a bare "failed to post". CodeRabbit non-blocking
  # note on PR #64.
  POST_OUTPUT=$(gh pr comment "$PR_NUMBER" --repo "$REPO" --body "@codex review" 2>&1) \
    || die 3 "failed to post '@codex review' comment: $POST_OUTPUT"
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
  TRIGGER_COMMENT_ID=$(echo "$POST_OUTPUT" | grep -oE 'issuecomment-[0-9]+' | head -1 | sed 's/issuecomment-//')
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
fi

# --- poll loop --------------------------------------------------------------

START_TS=$(date +%s)
DEADLINE=$((START_TS + TIMEOUT_SECONDS))
ELAPSED=0

# Returns 0 iff the scan has a signal that is at least as recent
# as TRIGGER_POST_TIME (>=, not >). Used by the poll loop only
# when TRIGGER_POSTED=1 so we don't short-circuit on stale signals.
#
# Uses >= rather than > because GitHub timestamps are second-
# precision and a legitimate Codex response in the same second as
# the trigger comment post would otherwise be classified as stale
# forever, forcing the script to time out to Phase 4b unnecessarily.
# nathanpayne-codex caught the >-vs->= bug on swipewatch propagation
# PR #33 round 4 and the related wall-clock-vs-GitHub-time bug on
# nathanpaynedotcom propagation PR #180 round 4.
has_post_trigger_signal() {
  local scan=$1
  [ "$(echo "$scan" | jq -r --arg after "$TRIGGER_POST_TIME" '
    ((.review != null and .review.submitted_at >= $after)
     or (.reaction != null and .reaction.created_at >= $after))
  ')" = "true" ]
}

if [ "$TRIGGER_POSTED" = "true" ]; then
  # We just posted a trigger. The INITIAL_SCAN data is now stale by
  # definition — Codex will respond with something new. Skip the
  # initial has_signal check; force the loop to actually poll.
  FINAL_SCAN='{"review":null,"findings":[],"reaction":null}'
else
  FINAL_SCAN=$INITIAL_SCAN
fi

while :; do
  # If we just triggered a fresh review, only break on a signal
  # strictly newer than the trigger. Otherwise (no trigger sent),
  # any existing signal is fine — that's the cleared-on-arrival path.
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

# Exit 0 if a signal arrived; exit 4 (FALLBACK_REQUIRED) if we timed
# out. When TRIGGER_POSTED=true, "a signal arrived" means a signal
# strictly newer than the trigger post — the existing pre-trigger
# signal doesn't count, otherwise the script would exit 0 with stale
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
