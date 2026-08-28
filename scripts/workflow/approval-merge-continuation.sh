#!/usr/bin/env bash
# Re-enter merge readiness from a trusted workflow completion event.

set -euo pipefail

usage() {
  echo "usage: approval-merge-continuation.sh [--retract-unsafe-only] <PR#> [owner/repo]" >&2
  exit 2
}

MODE="continue"
case "${1:-}" in
  --retract-unsafe-only|--disarm-shared-author-only)
    # APPROVAL_PROTECTIVE_RETRACTION_V2. The old spelling remains accepted for
    # one propagation window; both names select the same disable-only mode.
    MODE="retract-only"
    shift
    ;;
esac
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
PR_NUMBER="$1"
REPO="${2:-${GITHUB_REPOSITORY:-}}"
case "$PR_NUMBER" in *[!0-9]*|'') usage ;; esac
[ -n "$REPO" ] || usage

ROOT="${MERGEPATH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../lib/review-policy-scalar.sh
source "$ROOT/scripts/lib/review-policy-scalar.sh"

RETRACT_ON_EXIT=0

retract_latest_arm_for_exit() {
  local reason="$1"
  if [ -n "${MERGEPATH_PROTECTIVE_TOKEN:-}" ]; then
    GH_TOKEN="$MERGEPATH_PROTECTIVE_TOKEN" retract_latest_arm "$reason"
  else
    retract_latest_arm "$reason"
  fi
}

cleanup_on_exit() {
  local exit_rc cleanup_rc
  exit_rc="$1"
  cleanup_rc=0
  trap - EXIT
  if [ "$RETRACT_ON_EXIT" = "1" ]; then
    if ! retract_latest_arm_for_exit "continuation exit"; then
      echo "approval continuation: ERROR — could not retract the latest arm before exit" >&2
      cleanup_rc=3
    fi
  fi
  if [ "$cleanup_rc" -ne 0 ]; then
    exit "$cleanup_rc"
  fi
  exit "$exit_rc"
}
trap 'cleanup_on_exit "$?"' EXIT

not_ready() {
  echo "approval continuation: not ready — $*"
  exit 4
}

infra_error() {
  echo "approval continuation: ERROR — $*" >&2
  exit 3
}

if [ "$MODE" = "continue" ]; then
  [ "${MERGEPATH_PROTECTIVE_RETRACTION_DONE:-}" = "1" ] || \
    infra_error "normal continuation requires a successful workflow-token protective retraction first"
  [ -n "${MERGEPATH_PROTECTIVE_TOKEN:-}" ] || \
    infra_error "normal continuation requires a separate workflow token for exit cleanup"
  # Install cleanup before the first live read. The token is available solely
  # for disable-only cleanup and is never merge authorization.
  RETRACT_ON_EXIT=1
fi

read_pr() {
  gh pr view "$PR_NUMBER" --repo "$REPO" \
    --json state,isDraft,headRefOid,baseRefName,baseRefOid,url,body,labels,author,autoMergeRequest
}

valid_pr_shape() {
  jq -e '
    type == "object" and
    (.state | type == "string" and length > 0) and
    (.isDraft | type == "boolean") and
    (.author.login | type == "string" and length > 0) and
    (.url | type == "string" and length > 0) and
    (.headRefOid | type == "string" and length > 0) and
    (.baseRefName | type == "string" and length > 0) and
    (.baseRefOid | type == "string" and length > 0) and
    ((.body == null) or (.body | type == "string")) and
    (.labels | type == "array") and
    all(.labels[]; (.name | type == "string" and length > 0)) and
    has("autoMergeRequest") and
    ((.autoMergeRequest == null) or (.autoMergeRequest | type == "object"))
  ' >/dev/null 2>&1 <<<"$1"
}

readiness_snapshot_signature() {
  jq -c '{
    state,
    draft: .isDraft,
    head: .headRefOid,
    baseRef: .baseRefName,
    baseSha: .baseRefOid,
    author: .author.login,
    body: (.body // ""),
    labels: ([.labels[]?.name] | sort)
  }' <<<"$1"
}

