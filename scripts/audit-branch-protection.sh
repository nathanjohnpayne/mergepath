#!/usr/bin/env bash
# audit-branch-protection.sh — verify branch protection on `main` enforces
# the canonical required status checks shipped by mergepath.
#
# Background: pr-review-policy.yml's `Label Gate` job FAILS when a blocking
# label (`needs-human-review`, `policy-violation`, `needs-external-review`,
# `human-hold`)
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
#   2 — gh API failure (auth scope, network, missing repo) — see diagnostic
#   3 — one or more canonical checks NOT required (PR-merge gating gap)
#
# Auth-scope note (#177, #285):
#   Reading branch protection requires `Administration:read` on the target
#   repo. Most author/admin PATs already have this; **reviewer PATs often
#   do NOT** and will get a 403 from
#   `GET /repos/{owner}/{repo}/branches/{branch}/protection`. The script
#   distinguishes 403 (auth/scope failure → exit 2 with diagnostic) from
#   404 (no classic protection → fall back to rulesets) so that running the
#   audit under a reviewer identity does not produce a false "PR merges are
#   completely unprotected" verdict. If you hit exit 2 with an auth-scope
#   diagnostic, re-run with an author/admin token.

set -eo pipefail

# Canonical required-checks list. Keep in sync with the workflows that
# mergepath ships under .github/workflows/. Each entry must match the
# `name:` field of a job in those files exactly (GitHub's required-
# checks API matches on display name).
CANONICAL_REQUIRED_CHECKS=(
  "Label Gate"
  "Self-Review Required"
  # HEAD-pinned merge gates. Each is a required check whose workflow
  # ships from mergepath. They are no-ops (always green) when their
  # per-repo knob in .github/review-policy.yml is off, so requiring them
  # in branch protection is safe even on consumers that haven't enabled
  # the gate yet — and it flags consumers whose branch protection doesn't
  # require them, which is the gap #427/#428 exploited (the gate ran but
  # was advisory, so escapes were caught only by the weekly audit).
  "Codex P1 unresolved threads"   # .github/workflows/codex-p1-gate.yml (#235)
  "CodeRabbit unresolved blocking findings"  # .github/workflows/coderabbit-severity-gate.yml (#577); no-op/green when coderabbit.severity_gate.enabled is off
  "Merge clearance gate"          # .github/workflows/merge-clearance-gate.yml (#427/#428)
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
Exit 2 on gh API auth/scope failures (use an author/admin PAT).
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
# Try (1) first; on a true 404 fall back to (2). On 403 (auth/scope
# failure) bail with a diagnostic — falling through to rulesets would
# produce a false "unprotected" verdict because the rulesets endpoint
# may also be denied or empty under the same auth.
#
# Implementation: `gh api -i` includes the HTTP status line, which lets
# us inspect the status code directly. We split headers from body via a
# blank-line marker, then extract the HTTP/x.y status code from the
# first line of the headers.
PROT_RAW=$(gh api -i "repos/$REPO/branches/$BRANCH/protection" 2>&1) || PROT_API_RC=$?
PROT_API_RC=${PROT_API_RC:-0}

# Extract HTTP status code from the first line ("HTTP/2 200" / "HTTP/1.1 404 Not Found")
# Falls back to empty string if there's no recognizable status line (e.g. network error).
PROT_STATUS=$(printf '%s\n' "$PROT_RAW" | awk 'NR==1 && /^HTTP\// {print $2; exit}')

# Split headers from body on the first blank line. Body is everything
# AFTER the blank line; if we can't find one (malformed / pre-HTTP error),
# treat the whole payload as the body so error messages still surface.
PROT_BODY=$(printf '%s\n' "$PROT_RAW" | awk 'BEGIN{p=0} /^[[:space:]]*$/{if(!p){p=1; next}} p{print}')
if [ -z "$PROT_BODY" ] && [ -z "$PROT_STATUS" ]; then
  PROT_BODY="$PROT_RAW"
fi

USE_RULESETS=0
case "$PROT_STATUS" in
  200)
    # Classic protection present — happy path.
    ;;
  404)
    # No classic protection configured. Fall back to rulesets (modern path).
    echo "Note: classic branch protection not configured on $BRANCH — checking rulesets instead."
    USE_RULESETS=1
    ;;
  401|403)
    # Auth/scope failure. This is the #177/#285 trap: a reviewer PAT
    # typically lacks Administration:read and gets 403 here. Falling
    # through to rulesets (which may also be denied) would produce a
    # false "PR merges are completely unprotected" verdict.
    cat >&2 <<EOF
