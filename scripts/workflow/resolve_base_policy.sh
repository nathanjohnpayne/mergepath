#!/usr/bin/env bash
set -euo pipefail

# scripts/workflow/resolve_base_policy.sh — resolve the review policy that
# GOVERNS a pull request, as a single shared implementation (#769).
#
# WHY THIS EXISTS
#
# The policy that governs a PR is the policy of the branch it TARGETS. Several
# tools decide review requiredness, and each used to read
# `.github/review-policy.yml` from its own trusted default-branch checkout:
# pr-review-policy.yml, agent-review.yml's triage job, merge-clearance-gate.sh,
# and codex-review-check.sh (which the auto-clear workflow also runs). Fixing
# them one at a time produced a partially-threaded policy source — the
# gate-enable switch and threshold from one branch, the reviewer allow-list and
# Phase-4b-substitute rules from another. That is worse than either endpoint,
# so the resolution lives here once and every caller uses it.
#
# WHAT IT PRINTS
#
# A path to the policy file the caller should read. Either the caller's default
# config path (unchanged, no temp file), or a temp file holding the base
# branch's copy. The caller owns cleanup of a temp file; it is created under
# TMPDIR and its path is printed on stdout.
#
# SCOPING — deliberate, and load-bearing
#
# When the PR targets the DEFAULT branch, the base policy IS the default-branch
# policy the caller already has, so this prints the default path and makes NO
# API call. That keeps a contents-API dependency off the path that every
# ordinary PR takes across the fleet: an unconditional fetch would make a
# required merge gate newly dependent on an endpoint it never needed, and a
# transient failure, a rate-limit, or a token without `contents:read` would
# then affect every consumer. The fetch happens only for a non-default base,
# where it is genuinely load-bearing.
#
# FAILURE HANDLING — one rule, applied everywhere
#
#   confirmed 404  the base predates .github/review-policy.yml; there is no
#                  stricter policy to miss, so fall back to the default path.
#   anything else  exit 2. The base policy is UNKNOWN, and silently
#                  substituting the default-branch copy is exactly the bypass
#                  this resolution exists to close. Callers must fail closed.
#
# Usage:
#   resolve_base_policy.sh --repo owner/repo --pr N [--default-config PATH]
#   resolve_base_policy.sh --repo owner/repo --base-ref REF --base-sha SHA \
#                          --default-branch BRANCH [--default-config PATH]
#
# The second form lets a caller that has already fetched PR metadata avoid a
# redundant API round-trip. Exit 2 on usage error or an unreadable base policy.

REPO=""
PR_NUMBER=""
BASE_REF=""
BASE_SHA=""
DEFAULT_BRANCH=""
DEFAULT_CONFIG=".github/review-policy.yml"

