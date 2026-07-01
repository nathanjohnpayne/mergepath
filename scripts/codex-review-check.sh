#!/usr/bin/env bash
# scripts/codex-review-check.sh — Phase 4 external-review merge gate
#
# Verifies that a pull request is ready to merge under the Phase 4
# external-review flow. Read-only. Never merges, labels, or comments
# on the PR.
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
#   (c) Codex (when codex.enabled=true) or a Phase 4b substitute
#       reviewer has cleared on or after the current HEAD commit via
#       one of four signals:
#
#         - A COMMENTED review from the Codex bot on the current HEAD
#           with NO unaddressed P0/P1 inline findings, OR
#         - A +1 / 👍 reaction from the Codex bot on the PR issue
#           with created_at >= current HEAD committer date, OR
#         - **Issue-comment verdict (#600/#567):** a Codex-bot PR issue
#           comment carrying its stable affirmative verdict phrasing
#           ("Didn't find any major issues") AND a `Reviewed commit:
#           <sha>` line whose sha prefixes the current HEAD_SHA
#           (HEAD-anchored), with NO unaddressed P0/P1 inline findings
#           on HEAD. Codex routes its verdict here rather than to a
#           review object, and its 👍 reaction expires after
#           `reaction_freshness_window_seconds`, so a genuinely-clean
#           clearance can exist only as this comment. Fail-closed: a
#           stale-HEAD, findings-bearing, changes-requested, or
#           unrecognized verdict does not match. OR
#         - **Phase 4b substitute (#218):** an APPROVED review on the
#           current HEAD (`commit_id == HEAD_SHA`) from a non-author
#           identity in `available_reviewers`, gated on
#           `codex.allow_phase_4b_substitute` (default true). This
#           handles the case where the Codex App is unavailable
#           (not review-ready, timeout, agent usage limits) and an
#           external CLI reviewer (e.g., nathanpayne-cursor or
#           nathanpayne-codex) carries the cross-agent merge gate
#           per REVIEW_POLICY.md § Phase 4b. Set the knob to false
#           for repos that genuinely require Codex bot clearance and
#           not a substitute Phase 4b reviewer. Mirrors gate (b)
#           branch 1's filter shape, scoped to HEAD via commit_id.
#
#       The merge gate explicitly does NOT require an APPROVED review
#       state from the Codex bot. The ChatGPT Codex Connector GitHub
#       App never emits APPROVED — it uses COMMENTED with inline
#       findings, or no review at all when it reacts 👍. See #29 for
#       live observational evidence from the PR #53 bootstrap.
#       When codex.enabled=false, this script ignores Codex bot
#       reviews/reactions entirely and gate (c) can clear only through
#       the Phase 4b substitute branch when enabled.
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

# --- preflight auto-source (#282) ------------------------------------------
# Auto-source the op-preflight cache when GH_TOKEN is unset and a fresh
# cache exists for this agent. codex-review-check.sh is read-only, so
# reviewer scope is the right PAT — but the auto-source picks whatever
# is in the cache, both PATs are available, and we only need one for
# the API calls below.
__CODEX_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$__CODEX_CHECK_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__CODEX_CHECK_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi

# --- gh retry helper (#324) ------------------------------------------------
# Wrap gh calls (statusCheckRollup read in particular) in 3×30s retry on
# transient failures (HTTP 5xx, rate-limit, "Resource not accessible by
# integration"). Permanent 4xx errors break out immediately. The
# canonical helper lives at scripts/lib/gh-retry-helpers.sh and is
# declared as a `requires:` dep of this script in .mergepath-sync.yml,
# so propagated consumers always carry it. The existence-guarded
# fallback below means a hand-built or partial install still runs
# (without retry) rather than aborting with "with_gh_retry: command
# not found" at the call site.
if [ -r "$__CODEX_CHECK_DIR/lib/gh-retry-helpers.sh" ]; then
  # shellcheck source=lib/gh-retry-helpers.sh
  . "$__CODEX_CHECK_DIR/lib/gh-retry-helpers.sh"
else
  with_gh_retry() { "$@"; }
fi

# Shared available_reviewers reader (#453) — replaces the local
# double-quote-only parser so coderabbit-wait.sh and this script parse the
# allow-list identically (dash + inline comment + BOTH quote styles +
# whitespace). Hard-require it: REVIEWERS below is a fail-closed gate input
# (an empty list exits 3), so a missing helper must error, not degrade.
if [ ! -r "$__CODEX_CHECK_DIR/lib/reviewers-helpers.sh" ]; then
  echo "ERROR: reviewers-helpers missing: $__CODEX_CHECK_DIR/lib/reviewers-helpers.sh" >&2
  exit 3
fi
# shellcheck source=lib/reviewers-helpers.sh
. "$__CODEX_CHECK_DIR/lib/reviewers-helpers.sh"

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
  echo "  - Set GH_TOKEN inline per REVIEW_POLICY.md § PAT lookup table." >&2
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
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

# Read a top-level (block-less) scalar field. Same shape as codex_field
# but without the in-block check — used for fields like `phase_4b_default`
# (#185) that live at the document root rather than inside `codex:` /
# `coderabbit:`. Outputs the value or empty on miss.
#
# Anchored to start-of-line (no leading whitespace) so a same-named
# nested key under e.g. `codex:` doesn't accidentally match. Codex P2
# on PR #189 caught the unanchored-match scope-bleed risk.
policy_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^[^[:space:]]/ && $1 == field":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

# phase_4b_default — controls when Phase 4b fires proactively. Validated
# against the three known values; reject unknowns with a clear error
# pointing at REVIEW_POLICY.md § Phase 4b Triggers. Missing field defaults
# to "fallback-only" (existing-consumer migration semantics per #188).
PHASE_4B_DEFAULT=$(policy_field phase_4b_default)
PHASE_4B_DEFAULT=${PHASE_4B_DEFAULT:-fallback-only}
case "$PHASE_4B_DEFAULT" in
  fallback-only|complex-changes|always) ;;
  *)
    echo "ERROR: phase_4b_default must be one of: fallback-only, complex-changes, always — got '$PHASE_4B_DEFAULT'" >&2
    echo "       See REVIEW_POLICY.md § Phase 4b Triggers." >&2
    exit 3
    ;;
