#!/usr/bin/env bash
# scripts/admin-merge-codeowners-blocked.sh
#
# Batch-merge helper for the specific situation where:
#   - All required CI checks pass
#   - Codex 👍 cleared on the current HEAD
#   - An APPROVED review is present (possibly from a same-agent
#     reviewer identity)
#   - Branch protection's CODEOWNERS rule (`* @nathanjohnpayne` in
#     .github/CODEOWNERS) still blocks merge because the only
#     declared CODEOWNER is also the PR author, and GitHub's
#     no-self-approval rule prevents nathanjohnpayne from approving
#     their own PR.
#
# This is a HUMAN-AUTHORIZED escape hatch. The CODEOWNERS-author
# deadlock can't be cleared by automation; the human is the
# tiebreaker. Per REVIEW_POLICY.md § Phase 4 § "Never use --admin
# unless the human explicitly authorizes it in chat as a break-
# glass exception" — this script's invocation IS that
# authorization. The PreToolUse hook on `gh pr merge --admin`
# treats running this wrapper as the auth signal.
#
# Usage:
#   scripts/admin-merge-codeowners-blocked.sh <pr-ref> [<pr-ref> ...]
#
#   <pr-ref> takes one of two forms:
#     <num>                  PR in nathanjohnpayne/mergepath (this repo)
#     <owner>/<repo>#<num>   cross-repo PR
#
# Per PR, the script:
#   1. Resolves owner/repo + PR number
#   2. Asserts the PR is OPEN and MERGEABLE
#   3. Confirms the block is the CODEOWNERS deadlock and nothing else:
#      mergeStateStatus must be BLOCKED or CLEAN (not UNSTABLE/BEHIND/
#      DIRTY/DRAFT/UNKNOWN), every status check must be green, AND a
#      present APPROVED review must exist with no outstanding
#      CHANGES_REQUESTED. The approval requirement is what distinguishes
#      the CODEOWNERS self-author deadlock (an approval exists, it just
#      can't satisfy the CODEOWNERS rule) from a genuinely unreviewed PR
#      — without it, --admin would merge unreviewed code. This keeps the
#      escape hatch scoped to the review/conversation deadlock it exists
#      for; it will NOT force-merge failing/pending CI or unreviewed code.
#      (Note: in the real deadlock reviewDecision is REVIEW_REQUIRED, so
#      this checks for a present APPROVED review, not reviewDecision.)
#   4. Resolves bot-authored review threads on the current HEAD via
#      scripts/resolve-pr-threads.sh (HEAD-freshness guarded; human
#      threads are never touched), so required_conversation_resolution
#      doesn't block the merge.
#   5. Runs `scripts/gh-as-author.sh -- gh pr merge <n> --repo
#      <owner/repo> --squash --delete-branch --admin`
#   6. Verifies the merge landed by re-reading the PR's state
#
# Exit codes:
#   0  every PR merged successfully
#   1  at least one PR failed to merge or was refused (others may have
#      succeeded)
#   2  usage / argument error
#   3  preflight error (op-preflight cache missing, gh not on PATH, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat >&2 <<EOF
usage: scripts/admin-merge-codeowners-blocked.sh <pr-ref> [<pr-ref> ...]

  <pr-ref>   <num> for this repo, or <owner>/<repo>#<num> cross-repo

