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
#   scripts/audit-branch-protection.sh --fleet      # audit the whole fleet (#774)
#
# Exit codes (single-repo mode):
#   0 — all canonical checks are required
#   1 — bad arguments
#   2 — gh API failure (auth scope, network, missing repo) — see diagnostic
#   3 — one or more canonical checks NOT required (PR-merge gating gap)
#
# Fleet mode (--fleet, #774):
#   Audits the hub plus every consumer declared in `.mergepath-sync.yml`
#   (`.consumers[].repo`), re-invoking this same script once per repo, and
#   prints a compact per-repo verdict table alongside the full per-repo
#   output. `.github/workflows/branch-protection-audit.yml` is the
#   scheduled caller; before #774 nothing invoked this script at all, which
#   is how the fleet drifted to 0-of-5 canonical gates on eight of ten
#   repos without anything going red.
#
#   Each repo is audited on ITS OWN default branch, resolved per repo from
#   `GET /repos/{owner}/{repo}`. A fleet run must not assume every repo
#   calls its default branch `main`: the recorded posture in
#   docs/architecture/0002-branch-protection-enforcement-posture.md is
#   "all five canonical checks on its default branch", and auditing a
#   renamed or `master`-defaulted repo against a hard-coded `main` would
#   inspect a branch that may not even exist. An explicit `--branch` still
#   overrides, and is then applied uniformly to every repo.
#
#   Exit codes are deliberately the SAME shape as single-repo mode, so a
#   caller's `case "$rc"` reads identically in both:
#     0 — every audited repo requires all canonical checks
#     1 — bad arguments or a missing prerequisite (yq, manifest, hub repo)
#     2 — at least one repo could NOT be audited (auth/API failure). This
#         is an INFRASTRUCTURE failure, not drift — most often a token
#         without `Administration:read`. It takes precedence over 3
#         because an unreadable repo's protection posture is unknown, and
#         reporting "drift" for the repos that did answer would imply the
#         rest were clean.
#     3 — every repo was audited successfully and at least one is missing
#         a canonical check (the drift verdict worth rolling up).
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
#
# Admin-enforcement (--require-admin-enforcement):
#   A required status check is bypassable by a repository admin unless
#   classic protection sets `enforce_admins: true` (or, under rulesets, the
#   governing ruleset grants nobody a bypass). ADR 0002 requires that
#   posture on the HUB specifically — the two escapes that motivated the
#   merge-clearance gate (#427/#428) were both admin merges — so `--fleet`
#   passes this flag for the hub repo and a hub that requires all five
#   canonical checks but leaves admins unconstrained is DRIFT (exit 3), not
#   a PASS. Consumers are not audited for it: ADR 0002 does not require it
#   of them.

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

REPO=""
BRANCH="main"
# Distinguishes "caller asked for this branch" from "nobody said, so the
# default is main". --fleet resolves each repo's own default branch unless
# the caller was explicit, so the two cases cannot share one variable.
BRANCH_EXPLICIT=0
FLEET=0
MANIFEST=""
AUDIT_CMD=""
HUB_REPO=""
SUMMARY_FILE=""
REQUIRE_ADMIN_ENFORCEMENT=0

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
      BRANCH="$2"; BRANCH_EXPLICIT=1; shift 2 ;;
    --require-admin-enforcement)
      # ADR 0002 requires enforce_admins on the hub (#427/#428 were both
      # admin merges). Off by default so consumer audits keep their
      # documented posture.
      REQUIRE_ADMIN_ENFORCEMENT=1; shift ;;
    --fleet)
      FLEET=1; shift ;;
    --manifest)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --manifest requires a non-empty path" >&2; exit 1
      fi
      MANIFEST="$2"; shift 2 ;;
    --hub-repo)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --hub-repo requires a non-empty value (owner/name)" >&2; exit 1
      fi
      HUB_REPO="$2"; shift 2 ;;
    --summary-file)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --summary-file requires a non-empty path" >&2; exit 1
      fi
      SUMMARY_FILE="$2"; shift 2 ;;
    --audit-cmd)
      # Test seam: the per-repo auditor invoked by --fleet. Defaults to
      # this script itself, so production never passes it.
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --audit-cmd requires a non-empty path" >&2; exit 1
      fi
      AUDIT_CMD="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: scripts/audit-branch-protection.sh [--repo owner/name] [--branch <name>]
                                          [--require-admin-enforcement]
       scripts/audit-branch-protection.sh --fleet [--branch <name>]
                                          [--hub-repo owner/name]
                                          [--manifest <path>]
                                          [--summary-file <path>]

Verifies branch protection on \$BRANCH (default: main) requires the
canonical mergepath-shipped status checks:
  ${CANONICAL_REQUIRED_CHECKS[*]}