policy_snapshot_signature() {
  jq -c '{
    head: .headRefOid,
    baseRef: .baseRefName,
    baseSha: .baseRefOid,
    author: .author.login
  }' <<<"$1"
}

retract_snapshot_arm() {
  local snapshot="$1" reason="$2" target_url target_head target_base_ref
  local target_base_sha target_author readback readback_head readback_base_ref
  local readback_base_sha readback_author
  valid_pr_shape "$snapshot" || {
    echo "approval continuation: $reason snapshot is malformed" >&2
    return 1
  }
  if jq -e '.autoMergeRequest == null' >/dev/null 2>&1 <<<"$snapshot"; then
    return 0
  fi
  target_url=$(jq -r '.url' <<<"$snapshot")
  target_head=$(jq -r '.headRefOid' <<<"$snapshot")
  target_base_ref=$(jq -r '.baseRefName' <<<"$snapshot")
  target_base_sha=$(jq -r '.baseRefOid' <<<"$snapshot")
  target_author=$(jq -r '.author.login' <<<"$snapshot")
  # The dedicated Dependabot workflow owns its durable arm. Keep this exact
  # native-login boundary at the mutation site as well as at normal entry:
  # EXIT cleanup can reach here after the first PR read failed, before the
  # top-level author classification ever ran.
  if [ "$target_author" = "dependabot[bot]" ]; then
    echo "approval continuation: $reason snapshot belongs to Dependabot's dedicated auto-merge lane; leaving its durable request unchanged"
    return 0
  fi
  if ! gh pr merge "$target_url" --repo "$REPO" --disable-auto; then # NO_BARE_GH_WRITE_EXEMPT: disable-only cleanup is intentionally monotone across head drift; tuple readback below fails closed
    echo "approval continuation: could not disable $reason auto-merge request" >&2
    return 1
  fi
  readback=$(read_pr) || {
    echo "approval continuation: could not verify $reason auto-merge retraction" >&2
    return 1
  }
  valid_pr_shape "$readback" || {
    echo "approval continuation: $reason retraction readback is malformed" >&2
    return 1
  }
  readback_head=$(jq -r '.headRefOid' <<<"$readback")
  readback_base_ref=$(jq -r '.baseRefName' <<<"$readback")
  readback_base_sha=$(jq -r '.baseRefOid' <<<"$readback")
  readback_author=$(jq -r '.author.login' <<<"$readback")
  [ "$readback_head" = "$target_head" ] || return 1
  [ "$readback_base_ref" = "$target_base_ref" ] || return 1
  [ "$readback_base_sha" = "$target_base_sha" ] || return 1
  [ "$readback_author" = "$target_author" ] || return 1
  jq -e '.autoMergeRequest == null' >/dev/null 2>&1 <<<"$readback" || return 1
  echo "approval continuation: $reason auto-merge retraction verified"
}

retract_latest_arm() {
  local reason="$1" latest
  latest=$(read_pr) || {
    echo "approval continuation: could not read latest PR state for $reason" >&2
    return 1
  }
  retract_snapshot_arm "$latest" "$reason"
}

initial=$(read_pr) || infra_error "could not read PR #$PR_NUMBER"
valid_pr_shape "$initial" || infra_error "PR response lacks valid safety or auto-merge metadata"
state=$(jq -r '.state // ""' <<<"$initial")
draft=$(jq -r 'if has("isDraft") then .isDraft else true end' <<<"$initial")
head=$(jq -r '.headRefOid // ""' <<<"$initial")
base_ref=$(jq -r '.baseRefName // ""' <<<"$initial")
base_sha=$(jq -r '.baseRefOid // ""' <<<"$initial")
url=$(jq -r '.url // ""' <<<"$initial")
native_author=$(jq -r '.author.login' <<<"$initial")
[ -n "$head" ] && [ -n "$url" ] || infra_error "PR response lacks head or URL"
arm_enabled=$(jq -r 'if .autoMergeRequest == null then "false" else "true" end' <<<"$initial")

