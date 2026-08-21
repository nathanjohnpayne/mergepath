#!/usr/bin/env bash
set -euo pipefail

# scripts/workflow/load_review_config.sh — emit agent-review.yml's
# `load-config` job outputs from the review policy that GOVERNS the pull
# request, not from whichever copy happens to be in the checkout (#788).
#
# WHY THIS EXISTS
#
# `load-config` exports four values — threshold, protected paths,
# available_reviewers, author_identity — and they feed decisions that other
# tools re-derive from the BASE policy:
#
#   reviewers        -> the `assign` job's reviewer lookup, AND the
#                       auto-merge-on-approval registered-reviewer gate, which
#                       mirrors scripts/codex-review-check.sh gate (b) and the
#                       required merge-clearance-gate.
#   author_identity  -> the `assign` job's author check, AND the identity the
#                       auto-merge job requires AUTHOR_MERGE_TOKEN to resolve
#                       to before it will call `gh pr merge` at all. That step
#                       parsed the value out of its own unpinned checkout until
#                       #788's second half moved it onto this output.
#   threshold/paths  -> the `triage` job's preliminary requires-review calc.
#
# scripts/merge-clearance-gate.sh and scripts/codex-review-check.sh already
# read the base policy, and #769 moved the `triage` job onto it too. The
# `load-config` step was the one surface left reading its own checkout, so on a
# PR targeting a non-default branch whose policy names different identities the
# pipeline could assign a reviewer who can never satisfy the base-policy gates,
# or arm auto-merge from an identity the base policy does not permit. That is
# the partially-threaded policy source #768/#769 set out to remove — the fix
# here is the one those issues established, not a new mechanism: resolve once
# through the shared resolver, then parse everything from what it returns.
#
# The inline step also read whatever `actions/checkout` had materialized, which
# on a `pull_request` event is `refs/pull/N/merge` — the PR's OWN policy file,
# including any modification the PR makes to it — and on a `pull_request_review`
# event is the default branch. Two different policies for the same PR depending
# on which event woke the job. Both are wrong for the same reason: the governing
# policy is the policy of the branch the PR TARGETS.
#
# SCOPING — deliberate, and load-bearing
#
# Resolution goes through scripts/workflow/resolve_base_policy.sh, whose
# default-base short circuit makes NO API call. That property is why it was
# written that way (#769) and it must survive here: `load-config` runs on every
# push to every open PR across the fleet, so an unconditional contents fetch
# would put a new API dependency on the busiest path in the pipeline. Callers
# must therefore pass --base-ref/--base-sha/--default-branch from the event
# payload rather than the `--pr` form, which would fetch PR metadata even for a
# default-base PR.
#
# FAILURE HANDLING
#
# A resolver failure means the governing policy is UNKNOWN. This script then
# emits FAIL-CLOSED outputs and exits 0:
#
#   reviewers=[]        no account matches the reviewer allow-list, so `assign`
#                       assigns nobody and the auto-merge arming gate refuses
#                       every approval (both already default to [] and treat an
#                       empty list as "no match" — this feeds them the same).
#   threshold=0         every PR is at or over threshold, so `triage`'s
#                       preliminary calculation requires external review.
#   paths=[]            no path claims to be unprotected on evidence we do not
#                       have; `triage` fails closed on its own resolver failure
#                       moments later and skips the fingerprint helper entirely.
#   author_identity=    unproven, so left empty.
#
# A policy that RESOLVES but names no top-level `author_identity` is the same
# unproven state by a different route, and is emitted the same way: empty. See
# the note on the final `emit author_identity` below.
#
# Exiting 0 is the point: `triage` declares `needs: [load-config]` without
# `always()`, so a hard failure here SKIPS triage, and a skipped labeling job
# is fail-OPEN (#59's SKIPPED-as-SUCCESS class). Staying green with fail-closed
# values keeps every downstream guard armed.
#
# Usage:
#   load_review_config.sh --repo owner/repo --base-ref REF --base-sha SHA \
#                         --default-branch BRANCH [--default-config PATH] \
#                         [--output FILE]
#
# --output defaults to $GITHUB_OUTPUT. Exit 2 on usage error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCALAR_HELPER="$SCRIPT_DIR/../lib/review-policy-scalar.sh"

