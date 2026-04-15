#!/usr/bin/env bash
# scripts/codex-review-check.sh — Phase 4a merge gate
#
# Verifies that a pull request is ready to merge under the Phase 4a
# automated external review flow. Read-only. Never merges, labels, or
# comments on the PR.
#
# Usage:
#   scripts/codex-review-check.sh <PR_NUMBER> [REPO]
#
# Arguments:
#   PR_NUMBER  Required. The pull request number (integer).
#   REPO       Optional. "owner/repo". Defaults to the current repo.
#
# Environment:
#   GH_TOKEN   Required. Needs pull_requests:read + checks:read.
#
# Merge gate (all three must pass):
#
#   (a) Required CI checks are green.
#       `gh pr checks` reports no failing or pending required checks.
#
#   (b) At least one APPROVED review from a reviewer identity in
#       codex.available_reviewers (e.g., nathanpayne-claude,
#       nathanpayne-cursor, nathanpayne-codex) is present on the PR,
#       from an account != the PR author.
#
#   (c) Codex has cleared on or after the current HEAD commit via one
#       of two signals:
#
#         - A COMMENTED review from the Codex bot on the current HEAD
#           with NO unaddressed P0/P1 inline findings, OR
#         - A +1 / 👍 reaction from the Codex bot on the PR issue
#           with created_at >= current HEAD committer date.
#
#       The merge gate explicitly does NOT require an APPROVED review
#       state from the Codex bot. The ChatGPT Codex Connector GitHub
#       App never emits APPROVED — it uses COMMENTED with inline
#       findings, or no review at all when it reacts 👍. See #29 for
#       live observational evidence from the PR #53 bootstrap.
#
# "Unaddressed" heuristic for v1:
#   A P0/P1 finding is considered unaddressed if it exists on the
#   current HEAD (original_commit_id == HEAD or commit_id == HEAD) in
#   Codex's LATEST review round. Findings from earlier rounds that
#   are not re-raised by Codex on the current HEAD are considered
#   implicitly addressed — the agent either fixed them or Codex
#   accepted a rebuttal. This is the simpler end of the two options
#   discussed in the #35 refinement; see #35 comment thread for the
#   reply-matching version if false-negatives become a problem.
#
# Exit codes:
#   0   All three gate conditions pass; PR is mergeable.
#   1   At least one gate condition fails. A one-line reason is
#       printed to stderr.
#   3   API / infrastructure error. Error message on stderr.
#
# Design notes:
#   - Read-only. The only API calls are GETs: pulls, reviews, comments,
#     reactions, commits, checks. No POSTs, no PATCHes, no DELETEs.
#   - Uses jq for all JSON parsing. No ad-hoc string extraction.
#   - The available_reviewers list is read from .github/review-policy.yml
#     at runtime via the same state-machine awk parser used in
#     agent-review.yml post-#54.
#
# References:
#   - Project #2 — External Review (Phase 4 Review)
#   - #35 — this script
#   - #29 — live observations
#   - REVIEW_POLICY.md § Phase 4a merge gate (canonical policy)
#   - #37 — scripts/hooks/gh-pr-guard.sh extension that will call this
#     script before allowing `gh pr merge` on a labeled PR

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