Each PR is merged via \`gh pr merge --squash --delete-branch --admin\`
under the AUTHOR identity (nathanjohnpayne). Running this script is
the explicit human authorization for the --admin escape hatch per
REVIEW_POLICY.md § Phase 4.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage

command -v gh >/dev/null 2>&1 || {
  echo "admin-merge: gh not on PATH" >&2
  exit 3
}

# Auto-source preflight cache so write-path auth works without
# inline op-read biometric prompts.
PREFLIGHT="$SCRIPT_DIR/op-preflight.sh"
if [ -x "$PREFLIGHT" ]; then
  # shellcheck disable=SC1090
  eval "$("$PREFLIGHT" --agent claude --check 2>/dev/null)" || true
fi

# Read-path gh wrapper. Prefer the preflight reviewer PAT when present,
# otherwise fall back to the ambient GH_TOKEN / keyring. Never export an
# empty GH_TOKEN — an empty value still takes precedence over stored
# credentials and breaks auth when the preflight cache is absent.
gh_ro() {
  if [ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]; then
    GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh "$@"
  else
    gh "$@"
  fi
}

# Resolve current-repo for bare <num> refs.
CURRENT_REPO=""
resolve_current_repo() {
  if [ -n "$CURRENT_REPO" ]; then return 0; fi
  # Resolve from $REPO_ROOT, not the caller's CWD, so a bare <num> ref
  # always targets this repo even when the script is invoked elsewhere.
  if ! CURRENT_REPO=$( (cd "$REPO_ROOT" && gh_ro repo view --json owner,name --jq '.owner.login + "/" + .name') 2>/dev/null); then
    echo "admin-merge: bare <num> ref passed but current dir is not a gh-resolvable repo" >&2
    exit 3
  fi
}

parse_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^([^/]+)/([^#]+)#([0-9]+)$ ]]; then
    printf '%s/%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    resolve_current_repo
    printf '%s\t%s\n' "$CURRENT_REPO" "$ref"
  else
    echo "admin-merge: invalid pr-ref: $ref" >&2
    exit 2
  fi
}

GH_AS_AUTHOR="$SCRIPT_DIR/gh-as-author.sh"
if [ ! -x "$GH_AS_AUTHOR" ]; then
  echo "admin-merge: missing $GH_AS_AUTHOR" >&2
  exit 3
fi

# Canonical thread-resolution helper (HEAD-freshness guarded, bot-only).
RESOLVE_THREADS="$SCRIPT_DIR/resolve-pr-threads.sh"

OVERALL_RC=0

for ref in "$@"; do
  parsed=$(parse_ref "$ref")
  repo=$(printf '%s\n' "$parsed" | cut -f1)
  num=$(printf '%s\n' "$parsed" | cut -f2)

  printf '\n========================================\n'
  printf 'PR: %s#%s\n' "$repo" "$num"
  printf '========================================\n'

  state=$(gh_ro pr view "$num" --repo "$repo" \
    --json state,mergeable,mergeStateStatus,title \
    --jq '.state + "|" + (.mergeable // "") + "|" + (.mergeStateStatus // "") + "|" + .title' 2>&1) || {
    printf '  ✗ could not read PR state: %s\n' "$state"
    OVERALL_RC=1
    continue
  }
  pr_state=$(printf '%s\n' "$state" | cut -d'|' -f1)
  pr_mergeable=$(printf '%s\n' "$state" | cut -d'|' -f2)
  pr_msstatus=$(printf '%s\n' "$state" | cut -d'|' -f3)
  pr_title=$(printf '%s\n' "$state" | cut -d'|' -f4-)
  printf '  title:           %s\n' "$pr_title"
  printf '  state:           %s\n' "$pr_state"
  printf '  mergeable:       %s\n' "$pr_mergeable"
  printf '  mergeStateStatus: %s\n' "$pr_msstatus"

  if [ "$pr_state" != "OPEN" ]; then
    printf '  · already %s; skipping\n' "$pr_state"
    continue
  fi
  if [ "$pr_mergeable" != "MERGEABLE" ]; then
    printf '  ✗ not MERGEABLE (got %s) — refusing --admin merge\n' "$pr_mergeable"
    OVERALL_RC=1
    continue
  fi

  # Gate 1 — scope to the CODEOWNERS deadlock. `mergeable` only reports
  # merge-conflict status; it does NOT mean checks/reviews are satisfied.
  # The only states this break-glass helper should ever --admin-merge are
  # BLOCKED (the expected deadlock: required approving review missing
  # because the sole CODEOWNER is the author) and CLEAN (admin not even
  # needed). Anything else (UNSTABLE, BEHIND, DIRTY, DRAFT, UNKNOWN) means
  # a different blocker is in play — refuse rather than force past it.
  case "$pr_msstatus" in
    BLOCKED|CLEAN) : ;;
    *)
      printf '  ✗ mergeStateStatus=%s is not a CODEOWNERS-deadlock state — refusing --admin merge\n' "$pr_msstatus"
      OVERALL_RC=1
      continue
      ;;
  esac

  # Gate 2 — BLOCKED also covers failing/pending REQUIRED checks, which
  # mergeStateStatus alone can't distinguish from a review-only block.
  # This helper's precondition is "all CI checks pass", so refuse if any
  # status check is failing or still running.
  not_green=$(gh_ro pr view "$num" --repo "$repo" --json statusCheckRollup --jq '
    [ .statusCheckRollup[]?
      | select(
          (.__typename == "CheckRun" and (
             (.status != "COMPLETED")
             or ((.conclusion // "" | ascii_downcase) as $c
                 | (($c == "success") or ($c == "skipped") or ($c == "neutral")) | not)
          ))
          or
          (.__typename == "StatusContext" and ((.state // "" | ascii_downcase) != "success"))
        )
      | (.name // .context // "check") ]
    | join(", ")' 2>&1) || not_green="__error__"
  if [ "$not_green" = "__error__" ]; then
    printf '  ✗ could not read check status — refusing --admin merge\n'
    OVERALL_RC=1
    continue
  fi
  if [ -n "$not_green" ]; then
    printf '  ✗ checks not green (%s) — refusing --admin merge\n' "$not_green"
    OVERALL_RC=1
    continue
  fi

  # Gate 3 — require a present approving review. mergeStateStatus=BLOCKED
  # also matches a genuinely-unreviewed PR (no approvals at all), not just
  # the CODEOWNERS self-author deadlock. This helper's premise is that an
  # APPROVED review exists and merely can't satisfy the CODEOWNERS rule;
  # --admin-merging without one would bypass review entirely. reviewDecision
  # is REVIEW_REQUIRED in the real deadlock (the approval isn't from a
  # CODEOWNER), so check the latest review state per author instead: at
  # least one APPROVED, and none with CHANGES_REQUESTED outstanding.
  review_states=$(gh_ro pr view "$num" --repo "$repo" --json reviews --jq '
    .reviews
    | group_by(.author.login)
    | map(max_by(.submittedAt) | .state)' 2>&1) || review_states="__error__"
  if [ "$review_states" = "__error__" ]; then
    printf '  ✗ could not read review state — refusing --admin merge\n'
    OVERALL_RC=1
    continue
  fi
  if printf '%s' "$review_states" | grep -q '"CHANGES_REQUESTED"'; then
    printf '  ✗ a reviewer has CHANGES_REQUESTED outstanding — refusing --admin merge\n'
    OVERALL_RC=1
    continue
  fi
  if ! printf '%s' "$review_states" | grep -q '"APPROVED"'; then
    printf '  ✗ no APPROVED review present — refusing --admin merge (this helper clears the CODEOWNERS deadlock, not the review requirement itself)\n'
    OVERALL_RC=1
    continue
  fi

  # Resolve bot-authored review threads on the current HEAD before the
  # merge: branch protection's required_conversation_resolution fails the
  # merge (even with --admin) while any thread is unresolved. Delegate to
  # the canonical helper, which enforces the current-HEAD freshness guard
  # and only touches bot threads (never human-authored ones). The prior
  # inline GraphQL reimplementation here did neither.
  if [ -x "$RESOLVE_THREADS" ]; then
    rt_rc=0
    "$RESOLVE_THREADS" "$num" --repo "$repo" --auto-resolve-bots || rt_rc=$?
    if [ "$rt_rc" -ne 0 ]; then
      printf '  · note: resolve-pr-threads exited %d; any remaining (e.g. human-authored) thread will block the merge below\n' "$rt_rc"
    fi
  else
    printf '  · warning: %s missing; skipping pre-merge thread resolution\n' "$RESOLVE_THREADS"
  fi

  printf '  ⤷ merging with --admin (CODEOWNERS-author deadlock)\n'
  if "$GH_AS_AUTHOR" -- gh pr merge "$num" --repo "$repo" --squash --delete-branch --admin; then
    new_state=$(gh_ro pr view "$num" --repo "$repo" \
      --json state,mergeCommit --jq '.state + " " + (.mergeCommit.oid // "")[0:7]' 2>&1)
    printf '  ✓ merged: %s\n' "$new_state"
  else
    printf '  ✗ merge failed for #%s on %s\n' "$num" "$repo"
    OVERALL_RC=1
  fi
done

echo
if [ "$OVERALL_RC" -eq 0 ]; then
  echo "admin-merge: all PRs merged successfully"
else
  echo "admin-merge: one or more PRs failed; see output above"
fi
exit "$OVERALL_RC"
