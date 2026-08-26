#!/usr/bin/env bash
# Re-enter merge readiness from a trusted workflow completion event.

set -euo pipefail

usage() {
  echo "usage: approval-merge-continuation.sh [--disarm-shared-author-only] <PR#> [owner/repo]" >&2
  exit 2
}

MODE="continue"
if [ "${1:-}" = "--disarm-shared-author-only" ]; then
  MODE="disarm-only"
  shift
fi
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
PR_NUMBER="$1"
REPO="${2:-${GITHUB_REPOSITORY:-}}"
case "$PR_NUMBER" in *[!0-9]*|'') usage ;; esac
[ -n "$REPO" ] || usage

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../lib/blocking-labels.sh
source "$ROOT/scripts/lib/blocking-labels.sh"
# shellcheck source=../lib/review-policy-scalar.sh
source "$ROOT/scripts/lib/review-policy-scalar.sh"

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
    --json state,isDraft,headRefOid,baseRefName,baseRefOid,url,labels,author,autoMergeRequest
}

blocking_labels() {
  jq -r '.labels[]?.name' | mergepath_blocking_labels_csv
}

policy=$(bash "$ROOT/scripts/workflow/resolve_base_policy.sh" \
  --repo "$REPO" --pr "$PR_NUMBER" --materialize-default) \
  || infra_error "could not resolve the governing base policy"
[ -f "$policy" ] || infra_error "governing base policy was not materialized"
expected_author=$(review_policy_scalar "$policy" author_identity)
[ "$policy" = "$ROOT/.github/review-policy.yml" ] || rm -f "$policy"
[ -n "$expected_author" ] || infra_error "governing base policy names no author_identity"

identity_err=$(mktemp "${TMPDIR:-/tmp}/approval-continuation-identity.XXXXXX")
set +e
login=$(gh api user --jq .login 2>"$identity_err")
identity_rc=$?
set -e
identity_msg=$(cat "$identity_err" 2>/dev/null || true)
rm -f "$identity_err"
[ "$identity_rc" -eq 0 ] || infra_error "could not verify merge token identity: ${identity_msg:-unknown API error}"
[ "$login" = "$expected_author" ] || infra_error "merge token resolves to $login, expected $expected_author"

initial=$(read_pr) || infra_error "could not read PR #$PR_NUMBER"
if ! jq -e '
  type == "object" and
  (.author.login | type == "string" and length > 0) and
  has("autoMergeRequest") and
  ((.autoMergeRequest == null) or (.autoMergeRequest | type == "object"))
' >/dev/null 2>&1 <<<"$initial"; then
  infra_error "PR response lacks valid author or auto-merge metadata"
fi
state=$(jq -r '.state // ""' <<<"$initial")
draft=$(jq -r 'if has("isDraft") then .isDraft else true end' <<<"$initial")
head=$(jq -r '.headRefOid // ""' <<<"$initial")
base_ref=$(jq -r '.baseRefName // ""' <<<"$initial")
base_sha=$(jq -r '.baseRefOid // ""' <<<"$initial")
url=$(jq -r '.url // ""' <<<"$initial")
native_author=$(jq -r '.author.login' <<<"$initial")
labels=$(blocking_labels <<<"$initial")
[ "$state" = "OPEN" ] || not_ready "PR is $state"
[ -n "$head" ] && [ -n "$base_ref" ] && [ -n "$base_sha" ] && [ -n "$url" ] \
  || infra_error "PR response lacks head, base, or URL"

# A durable native auto-merge arm is unsafe for every PR whose native author
# is the fleet's shared author identity. The approval is intentionally valid
# under Phase 3, but the same head can later enter Phase 4 through a base-policy
# advance, retarget, or blocking label; GitHub's head CAS cannot bind those
# mutable facts. Keep self-review scope unchanged and make only the merge a
# one-shot action. This runs before every readiness/error exit and also exposes
# a disarm-only invalidation mode for the approval workflow.
if [ "$native_author" = "$login" ]; then
  if [ "$(jq -r 'if .autoMergeRequest == null then "false" else "true" end' <<<"$initial")" = "true" ]; then
    if ! gh pr merge "$url" --repo "$REPO" --disable-auto --match-head-commit "$head"; then # NO_BARE_GH_WRITE_EXEMPT: the effective token was verified above; this only retracts a shared-author arm
      infra_error "could not disable pre-existing auto-merge on shared-author PR"
    fi
    disarm_readback=$(read_pr) || infra_error "could not verify shared-author auto-merge retraction"
    disarm_head=$(jq -r '.headRefOid // ""' <<<"$disarm_readback")
    [ "$disarm_head" = "$head" ] || infra_error "head changed while disabling shared-author auto-merge"
    if ! jq -e 'has("autoMergeRequest") and .autoMergeRequest == null' >/dev/null 2>&1 <<<"$disarm_readback"; then
      infra_error "shared-author auto-merge retraction did not persist"
    fi
  fi
  if [ "$MODE" = "disarm-only" ]; then
    echo "approval continuation: shared-author auto-merge is disarmed for $REPO#$PR_NUMBER at $head"
    exit 0
  fi
  not_ready "shared-author PR requires a one-shot author merge because native auto-merge cannot bind later Phase 4 transitions"
fi

if [ "$MODE" = "disarm-only" ]; then
  echo "approval continuation: native non-shared PR requires no auto-merge invalidation"
  exit 0