esac
export PHASE_4B_DEFAULT

BOT_LOGIN=$(codex_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"chatgpt-codex-connector[bot]"}

CODEX_ENABLED=$(codex_field enabled)
CODEX_ENABLED=${CODEX_ENABLED:-true}
case "$CODEX_ENABLED" in
  true|false) ;;
  *)
    echo "ERROR: codex.enabled must be true|false; got '$CODEX_ENABLED'" >&2
    exit 3
    ;;
esac

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
# Validate strictly (consistent with codex.enabled /
# allow_phase_4b_substitute above) so a config typo can't silently skip
# gate (a) by being treated as "not true" (CodeRabbit ⚠️ Major on PR #429).
case "$REQUIRE_CI_GREEN" in
  true|false) ;;
  *)
    echo "ERROR: codex.require_ci_green must be true|false; got '$REQUIRE_CI_GREEN'" >&2
    exit 3
    ;;
esac

# Per-invocation CI-skip override (#427/#428). scripts/merge-clearance-gate.sh
# delegates the external-review clearance check to THIS script, but it is
# itself a REQUIRED status check (`Merge clearance gate`). Having gate (a)
# wait on the full required-check rollup — which now INCLUDES the
# merge-clearance gate — would deadlock: the gate can never go green
# because it would be blocking on itself. This override forces gate (a) to
# skip for the current invocation ONLY; it does not change config or the
# auto-clear path's behavior, and CI green is still enforced independently
# by the other required checks in branch protection. Honored only when set
# to the literal "1" so a stray empty/other value can't silently weaken CI
# enforcement on the normal path.
if [ "${CODEX_REVIEW_CHECK_SKIP_CI:-}" = "1" ]; then
  REQUIRE_CI_GREEN=false
fi

# Per-invocation gate-(b) HEAD-pin override (#435, the #427/#428 class one
# layer deeper). By default gate (b) branch 1 accepts each reviewer's
# latest-state APPROVED on ANY commit — so a reviewer's approval of an
# earlier head can survive a later push and clear gate (b) while gate (c)
# clears via a fresh on-HEAD Codex signal, merging a HEAD the reviewer never
# approved. When this is "1", gate (b) branch 1 additionally requires the
# APPROVED to be on the current HEAD (commit_id == HEAD_SHA), matching the
# gate-(c) Phase-4b-substitute's HEAD pinning. scripts/merge-clearance-gate.sh
# sets it so its REQUIRED check is fully HEAD-pinned (reviewer + Codex/Phase-4b
# both on HEAD). Unset (default) preserves the auto-clear path's behavior,
# where branch-protection dismiss_stale_reviews is the intended control.
REQUIRE_APPROVAL_ON_HEAD=0
if [ "${CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD:-}" = "1" ]; then
  REQUIRE_APPROVAL_ON_HEAD=1
fi

# Honor codex.allow_phase_4b_substitute. When true (default), gate (c)
# also accepts an APPROVED review on the current HEAD from an
# available_reviewers identity != the PR author as a Codex-equivalent
# clearance signal. This is the merge gate's understanding of Phase 4b
# clearance per REVIEW_POLICY.md § Phase 4b — without it, PRs that
# clear via Phase 4b (Codex App not review-ready, App timeout, agent
# usage limits) leave gate (c) failing forever and the auto-clear
# workflow stops working until a human removes the
# `needs-external-review` label by hand. Set to false for repos that
# genuinely require Codex clearance and not a substitute Phase 4b
# reviewer. See nathanjohnpayne/mergepath#218.
ALLOW_PHASE_4B_SUBSTITUTE=$(codex_field allow_phase_4b_substitute)
ALLOW_PHASE_4B_SUBSTITUTE=${ALLOW_PHASE_4B_SUBSTITUTE:-true}
case "$ALLOW_PHASE_4B_SUBSTITUTE" in
  true|false) ;;
  *)
    echo "ERROR: codex.allow_phase_4b_substitute must be true|false; got '$ALLOW_PHASE_4B_SUBSTITUTE'" >&2
    exit 3
    ;;
esac

