#!/usr/bin/env bash
# scripts/merge-clearance-gate.sh — HEAD-pinned merge-clearance gate
#
# Read-only required-status-check gate that fails CLOSED at merge time
# when a PR's clearance condition is not satisfied ON THE CURRENT HEAD.
# Never merges, labels, or comments.
#
# Context — nathanjohnpayne/mergepath#427 + #428. Two merge-gate escapes
# slipped past the enforcement layer and were caught only by the WEEKLY
# retroactive audit (pr-audit.yml), a week after merge:
#
#   #427 (matchline#245): a Dependabot dev-dependencies group bump merged
#        with NO reviewer-identity APPROVED review on the merge HEAD. The
#        dependabot-auto-merge.yml approval is transient — a rebase push
#        dismisses it (or it was never re-posted on the final SHA) — and a
#        human then merged the approved-but-unmerged PR. Nothing failed
#        closed.
#   #428 (nathanpaynedotcom#405): an over-threshold (needs-external-review)
#        PR merged with no APPROVED CLI review and no Codex review on the
#        merge HEAD. Clearance was evaluated on an EARLIER HEAD, the
#        removable-label proxy went stale, and the only required checks
#        (Label Gate green-but-stale, Codex P1 vacuously green) did not
#        represent clearance on the merge HEAD.
#
# Shared root cause: clearance was enforced via a MUTABLE proxy (a
# dismissable review, a removable label) plus a weekly audit — never as a
# HEAD-pinned required status check that re-evaluates on every push and
# fails closed. This script is that check. Modeled on the proven
# codex-p1-gate.sh / codex-p1-gate.yml pattern (required check +
# scheduled sweep + trusted default-branch checkout).
#
# Usage:
#   scripts/merge-clearance-gate.sh [PR_NUMBER] [REPO]
#   scripts/merge-clearance-gate.sh                  # env-only mode
#
# Arguments (positional take precedence; env fallbacks support the
# scheduled-sweep / workflow_dispatch invocation shape):
#   PR_NUMBER  Required (positional or $PR_NUMBER env). Integer.
#   REPO       Optional. "owner/repo". Falls back to $REPO env, then to
#              the current repo via `gh repo view`.
#
# Environment:
#   GH_TOKEN   Required. Needs pull_requests:read (+ the read scopes
#              codex-review-check.sh needs for the external-review path).
#              The #772 enforcement probe (reached only from
#              --derive-rate-limit-protection) reads two ADDITIONAL surfaces
#              whose access pull_requests:read does NOT imply: GraphQL
#              `ref.refUpdateRule` (classic branch protection — null for a
#              viewer without push access) and REST
#              `repos/{owner}/{repo}/rules/branches/{branch}` (rulesets —
#              needs repo metadata read). A plain write-scoped classic PAT,
#              which is what agent-review.yml runs this query under, reads
#              both. A fine-grained PAT scoped to pull-requests only still
#              satisfies the line above but gets null/403 on BOTH: the probe
#              then reports "not enforced" (the conservative direction, so
#              nothing unsafe happens) and arm 1 is permanently unavailable on
#              that repo — every answer comes from the arm-2 current-head
#              clearance probe. That state is indistinguishable from a
#              genuinely unprotected base branch in the true/false output, so
#              grep the job log for `enforcement probe:` lines to tell them
#              apart before concluding a repo is unprotected.
#   MERGE_CLEARANCE_CODEX_CHECK_BIN
#              Optional. Path to codex-review-check.sh. Defaults to the
#              sibling script next to this one. Tests override it to a
#              stub so the external-review dispatch + exit-code mapping
#              can be exercised without re-deriving codex-review-check's
#              full behavior.
#
# What it enforces, by PR class (evaluated on pr.head.sha):
#
#   Dependabot PR (author == 'dependabot[bot]'):
#     Gated by `dependabot.reviewer_gate.enabled` (default false; true in
#     mergepath). When enabled, BLOCKS unless a reviewer identity in
#     `available_reviewers` (≠ PR author) has a latest-state APPROVED
#     review whose commit_id == HEAD. This is the HEAD-pinned form of
#     pr-audit.yml Check 2's Dependabot path — a transient approval
#     dismissed on a rebase push re-blocks on the new HEAD.
#
#   External-review PR:
#     Gated by `codex.external_review_gate.enabled` (default false; true
#     in mergepath). Applicability is DERIVED from the PR's intrinsic
#     properties — over `external_review_threshold` lines, OR a changed
#     file matching `external_review_paths`, OR the `needs-external-review`
#     label present — NOT from the label alone. (Trusting the label would
#     reopen the #428 stale-label race: after a push, this gate can run
#     before pr-review-policy.yml re-adds the label, and a label-only check
#     would false-clear on an uncleared HEAD. #429 Codex P1.) When it
#     applies, delegates to codex-review-check.sh — the SAME clearance
#     predicate (gate (b) reviewer APPROVED + gate (c) Codex /
#     Phase-4b-substitute on HEAD) the auto-clear workflow uses — so the
#     merge-time gate and the label-clear logic cannot drift. CI checking
#     (gate (a)) is skipped for this invocation because this gate is ITSELF
#     a required check; waiting on the full required-check rollup (which
#     includes this gate) would deadlock. CI green is enforced
#     independently by the other required checks. Verified propagation PRs
#     (trusted github-actions[bot] lane marker, label absent) are EXEMPT —
#     the pr-review-policy.yml lane already cleared them; re-deriving would
#     force them into Phase 4 and break the lane (#429 Codex round-2 P1).
#
#   Any other PR (under-threshold, non-Dependabot, or relevant knob off):
#     CLEAN PASS (exit 0). The gate is a no-op so it can be a required
#     check on every PR without blocking normal under-threshold merges.
#
# Exit codes (same contract as scripts/codex-p1-gate.sh):
#   0   Clearance satisfied (or gate not applicable / disabled).
#   1   Clearance NOT satisfied on the current HEAD — gate BLOCKS.
#   2   Usage / config / infrastructure error. Message on stderr.
#
# Design notes:
#   - Read-only. Only GETs against the GitHub API (plus a read-only
#     delegate to codex-review-check.sh on the external-review path).
#   - bash 3.2 portable; PATH-shimmable `gh` for tests (see
#     tests/test_merge_clearance_gate.sh).
#
# References:
#   - nathanjohnpayne/mergepath#427, #428 — this script
#   - scripts/codex-review-check.sh — the shared external-review predicate
#   - .github/workflows/pr-audit.yml Check 2 — the retroactive backstop
#   - scripts/codex-p1-gate.sh — the required-check pattern this mirrors

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- tool preflight ---------------------------------------------------------
# Fail with the documented config/usage code (2) if a hard dependency is
# missing, rather than dying mid-run with an opaque 127 that the workflow
# would map to a generic CI error (CodeRabbit ⚠️ on PR #429).
for _tool in gh jq awk; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$_tool' not found on PATH" >&2
    exit 2
  fi
done

# --- argument parsing -------------------------------------------------------