usage() {
  cat >&2 <<'EOF'
usage: resolve_base_policy.sh --repo owner/repo (--pr N | --base-ref REF --base-sha SHA --default-branch BRANCH) [--default-config PATH]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)           [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --pr)             [ $# -ge 2 ] || usage; PR_NUMBER="$2"; shift 2 ;;
    --base-ref)       [ $# -ge 2 ] || usage; BASE_REF="$2"; shift 2 ;;
    --base-sha)       [ $# -ge 2 ] || usage; BASE_SHA="$2"; shift 2 ;;
    --default-branch) [ $# -ge 2 ] || usage; DEFAULT_BRANCH="$2"; shift 2 ;;
    --default-config) [ $# -ge 2 ] || usage; DEFAULT_CONFIG="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *) echo "resolve_base_policy.sh: unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$REPO" ] || usage
command -v gh >/dev/null 2>&1 || { echo "resolve_base_policy.sh: gh is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "resolve_base_policy.sh: jq is required" >&2; exit 2; }

# Fetch PR metadata only when the caller did not supply it.
if [ -z "$BASE_REF" ] || [ -z "$BASE_SHA" ] || [ -z "$DEFAULT_BRANCH" ]; then
  [ -n "$PR_NUMBER" ] || usage
  [[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "resolve_base_policy.sh: --pr must be an integer" >&2; exit 2; }
  # Keep stdout and stderr SEPARATE. Merging them (2>&1) would let a gh
  # warning on an otherwise-successful call land inside the JSON, and inside
  # the POLICY CONTENT on the fetch below — the #715/#716 failure class, which
  # is why this repo already has gh_api_capture elsewhere.
  pr_err=$(mktemp "${TMPDIR:-/tmp}/resolve-policy-pr-err.XXXXXX")
  set +e
  pr_json=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>"$pr_err")
  pr_rc=$?
  set -e
  pr_msg=$(cat "$pr_err" 2>/dev/null || true)
  rm -f "$pr_err"
  if [ "$pr_rc" -ne 0 ]; then
    # Could not determine the base at all. See the asymmetry note below: an
    # UNKNOWN base is not evidence of a non-default one, so fall back rather
    # than manufacture a blocking failure in every caller.
    echo "resolve_base_policy.sh: could not fetch PR metadata for $REPO#$PR_NUMBER ($pr_msg); assuming the default-branch policy governs" >&2
    printf '%s\n' "$DEFAULT_CONFIG"
    exit 0
  fi
  BASE_REF=$(printf '%s' "$pr_json" | jq -r '.base.ref // ""')
  BASE_SHA=$(printf '%s' "$pr_json" | jq -r '.base.sha // ""')
  DEFAULT_BRANCH=$(printf '%s' "$pr_json" | jq -r '.base.repo.default_branch // ""')
fi

# ASYMMETRY, deliberate: we fail closed only when we KNOW the governing policy
# is one we cannot read — a positively-identified non-default base whose
# review-policy.yml does not come back. We do NOT fail closed merely because
# the base could not be determined.
#
# The difference matters because this resolver runs inside codex-review-check.sh,
# which the merge gate (twice), the auto-clear workflow, and direct invocations
# all use. Turning "metadata unavailable" into a hard error would let a
# transient API failure block merges across the fleet — the same failure mode
# that broke five tests when an earlier draft fetched unconditionally. It is
# also not an exploitable downgrade: nobody can choose to make their own PR
# metadata unreadable, and callers that DO hold the metadata (merge-clearance-gate.sh
# passes --base-ref/--base-sha/--default-branch) get the strict path.
if [ -z "$BASE_REF" ] || [ -z "$DEFAULT_BRANCH" ]; then
  echo "resolve_base_policy.sh: base ref / default branch undetermined for $REPO; assuming the default-branch policy governs" >&2
  printf '%s\n' "$DEFAULT_CONFIG"
  exit 0
fi

# Default base: the caller's config already IS the governing policy.
if [ "$BASE_REF" = "$DEFAULT_BRANCH" ]; then
  printf '%s\n' "$DEFAULT_CONFIG"
  exit 0
fi

[ -n "$BASE_SHA" ] || { echo "resolve_base_policy.sh: non-default base $BASE_REF has no base sha" >&2; exit 2; }

# Separate streams: stdout is the raw policy FILE, so a stderr warning merged
# into it would be written into the temp policy verbatim and silently corrupt
# every threshold/path/reviewer decision made from it.
policy_err=$(mktemp "${TMPDIR:-/tmp}/resolve-policy-err.XXXXXX")
set +e
base_policy=$(gh api "repos/$REPO/contents/.github/review-policy.yml?ref=$BASE_SHA" \
  -H "Accept: application/vnd.github.raw" 2>"$policy_err")
policy_rc=$?
set -e
policy_msg=$(cat "$policy_err" 2>/dev/null || true)
rm -f "$policy_err"

if [ "$policy_rc" -eq 0 ] && [ -n "$base_policy" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/base-review-policy.XXXXXX")
  printf '%s\n' "$base_policy" > "$tmp"
  printf '%s\n' "$tmp"
  exit 0
fi

if printf '%s' "$policy_msg" | grep -qiE '(^|[^0-9])404([^0-9]|$)|not found'; then
  # Base predates the policy file — nothing stricter can be missed.
  printf '%s\n' "$DEFAULT_CONFIG"
  exit 0
fi

echo "resolve_base_policy.sh: could not read .github/review-policy.yml from non-default base $BASE_REF@$BASE_SHA (rc=$policy_rc): $policy_msg" >&2
exit 2
