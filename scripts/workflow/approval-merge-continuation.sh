#!/usr/bin/env bash
# Re-enter merge readiness from a trusted workflow completion event.

set -euo pipefail

usage() {
  echo "usage: approval-merge-continuation.sh <PR#> [owner/repo]" >&2
  exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
PR_NUMBER="$1"
REPO="${2:-${GITHUB_REPOSITORY:-}}"
case "$PR_NUMBER" in *[!0-9]*|'') usage ;; esac
[ -n "$REPO" ] || usage

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

not_ready() {
  echo "approval continuation: not ready — $*"
  exit 4
}

infra_error() {
  echo "approval continuation: ERROR — $*" >&2
  exit 3
}

read_pr() {
  gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json state,isDraft,headRefOid,url,labels
}

blocking_labels() {
  jq -r '[.labels[]?.name] | map(select(. == "needs-external-review" or . == "needs-human-review" or . == "policy-violation" or . == "human-hold")) | join(",")'
}

login=$(gh api user --jq .login 2>/dev/null) || infra_error "could not verify merge token identity"
[ "$login" = "nathanjohnpayne" ] || infra_error "merge token resolves to $login, expected nathanjohnpayne"

initial=$(read_pr) || infra_error "could not read PR #$PR_NUMBER"
state=$(jq -r '.state // ""' <<<"$initial")
draft=$(jq -r 'if has("isDraft") then .isDraft else true end' <<<"$initial")
head=$(jq -r '.headRefOid // ""' <<<"$initial")
url=$(jq -r '.url // ""' <<<"$initial")
labels=$(blocking_labels <<<"$initial")
[ "$state" = "OPEN" ] || not_ready "PR is $state"
[ "$draft" = "false" ] || not_ready "PR is draft"
[ -n "$head" ] && [ -n "$url" ] || infra_error "PR response lacks head or URL"
[ -z "$labels" ] || not_ready "blocking labels present: $labels"

set +e
bash "$ROOT/scripts/codex-review-check.sh" "$PR_NUMBER" "$REPO"
gate_rc=$?
set -e
case "$gate_rc" in
  0) ;;
  1) not_ready "merge-clearance predicate is not satisfied" ;;
  *) infra_error "merge-clearance predicate returned rc=$gate_rc" ;;
esac

if ! bash "$ROOT/scripts/review-feedback-accounting.sh" "$PR_NUMBER" "$REPO"; then
  not_ready "review feedback is not fully accounted"
fi

set +e
bash "$ROOT/scripts/resolve-pr-threads.sh" "$PR_NUMBER" --repo "$REPO" --list
threads_rc=$?
set -e
case "$threads_rc" in
  0) ;;
  3) not_ready "unresolved review conversations remain" ;;
  *) infra_error "conversation readback returned rc=$threads_rc" ;;
esac

# Re-read all mutable safety state immediately before arming. The first read
# prevents needless gate work; this read is the authority for the write.
final=$(read_pr) || infra_error "could not re-read PR #$PR_NUMBER"
final_state=$(jq -r '.state // ""' <<<"$final")
final_draft=$(jq -r 'if has("isDraft") then .isDraft else true end' <<<"$final")
final_head=$(jq -r '.headRefOid // ""' <<<"$final")
final_labels=$(blocking_labels <<<"$final")
[ "$final_state" = "OPEN" ] || not_ready "PR changed state to $final_state"
[ "$final_draft" = "false" ] || not_ready "PR became draft"
[ "$final_head" = "$head" ] || not_ready "head changed during evaluation"
[ -z "$final_labels" ] || not_ready "blocking labels appeared: $final_labels"

if ! gh pr merge "$url" --repo "$REPO" --squash --auto --match-head-commit "$final_head"; then
  infra_error "could not enable exact-head auto-merge"
fi
echo "approval continuation: armed exact-head auto-merge for $REPO#$PR_NUMBER at $final_head"