REPO=""
BASE_REF=""
BASE_SHA=""
DEFAULT_BRANCH=""
DEFAULT_CONFIG=".github/review-policy.yml"
OUTPUT="${GITHUB_OUTPUT:-}"

usage() {
  cat >&2 <<'EOF'
usage: load_review_config.sh --repo owner/repo --base-ref REF --base-sha SHA --default-branch BRANCH [--default-config PATH] [--output FILE]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)           [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --base-ref)       [ $# -ge 2 ] || usage; BASE_REF="$2"; shift 2 ;;
    --base-sha)       [ $# -ge 2 ] || usage; BASE_SHA="$2"; shift 2 ;;
    --default-branch) [ $# -ge 2 ] || usage; DEFAULT_BRANCH="$2"; shift 2 ;;
    --default-config) [ $# -ge 2 ] || usage; DEFAULT_CONFIG="$2"; shift 2 ;;
    --output)         [ $# -ge 2 ] || usage; OUTPUT="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *) echo "load_review_config.sh: unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$REPO" ] || usage
[ -n "$BASE_REF" ] || usage
[ -n "$DEFAULT_BRANCH" ] || usage
[ -n "$OUTPUT" ] || {
  echo "load_review_config.sh: no --output given and GITHUB_OUTPUT is unset" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || { echo "load_review_config.sh: jq is required" >&2; exit 2; }

emit() { printf '%s=%s\n' "$1" "$2" >> "$OUTPUT"; }

if [ ! -f "$SCALAR_HELPER" ]; then
  echo "::warning::$SCALAR_HELPER is not available in this trusted checkout; emitting fail-closed load-config outputs — empty reviewer allow-list, threshold 0."
  emit threshold "0"
  emit paths "[]"
  emit reviewers "[]"
  emit author_identity ""
  exit 0
fi
# shellcheck source=../lib/review-policy-scalar.sh
source "$SCALAR_HELPER"

# Read one TOP-LEVEL scalar out of a policy file.
#
# This is the parser `.github/workflows/agent-review.yml`'s auto-merge job used
# to run inline against its own checkout before #788 routed the identity
# through this script's output — byte-for-byte, so the value the
# AUTHOR_MERGE_TOKEN check now compares is the value it computed for itself
# then, and the switch of SOURCE does not smuggle in a change of SYNTAX.
# `scripts/ci/check_workflow_parsers` pins these semantics case by case
# (bare / "double-quoted" / 'single-quoted').
#
# Three properties are load-bearing, and the older `grep key: | awk '{print
# $2}'` form had none of them:
#
#   anchored     the key must start at column 0, so a nested `author_identity:`
#                under another block — or the same word inside a comment — is
#                not mistaken for the top-level setting.
#   unquoted     `author_identity: "nathanjohnpayne"` yields nathanjohnpayne,
#                not "nathanjohnpayne". A quoted value compared verbatim
#                against `gh api user --jq .login` never matches, which would
#                turn a legal YAML spelling into a permanent merge refusal.
#   first-wins   `exit` after the first match. A repeated scalar key would
#                otherwise print twice, and a GITHUB_OUTPUT entry is a single
#                `key=value` LINE — Actions parses the second one as its own
#                output entry. That shape became reachable when the policy
#                could be FETCHED from another branch rather than always being
#                the checked-out file.
#
# KNOWN LIMIT — tracked in #978, deliberately not fixed here. These are a LINE
# parser's semantics, not YAML's, and on a malformed or adversarial policy the
# two diverge: an unterminated quote is accepted as a value, and a repeated key
# resolves first-wins where YAML consumers resolve last-wins or reject the
# document. Both require malformed protected base-policy content. #978 carries
# the design of the parsing contract, including whether this scalar should come
# from a real YAML parser at all.
# Resolve the governing policy. stderr is left attached to the caller so the
# resolver's diagnostics land in the job log; only stdout is captured, because
# stdout is the policy PATH and merging the streams would turn a warning into a
# garbage filename (the #715/#716 failure class the resolver documents).
set +e
CONFIG=$(bash "$SCRIPT_DIR/resolve_base_policy.sh" \
  --repo "$REPO" \
  --base-ref "$BASE_REF" \
  --base-sha "$BASE_SHA" \
  --default-branch "$DEFAULT_BRANCH" \
  --default-config "$DEFAULT_CONFIG")
resolve_rc=$?
set -e

if [ "$resolve_rc" -ne 0 ] || [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
  echo "::warning::Could not resolve the review policy governing base '$BASE_REF' (rc=$resolve_rc); emitting fail-closed load-config outputs — empty reviewer allow-list, threshold 0 — rather than exporting identities from a policy that may not govern this PR (#788)."
  emit threshold "0"
  emit paths "[]"
  emit reviewers "[]"
  emit author_identity ""
  exit 0
fi

if [ "$CONFIG" = "$DEFAULT_CONFIG" ]; then
  echo "Governing review policy: $CONFIG (base '$BASE_REF' is the default branch, or predates the policy file)"
else
  echo "Governing review policy: $CONFIG (fetched from non-default base '$BASE_REF' at $BASE_SHA)"
fi

# The list extractions below are byte-for-byte the ones the inline
# `load-config` step used, so a default-base PR — every PR in the fleet today —
# produces identical outputs. Only the FILE they read changed.
#
# `parse_policy_list.sh` rather than an inline `awk '/^key:/,/^[^ ]/'` range
# parser: the range-start pattern also matches the range-end condition, so the
# naive form silently dropped every list entry and left `paths`/`reviewers`
# permanently `[]` (#54, documented in #57).
#
# `jq -c` (compact) is required: multi-line JSON cannot be written through the
# `key=value` GITHUB_OUTPUT format (#30/#58).
#
# The scalars go through shared `review_policy_scalar` rather than `grep key: | awk
# '{print $2}'`. A missing key is not an error there either — awk simply prints
# nothing, so a policy without the key yields the empty value the callers
# already handle, without a `|| true` guard against `pipefail` aborting the
# step (a failed load-config SKIPS triage — see FAILURE HANDLING above).
PATHS=$(bash "$SCRIPT_DIR/parse_policy_list.sh" "$CONFIG" external_review_paths \
  | jq -R -s -c 'split("\n") | map(select(length > 0))')
REVIEWERS=$(bash "$SCRIPT_DIR/parse_policy_list.sh" "$CONFIG" available_reviewers \
  | jq -R -s -c 'split("\n") | map(select(length > 0))')
THRESHOLD=$(review_policy_scalar "$CONFIG" external_review_threshold)
AUTHOR=$(review_policy_scalar "$CONFIG" author_identity)

# Every emitted value is a single GITHUB_OUTPUT line: `review_policy_scalar` stops at
# the first match (see its first-wins note), and PATHS/REVIEWERS are single-line
# by construction because `jq -c` compacts them.

# The resolver's contract: a non-default base returns a TEMP file and the
# caller owns cleanup. The default-config path is the caller's own checkout and
# must never be deleted.
[ "$CONFIG" = "$DEFAULT_CONFIG" ] || rm -f "$CONFIG"

emit threshold "$THRESHOLD"
emit paths "$PATHS"
emit reviewers "$REVIEWERS"

# `$AUTHOR` verbatim, with NO `:-nathanjohnpayne` fallback. A governing policy
# that is readable but carries no top-level `author_identity` proves no identity
# either — the same state the resolver-failure branch above emits empty — and it
# is the more reachable of the two, because a policy can simply omit the key (or
# nest it under a block, which `review_policy_scalar` correctly declines to match)
# without anything failing. Substituting a hard-coded login here would hand the
# auto-merge step a non-empty EXPECTED_AUTHOR, skip its `[ -z ]` fail-closed
# branch, and let AUTHOR_MERGE_TOKEN merge under an identity the governing
# policy never named — the substitution #768/#769/#788 exist to prevent, moved
# one file upstream rather than removed. The `assign` job keeps its own
# `AUTHOR_IDENTITY || 'nathanjohnpayne'` default in JS, so dropping the default
# here tightens the merge gate and leaves reviewer assignment unchanged.
emit author_identity "$AUTHOR"