--require-admin-enforcement additionally requires that admins cannot
bypass those checks (classic \`enforce_admins: true\`, or a governing
ruleset with no bypass actors). ADR 0002 requires this on the hub.

Exit 3 if any canonical check is not required (PR-merge gating gap).
Exit 2 on gh API auth/scope failures (use an author/admin PAT).

--fleet audits the hub plus every \`.consumers[].repo\` in
.mergepath-sync.yml and prints a per-repo verdict table. Each repo is
audited on its OWN default branch unless --branch is passed explicitly,
and the hub is audited with --require-admin-enforcement. Same exit-code
shape: 0 all clean, 1 usage/prerequisite, 2 at least one repo unreadable
(infrastructure, NOT drift), 3 drift on at least one readable repo.
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────
# Fleet mode (#774)
# ─────────────────────────────────────────────────────────────────────
#
# Loops the hub + every manifest consumer, re-invoking the single-repo
# auditor once per repo. Deliberately a thin loop: all protection
# semantics stay in the single-repo path below, so there is exactly one
# implementation of "is this check required".
fleet_audit() {
  local manifest="${MANIFEST:-$SCRIPT_DIR/../.mergepath-sync.yml}"
  local audit_cmd="${AUDIT_CMD:-$SELF}"

  if ! command -v yq >/dev/null 2>&1; then
    echo "Error: --fleet requires mikefarah/yq v4+ to parse $manifest" >&2
    echo "       brew install yq  (the pure-Python kislyuk/yq is NOT compatible)" >&2
    return 1
  fi
  if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
    echo "Error: detected a non-mikefarah yq; --fleet needs the Go binary (brew install yq)" >&2
    echo "       yq --version: $(yq --version 2>&1)" >&2
    return 1
  fi
  if [ ! -f "$manifest" ]; then
    echo "Error: propagation manifest not found: $manifest" >&2
    echo "       Pass --manifest <path> or run from a mergepath checkout." >&2
    return 1
  fi

  local consumer_rows
  if ! consumer_rows=$(yq -r '.consumers[].repo' "$manifest" 2>&1); then
    echo "Error: could not read .consumers[].repo from $manifest:" >&2
    printf '%s\n' "$consumer_rows" | sed 's/^/  /' >&2
    return 1
  fi

  # The hub is audited too — #774 measured mergepath itself at 2 of 5
  # canonical gates, so a fleet audit that covered only consumers would
  # miss the repo the whole system is governed from. It is not in the
  # manifest's consumer list (the hub is not its own consumer), so it is
  # resolved separately and prepended.
  local hub="$HUB_REPO"
  if [ -z "$hub" ]; then
    hub=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || hub=""
  fi
  if [ -z "$hub" ]; then
    echo "Error: could not resolve the hub repository. Pass --hub-repo owner/name." >&2
    return 1
  fi

  local repos=("$hub")
  local r
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    [ "$r" = "$hub" ] && continue
    repos+=("$r")
  done <<<"$consumer_rows"

  # A fleet run audits each repo on its own default branch. Only an
  # explicit --branch pins one branch name across the whole fleet.
  local branch_label
  if [ "$BRANCH_EXPLICIT" -eq 1 ]; then
    branch_label="branch '$BRANCH' (explicit --branch, applied to every repo)"
  else
    branch_label="each repo's own default branch"
  fi

  echo "Fleet branch-protection audit — ${#repos[@]} repo(s), $branch_label"
  echo "Manifest: $manifest"
  echo ""

  local summary=""
  local n_pass=0 n_drift=0 n_error=0
  local out rc verdict tmp repo_branch
  tmp="$(mktemp "${TMPDIR:-/tmp}/fleet-bp-audit.XXXXXX")"

  for r in "${repos[@]}"; do
    rc=0

    # Resolve this repo's default branch unless the caller pinned one.
    # A repo whose metadata cannot be read is an ERROR (infrastructure),
    # never a PASS: guessing `main` here would audit a branch that may
    # not exist and report the resulting "unprotected" verdict as drift.
    if [ "$BRANCH_EXPLICIT" -eq 1 ]; then
      repo_branch="$BRANCH"
    else
      repo_branch="$(gh api "repos/$r" --jq '.default_branch' 2>/dev/null || true)"
      if [ -z "$repo_branch" ] || [ "$repo_branch" = "null" ]; then
        n_error=$((n_error + 1))
        echo "--- $r (rc=2, ERROR) ---"
        echo "Could not resolve the default branch for $r via GET /repos/$r."
        echo "Refusing to fall back to 'main': that would audit a branch this repo"
        echo "may not have and report the miss as protection drift. Treating the"
        echo "repo as unreadable (infrastructure failure) instead."
        echo ""
        summary="${summary}$(printf '%-6s rc=%-2s %s' "ERROR" "2" "$r@<unresolved>")
"
        continue
      fi
    fi

    # ADR 0002 requires enforce_admins on the hub only, so the flag is
    # passed for the hub and withheld from consumers.
    if [ "$r" = "$hub" ]; then
      "$audit_cmd" --repo "$r" --branch "$repo_branch" --require-admin-enforcement >"$tmp" 2>&1 || rc=$?
    else
      "$audit_cmd" --repo "$r" --branch "$repo_branch" >"$tmp" 2>&1 || rc=$?
    fi
    out="$(cat "$tmp")"
    case "$rc" in
      0) verdict="PASS";  n_pass=$((n_pass + 1)) ;;
      3) verdict="DRIFT"; n_drift=$((n_drift + 1)) ;;
      # 1 (bad arguments) is impossible from a loop that builds its own
      # argv, and 2 is the documented auth/API failure. Both — and any
      # unexpected code — are infrastructure, never drift.
      *) verdict="ERROR"; n_error=$((n_error + 1)) ;;
    esac
    echo "--- $r@$repo_branch (rc=$rc, $verdict) ---"
    printf '%s\n' "$out"
    echo ""
    summary="${summary}$(printf '%-6s rc=%-2s %s' "$verdict" "$rc" "$r@$repo_branch")
"
  done
  rm -f "$tmp"

  local tally="Audited ${#repos[@]} repo(s): ${n_pass} pass, ${n_drift} drift, ${n_error} error."
  local summary_block
  summary_block="=== Fleet summary ($branch_label) ===
${summary}${tally}"

  echo "$summary_block"

  if [ -n "$SUMMARY_FILE" ]; then
    printf '%s\n' "$summary_block" >"$SUMMARY_FILE"
  fi

  if [ "$n_error" -gt 0 ]; then
    echo "" >&2
    echo "ERROR: ${n_error} repo(s) could not be audited. Branch protection is" >&2
    echo "       read via GET /repos/{owner}/{repo}/branches/{branch}/protection," >&2
    echo "       which requires the 'Administration:read' scope — reviewer PATs" >&2
    echo "       commonly lack it. Re-run with an author/admin token. This is an" >&2
    echo "       infrastructure failure, NOT a drift verdict." >&2
    return 2
  fi
  if [ "$n_drift" -gt 0 ]; then
    return 3
  fi
  return 0
}

# Reject the flag combinations that would otherwise be silently ignored:
# a caller who typed `--summary-file x` but forgot `--fleet` would get an
# empty summary and a clean exit, which is exactly the class of silent
# no-op #774 is about.
if [ "$FLEET" -eq 1 ] && [ -n "$REPO" ]; then
  echo "Error: --fleet and --repo are mutually exclusive" >&2; exit 1
fi
if [ "$FLEET" -eq 1 ] && [ "$REQUIRE_ADMIN_ENFORCEMENT" -eq 1 ]; then
  echo "Error: --require-admin-enforcement is decided per repo by --fleet (hub only, per ADR 0002)" >&2
  echo "       and would be silently ignored here. Drop it, or audit the hub directly with --repo." >&2
  exit 1
fi
if [ "$FLEET" -eq 0 ]; then
  for _fleet_only in "--manifest:$MANIFEST" "--hub-repo:$HUB_REPO" \
                     "--summary-file:$SUMMARY_FILE" "--audit-cmd:$AUDIT_CMD"; do
    if [ -n "${_fleet_only#*:}" ]; then
      echo "Error: ${_fleet_only%%:*} requires --fleet" >&2; exit 1
    fi
  done
fi

if [ "$FLEET" -eq 1 ]; then
  FLEET_RC=0
  fleet_audit || FLEET_RC=$?
  exit "$FLEET_RC"
fi

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

# Lazily resolve this repo's real default branch, once. Only the
# `~DEFAULT_BRANCH` ruleset condition needs it, so repos on the classic
# path never pay for the extra call. Returns the empty string when the
# metadata read fails, which callers treat as "unknown".
REPO_DEFAULT_BRANCH=""
REPO_DEFAULT_BRANCH_RESOLVED=0
repo_default_branch() {
  if [ "$REPO_DEFAULT_BRANCH_RESOLVED" -eq 0 ]; then
    REPO_DEFAULT_BRANCH_RESOLVED=1
    REPO_DEFAULT_BRANCH="$(gh api "repos/$REPO" --jq '.default_branch' 2>/dev/null || true)"
    [ "$REPO_DEFAULT_BRANCH" = "null" ] && REPO_DEFAULT_BRANCH=""
  fi
  printf '%s' "$REPO_DEFAULT_BRANCH"
}

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
    #   ~DEFAULT_BRANCH  — matches when BRANCH really is this repo's
    #                      default branch, resolved once from
    #                      GET /repos/{owner}/{repo}. The earlier
    #                      implementation assumed main/master was the
    #                      default, which mis-answered both ways on a
    #                      repo with a renamed default: a `trunk` audit
    #                      saw "no ruleset targets trunk" (false DRIFT)
    #                      and a `main` audit on a trunk-defaulted repo
    #                      counted a ruleset that does not govern main
    #                      (false PASS). The main/master guess survives
    #                      only as a fallback for when the metadata read
    #                      itself fails.
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
          local def
          def="$(repo_default_branch)"
          if [ -n "$def" ]; then
            # Authoritative answer from the repo's own metadata.
            if [ "$BRANCH" = "$def" ]; then
              echo 1; return
            fi
          elif [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
            # Metadata unreadable — degrade to the historical guess
            # rather than silently declaring the ruleset non-matching.
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
  BYPASS_ACTORS=""
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
    # Rulesets have no `enforce_admins`. Their equivalent is the
    # bypass list: anyone in `bypass_actors` merges past this ruleset's
    # required checks, so a non-empty list is the ruleset-world
    # analogue of `enforce_admins: false`.
    THIS_BYPASS=$(echo "$DETAIL" | jq -r --arg rid "$rid" '
      .bypass_actors[]?
      | "ruleset \($rid): actor_type=\(.actor_type // "?") actor_id=\(.actor_id // "?") bypass_mode=\(.bypass_mode // "?")"
    ' 2>/dev/null)
    if [ -n "$THIS_BYPASS" ]; then
      if [ -n "$BYPASS_ACTORS" ]; then
        BYPASS_ACTORS="$BYPASS_ACTORS
$THIS_BYPASS"
      else
        BYPASS_ACTORS="$THIS_BYPASS"
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

# Two independent posture questions are answered below: are the canonical
# checks required, and (when asked) can an admin merge past them anyway.
# Both are reported in one run — a repo that fixes the first and not the
# second is still not enforcing anything, and finding that out a week
# later is exactly the latency #774 exists to remove.
GAPS=0

MISSING=()
for check in "${CANONICAL_REQUIRED_CHECKS[@]}"; do
  if ! echo "$REQUIRED_CHECKS" | grep -Fxq "$check"; then
    MISSING+=("$check")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  GAPS=1
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
  echo ""
fi

# Admin-bypass posture. Required checks are only as strong as the set of
# people who cannot skip them: classic protection lets every repo admin
# "merge without waiting for requirements" unless `enforce_admins` is on,
# and a ruleset lets everyone in `bypass_actors` do the same. ADR 0002
# requires the closed posture on the hub because #427/#428 were both
# admin merges, so a hub that lists all five checks and leaves this open
# must not read as PASS.
if [ "$REQUIRE_ADMIN_ENFORCEMENT" -eq 1 ]; then
  if [ "$USE_RULESETS" -eq 1 ]; then
    if [ -n "$BYPASS_ACTORS" ]; then
      GAPS=1
      echo "FAIL: the ruleset(s) governing $BRANCH on $REPO grant bypass actors, so the"
      echo "      required checks above are skippable:"
      printf '%s\n' "$BYPASS_ACTORS" | sed 's/^/  ✗ /'
      echo ""
      echo "Fix: Settings → Rules → the ruleset governing '$BRANCH' → Bypass list →"
      echo "remove every actor. A bypass entry is the ruleset-world equivalent of"
      echo "classic protection's 'enforce_admins: false'."
      echo ""
    else
      echo "Admin enforcement: OK — no bypass actors on the ruleset(s) governing $BRANCH."
    fi
  else
    ENFORCE_ADMINS=$(echo "$PROT_BODY" | jq -r '.enforce_admins.enabled // false' 2>/dev/null)
    if [ "$ENFORCE_ADMINS" != "true" ]; then
      GAPS=1
      echo "FAIL: enforce_admins is not enabled on $REPO@$BRANCH, so a repository admin"
      echo "      can merge past every required check above ('merge without waiting for"
      echo "      requirements'). The two escapes that motivated the merge-clearance"
      echo "      gate (#427/#428) were both admin merges."
      echo ""
      echo "Fix: Settings → Branches → Branch protection rule for '$BRANCH'"
      echo "→ tick 'Do not allow bypassing the above settings'."
      echo ""
    else
      echo "Admin enforcement: OK — enforce_admins is enabled on $BRANCH."
    fi
  fi
fi

if [ "$GAPS" -eq 0 ]; then
  echo "PASS: all canonical mergepath checks are required."
  exit 0
fi
exit 3
