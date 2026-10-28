#!/usr/bin/env bash
# scripts/workflow/propagation_lane_label_remove.sh — the label half of caller
# C7 of ADR 0004 (#2727 slice 3c): once the trusted classifier has verified a
# PR as a faithful propagation mirror (classification `propagation`), remove
# `needs-external-review` so the Label Gate stops blocking (REVIEW_POLICY.md
# § Propagation PR review lane).
#
# This is the removal in pr-review-policy.yml's step "Propagation PR review
# lane", for the trusted consumer (trusted-policy-mutations.yml, job
# `mutate`). The producer's step also publishes the lane's diagnostic marker
# and sends the merge-clearance-recheck dispatch; the marker stays with the
# producer (GITHUB_TOKEN, no authority), and the consumer sends the dispatch
# from its own GITHUB_TOKEN job. The removal must start workflow runs (#620's
# `unlabeled` settle re-arm), so it uses LABEL_REMOVAL_TOKEN, never
# GITHUB_TOKEN.
#
# Contract:
#   env   GH_TOKEN             reads (the live PR)
#         LABEL_REMOVAL_TOKEN  the one write, DELETE the label
#         PR_NUMBER, EXPECTED_HEAD_SHA, EXPECTED_BASE_SHA, REPO
#   exit  0 removed, already absent, or the pair moved (a stale run; the
#         newer head's own run decides); 1 a read failed, the live pair was
#         malformed, the token is missing or the removal failed (fail
#         closed: the label stays and the run fails visibly).

set -euo pipefail

LABEL=needs-external-review
SHA_RE='^[0-9a-f]{40}$'

[[ "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || { echo "::error::PR_NUMBER is not a PR number." >&2; exit 1; }
[[ "${EXPECTED_HEAD_SHA:-}" =~ $SHA_RE ]] && [[ "${EXPECTED_BASE_SHA:-}" =~ $SHA_RE ]] \
  || { echo "::error::EXPECTED_HEAD_SHA / EXPECTED_BASE_SHA must be 40 hex." >&2; exit 1; }
[ -n "${REPO:-}" ] || { echo "::error::REPO is unset." >&2; exit 1; }

# read_live <output-var> → the live {head, base, labels}, or exit 1.
read_live() {
  local live
  if ! live=$(gh api "repos/$REPO/pulls/$PR_NUMBER" \
      --jq '{head: .head.sha, base: .base.sha, labels: [.labels[]?.name]}' 2>/dev/null); then
    echo "::error::Could not read PR #$PR_NUMBER; preserving $LABEL." >&2
    exit 1
  fi
  if ! jq -e --arg re "$SHA_RE" '(.head | type) == "string" and (.head | test($re))
        and (.base | type) == "string" and (.base | test($re)) and (.labels | type) == "array"' \
       <<<"$live" >/dev/null 2>&1; then
    echo "::error::PR #$PR_NUMBER's live head/base is malformed; preserving $LABEL." >&2
    exit 1
  fi
  printf -v "$1" '%s' "$live"
}

# fenced <live-json> → 0 when the live pair is the expected one.
fenced() {
  [ "$(jq -r .head <<<"$1")" = "$EXPECTED_HEAD_SHA" ] && [ "$(jq -r .base <<<"$1")" = "$EXPECTED_BASE_SHA" ]
}

LIVE=""
read_live LIVE
if ! fenced "$LIVE"; then
  echo "PR head/base moved from $EXPECTED_HEAD_SHA/$EXPECTED_BASE_SHA to $(jq -r '"\(.head)/\(.base)"' <<<"$LIVE"); leaving $LABEL to the newer head's run."
  exit 0
fi
if ! jq -e --arg l "$LABEL" '.labels | index($l) != null' <<<"$LIVE" >/dev/null; then
  echo "$LABEL is already absent; nothing to remove."
  exit 0
fi
if [ -z "${LABEL_REMOVAL_TOKEN:-}" ]; then
  echo "::error::LABEL_REMOVAL_TOKEN is empty; preserving $LABEL." >&2
  exit 1
fi

# Repeat the fence immediately before the write, as the producer does: this
# bounds the read-to-write window without claiming atomicity.
read_live LIVE
if ! fenced "$LIVE"; then
  echo "PR head/base moved during the removal; leaving $LABEL to the newer head's run."
  exit 0
fi
if ! GH_TOKEN="$LABEL_REMOVAL_TOKEN" gh api -X DELETE "repos/$REPO/issues/$PR_NUMBER/labels/$LABEL" >/dev/null; then  # NO_BARE_GH_WRITE_EXEMPT: CI workflow write under the exchanged policy-mutations app token; no agent identity to verify (#2727 3c)
  echo "::error::Could not remove $LABEL from PR #$PR_NUMBER." >&2
  exit 1
fi
echo "Removed $LABEL: PR #$PR_NUMBER at ${EXPECTED_HEAD_SHA:0:12} qualifies for the propagation review lane."
