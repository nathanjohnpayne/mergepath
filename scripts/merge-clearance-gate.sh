#!/usr/bin/env bash
# scripts/merge-clearance-gate.sh — HEAD-pinned merge-clearance gate
#
# Read-only required-status-check gate that fails CLOSED at merge time
# when a PR's clearance condition is not satisfied ON THE CURRENT HEAD.
# Never merges, labels, or comments.
#
# Context — nathanjohnpayne/mergepath#427 + #428. Two merge-gate escapes
# slipped past the enforcement layer and were caught only by the WEEKLY
# retroactive audit (pr-audit.yml), a week after merge:
#
#   #427 (matchline#245): a Dependabot dev-dependencies group bump merged
#        with NO reviewer-identity APPROVED review on the merge HEAD. The
#        dependabot-auto-merge.yml approval is transient — a rebase push
#        dismisses it (or it was never re-posted on the final SHA) — and a
#        human then merged the approved-but-unmerged PR. Nothing failed
#        closed.
#   #428 (nathanpaynedotcom#405): an over-threshold (needs-external-review)
#        PR merged with no APPROVED CLI review and no Codex review on the
#        merge HEAD. Clearance was evaluated on an EARLIER HEAD, the
#        removable-label proxy went stale, and the only required checks
#        (Label Gate green-but-stale, Codex P1 vacuously green) did not
#        represent clearance on the merge HEAD.
#
# Shared root cause: clearance was enforced via a MUTABLE proxy (a
# dismissable review, a removable label) plus a weekly audit — never as a
# HEAD-pinned required status check that re-evaluates on every push and
# fails closed. This script is that check. Modeled on the proven
# codex-p1-gate.sh / codex-p1-gate.yml pattern (required check +
# scheduled sweep + trusted default-branch checkout).
#
# Usage:
#   scripts/merge-clearance-gate.sh [PR_NUMBER] [REPO]
#   scripts/merge-clearance-gate.sh                  # env-only mode
#
# Arguments (positional take precedence; env fallbacks support the
# scheduled-sweep / workflow_dispatch invocation shape):
#   PR_NUMBER  Required (positional or $PR_NUMBER env). Integer.
#   REPO       Optional. "owner/repo". Falls back to $REPO env, then to
#              the current repo via `gh repo view`.
#
# Environment:
#   GH_TOKEN   Required. Needs pull_requests:read (+ the read scopes
#              codex-review-check.sh needs for the external-review path).
#   MERGE_CLEARANCE_CODEX_CHECK_BIN
#              Optional. Path to codex-review-check.sh. Defaults to the
#              sibling script next to this one. Tests override it to a
#              stub so the external-review dispatch + exit-code mapping
#              can be exercised without re-deriving codex-review-check's
#              full behavior.
#
# What it enforces, by PR class (evaluated on pr.head.sha):
#
#   Dependabot PR (author == 'dependabot[bot]'):
#     Gated by `dependabot.reviewer_gate.enabled` (default false; true in
#     mergepath). When enabled, BLOCKS unless a reviewer identity in
#     `available_reviewers` (≠ PR author) has a latest-state APPROVED
#     review whose commit_id == HEAD. This is the HEAD-pinned form of
#     pr-audit.yml Check 2's Dependabot path — a transient approval
#     dismissed on a rebase push re-blocks on the new HEAD.
#
#   External-review PR (carries `needs-external-review`):
#     Gated by `codex.external_review_gate.enabled` (default false; true
#     in mergepath). When enabled, delegates to codex-review-check.sh —
#     the SAME clearance predicate (gate (b) reviewer APPROVED + gate (c)
#     Codex / Phase-4b-substitute on HEAD) the auto-clear workflow uses —
#     so the merge-time gate and the label-clear logic cannot drift. CI
#     checking (gate (a)) is skipped for this invocation because this
#     gate is ITSELF a required check; waiting on the full required-check
#     rollup (which includes this gate) would deadlock. CI green is
#     enforced independently by the other required checks.
#
#   Any other PR (under-threshold, non-Dependabot, or relevant knob off):
#     CLEAN PASS (exit 0). The gate is a no-op so it can be a required
#     check on every PR without blocking normal under-threshold merges.
#
# Exit codes (same contract as scripts/codex-p1-gate.sh):
#   0   Clearance satisfied (or gate not applicable / disabled).
#   1   Clearance NOT satisfied on the current HEAD — gate BLOCKS.
#   2   Usage / config / infrastructure error. Message on stderr.
#
# Design notes:
#   - Read-only. Only GETs against the GitHub API (plus a read-only
#     delegate to codex-review-check.sh on the external-review path).
#   - bash 3.2 portable; PATH-shimmable `gh` for tests (see
#     tests/test_merge_clearance_gate.sh).
#
# References:
#   - nathanjohnpayne/mergepath#427, #428 — this script
#   - scripts/codex-review-check.sh — the shared external-review predicate
#   - .github/workflows/pr-audit.yml Check 2 — the retroactive backstop
#   - scripts/codex-p1-gate.sh — the required-check pattern this mirrors

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- argument parsing -------------------------------------------------------

