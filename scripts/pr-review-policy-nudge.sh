#!/usr/bin/env bash
# pr-review-policy-nudge.sh — make pr-review-policy.yml re-evaluate one PR.
#
# `.github/workflows/pr-review-policy.yml` produces two branch-protection
# required contexts, `Self-Review Required` and `Label Gate`, and it is
# triggered by `pull_request` only. When that delivery is missed or dropped,
# both contexts sit at "Expected — Waiting for status to be reported", the PR
# is unmergeable, and nothing re-fires them (#931).
#
# This script is the recovery path. It does NOT publish either context. It
# edits the PR body, replacing a single inert provenance marker, which is a
# `pull_request` action the workflow already listens for (`edited`) — so the
# canonical producer runs and reports its own verdicts on the current head.
#
# WHY THE NUDGE AND NOT A SECOND PRODUCER. Both contexts come from inline
# steps of that workflow, so adding a `schedule` or `workflow_dispatch`
# entrance to it means gating its jobs to `pull_request`, and a skipped
# Actions job still materializes a check run under the job's `name` whose
# `skipped` conclusion satisfies a required check. Publishing the two
# contexts from a separate workflow instead means owning producer-ownership
# arbitration, lineage retirement, pre-write fences, and a re-derivation of
# the Phase 4 classification the missed run also owned. Making the trusted
# producer run has none of those obligations. See
# docs/architecture/0003-pr-review-policy-recovery-producer.md.
#
# WHY A BODY EDIT AND NOT A LABEL TOGGLE. `labeled`/`unlabeled` are also in
# the workflow's trigger list, but its `external-review-labeling` job — the
# Phase 4 classifier — is explicitly gated OFF for those two actions. A label
# toggle would recover the two gates and leave the classification unrecovered,
# which is precisely the case where an absent `needs-external-review` is a
# symptom of the missed delivery rather than a clearance.
#
# THIS IS NOT A "RERUN MY FAILING CHECKS" BUTTON. The refusal below is on
# presence, not on success: once both contexts have reported on the head,
# recovery has done its job, and a red verdict is a job done.
#
# Usage:
#   scripts/pr-review-policy-nudge.sh <PR#> [owner/repo]
#
# The repo defaults to the current checkout's. Reads use whatever credential
# `gh` resolves; the single write goes through scripts/gh-as-author.sh, which
# verifies the token's identity before it runs.
#
# Exit codes:
#   0 = the PR body was edited; the canonical workflow will re-evaluate
#   1 = bad arguments, or the PR is not open
#   2 = infrastructure failure (gh read failed, validator or wrapper missing)
#   3 = not needed — both contexts have already reported on the current head
#   4 = refused — the edit would make an otherwise valid body fail Self-Review

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_AS_AUTHOR="${MERGEPATH_NUDGE_GH_AS_AUTHOR:-$ROOT/scripts/gh-as-author.sh}"
VALIDATE="${MERGEPATH_NUDGE_VALIDATE_BIN:-$ROOT/scripts/validate-pr-body.sh}"

# The two required contexts the workflow produces, spelled as the job `name:`
# values GitHub uses for the check-run name.
CONTEXT_SELF_REVIEW="Self-Review Required"
CONTEXT_LABEL_GATE="Label Gate"

# One marker, replaced rather than appended: this records the most recent
# nudge, not a history of them. The timestamp is load-bearing rather than
# decorative — GitHub emits no `edited` event for a body that did not change,
# so a second attempt has to write different bytes to fire the workflow at all.
MARKER_PREFIX="mergepath-recovery-nudge:"

die() { echo "pr-review-policy-nudge: $*" >&2; exit "${2:-1}"; }

PR_NUMBER="${1:-}"
REPO="${2:-}"
case "$PR_NUMBER" in
  '' | *[!0-9]*)
    echo "usage: scripts/pr-review-policy-nudge.sh <PR#> [owner/repo]" >&2
    exit 1
    ;;
esac

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || die "could not resolve the repository; pass it explicitly as the second argument" 2
fi

# Fail closed rather than skipping the invariant below: editing the body of a
# PR whose mergeability depends on that body, without being able to check what
# the edit did to it, is the one thing this script must never do silently.
[ -r "$VALIDATE" ] || die "PR-body validator not found at $VALIDATE; refusing to edit a body it cannot check" 2
[ -x "$GH_AS_AUTHOR" ] || die "author wrapper not executable at $GH_AS_AUTHOR" 2

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>/dev/null) \
  || die "could not read $REPO#$PR_NUMBER" 2

STATE=$(printf '%s' "$PR_JSON" | jq -r '.state // ""')
HEAD_SHA=$(printf '%s' "$PR_JSON" | jq -r '.head.sha // ""')
# An empty PR body reads back as JSON null, not "".
OLD_BODY=$(printf '%s' "$PR_JSON" | jq -r '.body // ""')

