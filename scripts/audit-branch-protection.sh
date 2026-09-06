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
#   `GET /repos/{owner}/{repo}` and then handed to the child audit via
#   `--default-branch` so the child never repeats the lookup. A fleet run
#   must not assume every repo
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
#     1 — bad arguments or a missing prerequisite: yq, a missing manifest,
#         a manifest whose schema `version:` this reader does not support,
#         an unresolvable hub repo, or an unwritable --summary-file (the
#         summary is what the rollup issue is built from, so a run that
#         cannot persist it must not return a verdict)
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
#   404 (no classic protection — rulesets are then the only possible
#   source) so that running the audit under a reviewer identity does not
#   produce a false "PR merges are completely unprotected" verdict. If you
#   hit exit 2 with an auth-scope diagnostic, re-run with an author/admin
#   token.
#
# Unknown is never a verdict:
#   Two ruleset facts are read from payloads that may not answer. A
#   `~DEFAULT_BRANCH` condition on a repo whose metadata cannot be read,
#   audited on a branch the historical main/master guess does not cover,
#   exits 2 rather than dropping the ruleset (which would report the
#   branch as unprotected). Likewise a ruleset detail payload that
#   answers neither `bypass_actors` (as an ARRAY) nor
#   `current_user_can_bypass` (as a recognised value, from a confirmed
#   repository admin) exits 2 under `--require-admin-enforcement` rather
#   than counting an absent or non-array field as an empty bypass list.
#   The same rule covers the ruleset INVENTORY: where the union is
#   load-bearing, an unreadable `/rulesets` list exits 2 rather than
#   reporting the classic-only picture as drift, because a missing
#   canonical check may be supplied by a ruleset this run could not see.
#
# Effective protection is a UNION:
#   GitHub enforces classic branch protection and every applicable ruleset
#   at the same time, so the effective required-check list on a branch is
#   the union of the two — the same reason
#   scripts/merge-clearance-gate.sh's enforcement probe unions them. Both
#   surfaces are therefore read, and a canonical check counts wherever it
#   comes from. The one exception is an optimisation, not a semantic: when
#   classic protection alone already establishes the clean posture the
#   ruleset call is skipped, because a ruleset can only ADD requirements
#   and a ruleset bypass weakens only its own rules.
#
# Ruleset enforcement:
#   Only rulesets whose `enforcement` is `active` are credited with
#   requiring a check. `evaluate` reports rule
#   outcomes without blocking a merge and `disabled` does nothing at all,
#   so counting either would report PASS on a branch nothing gates. An
#   absent or unreadable value is treated the same way, which errs toward
#   reporting drift — the safe direction for a protection audit.
#
# Admin-enforcement (--require-admin-enforcement), read-only by design:
#   GitHub returns a ruleset's `bypass_actors` list ONLY to a caller with
#   write access to that ruleset. This audit is deliberately provisioned
#   read-only (`Administration:read`), so on a ruleset payload that list
#   is normally absent — and requiring it would strand the hub at exit 2
#   forever. Admin bypass is therefore read from `current_user_can_bypass`,
#   which read-only callers DO receive, after confirming from
#   `GET /repos/{owner}/{repo}` `.permissions.admin` that the auditing
#   identity is a repository admin. Under rulesets nobody bypasses
#   implicitly, so `never` from a confirmed admin is genuine evidence the
#   admin role is not in the bypass list. `bypass_actors` is still used
#   wherever it IS returned, because it also catches a bypass actor that
#   is not the auditing identity; the narrower read is a fallback, never
#   a silent "no bypass". See ADR 0002 for why the token stays read-only.
#
#   A required status check is bypassable by a repository admin unless
#   classic protection sets `enforce_admins: true`. Under rulesets the
#   equivalent question is asked per CHECK, not per repo: a bypass entry
#   weakens only the ruleset granting it, so a canonical check counts as
#   skippable only when every ENFORCING ruleset requiring that check also
#   grants a bypass. A bypass on a ruleset that requires no canonical
#   check — or on one whose checks a no-bypass ruleset also requires —
#   leaves the gate intact and is not reported. ADR 0002 originally
#   required that posture on the HUB specifically, because the two escapes
#   that motivated the merge-clearance gate (#427/#428) were both admin
#   merges. The owner declined that recommendation on 2026-08-28: an admin
#   bypass is retained fleet-wide as the escape hatch for a CI or provider
#   outage, after a rate-limited gate stranded a fully reviewed PR (#1121).
#   `--fleet` therefore passes this flag for NO repo, and an unconstrained
#   admin is not drift anywhere. The flag remains available for ad-hoc
#   audits that want to ask the question; nothing scheduled passes it.

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

# A context name alone does not identify the workflow allowed to satisfy it.
# Count only checks pinned to mergepath's trusted GitHub Actions producer.
# The override name matches merge-clearance-gate.sh for GHES installations,
# where the github-actions app id differs from github.com's 15368.
MERGE_CLEARANCE_EXPECTED_APP_ID="${MERGE_CLEARANCE_EXPECTED_APP_ID:-15368}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# `.mergepath-sync.yml` schema version this reader understands. The
# manifest documents version bumps as INCOMPATIBLE changes and requires
# readers to refuse unknown ones; scripts/sync-to-downstream.sh and
# scripts/project-doc-sync.sh pin the same way.
SUPPORTED_MANIFEST_VERSION=1

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
# Caller-supplied answer to "what is this repo's default branch". Set by
# --fleet on each child audit, which has already resolved it from
# GET /repos/{owner}/{repo}; see --default-branch below.
DEFAULT_BRANCH_HINT=""

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
    --default-branch)
      # Seeds this repo's default branch instead of re-reading it from
      # GET /repos/{owner}/{repo}. --fleet passes the value it already
      # resolved: without it every child audit repeats its parent's
      # metadata call, and a transient failure of that redundant lookup
      # would leave `~DEFAULT_BRANCH` unresolvable on a repo whose
      # default is neither main nor master — turning an infrastructure
      # failure into a DRIFT verdict.
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --default-branch requires a non-empty value" >&2; exit 1
      fi
      DEFAULT_BRANCH_HINT="$2"; shift 2 ;;
    --require-admin-enforcement)
      # Off by default everywhere. ADR 0002 originally asked for this on
      # the hub (#427/#428 were both admin merges); the owner declined that
      # recommendation on 2026-08-28, so no scheduled path passes it. Kept
      # for ad-hoc audits that want to ask the bypass question directly.
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
                                          [--default-branch <name>]
                                          [--require-admin-enforcement]
       scripts/audit-branch-protection.sh --fleet [--branch <name>]
                                          [--hub-repo owner/name]
                                          [--manifest <path>]
                                          [--summary-file <path>]

Verifies branch protection on \$BRANCH (default: main) requires the
canonical mergepath-shipped status checks:
  ${CANONICAL_REQUIRED_CHECKS[*]}

A check counts whether it comes from classic branch protection or from a
ruleset that governs \$BRANCH: GitHub enforces both surfaces at once, so
the effective required-check list is their UNION.

