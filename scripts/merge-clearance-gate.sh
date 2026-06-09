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
#   External-review PR:
#     Gated by `codex.external_review_gate.enabled` (default false; true
#     in mergepath). Applicability is DERIVED from the PR's intrinsic
#     properties — over `external_review_threshold` lines, OR a changed
#     file matching `external_review_paths`, OR the `needs-external-review`
#     label present — NOT from the label alone. (Trusting the label would
#     reopen the #428 stale-label race: after a push, this gate can run
#     before pr-review-policy.yml re-adds the label, and a label-only check
#     would false-clear on an uncleared HEAD. #429 Codex P1.) When it
#     applies, delegates to codex-review-check.sh — the SAME clearance
#     predicate (gate (b) reviewer APPROVED + gate (c) Codex /
#     Phase-4b-substitute on HEAD) the auto-clear workflow uses — so the
#     merge-time gate and the label-clear logic cannot drift. CI checking
#     (gate (a)) is skipped for this invocation because this gate is ITSELF
#     a required check; waiting on the full required-check rollup (which
#     includes this gate) would deadlock. CI green is enforced
#     independently by the other required checks. Verified propagation PRs
#     (trusted github-actions[bot] lane marker, label absent) are EXEMPT —
#     the pr-review-policy.yml lane already cleared them; re-deriving would
#     force them into Phase 4 and break the lane (#429 Codex round-2 P1).
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

# --- tool preflight ---------------------------------------------------------
# Fail with the documented config/usage code (2) if a hard dependency is
# missing, rather than dying mid-run with an opaque 127 that the workflow
# would map to a generic CI error (CodeRabbit ⚠️ on PR #429).
for _tool in gh jq awk; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$_tool' not found on PATH" >&2
    exit 2
  fi
done

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