# --derive-external-requiredness (#620/#630): QUERY mode. Runs the same
# class dispatch + external-review applicability derivation as the gate and
# prints exactly `true` or `false` on stdout (exit 0) instead of evaluating
# clearance. `true` iff a NON-VACUOUS downstream CODEX/external *bot*-review
# gate protects this PR's CURRENT head: the external arm applies (intrinsic
# threshold / protected paths / label force-on). `false` when no such gate
# holds the merge until bot review: under threshold with no protected paths
# and no label, a lane-exempt verified head, external gate disabled, OR a
# Dependabot PR (its reviewer gate blocks on a reviewer-identity APPROVED,
# not on Codex — and Codex does not review Dependabot PRs, so it is never a
# bot-review gate; automated-4b P1). Every error keeps the die()/exit-2
# paths so callers MUST fail closed on nonzero. Retained as a narrow
# diagnostic/back-compat query for callers that need only intrinsic external
# applicability, not clearance. The production CodeRabbit rc=5 branch now uses
# --derive-rate-limit-protection below because Phase-4b-cleared protected PRs
# can be safe to auto-merge even after the removable label is gone (#713).
#
# --derive-rate-limit-protection (#713, tightened by #772): QUERY mode for
# agent-review.yml's CodeRabbit rc=5 branch. It prints `true` when a
# rate-limited PR is protected from bot-unreviewed auto-merge by either:
#   1. the merge-clearance external gate being ENFORCED — enabled in the
#      governing policy AND observably a required status check on the PR's
#      base branch (#772) — or
#   2. intrinsic external-review applicability plus an already-satisfied
#      current-head Codex/Phase-4b clearance predicate.
# Arm 1 previously asked only whether the gate was enabled in CONFIG. That is
# not evidence the gate can hold a merge: mergepath itself runs with the switch
# on while `Merge clearance gate` is absent from base-branch protection, so the
# query claimed protection on a repo where the gate blocks nothing. Enforcement
# that cannot be determined is treated as NOT enforced and falls through to arm
# 2, which is positive proof — so an undeterminable read costs availability, not
# safety.
# This keeps under-threshold stalls blocked while allowing the common
# Phase-4b timing case where the APPROVED review already removed
# `needs-external-review` before the auto-merge job re-checks CodeRabbit.
DERIVE_ONLY=false
RATE_LIMIT_PROTECTION_ONLY=false
_positional=()
for _arg in "$@"; do
  case "$_arg" in
    --derive-external-requiredness) DERIVE_ONLY=true ;;
    --derive-rate-limit-protection) RATE_LIMIT_PROTECTION_ONLY=true ;;
    *) _positional+=("$_arg") ;;
  esac
done
set -- ${_positional[@]+"${_positional[@]}"}

if [ "$DERIVE_ONLY" = "true" ] && [ "$RATE_LIMIT_PROTECTION_ONLY" = "true" ]; then
  echo "ERROR: choose only one query mode" >&2
  exit 2
fi

