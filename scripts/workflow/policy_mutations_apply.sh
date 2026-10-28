#!/usr/bin/env bash
# scripts/workflow/policy_mutations_apply.sh — the write step of
# trusted-policy-mutations.yml (job `mutate`, #2727 slice 3c, ADR 0004 callers
# C6 and C7). It runs from the default branch at github.workflow_sha, after
# the `classify` job admitted the producer run and re-derived its
# classification.
#
# Order, each step fail-closed:
#   1. The inputs (job outputs of `classify`) have the expected shape.
#   2. LABEL_REMOVAL_TOKEN is a GitHub App installation token. Anything else is
#      a failed exchange, never a reason to use another credential.
#   3. The admission recheck fence: the live PR still holds exactly the
#      classified head/base pair, is open, targets the default branch and is a
#      same-repository PR. A decline (exit 3) is a stale run and a no-op.
#   4. C7 when the classifier verified the propagation lane, else C6 when the
#      classification is `under-threshold` or `carried-forward`. Each helper
#      repeats its own live fence immediately before its write.
#
# Env: GH_TOKEN (reads), LABEL_REMOVAL_TOKEN (the app token), PR_NUMBER,
# EXPECTED_HEAD_SHA, EXPECTED_BASE_SHA, CLASSIFICATION, PROPAGATION_LANE,
# REPO, and GITHUB_REPOSITORY / GITHUB_REPOSITORY_ID for the fence.
# Exit: 0 applied, nothing to apply, or stale; non-zero fails the run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHA_RE='^[0-9a-f]{40}$'

fail() { echo "::error::$*" >&2; exit 1; }

[[ "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || fail "PR_NUMBER is not a PR number"
[[ "${EXPECTED_HEAD_SHA:-}" =~ $SHA_RE ]] || fail "EXPECTED_HEAD_SHA is not 40 hex"
[[ "${EXPECTED_BASE_SHA:-}" =~ $SHA_RE ]] || fail "EXPECTED_BASE_SHA is not 40 hex"

case "${PROPAGATION_LANE:-}:${CLASSIFICATION:-}" in
  true:*) MODE=propagation ;;
  *:under-threshold|*:carried-forward) MODE=reconcile ;;
  *) echo "Classification '${CLASSIFICATION:-}' (propagation lane '${PROPAGATION_LANE:-}') calls for no policy label mutation."; exit 0 ;;
esac

# shellcheck source=scripts/lib/credential-class.sh
. "$HERE/../lib/credential-class.sh"
if [ -z "${LABEL_REMOVAL_TOKEN:-}" ] || [ "$(credential_class "$LABEL_REMOVAL_TOKEN")" != app-installed ]; then
  fail "the Octo STS exchange did not return an installation token; refusing to write (no fallback to a PAT)"
fi

rc=0
"$HERE/trusted-consumer-admission.sh" recheck --pr "$PR_NUMBER" \
  --head "$EXPECTED_HEAD_SHA" --base "$EXPECTED_BASE_SHA" || rc=$?
case "$rc" in
  0) ;;
  3) echo "The classified pair no longer holds; a newer run decides. Nothing written."; exit 0 ;;
  *) fail "the admission recheck could not decide (exit $rc); nothing written" ;;
esac

case "$MODE" in
  propagation) exec "$HERE/propagation_lane_label_remove.sh" ;;
  reconcile) exec "$HERE/external_review_label_reconcile.sh" ;;
esac