# read_available_reviewers (and login_is_available_reviewer) now live in
# scripts/lib/reviewers-helpers.sh (sourced above, #453). They default to
# $CONFIG, so this call site is unchanged — but the allow-list now parses
# with the strongest normalization (quoted/commented entries included).
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
#
# Pipefail-safe header parse, iteration history:
#
#   r1 (#283 initial): used `echo "$PR_BODY" | grep ... | sed ... | tr ...`
#   assigned to AUTHORING_AGENT. On a PR with no `Authoring-Agent:` line
#   the `grep` step returned rc=1; under `set -eo pipefail` that rc=1
#   bubbled up as the pipeline's exit status and `set -e` aborted the
#   script before `SAME_AGENT_REVIEWER=""` ran on the next line — so any
#   PR missing the header (UI-created, external-contributor, or
#   predating the `gh-pr-guard.sh` Authoring-Agent enforcement on
#   `gh pr create`) blew up the merge gate with an opaque trace.
#
#   r2 (codex CHANGES_REQUESTED): gated extraction on a prior
#   `if printf ... | grep -qiE ...`. The if-test context suppresses
#   `set -e` on the test command, so no-header bodies now took the
#   intended "skip extraction, leave SAME_AGENT_REVIEWER empty" path
#   without aborting.
#
#   r3 (codex CHANGES_REQUESTED): r2 still had a silent failure on
#   LARGE bodies. `printf '%s\n' "$PR_BODY" | grep` is a producer
#   pipe; once the body crosses the 64KB pipe buffer AND the
#   `Authoring-Agent:` header is near the top of the body, grep -q
#   matches and exits early, printf gets SIGPIPE (rc=141), pipefail
#   bubbles the 141 as the pipeline's exit. In the guard `if` test,
#   141 is non-zero → the `if` evaluates false → AUTHORING_AGENT and
#   SAME_AGENT_REVIEWER stay empty even though the header IS present.
#   THE EXACT HOLE r1+r2 set out to close, reopened by a different
#   mechanism. Fix: replace producer pipe with bash herestring
#   `<<<"$PR_BODY"` — no producer process, no SIGPIPE.
#
#   r4 (codex CHANGES_REQUESTED — THIS iteration): r3 still failed
#   case-coverage. The guard's `grep -i` matched any case of the
#   header (e.g. `AUTHORING-AGENT: Claude`), but the extraction
#   `sed -E 's/^[Aa]uthoring-[Aa]gent:[[:space:]]*([A-Za-z0-9_-]+).*/\1/'`
#   only character-classed the FIRST letter of each word — fully-
#   uppercase keys fell through sed unchanged, and the trailing `tr`
#   then lowercased the WHOLE line (`AUTHORING-AGENT: Claude` →
#   `authoring-agent: claude`), so AUTHORING_AGENT was set to the
#   string "authoring-agent: claude" rather than just "claude". The
#   awk suffix match on `-authoring-agent: claude` against
#   `nathanpayne-claude` then failed → SAME_AGENT_REVIEWER="" →
#   same-agent exclusion no-op'd → self-approval hole reopened.
#   GNU sed's `I` regex flag would be the natural fix but BSD/macOS
#   sed doesn't support it, so we can't rely on it.
#
#   Fix: reorder the pipeline so `tr` lowercases BEFORE sed. sed
#   then sees a canonical-lowercase line and uses a strict-lowercase
#   pattern — no character classes needed. Order is grep -i (still
#   case-insensitive on detection) → tr (canonicalize) → sed
#   (extract from canonical). Works for every case-permutation of
#   the header without per-letter character classing.
#   (nathanpayne-codex Phase 4b r4 on PR #283.)
AUTHORING_AGENT=""
SAME_AGENT_REVIEWER=""
if grep -qiE '^Authoring-Agent:' <<<"$PR_BODY"; then
  AUTHORING_AGENT=$(grep -i -m1 -E '^Authoring-Agent:' <<<"$PR_BODY" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/^authoring-agent:[[:space:]]*([a-z0-9_-]+).*/\1/')
  if [ -n "$AUTHORING_AGENT" ]; then
    # Match against available_reviewers via suffix (e.g., "claude"
    # matches "nathanpayne-claude"). Empty if no match — also
    # pipefail-safe: REVIEWERS is small (~3 lines) so SIGPIPE on the
    # `echo` producer cannot fire here, and awk always exits 0 even
    # when no record matched.
    SAME_AGENT_REVIEWER=$(echo "$REVIEWERS" | awk -v agent="-$AUTHORING_AGENT" '$0 ~ agent"$" { print; exit }')
  fi
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
# `human-hold` is a manual hard freeze. All three block merge
# categorically and are not resolvable by Phase 4a flow.
#
# Note: `needs-external-review` is NOT a blocking label from this script's
# perspective — it's the signal that this script should run, not a block.
# Gate (c) resolves whether the external review is actually complete.
pr_has_label() {
  local label="$1"
  echo "$PR_JSON" | jq -e --arg label "$label" 'any(.labels[].name; . == $label)' >/dev/null
}

if pr_has_label "needs-human-review"; then
  fail_gate "blocking label 'needs-human-review' present — human disagreement resolution required"
fi
if pr_has_label "policy-violation"; then
  fail_gate "blocking label 'policy-violation' present — policy violation must be resolved"
fi
if pr_has_label "human-hold"; then
  fail_gate "blocking label 'human-hold' present — human hard hold must be released"
fi

# --- gate (a): CI checks green ---------------------------------------------

if [ "$REQUIRE_CI_GREEN" != "true" ]; then
  log "gate (a): SKIPPED (codex.require_ci_green=$REQUIRE_CI_GREEN)"
else

log "gate (a): checking CI state"

# Use the structured statusCheckRollup instead of `gh pr checks` so we can
# filter out checks that are EXPECTED to be failing during Phase 4a flow:
#
#   - "Label Gate" (from the "PR Review Policy" workflow) fails by design
#     whenever `needs-external-review`, `needs-human-review`,
#     `policy-violation`, or `human-hold` is present on the PR. During Phase 4a, the first
#     of those labels is always set by pr-review-policy.yml, so Label Gate
#     will fail. It's the enforcement mechanism for "don't merge until
#     external review clears" — NOT a code-quality signal. We verify
#     external review clearance separately in gate (b) below.
#
# All OTHER checks must be in a successful or explicitly skipped terminal
# state. A check still running (no conclusion yet) is treated as not-green
# — the caller should wait or retry. SKIPPED is treated as success because
# many Agent Review Pipeline jobs skip by design when the label is set.
# Drop `2>&1`: with_gh_retry emits per-attempt diagnostics to stderr on
# transient failures, and merging those lines into ROLLUP_JSON would
# corrupt the jq parse below — a transient 5xx + successful retry would
# look like an infra error (gate (a) fail) when the retry actually
# recovered. Caught by codex P1 on PR #328 round 1. The retry diagnostics
# still surface in the workflow log via stderr, so the visibility cost
# is zero.
ROLLUP_JSON=$(with_gh_retry gh pr view "$PR_NUMBER" --repo "$REPO" --json statusCheckRollup) \
  || die 3 "failed to fetch statusCheckRollup (see stderr above for retry diagnostics)"

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
# Fetch the branch-protection required-check list, DISTINGUISHING
# "read OK, none required" (gate (a) imposes no filter, passes) from
# "could not read" (fail closed) — #465 Option A. The prior code swallowed
# the gh failure and treated BOTH cases as "no required checks = pass",
# which fails OPEN: when the token cannot read branch protection (403) or
# the API errors (5xx), a genuinely-failing required check went unnoticed.
#
# gh api exits non-zero on any 4xx/5xx; capture stderr to tell a 404 (the
# required_status_checks sub-resource is not configured → legitimately NO
# required checks) apart from 403 (token lacks Administration:read scope) or
# 5xx/network (transient) — the latter leave the required list UNKNOWN.
protection_err=$(mktemp)
if protection_json=$(gh api "repos/$REPO/branches/$BASE_BRANCH/protection/required_status_checks" 2>"$protection_err"); then
  REQUIRED_CHECK_NAMES=$(printf '%s' "$protection_json" | jq -r '[.contexts[]?, .checks[]?.context] | unique | .[]' 2>/dev/null || true)
  protection_readable=1
elif grep -q 'HTTP 404' "$protection_err"; then
  REQUIRED_CHECK_NAMES=""
  protection_readable=1   # 404 → no required_status_checks protection → none required
else
  REQUIRED_CHECK_NAMES=""
  protection_readable=0   # 403 token scope / 5xx / network → could not read
fi
rm -f "$protection_err"

if [ "$protection_readable" -eq 0 ]; then
  # FAIL CLOSED (#465): the required-check list is UNKNOWN (token lacks
  # Administration:read, or the API errored). Do NOT optimistically treat
  # this as "no required checks = pass". Keep the FULL rollup and leave
  # REQUIRED_JSON empty — the BAD_CHECKS filter below treats an empty
  # required list as "all checks required", so every non-skipped check must
  # be green. SKIPPED/NEUTRAL still pass (optional jobs that skip by design
  # do not block), so this closes the fail-open hole while only blocking on
  # ACTUAL failures (a narrower reversal of the swipewatch #33 skip than a
  # blanket exit-3). To restore the precise required-check filter, grant the
  # token Administration:read.
  log "gate (a): WARNING — could not read branch-protection required checks for $BASE_BRANCH (token lacks Administration:read scope, or API error). Failing closed: every non-skipped rollup check must be green (#465)."
  REQUIRED_JSON='[]'
elif [ -z "$REQUIRED_CHECK_NAMES" ]; then
  # Read succeeded; branch protection lists NO required checks (404 or empty
  # contexts). Nothing to enforce — gate (a) imposes no required-check
  # filter (the other gates still run).
  log "gate (a): branch protection for $BASE_BRANCH lists no required checks; gate (a) imposes no required-check filter."
  ROLLUP_JSON='{"statusCheckRollup":[]}'
  REQUIRED_JSON='[]'
else
  # Build a jq array of required check names.
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
    # policy-violation / human-hold is set. That enforcement is what Phase 4a is
    # trying to unblock; we verify clearance separately in gate (c).
    | select(
        (.workflow != "PR Review Policy") or
        (.label != "Label Gate")
      )
    # When branch protection lists required checks, only those
    # checks block the gate. When the list is empty (no branch
    # protection configured or query failed), fall back to the
    # prior behavior of treating all checks as required.
    #
    # Bind `.label` to a variable BEFORE the `$required_names | ...`
    # sub-pipeline, because inside that sub-pipeline `.` rebinds to
    # `$required_names` (the array) and `.label` would then try to
    # index the array, producing the jq error
    # "Cannot index array with string \"label\"".
    | (.label) as $label_name
    | select(
        ($required_names | length) == 0
        or ($required_names | index($label_name)) != null
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

# --- Codex issue-comment verdict signal (#600 / #567) ----------------------
#
# Codex posts its review verdict as a PR ISSUE COMMENT
# (issues/{pr}/comments), e.g. "Codex Review: Didn't find any major issues.
# Swish!" followed by a "**Reviewed commit:** <sha>" line — NOT always a
# review object or a 👍 reaction (#567). The 👍 reaction additionally
# EXPIRES after reaction_freshness_window_seconds and Codex does not
# reliably re-post it on a re-review, so a genuinely-clean Codex clearance
# can manifest purely as this issue-comment verdict. Recognize a
# HEAD-anchored AFFIRMATIVE verdict as a clearance signal for gate (b)
# branch 2 and gate (c) (#600); this ADDS to — never replaces — the
# existing review-object and 👍 paths.
#
# Fail-closed matching — a comment qualifies as CODEX_HEAD_VERDICT_TIME
# ONLY when ALL hold:
#   1. author == BOT_LOGIN (the Codex connector bot);
#   2. body matches Codex's STABLE affirmative phrasing
#      ("Didn't find any major issues") — a structured shape, not
#      open-ended NLP;
#   3. body carries a `Reviewed commit: <sha>` line whose <sha> is a
#      prefix of the current HEAD_SHA (HEAD-anchored; Codex abbreviates
#      the sha, so match by prefix, not equality).
# A findings-bearing verdict, a changes-requested verdict, a stale-HEAD
# verdict (Reviewed commit != HEAD), or unrecognized text does NOT match —
# the signal stays empty and the gate falls through to its other
# (fail-closed) paths. Gate (c) additionally cross-checks that there are
# zero unaddressed P0/P1 inline findings on HEAD before honoring it, so a
# verdict comment can never override a live required-tier finding.
#
# Only a Codex-bot signal, so compute it only when codex.enabled=true;
# leaves disabled repos byte-identical in behavior.
CODEX_HEAD_VERDICT_TIME=""
CODEX_HEAD_VERDICT_ANY_TIME=""
if [ "$CODEX_ENABLED" = "true" ]; then
  ISSUE_COMMENTS_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments")
  # Select the LATEST HEAD-anchored Codex verdict comment FIRST (any
  # disposition), THEN decide whether that latest one is affirmative. Filtering
  # to affirmative-only BEFORE taking max() would let an older clean "Didn't
  # find any major issues" keep the signal non-empty even when a NEWER
  # "Codex Review: Found …" / changes-requested verdict for the same HEAD was
  # posted after it — a false clear (Codex P1 on #608). A "HEAD-anchored
  # verdict" is any Codex-bot comment carrying a `Reviewed commit: <sha>` line
  # whose sha prefixes HEAD; keeping the non-affirmative timestamp too lets the
  # Phase 4b substitute freshness guard reject a stale approval over a newer
  # negative verdict (Codex P2 on #608).
  CODEX_VERDICT_JSON=$(echo "$ISSUE_COMMENTS_JSON" | jq -c \
    --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    ($sha | ascii_downcase) as $head
    | [ .[]
        | select(.user.login == $bot)
        | . as $c
        # HEAD anchor — extract every "Reviewed commit: <sha>" hex token
        # (lowercased; tolerate ":", "**", backticks, whitespace between the
        # label and the sha) and require at least one to prefix HEAD. This
        # keeps verdicts of ANY disposition so latest-wins can see a newer
        # negative verdict.
        | ( [ $c.body
              | ascii_downcase
              | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
              | .[0]
            ] ) as $shas
        | select( ($shas | length) > 0
                  and ($shas | any(. as $s | $head | startswith($s))) )
        # affirmative ONLY when the Codex verdict HEADER line is the clean
        # verdict — anchored to a line starting with "codex review:" then the
        # no-major-issues phrase (multiline, case-insensitive; .? tolerates a
        # straight, absent, or typographic apostrophe). Matching the phrase
        # ANYWHERE would let a NEGATIVE or unrecognized verdict that QUOTES
        # prior affirmative text (e.g. a blockquote of an earlier clean
        # verdict) read as affirmative and break fail-closed (CodeRabbit Major
        # on #608). Real Codex verdicts always lead with that header line.
        | { created_at: .created_at,
            affirmative: (.body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b")) }
      ]
    | max_by(.created_at) // null
  ')
  CODEX_HEAD_VERDICT_ANY_TIME=$(echo "$CODEX_VERDICT_JSON" | jq -r 'if . == null then "" else .created_at end')
  if [ "$(echo "$CODEX_VERDICT_JSON" | jq -r 'if . == null then "false" else (.affirmative | tostring) end')" = "true" ]; then
    CODEX_HEAD_VERDICT_TIME="$CODEX_HEAD_VERDICT_ANY_TIME"
    log "codex verdict: latest HEAD-anchored verdict @ $CODEX_HEAD_VERDICT_TIME is AFFIRMATIVE (Reviewed commit prefixes $HEAD_SHA)"
  elif [ -n "$CODEX_HEAD_VERDICT_ANY_TIME" ]; then
    log "codex verdict: latest HEAD-anchored verdict @ $CODEX_HEAD_VERDICT_ANY_TIME is NON-affirmative — not a clearance signal (fail closed); carried into the Phase 4b freshness guard"
  fi
fi

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
# Self-approval guard: exclude BOTH the GitHub PR-author login
# (`$author`, typically nathanjohnpayne) AND the authoring-agent's
# reviewer identity (`$same_agent_reviewer`, e.g.
# nathanpayne-claude for a claude-authored PR). GitHub-native
# branch protection only blocks reviewer == PR-author, but per
# REVIEW_POLICY.md § No-self-approve scoping the authoring agent's
# OWN reviewer identity is also disqualified for Phase 4 (over-
# threshold) gate-(b) clearance — that's the exact case branch 2
# below (same-agent + Codex 👍) is designed to handle. Without
# the second exclusion, a claude-authored PR could be cleared by
# nathanpayne-claude posting APPROVED, since nathanpayne-claude
# is different from nathanjohnpayne and thus passes the bare
# `.user.login != $author` filter. (nathanpayne-codex Phase 4b
# finding on the 263caf3 sync wave.)
APPROVING_REVIEWER=$(echo "$REVIEWS_JSON" | jq -r \
  --argjson reviewers "$REVIEWERS_JSON" \
  --arg author "$PR_AUTHOR" \
  --arg same_agent_reviewer "$SAME_AGENT_REVIEWER" \
  --arg sha "$HEAD_SHA" \
  --arg require_head "$REQUIRE_APPROVAL_ON_HEAD" '
    [ .[]
      | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
      | select(.user.login as $u | $reviewers | index($u))
      | select(.user.login != $author)
      | select($same_agent_reviewer == "" or .user.login != $same_agent_reviewer)
    ]
    | group_by(.user.login)
    | map(max_by(.submitted_at))
    # Collapse to each reviewer'\''s LATEST opinionated state FIRST, then require
    # that latest state to be APPROVED — and, when HEAD-pinned (#435), to be on
    # the current HEAD. Filtering non-HEAD reviews BEFORE this collapse would
    # discard a later blocking CHANGES_REQUESTED/DISMISSED on an outdated/pending
    # commit and let a stale earlier APPROVED still clear gate (b). (Codex P1 on
    # PR #436.)
    | map(select(.state == "APPROVED" and ($require_head != "1" or .commit_id == $sha)))
    | first
    | if . == null then empty else .user.login end
')

if [ -z "$APPROVING_REVIEWER" ]; then
  # Branch 2 (#170): same-agent author/reviewer fallback. For Phase 4
  # PRs, the no-self-approve scoping rule (REVIEW_POLICY.md § No-self-
  # approve scoping; #220) prohibits the agent that authored the PR from
  # also approving under its own reviewer identity — that's the case
  # this branch handles. (Under-threshold PRs don't reach this script;
  # they self-approve via the reviewer identity per the same scoping
  # rule.) Same-agent PRs at Phase 4 would otherwise be unable to clear
  # gate (b) by branch 1 unless a second agent (cursor / codex CLI)
  # reviews independently. In a single-agent session that's friction
  # with no policy benefit when Codex is enabled — Codex's external
  # review IS the cross-agent signal. Accept a fresh Codex 👍 reaction
  # on the PR issue as a substitute for branch 1, BUT ONLY when
  # codex.enabled=true AND the PR's Authoring-Agent matches an entry in
  # available_reviewers (otherwise this would weaken gate (b) for
  # cross-agent PRs that genuinely need a reviewer-identity APPROVED).
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
  if [ -n "$SAME_AGENT_REVIEWER" ] && [ "$CODEX_ENABLED" != "true" ]; then
    log "gate (b): same-agent Codex 👍 fallback unavailable because codex.enabled=false"
  elif [ -n "$SAME_AGENT_REVIEWER" ]; then
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
    elif [ -n "$CODEX_HEAD_VERDICT_TIME" ]; then
      # #600: the 👍 reaction expires after reaction_freshness_window_seconds
      # and Codex does not reliably re-post it on a re-review, but its
      # HEAD-anchored affirmative issue-comment verdict ("Didn't find any
      # major issues" + "Reviewed commit: <HEAD>") is an equally strong
      # same-agent cross-review signal — and, being HEAD-anchored by the
      # Reviewed-commit sha, needs no time-window freshness check. Accept it
      # as a branch-2 clearance too. (gate (c) still enforces zero
      # unaddressed P0/P1 on HEAD, so this only substitutes for the reviewer
      # cross-check, not the findings check.)
      log "gate (b): same-agent + Codex HEAD-anchored verdict comment @ $CODEX_HEAD_VERDICT_TIME — branch 2 cleared (#600)"
      APPROVING_REVIEWER="(branch 2: same-agent + Codex verdict comment)"
    fi
  fi

  if [ -z "$APPROVING_REVIEWER" ]; then
    fail_gate "no reviewer identity in available_reviewers has a latest-state APPROVED review, and same-agent + Codex 👍 fallback (branch 2) did not apply (codex.enabled=$CODEX_ENABLED; Authoring-Agent: ${AUTHORING_AGENT:-not set}; matched reviewer: ${SAME_AGENT_REVIEWER:-none}; threshold: $REACTION_THRESHOLD)"
  fi
else
  log "gate (b): latest-state APPROVED by $APPROVING_REVIEWER"
fi

# --- gate (c): Codex / Phase 4b cleared on current HEAD --------------------

log "gate (c): checking external clearance on $HEAD_SHA (codex.enabled=$CODEX_ENABLED)"

CLEARED=false
CLEARANCE_REASON=""
CODEX_REVIEW='null'
CODEX_REVIEW_ID=""
COMMENTS_JSON='[]'
UNADDRESSED_P01='[]'
UNADDRESSED_COUNT=0
REACTIONS_JSON='[]'
LATEST_THUMBS_UP_TIME=""
CODEX_REVIEW_TIME=""

if [ "$CODEX_ENABLED" = "true" ]; then

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

# Resolution-aware filter (Option B on #460 / aligns gate (c) with
# codex-p1-gate.sh and the weekly audit). Thread resolution is the
# sanctioned override in codex-p1-gate.sh, so gate (c) must honor it too —
# otherwise the two required checks contradict (codex-p1-gate clears a
# resolved P0/P1 thread while gate (c) still blocks it, so a legitimately
# resolved finding can never satisfy both). A P0/P1 finding counts as
# unaddressed only when its review thread is NOT resolved.
#
# This runs at MERGE time (live), so isResolved is the state AT merge — no
# retrospective staleness applies here (that is the weekly audit's concern,
# which bounds resolution by merge time). Mirrors codex-p1-gate.sh's
# GraphQL reviewThreads → comment-databaseId → isResolved join.
#
# Fail CLOSED on lookup failure: leave UNADDRESSED_P01 unfiltered (every
# finding treated as unresolved), so a GraphQL hiccup or a >100-thread PR
# can't clear a real P0/P1. Only fetched when there is at least one finding.
if [ "$(echo "$UNADDRESSED_P01" | jq 'length')" -gt 0 ]; then
  RES_OWNER=${REPO%/*}
  RES_NAME=${REPO#*/}
  RES_QUERY='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved comments(first:100){nodes{databaseId}}}}}}}'
  # 2>/dev/null (not 2>&1): with_gh_retry emits retry diagnostics to stderr;
  # merging them into THREADS_JSON would make a transient-retry-then-success
  # look like malformed JSON and force a needless fail-closed block
  # (CodeRabbit Major + Codex P2 on #464). Keep only stdout (the JSON).
  THREADS_JSON=$(with_gh_retry gh api graphql -F owner="$RES_OWNER" -F name="$RES_NAME" -F pr="$PR_NUMBER" -f query="$RES_QUERY" 2>/dev/null) || THREADS_JSON=""
  if ! echo "$THREADS_JSON" | jq -e '.data.repository.pullRequest.reviewThreads' >/dev/null 2>&1; then
    log "gate (c): WARNING reviewThreads resolution lookup failed — failing closed (treating all P0/P1 findings as unresolved)"
  elif [ "$(echo "$THREADS_JSON" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')" = "true" ]; then
    log "gate (c): WARNING PR has >100 review threads; resolution pagination unsupported — failing closed (treating all P0/P1 findings as unresolved)"
  else
    RESOLUTION_MAP=$(echo "$THREADS_JSON" | jq '
      .data.repository.pullRequest.reviewThreads.nodes
      | map((.isResolved) as $r | .comments.nodes | map({ key: (.databaseId | tostring), value: $r }))
      | flatten | from_entries')
    UNADDRESSED_P01=$(echo "$UNADDRESSED_P01" | jq --argjson map "$RESOLUTION_MAP" '
      [ .[] | . as $c | ($map[($c.comment_id | tostring)] // false) as $resolved | select($resolved != true) ]')
    log "gate (c): resolution-aware — $(echo "$UNADDRESSED_P01" | jq 'length') unresolved P0/P1 finding(s) after honoring thread resolution"
  fi
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

# Decide clearance using the LATEST Codex signal on HEAD among THREE signal
# types — 👍 reaction, COMMENTED review, and issue-comment verdict — not
# whichever the script checks first (#64, extended for the verdict in
# #600/#608). Codex emits one signal per pass but can accumulate several on the
# same HEAD across rounds; the newest wins:
#
#   - 👍 reaction: Codex reacts 👍 only when it has no suggestions → affirmative,
#     clears (a newer 👍 overrides an earlier review's findings).
#   - COMMENTED review: clears iff no unaddressed P0/P1 on HEAD.
#   - issue-comment verdict: clears iff the latest HEAD-anchored verdict is
#     AFFIRMATIVE (CODEX_HEAD_VERDICT_TIME non-empty) AND no unaddressed P0/P1.
#     A NON-affirmative latest verdict fails closed.
#
# #608 P1: the verdict MUST participate in latest-signal-wins, not run as a
# fallback after CLEARED is set — otherwise an older clean 👍/review clears the
# gate even though Codex re-flagged issues in a NEWER negative verdict. Pick the
# newest signal by timestamp; ties resolve to the most authoritative disposition
# (verdict > review > 👍, via iteration order + replace-on-tie), so an ambiguous
# same-second tie fails closed when the verdict is negative. All review-side
# P0/P1 analysis still scopes to the latest review's pull_request_review_id
# (round-1 finding 2), so stale comments never count.
LATEST_SIGNAL_KIND=""
LATEST_SIGNAL_TIME=""
for __sig in "thumbs|$LATEST_THUMBS_UP_TIME" "review|$CODEX_REVIEW_TIME" "verdict|$CODEX_HEAD_VERDICT_ANY_TIME"; do
  __k=${__sig%%|*}
  __t=${__sig#*|}
  [ -n "$__t" ] || continue
  # Replace on strictly-newer OR on an equal timestamp: iterating thumbs →
  # review → verdict means the last one at the max time wins the tie, giving
  # priority verdict > review > 👍.
  if [ -z "$LATEST_SIGNAL_TIME" ] || [[ "$__t" > "$LATEST_SIGNAL_TIME" ]] \
     || [ "$__t" = "$LATEST_SIGNAL_TIME" ]; then
    LATEST_SIGNAL_TIME="$__t"
    LATEST_SIGNAL_KIND="$__k"
  fi
done

case "$LATEST_SIGNAL_KIND" in
  thumbs)
    CLEARED=true
    CLEARANCE_REASON="latest Codex signal is 👍 reaction @ $LATEST_SIGNAL_TIME (newest of 👍/review/verdict on HEAD; on or after reaction threshold $REACTION_THRESHOLD)"
    ;;
  review)
    if [ "$UNADDRESSED_COUNT" -eq 0 ]; then
      CLEARED=true
      CLEARANCE_REASON="latest Codex signal is COMMENTED review @ $LATEST_SIGNAL_TIME on $HEAD_SHA with no unaddressed P0/P1 findings"
    fi
    ;;
  verdict)
    if [ -n "$CODEX_HEAD_VERDICT_TIME" ] && [ "$UNADDRESSED_COUNT" -eq 0 ]; then
      CLEARED=true
      CLEARANCE_REASON="latest Codex signal is a HEAD-anchored AFFIRMATIVE verdict comment @ $LATEST_SIGNAL_TIME (Reviewed commit prefixes $HEAD_SHA; no unaddressed P0/P1) (#600)"
    else
      log "gate (c): latest Codex signal is a non-affirmative or findings-bearing verdict comment @ $LATEST_SIGNAL_TIME — fail closed, does not clear (#608 P1)"
    fi
    ;;
esac

else
  log "gate (c): codex.enabled=false — ignoring Codex bot review/reaction signals; requiring Phase 4b substitute clearance when allowed"
fi

# Phase 4b substitute (#218): if Codex hasn't cleared via 👍 or a
# COMMENTED-on-HEAD review, and the knob is on, accept a fresh APPROVED
# review on the current HEAD from an available_reviewers identity that
# is NOT the PR author. This is the merge gate's understanding of
# Phase 4b clearance per REVIEW_POLICY.md § Phase 4b: when the Codex
# App is unavailable / times out / hits usage limits, an external CLI
# reviewer (e.g., nathanpayne-cursor or nathanpayne-codex) is the
# cross-agent signal. The freshness anchor is a strict commit_id ==
# HEAD_SHA match — no time-window approximation needed since the
# review API returns the exact SHA the review was submitted on.
#
# Latest-state-per-reviewer filter (Codex P1 round 1 on PR #225):
# group reviews on HEAD by reviewer identity, take each reviewer's
# most-recent review on this SHA, then accept ONLY if that latest
# state is APPROVED. Without this guard, a reviewer who first APPROVED
# then later submitted CHANGES_REQUESTED on the same HEAD would still
# satisfy the substitute via the stale APPROVED. Mirrors gate (b)
# branch 1's same-shaped filter (line 547 above).
#
# When this branch fires, the auto-clear-blocking-labels workflow
# correctly removes `needs-external-review` on the next event-driven
# trigger or scheduled sweep, instead of stalling on a permanently-
# failing gate (c) until a human clears the label by hand.
if [ "$CLEARED" != "true" ] && [ "$ALLOW_PHASE_4B_SUBSTITUTE" = "true" ]; then
  # Same self-approval guard as gate (b) branch 1 above: exclude
  # the authoring-agent's reviewer identity in addition to the
  # GitHub PR-author login. Without this, a claude-authored
  # over-threshold PR could clear the Phase 4b substitute via
  # nathanpayne-claude posting APPROVED on HEAD — collapsing the
  # cross-agent guarantee Phase 4b is meant to provide. (Same
  # nathanpayne-codex Phase 4b finding on the 263caf3 sync wave.)
  PHASE_4B_APPROVER=$(echo "$REVIEWS_JSON" | jq -r \
    --argjson reviewers "$REVIEWERS_JSON" \
    --arg author "$PR_AUTHOR" \
    --arg same_agent_reviewer "$SAME_AGENT_REVIEWER" \
    --arg sha "$HEAD_SHA" '
      [ .[]
        | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
        | select(.commit_id == $sha)
        | select(.user.login as $u | $reviewers | index($u))
        | select(.user.login != $author)
        | select($same_agent_reviewer == "" or .user.login != $same_agent_reviewer)
      ]
      | group_by(.user.login)
      | map(max_by(.submitted_at))
      | map(select(.state == "APPROVED"))
      | max_by(.submitted_at)
      | if . == null then "" else .user.login + "|" + .submitted_at end
  ')
  if [ -n "$PHASE_4B_APPROVER" ]; then
    PHASE_4B_LOGIN="${PHASE_4B_APPROVER%|*}"
    PHASE_4B_TIME="${PHASE_4B_APPROVER#*|}"

    # Latest-signal-wins guard (codex CHANGES_REQUESTED + CodeRabbit ⚠️
    # Major @ scripts/codex-review-check.sh:811 on PR #225 round 3):
    # accept the Phase 4b substitute ONLY when its APPROVED is the
    # newest external clearance signal on HEAD. If a Codex bot review
    # or 👍 reaction on HEAD is newer than the Phase 4b APPROVED, the
    # Codex signal carries the verdict — and since the Codex paths
    # above already failed to clear (CLEARED != true at this point),
    # that means Codex's newer signal indicated unresolved P0/P1
    # findings or had no qualifying clearance, and the older Phase 4b
    # APPROVED must NOT override.
    #
    # Edge cases:
    # - No Codex signals on HEAD (`LATEST_CODEX_SIGNAL_TIME` empty):
    #   Phase 4b APPROVED is the only external-clearance evidence on
    #   HEAD; accept it. This is the bare Phase 4b path (Codex App
    #   not review-ready / timed out / etc.).
    # - Phase 4b APPROVED newer than Codex review timestamp: the
    #   reviewer saw Codex's findings and approved anyway (or the
    #   findings were addressed and Codex's review captured them
    #   without a 👍). Treat as deliberate; accept.
    LATEST_CODEX_SIGNAL_TIME="$LATEST_THUMBS_UP_TIME"
    if [ -n "$CODEX_REVIEW_TIME" ] && { [ -z "$LATEST_CODEX_SIGNAL_TIME" ] || [[ "$CODEX_REVIEW_TIME" > "$LATEST_CODEX_SIGNAL_TIME" ]]; }; then
      LATEST_CODEX_SIGNAL_TIME="$CODEX_REVIEW_TIME"
    fi
    # #608 P2: a HEAD-anchored Codex verdict COMMENT (affirmative OR not) is
    # also a Codex signal on HEAD. Fold its timestamp in so a stale Phase 4b
    # APPROVED cannot clear over a NEWER negative verdict comment — the
    # affirmative-only CODEX_HEAD_VERDICT_TIME would drop a newer negative
    # verdict and let the stale approval through. CODEX_HEAD_VERDICT_ANY_TIME
    # is the latest HEAD-anchored verdict regardless of disposition.
    if [ -n "$CODEX_HEAD_VERDICT_ANY_TIME" ] && { [ -z "$LATEST_CODEX_SIGNAL_TIME" ] || [[ "$CODEX_HEAD_VERDICT_ANY_TIME" > "$LATEST_CODEX_SIGNAL_TIME" ]]; }; then
      LATEST_CODEX_SIGNAL_TIME="$CODEX_HEAD_VERDICT_ANY_TIME"
    fi
    if [ -z "$LATEST_CODEX_SIGNAL_TIME" ] || [[ "$PHASE_4B_TIME" > "$LATEST_CODEX_SIGNAL_TIME" ]]; then
      CLEARED=true
      CLEARANCE_REASON="Phase 4b substitute: latest-state APPROVED on HEAD from $PHASE_4B_LOGIN @ $PHASE_4B_TIME (codex.allow_phase_4b_substitute=true; newer than any Codex bot signal on HEAD: ${LATEST_CODEX_SIGNAL_TIME:-none})"
    else
      log "gate (c): Phase 4b substitute candidate $PHASE_4B_LOGIN @ $PHASE_4B_TIME is older than newest Codex bot signal @ $LATEST_CODEX_SIGNAL_TIME; latest-signal-wins guard rejects substitute"
    fi
  fi
fi

if [ "$CLEARED" != "true" ]; then
  if [ "$CODEX_ENABLED" != "true" ]; then
    if [ "$ALLOW_PHASE_4B_SUBSTITUTE" = "true" ]; then
      fail_gate "codex.enabled=false and no Phase 4b substitute APPROVED on $HEAD_SHA from a non-author identity in available_reviewers"
    else
      fail_gate "codex.enabled=false and codex.allow_phase_4b_substitute=false, so no gate (c) clearance path is available"
    fi
  elif [ -z "$LATEST_THUMBS_UP_TIME" ] && [ -z "$CODEX_REVIEW_TIME" ]; then
    if [ "$ALLOW_PHASE_4B_SUBSTITUTE" = "true" ]; then
      fail_gate "Codex has not cleared current HEAD and no Phase 4b substitute APPROVED on $HEAD_SHA from a non-author identity in available_reviewers (no review on HEAD, no +1 reaction from $BOT_LOGIN on or after reaction threshold $REACTION_THRESHOLD: $REACTION_THRESHOLD_SOURCE)"
    else
      fail_gate "Codex has not cleared current HEAD (no review on $HEAD_SHA and no +1 reaction from $BOT_LOGIN on or after reaction threshold $REACTION_THRESHOLD: $REACTION_THRESHOLD_SOURCE)"
    fi
  else
    PATHS=$(echo "$UNADDRESSED_P01" | jq -r '[.[] | "\(.path):\(.line)"] | join(", ")')
    fail_gate "latest Codex signal is a review on HEAD with $UNADDRESSED_COUNT unaddressed P0/P1 finding(s): $PATHS"
  fi
fi

log "gate (c): cleared — $CLEARANCE_REASON"

# --- all gates pass ---------------------------------------------------------

log "all merge gates pass — PR $REPO#$PR_NUMBER is mergeable under Phase 4 external review"
exit 0