# Dependabot owns a separate, purpose-built durable auto-merge lane. The
# workflow-run and scheduled approval sweeps enumerate every approved PR, so
# this helper is the authoritative author-class boundary: neither protective
# mode nor a mistakenly-entered normal continuation may disable Dependabot's
# request. The login comes from the live PR object and cannot be supplied by
# PR-authored content.
if [ "$native_author" = "dependabot[bot]" ]; then
  RETRACT_ON_EXIT=0
  echo "approval continuation: Dependabot PR is owned by the dedicated auto-merge lane; leaving its durable request unchanged"
  exit 0
fi

# Resolve the policy that governs this exact PR base before classifying its
# shared author. The default-branch copy is not an identity authority for a
# non-default base (#788). Retraction-only mode is the bounded workflow-token
# safety pass: if policy is unreadable and an arm exists, it retracts that
# unclassified arm rather than guessing that it belongs to an external author.
default_branch_err=$(mktemp "${TMPDIR:-/tmp}/approval-continuation-default-branch.XXXXXX")
set +e
default_branch=$(gh api "repos/$REPO" --jq .default_branch 2>"$default_branch_err")
default_branch_rc=$?
set -e
default_branch_msg=$(cat "$default_branch_err" 2>/dev/null || true)
rm -f "$default_branch_err"
if [ "$default_branch_rc" -ne 0 ] || [ -z "$default_branch" ]; then
  echo "approval continuation: could not resolve repository default branch; governing policy is unclassified (${default_branch_msg:-empty response})" >&2
fi

set +e
if [ "$default_branch_rc" -eq 0 ] && [ -n "$default_branch" ]; then
  policy=$(bash "$ROOT/scripts/workflow/resolve_base_policy.sh" \
    --repo "$REPO" --base-ref "$base_ref" --base-sha "$base_sha" \
    --default-branch "$default_branch" --materialize-default)
  policy_rc=$?
else
  policy=""
  policy_rc=2
fi
set -e
expected_author=""
if [ "$policy_rc" -eq 0 ] && [ -f "$policy" ]; then
  expected_author=$(review_policy_scalar "$policy" author_identity)
fi
if [ -n "${policy:-}" ] && [ "$policy" != "$ROOT/.github/review-policy.yml" ]; then
  rm -f "$policy"
fi

if [ "$MODE" = "retract-only" ]; then
  # Bracket every policy classification, including an initially unarmed PR.
  # Otherwise another run can add an arm while policy materializes and the
  # protective-only path (used when AUTHOR_MERGE_TOKEN is absent) returns
  # without ever observing it.
  set +e
  protection_snapshot=$(read_pr)
  protection_rc=$?
  set -e
  if [ "$protection_rc" -ne 0 ] || ! valid_pr_shape "$protection_snapshot"; then
    if [ "$arm_enabled" != "true" ]; then
      infra_error "could not bracket the unarmed PR after policy classification"
    fi
    echo "approval continuation: could not stabilize PR state after policy classification; retracting the known arm as unclassified" >&2
    protection_snapshot="$initial"
  elif [ "$(policy_snapshot_signature "$protection_snapshot")" != "$(policy_snapshot_signature "$initial")" ]; then
    echo "approval continuation: PR head/base/author changed during policy classification; treating the latest armed state as unclassified"
  fi

  if jq -e '.autoMergeRequest == null' >/dev/null 2>&1 <<<"$protection_snapshot"; then
    echo "approval continuation: no auto-merge request requires protective retraction"
    exit 0
  fi
  retract_snapshot_arm "$protection_snapshot" "durable or unclassified" || \
    infra_error "could not retract and verify the protective auto-merge request"
  exit 0
fi

[ "$policy_rc" -eq 0 ] || infra_error "could not resolve the governing base policy"
[ -n "$expected_author" ] || infra_error "governing base policy names no author_identity"

identity_err=$(mktemp "${TMPDIR:-/tmp}/approval-continuation-identity.XXXXXX")
set +e
login=$(gh api user --jq .login 2>"$identity_err")
identity_rc=$?
set -e
identity_msg=$(cat "$identity_err" 2>/dev/null || true)
rm -f "$identity_err"
[ "$identity_rc" -eq 0 ] || infra_error "could not verify merge token identity: ${identity_msg:-unknown API error}"
[ -n "$login" ] || infra_error "merge token identity is empty"
[ "$login" = "$expected_author" ] || infra_error "merge token resolves to $login, expected $expected_author"