--require-admin-enforcement additionally requires that admins cannot
bypass those checks. A check is skippable only when EVERY source
requiring it also allows a bypass — classic protection without
\`enforce_admins: true\`, or a ruleset with a non-empty bypass-actor
array (or, where GitHub withholds that array from a read-only caller,
\`current_user_can_bypass\` other than \`never\` reported to a confirmed
repository admin). A ruleset payload that answers neither bypass
question exits 2. NOT passed by --fleet for any repo: the owner
declined ADR 0002's hub requirement on 2026-08-28 in favour of keeping
an admin escape hatch fleet-wide. Available for ad-hoc audits.

--default-branch supplies this repo's default branch instead of reading
it from GET /repos/{owner}/{repo}; only \`~DEFAULT_BRANCH\` ruleset
conditions consult it. --fleet passes the value it already resolved.

Exit 3 if any canonical check is not required (PR-merge gating gap).
Exit 2 on gh API auth/scope failures (use an author/admin PAT).

--fleet audits the hub plus every \`.consumers[].repo\` in
.mergepath-sync.yml and prints a per-repo verdict table. Each repo is
audited on its OWN default branch unless --branch is passed explicitly,
and every repo, hub included, is audited WITHOUT
--require-admin-enforcement. The manifest's
schema \`version:\` must be $SUPPORTED_MANIFEST_VERSION. Same exit-code shape: 0 all clean,
1 usage/prerequisite (including an unwritable --summary-file), 2 at least
one repo unreadable (infrastructure, NOT drift), 3 drift on at least one
readable repo.
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────
# Default-branch resolution
# ─────────────────────────────────────────────────────────────────────
#
# `gh api ... --jq <expr>` writes the HTTP error BODY to STDOUT, not to
# stderr, and exits non-zero. Verified against live gh:
#
#   $ gh api repos/<owner>/<missing> --jq .default_branch
#   stdout: {"message":"Not Found",...,"status":"404"}
#   stderr: gh: Not Found (HTTP 404)
#   rc=1
#
# So the shape `x="$(gh api ... --jq ... 2>/dev/null || true)"` followed
# by a test for empty does NOT detect a failed read: `2>/dev/null`
# discards only the human-readable line, `|| true` discards the status,
# and `x` is left holding a JSON blob that every downstream emptiness
# guard accepts as a branch name. Both call sites below therefore capture
# the EXIT STATUS instead of inferring failure from empty output.
#
# This predicate is the second line of defence behind that status check:
# it rejects anything that could not be a branch name, so a payload that
# ever leaks through with a zero status still reads as "unresolved"
# rather than being audited as a branch. It is fail-closed — an
# unresolved default branch becomes an infrastructure ERROR (exit 2),
# never a PASS or a DRIFT verdict.
#
# The rules below are `git check-ref-format`'s rules for `refs/heads/<v>`,
# NOT a narrower ASCII allow-list. An earlier version demanded
# `^[A-Za-z0-9][A-Za-z0-9._/+-]*$`, which rejects branch names git accepts
# — `feat#2`, `feat%2Ftwo`, `fix!urgent`, any non-ASCII name — and a repo
# whose default branch is one of those became a permanent fleet ERROR
# (exit 2, no drift issue maintained) purely because the audit could not
# spell it. Availability lost for no safety gained: the JSON error bodies
# this guard exists to catch are excluded by git's OWN rules, because
# every gh error body is a JSON object and so contains a `:` — which git
# forbids in a ref — plus, on any pretty-printed or multi-line payload,
# whitespace and control characters git also forbids. Whether a given
# name is accepted here is asserted against the real `git check-ref-format`
# binary in tests/test_audit_branch_protection.sh.
#
# Two exclusions go beyond git, both deliberate and both documented there:
#   - the literal string `null`, which is what `--jq` prints for an absent
#     field (a repo whose default branch is genuinely named `null` is not
#     a case worth admitting at the cost of that signal);
#   - a leading `{`, which is a legal ref character but cannot begin any
#     answer this predicate should accept, and is the first byte of every
#     JSON object gh could leak.
# BEGIN looks_like_branch_name — extracted VERBATIM and cross-checked
# against the real `git check-ref-format` by
# tests/test_audit_branch_protection.sh. Keep the markers.
looks_like_branch_name() {
  local v="$1"
  [ -n "$v" ] || return 1
  [ "$v" != "null" ] || return 1
  case "$v" in '{'*) return 1 ;; esac

  # git check-ref-format(1), rule 4: no ASCII control character (including
  # DEL), space, `~`, `^` or `:` anywhere.
  case "$v" in *[[:cntrl:]]*|*' '*|*'~'*|*'^'*|*:*) return 1 ;; esac
  # Rule 5: no `?`, `*` or `[`. Rule 10: no `\`.
  case "$v" in *'?'*|*'*'*|*'['*|*'\'*) return 1 ;; esac
  # Rule 3: no `..` anywhere.
  case "$v" in *..*) return 1 ;; esac
  # Rule 8: no `@{`. (Rule 9, "not the single character @", is about the
  # WHOLE refname: `git check-ref-format refs/heads/@` succeeds and git
  # will create a branch called `@`, so it is not excluded here.)
  case "$v" in *'@{'*) return 1 ;; esac
  # Rule 6: no leading or trailing `/`, and no `//`.
  case "$v" in /*|*/|*//*) return 1 ;; esac
  # Rule 7: no trailing `.`.
  case "$v" in *.) return 1 ;; esac
  # Rule 1: no slash-separated component may begin with `.` or end with
  # `.lock`.
  local IFS=/ comp
  for comp in $v; do
    case "$comp" in .*|*.lock) return 1 ;; esac
  done
  # Not a check-ref-format rule, but `git branch` cannot create a name
  # beginning with `-` (it parses as an option), so GitHub cannot report
  # one as a default branch.
  case "$v" in -*) return 1 ;; esac
  return 0
}
# END looks_like_branch_name

# Percent-encode a branch name for interpolation into an API path.
#
# `gh api` passes the path through verbatim, so a branch name carrying a
# character that is legal in a git ref but structural in a URL corrupts
# the request rather than 404ing honestly: `#` truncates everything after
# it as a fragment, and a stray `%` is read as the start of an escape.
# Slashes are the one thing that must NOT be encoded — GitHub's
# `/branches/{branch}/protection` route accepts a hierarchical branch
# name with literal separators — so each segment is encoded on its own
# and the segments rejoined. jq's `@uri` does the per-segment work
# (correct for UTF-8, which a hand-rolled byte loop is not), and jq is
# already a hard dependency of this script.
#
# The definition moved to scripts/lib/branch-requirements.sh (#1063, landed
# with #1064): gate (a) needs the same encoding, and this script is hub-only,
# so a propagated caller could not reuse the copy that lived here. This
# wrapper keeps the local call sites reading the same as before.
#
# Hard-required. A silent fallback to an unencoded path is precisely the
# failure this function exists to prevent — it would read a DIFFERENT branch
# and report its protection as this one.
if [ ! -r "$SCRIPT_DIR/lib/branch-requirements.sh" ]; then
  echo "ERROR: branch-requirements helper missing: $SCRIPT_DIR/lib/branch-requirements.sh" >&2
  exit 2
