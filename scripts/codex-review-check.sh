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

REACTION_FRESHNESS_SECONDS=$(codex_field reaction_freshness_window_seconds)
REACTION_FRESHNESS_SECONDS=${REACTION_FRESHNESS_SECONDS:-1800}
if ! [[ "$REACTION_FRESHNESS_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.reaction_freshness_window_seconds must be an integer; got '$REACTION_FRESHNESS_SECONDS'" >&2
  exit 3
fi

# Honor codex.require_ci_green. When true (default), gate (a) runs
# and any non-passing required check blocks merge. When false, gate
# (a) is skipped — useful for emergency or manual flows where CI
# is intentionally bypassed. Codex caught the missing wire-up on
# the nathanpaynedotcom propagation PR #180 (the field was read by
# the policy parser and documented in the codex: block but never
# actually consulted by this script).
REQUIRE_CI_GREEN=$(codex_field require_ci_green)
REQUIRE_CI_GREEN=${REQUIRE_CI_GREEN:-true}

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
PR_BODY=$(echo "$PR_JSON" | jq -r '.body // ""')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 3 "could not determine HEAD sha for PR #$PR_NUMBER"
fi

# Extract the Authoring-Agent line and resolve it to the matching reviewer
# identity (e.g., `Authoring-Agent: claude` → `nathanpayne-claude`). Used
# by gate (b) branch 2 (#170) to detect the same-agent author/reviewer
# case where Codex's 👍 reaction can substitute for an APPROVED review.
AUTHORING_AGENT=$(echo "$PR_BODY" | grep -i -m1 -E '^Authoring-Agent:' | sed -E 's/^[Aa]uthoring-[Aa]gent:[[:space:]]*([A-Za-z0-9_-]+).*/\1/' | tr '[:upper:]' '[:lower:]')
SAME_AGENT_REVIEWER=""
if [ -n "$AUTHORING_AGENT" ]; then
  # Match against available_reviewers via suffix (e.g., "claude" matches
  # "nathanpayne-claude"). Empty if no match.
  SAME_AGENT_REVIEWER=$(echo "$REVIEWERS" | awk -v agent="-$AUTHORING_AGENT" '$0 ~ agent"$" { print; exit }')
fi

HEAD_COMMITTER_DATE=$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>&1) \
  || die 3 "failed to fetch commit date for $HEAD_SHA: $HEAD_COMMITTER_DATE"

# HEAD_PUSHED_AT: the timestamp to use as the "when did this commit
# become current on THIS PR" anchor for reaction freshness. Committer
# date is commit metadata and can be ARBITRARILY OLD if someone force-
# pushes a previously-authored commit — a stale Codex 👍 from a prior
# HEAD would then satisfy `reaction.created_at >= committer_date` even
# though the reaction predates the current HEAD's existence on this
# PR. See #64 Codex P1 finding ("Anchor reaction freshness to PR head
# update time") and the #65 round-1/2/3 follow-up findings.
#
# Iteration history and why the obvious fixes don't work:
#
#   Round 1 tried `repos/{repo}/commits/{sha}/check-runs`. Rejected:
#   that endpoint is COMMIT-scoped, not PR-scoped — if the same SHA
#   ran in an earlier context (different branch, previous PR, direct
#   push to main), the earliest check-run's started_at comes from
#   THAT context and leaks across PRs.
#
#   Round 2 tried `repos/{repo}/issues/{pr}/timeline` with a
#   `head_ref_force_pushed` event selector. Better: that endpoint is
#   strictly PR-scoped. BUT it only covers force-push. For ORDINARY
#   push / fast-forward to a descendant commit, the timeline emits a
#   `committed` event whose `created_at` is `null` — verified against
#   PR #63's raw timeline payload on 2026-04-15. There is no per-PR
#   push timestamp for non-force pushes in the GitHub API.
#
# The ordinary-push hole:
#
#   Scenario — PR HEAD is at commit A, Codex reacts 👍 on the PR at
#   time T1, then the PR is advanced via ordinary push (fast-forward)
#   to descendant commit B whose committer date is OLDER than T1
#   (e.g., cherry-pick of a pre-existing SHA, or a commit authored
#   weeks ago and just now pushed). The stale 👍 from HEAD A would
#   pass `reaction.created_at >= HEAD_COMMITTER_DATE` on HEAD B and
#   false-clear gate (c) because the anchor can only be advanced by a
#   signal we don't have access to.
#
# Two-layer mitigation applied below:
#
#   Layer 1 — per-PR push anchor via force-push events. For the cases
#   where a per-PR push time IS observable (force-push), use it.
#   Start with HEAD_COMMITTER_DATE as the base (correct for the
#   common case where committer date ≈ push time), then override to
#   `head_ref_force_pushed.created_at` if later. This closes the
#   force-push-of-old-commit variant identified in the #64 review.
#
#   Layer 2 — reaction freshness floor. Bound the exposure window of
#   the residual ordinary-push-old-committer-date hole by requiring a
#   👍 reaction to be within `codex.reaction_freshness_window_seconds`
#   of the gate-check time. A stale 👍 from a prior HEAD that outlives
#   the window is automatically filtered out, regardless of how old
#   the new HEAD's committer date is. Default 1800s (30 min) is
#   generous for the typical Phase 4a cycle (1–5 min push → clearance)
#   while catching cross-cycle stale 👍s. See review-policy.yml
#   `codex.reaction_freshness_window_seconds` for the full rationale.
#
# Residual hole: if the stale 👍 is within the freshness window AND
# the new HEAD was pushed via ordinary push AND the new HEAD has an
# old committer date, a false clear is still mechanically possible.
# That combination is narrow — it requires a rebased/cherry-picked
# old commit pushed within the freshness window after a prior-HEAD
# 👍. Closing it fully would require a per-PR push timestamp that
# GitHub does not currently expose.
HEAD_PUSHED_AT="$HEAD_COMMITTER_DATE"

TIMELINE_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/timeline" "PR timeline")

LATEST_FORCE_PUSH_TIME=$(echo "$TIMELINE_JSON" | jq -r '
  [ .[] | select(.event == "head_ref_force_pushed") | .created_at ]
  | max // ""
')

if [ -n "$LATEST_FORCE_PUSH_TIME" ] && [[ "$LATEST_FORCE_PUSH_TIME" > "$HEAD_PUSHED_AT" ]]; then
  HEAD_PUSHED_AT="$LATEST_FORCE_PUSH_TIME"
  ANCHOR_SOURCE="head_ref_force_pushed @ $LATEST_FORCE_PUSH_TIME"
else
  ANCHOR_SOURCE="HEAD committer date"
fi

# Compute freshness floor = NOW - reaction_freshness_window_seconds.
# ISO 8601 UTC so it sorts lexicographically against reaction
# created_at values. Cross-platform epoch→ISO conversion: try BSD
# `date -r` first (macOS), fall back to GNU `date -d @...` (Linux).
EPOCH_NOW=$(date +%s)
EPOCH_FLOOR=$((EPOCH_NOW - REACTION_FRESHNESS_SECONDS))
if REACTION_FLOOR_ISO=$(date -u -r "$EPOCH_FLOOR" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  :
else
  REACTION_FLOOR_ISO=$(date -u -d "@$EPOCH_FLOOR" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
    || die 3 "could not compute reaction freshness floor from epoch $EPOCH_FLOOR"
fi

# Effective threshold a 👍 reaction must satisfy = max(HEAD_PUSHED_AT,
# REACTION_FLOOR_ISO). Both are ISO 8601 UTC; lexicographic comparison
# is chronological.
if [[ "$REACTION_FLOOR_ISO" > "$HEAD_PUSHED_AT" ]]; then
  REACTION_THRESHOLD="$REACTION_FLOOR_ISO"
  REACTION_THRESHOLD_SOURCE="freshness floor (NOW - ${REACTION_FRESHNESS_SECONDS}s = $REACTION_FLOOR_ISO)"
else
  REACTION_THRESHOLD="$HEAD_PUSHED_AT"
  REACTION_THRESHOLD_SOURCE="HEAD pushed-at anchor ($HEAD_PUSHED_AT, source: $ANCHOR_SOURCE)"
fi

log "HEAD = $HEAD_SHA    author = $PR_AUTHOR"
log "committer_date = $HEAD_COMMITTER_DATE"
log "anchor = $HEAD_PUSHED_AT (source: $ANCHOR_SOURCE)"
log "reaction_threshold = $REACTION_THRESHOLD (source: $REACTION_THRESHOLD_SOURCE)"

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

if [ "$REQUIRE_CI_GREEN" != "true" ]; then
  log "gate (a): SKIPPED (codex.require_ci_green=$REQUIRE_CI_GREEN)"
else

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
# Determine which checks are REQUIRED via branch protection. Without
# this filter, gate (a) blocks on any non-passing check in the
# rollup including optional / informational ones that branch
# protection wouldn't actually require for merge. nathanpayne-codex
# caught the over-strict behavior on swipewatch propagation PR #33
# round 4.
#
# The base branch is read from PR_JSON. If branch protection isn't
# configured (or returns empty), fall back to the prior behavior
# (consider all checks). If branch protection IS configured, only
# checks listed in required_status_checks.contexts AND/OR
# required_status_checks.checks[].context block the gate.
BASE_BRANCH=$(echo "$PR_JSON" | jq -r '.base.ref')
REQUIRED_CHECK_NAMES=$(gh api "repos/$REPO/branches/$BASE_BRANCH/protection/required_status_checks" 2>/dev/null \
  | jq -r '[.contexts[]?, .checks[]?.context] | unique | .[]' 2>/dev/null \
  || true)

if [ -z "$REQUIRED_CHECK_NAMES" ]; then
  # No required-check list available. This can happen because:
  #   - The branch has no branch protection rules at all, OR
  #   - The token lacks Administration:read scope (which the
  #     required_status_checks endpoint requires).
  #
  # Earlier versions treated "no list" as "all checks required",
  # which caused over-strict blocking when the token lacked perms
  # and optional/flaky checks happened to be failing. Codex caught
  # this on swipewatch propagation PR #33 round 8.
  #
  # New behavior: log a warning and SKIP the required-check filter
  # entirely, letting gate (a) pass. The rationale is that if
  # branch protection isn't configured or the token can't read it,
  # the BRANCH PROTECTION ITSELF doesn't enforce required checks,
  # so gate (a) shouldn't either.
  log "gate (a): WARNING — could not determine required checks from branch protection for $BASE_BRANCH (no rules configured or token lacks Administration:read scope). Skipping required-check filter — all checks treated as passing this gate."
  # Skip gate (a) entirely for this case
  ROLLUP_JSON='{"statusCheckRollup":[]}'
  REQUIRED_JSON='[]'
else
  # Build a jq array of required check names
  REQUIRED_JSON=$(echo "$REQUIRED_CHECK_NAMES" | jq -R . | jq -s .)
fi

BAD_CHECKS=$(echo "$ROLLUP_JSON" | jq --argjson required_names "${REQUIRED_JSON:-[]}" '
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
    # When branch protection lists required checks, only those
    # checks block the gate. When the list is empty (no branch
    # protection configured or query failed), fall back to the
    # prior behavior of treating all checks as required.
    | select(
        ($required_names | length) == 0
        or ($required_names | index(.label)) != null
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

fi  # end REQUIRE_CI_GREEN

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
  # Branch 2 (#170): same-agent author/reviewer fallback. The
  # no-self-approve rule prohibits the agent that authored the PR from
  # also approving under its own reviewer identity, which leaves
  # same-agent PRs unable to clear gate (b) by branch 1 unless a second
  # agent (cursor / codex CLI) reviews independently. In a single-agent
  # session that's friction with no policy benefit — Codex's external
  # review IS the cross-agent signal. Accept a fresh Codex 👍 reaction
  # on the PR issue as a substitute for branch 1, BUT ONLY when the
  # PR's Authoring-Agent matches an entry in available_reviewers
  # (otherwise this would weaken gate (b) for cross-agent PRs that
  # genuinely need a reviewer-identity APPROVED).
  #
  # Freshness: same REACTION_THRESHOLD that gate (c) uses, computed
  # earlier in the script. Reaction must be at-or-after the threshold,
  # which is max(HEAD_PUSHED_AT, NOW - reaction_freshness_window).
  #
  # If a cross-agent reviewer COULD review (e.g., another agent is in
  # available_reviewers with no opinionated state on this PR), that's
  # still permitted — branch 2 is opt-in via the matching Authoring-
  # Agent header. If you want strict cross-agent enforcement, omit the
  # Authoring-Agent line; gate (b) then falls back to branch 1 only.
  if [ -n "$SAME_AGENT_REVIEWER" ]; then
    log "gate (b): no reviewer-identity APPROVED, but same-agent author/reviewer detected (Authoring-Agent: $AUTHORING_AGENT → $SAME_AGENT_REVIEWER); checking for Codex 👍 fallback per #170"
    REACTIONS_FOR_GATE_B=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/reactions" "reactions")
    GATE_B_THUMBS_UP=$(echo "$REACTIONS_FOR_GATE_B" | jq -r \
      --arg bot "$BOT_LOGIN" --arg after "$REACTION_THRESHOLD" '
      [ .[]
        | select(.user.login == $bot)
        | select(.content == "+1")
        | select(.created_at >= $after)
        | .created_at
      ]
      | max // ""
    ')
    if [ -n "$GATE_B_THUMBS_UP" ]; then
      log "gate (b): same-agent + Codex 👍 @ $GATE_B_THUMBS_UP (≥ threshold $REACTION_THRESHOLD) — branch 2 cleared"
      APPROVING_REVIEWER="(branch 2: same-agent + Codex 👍)"
    fi
  fi

  if [ -z "$APPROVING_REVIEWER" ]; then
    fail_gate "no reviewer identity in available_reviewers has a latest-state APPROVED review, and same-agent + Codex 👍 fallback (branch 2) did not apply (Authoring-Agent: ${AUTHORING_AGENT:-not set}; matched reviewer: ${SAME_AGENT_REVIEWER:-none}; threshold: $REACTION_THRESHOLD)"
  fi
else
  log "gate (b): latest-state APPROVED by $APPROVING_REVIEWER"
fi

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
#
# Filter MUST include user.login == BOT_LOGIN. Review-thread replies
# (e.g., a human quoting a P1 badge from a Codex finding while
# debugging) share the same pull_request_review_id as the original
# Codex comments, so a quote-only reply containing `![P1 Badge]`
# would otherwise be misclassified as an unaddressed Codex finding
# and incorrectly block merge. nathanpayne-codex caught this on
# nathanpaynedotcom propagation PR #180 round 3.
if [ -n "$CODEX_REVIEW_ID" ] && [ "$CODEX_REVIEW_ID" != "null" ]; then
  UNADDRESSED_P01=$(echo "$COMMENTS_JSON" | jq \
    --arg bot "$BOT_LOGIN" \
    --argjson review_id "$CODEX_REVIEW_ID" '
    [ .[]
      | select(.user.login == $bot)
      | select(.pull_request_review_id == $review_id)
      | select(.body | test("!\\[P[01] Badge\\]"))
      | { path, line, comment_id: .id }
    ]
  ')
else
  UNADDRESSED_P01='[]'
fi

UNADDRESSED_COUNT=$(echo "$UNADDRESSED_P01" | jq 'length')

# Latest +1 reaction on the PR issue from the Codex bot, filtered by
# REACTION_THRESHOLD. REACTION_THRESHOLD = max(HEAD_PUSHED_AT,
# freshness_floor), where the freshness floor is NOW minus
# reaction_freshness_window_seconds. See the anchor computation
# earlier in the script for why both bounds are required and the
# residual hole the freshness floor mitigates.
REACTIONS_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/reactions" "reactions")

LATEST_THUMBS_UP_TIME=$(echo "$REACTIONS_JSON" | jq -r \
  --arg bot "$BOT_LOGIN" --arg after "$REACTION_THRESHOLD" '
  [ .[]
    | select(.user.login == $bot)
    | select(.content == "+1")
    | select(.created_at >= $after)
    | .created_at
  ]
  | max // ""
')

# Latest Codex review submission time on HEAD (empty if none).
CODEX_REVIEW_TIME=$(echo "$CODEX_REVIEW" | jq -r 'if . == null then "" else .submitted_at end')

# Decide clearance using the LATEST Codex signal, not whichever signal
# the script happens to check first. See #64 Codex P1 finding ("Reject
# stale thumbs-up when newer Codex findings exist").
#
# Semantics: Codex sends either a review OR a 👍 reaction per pass, but
# on a PR with multiple rounds on the same HEAD it can end up with both
# historical review comments AND a reaction. The LATEST one wins:
#
#   - If Codex's most recent signal is a review, inspect its P0/P1
#     findings. Zero findings → clear. Any findings → block.
#   - If Codex's most recent signal is a 👍 reaction, clear. Codex only
#     reacts 👍 when it has no suggestions, so a newer 👍 overrides any
#     earlier review's findings.
#   - If both timestamps exist, use max() to pick the latest.
#   - If neither exists, block.
#
# All review-side analysis still uses the latest review's
# pull_request_review_id to scope findings (addressed in round 1's
# finding 2), so an older review's stale comments are never counted.

CLEARED=false
CLEARANCE_REASON=""

if [ -n "$LATEST_THUMBS_UP_TIME" ] && [ -n "$CODEX_REVIEW_TIME" ]; then
  # Both signals present on HEAD — compare timestamps. ISO 8601 sorts
  # chronologically under lexicographic string comparison.
  if [[ "$LATEST_THUMBS_UP_TIME" > "$CODEX_REVIEW_TIME" ]]; then
    CLEARED=true
    CLEARANCE_REASON="latest signal is 👍 reaction @ $LATEST_THUMBS_UP_TIME (newer than review @ $CODEX_REVIEW_TIME)"
  else
    if [ "$UNADDRESSED_COUNT" -eq 0 ]; then
      CLEARED=true
      CLEARANCE_REASON="latest signal is COMMENTED review @ $CODEX_REVIEW_TIME on $HEAD_SHA with no unaddressed P0/P1 findings (newer than 👍 @ $LATEST_THUMBS_UP_TIME)"
    fi
  fi
elif [ -n "$LATEST_THUMBS_UP_TIME" ]; then
  # Only a qualifying reaction, no review on HEAD.
  CLEARED=true
  CLEARANCE_REASON="👍 reaction from $BOT_LOGIN @ $LATEST_THUMBS_UP_TIME (on or after reaction threshold $REACTION_THRESHOLD: $REACTION_THRESHOLD_SOURCE)"
elif [ -n "$CODEX_REVIEW_TIME" ]; then
  # Only a review on HEAD, no qualifying reaction.
  if [ "$UNADDRESSED_COUNT" -eq 0 ]; then
    CLEARED=true
    CLEARANCE_REASON="COMMENTED review from $BOT_LOGIN @ $CODEX_REVIEW_TIME on $HEAD_SHA with no unaddressed P0/P1 findings"
  fi
fi

if [ "$CLEARED" != "true" ]; then
  if [ -z "$LATEST_THUMBS_UP_TIME" ] && [ -z "$CODEX_REVIEW_TIME" ]; then
    fail_gate "Codex has not cleared current HEAD (no review on $HEAD_SHA and no +1 reaction from $BOT_LOGIN on or after reaction threshold $REACTION_THRESHOLD: $REACTION_THRESHOLD_SOURCE)"
  else
    PATHS=$(echo "$UNADDRESSED_P01" | jq -r '[.[] | "\(.path):\(.line)"] | join(", ")')
    fail_gate "latest Codex signal is a review on HEAD with $UNADDRESSED_COUNT unaddressed P0/P1 finding(s): $PATHS"
  fi
fi

log "gate (c): cleared — $CLEARANCE_REASON"

# --- all gates pass ---------------------------------------------------------

log "all merge gates pass — PR $REPO#$PR_NUMBER is mergeable under Phase 4a"
exit 0