# Propagation-lane exemption (#429), HEAD-PINNED. Returns 0 (true) iff a PR
# comment authored by github-actions[bot] carries the propagation-lane marker
# scoped to the CURRENT head SHA — i.e. `mergepath-propagation-lane
# verified-head=<HEAD_SHA>`. .github/workflows/pr-review-policy.yml posts that
# marker ONLY after mergepath@<sha>'s verify-propagation-pr.sh byte-confirms a
# faithful mirror AT THAT HEAD, and a PR author cannot post as
# github-actions[bot] — so it is a TRUSTED, head-scoped signal that the lane
# already exempted THIS head from external review (REVIEW_POLICY.md §
# Propagation PR review lane).
#
# Why head-pinned (Codex round-3 P1 + nathanpayne-codex CHANGES_REQUESTED on
# #429): an unscoped "was-ever-a-mirror" marker is posted once and survives a
# later divergent push. On the synchronize where this gate finishes before
# pr-review-policy.yml re-adds needs-external-review, an unscoped check would
# go GREEN on an unverified large/.github PR. Pinning the exemption to the
# current head SHA closes that race independently of label timing: a diverged
# (or merely newer-but-not-yet-verified) head has no matching marker, so the
# gate does NOT exempt it and falls through to threshold/paths derivation.
# A DIVERGED push never gets a marker at all (the lane's propagation_lane is
# false → it posts nothing for that head). A faithful re-push is briefly
# not-yet-exempt (fail-closed) until the lane posts the new head's marker and
# the next event / scheduled sweep re-evaluates.
#
# Without this exemption, deriving applicability from threshold/protected-paths
# would force verified propagation PRs — large by design, touching .github/**,
# AND carrying an `Authoring-Agent` stamp (so codex-review-check.sh's
# same-agent guard disqualifies their normal internal approval) — into Phase
# 4/Codex clearance, breaking the documented under-threshold lane.
#
# Marker contract is shared with pr-review-policy.yml — keep the
# `mergepath-propagation-lane verified-head=<sha>` form in sync.
lane_verified() {
  local comments
  comments=$(gh api --paginate "repos/$REPO/issues/$PR_NUMBER/comments" 2>/dev/null | jq -s 'add // []' 2>/dev/null) || return 1
  echo "$comments" | jq -e --arg head "$HEAD_SHA" '
    any(.[]; (.user.login == "github-actions[bot]")
             and ((.body // "") | contains("mergepath-propagation-lane verified-head=" + $head)))
  ' >/dev/null 2>&1
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

# --- external-review applicability (DERIVED, not label-trusting) -----------
#
# #429 Codex P1: keying the external arm on the CURRENT label state would
# reintroduce the exact stale-label race this gate exists to close. After a
# push, this gate can run on `synchronize` BEFORE pr-review-policy.yml
# re-adds `needs-external-review` for the new HEAD; a label-only check would
# then fall through to "not applicable" and go GREEN on an uncleared HEAD
# (the #428 escape, reopened). So derive applicability from the PR's
# INTRINSIC properties — the same line-threshold + protected-paths
# computation pr-review-policy.yml's External Review Check uses — and treat
# the label, when present, as an additional force-on signal (a human may
# add it to a small PR). Config (threshold + paths) is read from the
# TRUSTED default-branch review-policy.yml; the changed-file set comes from
# the API (this gate runs on a default-branch checkout with no local PR
# diff). Propagation PRs are NOT special-cased: they reach clearance via
# codex-review-check.sh's internal-reviewer-APPROVED-on-HEAD (Phase-4b
# substitute) path, consistent with the lane's standard "internal
# reviewer-identity APPROVED required" rule.

if [ "$EXTERNAL_GATE_ENABLED" = "true" ]; then
  REQUIRES_EXTERNAL=false
  REQUIRES_REASON=""

  if [ "$HAS_EXTERNAL_LABEL" = "true" ]; then
    # Label present forces the arm on (a human may add it to a small PR;
    # or the propagation lane RE-ADDED it after a divergence). Not subject
    # to the propagation exemption below — a present label means the lane's
    # latest per-HEAD verdict is "needs review."
    REQUIRES_EXTERNAL=true
    REQUIRES_REASON="needs-external-review label present"
  elif lane_verified; then
    # Verified propagation PR: a trusted github-actions[bot] lane marker
    # scoped to THIS head SHA is present (label absent). The lane already
    # byte-verified this exact head and exempted it from external review;
    # defer to it and do NOT re-derive from threshold/paths (#429).
    log "verified propagation lane (trusted head-pinned marker for $HEAD_SHA, label absent) — exempt from external-review derivation; deferring to pr-review-policy.yml lane"
  else
    # `|| true` so a missing key (grep no-match → pipeline non-zero under
    # pipefail) does NOT abort the script before the `:-300` fallback runs
    # (CodeRabbit ⚠️ on PR #429).
    THRESHOLD=$(grep -E '^external_review_threshold:' "$CONFIG" 2>/dev/null | awk '{print $2}' || true)
    THRESHOLD=${THRESHOLD:-300}
    if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then THRESHOLD=300; fi

    FILES_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/files" "PR files")

    # Sum additions+deletions, excluding the same generated/lockfile
    # patterns pr-review-policy.yml's git-diff pathspec excludes.
    LINES_CHANGED=$(echo "$FILES_JSON" | jq '
      [ .[]
        | select((.filename
            | test("(\\.lock$)|(lock\\.json$)|(\\.min\\.js$)|(\\.min\\.css$)|(\\.generated\\.)|(\\.g\\.dart$)|(\\.freezed\\.dart$)")) | not)
        | ((.additions // 0) + (.deletions // 0)) ]
      | add // 0')
    LINES_CHANGED=${LINES_CHANGED:-0}

    if [ "$LINES_CHANGED" -ge "$THRESHOLD" ]; then
      REQUIRES_EXTERNAL=true
      REQUIRES_REASON="$LINES_CHANGED lines changed >= threshold $THRESHOLD"
    else
      # Protected-paths match, reusing the SAME helpers pr-review-policy.yml
      # uses (no drift). Resolved relative to this script so they work from a
      # trusted default-branch checkout; they take the config path + read
      # candidate filenames on stdin (no filesystem access to PR content).
      # MERGE_CLEARANCE_WORKFLOW_DIR overrides the helper dir (tests only).
      #
      # Fail CLOSED on any failure to RUN the matcher (missing helper, parse
      # error, match error): a protected-path PR must never slip through as
      # "threshold-only" just because the matcher couldn't run. The helpers
      # ship with this gate via .mergepath-sync.yml, so their absence means a
      # broken install — require external review rather than skip it.
      # (CodeRabbit ⚠️ Major on PR #429.) Note: a SUCCESSFUL parse that
      # yields no entries (external_review_paths absent/empty) is NOT a
      # failure — it legitimately means "no protected paths," so the gate
      # does not fail closed in that case.
      WF_DIR="${MERGE_CLEARANCE_WORKFLOW_DIR:-$SCRIPT_DIR/workflow}"
      PARSE="$WF_DIR/parse_policy_list.sh"
      MATCH="$WF_DIR/match_protected_paths.sh"
      if [ ! -f "$PARSE" ] || [ ! -f "$MATCH" ]; then
        REQUIRES_EXTERNAL=true
        REQUIRES_REASON="protected-paths check unavailable (parser/matcher missing under $WF_DIR) — failing closed"
      else
        set +e
        PATHS=$(bash "$PARSE" "$CONFIG" external_review_paths)
        parse_rc=$?
        set -e
        if [ "$parse_rc" -ne 0 ]; then
          REQUIRES_EXTERNAL=true
          REQUIRES_REASON="protected-paths parse failed (rc=$parse_rc) — failing closed"
        elif [ -n "$PATHS" ]; then
          PATTERNS=()
          while IFS= read -r pline; do
            [ -n "$pline" ] && PATTERNS+=("$pline")
          done <<<"$PATHS"
          if [ "${#PATTERNS[@]}" -gt 0 ]; then
            CHANGED_FILES=$(echo "$FILES_JSON" | jq -r '.[].filename')
            set +e
            MATCHED=$(printf '%s\n' "$CHANGED_FILES" | bash "$MATCH" "${PATTERNS[@]}")
            match_rc=$?
            set -e
            if [ "$match_rc" -ne 0 ]; then
              REQUIRES_EXTERNAL=true
              REQUIRES_REASON="protected-paths match failed (rc=$match_rc) — failing closed"
            elif [ -n "$MATCHED" ]; then
              REQUIRES_EXTERNAL=true
              REQUIRES_REASON="protected paths modified: $(printf '%s' "$MATCHED" | tr '\n' ' ')"
            fi
          fi
        fi
      fi
    fi
  fi

  if [ "$REQUIRES_EXTERNAL" = "true" ]; then
    log "external review applies ($REQUIRES_REASON); delegating to codex-review-check.sh (CI gate skipped — this gate is itself a required check)"

    CODEX_CHECK_BIN="${MERGE_CLEARANCE_CODEX_CHECK_BIN:-$SCRIPT_DIR/codex-review-check.sh}"
    if [ ! -f "$CODEX_CHECK_BIN" ]; then
      die 2 "codex-review-check.sh not found at $CODEX_CHECK_BIN (required for the external-review path)"
    fi

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
      0) clear_pass "external review cleared on HEAD $HEAD_SHA ($REQUIRES_REASON; reviewer APPROVED + Codex/Phase-4b on HEAD)" ;;
      1) block "external review is NOT cleared on the merge HEAD $HEAD_SHA ($REQUIRES_REASON; no APPROVED CLI review and/or no Codex clearance on this HEAD). See codex-review-check.sh stderr above (mergepath#428)." ;;
      *) die 2 "codex-review-check.sh returned rc=$crc (config/infrastructure error) on PR #$PR_NUMBER" ;;
    esac
  fi
fi

# Not a Dependabot PR, and external review does not apply (under threshold,
# no protected paths, no label — or the external gate is disabled). Clean
# pass so the required check is green on normal under-threshold PRs.
clear_pass "merge-clearance gate not applicable (under threshold, no protected paths, no external-review label; or external gate disabled)"