fi
# shellcheck source=lib/branch-requirements.sh
. "$SCRIPT_DIR/lib/branch-requirements.sh"

urlencode_branch_path() {
  br_urlencode_branch_path "$1"
}

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

  # Refuse a manifest schema this reader does not understand. The
  # manifest reserves `version:` bumps for INCOMPATIBLE changes — "the
  # script refuses to run against an unknown version so old scripts
  # can't silently misinterpret a newer manifest" — and both existing
  # readers (scripts/sync-to-downstream.sh, scripts/project-doc-sync.sh)
  # already gate on it. Without the check a v2 manifest that still
  # happens to parse as `.consumers[].repo` would yield a fleet verdict
  # over a consumer list this auditor no longer reads correctly, and the
  # scheduled run would report that partial audit as a fleet-wide
  # all-clear. A missing key reads as yq's `null` and is rejected too.
  local manifest_version
  if ! manifest_version=$(yq -r '.version' "$manifest" 2>&1); then
    echo "Error: could not read .version from $manifest:" >&2
    printf '%s\n' "$manifest_version" | sed 's/^/  /' >&2
    return 1
  fi
  if [ "$manifest_version" != "$SUPPORTED_MANIFEST_VERSION" ]; then
    echo "Error: $manifest declares schema version '$manifest_version'; this auditor" >&2
    echo "       supports version $SUPPORTED_MANIFEST_VERSION only. A version bump means an INCOMPATIBLE" >&2
    echo "       change, so the consumer list may no longer mean what this script" >&2
    echo "       reads. Refusing to emit a fleet verdict over a manifest it cannot" >&2
    echo "       interpret — upgrade scripts/audit-branch-protection.sh." >&2
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
  # Extra argv handed to the child audit. Carries the default-branch fact
  # this loop established, so the child never re-issues the same
  # GET /repos/{owner}/{repo}; see the --default-branch flag.
  local -a child_args=()
  tmp="$(mktemp "${TMPDIR:-/tmp}/fleet-bp-audit.XXXXXX")"

  for r in "${repos[@]}"; do
    rc=0

    # Resolve this repo's default branch unless the caller pinned one.
    # A repo whose metadata cannot be read is an ERROR (infrastructure),
    # never a PASS: guessing `main` here would audit a branch that may
    # not exist and report the resulting "unprotected" verdict as drift.
    child_args=()
    if [ "$BRANCH_EXPLICIT" -eq 1 ]; then
      repo_branch="$BRANCH"
    else
      # Capture the STATUS — never infer failure from empty output. On an
      # HTTP error `gh api --jq` prints the JSON error body to stdout, so
      # the old `|| true` + emptiness test accepted
      # `{"message":"Server Error","status":"500"}` as this repo's branch
      # name, handed it to the child via --default-branch below, and
      # reported the resulting audit as a PASS — a broken fleet presenting
      # as a clean one, which closes the rollup issue.
      if ! repo_branch="$(gh api "repos/$r" --jq '.default_branch' 2>/dev/null)"; then
        repo_branch=""
      fi
      if ! looks_like_branch_name "$repo_branch"; then
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
      # This loop just established the repo's default branch
      # authoritatively. Hand that fact to the child instead of letting
      # it repeat the same metadata call: the repeat is both wasteful
      # (one extra request per repo per ~DEFAULT_BRANCH ruleset pattern
      # would otherwise be N+1 across the fleet) and unsafe. A repo whose
      # default is neither `main` nor `master` and whose protection comes
      # from a `~DEFAULT_BRANCH` ruleset would, on a transient failure of
      # that redundant lookup, fall past the main/master guess, count no
      # ruleset as targeting the branch, and return DRIFT — reporting an
      # infrastructure failure as a protection gap in the rollup issue.
      child_args+=(--default-branch "$repo_branch")
    fi

    # The owner declined ADR 0002's hub-only enforce_admins requirement on
    # 2026-08-28 and set the posture the other way: an admin merge-without-
    # waiting escape is retained on EVERY repo, hub included, so that a CI
    # or provider outage cannot strand a fully reviewed PR. `--fleet` no
    # longer passes --require-admin-enforcement for any repo, so the hub is
    # audited exactly like a consumer. The flag itself is kept for ad-hoc
    # use; nothing in the scheduled path passes it. See ADR 0002 Exceptions.
    "$audit_cmd" --repo "$r" --branch "$repo_branch" "${child_args[@]}" >"$tmp" 2>&1 || rc=$?
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

  # The summary file is the artifact the scheduled workflow embeds
  # VERBATIM in the rollup issue body (the verbose stdout is truncated),
  # so an unwritten summary is a rollup built from nothing — or, worse,
  # from a stale file left by an earlier run. `set -e` cannot catch the
  # failure: fleet_audit is invoked on the left of `||` to capture its
  # status, which disables errexit for the whole function, so the failed
  # redirection would fall through to a 0/3 return with the requested
  # file absent. Checked explicitly and reported as a prerequisite
  # failure (exit 1), which the workflow handles by failing the job
  # WITHOUT touching the rollup issue.
  if [ -n "$SUMMARY_FILE" ]; then
    if ! printf '%s\n' "$summary_block" >"$SUMMARY_FILE"; then
      echo "" >&2
      echo "Error: could not write the fleet summary to '$SUMMARY_FILE'." >&2
      echo "       The per-repo verdict table above is the payload the rollup" >&2
      echo "       issue is built from, so a run that cannot persist it must not" >&2
      echo "       return a verdict — a stale or missing summary would be" >&2
      echo "       published as though it described this run." >&2
      echo "       Check the path exists, is writable, and its parent directory" >&2
      echo "       was created before the audit ran." >&2
      return 1
    fi
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
if [ "$FLEET" -eq 1 ] && [ -n "$DEFAULT_BRANCH_HINT" ]; then
  echo "Error: --default-branch is a per-repo fact that --fleet resolves for each repo itself" >&2
  echo "       and would be silently ignored here. Drop it, or audit one repo with --repo." >&2
  exit 1
