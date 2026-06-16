#!/usr/bin/env bash
# scripts/audit-propagation-lane.sh
#
# Regression net for the propagation PR review lane (#434, Option 3).
#
# The lane defaults ON in the synced pr-review-policy.yml workflow, but
# three per-consumer preconditions can still silently disable it — and
# a file-level drift audit alone can't see them together:
#
#   1. the consumer's live default branch carries the default-ON lane
#      code in .github/workflows/pr-review-policy.yml (a consumer that
#      has not received the #434 sync still requires an explicit
#      propagation_prs.enabled: true it does not have);
#   2. the consumer's .github/review-policy.yml does not explicitly set
#      propagation_prs.enabled: false (the intentional opt-out — valid,
#      but it must be VISIBLE, not a surprise at the next sync wave);
#   3. the consumer's .github/review-policy.yml has an author_identity
#      (the lane's PR-author fingerprint check requires it).
#
# For each consumer in .mergepath-sync.yml, this script reads BOTH
# files from the consumer's live default branch via the GitHub contents
# API and reports lane status. Any consumer where the lane would NOT
# fire fails the audit.
#
# Usage:
#   scripts/audit-propagation-lane.sh                 # all consumers
#   scripts/audit-propagation-lane.sh --repos r1,r2   # subset
#   scripts/audit-propagation-lane.sh --check-files <review-policy.yml> <pr-review-policy.yml>
#       Offline single-pair mode for tests: prints the same status line
#       a live consumer would get, using local files instead of the API.
#
# Exit codes:
#   0  lane fires on every audited consumer (explicit opt-outs included
#      in output but reported as ⚠ and DO fail the audit — an opt-out
#      should be acknowledged by --repos-excluding it from the audit
#      invocation, keeping the intent visible in the caller).
#   1  lane would not fire on at least one consumer.
#   2  usage error / missing prerequisite.
#   3  fetch error (could not read a consumer's live files).
#
# Bash 3.2 portable. Requires yq (mikefarah v4+) for manifest parsing
# in live mode; --check-files mode needs no yq.

set -euo pipefail

err() { echo "ERROR: $*" >&2; }

MANIFEST=".mergepath-sync.yml"

# The marker that proves the default-ON lane code is present in a
# consumer's synced workflow. Single-sourced here; the workflow carries
# the literal.
LANE_DEFAULT_MARKER='PROP_ENABLED=${PROP_ENABLED:-true}'

# The branch prefix scripts/sync-to-downstream.sh actually uses for the
# PRs it opens. A consumer whose review-policy.yml overrides
# propagation_prs.branch_prefix to anything else has a lane that never
# matches real sync branches — that's a would-not-fire condition, not a
# healthy lane (Codex P2 on PR #444).
SYNC_BRANCH_PREFIX='mergepath-sync/'

# The actor scripts/sync-to-downstream.sh creates consumer PRs under.
# The lane's fingerprint requires PR author == the consumer's
# author_identity, so a present-but-wrong value (typo, stale identity,
# stray quoting that survives the same grep/awk extraction the lane
# uses) means the lane never matches a real sync PR (Codex P2 on
# PR #444 r3).
SYNC_AUTHOR_IDENTITY='nathanjohnpayne'

# Read a 2-space-indented scalar from a named YAML block — same
# state-machine awk as pr-review-policy.yml's prop_field, so this audit
# evaluates the exact predicate the lane evaluates.
prop_field() {  # <file> <block> <key>
  awk -v blk="$2" -v key="$3" '
    $0 ~ "^" blk ":" { in_blk = 1; next }
    in_blk && /^[^[:space:]#]/ { in_blk = 0 }
    in_blk && $1 == key":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      sub(/[[:space:]]*#.*$/, "", $0)
      gsub(/^"|"$/, "", $0)
      print
      exit
    }
  ' "$1"
}