if [ $# -gt 2 ]; then
  echo "Usage: $0 [--derive-external-requiredness|--derive-rate-limit-protection] [PR_NUMBER] [REPO]" >&2
  echo "       PR_NUMBER and REPO may also be set via env." >&2
  exit 2
fi

PR_NUMBER=${1:-${PR_NUMBER:-}}
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PR_NUMBER required (positional arg or \$PR_NUMBER env)" >&2
  exit 2
fi
if ! echo "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
  echo "ERROR: PR_NUMBER must be an integer; got '$PR_NUMBER'" >&2
  exit 2
fi

REPO=${2:-${REPO:-}}
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  if [ -z "$REPO" ]; then
    echo "ERROR: could not detect current repo via 'gh repo view'. Pass REPO explicitly." >&2
    exit 2
  fi
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN is required. See REVIEW_POLICY.md § PAT lookup table." >&2
  exit 2
fi

# --- config readers ---------------------------------------------------------

CONFIG=".github/review-policy.yml"

# Scratch file for the PR-base review policy (#763; see the derivation block).
BASE_POLICY_TMP=""
# Policy source for every gating decision. Defaults to the trusted
# default-branch checkout and is redirected to the PR base tree only for a
# non-default base (see the #763 block after the PR metadata fetch).
POLICY_CONFIG="$CONFIG"
# shellcheck disable=SC2329  # invoked via the EXIT trap below
cleanup_base_policy() {
  [ -z "$BASE_POLICY_TMP" ] || rm -f "$BASE_POLICY_TMP"
}
trap cleanup_base_policy EXIT

# Read a scalar field nested two levels deep: `<block>:` `<sub>:` `<field>:`.
# Same state-machine awk pattern as codex-p1-gate.sh's
# codex_p1_gate_field, generalized over the top block + sub-block names so
# it serves both `dependabot.reviewer_gate.enabled` and
# `codex.external_review_gate.enabled`.
nested_field() {  # <top_block> <sub_block> <field>
  # NOTE: do not name an awk -v variable `sub` — it shadows awk's
  # built-in sub() used in the body. Use topkey/subkey/fldkey.
  local topkey=$1 subkey=$2 fldkey=$3
  [ -f "$CONFIG" ] || return 0
  awk -v topkey="$topkey" -v subkey="$subkey" -v fldkey="$fldkey" '
    $0 ~ "^" topkey ":" { in_top=1; in_sub=0; next }
    in_top && /^[^[:space:]#]/ { in_top=0; in_sub=0 }
    in_top && $1 == subkey":" { in_sub=1; next }
    in_sub && /^[[:space:]]{0,3}[^[:space:]#]/ { in_sub=0 }
    in_sub && $1 == fldkey":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      # Strip BOTH single and double quotes (#536): a single-quoted
      # scalar like `enabled: '"'"'true'"'"'` previously kept its quotes
      # and tripped the true|false validator (exit 2). \047 is the octal
      # escape for a single quote inside the awk character class, mirroring
      # codex-p1-gate.sh codex_field and the policy parsers in
      # check_workflow_parsers.
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$POLICY_CONFIG"
}

# Read the available_reviewers list (one login per line). Identical parser
# to scripts/codex-review-check.sh read_available_reviewers.
read_available_reviewers() {
  # $POLICY_CONFIG, not $CONFIG (#769): the reviewer allow-list must come from
  # the SAME policy as the gate-enable switch and the threshold. Reading it
  # from the default branch while the switch came from the base was the
  # half-threaded state the #767 review flagged.
  [ -f "$POLICY_CONFIG" ] || return 0
  awk '
    /^available_reviewers:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && /^ *-/ {print}
  ' "$POLICY_CONFIG" | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'
}

# --- logging helpers --------------------------------------------------------

log() {
  echo "[merge-clearance-gate] $*" >&2
}

die() {  # <code> <msg>
  local code=$1; shift
  echo "[merge-clearance-gate] ERROR: $*" >&2
  exit "$code"
}

block() {  # <reason>
  echo ""
  echo "Merge clearance: BLOCKED — $*"
  echo ""
  exit 1
}

clear_pass() {  # <reason>
  echo "Merge clearance: PASS — $*"
  exit 0
}

fetch_api_array() {  # <endpoint> <label>
  local endpoint=$1 label=$2 raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || die 2 "failed to fetch $label: $raw"
  echo "$raw" | jq -s 'add // []' 2>/dev/null \
    || die 2 "failed to flatten $label pagination output"
}

# --- merge-clearance required-check enforcement probe (#772) ----------------
#
# The required-status-check CONTEXT this gate reports. Branch protection and
# rulesets both key on the workflow JOB name, and
# .github/workflows/merge-clearance-gate.yml names that job `Merge clearance
# gate` (its scheduled-sweep and dispatch-recheck jobs POST check_runs under the
# same CHECK_NAME so every source resolves as one context).
# scripts/ci/check_merge_clearance_gate asserts that job name verbatim and
# scripts/audit-branch-protection.sh carries the same string in
# CANONICAL_REQUIRED_CHECKS, so this constant cannot drift from the workflow
# without CI saying so.
MERGE_CLEARANCE_CHECK_NAME="Merge clearance gate"

# The app that must PRODUCE the required check for it to count as proof.
# A context is just a string: a branch rule that requires
# `Merge clearance gate` from a different integration — or from ANY source —
# is satisfied by some other producer emitting that name, while this script
# would conclude the trusted Actions job is enforced (#772 r5 P1). Both
# surfaces carry the producer, so it is checkable: classic protection exposes
# `required_status_checks.checks[].app_id`, rulesets expose
# `parameters.required_status_checks[].integration_id`.
#
# 15368 is github.com's `github-actions` app. Verified live rather than looked
# up: every check run on this repo's head reports `app.slug=github-actions`
# with `app.id=15368`, and mergepath's own three required contexts are
# recorded under that same app_id. Overridable for GitHub Enterprise Server,
# where the id differs.
MERGE_CLEARANCE_EXPECTED_APP_ID="${MERGE_CLEARANCE_EXPECTED_APP_ID:-15368}"

# Positive proof that $MERGE_CLEARANCE_CHECK_NAME is an ENFORCED required
# status check on the PR's base branch. Returns 0 ONLY when the context is
# observed in a required-status-check list for $BASE_REF; returns 1 for
# everything else — definitively absent, unknown base ref, API failure, or an
# unparseable payload. "Undeterminable" is deliberately NOT distinguished from
# "absent": the only caller's next step is the positive-proof current-head
# clearance probe, so treating an unknown as not-enforced costs availability,
# never safety (#768's positive-proof rule). Prints nothing; every diagnostic
# goes to stderr via log() so the query's stdout stays exactly true/false.
#
# Why two surfaces, and why not the obvious REST endpoint: reading
# repos/{owner}/{repo}/branches/{branch}/protection[/required_status_checks]
# needs Administration:read and 404s for the write-scoped reviewer PAT this
# query runs under in agent-review.yml (verified live against
# nathanjohnpayne/mergepath). The two below are readable by a plain
# write-scoped token and together cover both protection models:
#   1. GraphQL ref.refUpdateRule.requiredStatusCheckContexts — CLASSIC branch
#      protection, which is what the whole fleet uses today.
#   2. REST repos/{owner}/{repo}/rules/branches/{branch} — repository RULESETS,
#      the modern model. Classic protection does NOT surface there: verified
#      live on mergepath@main, whose classic contexts are
#      ["Label Gate","Self-Review Required","lint"] while that endpoint returns
#      []. So neither surface alone is sufficient and the two lists are unioned.
# Both are scoped to rules enforced on the VIEWER, so bypass filtering can only
# HIDE a rule, never invent one — it can push this probe toward "not enforced"
# (the conservative direction) and never toward a false "enforced".
merge_clearance_check_enforced() {
  local owner name contexts="" out err rc parsed observed
  owner=${REPO%%/*}
  name=${REPO##*/}

  if [ -z "$BASE_REF" ]; then
    log "enforcement probe: PR base ref is unknown — treating '$MERGE_CLEARANCE_CHECK_NAME' as NOT enforced"
    return 1
  fi

  # errexit is suppressed inside a function called as an `if` condition, so an
  # unguarded mktemp failure would leave $err empty and turn every redirect
  # below into a confusing "no such file" — check it explicitly and take the
  # conservative branch instead.
  err=$(mktemp "${TMPDIR:-/tmp}/mcg-enforcement-err.XXXXXX" 2>/dev/null) || err=""
  if [ -z "$err" ]; then
    log "enforcement probe: could not create a scratch file for API diagnostics — treating '$MERGE_CLEARANCE_CHECK_NAME' as NOT enforced"
    return 1
  fi

  local base_ref_enc
  base_ref_enc=$(printf '%s' "$BASE_REF" | LC_ALL=C awk '
    BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c ~ /[A-Za-z0-9._~\/-]/) out = out c
        else out = out sprintf("%%%02X", ord[c])
      }
      printf "%s", out
    }')
  if [ -z "$base_ref_enc" ]; then
    log "enforcement probe: could not encode base ref '$BASE_REF' for the ruleset URL — treating '$MERGE_CLEARANCE_CHECK_NAME' as NOT enforced"
    rm -f "$err"
    return 1
  fi

  # Surface 1 — classic branch protection.
  set +e
  # shellcheck disable=SC2016  # $owner/$name/$qref are GraphQL variables, bound by the -f flags below
  out=$(gh api graphql \
    -f query='query($owner:String!,$name:String!,$qref:String!){repository(owner:$owner,name:$name){ref(qualifiedName:$qref){refUpdateRule{requiredStatusCheckContexts}}}}' \
    -f owner="$owner" -f name="$name" -f qref="refs/heads/$BASE_REF" 2>"$err")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    log "enforcement probe: classic branch-protection read failed on '$BASE_REF' (gh rc=$rc): $(tr '\n' ' ' <"$err")"
  else
    set +e
    parsed=$(printf '%s' "$out" \
      | jq -r '.data.repository.ref.refUpdateRule.requiredStatusCheckContexts // [] | .[]' 2>"$err")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      log "enforcement probe: could not parse the classic branch-protection response for '$BASE_REF': $(tr '\n' ' ' <"$err")"
    elif [ -n "$parsed" ]; then
      # A required context is not proof that the MERGING identity is bound by
      # it. Classic protection exempts repo admins unless `enforce_admins` is
      # on, and this probe runs under the reviewer/CI token while the final
      # `gh pr merge` runs under the author token — so a context merely
      # VISIBLE to the reviewer would let an admin author merge on a
      # downgraded rate-limit stall with no bot review. Same defect class as
      # the ruleset bypass_actors case below (#772 r3 P1).
      #
      # `enforce_admins` is exposed only on the admin-scoped REST endpoint;
      # GraphQL's refUpdateRule does not carry it (verified: it offers
      # requiredStatusCheckContexts / viewerCanPush / viewerAllowedToDismiss-
      # Reviews and nothing about admin exemption). That endpoint 404s for the
      # write-scoped reviewer PAT this query runs under, so on the normal CI
      # path enforcement is NOT provable here and the classic surface
      # contributes nothing — the probe falls through to arm 2's positive-proof
      # clearance check. Where the token IS admin-scoped, the read succeeds and
      # the classic arm still works. Availability degrades, safety does not.
      set +e
      prot_out=$(gh api "repos/$REPO/branches/$base_ref_enc/protection" 2>"$err")
      prot_rc=$?
      set -e
      if [ "$prot_rc" -ne 0 ]; then
        log "enforcement probe: classic protection lists required contexts on '$BASE_REF' but admin-exemption state is unreadable with this token (gh rc=$prot_rc) — not counting the classic surface: $(tr '\n' ' ' <"$err")"
      else
        set +e
        # Type-check rather than `// "unknown"`: jq's alternative operator
        # treats `false` as empty, so an explicit enforce_admins=false would
        # collapse into the undeterminable state. The verdict is the same
        # either way (classic surface not counted), but the two are different
        # facts — "admins are exempt" vs "we could not look" — and the
        # `enforcement probe:` log lines are what an operator greps to tell a
        # deliberately-unprotected base branch from a token-scope problem.
        enforce_admins=$(printf '%s' "$prot_out" \
          | jq -r 'if (.enforce_admins.enabled | type) == "boolean" then (.enforce_admins.enabled | tostring) else "unknown" end' 2>"$err")
        prot_rc=$?
        set -e
        if [ "$prot_rc" -ne 0 ] || [ "$enforce_admins" = "unknown" ]; then
          log "enforcement probe: could not determine enforce_admins on '$BASE_REF' — not counting the classic surface: $(tr '\n' ' ' <"$err")"
        elif [ "$enforce_admins" != "true" ]; then
          log "enforcement probe: classic protection on '$BASE_REF' requires contexts but enforce_admins=false, so an admin merger is not bound by them — not counting the classic surface"
        else
          # Producer check (#772 r5 P1). The same admin response carries
          # `required_status_checks.checks[] = {context, app_id}`, so the
          # producer is verifiable from a call already made. A context-only
          # match would accept the required check being satisfied by some
          # other app emitting that name.
          set +e
          # ANY matching entry with the trusted app is enough. Classic
          # protection may list the same context more than once under
          # different producers; taking `.[0]` would report not-enforced
          # whenever a foreign entry happened to sort first, even though the
          # expected producer IS explicitly required (#772 r6 P2).
          classic_app=$(printf '%s' "$prot_out" | jq -r --arg ctx "$MERGE_CLEARANCE_CHECK_NAME" --arg app "$MERGE_CLEARANCE_EXPECTED_APP_ID" '
            if (.required_status_checks.checks | type) == "array"
            then ([ .required_status_checks.checks[] | select(.context == $ctx) | .app_id | tostring ]) as $ids
                 | if   ($ids | length) == 0 then "absent"
                   elif ($ids | index($app)) then $app
                   else ($ids | join(","))
                   end
            else "unknown" end' 2>"$err")
          prot_rc=$?
          set -e
          if [ "$prot_rc" -ne 0 ] || [ "$classic_app" = "unknown" ]; then
            log "enforcement probe: classic protection on '$BASE_REF' does not expose per-check producer data (no checks[] array) — cannot prove '$MERGE_CLEARANCE_CHECK_NAME' comes from the trusted workflow; not counting the classic surface"
          elif [ "$classic_app" = "absent" ]; then
            log "enforcement probe: '$MERGE_CLEARANCE_CHECK_NAME' is not among the classic required checks on '$BASE_REF' — not counting the classic surface"
          elif [ "$classic_app" != "$MERGE_CLEARANCE_EXPECTED_APP_ID" ]; then
            log "enforcement probe: classic protection on '$BASE_REF' requires '$MERGE_CLEARANCE_CHECK_NAME' from app_id=$classic_app, not the expected $MERGE_CLEARANCE_EXPECTED_APP_ID — a same-named check from another producer is not proof; not counting the classic surface"
          else
            contexts="$contexts$parsed"$'\n'
          fi
        fi
      fi
    fi
  fi

  # Surface 2 — repository rulesets.
  #
  # --paginate is load-bearing: this endpoint pages at 30 applicable rules, and
  # stacked rulesets can push the `required_status_checks` rule carrying
  # $MERGE_CLEARANCE_CHECK_NAME onto page 2. A truncated first page is
  # INDISTINGUISHABLE from an absent rule — same empty match, same log line —
  # so the omission would silently and permanently disable arm 1 on such a repo
  # instead of announcing itself.
  #
  # fetch_api_array() (which also paginates) is deliberately NOT reused here:
  # it die()s with exit 2 on a failed fetch or flatten, which would turn an
  # unreadable rulesets endpoint into a hard failure of the entire query
  # instead of the conservative fall-through to arm 2 that this probe's
  # contract promises. Hence the local set +e / rc capture.
  #
  # --paginate emits one JSON array per page, so the filter slurps (`-s`) and
  # concatenates with `add`; `objects` keeps a non-object page element (an
  # error envelope on a partial-failure page) from hard-erroring the filter
  # mid-stream.
  #
  # $BASE_REF is percent-encoded before interpolation. A branch name is far
  # more permissive than a URL path segment: `#` truncates the request at a
  # fragment (querying `.../rules/branches/feat` for a base ref `feat#2`), `%`
  # can form an accidental escape, and `?` starts a query string — each
  # silently reads a DIFFERENT branch's rules, or none, and an empty result is
  # indistinguishable from "not enforced". On a ruleset-only repo the classic
  # GraphQL surface cannot compensate, so a genuinely enforced gate would be
  # reported unproven and the rate-limit path would block unnecessarily.
  # `/` is deliberately left RAW: GitHub addresses nested branch names
  # (`release/1.0`) with literal slashes in this endpoint's `{branch}`
  # parameter, so encoding it as %2F would break the common case to guard the
  # rare one (#772 r1 P2).
  set +e
  out=$(gh api --paginate "repos/$REPO/rules/branches/$base_ref_enc" 2>"$err")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    log "enforcement probe: ruleset read failed on '$BASE_REF' (gh rc=$rc): $(tr '\n' ' ' <"$err")"
  else
    # Only rules that carry OUR context matter, and each is kept only if its
    # owning ruleset provably constrains the identity that will merge.
    #
    # `rules/branches` filters to rules enforced on the REQUESTING identity —
    # here the CI reviewer token — but the account that runs the final
    # `gh pr merge` is the AUTHOR identity. A ruleset whose `bypass_actors`
    # lists that author therefore still appears in this response while not
    # constraining the merge at all, and counting it would reproduce the exact
    # defect this PR exists to remove: treating configuration as enforcement.
    # `bypass_actors` is not returned by this endpoint, so each candidate
    # ruleset is fetched and required to have NO bypass actors. A ruleset that
    # cannot be read, or that has any, is not proof — drop it and fall through
    # to arm 2 (#772 r2 P1).
    set +e
    # A rule counts only when it requires OUR context FROM the trusted app.
    # `integration_id` absent means the rule accepts the context from ANY
    # producer, so an untrusted workflow emitting that name would satisfy it —
    # not proof, and dropped here rather than trusted (#772 r5 P1).
    ruleset_ids=$(printf '%s' "$out" \
      | jq -r -s --arg ctx "$MERGE_CLEARANCE_CHECK_NAME" --arg app "$MERGE_CLEARANCE_EXPECTED_APP_ID" '
          add // []
          | [ .[]? | objects
              | select(.type == "required_status_checks")
              | select([ .parameters.required_status_checks[]?
                         | select(.context == $ctx)
                         | select((.integration_id | tostring) == $app) ] | length > 0)
              | .ruleset_id ]
          | map(select(. != null)) | unique | .[]' 2>"$err")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      log "enforcement probe: could not parse the ruleset response for '$BASE_REF': $(tr '\n' ' ' <"$err")"
    elif [ -n "$ruleset_ids" ]; then
      while IFS= read -r rs_id; do
        [ -n "$rs_id" ] || continue
        set +e
        rs_out=$(gh api "repos/$REPO/rulesets/$rs_id" 2>"$err")
        rs_rc=$?
        set -e
        if [ "$rs_rc" -ne 0 ]; then
          log "enforcement probe: ruleset $rs_id carries '$MERGE_CLEARANCE_CHECK_NAME' on '$BASE_REF' but could not be read for bypass actors (gh rc=$rs_rc) — not counting it: $(tr '\n' ' ' <"$err")"
          continue
        fi
        set +e
        # The key must be PRESENT and an ARRAY. `[ .bypass_actors[]? ] | length`
        # yields 0 for a genuinely empty list AND for an absent key or a null /
        # non-array value — so an unknown payload shape would have been recorded
        # as positive proof of "no bypass actors". That is the one direction
        # this probe must never move in; every other unknown here falls back
        # conservatively. Flagged independently by both reviewers.
        bypass_count=$(printf '%s' "$rs_out" \
          | jq -r 'if (.bypass_actors | type) == "array" then (.bypass_actors | length) else "unknown" end' 2>"$err")
        rs_rc=$?
        set -e
        # An empty or non-numeric count means the payload was not the ruleset
        # object we expected; that is not proof of zero bypass actors.
        if [ "$rs_rc" -ne 0 ] || ! [[ "$bypass_count" =~ ^[0-9]+$ ]]; then
          log "enforcement probe: could not read bypass actors for ruleset $rs_id (got '${bypass_count:-}') — not counting it: $(tr '\n' ' ' <"$err")"
        elif [ "$bypass_count" -gt 0 ]; then
          log "enforcement probe: ruleset $rs_id requires '$MERGE_CLEARANCE_CHECK_NAME' but declares $bypass_count bypass actor(s), so it does not provably constrain the merging identity — not counting it"
        else
          contexts="$contexts$MERGE_CLEARANCE_CHECK_NAME"$'\n'
        fi
      done <<EOF
$ruleset_ids
EOF
    fi
  fi

  rm -f "$err"

  if printf '%s' "$contexts" | grep -Fxq -- "$MERGE_CLEARANCE_CHECK_NAME"; then
    return 0
  fi
  # Render the observed contexts QUOTED and comma-separated. Every name this
  # probe compares against contains spaces — `Merge clearance gate`,
  # `Self-Review Required` — so a space-joined list is ambiguous exactly where
  # it matters: in `[Label Gate Self-Review Required lint]` a reader cannot
  # tell three contexts from five, nor whether `Merge clearance gate` is
  # present as one entry or only as fragments of its neighbours — which is
  # the one thing this log line exists to let an operator check.
  # awk (already required by the preflight) formats it; \047 is the octal
  # escape for a single quote, same idiom as nested_field above. NF skips the
  # blank line left by the trailing newline on $contexts.
  observed=$(printf '%s' "$contexts" | awk 'NF { printf "%s\047%s\047", sep, $0; sep=", " }' || true)
  log "enforcement probe: '$MERGE_CLEARANCE_CHECK_NAME' is NOT among the required status checks observable on base '$BASE_REF' (observed: [$observed])"
  return 1
}

# Propagation-lane exemption (#429), HEAD-PINNED. Returns 0 (true) iff a PR
# comment authored by github-actions[bot] carries the propagation-lane marker
# scoped to the CURRENT head SHA — i.e. `mergepath-propagation-lane
# verified-head=<HEAD_SHA>`. .github/workflows/pr-review-policy.yml posts that
# marker ONLY after mergepath@<sha>'s verify-propagation-pr.sh byte-confirms a
# faithful mirror AT THAT HEAD, and a PR author cannot post as
# github-actions[bot] — so it is a TRUSTED, head-scoped signal that the lane
# already exempted THIS head from external review (REVIEW_POLICY.md §
# Propagation PR review lane).
#
# Why head-pinned (Codex round-3 P1 + nathanpayne-codex CHANGES_REQUESTED on
# #429): an unscoped "was-ever-a-mirror" marker is posted once and survives a
# later divergent push. On the synchronize where this gate finishes before
# pr-review-policy.yml re-adds needs-external-review, an unscoped check would
# go GREEN on an unverified large/.github PR. Pinning the exemption to the
# current head SHA closes that race independently of label timing: a diverged
# (or merely newer-but-not-yet-verified) head has no matching marker, so the
# gate does NOT exempt it and falls through to threshold/paths derivation.
# A DIVERGED push never gets a marker at all (the lane's propagation_lane is
# false → it posts nothing for that head). A faithful re-push is briefly
# not-yet-exempt (fail-closed) until the lane posts the new head's marker and
# the next event / scheduled sweep re-evaluates.
#
# Without this exemption, deriving applicability from threshold/protected-paths
# would force verified propagation PRs — large by design, touching .github/**,
# AND carrying an `Authoring-Agent` stamp (so codex-review-check.sh's
# same-agent guard disqualifies their normal internal approval) — into Phase
# 4/Codex clearance, breaking the documented under-threshold lane.
#
# Marker contract is shared with pr-review-policy.yml — keep the
# `mergepath-propagation-lane verified-head=<sha>` form in sync.
# agent-review.yml's rc=5 branch consumes it indirectly through this
# script's --derive-external-requiredness query (#620).
lane_verified() {
  # Exit: 0 = marker present; 1 = definitively absent (fetch + parse OK, no
  # matching comment); 2 = INDETERMINATE (comments API fetch or JSON parse
  # failed). The full-gate callsite treats 1 and 2 alike — no exemption,
  # fail-safe, since external review can only be ADDED. The
  # The query modes MUST tell 2 apart (automated-4b round-5 P1): there
  # `true` is the UNSAFE value (it authorizes the rc=5 CodeRabbit
  # downgrade), and a verified propagation PR's real Merge clearance gate
  # is green via the exemption — so an unknowable marker state must fail
  # closed to the caller, not fall through to threshold derivation (which
  # would return true for a large propagation PR).
  local comments rc=0
  comments=$(gh api --paginate "repos/$REPO/issues/$PR_NUMBER/comments" 2>/dev/null | jq -s 'add // []' 2>/dev/null) || return 2
  # `|| rc=$?` keeps the capture correct under `set -e` regardless of call
  # context (jq -e: 0 = match, 1 = no match, >1 = parse error).
  echo "$comments" | jq -e --arg head "$HEAD_SHA" '
    any(.[]; (.user.login == "github-actions[bot]")
             and ((.body // "") | contains("mergepath-propagation-lane verified-head=" + $head)))
  ' >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if [ "$rc" -eq 1 ]; then return 1; fi
  return 2
}

# --- fetch PR metadata ------------------------------------------------------

log "PR $REPO#$PR_NUMBER — fetching metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) \
  || die 2 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
BASE_SHA=$(echo "$PR_JSON" | jq -r '.base.sha // ""')

# --- PR-base review policy (#763) -------------------------------------------
#
# Every policy decision this gate makes must be judged by the policy of the
# branch the PR TARGETS, not by this trusted default-branch checkout. That
# includes the gate-enable switches, not just threshold/paths: if the default
# branch has codex.external_review_gate.enabled:false while the PR base
# enables it, parsing the switch from the default branch makes the whole
# external arm vacuous and the required check passes a PR the base policy
# requires it to gate (Codex P1 on #767). So the base policy is resolved HERE,
# before any switch is read, and POLICY_CONFIG then feeds nested_field.
#
# SCOPED DELIBERATELY to non-default bases. When a PR targets the default
# branch — the overwhelming majority, including every propagation sync PR —
# the base policy IS the default-branch policy this job already has checked
# out, so there is nothing to fetch and behaviour is byte-identical to before.
# Restricting the call this way keeps a new contents-API dependency (and its
# rate-limit / token-scope exposure) off the path that every consumer PR takes,
# instead of making the whole fleet depend on an endpoint this gate never
# needed before.
#
# On a NON-default base the fetch is load-bearing, so a failure other than a
# confirmed 404 (a base predating the policy file) is an infrastructure error:
# die 2, exactly as this script already does for a failed PR-metadata fetch.
# Silently substituting the default-branch policy there is the bypass itself.
BASE_REF=$(echo "$PR_JSON" | jq -r '.base.ref // ""')
DEFAULT_BRANCH=$(echo "$PR_JSON" | jq -r '.base.repo.default_branch // ""')
RESOLVE_POLICY_BIN="${MERGE_CLEARANCE_WORKFLOW_DIR:-$SCRIPT_DIR/workflow}/resolve_base_policy.sh"
if [ ! -f "$RESOLVE_POLICY_BIN" ]; then
  # Broken install (the resolver ships with this gate via .mergepath-sync.yml).
  # Degrade ONLY where the degradation is provably a no-op — a PR targeting the
  # DEFAULT branch, where the checked-out config IS the governing policy. There,
  # a missing resolver changes nothing, and hard-failing would turn a mid-sync
  # consumer into a red required check for no safety gain.
  #
  # For a NON-DEFAULT base the same fallback is the unsafe downgrade this whole
  # change exists to prevent: the gate would evaluate the threshold, protected
  # paths, reviewer allow-list, and enable switches from a looser default-branch
  # policy and could clear a PR the base policy would block. That is an
  # infrastructure failure in a required merge gate — fail closed (Codex P1 on
  # #768). BASE_REF/DEFAULT_BRANCH come from PR_JSON, so this decision does not
  # itself need the resolver.
  # POSITIVE proof required, phrased as such: degrade only when both fields are
  # present AND equal. The earlier form tested `!=`, so EMPTY metadata — an
  # undeterminable base — fell through to the degrade branch, which is an
  # assumption, not proof (CodeRabbit Major on #768). Same rule the resolver
  # applies: "unknown" is not proof.
  if [ -z "$BASE_REF" ] || [ -z "$DEFAULT_BRANCH" ] || [ "$BASE_REF" != "$DEFAULT_BRANCH" ]; then
    echo "ERROR: policy resolver missing ($RESOLVE_POLICY_BIN) and this PR is not provably against the default branch (base='$BASE_REF' default='$DEFAULT_BRANCH') — refusing to evaluate it against the default-branch policy" >&2
    exit 2
  fi
  echo "WARNING: policy resolver missing ($RESOLVE_POLICY_BIN); PR provably targets the default branch, so the checked-out policy already governs" >&2
  RESOLVED_POLICY="$CONFIG"
  resolve_rc=0
else
# stdout is the policy PATH, stderr is diagnostics — keep them separate so a
# warning cannot be concatenated into the path (#715/#716 class).
RESOLVE_ERR=$(mktemp "${TMPDIR:-/tmp}/mcg-resolve-err.XXXXXX")
set +e
RESOLVED_POLICY=$(bash "$RESOLVE_POLICY_BIN" \
  --repo "$REPO" --base-ref "$BASE_REF" --base-sha "$BASE_SHA" \
  --default-branch "$DEFAULT_BRANCH" --default-config "$CONFIG" 2>"$RESOLVE_ERR")
resolve_rc=$?
set -e
RESOLVE_MSG=$(cat "$RESOLVE_ERR" 2>/dev/null || true)
rm -f "$RESOLVE_ERR"
if [ "$resolve_rc" -ne 0 ]; then
  echo "ERROR: could not resolve the governing review policy: $RESOLVE_MSG" >&2
  exit 2
fi
fi
POLICY_CONFIG="$RESOLVED_POLICY"
# Only a fetched base policy lives in TMPDIR and needs cleanup; the
# default-config path is the repo checkout.
case "$POLICY_CONFIG" in
  "$CONFIG") ;;
  *) BASE_POLICY_TMP="$POLICY_CONFIG" ;;
esac

DEPENDABOT_GATE_ENABLED=$(nested_field dependabot reviewer_gate enabled)
DEPENDABOT_GATE_ENABLED=${DEPENDABOT_GATE_ENABLED:-false}
case "$DEPENDABOT_GATE_ENABLED" in
  true|false) ;;
  *)
    echo "ERROR: dependabot.reviewer_gate.enabled must be true|false; got '$DEPENDABOT_GATE_ENABLED'" >&2
    exit 2
    ;;
esac

EXTERNAL_GATE_ENABLED=$(nested_field codex external_review_gate enabled)
EXTERNAL_GATE_ENABLED=${EXTERNAL_GATE_ENABLED:-false}
case "$EXTERNAL_GATE_ENABLED" in
  true|false) ;;
  *)
    echo "ERROR: codex.external_review_gate.enabled must be true|false; got '$EXTERNAL_GATE_ENABLED'" >&2
    exit 2
    ;;