fi
if [ "$FLEET" -eq 1 ] && [ "$REQUIRE_ADMIN_ENFORCEMENT" -eq 1 ]; then
  echo "Error: --require-admin-enforcement is not passed by --fleet for any repo" >&2
  echo "       (the owner declined ADR 0002's hub requirement on 2026-08-28) and would be" >&2
  echo "       silently ignored here. Drop it, or audit one repo with --repo." >&2
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
# path never pay for the extra call. Leaves REPO_DEFAULT_BRANCH empty
# when the metadata read fails, which callers treat as "unknown".
#
# The answer is published in a GLOBAL rather than on stdout, and callers
# invoke this as a plain command (never `$(repo_default_branch)`): a
# command substitution runs the body in a subshell, where the memo below
# is written and then discarded with the subshell. That is what made the
# cache a no-op before — every `~DEFAULT_BRANCH` pattern re-issued
# `GET /repos/{owner}/{repo}` (fleet-wide, once per pattern per ruleset),
# and a transient failure on a later call could downgrade an already
# resolved answer to the main/master guess and flip the ruleset-target
# verdict.
#
# A caller that already knows the answer seeds it with --default-branch,
# which pre-satisfies the memo so no metadata request is made at all.
REPO_DEFAULT_BRANCH=""
REPO_DEFAULT_BRANCH_RESOLVED=0
if [ -n "$DEFAULT_BRANCH_HINT" ]; then
  REPO_DEFAULT_BRANCH="$DEFAULT_BRANCH_HINT"
  REPO_DEFAULT_BRANCH_RESOLVED=1
fi
resolve_repo_default_branch() {
  if [ "$REPO_DEFAULT_BRANCH_RESOLVED" -eq 0 ]; then
    REPO_DEFAULT_BRANCH_RESOLVED=1
    # Status-checked, then shape-checked — see looks_like_branch_name.
    # A failed read must leave this EMPTY so `~DEFAULT_BRANCH` resolution
    # takes the "unknown" path (main/master guess, else exit 2). Letting
    # the JSON error body through instead made the branch compare unequal
    # to every real name, dropping the only ruleset protecting the repo
    # and reporting the failed read as DRIFT.
    if ! REPO_DEFAULT_BRANCH="$(gh api "repos/$REPO" --jq '.default_branch' 2>/dev/null)"; then
      REPO_DEFAULT_BRANCH=""
    fi
    if ! looks_like_branch_name "$REPO_DEFAULT_BRANCH"; then
      REPO_DEFAULT_BRANCH=""
    fi
  fi
  return 0
}

# Is the identity behind the active token a repository ADMIN on $REPO?
#
# Memoised in a GLOBAL and invoked as a plain command (never
# `$(resolve_repo_admin_permission)`) for the same reason as
# resolve_repo_default_branch above: a command substitution would write
# the memo in a subshell and throw it away, re-issuing the request once
# per ruleset.
#
# Only the read-only admin-bypass fallback consults this, so the request
# is made only when a ruleset is read at all, only under
# --require-admin-enforcement, and only when `bypass_actors` was withheld
# — consumer audits and every classic-protection audit pay nothing.
#
# Tri-state, and the third state is load-bearing: "yes" / "no" / ""
# (unknown, the read failed). "Unknown" must never collapse into either
# answer — the caller treats it as an unreadable repo and exits 2.
# `.permissions` is the authenticated user's own permission set, so this
# needs no scope beyond the read access the audit already has.
REPO_ADMIN_PERMISSION=""
REPO_ADMIN_PERMISSION_RESOLVED=0
resolve_repo_admin_permission() {
  if [ "$REPO_ADMIN_PERMISSION_RESOLVED" -eq 0 ]; then
    REPO_ADMIN_PERMISSION_RESOLVED=1
    local raw=""
    # Status-checked first, then value-checked. A failed read writes the
    # HTTP error BODY to stdout (see the note in tests/…: that is real gh
    # behaviour), so a status-blind read would hand a JSON blob to the
    # comparison below and quietly land in the "not admin" branch.
    if raw="$(gh api "repos/$REPO" --jq '.permissions.admin' 2>/dev/null)"; then
      case "$raw" in
        true)  REPO_ADMIN_PERMISSION="yes" ;;
        false) REPO_ADMIN_PERMISSION="no" ;;
        *)     REPO_ADMIN_PERMISSION="" ;;
      esac
    else
      REPO_ADMIN_PERMISSION=""
    fi
  fi
  return 0
}

# Fetch the branch-protection rules. Two endpoints are relevant:
#   1. /branches/{branch}/protection — classic protection rules
#   2. /rulesets — newer rulesets (the modern way)
#
# They are not alternatives. GitHub enforces classic protection and every
# applicable ruleset SIMULTANEOUSLY, and the effective requirement on a
# branch is the UNION of the two lists — the repository's own enforcement
# probe (scripts/merge-clearance-gate.sh, merge_clearance_check_enforced)
# unions them for exactly that reason, having verified live that
# mergepath@main's classic contexts do not appear on the ruleset surface
# at all. Reading (1) and stopping there whenever it answered 200 filed a
# repo whose fifth canonical check comes from a ruleset as DRIFT and
# refreshed the weekly rollup issue for it every Monday.
#
# So (1) is read first, and (2) is read as well WHENEVER it could change
# the verdict. It cannot when classic protection alone already establishes
# the clean posture — rulesets only ADD requirements, and a ruleset bypass
# weakens only that ruleset's own rules, so nothing in (2) can unmake a
# classic requirement or make a non-bypassable one skippable. Skipping the
# call in that one case keeps a fully protected repo from being turned
# into an exit-2 infrastructure failure by a flaky second request.
#
# On 403 (auth/scope failure) bail with a diagnostic — falling through to
# rulesets would produce a false "unprotected" verdict because the
# rulesets endpoint may also be denied or empty under the same auth.
#
# Implementation: `gh api -i` includes the HTTP status line, which lets
# us inspect the status code directly. We split headers from body via a
# blank-line marker, then extract the HTTP/x.y status code from the
# first line of the headers.
BRANCH_PATH="$(urlencode_branch_path "$BRANCH")"
PROT_RAW=$(gh api -i "repos/$REPO/branches/$BRANCH_PATH/protection" 2>&1) || PROT_API_RC=$?
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

HAVE_CLASSIC=0
case "$PROT_STATUS" in
  200)
    # Classic protection present. Its contexts are one half of the union;
    # the ruleset half is still read below unless classic alone settles
    # the verdict.
    HAVE_CLASSIC=1
    ;;
  404)
    # No classic protection configured. Rulesets are the only possible
    # source of protection here, so "no matching ruleset" really does mean
    # "unprotected" on this path (and only on this path).
    echo "Note: classic branch protection not configured on $BRANCH — checking rulesets instead."
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

       Refusing to fall through to a ruleset-only read because that would
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

# ─────────────────────────────────────────────────────────────────────
# Effective required checks = classic contexts ∪ ruleset contexts
# ─────────────────────────────────────────────────────────────────────
#
# One TAB-separated "<context>\t<source>\t<0|1 source allows a bypass>"
# row per (protection source, required context) pairing, where <source>
# is `classic` or a ruleset id. The admin-enforcement block below needs
# that provenance: a bypass applies ONLY to the source that grants it, so
# "some source allows a bypass" is not evidence that any canonical check
# is skippable.
CHECK_SOURCES=""
# "<source>\t<human-readable bypass entry>" rows, reported only for the
# sources a canonical check actually depends on.
BYPASS_LINES=""
# Set when at least one ruleset's bypass posture was decided from
# `current_user_can_bypass` because GitHub withheld `bypass_actors`.
# That evidence covers the auditing admin identity, not every possible
# bypass actor, so a clean verdict resting on it must say which
# question it answered rather than claim the stronger one.
BYPASS_EVIDENCE_IDENTITY_ONLY=0
# Field separator for the accumulators above. Spelled as an escape
# rather than an inline literal so the delimiter cannot be lost to a
# whitespace-normalising edit — check names contain spaces, so a
# space-delimited row would be unsplittable.
TAB=$'\t'