ERROR: GitHub API returned HTTP $PROT_STATUS reading branch protection on
       $REPO@$BRANCH. This usually means the active token lacks the
       'Administration:read' scope required to read branch protection
       (reviewer PATs are commonly affected; author/admin PATs typically
       have it).

       Re-run with an author/admin token:
         GH_TOKEN="\$OP_PREFLIGHT_AUTHOR_PAT" scripts/audit-branch-protection.sh \\
           --repo $REPO --branch $BRANCH

       Refusing to fall through to the ruleset fallback because that would
       produce a false "unprotected" verdict under the same auth failure.

       Raw API response body:
EOF
    printf '%s\n' "$PROT_BODY" | sed 's/^/         /' >&2
    exit 2
    ;;
  "")
    # No status line — gh itself failed (network, gh not installed, etc).
    echo "Could not call gh api for branch protection on $REPO@$BRANCH (gh rc=$PROT_API_RC):" >&2
    printf '%s\n' "$PROT_RAW" | sed 's/^/  /' >&2
    exit 2
    ;;
  *)
    echo "Unexpected HTTP $PROT_STATUS reading branch protection on $REPO@$BRANCH:" >&2
    printf '%s\n' "$PROT_BODY" | sed 's/^/  /' >&2
    exit 2
    ;;
esac