esac

PR_AUTHOR=$(echo "$PR_JSON" | jq -r '.user.login')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 2 "could not determine HEAD sha for PR #$PR_NUMBER"
fi

HAS_EXTERNAL_LABEL=$(echo "$PR_JSON" \
  | jq -r 'if any(.labels[]?.name; . == "needs-external-review") then "true" else "false" end')

log "HEAD = $HEAD_SHA    author = $PR_AUTHOR    needs-external-review = $HAS_EXTERNAL_LABEL"

# --- class dispatch ---------------------------------------------------------
#
# Dependabot is checked FIRST and uses the narrower rule (CLI reviewer
# APPROVED on HEAD only — Codex does not review Dependabot PRs). This
# mirrors pr-audit.yml Check 2's precedence: a Dependabot PR that also
# carries needs-external-review is still judged by the Dependabot rule.

if [ "$PR_AUTHOR" = "dependabot[bot]" ]; then
  if [ "$DERIVE_ONLY" = "true" ] || [ "$RATE_LIMIT_PROTECTION_ONLY" = "true" ]; then
    # Query mode always returns FALSE for a Dependabot PR (automated-4b P1).
    # The query consumers ask a NARROW question: will this PR be protected
    # from bot-unreviewed auto-merge after CodeRabbit rate-limits? The
    # Dependabot reviewer gate is NOT such a gate: when enabled it blocks
    # until a reviewer-identity APPROVED (a human/CLI approval, which
    # dependabot-auto-merge supplies automatically), and Codex does not
    # review Dependabot PRs at all. So neither gate state guarantees a bot
    # reviewed the head. Returning true here would let the rc=5 branch
    # downgrade a CodeRabbit rate-limit stall on an approved Dependabot PR
    # and merge it with NEITHER bot having reviewed (the #512 r3 hazard).
    # The FULL gate below still enforces the reviewer-APPROVED requirement
    # for the actual merge.
    printf 'false\n'
    exit 0
  fi
  if [ "$DEPENDABOT_GATE_ENABLED" != "true" ]; then
    clear_pass "Dependabot PR and dependabot.reviewer_gate.enabled=false (gate disabled)"
  fi

  log "Dependabot path: requiring a reviewer-identity APPROVED review on HEAD"

  REVIEWERS=$(read_available_reviewers)
  if [ -z "$REVIEWERS" ]; then
    die 2 "no available_reviewers found in $CONFIG"
  fi
  REVIEWERS_JSON=$(echo "$REVIEWERS" | jq -R . | jq -s .)

  REVIEWS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")

  # Latest-state-per-reviewer APPROVED on the current HEAD, from a
  # reviewer identity that is not the PR author. Mirrors the proven
  # filter shape in codex-review-check.sh gate (c) Phase-4b-substitute:
  # collapse each reviewer's review history on HEAD to their most-recent
  # opinionated state, then accept only if that latest state is APPROVED.
  # A reviewer who APPROVED then later submitted CHANGES_REQUESTED on the
  # same HEAD does NOT clear (stale APPROVED rejected). commit_id == HEAD
  # is the HEAD pinning that closes the #427 escape.
  APPROVER=$(echo "$REVIEWS_JSON" | jq -r \
    --argjson reviewers "$REVIEWERS_JSON" \
    --arg author "$PR_AUTHOR" \
    --arg sha "$HEAD_SHA" '
      [ .[]
        | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
        | select(.commit_id == $sha)
        | select(.user.login as $u | $reviewers | index($u))
        | select(.user.login != $author)
      ]
      | group_by(.user.login)
      | map(max_by(.submitted_at))
      | map(select(.state == "APPROVED"))
      | first
      | if . == null then "" else .user.login end
  ')

  if [ -n "$APPROVER" ]; then
    clear_pass "Dependabot PR has a latest-state APPROVED review on HEAD $HEAD_SHA from $APPROVER"
  fi
  block "Dependabot PR has no reviewer-identity APPROVED review on the merge HEAD $HEAD_SHA. The dependabot-auto-merge approval is missing or was dismissed on a push; a fresh reviewer-identity approval on this HEAD is required (mergepath#427)."
fi

# --- external-review applicability (DERIVED, not label-trusting) -----------
#
# #429 Codex P1: keying the external arm on the CURRENT label state would
# reintroduce the exact stale-label race this gate exists to close. After a
# push, this gate can run on `synchronize` BEFORE pr-review-policy.yml
# re-adds `needs-external-review` for the new HEAD; a label-only check would
# then fall through to "not applicable" and go GREEN on an uncleared HEAD
# (the #428 escape, reopened). So derive applicability from the PR's
# INTRINSIC properties — the same line-threshold + protected-paths
# computation pr-review-policy.yml's External Review Check uses — and treat
# the label, when present, as an additional force-on signal (a human may
# add it to a small PR). Config (threshold + paths) is read from the
# TRUSTED default-branch review-policy.yml; the changed-file set comes from
# the API (this gate runs on a default-branch checkout with no local PR
# diff). Propagation PRs are NOT special-cased: they reach clearance via
# codex-review-check.sh's internal-reviewer-APPROVED-on-HEAD (Phase-4b
# substitute) path, consistent with the lane's standard "internal
# reviewer-identity APPROVED required" rule.

# Query mode with the external arm disabled: nothing downstream gates the
# merge on review state — report vacuous.
if [ "$DERIVE_ONLY" = "true" ] && [ "$EXTERNAL_GATE_ENABLED" != "true" ]; then
  printf 'false\n'
  exit 0
fi

if [ "$EXTERNAL_GATE_ENABLED" = "true" ] || [ "$RATE_LIMIT_PROTECTION_ONLY" = "true" ]; then
  REQUIRES_EXTERNAL=false
  REQUIRES_REASON=""

  if [ "$HAS_EXTERNAL_LABEL" = "true" ]; then
    # Label present forces the arm on (a human may add it to a small PR;
    # or the propagation lane RE-ADDED it after a divergence). Not subject
    # to the propagation exemption below — a present label means the lane's
    # latest per-HEAD verdict is "needs review."
    REQUIRES_EXTERNAL=true
    REQUIRES_REASON="needs-external-review label present"
  elif lane_verified; then
    # Verified propagation PR: a trusted github-actions[bot] lane marker
    # scoped to THIS head SHA is present (label absent). The lane already
    # byte-verified this exact head and exempted it from external review;
    # defer to it and do NOT re-derive from threshold/paths (#429).
    log "verified propagation lane (trusted head-pinned marker for $HEAD_SHA, label absent) — exempt from external-review derivation; deferring to pr-review-policy.yml lane"
  else
    lane_rc=$?
    # Indeterminate marker read (rc 2): in the FULL gate, falling through to
    # threshold/paths derivation is fail-safe (external review can only be
    # ADDED, never removed, so an uncertain read at worst over-requires and
    # blocks). But in the query modes, `true` is the value that authorizes
    # the rc=5 CodeRabbit downgrade, and a verified propagation PR's real
    # Merge clearance gate is already green via the exemption — so an
    # unknowable exemption state here must NOT assert requiredness or
    # protection. Fail closed to the caller instead (the rc=5 branch reads a
    # nonzero query as false → block). automated-4b round-5 P1.
    if [ "${lane_rc:-0}" -eq 2 ] && { [ "$DERIVE_ONLY" = "true" ] || [ "$RATE_LIMIT_PROTECTION_ONLY" = "true" ]; }; then
      die 2 "propagation-lane marker read was indeterminate (comments API fetch/parse failed) in query mode for $HEAD_SHA; refusing to assert external-review requiredness/protection (fail-closed)"
    fi
    # `|| true` so a missing key (grep no-match → pipeline non-zero under
    # pipefail) does NOT abort the script before the `:-300` fallback runs
    # (CodeRabbit ⚠️ on PR #429).
    THRESHOLD=$(grep -E '^external_review_threshold:' "$POLICY_CONFIG" 2>/dev/null | awk '{print $2}' || true)
    THRESHOLD=${THRESHOLD:-300}
    if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then THRESHOLD=300; fi

    FILES_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/files" "PR files")

    # Sum additions+deletions, excluding the same generated/lockfile
    # patterns pr-review-policy.yml's git-diff pathspec excludes.
    LINES_CHANGED=$(echo "$FILES_JSON" | jq '
      [ .[]
        | select((.filename
            | test("(\\.lock$)|(lock\\.json$)|(\\.min\\.js$)|(\\.min\\.css$)|(\\.generated\\.)|(\\.g\\.dart$)|(\\.freezed\\.dart$)")) | not)
        | ((.additions // 0) + (.deletions // 0)) ]
      | add // 0')
    LINES_CHANGED=${LINES_CHANGED:-0}

    if [ "$LINES_CHANGED" -ge "$THRESHOLD" ]; then
      REQUIRES_EXTERNAL=true
      REQUIRES_REASON="$LINES_CHANGED lines changed >= threshold $THRESHOLD"
    else
      # Protected-paths match, reusing the SAME helpers pr-review-policy.yml
      # uses (no drift). Resolved relative to this script so they work from a
      # trusted default-branch checkout; they take the config path + read
      # candidate filenames on stdin (no filesystem access to PR content).
      # MERGE_CLEARANCE_WORKFLOW_DIR overrides the helper dir (tests only).
      #
      # Fail CLOSED on any failure to RUN the matcher (missing helper, parse
      # error, match error): a protected-path PR must never slip through as
      # "threshold-only" just because the matcher couldn't run. The helpers
      # ship with this gate via .mergepath-sync.yml, so their absence means a
      # broken install — require external review rather than skip it.
      # (CodeRabbit ⚠️ Major on PR #429.) Note: a SUCCESSFUL parse that
      # yields no entries (external_review_paths absent/empty) is NOT a
      # failure — it legitimately means "no protected paths," so the gate
      # does not fail closed in that case.
      WF_DIR="${MERGE_CLEARANCE_WORKFLOW_DIR:-$SCRIPT_DIR/workflow}"
      PARSE="$WF_DIR/parse_policy_list.sh"
      MATCH="$WF_DIR/match_protected_paths.sh"
      if [ ! -f "$PARSE" ] || [ ! -f "$MATCH" ]; then
        REQUIRES_EXTERNAL=true
        REQUIRES_REASON="protected-paths check unavailable (parser/matcher missing under $WF_DIR) — failing closed"
      else
        set +e
        PATHS=$(bash "$PARSE" "$POLICY_CONFIG" external_review_paths)
        parse_rc=$?
        set -e
        if [ "$parse_rc" -ne 0 ]; then
          REQUIRES_EXTERNAL=true
          REQUIRES_REASON="protected-paths parse failed (rc=$parse_rc) — failing closed"
        elif [ -n "$PATHS" ]; then
          PATTERNS=()
          while IFS= read -r pline; do
            [ -n "$pline" ] && PATTERNS+=("$pline")
          done <<<"$PATHS"
          if [ "${#PATTERNS[@]}" -gt 0 ]; then
            # Both sides of a rename (#763): GitHub reports the
            # destination in .filename and the source in
            # .previous_filename. Matching only .filename let a
            # below-threshold PR MOVE a protected file to an unprotected
            # path and still get a green required check here — this gate
            # runs on `synchronize` before the labelers can re-add
            # needs-external-review, so that green permits auto-merge.
            CHANGED_FILES=$(echo "$FILES_JSON" | jq -r '.[] | (.filename, (.previous_filename // empty))')
            set +e
            MATCHED=$(printf '%s\n' "$CHANGED_FILES" | bash "$MATCH" "${PATTERNS[@]}")
            match_rc=$?
            set -e
            if [ "$match_rc" -ne 0 ]; then
              REQUIRES_EXTERNAL=true
              REQUIRES_REASON="protected-paths match failed (rc=$match_rc) — failing closed"
            elif [ -n "$MATCHED" ]; then
              REQUIRES_EXTERNAL=true
              REQUIRES_REASON="protected paths modified: $(printf '%s' "$MATCHED" | tr '\n' ' ')"
            fi
          fi
        fi
      fi
    fi
  fi

  if [ "$DERIVE_ONLY" = "true" ]; then
    log "query mode: external requiredness on HEAD $HEAD_SHA = $REQUIRES_EXTERNAL${REQUIRES_REASON:+ ($REQUIRES_REASON)}"
    printf '%s\n' "$REQUIRES_EXTERNAL"
    exit 0
  fi

  if [ "$RATE_LIMIT_PROTECTION_ONLY" = "true" ]; then
    if [ "$REQUIRES_EXTERNAL" != "true" ]; then
      log "rate-limit protection query: external review does not apply on HEAD $HEAD_SHA"
      printf 'false\n'
      exit 0
    fi
    # Arm 1 (#713, tightened by #772): the merge-clearance gate will really
    # hold this merge. That needs BOTH the config switch AND positive proof the
    # check is ENFORCED on the PR's base branch. `codex.external_review_gate.
    # enabled` alone is CONFIGURATION, not enforcement — on
    # nathanjohnpayne/mergepath that switch is true while base `main` requires
    # only ["Label Gate","Self-Review Required","lint"], so the pre-#772
    # short-circuit reported protected:true on a repo where this gate cannot
    # block anything, and agent-review.yml's rc=5 branch downgraded a
    # CodeRabbit rate-limit stall on that strength. Enforcement that cannot be
    # DETERMINED counts as not-enforced and falls through to arm 2, which is a
    # positive-proof probe — so nothing is lost but availability.
    if [ "$EXTERNAL_GATE_ENABLED" = "true" ] && merge_clearance_check_enforced; then
      log "rate-limit protection query: '$MERGE_CLEARANCE_CHECK_NAME' is an ENFORCED required check on base '$BASE_REF' and its external arm applies on HEAD $HEAD_SHA ($REQUIRES_REASON)"
      printf 'true\n'
      exit 0
    fi

    # Arm 2 (#714, unchanged): no provably-enforced gate — the switch is off,
    # the check is not required on the base branch, or enforcement was
    # undeterminable — so fall back to proving clearance is already satisfied
    # on THIS head.
    log "rate-limit protection query: external review applies on HEAD $HEAD_SHA ($REQUIRES_REASON), but '$MERGE_CLEARANCE_CHECK_NAME' is not a proven-enforced required check on base '$BASE_REF' (external_review_gate.enabled=$EXTERNAL_GATE_ENABLED); checking current-head Codex/Phase-4b clearance"
    CODEX_CHECK_BIN="${MERGE_CLEARANCE_CODEX_CHECK_BIN:-$SCRIPT_DIR/codex-review-check.sh}"
    if [ ! -f "$CODEX_CHECK_BIN" ]; then
      die 2 "codex-review-check.sh not found at $CODEX_CHECK_BIN (required for rate-limit protection query)"
    fi
    set +e
    CODEX_REVIEW_CHECK_SKIP_CI=1 CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 \
      MERGEPATH_REVIEW_POLICY_PATH="$POLICY_CONFIG" bash "$CODEX_CHECK_BIN" "$PR_NUMBER" "$REPO" >&2
    crc=$?
    set -e
    # codex-review-check.sh's public contract is 0 clear, 1 gate-fail,
    # 3 infrastructure/config. It has no "pending" success-adjacent code, so
    # every other rc is treated as infrastructure and fails closed.
    case "$crc" in
      0)
        log "rate-limit protection query: current-head Codex/Phase-4b clearance is already satisfied"
        printf 'true\n'
        exit 0
        ;;
      1)
        log "rate-limit protection query: external review applies but current-head Codex/Phase-4b clearance is not satisfied"
        printf 'false\n'
        exit 0
        ;;
      *) die 2 "codex-review-check.sh returned rc=$crc (config/infrastructure error) in rate-limit protection query on PR #$PR_NUMBER" ;;
    esac
  fi

  if [ "$REQUIRES_EXTERNAL" = "true" ]; then
    log "external review applies ($REQUIRES_REASON); delegating to codex-review-check.sh (CI gate skipped — this gate is itself a required check)"

    CODEX_CHECK_BIN="${MERGE_CLEARANCE_CODEX_CHECK_BIN:-$SCRIPT_DIR/codex-review-check.sh}"
    if [ ! -f "$CODEX_CHECK_BIN" ]; then
      die 2 "codex-review-check.sh not found at $CODEX_CHECK_BIN (required for the external-review path)"
    fi

    # Delegate to the shared predicate. CODEX_REVIEW_CHECK_SKIP_CI=1 skips
    # gate (a) for THIS invocation only (avoids the required-check
    # self-deadlock). CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 HEAD-pins
    # gate (b) so a stale earlier-head reviewer APPROVED can't ride a later
    # push to clearance (#435) — making this REQUIRED check fully HEAD-pinned
    # (reviewer + Codex/Phase-4b both on HEAD). codex-review-check.sh exits:
    # 0 clear, 1 gate fail, 3 infra. Map 3 → 2 (config/infra error).
    set +e
    CODEX_REVIEW_CHECK_SKIP_CI=1 CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 \
      MERGEPATH_REVIEW_POLICY_PATH="$POLICY_CONFIG" bash "$CODEX_CHECK_BIN" "$PR_NUMBER" "$REPO"
    crc=$?
    set -e
    case "$crc" in
      0) clear_pass "external review cleared on HEAD $HEAD_SHA ($REQUIRES_REASON; reviewer APPROVED + Codex/Phase-4b on HEAD)" ;;
      1) block "external review is NOT cleared on the merge HEAD $HEAD_SHA ($REQUIRES_REASON; no APPROVED CLI review and/or no Codex clearance on this HEAD). See codex-review-check.sh stderr above (mergepath#428)." ;;
      *) die 2 "codex-review-check.sh returned rc=$crc (config/infrastructure error) on PR #$PR_NUMBER" ;;
    esac
  fi
fi

# Not a Dependabot PR, and external review does not apply (under threshold,
# no protected paths, no label — or the external gate is disabled). Clean
# pass so the required check is green on normal under-threshold PRs.
clear_pass "merge-clearance gate not applicable (under threshold, no protected paths, no external-review label; or external gate disabled)"