REQUIRED_CHECKS=""

# Record one protection source's required contexts: adds them to the
# effective union AND files a provenance row per context.
add_required_checks() {  # <contexts, one per line> <source> <bypassable 0|1>
  local ctxs="$1" source="$2" bypassable="$3" ctx
  [ -n "$ctxs" ] || return 0
  if [ -n "$REQUIRED_CHECKS" ]; then
    REQUIRED_CHECKS="$REQUIRED_CHECKS
$ctxs"
  else
    REQUIRED_CHECKS="$ctxs"
  fi
  while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    CHECK_SOURCES="${CHECK_SOURCES}${ctx}${TAB}${source}${TAB}${bypassable}
"
  done <<<"$ctxs"
}

# Does this context list carry every canonical check?
canonical_checks_all_present() {  # <contexts, one per line>
  local have="$1" check
  for check in "${CANONICAL_REQUIRED_CHECKS[@]}"; do
    printf '%s\n' "$have" | grep -Fxq "$check" || return 1
  done
  return 0
}

# ── Classic half ─────────────────────────────────────────────────────
CLASSIC_CHECKS=""
CLASSIC_BYPASSABLE=1
if [ "$HAVE_CLASSIC" -eq 1 ]; then
  CLASSIC_CHECKS=$(echo "$PROT_BODY" | jq -r --arg app "$MERGE_CLEARANCE_EXPECTED_APP_ID" '
    .required_status_checks.checks[]?
    | select((.app_id | tostring) == $app)
    | .context // empty
  ')
  # Classic protection lets every repository admin "merge without waiting
  # for requirements" unless `enforce_admins` is on, so that flag IS the
  # classic bypass list: off means every admin bypasses every classic
  # requirement, on means nobody does.
  CLASSIC_ENFORCE_ADMINS=$(echo "$PROT_BODY" | jq -r '.enforce_admins.enabled // false' 2>/dev/null)
  if [ "$CLASSIC_ENFORCE_ADMINS" = "true" ]; then
    CLASSIC_BYPASSABLE=0
  else
    CLASSIC_BYPASSABLE=1
    BYPASS_LINES="${BYPASS_LINES}classic${TAB}classic protection: enforce_admins is not enabled, so every repository admin can 'merge without waiting for requirements'
"
  fi
  add_required_checks "$CLASSIC_CHECKS" "classic" "$CLASSIC_BYPASSABLE"
fi

# ── Is the ruleset half load-bearing? ────────────────────────────────
#
# Always, except when classic protection alone already establishes the
# clean posture. Rulesets can only ADD requirements and a ruleset bypass
# weakens only that ruleset's own rules, so once classic requires every
# canonical check — and, under --require-admin-enforcement, nobody can
# bypass classic — no ruleset payload can change the verdict. Skipping
# the call there is what stops a flaky second request turning a fully
# protected repo into an exit-2 infrastructure failure.
SCAN_RULESETS=1
if [ "$HAVE_CLASSIC" -eq 1 ] \
   && canonical_checks_all_present "$CLASSIC_CHECKS" \
   && { [ "$REQUIRE_ADMIN_ENFORCEMENT" -eq 0 ] || [ "$CLASSIC_BYPASSABLE" -eq 0 ]; }; then
  SCAN_RULESETS=0
fi

# Ruleset id whose conditions are currently being evaluated. A global
# because match_ref_pat names it in the `~DEFAULT_BRANCH` diagnostic and
# must stay a plain command (see below), not a subshell.
CURRENT_RULESET_ID=""

# The audited branch as a fully-qualified ref: `conditions.ref_name`
# patterns are matched against this, not against the bare branch name.
BRANCH_REF="refs/heads/$BRANCH"

# Does a GitHub ruleset ref-name pattern match $2?
#
# GitHub matches `conditions.ref_name` patterns with Ruby's `File.fnmatch`
# under the `File::FNM_PATHNAME` flag — stated outright in the ruleset
# docs: "Because GitHub uses the File::FNM_PATHNAME flag for the
# File.fnmatch syntax, the `*` wildcard does not match directory
# separators (/). For example, qa/* will match all branches beginning
# with qa/ and containing a single slash, but will not match qa/foo/bar."
# Bash's own `[[ str == pat ]]` has no such rule — its `*` crosses `/`
# freely — so comparing with it credited `refs/heads/release/*` with
# governing `release/a/b` (a false PASS on an ungoverned branch) and, in
# an `exclude` list, disqualified a ruleset that does govern it (a false
# DRIFT).
#
# Invoke the reference implementation GitHub documents. A Bash
# reimplementation matched the common `*`, `?`, range and `**/` cases but
# interpreted POSIX bracket classes such as `[[:digit:]]`; Ruby treats that
# spelling differently. That disagreement can credit a ruleset with governing
# a branch it does not govern, which is a false PASS. Exact semantics are worth
# the tiny subprocess cost in a weekly protection audit.
#
# BEGIN fnmatch — the function below is extracted VERBATIM by
# tests/test_audit_branch_protection.sh and differentially tested against
# `File.fnmatch(pat, ref, File::FNM_PATHNAME)` in real Ruby. Keep the
# markers.
fnmatch_pathname() {  # <pattern> <ref>
  if ! command -v ruby >/dev/null 2>&1; then
    echo "ERROR: ruby is required to evaluate GitHub ruleset ref patterns exactly" >&2
    exit 2
  fi
  ruby -e 'exit(File.fnmatch(ARGV[0], ARGV[1], File::FNM_PATHNAME) ? 0 : 1)' -- "$1" "$2"
}
# END fnmatch

# Pattern-matches a SINGLE `conditions.ref_name` pattern against the
# audited branch ref. Answers through its EXIT STATUS (0 = match,
# 1 = miss) so callers can invoke it directly in an `if` instead of in a
# `$(...)`; that keeps `~DEFAULT_BRANCH` resolution in THIS shell, which
# is what makes resolve_repo_default_branch's one-shot memo survive from
# one pattern to the next. Used by BOTH the include scan (a match means
# "this ruleset could apply") and the exclude scan (a match means "this
# ruleset does NOT apply to this branch"). #285 r2 — nathanpayne-codex
# Phase 4b finding: the original implementation only consulted
# `.conditions.ref_name.include`, so a ruleset that included `~ALL` but
# excluded `main` was incorrectly counted as protecting main.
#
# Supported forms:
#   ~DEFAULT_BRANCH  — matches when BRANCH really is this repo's default
#                      branch, resolved once from GET /repos/{o}/{r}. The
#                      earlier implementation assumed main/master was the
#                      default, which mis-answered both ways on a repo
#                      with a renamed default: a `trunk` audit saw "no
#                      ruleset targets trunk" (false DRIFT) and a `main`
#                      audit on a trunk-defaulted repo counted a ruleset
#                      that does not govern main (false PASS). The
#                      main/master guess survives only as a fallback for
#                      when the metadata read itself fails.
#   ~ALL             — matches every branch
#   anything else    — a full ref, matched with GitHub's fnmatch
#                      semantics (see fnmatch_pathname). A literal ref
#                      name is just a pattern with no metacharacters:
#                      git forbids `*`, `?`, `[` and `\` in a ref, so a
#                      literal can never be misread as a glob.
match_ref_pat() {
  local pat="$1"
  case "$pat" in
    "~ALL")
      return 0 ;;
    "~DEFAULT_BRANCH")
      resolve_repo_default_branch
      if [ -n "$REPO_DEFAULT_BRANCH" ]; then
        # Authoritative answer from the repo's own metadata (or from
        # the --default-branch fact the caller already established).
        if [ "$BRANCH" = "$REPO_DEFAULT_BRANCH" ]; then
          return 0
        fi
      elif [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
        # Metadata unreadable — degrade to the historical guess
        # rather than silently declaring the ruleset non-matching.
        return 0
      else
        # Metadata unreadable AND the audited branch is outside what
        # the main/master guess can speak to. Whether this ruleset
        # governs the branch is now genuinely UNKNOWN, and returning
        # "no match" would drop the only ruleset protecting the repo
        # and report the resulting "nothing targets $BRANCH" as
        # DRIFT — filing an infrastructure failure in the rollup
        # issue as a protection gap. Same rule the fleet loop already
        # applies to its own unresolvable default branches.
        cat >&2 <<EOF
ERROR: ruleset $CURRENT_RULESET_ID targets '~DEFAULT_BRANCH' on $REPO, but this repo's
       default branch could not be read from GET /repos/$REPO, and the
       audited branch '$BRANCH' is neither 'main' nor 'master' — so
       whether the ruleset governs it is unknown.

       Refusing to treat the ruleset as non-matching: that would report
       '$BRANCH' as unprotected (drift) on the strength of a failed
       metadata read. Treating the repo as unreadable (infrastructure
       failure) instead.

       Re-run with a token that can read repository metadata, or pass
       the branch fact directly:
         scripts/audit-branch-protection.sh --repo $REPO --branch $BRANCH \\
           --default-branch <this repo's default branch>
EOF
        exit 2
      fi
      ;;
    *)
      if fnmatch_pathname "$pat" "$BRANCH_REF"; then
        return 0
      fi
      ;;
  esac
  return 1
}

