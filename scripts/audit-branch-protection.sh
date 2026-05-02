#!/usr/bin/env bash
# audit-branch-protection.sh — verify branch protection on `main` enforces
# the canonical required status checks shipped by mergepath.
#
# Background: pr-review-policy.yml's `Label Gate` job FAILS when a blocking
# label (`needs-human-review`, `policy-violation`, `needs-external-review`)
# is on the PR. But that failure only blocks merge if the workflow is
# configured as a REQUIRED status check in branch protection. Without the
# protection bit, the failed check is advisory and PRs merge anyway. This
# is the gap that motivated nathanjohnpayne/mergepath#161 (matchline #93,
# #76 merged past `needs-human-review`).
#
# Same gap applies to other workflows (Self-Review Required, agent-review
# pipeline jobs). This audit reads branch protection via gh API and reports
# whether each canonical check is required.
#
# Usage:
#   scripts/audit-branch-protection.sh              # audit current repo, branch=main
#   scripts/audit-branch-protection.sh --repo owner/name
#   scripts/audit-branch-protection.sh --branch master
#
# Exit codes:
#   0 — all canonical checks are required
#   1 — bad arguments
#   2 — gh API failure (auth, missing repo, network)
#   3 — one or more canonical checks NOT required (PR-merge gating gap)
#
# Requires a token with `Administration:read` scope on the target repo
# (most reviewer/author PATs already have this).

set -eo pipefail

# Canonical required-checks list. Keep in sync with the workflows that
# mergepath ships under .github/workflows/. Each entry must match the
# `name:` field of a job in those files exactly (GitHub's required-
# checks API matches on display name).
CANONICAL_REQUIRED_CHECKS=(
  "Label Gate"
  "Self-Review Required"
)

REPO=""
BRANCH="main"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --repo requires a non-empty value (owner/name)" >&2; exit 1
      fi
      REPO="$2"; shift 2 ;;
    --branch)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --branch requires a non-empty value" >&2; exit 1
      fi
      BRANCH="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: scripts/audit-branch-protection.sh [--repo owner/name] [--branch <name>]

Verifies branch protection on \$BRANCH (default: main) requires the
canonical mergepath-shipped status checks:
  ${CANONICAL_REQUIRED_CHECKS[*]}

Exit 3 if any canonical check is not required (PR-merge gating gap).
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Could not resolve repo. Pass --repo owner/name." >&2; exit 2
  }
fi

if ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid --repo value: '$REPO' (expected owner/name)" >&2; exit 1
fi

echo "Auditing branch protection on $REPO@$BRANCH..."
echo ""

# Fetch the branch-protection rules. Two endpoints are relevant:
#   1. /branches/{branch}/protection — classic protection rules
#   2. /rulesets — newer rulesets (the modern way)
# Try (1) first; if 404, fall back to (2).
PROT=$(gh api "repos/$REPO/branches/$BRANCH/protection" 2>&1) || true
if echo "$PROT" | grep -q '"message":'; then
  echo "Note: classic branch protection not configured on $BRANCH — checking rulesets instead."
  RULESETS=$(gh api "repos/$REPO/rulesets" 2>&1) || {
    echo "Could not fetch rulesets: $RULESETS" >&2; exit 2
  }
  REQUIRED=$(echo "$RULESETS" | jq -r '
    .[]
    | select(.target == "branch")
    | .conditions.ref_name.include[]?
    | select(. == "~DEFAULT_BRANCH" or . == "refs/heads/'"$BRANCH"'")
  ' 2>/dev/null | head -1)
  if [ -z "$REQUIRED" ]; then
    echo "FAIL: no rulesets target $BRANCH on $REPO. PR merges are completely unprotected."
    exit 3
  fi
  REQUIRED_CHECKS=$(echo "$RULESETS" | jq -r '
    .[]
    | select(.target == "branch")
    | .rules[]?
    | select(.type == "required_status_checks")
    | .parameters.required_status_checks[]?
    | .context
  ')
else
  REQUIRED_CHECKS=$(echo "$PROT" | jq -r '.required_status_checks.contexts[]? // empty')
fi

if [ -z "$REQUIRED_CHECKS" ]; then
  echo "FAIL: $REPO@$BRANCH has branch protection but no required status checks configured."
  echo "      Add the canonical checks via:"
  echo "        Settings → Branches → Branch protection rule for '$BRANCH'"
  echo "        → Require status checks to pass before merging"
  echo "        → Add: ${CANONICAL_REQUIRED_CHECKS[*]}"
  exit 3
fi

echo "Required status checks currently enforced:"
echo "$REQUIRED_CHECKS" | sed 's/^/  ✓ /'
echo ""

MISSING=()
for check in "${CANONICAL_REQUIRED_CHECKS[@]}"; do
  if ! echo "$REQUIRED_CHECKS" | grep -Fxq "$check"; then
    MISSING+=("$check")
  fi
done

if [ ${#MISSING[@]} -eq 0 ]; then
  echo "PASS: all canonical mergepath checks are required."
  exit 0
fi

echo "FAIL: ${#MISSING[@]} canonical mergepath check(s) NOT required on $BRANCH:"
for check in "${MISSING[@]}"; do
  echo "  ✗ $check"
done
echo ""
echo "Without these as required, the corresponding workflows fire on PRs but"
echo "their failures are advisory — PRs merge despite the failed check."
echo "Specifically: 'Label Gate' enforces the prohibition on merging while"
echo "'needs-human-review' / 'policy-violation' / 'needs-external-review' is"
echo "present (see nathanjohnpayne/mergepath#161)."
echo ""
echo "Fix: Settings → Branches → Branch protection rule for '$BRANCH'"
echo "→ Require status checks to pass before merging → Add the missing"
echo "checks. Each workflow must have run at least once on the repo for"
echo "GitHub's UI to offer the check name in the dropdown."
exit 3