# Re-read after the exact-base policy fetch in normal mode too. The preceding
# workflow-token invocation is a separate process; an arm can appear between
# it and this author-token pass, or the base can move while this pass resolves
# policy. A mixed tuple is unclassified and must be disarmed before deferring.
normal_snapshot=$(read_pr) || infra_error "could not bracket normal policy classification"
valid_pr_shape "$normal_snapshot" || infra_error "normal policy readback is malformed"
if [ "$(policy_snapshot_signature "$normal_snapshot")" != "$(policy_snapshot_signature "$initial")" ]; then
  retract_snapshot_arm "$normal_snapshot" "policy-drift" || \
    infra_error "could not retract a policy-drift auto-merge request"
  not_ready "PR head/base/author changed during policy classification"
fi

initial="$normal_snapshot"
state=$(jq -r '.state // ""' <<<"$initial")
draft=$(jq -r 'if has("isDraft") then .isDraft else true end' <<<"$initial")
head=$(jq -r '.headRefOid' <<<"$initial")
base_ref=$(jq -r '.baseRefName' <<<"$initial")
base_sha=$(jq -r '.baseRefOid' <<<"$initial")
url=$(jq -r '.url' <<<"$initial")
native_author=$(jq -r '.author.login' <<<"$initial")

# Reclaim every pre-existing arm before expensive readiness work, even for a
# proven native non-shared author. A later not-ready exit then cannot strand an
# arm whose base-policy classification has gone stale. A fully clean run stays
# unarmed and reports readiness for an ordinary one-shot author merge.
retract_snapshot_arm "$initial" "pre-evaluation" || \
  infra_error "could not retract and verify the pre-evaluation auto-merge request"
initial=$(jq -c '.autoMergeRequest = null' <<<"$initial")

# Every subsequent not-ready exit performs a final live protective pass. This
# includes the shared-author stop immediately below: an older overlapping run
# can create a new arm after the pre-evaluation readback during a first rollout.
# The live pass also catches arms created while this invocation is inside an
# expensive gate.
RETRACT_ON_EXIT=1

# A durable native auto-merge arm is unsafe for every PR whose native author
# is the fleet's shared author identity. The approval remains valid under Phase
# 3, but the merge is a one-shot action after every live gate is clean.
if [ "$native_author" = "$expected_author" ]; then
  not_ready "shared-author PR requires a one-shot author merge because native auto-merge cannot bind later Phase 4 transitions"
fi

# shellcheck source=../lib/blocking-labels.sh
source "$ROOT/scripts/lib/blocking-labels.sh"

blocking_labels() {
  jq -r '.labels[]?.name' | mergepath_blocking_labels_csv
}

labels=$(blocking_labels <<<"$initial")
[ "$state" = "OPEN" ] || not_ready "PR is $state"
[ -n "$base_ref" ] && [ -n "$base_sha" ] || infra_error "PR response lacks base metadata"
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
# Prefer ACCOUNTING_GH_TOKEN when the caller sets it (#1101, CodeRabbit on
# PR #1106): every caller of this script runs it under GH_TOKEN=
# AUTHOR_MERGE_TOKEN, an external PAT secret this repo's workflow
# `permissions:` blocks cannot grant Code Scanning alerts access to.
# Accounting is read-only and needs no author attribution, so it runs
# under GITHUB_TOKEN (scoped by the calling workflow's own permissions)
# instead when that's supplied; falls back to the ambient GH_TOKEN
# otherwise, unchanged for CLI/test callers that don't set it.
GH_TOKEN="${ACCOUNTING_GH_TOKEN:-${GH_TOKEN:-}}" \
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
# branch-protected, so a repo-lint completion could otherwise report readiness
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