# ── Ruleset half ─────────────────────────────────────────────────────
MATCHING_IDS=""
if [ "$SCAN_RULESETS" -eq 1 ]; then
  # Step A: compute the set of rulesets that ACTUALLY target the
  # audited branch. We need each ruleset's full definition to inspect
  # its conditions.ref_name.include array, so list IDs first then
  # fetch each one. Listing returns summaries without conditions.
  #
  # --paginate is mandatory, not a nicety: an unpaginated list read
  # returns exactly ONE page (30 items by default), so on a repo with
  # more rulesets than that the applicable required-check ruleset can sit
  # on page 2, be silently omitted here, and have its checks reported as
  # missing protection — refreshing the drift issue every week over a
  # repo that is fully gated. `--jq` is applied per page and its output
  # concatenated, which is why the filter runs here rather than over a
  # slurped array (pages are separate JSON documents).
  #
  # Status-checked, then shape-checked: `gh api --jq` prints the HTTP
  # error BODY to stdout, so the ids are validated as integers before
  # being interpolated into a URL — the same second-line defence
  # looks_like_branch_name gives the default-branch read.
  if ! RULESET_IDS="$(gh api --paginate "repos/$REPO/rulesets?per_page=100" \
      --jq '.[] | select(.target == "branch") | .id' 2>&1)"; then
    echo "Could not fetch rulesets for $REPO: $RULESET_IDS" >&2; exit 2
  fi
  for rid in $RULESET_IDS; do
    if ! [[ "$rid" =~ ^[0-9]+$ ]]; then
      echo "Unexpected ruleset id '$rid' from repos/$REPO/rulesets — refusing to" >&2
      echo "       interpolate it into an API path. Treating the repo as unreadable." >&2
      exit 2
    fi
  done

  for rid in $RULESET_IDS; do
    CURRENT_RULESET_ID="$rid"
    DETAIL=$(gh api "repos/$REPO/rulesets/$rid" 2>&1) || {
      echo "Could not fetch ruleset $rid: $DETAIL" >&2; exit 2
    }
    INCLUDES=$(echo "$DETAIL" | jq -r '.conditions.ref_name.include[]?' 2>/dev/null)
    [ -z "$INCLUDES" ] && continue

    # Pass 1: any include pattern must match.
    MATCHED=0
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      if match_ref_pat "$pat"; then
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
        if match_ref_pat "$pat"; then
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

  if [ -z "$MATCHING_IDS" ] && [ "$HAVE_CLASSIC" -eq 0 ]; then
    echo "FAIL: no rulesets target $BRANCH on $REPO. PR merges are completely unprotected."
    exit 3
  fi

  # Step B: extract required status checks ONLY from the rulesets that
  # target the audited branch AND actually enforce. Previously this
  # collected from ALL branch-target rulesets regardless of include
  # match (#285).
  for rid in $MATCHING_IDS; do
    CURRENT_RULESET_ID="$rid"
    DETAIL=$(gh api "repos/$REPO/rulesets/$rid" 2>&1) || {
      echo "Could not fetch ruleset $rid: $DETAIL" >&2; exit 2
    }
    THIS_CHECKS=$(echo "$DETAIL" | jq -r --arg app "$MERGE_CLEARANCE_EXPECTED_APP_ID" '
      .rules[]?
      | select(.type == "required_status_checks")
      | .parameters.required_status_checks[]?
      | select((.integration_id | tostring) == $app)
      | .context // empty
    ' 2>/dev/null)

    # A ruleset gates merges only while its `enforcement` is `active`.
    # `evaluate` reports rule outcomes without blocking anything and
    # `disabled` does nothing at all, so crediting either with a
    # canonical required check would report PASS on a branch nothing
    # actually gates. An unreadable or absent value is treated as NOT
    # enforcing: that errs toward reporting drift, which is the safe
    # direction for a protection audit.
    RS_ENFORCEMENT=$(echo "$DETAIL" | jq -r '.enforcement // ""' 2>/dev/null || true)
    if [ "$RS_ENFORCEMENT" != "active" ]; then
      if [ -n "$THIS_CHECKS" ]; then
        echo "Note: ruleset $rid targets $BRANCH but its enforcement is '${RS_ENFORCEMENT:-unknown}', not 'active' — its required status checks do not gate merges and are not counted."
      fi
      continue
    fi

    # Does this ruleset require any CANONICAL check? Only then can its
    # bypass posture make a canonical gate skippable, so only then is
    # that posture interrogated at all. Without the guard, an unrelated
    # ruleset (a formatting rule, a project build check) whose payload
    # answers neither bypass question would exit 2 under
    # --require-admin-enforcement on a repo whose canonical gates are
    # provably intact — an infrastructure failure manufactured out of a
    # ruleset that cannot affect the verdict.
    RS_CANONICAL_RELEVANT=0
    if [ -n "$THIS_CHECKS" ]; then
      for check in "${CANONICAL_REQUIRED_CHECKS[@]}"; do
        if printf '%s\n' "$THIS_CHECKS" | grep -Fxq "$check"; then
          RS_CANONICAL_RELEVANT=1
          break
        fi
      done
    fi

    # Rulesets have no `enforce_admins`. Their equivalent is the
    # bypass list: anyone in `bypass_actors` merges past THIS ruleset's
    # rules, so a non-empty list is the ruleset-world analogue of
    # `enforce_admins: false` — but only for the checks this same
    # ruleset requires.
    #
    # Two payload shapes can answer that question, and which one arrives
    # is decided by the TOKEN, not by the ruleset:
    #
    #   1. `bypass_actors` — the full list, and AUTHORITATIVE: it names
    #      every actor, including teams, apps and deploy keys that are
    #      not the auditing identity. GitHub returns it only to a caller
    #      with WRITE access to the ruleset ("To prevent leaking
    #      sensitive information, the bypass_actors property is only
    #      returned if the user making the API request has write access
    #      to the ruleset" — REST docs, GET /repos/{o}/{r}/rulesets/{id}).
    #
    #   2. `current_user_can_bypass` — "never" | "pull_requests_only" |
    #      "always", for the identity making the request. Returned to
    #      READ-ONLY callers. Verified live against four repositories
    #      whose rulesets this machine's token cannot write — cli/cli,
    #      home-assistant/core, github/docs, vercel/next.js: every one
    #      answered HTTP 200 with a complete `rules`/`conditions`/
    #      `enforcement` payload, `current_user_can_bypass` PRESENT and
    #      `bypass_actors` ABSENT, across Repository-, Organization- and
    #      Enterprise-sourced rulesets alike.
    #
    # This audit is provisioned read-only on purpose (see the scope note
    # at the head of .github/workflows/branch-protection-audit.yml), so
    # shape 2 is what the scheduled run actually receives. Demanding
    # shape 1 made the hub ruleset path exit 2 permanently — never clean,
    # never drift, indistinguishable from a broken audit — and buying it
    # back would mean giving a weekly, unattended, fleet-wide credential
    # `Administration: write`: the power to rewrite the very protection
    # it exists to audit. ADR 0002 declines that trade.
    #
    # Shape 2 answers a NARROWER question than shape 1 — "can the
    # auditing identity bypass this ruleset", not "is the bypass list
    # empty" — so it is only evidence about admins when that identity IS
    # a repository admin, which is verified before the answer is
    # trusted. Under rulesets nobody bypasses implicitly (unlike classic
    # protection, where every admin does until `enforce_admins` is set),
    # so `never` from a confirmed admin is real evidence that the admin
    # role is absent from the bypass list — the #427/#428 question ADR
    # 0002 actually asks. Shape 1 is still preferred wherever it is
    # offered, because it also catches a non-admin bypass actor.
    #
    # What is still never conflated: `.bypass_actors[]?` yields nothing
    # for a genuinely empty list AND for an absent key, a null, or any
    # non-array value, so emptiness is read only from a real ARRAY. A
    # payload with neither a readable array nor a usable
    # `current_user_can_bypass`, or one whose admin standing cannot be
    # established, exits 2. Unknown never becomes "no bypass".
    RS_BYPASS_TYPE=$(echo "$DETAIL" | jq -r '.bypass_actors | type' 2>/dev/null || true)
    RS_BYPASSED=0
    THIS_BYPASS=""
    if [ "$RS_BYPASS_TYPE" = "array" ]; then
      THIS_BYPASS=$(echo "$DETAIL" | jq -r --arg rid "$rid" '
        .bypass_actors[]?
        | "ruleset \($rid): actor_type=\(.actor_type // "?") actor_id=\(.actor_id // "?") bypass_mode=\(.bypass_mode // "?")"
      ' 2>/dev/null)
      if [ -n "$THIS_BYPASS" ]; then
        RS_BYPASSED=1
      fi
    elif [ "$REQUIRE_ADMIN_ENFORCEMENT" -eq 1 ] && [ "$RS_CANONICAL_RELEVANT" -eq 1 ]; then
      # Read-only fallback. Only reached under the flag, because that is
      # the only mode in which the answer is consulted at all (ADR 0002
      # asks it of the hub, not of consumers) — an unreadable field on a
      # consumer audit that never reads it is not a reason to fail a run.
      #
      # Type-checked, not `// ""`: a null or a non-string would otherwise
      # fall through the string comparisons below as an empty value.
      RS_CAN_BYPASS=$(echo "$DETAIL" | jq -r '
        if (.current_user_can_bypass | type) == "string"
        then .current_user_can_bypass else "" end
      ' 2>/dev/null || true)
      case "$RS_CAN_BYPASS" in
        never|pull_requests_only|always) ;;
        *)
          cat >&2 <<EOF
ERROR: ruleset $rid governs $REPO@$BRANCH and requires at least one canonical
       check, but its detail payload answers neither of the two questions
       that settle admin bypass: it carries no readable 'bypass_actors'
       array (jq type: ${RS_BYPASS_TYPE:-unreadable}) and no recognised
       'current_user_can_bypass' value (got: '${RS_CAN_BYPASS:-<absent>}',
       expected never|pull_requests_only|always).

       --require-admin-enforcement asks whether a canonical required
       check is skippable. An absent, null or unrecognised field is NOT
       evidence that nobody can bypass — crediting it as one would let
       the hub pass admin-enforcement auditing with no proof its gates
       hold, and publish that as a fleet-wide all-clear.

       Treating the repo as unreadable (infrastructure failure) instead.
EOF
          exit 2
          ;;
      esac
      resolve_repo_admin_permission
      if [ "$REPO_ADMIN_PERMISSION" != "yes" ]; then
        cat >&2 <<EOF
ERROR: ruleset $rid governs $REPO@$BRANCH and withheld its 'bypass_actors'
       list (GitHub returns it only to callers with write access to the
       ruleset), so admin bypass has to be read from
       'current_user_can_bypass' — which describes the AUDITING IDENTITY,
       not the bypass list.

       That is evidence about admins only if the auditing identity is a
       repository admin, and this run could not establish that:
       GET /repos/$REPO '.permissions.admin' returned
       '${REPO_ADMIN_PERMISSION:-unreadable}'.

       A non-admin identity reports 'never' whether or not admins can
       bypass, so accepting it here would turn "we could not tell" into
       an all-clear.

       Re-run with an identity that is an admin on $REPO — the audit's
       own BRANCH_PROTECTION_AUDIT_TOKEN is provisioned that way:
         GH_TOKEN="\$OP_PREFLIGHT_AUTHOR_PAT" scripts/audit-branch-protection.sh \\
           --repo $REPO --branch $BRANCH --require-admin-enforcement
EOF
        exit 2
      fi
      BYPASS_EVIDENCE_IDENTITY_ONLY=1
      if [ "$RS_CAN_BYPASS" != "never" ]; then
        RS_BYPASSED=1
        THIS_BYPASS="ruleset $rid: the auditing admin identity can bypass this ruleset (current_user_can_bypass=$RS_CAN_BYPASS; the full bypass_actors list is not readable under read-only auth)"
      fi
    fi
    if [ -n "$THIS_BYPASS" ]; then
      while IFS= read -r bline; do
        [ -z "$bline" ] && continue
        BYPASS_LINES="${BYPASS_LINES}${rid}${TAB}${bline}
"
      done <<<"$THIS_BYPASS"
    fi
    add_required_checks "$THIS_CHECKS" "$rid" "$RS_BYPASSED"
  done
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
# Deduplicated, order preserved: a context required by BOTH classic
# protection and a ruleset appears once here. Its provenance is not lost —
# CHECK_SOURCES keeps one row per (source, context) pairing, which is what
# the admin-bypass analysis below reads.
echo "$REQUIRED_CHECKS" | awk 'NF && !seen[$0]++' | sed 's/^/  ✓ /'
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
# argued for the closed posture on the hub because #427/#428 were both
# admin merges; the owner declined that on 2026-08-28 and kept the escape
# fleet-wide, so this block runs only when a caller asks for it
# explicitly. Nothing scheduled does. See ADR 0002 Exceptions.
if [ "$REQUIRE_ADMIN_ENFORCEMENT" -eq 1 ]; then
  # One analysis over BOTH protection surfaces, because they are enforced
  # together. A bypass weakens only the source that grants it, so a
  # canonical check is skippable only when EVERY source requiring it also
  # allows a bypass:
  #   - classic protection allows one for every requirement it carries
  #     unless `enforce_admins` is on;
  #   - a ruleset allows one for its own requirements when its bypass list
  #     is non-empty (or the confirmed auditing admin can bypass it).
  # One no-bypass source requiring the check keeps it mandatory for
  # everybody. That is why the two surfaces cannot be judged separately:
  # a repo whose classic rule lists all five checks with enforce_admins
  # OFF is fully gated if an unbypassable ruleset requires the same five,
  # and the old per-surface branches reported it as DRIFT. Symmetrically,
  # a bypass on a source that requires no canonical check (a formatting
  # rule, a non-canonical build check) cannot make a canonical gate
  # skippable at all.
  #
  # Deliberately conservative where the answer is genuinely uncertain:
  # a check required only by bypassed sources is reported even though
  # the individual actor sets may not overlap, because an audit that
  # under-reports a skippable gate recreates the #774 blind spot,
  # whereas an over-report is a visible, checkable claim.
  SKIPPABLE_CHECKS=""
  CULPRIT_IDS=""
  for check in "${CANONICAL_REQUIRED_CHECKS[@]}"; do
    check_rows=$(printf '%s' "$CHECK_SOURCES" | awk -F'\t' -v c="$check" '$1 == c')
    # Not required by any enforcing source — already counted as a
    # missing canonical check above; not an admin-bypass finding.
    [ -z "$check_rows" ] && continue
    if printf '%s\n' "$check_rows" \
      | awk -F'\t' '$3 == "0" { found = 1 } END { if (found) exit 0; exit 1 }'; then
      continue
    fi
    SKIPPABLE_CHECKS="${SKIPPABLE_CHECKS}${check}
"
    CULPRIT_IDS="$CULPRIT_IDS $(printf '%s\n' "$check_rows" | cut -f2 | tr '\n' ' ')"
  done

  if [ -n "$SKIPPABLE_CHECKS" ]; then
    GAPS=1
    echo "FAIL: every protection source that requires the following canonical check(s)"
    echo "      on $REPO@$BRANCH also allows a bypass, so the check(s) are skippable:"
    printf '%s' "$SKIPPABLE_CHECKS" | sed 's/^/  ✗ /'
    echo ""
    echo "      Bypass entries responsible:"
    for cid in $(printf '%s' "$CULPRIT_IDS" | tr ' ' '\n' | sort -u); do
      [ -z "$cid" ] && continue
      printf '%s' "$BYPASS_LINES" | awk -F'\t' -v r="$cid" '$1 == r { print "  ✗ " $2 }'
    done
    echo ""
    echo "The two escapes that motivated the merge-clearance gate (#427/#428) were"
    echo "both admin merges, which is the case ADR 0002 made for the closed posture."
    echo "That recommendation was DECLINED by the owner on 2026-08-28: the escape is"
    echo "retained fleet-wide so that a CI or provider outage cannot strand a fully"
    echo "reviewed PR. You passed --require-admin-enforcement explicitly, so this is"
    echo "the answer to that question, not fleet drift."
    echo ""
    echo "Fix (classic protection): Settings → Branches → Branch protection rule for"
    echo "'$BRANCH' → tick 'Do not allow bypassing the above settings' (enforce_admins)."
    echo "Fix (rulesets): Settings → Rules → the ruleset(s) named above → Bypass list →"
    echo "remove every actor. A bypass entry is the ruleset-world equivalent of"
    echo "classic protection's 'enforce_admins: false'."
    echo ""
  elif [ "$BYPASS_EVIDENCE_IDENTITY_ONLY" -eq 1 ]; then
    # Say which question the evidence answered. GitHub withheld the
    # bypass list from this read-only caller, so the proof is "a
    # confirmed repository admin cannot bypass" — the ADR 0002
    # question — not "the bypass list is empty".
    echo "Admin enforcement: OK — a confirmed repository admin cannot skip a canonical required check on $BRANCH."
    echo "      (GitHub withheld 'bypass_actors' from this read-only token, so this rests on"
    echo "      'current_user_can_bypass: never'; a bypass actor that is neither the auditing"
    echo "      identity nor the admin role would not be visible to a read-only audit.)"
  elif [ "$HAVE_CLASSIC" -eq 1 ] && [ "$CLASSIC_BYPASSABLE" -eq 0 ] && [ "$SCAN_RULESETS" -eq 0 ]; then
    echo "Admin enforcement: OK — enforce_admins is enabled on $BRANCH."
  else
    echo "Admin enforcement: OK — no bypass actor can skip a canonical required check on $BRANCH."
  fi
fi

if [ "$GAPS" -eq 0 ]; then
  echo "PASS: all canonical mergepath checks are required."
  exit 0
fi
exit 3