[ -n "$HEAD_SHA" ] || die "PR $REPO#$PR_NUMBER returned no head SHA" 2
[ "$STATE" = "open" ] || die "PR $REPO#$PR_NUMBER is $STATE, not open" 1

# --- refuse on presence, not on success ------------------------------------
# Any check run under either name means that context reported on this head.
# The conclusion is deliberately not consulted: a red `Label Gate` is the
# canonical producer having run and having decided, which is the outcome this
# script exists to bring about.
NAMES=$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/check-runs" \
  --jq '.check_runs[].name' 2>/dev/null) \
  || die "could not list check runs on $HEAD_SHA" 2

has_context() { printf '%s\n' "$NAMES" | grep -Fxq "$1"; }

MISSING=()
has_context "$CONTEXT_SELF_REVIEW" || MISSING+=("$CONTEXT_SELF_REVIEW")
has_context "$CONTEXT_LABEL_GATE" || MISSING+=("$CONTEXT_LABEL_GATE")

if [ "${#MISSING[@]}" -eq 0 ]; then
  echo "pr-review-policy-nudge: both required contexts have already reported on $HEAD_SHA — nothing to recover."
  echo "  This recovers a missed delivery; it does not re-run a context that reported and failed."
  exit 3
fi

# --- build the new body ----------------------------------------------------
# Removing the previous marker leaves the body ending in the blank line that
# preceded it; command substitution strips those trailing newlines, so a
# repeated nudge does not grow the body by a blank line each time. Nothing
# above the tail is touched.
STRIPPED=$(printf '%s' "$OLD_BODY" | grep -v -e "^<!-- $MARKER_PREFIX .* -->$" || true)
new_body_for_stamp() { printf '%s\n\n<!-- %s %s -->' "$STRIPPED" "$MARKER_PREFIX" "$1"; }
NEW_BODY=$(new_body_for_stamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

# The stamp has one-second granularity, so a nudge repeated inside the same
# second rebuilds a byte-identical body. GitHub emits no `edited` event for a
# body that did not change, so writing that would report success having fired
# nothing — the "recorded that we called it, not that it worked" shape. Wait
# out the second, then assert the difference rather than assuming it.
if [ "$NEW_BODY" = "$OLD_BODY" ]; then
  sleep 1
  NEW_BODY=$(new_body_for_stamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
fi
[ "$NEW_BODY" != "$OLD_BODY" ] \
  || die "the rebuilt marker is byte-identical to the current body; the edit would fire no event" 2

# --- non-introduction invariant --------------------------------------------
# The rule is NOT "the body must be valid" — that is the author's problem, and
# an invalid body is exactly the state a red `Self-Review Required` should
# report. The rule is that this edit must not be what breaks it: whatever the
# original body passes, the nudged body must pass too.
validate_rc() {  # <body> [flag...]  -> the validator's exit status
  local body=$1; shift
  local rc=0
  printf '%s' "$body" | bash "$VALIDATE" "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

OLD_FULL=$(validate_rc "$OLD_BODY")
NEW_FULL=$(validate_rc "$NEW_BODY")
OLD_SELF_REVIEW=$(validate_rc "$OLD_BODY" --self-review-only)
NEW_SELF_REVIEW=$(validate_rc "$NEW_BODY" --self-review-only)

if { [ "$OLD_FULL" -eq 0 ] && [ "$NEW_FULL" -ne 0 ]; } \
  || { [ "$OLD_SELF_REVIEW" -eq 0 ] && [ "$NEW_SELF_REVIEW" -ne 0 ]; }; then
  die "the nudge marker would make this body fail PR-body validation (full $OLD_FULL->$NEW_FULL, self-review $OLD_SELF_REVIEW->$NEW_SELF_REVIEW); refusing to edit" 4
fi

# --- the one write ---------------------------------------------------------
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-review-policy-nudge.XXXXXX")
trap 'rm -f "$BODY_FILE"' EXIT
printf '%s\n' "$NEW_BODY" >"$BODY_FILE"

"$GH_AS_AUTHOR" -- gh pr edit "$PR_NUMBER" --repo "$REPO" --body-file "$BODY_FILE" >/dev/null \
  || die "the PR body edit failed; the workflow was not nudged" 2

MISSING_LIST=$(printf '%s, ' "${MISSING[@]}"); MISSING_LIST=${MISSING_LIST%, }
echo "pr-review-policy-nudge: edited $REPO#$PR_NUMBER (head $HEAD_SHA); not yet reported: $MISSING_LIST"
echo "  The 'edited' action re-runs pr-review-policy.yml's three jobs, including External Review Check."
echo "  This script published nothing; the verdicts are the canonical producer's."