fi

[ "$draft" = "false" ] || not_ready "PR is draft"
[ -z "$labels" ] || not_ready "blocking labels present: $labels"

set +e
CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 \
  bash "$ROOT/scripts/codex-review-check.sh" --approval-readiness-only "$PR_NUMBER" "$REPO"
readiness_rc=$?
set -e
case "$readiness_rc" in
  0) ;;
  1) not_ready "registered approval or current-head CI/annex readiness is not satisfied" ;;
  *) infra_error "approval-readiness predicate returned rc=$readiness_rc" ;;
esac

set +e
bash "$ROOT/scripts/merge-clearance-gate.sh" "$PR_NUMBER" "$REPO"
gate_rc=$?
set -e
case "$gate_rc" in
  0) ;;
  1) not_ready "threshold-aware merge-clearance predicate is not satisfied" ;;
  *) infra_error "threshold-aware merge-clearance predicate returned rc=$gate_rc" ;;
esac

set +e
bash "$ROOT/scripts/review-feedback-accounting.sh" "$PR_NUMBER" "$REPO"
accounting_rc=$?
set -e
case "$accounting_rc" in
  0) ;;
  1) not_ready "review feedback is not fully accounted" ;;
  *) infra_error "review feedback accounting returned rc=$accounting_rc" ;;
esac

set +e
bash "$ROOT/scripts/resolve-pr-threads.sh" "$PR_NUMBER" --repo "$REPO" --list
threads_rc=$?
set -e
case "$threads_rc" in
  0) ;;
  3) not_ready "unresolved review conversations remain" ;;
  *) infra_error "conversation readback returned rc=$threads_rc" ;;
esac

# Enforce the SAME configured required head-check list the initial readiness
# probe used (#1070). Without this, every continuation re-entry --
# workflow_run completions and the scheduled sweep -- decides readiness from
# codex-review-check.sh, which filters CI by BRANCH-PROTECTION requirements.
# The whole premise of the configured list is that the extra check is NOT
# branch-protected, so a repo-lint completion could otherwise arm auto-merge
# before that check even appears. Pinned to $head, which the final re-read
# below confirms has not moved.
set +e
bash "$ROOT/scripts/required-head-checks.sh" --repo "$REPO" --verify --sha "$head"
required_checks_rc=$?
set -e
case "$required_checks_rc" in
  0) ;;
  1) not_ready "configured required head checks are not all green on $head" ;;
  *) infra_error "required head-check verification returned rc=$required_checks_rc" ;;
esac

# Re-read all mutable safety state immediately before arming. The first read
# prevents needless gate work; this read is the authority for the write.
final=$(read_pr) || infra_error "could not re-read PR #$PR_NUMBER"
final_state=$(jq -r '.state // ""' <<<"$final")
final_draft=$(jq -r 'if has("isDraft") then .isDraft else true end' <<<"$final")
final_head=$(jq -r '.headRefOid // ""' <<<"$final")
final_base_ref=$(jq -r '.baseRefName // ""' <<<"$final")
final_base_sha=$(jq -r '.baseRefOid // ""' <<<"$final")
final_labels=$(blocking_labels <<<"$final")
[ "$final_state" = "OPEN" ] || not_ready "PR changed state to $final_state"
[ "$final_draft" = "false" ] || not_ready "PR became draft"
[ "$final_head" = "$head" ] || not_ready "head changed during evaluation"
[ "$final_base_ref" = "$base_ref" ] || not_ready "base ref changed during evaluation"
[ "$final_base_sha" = "$base_sha" ] || not_ready "base branch advanced during evaluation"
[ -z "$final_labels" ] || not_ready "blocking labels appeared: $final_labels"

# #1094: the approval event's pull_request body is an immutable webhook
# snapshot. An `edited` event can change Authoring-Agent while an older
# approval-triggered run is still evaluating, without changing the head SHA.
# Re-fetch live metadata and paginated latest-state reviews here, after every
# expensive predicate and immediately before the write, then classify them
# with the canonical detector against the same governing policy. This shared
# continuation is used by the immediate, completion, and scheduled paths.
set +e
independence_output=$(bash "$ROOT/scripts/workflow/approval-independence-check.sh" \
  --repo "$REPO" --pr "$PR_NUMBER" --head "$final_head" \
  --base-ref "$final_base_ref" --base-sha "$final_base_sha" \
  --merge-login "$login" 2>&1)
independence_rc=$?
set -e
case "$independence_rc" in
  0)
    if ! jq -e '
      type == "object" and
      (.sharedAuthor | type == "boolean") and
      (.requiresExternalReview | type == "boolean")
    ' >/dev/null 2>&1 <<<"$independence_output"; then
      infra_error "live approval-independence predicate returned malformed success output"
    fi
    ;;
  1) not_ready "live approval independence is not satisfied: $independence_output" ;;
  *) infra_error "live approval-independence predicate returned rc=$independence_rc: $independence_output" ;;
esac

if ! gh pr merge "$url" --repo "$REPO" --squash --auto --match-head-commit "$final_head"; then # NO_BARE_GH_WRITE_EXEMPT: the effective token was verified above against the governing author_identity before this exact-head merge write
  infra_error "could not enable exact-head auto-merge"
fi
echo "approval continuation: armed exact-head auto-merge for $REPO#$PR_NUMBER at $final_head"