# Read a scalar field from the codex: block. See agent-review.yml
# post-#54 for the rationale on the state-machine awk parser.
codex_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^codex:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && $1 == field":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^"/, "", $0)
      gsub(/"[[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

BOT_LOGIN=$(codex_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"chatgpt-codex-connector[bot]"}

# Read the available_reviewers list (one per line). Same state-machine
# awk pattern, but collecting list items rather than matching a scalar.
# Outputs one reviewer login per line to stdout. Handles both quoted
# (`  - "name"`) and unquoted (`  - name`) list item formats.
read_available_reviewers() {
  [ -f "$CONFIG" ] || return 0
  awk '
    /^available_reviewers:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && /^ *-/ {print}
  ' "$CONFIG" | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

REVIEWERS=$(read_available_reviewers)
if [ -z "$REVIEWERS" ]; then
  echo "ERROR: no available_reviewers found in $CONFIG" >&2
  exit 3
fi

# --- logging helpers --------------------------------------------------------

log() {
  echo "[codex-review-check] $*" >&2
}

fail_gate() {
  echo "[codex-review-check] FAIL: $*" >&2
  exit 1
}

die() {
  local code=$1
  shift
  echo "[codex-review-check] ERROR: $*" >&2
  exit "$code"
}

# Fetch a paginated GitHub REST API endpoint and return the flattened JSON
# array on stdout. See the identical helper in codex-review-request.sh for
# the rationale; both scripts need the same fix (#64 review finding 3).
fetch_api_array() {
  local endpoint=$1
  local label=$2
  local raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || die 3 "failed to fetch $label: $raw"
  echo "$raw" | jq -s 'add // []' 2>/dev/null \
    || die 3 "failed to flatten $label pagination output"
}

# --- fetch PR metadata ------------------------------------------------------

log "PR $REPO#$PR_NUMBER — fetching metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) || die 3 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
PR_AUTHOR=$(echo "$PR_JSON" | jq -r '.user.login')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 3 "could not determine HEAD sha for PR #$PR_NUMBER"
fi

HEAD_COMMITTER_DATE=$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>&1) \
  || die 3 "failed to fetch commit date for $HEAD_SHA: $HEAD_COMMITTER_DATE"

log "HEAD = $HEAD_SHA    author = $PR_AUTHOR    committer date = $HEAD_COMMITTER_DATE"

# --- preflight: blocking labels --------------------------------------------
#
# `needs-human-review` is applied by the detect-disagreement job in
# agent-review.yml when two reviewers have opposing opinionated states —
# a human must resolve it. `policy-violation` is applied by
# block-self-approval when a reviewer bot tries to approve its own PR.
# Both block merge categorically and are not resolvable by Phase 4a flow.
#
# Note: `needs-external-review` is NOT a blocking label from this script's
# perspective — it's the signal that this script should run, not a block.
# Gate (c) resolves whether the external review is actually complete.
PR_LABELS=$(echo "$PR_JSON" | jq -r '[.labels[].name] | join(",")')
case ",$PR_LABELS," in
  *,needs-human-review,*)
    fail_gate "blocking label 'needs-human-review' present — human disagreement resolution required"
    ;;
  *,policy-violation,*)
    fail_gate "blocking label 'policy-violation' present — policy violation must be resolved"
    ;;
esac

# --- gate (a): CI checks green ---------------------------------------------

log "gate (a): checking CI state"

# Use the structured statusCheckRollup instead of `gh pr checks` so we can
# filter out checks that are EXPECTED to be failing during Phase 4a flow:
#
#   - "Label Gate" (from the "PR Review Policy" workflow) fails by design
#     whenever `needs-external-review`, `needs-human-review`, or
#     `policy-violation` is present on the PR. During Phase 4a, the first
#     of those labels is always set by pr-review-policy.yml, so Label Gate
#     will fail. It's the enforcement mechanism for "don't merge until
#     external review clears" — NOT a code-quality signal. We verify
#     external review clearance separately in gate (b) below.
#
# All OTHER checks must be in a successful or explicitly skipped terminal
# state. A check still running (no conclusion yet) is treated as not-green
# — the caller should wait or retry. SKIPPED is treated as success because
# many Agent Review Pipeline jobs skip by design when the label is set.
ROLLUP_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json statusCheckRollup 2>&1) \
  || die 3 "failed to fetch statusCheckRollup: $ROLLUP_JSON"