# Read a TOP-LEVEL scalar (e.g. author_identity), stripping BOTH YAML quote
# styles, a trailing inline comment, and surrounding whitespace — the same
# normalization codex-review-request.sh's policy_top_field and the
# gh-pr-guard expected-author parser apply (#452). The lane's PR-author
# fingerprint in pr-review-policy.yml carries the matching extraction, so a
# quoted-but-correct `author_identity: "nathanjohnpayne"` passes in both the
# live lane and this audit instead of failing on the retained quotes.
policy_top_scalar() {  # <file> <key>
  [ -f "$1" ] || return 0
  awk -v key="$2" '
    /^[^[:space:]#]/ && $1 == key":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\x27]/, "", $0)
      gsub(/["\x27][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$1"
}

# Evaluate the lane preconditions for one (review-policy, workflow)
# file pair. Prints a status line; returns 0 if the lane fires, 1 if
# not.
lane_status_for_files() {  # <label> <policy-file-or-empty> <workflow-file-or-empty>
  local label=$1 policy=$2 workflow=$3
  local enabled author_id prefix

  if [ -z "$workflow" ] || [ ! -f "$workflow" ]; then
    echo "  ✗ $label: pr-review-policy.yml ABSENT on the live default branch — lane cannot fire"
    return 1
  fi
  if ! grep -qF "$LANE_DEFAULT_MARKER" "$workflow"; then
    echo "  ✗ $label: pr-review-policy.yml predates the #434 default-ON lane (marker '$LANE_DEFAULT_MARKER' missing) — lane requires an explicit enabled: true the consumer does not get; re-sync the workflow"
    return 1
  fi

  enabled=""
  author_id=""
  prefix=""
  if [ -n "$policy" ] && [ -f "$policy" ]; then
    enabled=$(prop_field "$policy" propagation_prs enabled)
    prefix=$(prop_field "$policy" propagation_prs branch_prefix)
    author_id=$(policy_top_scalar "$policy" author_identity || true)
  fi

  if [ "$enabled" = "false" ]; then
    echo "  ⚠ $label: propagation_prs.enabled: false — explicit opt-out; lane will NOT fire (exclude this consumer via --repos if intentional)"
    return 1
  fi
  # The lane enters only when PROP_ENABLED is exactly 'true' after
  # defaulting (absent → true). Any other present value — TRUE, False,
  # typos — leaves the lane dark even though YAML may consider it a
  # boolean; mirror the lane's exact-match semantics here (Codex P2 on
  # PR #444 r4).
  if [ -n "$enabled" ] && [ "$enabled" != "true" ]; then
    echo "  ✗ $label: propagation_prs.enabled is '$enabled' — the lane only fires on exactly 'true' (or an absent key); normalize the value or remove the key"
    return 1
  fi
  # An overridden branch_prefix that doesn't match what
  # sync-to-downstream.sh actually opens means the lane never matches a
  # real sync PR — report would-not-fire, not healthy (Codex P2 on
  # PR #444). Absent defaults to the sync prefix, mirroring the lane.
  if [ -n "$prefix" ] && [ "$prefix" != "$SYNC_BRANCH_PREFIX" ]; then
    echo "  ✗ $label: propagation_prs.branch_prefix is '$prefix' but sync-to-downstream.sh opens '$SYNC_BRANCH_PREFIX*' branches — lane will never match a real sync PR"
    return 1
  fi
  if [ -z "$author_id" ]; then
    echo "  ✗ $label: review-policy.yml has no author_identity — the lane's PR-author fingerprint cannot match"
    return 1
  fi
  if [ "$author_id" != "$SYNC_AUTHOR_IDENTITY" ]; then
    echo "  ✗ $label: review-policy.yml author_identity is '$author_id' but sync PRs are authored by '$SYNC_AUTHOR_IDENTITY' — the lane's PR-author fingerprint will never match a real sync PR"
    return 1
  fi

  if [ -z "$enabled" ]; then
    echo "  ✓ $label: lane fires (default-ON, author_identity=$author_id)"
  else
    echo "  ✓ $label: lane fires (enabled: $enabled, author_identity=$author_id)"
  fi
  return 0
}

# --- offline test mode ------------------------------------------------------

if [ "${1:-}" = "--check-files" ]; then
  [ $# -eq 3 ] || { err "--check-files needs exactly two file arguments"; exit 2; }
  if lane_status_for_files "check-files" "$2" "$3"; then
    exit 0
  fi
  exit 1
fi

# --- live mode --------------------------------------------------------------

FILTER_REPOS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repos)
      [ -n "${2:-}" ] || { err "missing argument for --repos"; exit 2; }
      FILTER_REPOS="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      err "unknown argument: $1"
      exit 2
      ;;
  esac
done

command -v yq >/dev/null 2>&1 || { err "yq is required (brew install yq)"; exit 2; }
yq --version 2>&1 | grep -q "mikefarah/yq" || { err "mikefarah/yq v4+ required"; exit 2; }
command -v gh >/dev/null 2>&1 || { err "gh is required"; exit 2; }
[ -f "$MANIFEST" ] || { err "$MANIFEST not found (run from the mergepath root)"; exit 2; }

# --- live-mode credential binding (#454) ------------------------------------
# Live mode does GitHub reads; bind them to a VERIFIED reviewer token rather
# than ambient gh state. --check-files mode returned above, so none of this
# runs offline (that mode needs no token, preflight, gh, or network).
__LANE_AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Auto-source the op-preflight cache when GH_TOKEN is unset and a fresh cache
# exists — the #282 pattern the sibling helpers use. A caller-supplied
# GH_TOKEN is respected and still verified below.
if [ -r "$__LANE_AUDIT_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__LANE_AUDIT_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi
if [ -z "${GH_TOKEN:-}" ]; then
  err "live mode needs a reviewer token. Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode review)\", or set GH_TOKEN to a reviewer PAT."
  exit 3
fi
# Verify the effective token identity is an available_reviewers reviewer
# (fail closed). Hard-require the shared reader: an unverifiable token must
# error rather than read live data under an unknown identity.
if [ ! -r "$__LANE_AUDIT_DIR/lib/reviewers-helpers.sh" ]; then
  err "reviewers-helpers missing: $__LANE_AUDIT_DIR/lib/reviewers-helpers.sh"
  exit 3
fi
# shellcheck source=lib/reviewers-helpers.sh
. "$__LANE_AUDIT_DIR/lib/reviewers-helpers.sh"
LANE_TOKEN_LOGIN=$(gh api user --jq .login 2>/dev/null || true)
if [ -z "$LANE_TOKEN_LOGIN" ] || ! login_is_available_reviewer "$LANE_TOKEN_LOGIN"; then
  err "live-mode token identity '${LANE_TOKEN_LOGIN:-<unresolvable>}' is not in available_reviewers — fail closed"
  exit 3
fi

in_repo_filter() {
  local name=$1
  [ -z "$FILTER_REPOS" ] && return 0
  case ",$FILTER_REPOS," in
    *",$name,"*) return 0 ;;
  esac
  return 1
}

fetch_live_file() {  # <repo> <path> <dest>; returns 0 fetched, 1 absent (404), 3 error
  local repo=$1 path=$2 dest=$3 rc=0 out
  out=$(gh api "repos/$repo/contents/$path" --jq '.content' 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"Not Found"*|*"404"*) return 1 ;;
      *) err "$repo: could not fetch $path: $out"; return 3 ;;
    esac
  fi
  printf '%s' "$out" | base64 -d > "$dest" 2>/dev/null || { err "$repo: could not decode $path"; return 3; }
  return 0
}

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/lane-audit.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

LANE_BROKEN=0
FETCH_ERROR=0

echo "Propagation lane audit (#434) — live default-branch preconditions per consumer"

while IFS=$'\t' read -r consumer_name consumer_repo; do
  [ -z "$consumer_name" ] && continue
  in_repo_filter "$consumer_name" || continue

  policy_file="$WORKDIR/$consumer_name-policy.yml"
  workflow_file="$WORKDIR/$consumer_name-workflow.yml"

  rc=0
  fetch_live_file "$consumer_repo" ".github/review-policy.yml" "$policy_file" || rc=$?
  if [ "$rc" -eq 3 ]; then FETCH_ERROR=1; continue; fi
  [ "$rc" -eq 1 ] && policy_file=""

  rc=0
  fetch_live_file "$consumer_repo" ".github/workflows/pr-review-policy.yml" "$workflow_file" || rc=$?
  if [ "$rc" -eq 3 ]; then FETCH_ERROR=1; continue; fi
  [ "$rc" -eq 1 ] && workflow_file=""

  if ! lane_status_for_files "$consumer_name" "$policy_file" "$workflow_file"; then
    LANE_BROKEN=1
  fi
done <<EOF
$(yq -r '.consumers[] | (.name + "\t" + .repo)' "$MANIFEST")
EOF

if [ "$FETCH_ERROR" -eq 1 ]; then
  echo "Propagation lane audit: FETCH ERROR (one or more consumers unreadable)"
  exit 3
fi
if [ "$LANE_BROKEN" -eq 1 ]; then
  echo "Propagation lane audit: FAIL (lane would not fire on at least one consumer)"
  exit 1
fi
echo "Propagation lane audit: PASS (lane fires on every audited consumer)"
exit 0