if [ "$USE_RULESETS" -eq 1 ]; then
  RULESETS=$(gh api "repos/$REPO/rulesets" 2>&1) || {
    echo "Could not fetch rulesets: $RULESETS" >&2; exit 2
  }

  # Step A: compute the set of rulesets that ACTUALLY target the
  # audited branch. We need each ruleset's full definition to inspect
  # its conditions.ref_name.include array, so list IDs first then
  # fetch each one. Listing returns summaries without conditions.
  RULESET_IDS=$(echo "$RULESETS" | jq -r '
    .[]
    | select(.target == "branch")
    | .id
  ' 2>/dev/null)

  MATCHING_IDS=""
  for rid in $RULESET_IDS; do
    DETAIL=$(gh api "repos/$REPO/rulesets/$rid" 2>&1) || {
      echo "Could not fetch ruleset $rid: $DETAIL" >&2; exit 2
    }
    # Extract include patterns for this ruleset and decide if any of
    # them targets the audited branch. Four supported forms:
    #   ~DEFAULT_BRANCH  — matches if BRANCH is the repo's default
    #                      (we approximate: trust the include and let
    #                      a non-default-branch audit pick this up
    #                      only when the caller passed the actual
    #                      default; an explicit DEFAULT_BRANCH probe
    #                      would require an extra API call, so we
    #                      treat ~DEFAULT_BRANCH as matching when the
    #                      audited branch is "main" or "master" — the
    #                      99% case — and recommend explicit
    #                      refs/heads/<name> for non-default audits)
    #   ~ALL             — matches every branch
    #   refs/heads/<x>   — literal match against BRANCH
    #   refs/heads/<glob>— bash glob match against the BRANCH ref
    INCLUDES=$(echo "$DETAIL" | jq -r '.conditions.ref_name.include[]?' 2>/dev/null)
    [ -z "$INCLUDES" ] && continue

    BRANCH_REF="refs/heads/$BRANCH"
    # Reusable matcher: pattern-matches a SINGLE pattern against the
    # audited branch ref. Echoes "1" on match, "0" on miss. Used by
    # BOTH the include scan (a match means "this ruleset could apply")
    # and the exclude scan below (a match means "this ruleset does
    # NOT apply to this branch"). #285 r2 — nathanpayne-codex Phase
    # 4b finding: the original implementation only consulted
    # `.conditions.ref_name.include`, so a ruleset that included
    # `~ALL` but excluded `main` was incorrectly counted as
    # protecting main.
    match_ref_pat() {
      local pat="$1"
      case "$pat" in
        "~ALL")
          echo 1; return ;;
        "~DEFAULT_BRANCH")
          # main/master treated as the assumed default; for
          # non-default-branch audits, callers should use an explicit
          # refs/heads/<name> form.
          if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
            echo 1; return
          fi
          ;;
        "$BRANCH_REF")
          echo 1; return ;;
        refs/heads/*)
          # Bash glob match against the ref.
          # shellcheck disable=SC2053
          if [[ "$BRANCH_REF" == $pat ]]; then
            echo 1; return
          fi
          ;;
      esac
      echo 0
    }

    # Pass 1: any include pattern must match.
    MATCHED=0
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      if [ "$(match_ref_pat "$pat")" = "1" ]; then
        MATCHED=1
        break
      fi
    done <<<"$INCLUDES"

    if [ "$MATCHED" -ne 1 ]; then
      continue
    fi

    # Pass 2: any exclude pattern that matches DISQUALIFIES this
    # ruleset for the audited branch. A ruleset with
    # `include: [~ALL]` + `exclude: [refs/heads/main]` applies to
    # everything except main, so it does NOT protect main even though
    # the include matched. (#285 r2 — nathanpayne-codex Phase 4b.)
    EXCLUDES=$(echo "$DETAIL" | jq -r '.conditions.ref_name.exclude[]?' 2>/dev/null)
    if [ -n "$EXCLUDES" ]; then
      EXCLUDED=0
      while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        if [ "$(match_ref_pat "$pat")" = "1" ]; then
          EXCLUDED=1
          break
        fi
      done <<<"$EXCLUDES"
      if [ "$EXCLUDED" -eq 1 ]; then
        continue
      fi
    fi

    MATCHING_IDS="$MATCHING_IDS $rid"
  done

  # Strip leading/trailing whitespace for the empty check below.
  MATCHING_IDS=$(echo "$MATCHING_IDS" | awk '{$1=$1; print}')

  if [ -z "$MATCHING_IDS" ]; then
    echo "FAIL: no rulesets target $BRANCH on $REPO. PR merges are completely unprotected."
    exit 3
  fi

  # Step B: extract required status checks ONLY from the rulesets that
  # target the audited branch. Concatenate each matching ruleset's
  # required_status_checks parameter. Previously this collected from
  # ALL branch-target rulesets regardless of include match (#285).
  REQUIRED_CHECKS=""
  for rid in $MATCHING_IDS; do
    DETAIL=$(gh api "repos/$REPO/rulesets/$rid" 2>&1) || {
      echo "Could not fetch ruleset $rid: $DETAIL" >&2; exit 2
    }
    THIS_CHECKS=$(echo "$DETAIL" | jq -r '
      .rules[]?
      | select(.type == "required_status_checks")
      | .parameters.required_status_checks[]?
      | .context
    ' 2>/dev/null)
    if [ -n "$THIS_CHECKS" ]; then
      if [ -n "$REQUIRED_CHECKS" ]; then
        REQUIRED_CHECKS="$REQUIRED_CHECKS
$THIS_CHECKS"
      else
        REQUIRED_CHECKS="$THIS_CHECKS"
      fi
    fi
  done
else
  REQUIRED_CHECKS=$(echo "$PROT_BODY" | jq -r '.required_status_checks.contexts[]? // empty')
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
echo "'needs-human-review' / 'policy-violation' / 'needs-external-review' /"
echo "'human-hold' is"
echo "present (see nathanjohnpayne/mergepath#161)."
echo ""
echo "Fix: Settings → Branches → Branch protection rule for '$BRANCH'"
echo "→ Require status checks to pass before merging → Add the missing"
echo "checks. Each workflow must have run at least once on the repo for"
echo "GitHub's UI to offer the check name in the dropdown."
exit 3