# statusCheckRollup mixes two entry types:
#   - CheckRun (GitHub Actions jobs): uses .name, .workflowName,
#     .status, .conclusion (SUCCESS/SKIPPED/FAILURE/NEUTRAL/CANCELLED/
#     TIMED_OUT/ACTION_REQUIRED).
#   - StatusContext (commit statuses, e.g. CodeRabbit): uses .context
#     (as the label) and .state (SUCCESS/FAILURE/PENDING/ERROR/EXPECTED).
#     No .workflowName, .name, .status, or .conclusion.
#
# Normalize both into {label, workflow, result}, then accept only
# SUCCESS / SKIPPED / NEUTRAL as non-blocking.
BAD_CHECKS=$(echo "$ROLLUP_JSON" | jq '
  [.statusCheckRollup[]
    | {
        label: (.name // .context // "?"),
        workflow: (.workflowName // ""),
        result: (.conclusion // .state // "")
      }
    # Filter out the known "expected to fail during Phase 4a" check.
    # Label Gate lives in the "PR Review Policy" workflow and fails by
    # design whenever needs-external-review / needs-human-review /
    # policy-violation is set. That enforcement is what Phase 4a is
    # trying to unblock; we verify clearance separately in gate (c).
    | select(
        (.workflow != "PR Review Policy") or
        (.label != "Label Gate")
      )
    # A check passes the gate iff its result is SUCCESS, SKIPPED, or
    # NEUTRAL. Everything else — FAILURE, CANCELLED, TIMED_OUT,
    # ACTION_REQUIRED, PENDING, EXPECTED, ERROR, or unknown — blocks.
    | select(
        (.result != "SUCCESS") and
        (.result != "SKIPPED") and
        (.result != "NEUTRAL")
      )
  ]
')

BAD_COUNT=$(echo "$BAD_CHECKS" | jq 'length')

if [ "$BAD_COUNT" -gt 0 ]; then
  SUMMARY=$(echo "$BAD_CHECKS" | jq -r '
    [.[] | (if .workflow == "" then .label else "\(.workflow)/\(.label)" end) + "=" + .result]
    | unique | join(", ")
  ')
  fail_gate "CI not green: $BAD_COUNT non-passing check(s): $SUMMARY"
fi

log "gate (a): CI is green (Label Gate failure, if present, is expected during Phase 4a)"

# --- gate (b): reviewer identity approval ----------------------------------

log "gate (b): checking for latest-state APPROVED review from a reviewer identity"

REVIEWS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")

# Build a JSON array of reviewer logins for the filter.
REVIEWERS_JSON=$(echo "$REVIEWERS" | jq -R . | jq -s .)

# Take each reviewer identity's LATEST OPINIONATED review state — where
# "opinionated" means APPROVED, CHANGES_REQUESTED, or DISMISSED. COMMENTED
# reviews are informational and do not change a reviewer's position. The
# gate passes iff at least one reviewer identity's latest opinionated
# state is APPROVED.
#
# Note (#64 review finding 1): the previous implementation matched any
# historical APPROVED review, which meant a reviewer who approved at t=0
# and later submitted CHANGES_REQUESTED at t=5 still cleared the gate.
# The group_by + max_by pattern below fixes that by collapsing each
# reviewer's review history down to their latest opinionated state.
#
# Multi-reviewer disagreement (one reviewer approves, another requests
# changes) is caught by the preflight blocking-label check above: the
# Agent Review Pipeline's detect-disagreement job applies
# `needs-human-review`, which the preflight rejects before this gate runs.
APPROVING_REVIEWER=$(echo "$REVIEWS_JSON" | jq -r \
  --argjson reviewers "$REVIEWERS_JSON" \
  --arg author "$PR_AUTHOR" '
    [ .[]
      | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
      | select(.user.login as $u | $reviewers | index($u))
      | select(.user.login != $author)
    ]
    | group_by(.user.login)
    | map(max_by(.submitted_at))
    | map(select(.state == "APPROVED"))
    | first
    | if . == null then empty else .user.login end
')

if [ -z "$APPROVING_REVIEWER" ]; then
  fail_gate "no reviewer identity in available_reviewers has a latest-state APPROVED review (COMMENTED reviews are ignored; later CHANGES_REQUESTED/DISMISSED overrides earlier APPROVED)"
fi

log "gate (b): latest-state APPROVED by $APPROVING_REVIEWER"

# --- gate (c): Codex cleared on current HEAD -------------------------------

log "gate (c): checking Codex clearance on $HEAD_SHA"

# Latest Codex review on the current HEAD commit (if any). Codex always
# uses COMMENTED state regardless of findings — do NOT filter on state.
CODEX_REVIEW=$(echo "$REVIEWS_JSON" | jq \
  --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
  [.[] | select(.user.login == $bot) | select(.commit_id == $sha)]
  | max_by(.submitted_at) // null
')

# If a Codex review on HEAD exists, extract its id for filtering inline
# comments down to THAT REVIEW ONLY. Older reviews on the same HEAD
# (same-HEAD rebuttal flow) must not count, per #64 review finding 2:
# if Codex posted a review with P1 findings, the agent replied with a
# rebuttal, and Codex's next review on the same HEAD cleared the
# finding, the earlier P1 comments are still visible in the API but
# tied to the older review's id. Filtering by pull_request_review_id
# scopes the findings to the latest round only.
CODEX_REVIEW_ID=$(echo "$CODEX_REVIEW" | jq -r 'if . == null then "" else .id end')

COMMENTS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline comments")

# P0/P1 inline findings from the LATEST Codex review round on HEAD only.
# P2/P3 don't block clearance per REVIEW_POLICY.md § Phase 4a step 15a.
# If there's no Codex review on HEAD, UNADDRESSED_P01 is [] — the
# reaction path is then the only way gate (c) can clear.
if [ -n "$CODEX_REVIEW_ID" ] && [ "$CODEX_REVIEW_ID" != "null" ]; then
  UNADDRESSED_P01=$(echo "$COMMENTS_JSON" | jq \
    --argjson review_id "$CODEX_REVIEW_ID" '
    [ .[]
      | select(.pull_request_review_id == $review_id)
      | select(.body | test("!\\[P[01] Badge\\]"))
      | { path, line, comment_id: .id }
    ]
  ')
else
  UNADDRESSED_P01='[]'
fi

UNADDRESSED_COUNT=$(echo "$UNADDRESSED_P01" | jq 'length')

# +1 reaction on the PR issue from the Codex bot, dated after HEAD commit.
REACTIONS_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/reactions" "reactions")

RECENT_THUMBS_UP=$(echo "$REACTIONS_JSON" | jq \
  --arg bot "$BOT_LOGIN" --arg after "$HEAD_COMMITTER_DATE" '
  [.[]
    | select(.user.login == $bot)
    | select(.content == "+1")
    | select(.created_at >= $after)
  ] | length
')

# Decide: cleared iff (review on HEAD with zero P0/P1) OR (recent +1 reaction).
CODEX_REVIEW_ON_HEAD=$(echo "$CODEX_REVIEW" | jq 'if . == null then false else true end')

CLEARED=false
CLEARANCE_REASON=""

if [ "$RECENT_THUMBS_UP" -gt 0 ]; then
  CLEARED=true
  CLEARANCE_REASON="👍 reaction from $BOT_LOGIN on or after $HEAD_COMMITTER_DATE"
elif [ "$CODEX_REVIEW_ON_HEAD" = "true" ] && [ "$UNADDRESSED_COUNT" -eq 0 ]; then
  CLEARED=true
  CLEARANCE_REASON="COMMENTED review from $BOT_LOGIN on $HEAD_SHA with no unaddressed P0/P1 findings"
fi

if [ "$CLEARED" != "true" ]; then
  if [ "$CODEX_REVIEW_ON_HEAD" = "false" ] && [ "$RECENT_THUMBS_UP" -eq 0 ]; then
    fail_gate "Codex has not cleared current HEAD (no review and no +1 reaction from $BOT_LOGIN since $HEAD_COMMITTER_DATE)"
  else
    PATHS=$(echo "$UNADDRESSED_P01" | jq -r '[.[] | "\(.path):\(.line)"] | join(", ")')
    fail_gate "Codex review on HEAD has $UNADDRESSED_COUNT unaddressed P0/P1 finding(s): $PATHS"
  fi
fi

log "gate (c): cleared — $CLEARANCE_REASON"

# --- all gates pass ---------------------------------------------------------

log "all merge gates pass — PR $REPO#$PR_NUMBER is mergeable under Phase 4a"
exit 0