# Re-read all mutable safety state after the expensive readiness gates. The
# first read prevents needless gate work; this read anchors independence.
final=$(read_pr) || infra_error "could not re-read PR #$PR_NUMBER"
valid_pr_shape "$final" || infra_error "final PR readback is malformed"
final_state=$(jq -r '.state // ""' <<<"$final")
final_draft=$(jq -r 'if has("isDraft") then .isDraft else true end' <<<"$final")
final_head=$(jq -r '.headRefOid // ""' <<<"$final")
final_base_ref=$(jq -r '.baseRefName // ""' <<<"$final")
final_base_sha=$(jq -r '.baseRefOid // ""' <<<"$final")
final_labels=$(blocking_labels <<<"$final")
[ "$final_state" = "OPEN" ] || not_ready "PR changed state to $final_state"
[ "$final_draft" = "false" ] || not_ready "PR became draft"
if [ "$final_head" != "$head" ] || [ "$final_base_ref" != "$base_ref" ] ||
  [ "$final_base_sha" != "$base_sha" ]; then
  retract_snapshot_arm "$final" "final-snapshot-drift" || \
    infra_error "could not retract an arm from the drifted final snapshot"
  # The exact drifted snapshot was retracted and read back above. The exit trap
  # performs one more workflow-token pass so a newer overlapping arm cannot
  # appear between this readback and process exit.
  not_ready "head or base changed during evaluation"
fi
[ -z "$final_labels" ] || not_ready "blocking labels appeared: $final_labels"

# #1094: the approval event's pull_request body is an immutable webhook
# snapshot. An `edited` event can change Authoring-Agent while an older
# approval-triggered run is still evaluating, without changing the head SHA.
# Re-fetch live metadata and paginated latest-state reviews here, after every
# expensive predicate and immediately before the final readiness boundary,
# then classify them with the canonical detector against the same governing
# policy. This shared continuation is used by the immediate, completion, and
# scheduled paths.
independence_err=$(mktemp "${TMPDIR:-/tmp}/approval-continuation-independence.XXXXXX") \
  || infra_error "could not allocate approval-independence diagnostic capture"
set +e
independence_output=$(bash "$ROOT/scripts/workflow/approval-independence-check.sh" \
  --repo "$REPO" --pr "$PR_NUMBER" --head "$final_head" \
  --base-ref "$final_base_ref" --base-sha "$final_base_sha" \
  --merge-login "$login" 2>"$independence_err")
independence_rc=$?
set -e
independence_msg=$(cat "$independence_err" 2>/dev/null || true)
rm -f "$independence_err"
case "$independence_rc" in
  0)
    if ! jq -e '
      type == "object" and
      (.sharedAuthor | type == "boolean") and
      (.requiresExternalReview | type == "boolean")
    ' >/dev/null 2>&1 <<<"$independence_output"; then
      infra_error "live approval-independence predicate returned malformed success output${independence_msg:+: $independence_msg}"
    fi
    ;;
  1) not_ready "live approval independence is not satisfied: ${independence_msg:-$independence_output}" ;;
  *) infra_error "live approval-independence predicate returned rc=$independence_rc: ${independence_msg:-$independence_output}" ;;
esac

# GitHub exposes a head precondition for merge writes but no base-SHA
# precondition. Re-read after independence so observed drift defers, then leave
# the PR unarmed: a durable request could execute immediately after an
# unobservable same-head base-policy transition. Merge-queue ownership of an
# immutable merge-group tuple is tracked in #1058; until then the final merge is
# an ordinary one-shot author action after this readiness result.
post_independence=$(read_pr) || infra_error "could not read PR after approval-independence evaluation"
valid_pr_shape "$post_independence" || infra_error "post-independence PR readback is malformed"
if [ "$(readiness_snapshot_signature "$post_independence")" != "$(readiness_snapshot_signature "$final")" ]; then
  not_ready "mutable PR metadata changed after approval-independence evaluation"
fi
GH_TOKEN="$MERGEPATH_PROTECTIVE_TOKEN" \
  retract_snapshot_arm "$post_independence" "post-independence" || \
  infra_error "could not retract and verify a post-independence auto-merge request"
echo "approval continuation: merge-ready at $final_head; durable auto-merge remains disabled pending the #1058 merge-group boundary"