if [ $# -gt 2 ]; then
  echo "Usage: $0 [PR_NUMBER] [REPO]" >&2
  echo "       PR_NUMBER and REPO may also be set via env." >&2
  exit 2
fi

PR_NUMBER=${1:-${PR_NUMBER:-}}
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PR_NUMBER required (positional arg or \$PR_NUMBER env)" >&2
  exit 2
fi
if ! echo "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
  echo "ERROR: PR_NUMBER must be an integer; got '$PR_NUMBER'" >&2
  exit 2
fi

REPO=${2:-${REPO:-}}
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  if [ -z "$REPO" ]; then
    echo "ERROR: could not detect current repo via 'gh repo view'. Pass REPO explicitly." >&2
    exit 2
  fi
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN is required. See REVIEW_POLICY.md § PAT lookup table." >&2
  exit 2
fi

# --- config readers ---------------------------------------------------------

CONFIG=".github/review-policy.yml"

# Read a scalar field nested two levels deep: `<block>:` `<sub>:` `<field>:`.
# Same state-machine awk pattern as codex-p1-gate.sh's
# codex_p1_gate_field, generalized over the top block + sub-block names so
# it serves both `dependabot.reviewer_gate.enabled` and
# `codex.external_review_gate.enabled`.
nested_field() {  # <top_block> <sub_block> <field>
  # NOTE: do not name an awk -v variable `sub` — it shadows awk's
  # built-in sub() used in the body. Use topkey/subkey/fldkey.
  local topkey=$1 subkey=$2 fldkey=$3
  [ -f "$CONFIG" ] || return 0
  awk -v topkey="$topkey" -v subkey="$subkey" -v fldkey="$fldkey" '
    $0 ~ "^" topkey ":" { in_top=1; in_sub=0; next }
    in_top && /^[^[:space:]#]/ { in_top=0; in_sub=0 }
    in_top && $1 == subkey":" { in_sub=1; next }
    in_sub && /^[[:space:]]{0,3}[^[:space:]#]/ { in_sub=0 }
    in_sub && $1 == fldkey":" {
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

# Read the available_reviewers list (one login per line). Identical parser
# to scripts/codex-review-check.sh read_available_reviewers.
read_available_reviewers() {
  [ -f "$CONFIG" ] || return 0
  awk '
    /^available_reviewers:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && /^ *-/ {print}
  ' "$CONFIG" | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

DEPENDABOT_GATE_ENABLED=$(nested_field dependabot reviewer_gate enabled)
DEPENDABOT_GATE_ENABLED=${DEPENDABOT_GATE_ENABLED:-false}
case "$DEPENDABOT_GATE_ENABLED" in
  true|false) ;;
  *)
    echo "ERROR: dependabot.reviewer_gate.enabled must be true|false; got '$DEPENDABOT_GATE_ENABLED'" >&2
    exit 2
    ;;
esac

EXTERNAL_GATE_ENABLED=$(nested_field codex external_review_gate enabled)
EXTERNAL_GATE_ENABLED=${EXTERNAL_GATE_ENABLED:-false}
case "$EXTERNAL_GATE_ENABLED" in
  true|false) ;;
  *)
    echo "ERROR: codex.external_review_gate.enabled must be true|false; got '$EXTERNAL_GATE_ENABLED'" >&2
    exit 2
    ;;
esac

# --- logging helpers --------------------------------------------------------

log() {
  echo "[merge-clearance-gate] $*" >&2
}

die() {  # <code> <msg>
  local code=$1; shift
  echo "[merge-clearance-gate] ERROR: $*" >&2
  exit "$code"
}

block() {  # <reason>
  echo ""
  echo "Merge clearance: BLOCKED — $*"
  echo ""
  exit 1
}

clear_pass() {  # <reason>
  echo "Merge clearance: PASS — $*"
  exit 0
}

fetch_api_array() {  # <endpoint> <label>
  local endpoint=$1 label=$2 raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || die 2 "failed to fetch $label: $raw"
  echo "$raw" | jq -s 'add // []' 2>/dev/null \
    || die 2 "failed to flatten $label pagination output"
}

# --- fetch PR metadata ------------------------------------------------------

log "PR $REPO#$PR_NUMBER — fetching metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) \
  || die 2 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
PR_AUTHOR=$(echo "$PR_JSON" | jq -r '.user.login')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 2 "could not determine HEAD sha for PR #$PR_NUMBER"
fi

HAS_EXTERNAL_LABEL=$(echo "$PR_JSON" \
  | jq -r 'if any(.labels[]?.name; . == "needs-external-review") then "true" else "false" end')

log "HEAD = $HEAD_SHA    author = $PR_AUTHOR    needs-external-review = $HAS_EXTERNAL_LABEL"

# --- class dispatch ---------------------------------------------------------
#
# Dependabot is checked FIRST and uses the narrower rule (CLI reviewer
# APPROVED on HEAD only — Codex does not review Dependabot PRs). This
# mirrors pr-audit.yml Check 2's precedence: a Dependabot PR that also
# carries needs-external-review is still judged by the Dependabot rule.

if [ "$PR_AUTHOR" = "dependabot[bot]" ]; then
  if [ "$DEPENDABOT_GATE_ENABLED" != "true" ]; then
    clear_pass "Dependabot PR and dependabot.reviewer_gate.enabled=false (gate disabled)"
  fi

  log "Dependabot path: requiring a reviewer-identity APPROVED review on HEAD"

  REVIEWERS=$(read_available_reviewers)
  if [ -z "$REVIEWERS" ]; then
    die 2 "no available_reviewers found in $CONFIG"
  fi
  REVIEWERS_JSON=$(echo "$REVIEWERS" | jq -R . | jq -s .)

  REVIEWS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")

  # Latest-state-per-reviewer APPROVED on the current HEAD, from a
  # reviewer identity that is not the PR author. Mirrors the proven
  # filter shape in codex-review-check.sh gate (c) Phase-4b-substitute:
  # collapse each reviewer's review history on HEAD to their most-recent
  # opinionated state, then accept only if that latest state is APPROVED.
  # A reviewer who APPROVED then later submitted CHANGES_REQUESTED on the
  # same HEAD does NOT clear (stale APPROVED rejected). commit_id == HEAD
  # is the HEAD pinning that closes the #427 escape.
  APPROVER=$(echo "$REVIEWS_JSON" | jq -r \
    --argjson reviewers "$REVIEWERS_JSON" \
    --arg author "$PR_AUTHOR" \
    --arg sha "$HEAD_SHA" '
      [ .[]
        | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
        | select(.commit_id == $sha)
        | select(.user.login as $u | $reviewers | index($u))
        | select(.user.login != $author)
      ]
      | group_by(.user.login)
      | map(max_by(.submitted_at))
      | map(select(.state == "APPROVED"))
      | first
      | if . == null then "" else .user.login end
  ')

  if [ -n "$APPROVER" ]; then
    clear_pass "Dependabot PR has a latest-state APPROVED review on HEAD $HEAD_SHA from $APPROVER"
  fi
  block "Dependabot PR has no reviewer-identity APPROVED review on the merge HEAD $HEAD_SHA. The dependabot-auto-merge approval is missing or was dismissed on a push; a fresh reviewer-identity approval on this HEAD is required (mergepath#427)."
fi

if [ "$HAS_EXTERNAL_LABEL" = "true" ]; then
  if [ "$EXTERNAL_GATE_ENABLED" != "true" ]; then
    clear_pass "needs-external-review present but codex.external_review_gate.enabled=false (gate disabled)"
  fi

  CODEX_CHECK_BIN="${MERGE_CLEARANCE_CODEX_CHECK_BIN:-$SCRIPT_DIR/codex-review-check.sh}"
  if [ ! -f "$CODEX_CHECK_BIN" ]; then
    die 2 "codex-review-check.sh not found at $CODEX_CHECK_BIN (required for the external-review path)"
  fi

  log "External-review path: delegating to codex-review-check.sh (CI gate skipped — this gate is itself a required check)"

  # Delegate to the shared predicate. CODEX_REVIEW_CHECK_SKIP_CI=1 skips
  # gate (a) for THIS invocation only (avoids the required-check
  # self-deadlock); gate (b) reviewer-APPROVED + gate (c) Codex/Phase-4b
  # on HEAD still run. codex-review-check.sh exits: 0 clear, 1 gate fail,
  # 3 infra. Map 3 → 2 (config/infra error).
  set +e
  CODEX_REVIEW_CHECK_SKIP_CI=1 bash "$CODEX_CHECK_BIN" "$PR_NUMBER" "$REPO"
  crc=$?
  set -e
  case "$crc" in
    0) clear_pass "codex-review-check.sh cleared external-review on HEAD $HEAD_SHA (reviewer APPROVED + Codex/Phase-4b on HEAD)" ;;
    1) block "codex-review-check.sh reports external review is NOT cleared on the merge HEAD $HEAD_SHA (no APPROVED CLI review and/or no Codex clearance on this HEAD). See its stderr above (mergepath#428)." ;;
    *) die 2 "codex-review-check.sh returned rc=$crc (config/infrastructure error) on PR #$PR_NUMBER" ;;
  esac
fi

# Not a Dependabot PR and not external-review-labeled → gate not
# applicable. Clean pass so the required check is green on normal
# under-threshold PRs.
clear_pass "not a Dependabot or needs-external-review PR — merge-clearance gate not applicable"
