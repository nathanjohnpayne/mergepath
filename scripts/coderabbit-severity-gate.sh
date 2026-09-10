#!/usr/bin/env bash
# scripts/coderabbit-severity-gate.sh — CodeRabbit blocking-tier
# unresolved-thread merge gate
#
# The CodeRabbit twin of scripts/codex-p1-gate.sh (nathanjohnpayne/
# mergepath#574, sub-issue #577). Reports "CodeRabbit blocking-tier
# unresolved: N" for a pull request and fails (exit 1) when N > 0.
# Read-only. Never merges, labels, or comments.
#
# Context: #574 makes the disposition policy symmetric across BOTH bot
# reviewers. The Codex side already had a teeth-bearing gate (#235); this
# is its CodeRabbit mirror. CodeRabbit has no numeric P-scale, so each
# inline finding is mapped to the normalized tier ladder HEURISTICALLY by
# scripts/lib/feedback-policy-helpers.sh's coderabbit_tier_of (category +
# Critical/Major/Minor qualifier; 🧹 Nitpick -> nitpick). The gate then
# enforces the BLOCKING tier set resolved by resolve_required_tiers from
# the `feedback_policy` block in .github/review-policy.yml.
#
# Narrow-start posture (identical to codex.p1_gate / external_review_gate):
# the gate is gated by `coderabbit.severity_gate.enabled`, which defaults
# to false EVERYWHERE — today CodeRabbit has no merge gate at all — and is
# set true in mergepath first. When disabled the gate is a clean no-op
# (always green), exactly like codex-p1-gate.sh's off-state short-circuit,
# so it is safe to add to required checks everywhere before flipping the
# switch on a given repo.
#
# Usage:
#   scripts/coderabbit-severity-gate.sh <PR_NUMBER> [REPO]
#   scripts/coderabbit-severity-gate.sh                # env-only mode
#
# Arguments:
#   PR_NUMBER  Required (positional or via $PR_NUMBER env). Integer.
#   REPO       Optional. "owner/repo". Falls back to $REPO env, then
#              to the current repo via `gh repo view`.
#
# Environment:
#   GH_TOKEN   Required. Needs pull_requests:read AND issues:read.
#              `issues:read` is for the PR-level SUMMARY surface added in
#              #832 (`repos/{repo}/issues/{pr}/comments`). It is not
#              optional: that read is fail-CLOSED, so a token without the
#              permission gets a 403 and the gate exits 2 rather than
#              silently skipping the surface. The bundled workflow grants
#              it; ad-hoc and private-repo callers using a fine-grained
#              token must provision it too.
#   PR_NUMBER  Optional fallback for the positional arg. The
#              scheduled-sweep job in
#              .github/workflows/coderabbit-severity-gate.yml passes
#              PR_NUMBER positionally per iteration, but other callers
#              (workflow_dispatch, ad-hoc CLI use, CI matrix jobs) may
#              find it easier to set it as env.
#   REPO       Optional fallback for the positional REPO arg. Same
#              motivation as PR_NUMBER above.
#   REQUIRE_REVIEW_SUMMARY  Optional true|false (default false). Both bundled
#              workflow arms set true: once a completed CodeRabbit review run
#              exists on HEAD, hold this run rather than publish a verdict
#              until a summary is correlated to that run. Other callers retain
#              the normal arrival-independent gate behavior.
#
# Algorithm:
#   1. Read .github/review-policy.yml `coderabbit.severity_gate.enabled`.
#      If false (the default everywhere except mergepath), exit 0 — clean
#      pass, gate disabled.
#   2. Fetch all inline review comments on the PR via
#      `repos/{repo}/pulls/{pr}/comments`.
#   3. Filter to comments authored by `coderabbitai[bot]` (or whatever
#      `coderabbit.bot_login` is configured to) whose CodeRabbit tier
#      (coderabbit_tier_of) is in the resolved BLOCKING tier set.
#   4. For each candidate, fetch its review thread state via GraphQL
#      `reviewThreads` and check `isResolved`. The author or any
#      collaborator can resolve a thread via the GitHub UI's "Resolve
#      conversation" button or the `resolveReviewThread` mutation; this
#      script does NOT fight against a human-or-agent-marked-resolved
#      state.
#   5. SHA scope: a finding only gates if its comment was attached to the
#      PR's current HEAD. A finding from an earlier SHA that is now either
#      resolved OR no longer on HEAD does not count.
#   5b. Also fetch the SUMMARY surface — the head-pinned CodeRabbit review
#      objects (`repos/{repo}/pulls/{pr}/reviews`, where the markerless
#      full-review body lives) and the PR-level comments
#      (`repos/{repo}/issues/{pr}/comments`, where the marker-led walkthrough
#      lives) — and classify both with the SAME coderabbit_tier_of (#832).
#      CodeRabbit can carry a blocking finding solely in its summary, with no
#      inline anchor and therefore no review thread. See the "PR-level summary
#      surface" section below for the identity / scope / completeness rules,
#      and for the acknowledgement channel that stands in for "Resolve
#      conversation" on that surface.
#   6. Print one line per unresolved blocking-tier finding to stdout for
#      CI visibility, then the summary "CodeRabbit blocking-tier
#      unresolved: N".
#
# Exit codes:
#   0   No unresolved blocking-tier findings on current HEAD (or gate
#       disabled).
#   1   One or more unresolved blocking-tier findings on current HEAD —
#       gate blocks.
#   2   Usage / config error. Error message on stderr.
#   3   REQUIRE_REVIEW_SUMMARY only: a completed CodeRabbit review run is on
#       the current HEAD and NO acceptor recognised a summary for it, so the
#       findings on that surface are not knowable. NOT a finding count.
#       An event-driven caller treats it as non-green; the scheduled /
#       issue_comment sweep must DECLINE TO PUBLISH rather than post a
#       success read off the previous publication. Since the primary acceptor
#       reads the summary out of the run object's OWN body, this no longer
#       fires merely because the walkthrough comment has not caught up — it
#       means the run's serialization is one this gate cannot classify.
#
# Design notes:
#   - Read-only. Only GETs against the GitHub API.
#   - bash 3.2 portable (`#!/usr/bin/env bash`, no associative arrays
#     or [[ ]] regex features beyond what 3.2 supports).
#   - PATH-shimmable: tests substitute a `gh` stub on PATH that returns
#     canned payloads. See tests/test_coderabbit_severity_gate.sh.
#   - The override path is "mark the thread resolved via the GitHub UI or
#     GraphQL" — the same mechanism the author or any collaborator already
#     uses to clear any review thread. Resolving a finding that
#     legitimately does not apply (rebutted with rationale, moot, deferred
#     to a follow-up issue) clears the gate. A summary-only finding has no
#     thread; its override path is the head-and-finding-set-pinned collaborator
#     ack comment documented in the "PR-level summary surface" section (#832).
#
# References:
#   - nathanjohnpayne/mergepath#574 — the symmetric feedback policy
#   - nathanjohnpayne/mergepath#577 — this script + the generalized Codex gate
#   - nathanjohnpayne/mergepath#535 — CodeRabbit can carry a finding in the
#     PR-level summary alone; taught the advisory waiter to look
#   - nathanjohnpayne/mergepath#832 — teaching THIS (required) gate the same
#   - scripts/codex-p1-gate.sh — the Codex twin this mirrors
#   - scripts/coderabbit-wait.sh — canonical source of the summary predicates
#   - REVIEW_POLICY.md § Feedback Disposition Policy — the normalized ladder

set -euo pipefail

# --- argument parsing -------------------------------------------------------

if [ $# -gt 2 ]; then
  echo "Usage: $0 [PR_NUMBER] [REPO]" >&2
  echo "       PR_NUMBER and REPO may also be set via env." >&2
  exit 2
fi

# --- config readers ---------------------------------------------------------

CONFIG=".github/review-policy.yml"

# Shared blocking-tier resolver + CodeRabbit tier classifier (#576
# foundation). resolve_required_tiers reads CONFIG (the global set above)
# and prints the blocking tier set one per line — "p1" when the
# feedback_policy block is absent. coderabbit_tier_of maps a CodeRabbit
# finding body to p0..p3|nitpick. Sourced relative to this script so it
# resolves regardless of cwd (the gate runs from the trusted default-branch
# checkout root, but lib lives under scripts/).
__CR_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/feedback-policy-helpers.sh
. "$__CR_GATE_DIR/lib/feedback-policy-helpers.sh"

# Shared paginated-list reader (#1008) — the fetch → capture → flatten
# algorithm fetch_api_array below used to carry inline, alongside seven other
# copies. Hard-required: this is a REQUIRED status check, and an undefined
# reader would surface as `command not found` on the very reads whose
# fail-closed contract keeps an unreadable surface from being graded as "no
# findings".
if [ ! -r "$__CR_GATE_DIR/lib/gh-api-array.sh" ]; then
  echo "ERROR: gh-api-array helper missing: $__CR_GATE_DIR/lib/gh-api-array.sh" >&2
  exit 2
fi
# shellcheck source=lib/gh-api-array.sh
. "$__CR_GATE_DIR/lib/gh-api-array.sh"

# Read a scalar field nested inside `coderabbit:` `severity_gate:`
# `<field>:`. Same state-machine awk pattern as codex_p1_gate_field in
# scripts/codex-p1-gate.sh, retargeted to the coderabbit: block.
coderabbit_severity_gate_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^coderabbit:/ { in_cr=1; in_sg=0; next }
    in_cr && /^[^[:space:]#]/ { in_cr=0; in_sg=0 }
    in_cr && /^[[:space:]]+severity_gate:/ { in_sg=1; next }
    in_sg && /^[[:space:]]{0,3}[^[:space:]#]/ { in_sg=0 }
    in_sg && $1 == field":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

# Read a scalar field from the coderabbit: block. Mirrors
# scripts/coderabbit-wait.sh's coderabbit_field.
coderabbit_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^coderabbit:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && $1 == field":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

# Gate knob: coderabbit.severity_gate.enabled. Default false EVERYWHERE
# (today CodeRabbit has no gate); mergepath sets it true. Off-state is a
# clean pass — no API calls, no work.
#
# This off-state short-circuit runs BEFORE the PR_NUMBER/REPO/GH_TOKEN
# requirements below (mirrors codex-p1-gate.sh #447): step 1 is
# "severity_gate.enabled=false → clean pass," so a consumer with the gate
# disabled must no-op on a bare/ad-hoc invocation instead of erroring on
# missing PR context. The readers above touch only the local
# review-policy.yml — no args, no API, no gh.
GATE_ENABLED=$(coderabbit_severity_gate_field enabled)
GATE_ENABLED=${GATE_ENABLED:-false}
case "$GATE_ENABLED" in
  true|false) ;;
  *)
    echo "ERROR: coderabbit.severity_gate.enabled must be true|false; got '$GATE_ENABLED'" >&2
    exit 2
    ;;
esac

if [ "$GATE_ENABLED" != "true" ]; then
  echo "[coderabbit-severity-gate] coderabbit.severity_gate.enabled=false — skipping (clean pass)"
  echo "CodeRabbit blocking-tier unresolved: 0"
  exit 0
fi

# --- PR context (required only once the gate is enabled) --------------------

# Positional args take precedence; env fallbacks support the
# workflow_dispatch / scheduled-sweep paths where it's more
# ergonomic to set env than to build a positional arg list.
PR_NUMBER=${1:-${PR_NUMBER:-}}
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PR_NUMBER required (positional arg or \$PR_NUMBER env)" >&2
  exit 2
fi
if ! echo "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
  echo "ERROR: PR_NUMBER must be an integer; got '$PR_NUMBER'" >&2
  exit 2
fi

# Verify GH_TOKEN BEFORE auto-detecting REPO via `gh repo view` — a
# missing/invalid token otherwise surfaces as a misleading "could not
# detect current repo" instead of the real auth error (matches
# codex-p1-gate.sh, CodeRabbit on #463).
if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN is required. See REVIEW_POLICY.md § PAT lookup table." >&2
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

BOT_LOGIN=$(coderabbit_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"coderabbitai[bot]"}

# Resolve the BLOCKING tier set from the feedback_policy block (#577). Absent
# block -> "p1". Only rc 2 is the documented "malformed mode/tier" signal —
# fail closed as a config error (exit 2). A non-2 non-zero rc is benign:
# resolve_required_tiers' by-priority branch inherits the exit status of its
# final loop iteration (e.g. rc 1 when the last tier, nitpick, is not
# `required`). Capture the output regardless and branch on the rc explicitly.
set +e
REQUIRED_TIERS=$(resolve_required_tiers "$CONFIG")
RT_RC=$?
set -e
if [ "$RT_RC" -eq 2 ]; then
  echo "ERROR: malformed feedback_policy block in $CONFIG (resolve_required_tiers exit 2)" >&2
  exit 2
fi

# Return 0 iff $1 (a tier like p0..p3|nitpick) is in the resolved set.
# Newline-delimited exact match — mirrors login_is_available_reviewer.
tier_is_required() {
  local needle=$1 t
  [ -n "$needle" ] || return 1
  while IFS= read -r t; do
    [ "$t" = "$needle" ] && return 0
  done <<< "$REQUIRED_TIERS"
  return 1
}

# --- logging helpers --------------------------------------------------------

log() {
  echo "[coderabbit-severity-gate] $*" >&2
}

die() {
  local code=$1
  shift
  echo "[coderabbit-severity-gate] ERROR: $*" >&2
  exit "$code"
}

# --- nitpick-under-chill no-op warning (#577) -------------------------------
# `nitpick: required` only has teeth when .coderabbit.yml runs
# reviews.profile: assertive — the shipped `chill` profile suppresses the
# 🧹 Nitpick category ENTIRELY, so CodeRabbit never emits a nitpick finding
# for this gate to catch. When the resolved required set includes `nitpick`
# but the profile is (or defaults to) chill, warn that the gating is a
# silent no-op. Advisory only: it does NOT change the gate result and NEVER
# rewrites .coderabbit.yml (both out of scope per the issue). Read the
# profile with the same dependency-free awk-state-machine style as
# coderabbit_field, retargeted to the reviews: block in .coderabbit.yml.
coderabbit_yml_profile() {
  local f=".coderabbit.yml"
  [ -f "$f" ] || return 0
  awk '
    /^reviews:/ { in_rev=1; next }
    in_rev && /^[^[:space:]#]/ { in_rev=0 }
    in_rev && $1 == "profile:" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$f"
}

if tier_is_required nitpick; then
  CR_PROFILE=$(coderabbit_yml_profile)
  # Absent .coderabbit.yml / absent profile ⇒ CodeRabbit's own default,
  # which is chill — so treat empty as chill for the purpose of this warning.
  CR_PROFILE=${CR_PROFILE:-chill}
  if [ "$CR_PROFILE" = "chill" ]; then
    log "WARNING: feedback_policy marks 'nitpick' required, but .coderabbit.yml"
    log "         reviews.profile is '$CR_PROFILE' — the chill profile suppresses the"
    log "         🧹 Nitpick category entirely, so nitpick gating is a silent no-op."
    log "         Set reviews.profile: assertive in .coderabbit.yml to give it teeth,"
    log "         or set feedback_policy nitpick to discretionary to drop the claim."
  fi
fi

# Paginated fetch helper. The algorithm lives in scripts/lib/gh-api-array.sh
# (#1008); what stays here is this gate's failure ACTION — `die 2`, the
# config/usage code the workflow maps to a hard gate failure, so an unreadable
# surface can never be graded as "no findings".
fetch_api_array() {
  gh_api_array "$1" "$2" || die 2 "$GH_API_ARRAY_ERROR"
}

# --- fetch PR metadata ------------------------------------------------------

log "PR $REPO#$PR_NUMBER — fetching metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) \
  || die 2 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 2 "could not determine HEAD sha for PR #$PR_NUMBER"
fi
log "HEAD = $HEAD_SHA    bot_login = $BOT_LOGIN"

# --- fetch CodeRabbit blocking-tier inline comments -------------------------

COMMENTS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline comments")

log "blocking tier set: $(echo "$REQUIRED_TIERS" | tr '\n' ' ')"

# Stage 1 (jq): narrow to bot-authored comments on the current HEAD —
#   - author == bot_login
#   - on the current HEAD: original_commit_id == HEAD or commit_id == HEAD.
#     A finding from an earlier SHA that was addressed in a later commit
#     has commit_id != HEAD; we treat it as out-of-scope for this gate
#     regardless of thread state (already resolved by not being on HEAD).
# We keep the FULL body here so stage 2 can classify each candidate with
# the shared coderabbit_tier_of — no tier filter in jq, to avoid
# re-implementing (and drifting from) the classifier in
# scripts/lib/feedback-policy-helpers.sh.
CANDIDATES=$(echo "$COMMENTS_JSON" | jq -c \
  --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
  [ .[]
    | select(.user.login == $bot)
    | select((.commit_id == $sha) or (.original_commit_id == $sha))
    | {
        id: .id,
        path: .path,
        line: (.line // .original_line // 0),
        body: (.body // "")
      }
  ]
')

# Stage 2 (bash): classify each candidate via coderabbit_tier_of and keep
# only those whose tier is in the resolved blocking set. Re-assemble the
# kept comments into a JSON array of {id, path, line, tier, body_snippet}
# (trimmed first line for log readability).
BLOCKING_COMMENTS="[]"
CAND_COUNT=$(echo "$CANDIDATES" | jq 'length')
i=0
while [ "$i" -lt "$CAND_COUNT" ]; do
  c=$(echo "$CANDIDATES" | jq -c ".[$i]")
  body=$(echo "$c" | jq -r '.body')
  tier=$(coderabbit_tier_of "$body")
  if tier_is_required "$tier"; then
    BLOCKING_COMMENTS=$(echo "$BLOCKING_COMMENTS" | jq -c \
      --argjson c "$c" --arg tier "$tier" '
      . + [ {
        id: $c.id,
        path: $c.path,
        line: $c.line,
        tier: $tier,
        body_snippet: ($c.body | split("\n")[0] | .[0:120])
      } ]
    ')
  fi
  i=$((i + 1))
done

BLOCKING_COUNT=$(echo "$BLOCKING_COMMENTS" | jq 'length')
log "found $BLOCKING_COUNT blocking-tier inline comment(s) on HEAD"

# --- fetch CodeRabbit blocking-tier PR-level SUMMARY findings (#832) --------
#
# `pulls/{pr}/comments` above returns inline review comments only. CodeRabbit
# also publishes a PR-level summary on `issues/{pr}/comments`, and it can carry
# a blocking finding that has NO inline anchor at all (#535 established this is
# real, and taught the ADVISORY waiter to look; the REQUIRED gate was never
# taught the same thing — the inversion #832 filed).
#
# Three properties this surface needs and the inline surface gets for free:
#
#   IDENTITY. Select the summary BY its auto-generated marker, never as "the
#   newest CodeRabbit comment". CodeRabbit keeps exactly one marker-carrying
#   comment per PR and edits it in place; a CodeRabbit CHAT REPLY is a
#   different comment that carries no marker, and two live replies (#794,
#   #518) embed a full 40-hex head SHA lifted from a pasted `gh pr view`
#   snippet — marker selection makes those structurally unable to supply
#   evidence here.
#
#   SCOPE. An inline comment carries `commit_id`; a summary comment carries no
#   commit field at all. The honest anchor is the one CODERABBIT itself writes
#   into the body: the `📥 Commits` line's range END (`between <prev> and
#   <head>`). It is bot-authored content naming a SHA, exactly like the
#   `Reviewed commit:` line the Codex path anchors on. It is deliberately NOT
#   a timestamp: no wall-clock floor is consulted anywhere below, so a finding
#   can never age out of view, and no pusher-controlled clock can move the
#   boundary (per REVIEW_POLICY.md's no-spoofable-timestamp rule and the #535
#   HEAD_ANCHOR caveat the issue calls out).
#
#   COMPLETENESS. The commits range describes whatever run last touched the
#   comment, INCLUDING runs that produced no review (`rate limited`,
#   `failure`, `review in progress` — #790 names the head exactly while saying
#   "Review failed"). So the summary counts as a report only when every
#   outcome stanza present is benign. ALLOW-list, not deny-list: a stanza KIND
#   CodeRabbit has not shipped yet reads as not-a-report, never as clean.
#
# The four constants and the two predicates below are the canonical ones from
# scripts/coderabbit-wait.sh (SUMMARY_MARKER, CR_SUMMARY_BENIGN_STANZA_RE,
# CR_PRE_MERGE_BLOCK_*, summary_stanzas_all_benign, summary_names_head). They
# are duplicated here rather than sourced: this required gate must not take a
# runtime dependency on the advisory waiter, and the shared lib
# (scripts/lib/feedback-policy-helpers.sh) is contractually a pure
# tier-classifier. Keep the two copies in lockstep — the same posture the
# GraphQL pagination block below carries with scripts/codex-p1-gate.sh.
CR_SUMMARY_MARKER='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->'
CR_SUMMARY_BENIGN_STANZA_RE='auto-generated comment: (summarize|release notes) by coderabbit\.ai'
CR_PRE_MERGE_BLOCK_START='<!-- pre_merge_checks_walkthrough_start -->'
CR_PRE_MERGE_BLOCK_END='<!-- pre_merge_checks_walkthrough_end -->'
# CodeRabbit's current full-review format can omit CR_SUMMARY_MARKER entirely
# and lead with this machine-shaped result line. It is intentionally narrow:
# prose such as a chat reply must not become a summary merely because a review
# object exists on the same head.
CR_MARKERLESS_FULL_REVIEW_RE='^\*\*Actionable comments posted: [0-9]+\*\*(\r?\n|$)'

# --- shared fence-aware line filter ----------------------------------------
#
# Moved to scripts/lib/coderabbit-fence.sh (#1178 round 5) so the advisory
# waiter reads fences through the SAME implementation instead of its own
# raw-grep copy. Behaviour here is unchanged: the constant is identical, only
# its home moved. See that file's header for why the duplication mattered.
# shellcheck source=lib/coderabbit-fence.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/coderabbit-fence.sh"

# Emit `<original line number>\t<CR-stripped line>` for every line of the body
# that is OUTSIDE a fenced code block, dropping the fence delimiter lines
# themselves. The line number is carried because the pre-merge strip has to map
# its decision back onto the original body.
#
# CONTRACT (#942), the same two-rung one `fetch_api_array` (#831/#965) and
# `gh_api_scalar` (#799/#971) already carry in this repo — deliberately the
# same rc so this does not become a third notion of failure:
#
#   rc 0  — the body WAS read. The numbered lines are on stdout, and an empty
#           stdout means the body genuinely has no unfenced line.
#   rc 3  — the body could NOT be read (awk died). NOTHING is written to
#           stdout; the diagnostic goes to stderr.
#
# The stdout suppression is what makes the emptiness meaningful again, and it
# is the half that matters most here. Four callers capture this reader in a
# command substitution, and #936 fixed the LAST of them by checking the status.
# The other three inferred "the body says nothing" from empty output, so a dead
# awk — a locale/encoding fault, a memory limit, a mawk-vs-gawk difference on a
# pathological line — reached this REQUIRED gate's merge decision as "nothing
# blocking here" and it exited 0 (#942). Streaming the awk output straight to
# stdout is what made a partial read indistinguishable from a complete one, so
# the output is captured first and only replayed on success.
#
# `die` deliberately does NOT appear here: every caller is a `$( )`, so a `die`
# would exit only the subshell — the same trap the status swallow already is.
summary_unfenced_numbered() {
  local out
  out=$(printf '%s\n' "$1" | awk "$CR_AWK_FENCE_PRELUDE"'
    {
      line = $0
      sub(/\r$/, "", line)
      if (fence_update(line)) next
      if (FENCE) next
      printf "%d\t%s\n", NR, line
    }
  ') || {
    log "ERROR: the fence-aware summary reader failed on this body — the summary is UNREAD, not empty"
    return 3
  }
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}

# Emit one normalized line per STRUCTURAL stanza OPENER in the body.
#
# "Structural" is the whole point (Codex P1 round 1 on #886). Counting the bare
# `auto-generated comment: ` substring anywhere in the body lets PR-CONTROLLED
# text decide whether this summary is a completed report: CodeRabbit quotes
# changed code in its walkthrough and in summary findings, so a PR that merely
# CONTAINS the rate-limit marker as source text — this very PR's test fixtures
# do — inflates the non-benign count and makes an otherwise-complete summary
# read as "not a report". That path exits 0 with any real blocking finding in
# that summary ungated: a false clear of a required gate, produced by content
# the PR author writes. Precisely the failure class #832 exists to close.
#
# So a stanza counts only in the shape CodeRabbit actually writes it: a whole
# line, at column 0, wrapping a KIND — and only OUTSIDE a fenced code block,
# because a fence is how a quoted marker reaches the rendered body at column 0.
# Both narrowings move the same way: they can only shrink the non-benign count,
# never grow it. That direction is deliberate. Over-counting non-benign skips
# the summary and clears the gate (fails OPEN); under-counting classifies a
# body that produced no review, which finds no `⚠️`/`P1` lines in a rate-limit
# notice and, in the #790 stale-text case, gates on findings rather than
# clearing (fails CLOSED). Only one of those two errors can pass a blocking
# finding through, and this shape cannot make it.
#
# `end of auto-generated comment:` CLOSERS are deliberately not openers, so a
# stanza contributes exactly once whether or not CodeRabbit closes it. Real
# bodies carry both forms (mergepath#874's summary has three openers and two
# closers), and counting closers made the total depend on which stanza kinds
# happen to be wrapped.
#
# Carries the reader's rc-3 rung through unchanged (#942): "I could not read
# this body" is not "this body has no stanza openers", and every predicate
# built on top of this one has to be able to tell them apart.
summary_stanza_opener_lines() {
  local numbered out
  numbered=$(summary_unfenced_numbered "$1") || return 3
  out=$(printf '%s\n' "$numbered" | sed 's/^[0-9]*	//' | awk '
    {
      line = $0
      sub(/[ \t]+$/, "", line)
      if (line ~ /^<!-- This is an auto-generated comment: .* by coderabbit\.ai -->$/) {
        print line
      }
    }
  ') || {
    log "ERROR: the stanza-opener scan failed on this summary body — the summary is UNREAD, not stanza-free"
    return 3
  }
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}

# True when the body carries at least one outcome stanza AND every stanza is
# benign. The KIND allow-list ($CR_SUMMARY_BENIGN_STANZA_RE) is unchanged and
# stays in lockstep with scripts/coderabbit-wait.sh; only WHERE it is applied
# narrowed, to the structural openers above. The `-gt 0` guard is load-bearing,
# not defensive — a body with zero stanzas is no report at all and must not
# pass vacuously. ALLOW-list, not deny-list: a KIND CodeRabbit has not shipped
# yet reads as not-a-report, never as clean, including one containing angle
# brackets (`failure <head-changed>`), which the `.*` KIND span still matches.
#
# THREE states, not two (#942). The read status used to be swallowed by the
# `$( )`, which manufactured the zero-stanza state the `-gt 0` guard is
# watching for out of an infrastructure failure rather than out of the body —
# and the caller then logged the specific, WRONG diagnosis "carries a
# non-benign outcome stanza" for a body it had simply failed to read:
#
#   rc 0  every stanza present is benign — a completed marker-format report
#   rc 1  not a completed report (zero stanzas, or at least one non-benign)
#   rc 3  the body could NOT be read; the caller must HOLD, never drop the
#         summary out of scope
summary_stanzas_all_benign() {
  local openers total benign grc
  openers=$(summary_stanza_opener_lines "$1") || return 3
  [ -n "$openers" ] || return 1
  # The counters are READERS too, and `|| true` is rc-BLIND: it cannot tell
  # grep's no-match (rc 1, the only status it was ever meant to absorb, on
  # which `grep -c` still prints the 0 this wants) from grep's own ERROR
  # (rc >= 2 — an invalid multibyte sequence or a bad locale, which is one of
  # the production causes #942 names for the awk death). On an error grep
  # prints NOTHING, so `total` came back empty, `${total:-0}` manufactured the
  # zero-stanza state the `-gt 0` guard is watching for, and this predicate
  # returned 1 — the caller then logged the specific, WRONG diagnosis "carries
  # a non-benign outcome stanza" about a body it had failed to search and the
  # required gate cleared. That is exactly the misdiagnosis #942's acceptance
  # criterion 2 forbids, so the rc-3 rung has to cover the search as well as
  # the read.
  grc=0
  total=$(printf '%s\n' "$openers" | grep -c .) || grc=$?
  if [ "$grc" -gt 1 ]; then
    log "ERROR: counting the outcome-stanza openers failed on this summary body — the summary is UNSEARCHED, not stanza-free"
    return 3
  fi
  grc=0
  benign=$(printf '%s\n' "$openers" | grep -ciE "$CR_SUMMARY_BENIGN_STANZA_RE") || grc=$?
  if [ "$grc" -gt 1 ]; then
    log "ERROR: grading the outcome-stanza openers against the benign allow-list failed on this summary body — the summary is UNSEARCHED, not non-benign"
    return 3
  fi
  [ "${total:-0}" -gt 0 ] && [ "$total" = "$benign" ]
}

# True when the body carries at least one structural outcome stanza and at least
# one of them is NON-benign — i.e. CodeRabbit said in its own markup that this
# publication produced no review (`rate limited`, `failure`, `review in
# progress`).
#
# This is deliberately NOT the negation of summary_stanzas_all_benign. That
# predicate answers "is this a completed marker-format report?", and a body with
# ZERO stanzas fails it — correct for the marker format, whose completed shape
# always carries the `summarize` stanza. A review RUN object's body carries no
# such stanza at all (measured: mergepath#880 review 4848342765 closes with
# `<!-- This is an auto-generated comment by CodeRabbit for review status -->`,
# which is not a stanza opener), so requiring all-benign there would reject every
# genuine run body. The question the run-object acceptors need is the narrower
# one: did CodeRabbit itself declare this publication a non-review? Zero stanzas
# is not such a declaration; a `rate limited` stanza is.
#
# Same three-rung contract as summary_stanzas_all_benign (rc 3 = unreadable),
# and here the swallow was the more dangerous of the two: this predicate is
# read through a `!` at its call site, so an unreadable body came back as
# "no non-benign stanza" and the run was ACCEPTED as a recognised summary.
summary_has_non_benign_stanza() {
  local openers nonbenign grc
  openers=$(summary_stanza_opener_lines "$1") || return 3
  [ -n "$openers" ] || return 1
  # Same rc split as above, and the same reason `|| true` cannot make it:
  # `grep -vc` exits 1 when every line matches (still printing the 0 this
  # wants) and >= 2 on its own error, printing nothing. Here the swallow was
  # the worse of the two, because this predicate is read through a `!` at its
  # call site: an unsearched body came back as "no non-benign stanza" and the
  # run was ACCEPTED as a recognised summary.
  grc=0
  nonbenign=$(printf '%s\n' "$openers" | grep -vciE "$CR_SUMMARY_BENIGN_STANZA_RE") || grc=$?
  if [ "$grc" -gt 1 ]; then
    log "ERROR: grading the outcome-stanza openers against the benign allow-list failed on this summary body — the summary is UNSEARCHED, so whether it declares a non-review is unknown"
    return 3
  fi
  [ "${nonbenign:-0}" -gt 0 ]
}

# True when $2 (the PR HEAD sha) is the RANGE END of a `between <prev> and
# <head>` commits line in $1. Position matters twice over: the range START is
# the PREVIOUSLY-reviewed head, so a force-push back to it would read a later
# round's summary as this head's; and a "Review failed" body names the
# abandoned NEW head in refusal prose ("changed during the review from X to
# Y"), which a position-blind token match accepts.
#
# The range is EXTRACTED and then compared as a string rather than
# interpolating the head into the pattern. Require full object IDs: a shortened
# SHA is not a unique commit identifier, and a PR author can produce a later
# head with the same prefix. Keeping the head out of the regex means no
# caller-supplied value is ever evaluated as a pattern.
summary_names_head() {
  local ranges end want r
  # Extracted from the UNFENCED body only (Codex P1 round 5 on #886). A
  # whole-body match accepted a `between <sha> and <sha>` string that CodeRabbit
  # was merely QUOTING from the diff, which is enough to make a stale summary
  # read as this head's report — and both error directions are unsafe here, so
  # this is one of the few places where precision matters rather than a
  # fail-direction argument. Excluding fenced quotes is a strict improvement:
  # CodeRabbit's own commits row is never inside a fence, so nothing genuine is
  # lost.
  #
  # NOT narrowed to the `📥 Commits` section, though that would be more precise
  # still: the section heading is CodeRabbit presentation that can change
  # without notice, and if it did, the range would stop being found, the summary
  # would fall out of scope, and its findings would go ungated. That is a false
  # CLEAR bought with precision, which is the wrong trade for a required gate.
  #
  # Three rungs, as above (#942): rc 3 is "I could not read this body", which
  # the `|| true` used to flatten into rc 1, "this body names no commits
  # range" — i.e. into "not this head's report", which drops the summary and
  # clears the gate.
  #
  # The commits-range grep below carries the same rung for the same reason.
  # `|| true` is rc-BLIND — it absorbs grep's no-match (rc 1) and grep's own
  # ERROR (rc >= 2, reachable on an invalid multibyte sequence or a bad
  # locale) identically, and on an error grep prints nothing, so `ranges` came
  # back empty and this returned 1: "not this head's report", from a body that
  # was never searched. Statuses are captured explicitly rather than absorbed.
  local numbered stripped grc
  numbered=$(summary_unfenced_numbered "$1") || return 3
  stripped=$(printf '%s\n' "$numbered" | sed 's/^[0-9]*	//') || {
    log "ERROR: could not strip line numbers off the summary body while looking for its commits range — the summary is UNREAD"
    return 3
  }
  grc=0
  ranges=$(printf '%s\n' "$stripped" \
    | grep -oiE 'between [0-9a-f]{40} and [0-9a-f]{40}') || grc=$?
  if [ "$grc" -gt 1 ]; then
    log "ERROR: the commits-range scan failed on this summary body — the summary is UNSEARCHED, not range-free"
    return 3
  fi
  [ -n "$ranges" ] || return 1
  # Hex is case-insensitive; GitHub renders shas lowercase but the comparison
  # must not depend on that, or an uppercase range would silently drop this
  # head's summary out of scope.
  want=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  # Exact comparison only. An abbreviated end cannot distinguish the current
  # head from another commit with the same prefix, so fail closed until the
  # summary names the full current object ID.
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    end=$(printf '%s' "$r" | awk '{print $4}' | tr '[:upper:]' '[:lower:]')
    [ -n "$end" ] || continue
    [ "$end" = "$want" ] && return 0
  done <<EOF
$ranges
EOF
  return 1
}

# Drop CodeRabbit's pre-merge check table from the body before classifying.
# That table grades PR hygiene and renders a `⚠️ Warning` row for a
# below-threshold docstring score — not a code finding (3 of 5 sampled
# summaries carry one).
#
# STRUCTURAL and FENCE-AWARE, on the same reasoning as the stanza parser above
# (Codex P1 round 4 on #886), and this one is the more dangerous of the pair
# because it deletes text rather than reclassifying it. Matching the delimiter
# as a SUBSTRING anywhere let PR-controlled text move the suppressor's start:
# a PR whose diff contains the start delimiter, quoted back by CodeRabbit in
# its walkthrough ABOVE the genuine table, made the strip span from that quote
# to the real table's end — silently deleting every genuine blocking finding in
# between and clearing a required gate. So a delimiter counts only as a whole
# line at column 0, outside a fenced code block.
#
# The pairing rule is unchanged and still load-bearing: strip only a START that
# has an END AFTER it. With presence alone checked, a stray START (or an END
# rendered first) latches the suppressor and drops everything to EOF.
#
# rc 3 when the body could not be read (#942). The fail DIRECTION of a
# swallowed read is milder here than at the other two sites — an unread body
# yields no pair, the strip becomes a no-op, and the un-stripped body reaches
# the classifier, which can only ADD findings — but "milder" is not a contract.
# Silently skipping the suppressor means the gate grades the pre-merge check
# table's hygiene `⚠️ Warning` rows as code findings and reports a blocking
# summary finding that CodeRabbit never made, which under `enforce_admins:
# true` is a red with no honest ack to write. Say "unread" and let the caller
# decide.
summary_strip_pre_merge_block() {
  local body=$1 pair numbered stripped
  numbered=$(summary_unfenced_numbered "$body") || return 3
  # Emit "<start_line> <end_line>" for the first structural START that is
  # followed by a structural END, or nothing at all.
  pair=$(printf '%s\n' "$numbered" | awk -F'\t' \
    -v s="$CR_PRE_MERGE_BLOCK_START" -v e="$CR_PRE_MERGE_BLOCK_END" '
    {
      n = $1
      line = substr($0, index($0, "\t") + 1)
      sub(/[ \t]+$/, "", line)
      if (line == s && !have_s) { have_s = 1; sl = n; next }
      if (line == e && have_s) { print sl " " n; exit }
    }
  ') || {
    log "ERROR: the pre-merge-block scan failed on this summary body — the summary is UNREAD, so the check table cannot be located"
    return 3
  }
  if [ -n "$pair" ]; then
    # The STRIP is a reader too, and it was the last unchecked one in this
    # function: its output IS this function's return value, so a dead awk here
    # produced an empty SUMMARY_SCAN and the caller's `[ -n "$SUMMARY_SCAN" ]`
    # skipped the entire grading block — a required gate cleared on a body
    # carrying a 🟠 Major, which is the very defect #942 exists to close, one
    # line below the two reads above it.
    #
    # errexit does NOT rescue a streamed pipeline here, which is why the
    # status is captured rather than left to `set -e`. The sole call site is
    # `SUMMARY_SCAN=$(summary_strip_pre_merge_block "$SUMMARY_BODY") || die 2`,
    # and errexit is suppressed inside a command substitution on the left of an
    # `||` list: a dying awk that has already emitted a partial stream yields
    # rc 0 and that partial output, uncaught (probed on bash 3.2).
    stripped=$(printf '%s\n' "$body" \
      | awk -v sl="${pair% *}" -v el="${pair#* }" 'NR < sl || NR > el') || {
      log "ERROR: the pre-merge-block strip failed on this summary body — the summary is UNREAD, so the check table could not be removed"
      return 3
    }
    if [ -n "$stripped" ]; then
      printf '%s\n' "$stripped"
    fi
    return 0
  fi
  printf '%s' "$body"
}

# Fingerprint the classified blocking summary lines, for the ack token below.
# Portable SHA-256 (sha256sum on Linux/CI, shasum -a 256 on macOS), truncated
# to 12 hex chars — this is a change detector, not a security boundary: the
# collaborator copies whatever the gate prints, so the only property that
# matters is that a different finding set yields a different token. With
# neither hasher on PATH the gate cannot bind an ack to a finding set at all,
# which is a config error (die 2), never a silent fall back to head-only
# pinning.
summary_findings_fingerprint() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256)
  else
    die 2 "neither sha256sum nor shasum found on PATH — cannot fingerprint the summary finding set for the acknowledgement token"
  fi
  printf '%s' "$out" | awk '{print substr($1, 1, 12)}'
}

# The issues endpoint is a REQUIRED read: an unreadable one is a scan that
# cannot be trusted complete, so fetch_api_array's die 2 (fail closed) is the
# correct outcome — never an empty result silently treated as "no findings".
ISSUE_COMMENTS_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "PR-level issue comments")

REQUIRE_REVIEW_SUMMARY=${REQUIRE_REVIEW_SUMMARY:-false}
case "$REQUIRE_REVIEW_SUMMARY" in
  true|false) ;;
  *) die 2 "REQUIRE_REVIEW_SUMMARY must be true|false; got '$REQUIRE_REVIEW_SUMMARY'" ;;
esac

# `startswith`, not `contains` — the same predicate scripts/coderabbit-wait.sh
# uses at its own selection site, and for the same reason (Codex P1 round 2 on
# #886). The marker opens the real summary at byte zero; a CodeRabbit CHAT
# REPLY can QUOTE it further down. Containment lets such a reply — which always
# has the higher comment id, so `last` picks it — stand in for the summary. It
# carries no structural stanza, so it is then rejected as "not a completed
# report" and the real current-head summary is never examined: a false CLEAR of
# this required gate. The shape is a live one, fixture 7917/7918 in
# tests/test_coderabbit_wait_status_probe.sh (#794).
#
# CodeRabbit also has a markerless full-review format whose first line is
# `**Actionable comments posted: N**` (#886, Codex P1). In production that
# format is written in the REVIEW OBJECT body, which is where the primary
# acceptor below reads it from. The same predicate is still applied to this
# PR-comment surface as a retained secondary acceptor: it costs nothing, it can
# only ADD candidates (the fail-closed direction), and a serialization that
# moved onto comments must not silently un-gate its findings. On that surface
# the shape is not enough on its own — unlike the marker format it carries no
# commits-range anchor — so accept it only when a CodeRabbit review run is
# anchored to this exact PR head, and only when the comment is fresh at-or-after
# that run; otherwise an older markerless body can inherit a later exact-head
# object and briefly publish a stale verdict.
MARKER_SUMMARY_JSON=$(echo "$ISSUE_COMMENTS_JSON" | jq -c \
  --arg bot "$BOT_LOGIN" --arg m "$CR_SUMMARY_MARKER" '
  [ .[]
    | select(.user.login == $bot)
    | select((.body // "") | startswith($m))
    | . + { fresh_at: ([.created_at, (.updated_at // .created_at)]
                        | map(select(type == "string" and . != "")) | max // "") }
  ]
  | sort_by(.id)
  | last
  | { id: (.id // 0), body: (.body // ""), fresh_at: (.fresh_at // "") }
')
MARKER_SUMMARY_ID=$(echo "$MARKER_SUMMARY_JSON" | jq -r '.id')
MARKER_SUMMARY_BODY=$(echo "$MARKER_SUMMARY_JSON" | jq -r '.body')
MARKER_SUMMARY_FRESH_AT=$(echo "$MARKER_SUMMARY_JSON" | jq -r '.fresh_at')

# --- head-pinned CodeRabbit review RUN objects ------------------------------
#
# Read UNCONDITIONALLY, because pulls/{pr}/reviews is the surface CodeRabbit's
# markerless full-review summary is actually written on. Measured across ten
# real PRs (#886, #902, #889, #884, #874, #873, #866, #872, #880, #867):
# `**Actionable comments posted: N**` occurs ZERO times in issues/{pr}/comments
# and SEVENTEEN times in pulls/{pr}/reviews. Applying the markerless predicate
# only to the comment surface made that acceptor contribute a candidate zero
# percent of the time against production data, so with a TERMINAL CodeRabbit on
# the head the candidate set was routinely EMPTY, the publication hold below
# never cleared, and the required check stayed red with no break-glass under
# `enforce_admins: true`.
#
# Unconditional rather than flag-gated: both bundled workflow arms already set
# REQUIRE_REVIEW_SUMMARY=true and so already pay for this read, and for an
# ad-hoc caller the alternative to paying for it is not reading the surface the
# findings are on — a false CLEAR of a required gate rather than a saving. A
# failed read is fetch_api_array's die 2, never an empty result read as "no
# findings".
REVIEWS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "CodeRabbit review objects")

# Only a review RUN carries (and anchors) a summary — a NON-EMPTY body is the
# discriminator, the same one mergepath#900 measured. CodeRabbit also creates a
# head-pinned COMMENTED review object for a conversational REPLY on a review
# thread (its answer to a rebuttal, or to the `[mergepath-resolve:<class>]` tag
# reply resolve-pr-threads.sh posts to clear the pre-merge conversation gate).
# Those carry an empty body and start no run, so no summary ever accompanies
# them. Taking the newest object outright let a reply that lands AFTER the
# summary push the correlation floor past it, and the filter below then
# discarded the genuine current summary — a permanent hold on a PR whose review
# demonstrably finished, re-armed by every thread reply. Five such objects sat
# on this PR's own head while its one real run carried a 9906-byte body.
#
# DISMISSED counts as a run (Codex P1 on #886). The question here is whether the
# bot reviewed this head, not whether its review is still standing — and
# `pull_request_review: [dismissed]` is one of this gate's own triggers, so
# dropping the state made dismissing the review re-run the gate with its anchor
# removed. A markerless summary then fell out of scope and a summary-only
# blocking finding cleared on exit 0, giving dismissal a second job as a bypass
# of the collaborator ack channel that is supposed to be the only way off that
# surface.
HEAD_REVIEW_RUNS_JSON=$(echo "$REVIEWS_JSON" | jq -c \
  --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
  [ .[]
    | select(.user.login == $bot)
    | select(.commit_id == $sha)
    | select(.state == "COMMENTED" or .state == "APPROVED"
             or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
    | select(((.body // "") | gsub("\\s"; "")) != "")
    | { id: (.id // 0),
        body: (.body // ""),
        fresh_at: (.submitted_at | if type == "string" then . else "" end) }
  ]
  | sort_by(.fresh_at, .id)
')
HEAD_REVIEW_AT=$(echo "$HEAD_REVIEW_RUNS_JSON" | jq -r '
  [ .[] | .fresh_at | select(. != "") ] | max // ""
')
HEAD_REVIEW_RUN_IDS=$(echo "$HEAD_REVIEW_RUNS_JSON" | jq -r \
  '[ .[] | .id | tostring ] | join(", ")')

# The marker-led summarize and markerless full-review serializations are both
# live CodeRabbit protocols. They are not mutually exclusive: a stale marker
# comment must never suppress a current markerless review summary, or vice
# versa. Scope each independently, then classify every current candidate below.
SUMMARY_CANDIDATES='[]'
if [ "$MARKER_SUMMARY_ID" != "0" ]; then
  # Both scope predicates are read as THREE-way (#942), never as booleans. The
  # `if ! …` / `elif ! …` shape collapsed each helper's rc 3 (body UNREADABLE)
  # into rc 1 (body says no), and rc 1 here means "not this head's completed
  # report" — which drops the summary out of scope entirely, so the graded
  # pipeline's own #936 guard is never reached and the gate prints
  # `CodeRabbit blocking-tier unresolved: 0`. That is strictly worse than the
  # site #936 fixed, because it fires EARLIER.
  #
  # Exit 2, the config/infra code this gate already uses for "cannot decide",
  # and the log names the unread body rather than asserting a diagnosis about
  # its contents. The old messages did assert one — "carries a non-benign
  # outcome stanza" for a body carrying no such stanza — which sends an
  # operator looking for a CodeRabbit rate limit instead of a broken read.
  MARKER_BENIGN_RC=0
  summary_stanzas_all_benign "$MARKER_SUMMARY_BODY" || MARKER_BENIGN_RC=$?
  MARKER_NAMES_HEAD_RC=0
  if [ "$MARKER_BENIGN_RC" = "3" ]; then
    die 2 "could not READ the PR-level summary (comment id $MARKER_SUMMARY_ID) while classifying its outcome stanzas — an unread summary is not a non-report, and refusing to drop it from scope is the only answer that cannot clear this gate on a summary nobody read"
  elif [ "$MARKER_BENIGN_RC" != "0" ]; then
    log "PR-level summary (comment id $MARKER_SUMMARY_ID) carries a non-benign outcome stanza (rate limit / failure / in progress) — not a completed report, no summary findings in scope"
  else
    summary_names_head "$MARKER_SUMMARY_BODY" "$HEAD_SHA" || MARKER_NAMES_HEAD_RC=$?
    if [ "$MARKER_NAMES_HEAD_RC" = "3" ]; then
      die 2 "could not READ the PR-level summary (comment id $MARKER_SUMMARY_ID) while looking for its commits range — an unread summary is not a stale one, and dropping it out of scope would clear this gate on a summary nobody read"
    elif [ "$MARKER_NAMES_HEAD_RC" != "0" ]; then
      log "PR-level summary (comment id $MARKER_SUMMARY_ID) does not name $HEAD_SHA as its commits-range end — not this head's report, no summary findings in scope"
    else
      SUMMARY_CANDIDATES=$(echo "$SUMMARY_CANDIDATES" | jq -c \
        --argjson id "$MARKER_SUMMARY_ID" --arg body "$MARKER_SUMMARY_BODY" \
        --arg fresh_at "$MARKER_SUMMARY_FRESH_AT" \
        '. + [{id: $id, body: $body, scope: "commits-range", fresh_at: $fresh_at}]')
    fi
  fi
fi

# PRIMARY ACCEPTORS: the full-review summary in the body of a head-pinned review
# RUN object.
#
# Scoped by the object's GitHub-owned `commit_id` alone — the same
# no-spoofable-timestamp posture the marker-led commits range has, and a
# STRONGER one than the marker path can offer, because the anchor travels with
# the report instead of having to be re-stamped onto a comment afterwards. That
# distinction is the whole defect this closes: CodeRabbit updates the
# walkthrough comment IN PLACE and does not reliably re-carry a commits range
# naming the current head, so the marker-led path can find nothing while
# CodeRabbit is demonstrably terminal on that head (measured on this PR: review
# object present, commit StatusContext `CodeRabbit = success`, walkthrough still
# naming an older head). The marker-led path above therefore stays an ACCEPTOR
# and is no longer a REQUIREMENT.
#
# TWO acceptors, because ONE does not cover CodeRabbit's ordinary terminal
# report. Measured across `pulls/{pr}/reviews` for 20 mergepath PRs (#886, #902,
# #900, #898, #889, #884, #874, #873, #872, #869, #867, #866, #880, #865, #849,
# #843, #909, #876, #887, #883): of 22 non-empty `coderabbitai[bot]` review
# bodies, 2 (9%) carry NO `Actionable comments posted` header at all — they open
# with a blank line and then `<details><summary>🧹 Nitpick comments (N)</summary>`
# (mergepath#880 review 4848342765 on 9601e872, mergepath#849 review 4833684457
# on 1b8195da). Both are COMPLETE terminal reports, and on #880's head that
# object was the only CodeRabbit review object there was. With the header as the
# sole acceptor the candidate set was empty on a terminal review, which is rc 3 —
# and rc 3 is unretirable: the event-driven arm publishes a native FAILURE on
# that head and the sweep, the only arm that can restore the check, declines to
# publish on it. Every later sweep re-reads the same stable body and skips again,
# `@coderabbitai full review` reproduces the same serialization, and
# `enforce_admins: true` leaves no break-glass. So the second acceptor is not a
# convenience: without it this gate manufactures exactly the red nothing retires
# that the spec says it cannot.
#
#   1. HEADER — the body matches CR_MARKERLESS_FULL_REVIEW_RE, the machine-shaped
#      result line of the format CodeRabbit writes most of the time.
#   2. SELF-ANCHORED — the body carries its OWN `📥 Commits` range whose end names
#      this head. That is the same bot-authored evidence the marker-led path
#      accepts on the comment surface, here corroborated by the object's
#      GitHub-owned `commit_id`: two independent anchors naming the same head,
#      which is strictly stronger than the marker path's one. The #880 body
#      carries `between 21cf07b5… and 9601e872…` — the anchor the gate needed was
#      inside the object it was already holding on.
#
# Acceptor 2 declines a body whose own markup says the publication produced no
# review (a `rate limited` / `failure` / `review in progress` stanza). It does
# NOT require the marker format's all-benign test: a run body legitimately
# carries zero stanzas, so demanding one would reject every real run.
#
# The recognised runs are collected in order (the sort_by above), so `last` is
# the newest: a same-head re-review's newer run wins over the run it replaced,
# and the superseded body is dropped by the correlation filter below on the
# review-triggered path, exactly as a superseded marker-led summary is.
HEAD_SUMMARY_RUNS_JSON='[]'
while IFS= read -r cr_run_json; do
  [ -n "$cr_run_json" ] || continue
  cr_run_body=$(printf '%s' "$cr_run_json" | jq -r '.body')
  cr_run_recognised_by=''
  # jq's `test` rather than a shell grep, so the acceptor keeps the exact
  # semantics the constant was written against.
  if printf '%s' "$cr_run_json" \
      | jq -e --arg re "$CR_MARKERLESS_FULL_REVIEW_RE" '.body | test($re)' >/dev/null; then
    cr_run_recognised_by='markerless-result-line'
  else
    # Acceptor 2, read three-way (#942). The `&& ! …` conjunction was the worst
    # of the swallowed-status sites in this file because the two operands fail
    # in OPPOSITE directions: an unreadable body makes summary_names_head look
    # like "not this head" (the run is skipped, which can strand the gate on
    # the publication HOLD), while the NEGATED summary_has_non_benign_stanza
    # turns the same unreadable body into "no refusal stanza" — i.e. this run
    # gets ACCEPTED as a recognised summary and then graded, from a body no
    # reader ever got through.
    cr_names_head_rc=0
    summary_names_head "$cr_run_body" "$HEAD_SHA" || cr_names_head_rc=$?
    cr_nonbenign_rc=0
    if [ "$cr_names_head_rc" = "3" ]; then
      die 2 "could not READ the body of CodeRabbit review run $(printf '%s' "$cr_run_json" | jq -r '.id') while looking for its own commits range — refusing to decide whether it reports on $HEAD_SHA from a body nobody read"
    elif [ "$cr_names_head_rc" = "0" ]; then
      summary_has_non_benign_stanza "$cr_run_body" || cr_nonbenign_rc=$?
      if [ "$cr_nonbenign_rc" = "3" ]; then
        die 2 "could not READ the body of CodeRabbit review run $(printf '%s' "$cr_run_json" | jq -r '.id') while checking it for a refusal stanza — refusing to accept an unread body as a completed report"
      elif [ "$cr_nonbenign_rc" != "0" ]; then
        cr_run_recognised_by='own-commits-range'
      fi
    fi
  fi
  [ -n "$cr_run_recognised_by" ] || continue
  HEAD_SUMMARY_RUNS_JSON=$(echo "$HEAD_SUMMARY_RUNS_JSON" | jq -c \
    --argjson run "$cr_run_json" --arg by "$cr_run_recognised_by" \
    '. + [ $run + {recognised_by: $by} ]')
done <<EOF
$(echo "$HEAD_REVIEW_RUNS_JSON" | jq -c '.[]')
EOF

# The correlation floor for the same-head re-review filter below. Taken from the
# runs that actually CARRY a recognised summary, never from any non-empty run
# (CodeRabbit Major / Codex P1 on #886). HEAD_REVIEW_AT is max(submitted_at) over
# every non-empty head-pinned run INCLUDING ones no acceptor recognises, and
# using it as the floor let a later unrecognised run discard the recognised
# summary — up to and including the review-object-body candidate itself, whose
# fresh_at IS its own run's submitted_at. Both input shapes are production-real:
# same-head double runs exist (#886 commit 5d04dfc9 → reviews 4860672174 +
# 4860719383), and an unrecognised body is whatever serialization the acceptors
# above have not been taught. The result was that a head carrying a demonstrably
# recognised summary — with a genuine Major in it — reported neither the Major
# nor a success, reaching the same unretirable red from the opposite direction.
#
# HEAD_REVIEW_AT keeps its own job: it arms the publication HOLD, which asks "did
# CodeRabbit run on this head at all", not "which publication does this candidate
# belong to". The two questions have different answers and now have different
# variables.
SUMMARY_CORRELATION_AT=$(echo "$HEAD_SUMMARY_RUNS_JSON" | jq -r '
  [ .[] | .fresh_at | select(. != "") ] | max // ""
')

# The head-pinned runs NO acceptor recognised, restricted to the ones NEWER than
# every recognised summary (Codex P1 round 15 on #886). Taking the correlation
# floor from recognised runs alone fixed one asymmetry and opened its mirror
# image: a later unrecognised run no longer discards the earlier recognised
# candidate, so when that earlier candidate is CLEAN the gate publishes success
# while CodeRabbit's newest serialization on this head sits unread — which is
# exactly the summary-only blocking finding this gate exists to catch. The
# candidate is not "stale" in the sense the floor is about, but the head is no
# longer fully read, and the spec's contract is that a completed current-head run
# with no recognised summary HOLDS.
#
# `$at == ""` (no recognised run at all) counts every unrecognised run, because
# then nothing on the review surface has been read and any verdict in hand came
# from the comment surface alone.
#
# This does NOT drop candidates, and that distinction is the whole point. Codex's
# literal remedy — treat the newer unrecognised run as superseding older
# candidates — is the HEAD_REVIEW_AT floor again, and it re-breaks the case this
# round fixed: an earlier recognised summary carrying a real Major would vanish
# into the hold instead of being reported. Both properties hold together because
# they apply to different verdicts. A blocking finding still gates on exit 1 —
# fail-closed, retirable by a push, and it names the finding. Only a would-be
# PASS is withheld, which is the verdict an unread run can actually invalidate.
#
# "NEWER" IS TOTAL, AND UNKNOWN ORDER COUNTS AS NEWER (CodeRabbit Major on #886).
# `>` on the timestamp alone leaves two fail-OPEN gaps, and both matter here for
# the opposite reason they are safe elsewhere in this file. A candidate with no
# usable timestamp is DROPPED by the correlation filter, and dropping is the safe
# direction there; an unread RUN with no usable timestamp must be KEPT, because
# ignoring it is exactly the certify-on-an-older-clean-summary hole this block
# exists to close. So an unrecognised run whose `submitted_at` is absent or
# non-string counts as newer unconditionally: the gate cannot place it in the
# order, and a run it cannot order is a run it must not certify around.
# Equal timestamps are broken by the run id, giving the same total order
# `(fresh_at, id)` that HEAD_REVIEW_RUNS_JSON is already sorted by — two runs can
# share a second, and under `>` alone the later one silently read as not-newer.
SUMMARY_CORRELATION_ID=$(echo "$HEAD_SUMMARY_RUNS_JSON" | jq -r 'last.id // 0')
HEAD_UNRECOGNISED_NEWER_IDS=$(jq -rn \
  --argjson runs "$HEAD_REVIEW_RUNS_JSON" \
  --argjson recognised "$HEAD_SUMMARY_RUNS_JSON" \
  --arg at "$SUMMARY_CORRELATION_AT" \
  --argjson atid "$SUMMARY_CORRELATION_ID" '
  ($recognised | map(.id)) as $known
  | [ $runs[]
      # `. as $run` FIRST: inside `index(...)` the input `.` is $known, the
      # ARRAY, so a bare `.id` there indexes an array with a string and aborts
      # the whole gate (the jq dot-rebind hazard).
      | . as $run
      | select(($known | index($run.id)) == null)
      | (if ($run.fresh_at | type) == "string" then $run.fresh_at else "" end) as $ts
      | select($at == ""
               or $ts == ""
               or $ts > $at
               or ($ts == $at and ($run.id // 0) > $atid))
      | ($run.id | tostring) ]
  | join(", ")
')

REVIEW_OBJECT_SUMMARY_JSON=$(echo "$HEAD_SUMMARY_RUNS_JSON" | jq -c 'last // {}')
REVIEW_OBJECT_SUMMARY_ID=$(echo "$REVIEW_OBJECT_SUMMARY_JSON" | jq -r '.id // 0')
if [ "$REVIEW_OBJECT_SUMMARY_ID" != "0" ]; then
  REVIEW_OBJECT_SUMMARY_BODY=$(echo "$REVIEW_OBJECT_SUMMARY_JSON" | jq -r '.body')
  REVIEW_OBJECT_SUMMARY_FRESH_AT=$(echo "$REVIEW_OBJECT_SUMMARY_JSON" | jq -r '.fresh_at // ""')
  REVIEW_OBJECT_SUMMARY_BY=$(echo "$REVIEW_OBJECT_SUMMARY_JSON" | jq -r '.recognised_by // ""')
  SUMMARY_CANDIDATES=$(echo "$SUMMARY_CANDIDATES" | jq -c \
    --argjson id "$REVIEW_OBJECT_SUMMARY_ID" --arg body "$REVIEW_OBJECT_SUMMARY_BODY" \
    --arg fresh_at "$REVIEW_OBJECT_SUMMARY_FRESH_AT" --arg by "$REVIEW_OBJECT_SUMMARY_BY" \
    '. + [{id: $id, body: $body, scope: "review-object-body", fresh_at: $fresh_at,
           recognised_by: $by}]')
fi

MARKERLESS_SUMMARIES_JSON=$(echo "$ISSUE_COMMENTS_JSON" | jq -c \
  --arg bot "$BOT_LOGIN" --arg re "$CR_MARKERLESS_FULL_REVIEW_RE" '
  [ .[]
    | select(.user.login == $bot)
    | select((.body // "") | test($re))
    | . + { fresh_at: ([.created_at, (.updated_at // .created_at)]
                        | map(select(type == "string" and . != "")) | max // "") }
  ]
  | map({ id: (.id // 0), body: (.body // ""), fresh_at })
')
MARKERLESS_SUMMARY_COUNT=$(echo "$MARKERLESS_SUMMARIES_JSON" | jq 'length')
# The comment-surface acceptor needs BOTH halves of the anchor, and they are two
# different variables for the reason above. EXISTENCE stays on HEAD_REVIEW_AT —
# any completed run proves CodeRabbit reviewed this head, which is what a body
# with no anchor of its own is borrowing. FRESHNESS prefers the recognised-summary
# floor, so a later unrecognised run cannot push the floor past a comment that
# genuinely belongs to the current publication. With no recognised run the two
# collapse to the previous behaviour.
if [ -n "$SUMMARY_CORRELATION_AT" ]; then
  SUMMARY_FRESHNESS_AT=$SUMMARY_CORRELATION_AT
else
  SUMMARY_FRESHNESS_AT=$HEAD_REVIEW_AT
fi
if [ "$MARKERLESS_SUMMARY_COUNT" -gt 0 ]; then
  MARKERLESS_SUMMARY_JSON=$(echo "$MARKERLESS_SUMMARIES_JSON" | jq -c --arg at "$SUMMARY_FRESHNESS_AT" '
    if $at == "" then null
    else [ .[] | select(.fresh_at >= $at) ] | sort_by(.fresh_at, .id) | last
    end
  ')
  MARKERLESS_SUMMARY_ID=$(echo "$MARKERLESS_SUMMARY_JSON" | jq -r '.id // 0')
  if [ "$MARKERLESS_SUMMARY_ID" != "0" ]; then
    MARKERLESS_SUMMARY_BODY=$(echo "$MARKERLESS_SUMMARY_JSON" | jq -r '.body')
    # fresh_at travels WITH the candidate. This selection has already applied
    # the >= HEAD_REVIEW_AT floor, so dropping the field would leave the
    # correlation filter below reading it as "" and discarding a candidate it
    # had just admitted — a false HOLD on the review-triggered path (CodeRabbit
    # Major on #886).
    MARKERLESS_SUMMARY_FRESH_AT=$(echo "$MARKERLESS_SUMMARY_JSON" | jq -r '.fresh_at // ""')
    SUMMARY_CANDIDATES=$(echo "$SUMMARY_CANDIDATES" | jq -c \
      --argjson id "$MARKERLESS_SUMMARY_ID" --arg body "$MARKERLESS_SUMMARY_BODY" \
      --arg fresh_at "$MARKERLESS_SUMMARY_FRESH_AT" \
      '. + [{id: $id, body: $body, scope: "review-object", fresh_at: $fresh_at}]')
  elif [ -z "$HEAD_REVIEW_AT" ]; then
    log "markerless CodeRabbit full-review candidate has no timestamped completed CodeRabbit review object on $HEAD_SHA — no summary findings in scope"
  else
    log "markerless CodeRabbit full-review candidate predates completed CodeRabbit review object on $HEAD_SHA — no summary findings in scope"
  fi
fi

# Same-head re-review correlation, on the review-triggered path ONLY (Codex P1
# on #886). The scope predicates above are SHA-only for a marker-led summary:
# its commits-range end still names this head after CodeRabbit re-reviews the
# SAME head (the `@coderabbitai full review` recovery flow, mergepath#898). So
# the previous — possibly clean — summary keeps SUMMARY_CANDIDATE_COUNT
# nonzero, the publication hold below never fires, and the run can publish
# success in the window before the replacement summary lands. Correlate the
# candidate to the triggering review the same way the markerless path already
# does, by requiring it to be fresh at-or-after the completed review object on
# this head; a candidate that predates it belongs to the previous publication.
#
# Restricted to REQUIRE_REVIEW_SUMMARY=true because dropping the candidate is
# only safe there: with the flag set, zero candidates reaches the hold below and
# exits 3, which withholds a verdict. Without it, zero candidates means "nothing
# in scope yet" and PASSES, so applying the same filter would discard a real
# summary finding and fail OPEN. Both bundled workflow arms set the flag; the
# default-false path is for ad-hoc and third-party callers, which have no
# publication to withhold. A missing or unparseable timestamp sorts below any
# real one and is therefore dropped, which is the safe direction here.
#
# The floor is SUMMARY_CORRELATION_AT — the newest run carrying a RECOGNISED
# summary — and never HEAD_REVIEW_AT. A run this gate cannot read is not a
# publication a candidate can be late for, and treating it as one discarded the
# recognised summary and produced a hold on a head where the verdict was sitting
# in hand. With no recognised run the floor is empty and no candidate is dropped:
# the marker-led surface then supplies the verdict, which is the same answer this
# filter would have given before any review object existed.
if [ "$REQUIRE_REVIEW_SUMMARY" = "true" ] && [ -n "$SUMMARY_CORRELATION_AT" ]; then
  SUMMARY_UNCORRELATED=$(echo "$SUMMARY_CANDIDATES" | jq -r --arg at "$SUMMARY_CORRELATION_AT" '
    [ .[] | select((.fresh_at // "") < $at) | (.id | tostring) ] | join(", ")
  ')
  if [ -n "$SUMMARY_UNCORRELATED" ]; then
    log "PR-level summary comment(s) $SUMMARY_UNCORRELATED predate the completed CodeRabbit review object on $HEAD_SHA — not this review's publication"
    SUMMARY_CANDIDATES=$(echo "$SUMMARY_CANDIDATES" | jq -c --arg at "$SUMMARY_CORRELATION_AT" '
      [ .[] | select((.fresh_at // "") >= $at) ]
    ')
  fi
fi

# Classify the summary with the SAME shared coderabbit_tier_of the inline path
# uses — there is deliberately no second classifier. It is applied PER LINE
# rather than to the whole body because the classifier truncates its input to
# the first 600 chars (a deliberate anti-drift choice for a single finding
# body, and wrong for a multi-kilobyte summary): line-wise application is
# exactly a whole-body scan with the truncation removed, and it yields a
# reportable location and snippet per finding for free.
#
# The acknowledgement token below is fingerprinted from the WHOLE classified
# body (SUMMARY_FINDINGS_FINGERPRINT_INPUT), not from the classified lines
# alone. Fingerprinting only the marker-bearing lines was the round-2 shape and
# it was very nearly a no-op (Codex P1 round 1 on #886): CodeRabbit writes a
# finding as a marker line — `_⚠️ Potential issue_` — on its own, with the
# actual finding on the lines BELOW it, so a same-head re-review that replaces
# finding A with finding B keeps that marker line byte-identical and produced
# an identical fingerprint. A's ack then cleared B, which is exactly the false
# clear the fingerprint was introduced to prevent.
#
# Hashing the whole classified body is deliberately blunter than hashing
# per-finding blocks. A block-scoped fingerprint would have to decide where a
# finding ends, and the boundary is not ours to define — CodeRabbit owns that
# layout, and a wrong boundary silently reopens this same hole (a finding whose
# file header sits ABOVE its marker moves between files without the hash
# moving). Whole-body errs toward invalidating an ack that a cosmetic edit
# would have survived, and that error is free: the gate stays red and prints
# the fresh token, so recovery is one line. The opposite error passes an
# undispositioned blocking finding through a required gate. The pre-merge check
# table — the one part of the body that churns without a re-review — is already
# stripped before this point, so ordinary noise does not reach the hash.
SUMMARY_BLOCKING='[]'
SUMMARY_FINDINGS_FINGERPRINT_INPUT=''
SUMMARY_CANDIDATE_COUNT=$(echo "$SUMMARY_CANDIDATES" | jq 'length')
if [ "$SUMMARY_CANDIDATE_COUNT" -eq 0 ]; then
  if [ "$REQUIRE_REVIEW_SUMMARY" = "true" ] && [ -n "$HEAD_REVIEW_AT" ]; then
    # Exit 3, NOT 1 (Codex P1 + CodeRabbit Major on #886). "A review has begun
    # and its summary is not published yet" is not a finding count, and the two
    # publishers have to act on it differently: an event-driven run has to go
    # non-green, while the sweep — the only publisher that can restore this
    # check through the Checks API — must DECLINE TO PUBLISH rather than
    # overwrite the event run's red with a success read off the previous
    # publication. Collapsing both into 1 forced a choice between a sweep that
    # reopens the gap and a sweep that can hold a required check red with no ack
    # channel and no break-glass under `enforce_admins: true`.
    #
    # REACHING THIS IS NOW RARE BY CONSTRUCTION. The primary acceptors read the
    # summary out of the review RUN object's own body, so a run that carries a
    # recognised serialization is a candidate the moment it exists — there is no
    # second surface for it to wait on. What is left here is the genuinely
    # unknown state: a head-pinned run whose body matches NO acceptor, i.e. a
    # serialization this gate cannot classify. Holding is the correct answer to
    # that (a gate that cannot read the review must not certify it), and the run
    # ids are printed so an operator can see which body was not recognised
    # rather than having to re-derive it.
    #
    # "Rare" is a claim about COVERAGE, and coverage was measured rather than
    # assumed: across the 22 non-empty CodeRabbit review bodies on 20 mergepath
    # PRs, the two acceptors between them recognise every one. Neither acceptor
    # alone does — the header misses 2 (9%), which is how this hold became a red
    # nothing retires on an ordinary zero-actionable-comments report. Any future
    # widening belongs here, in the acceptors, not in a bound on the hold:
    # bounding it would trade an unretirable red for an uncertified pass.
    # Bounding the hold for the residual case is #906 / #896, which own the
    # ordered-publisher work this gate's two publishers need.
    echo "CodeRabbit current-HEAD review is awaiting its PR-level summary; holding this gate run. (head-pinned review run object(s): $HEAD_REVIEW_RUN_IDS)" >&2
    echo "CodeRabbit blocking-tier unresolved: pending (summary publication in flight)"
    exit 3
  fi
  log "no CodeRabbit PR-level summary comment found — no summary findings in scope"
fi

while IFS= read -r SUMMARY_JSON; do
  [ -n "$SUMMARY_JSON" ] || continue
  SUMMARY_ID=$(echo "$SUMMARY_JSON" | jq -r '.id')
  SUMMARY_BODY=$(echo "$SUMMARY_JSON" | jq -r '.body')
  SUMMARY_SCOPE=$(echo "$SUMMARY_JSON" | jq -r '.scope')
  if [ "$SUMMARY_SCOPE" = 'review-object-body' ]; then
    # Scope and completion both come from the review object itself: its
    # GitHub-owned commit_id names this head, and its non-empty body is the
    # report. Do not apply the marker-format all-benign stanza test: it does not
    # exist in this legitimate shape. Which acceptor recognised the body is
    # printed, because the two answer different questions about the same object
    # and an operator reading a verdict should not have to re-derive which one
    # fired.
    log "CodeRabbit markerless full-review summary in review object $SUMMARY_ID, head-pinned by its commit_id to $HEAD_SHA (recognised by: $(echo "$SUMMARY_JSON" | jq -r '.recognised_by // "unknown"'))"
  elif [ "$SUMMARY_SCOPE" = 'review-object' ]; then
    # The strict markerless result line identifies the known full-review format,
    # and the fresh exact-head review object above supplies the scope / completion
    # anchor that this format omits. Do not apply the marker-format stanza or
    # commits-range predicates: neither exists in this legitimate shape.
    log "PR-level markerless full-review summary (comment id $SUMMARY_ID) is anchored by a fresh completed CodeRabbit review object on $HEAD_SHA"
  fi
  # Status-checked for the same reason as the graded read below (#942): the
  # strip is a reader too, and a `$( )` that swallows its status turns a dead
  # awk into a silently-skipped suppressor.
  SUMMARY_SCAN=$(summary_strip_pre_merge_block "$SUMMARY_BODY") \
    || die 2 "failed to read the PR-level summary (comment id $SUMMARY_ID) while locating its pre-merge check table — refusing to grade a summary this gate could not read"
  if [ -n "$SUMMARY_SCAN" ]; then
  SUMMARY_BLOCKING_BEFORE=$(echo "$SUMMARY_BLOCKING" | jq 'length')
  # Classify UNFENCED lines only (Phase 4b P2 on #886, and Codex's earlier P2 —
  # both reviewers landed on this). The three structural scans had already been
  # taught to ignore fenced quotes; the finding loop had not, so a PR whose diff
  # contains `_⚠️ Potential issue_`, `P1`, or any other classifier marker as
  # SOURCE TEXT could manufacture a blocking summary finding against itself when
  # CodeRabbit quoted it back. This repo's own test fixtures contain exactly
  # such strings.
  #
  # I deferred this once (#893) on the argument that skipping fenced content in
  # the CLASSIFIER inverts the fail direction — and that argument was wrong on
  # the facts. CodeRabbit's finding markers are markdown emphasis rendered as
  # PROSE; a finding's code snippet sits inside a fence but the marker line that
  # classifies never does. So no genuine finding is lost, and the change is a
  # pure precision gain rather than a fail-open trade. #893 is closed by this.
  #
  # Line numbers stay those of SUMMARY_SCAN, not of the filtered stream, so a
  # reported location still points at the real line in the summary.
  #
  # Read BEFORE the loop, with the status checked, because a here-document
  # discards its command substitution's exit status: `done <<EOF\n$(pipeline)`
  # cannot fail. An awk that died on a pathological body therefore produced an
  # empty stream, the loop found nothing, and this REQUIRED gate reported zero
  # blocking summary findings — a failed read reading as a clean report, which
  # is the fail-open shape the gate exists to prevent (CodeRabbit 🟠 Major on
  # #936). Exit 2, the config/infra code the gate already uses for "cannot
  # decide", never 0.
  SUMMARY_NUMBERED=$(summary_unfenced_numbered "$SUMMARY_SCAN") \
    || die 2 "failed to read the PR-level summary (comment id $SUMMARY_ID) — refusing to report zero blocking findings from an unread summary"
  while IFS= read -r cr_numbered; do
    [ -n "$cr_numbered" ] || continue
    cr_line_no=${cr_numbered%%	*}
    cr_line=${cr_numbered#*	}
    [ -n "$cr_line" ] || continue
    cr_tier=$(coderabbit_tier_of "$cr_line")
    if tier_is_required "$cr_tier"; then
      SUMMARY_BLOCKING=$(echo "$SUMMARY_BLOCKING" | jq -c \
        --argjson id "$SUMMARY_ID" --argjson line "$cr_line_no" \
        --arg tier "$cr_tier" --arg body "$cr_line" '
        . + [ {
          id: $id,
          path: "(PR-level summary comment)",
          line: $line,
          tier: $tier,
          body_snippet: ($body | .[0:120])
        } ]
      ')
    fi
  done <<EOF
$SUMMARY_NUMBERED
EOF
  # Only bind a fingerprint when there is something to acknowledge. With no
  # blocking finding the token is never printed and never consulted, and
  # hashing the body anyway would make the (unused) token churn on every
  # walkthrough edit.
  #
  # SALTED WITH THE ACTIVE BLOCKING TIER SET (Codex P1 round 2 on #886). The
  # summary body alone does not determine what is blocking about it — the
  # resolved `required` tier set does, and that set comes from the TRUSTED
  # DEFAULT-BRANCH policy, so it can tighten while this PR is open. A summary
  # carrying both P1 and P2 text under a `{p1}` policy hashes identically under
  # `{p1,p2}`, so an ack written when only the P1 was blocking would clear a P2
  # the collaborator was never shown as blocking. Salting means a policy change
  # invalidates prior acks exactly as a push or a re-review does.
  SUMMARY_BLOCKING_AFTER=$(echo "$SUMMARY_BLOCKING" | jq 'length')
  if [ "$SUMMARY_BLOCKING_AFTER" -gt "$SUMMARY_BLOCKING_BEFORE" ]; then
    SUMMARY_FINDINGS_FINGERPRINT_INPUT="${SUMMARY_FINDINGS_FINGERPRINT_INPUT}
summary-comment: $SUMMARY_ID
$SUMMARY_SCAN"
  fi
  fi
done <<EOF
$(echo "$SUMMARY_CANDIDATES" | jq -c '.[]')
EOF

if [ -n "$SUMMARY_FINDINGS_FINGERPRINT_INPUT" ]; then
  SUMMARY_FINDINGS_FINGERPRINT_INPUT="required-tiers: $(echo "$REQUIRED_TIERS" | tr '\n' ' ')$SUMMARY_FINDINGS_FINGERPRINT_INPUT"
fi

SUMMARY_BLOCKING_COUNT=$(echo "$SUMMARY_BLOCKING" | jq 'length')
log "found $SUMMARY_BLOCKING_COUNT blocking-tier summary finding(s) on HEAD"

# Resolution channel for a summary-only finding (#832 acceptance criterion 3).
# A summary finding has no review thread, so "Resolve conversation" — the
# inline path's escape hatch — does not exist for it. A FIXED finding clears
# itself: the next push produces a new summary for the new head without the
# marker. A REBUTTED or DEFERRED one has no such path, and with
# `enforce_admins: true` there is no break-glass either, so the gate would
# deadlock the PR permanently without an explicit acknowledgement channel.
#
# The channel: a PR comment whose FIRST LINE is exactly the token
#   [mergepath-summary-ack: <HEAD sha> <finding-set fingerprint>]
# written by a human collaborator (author_association OWNER / MEMBER /
# COLLABORATOR — a GitHub-computed field, not something the commenter sets)
# and, per the same reasoning that keeps bots out of the reviewer set, not by
# a `[bot]` account. Rationale for the rebuttal or deferral goes on the lines
# BELOW the token.
#
# Head-pinned by construction, not by clock: the token names the current head
# sha, so an ack cannot be written before the commit it clears exists, and a
# subsequent push invalidates every prior ack. That is the same anchor the
# summary selection above uses, and again involves no timestamp.
#
# FINDING-PINNED as well as head-pinned. Head-pinning alone binds the ack to a
# COMMIT, not to the finding set that was on screen when it was written, and
# the summary surface can change WITHOUT the head changing: a same-head
# re-review (`@coderabbitai review`, `@coderabbitai resume`, or the rate-limit
# `try again` retry that scripts/coderabbit-wait.sh posts itself) rewrites the
# summary — in place, or as a later comment this script then selects — with a
# finding the acking collaborator never saw. A head-only ack would clear that
# new finding retroactively, and a required gate would pass with an
# undispositioned blocking finding on it. So the token also carries a
# fingerprint of the classified blocking lines: change the finding set and
# every prior ack stops matching, exactly as a push does. Fingerprinting the
# CONTENT (rather than ordering acks against the summary's comment id) is what
# survives an in-place edit, which leaves the comment id untouched.
#
# ANCHORED, not substring-matched. This script PRINTS the token verbatim in its
# own failure output below, and pasting a failing check's output into a PR
# comment while triaging it is routine agent behaviour in this repo. A bare
# "body contains the token" test would let that paste clear the gate silently.
# Requiring the token to BE the comment's first line (no leading whitespace —
# the failure block renders it indented, and inside surrounding prose) means a
# quote of this script's output can never satisfy it, while a deliberate ack is
# a one-line copy. The two halves of that argument have to be kept in step: the
# report below renders the token INDENTED and never at column 0, which is what
# makes "a verbatim paste of any contiguous region of this output cannot ack"
# true rather than merely likely. tests/test_coderabbit_severity_gate.sh
# asserts that rendering directly, so unindenting it there fails the suite.
#
# Computed only when there is a summary finding to acknowledge (Codex P2 round
# 5 on #886). summary_findings_fingerprint `die 2`s when neither sha256sum nor
# shasum is on PATH — the right call when an ack has to be bound to a finding
# set, and the wrong one when there is no finding, no token printed and nothing
# to bind: an unconditional call turned an otherwise-clean required check red
# over a hashing dependency it was not going to use.
SUMMARY_FINDINGS_FINGERPRINT=''
SUMMARY_ACK_TOKEN=''
if [ "$SUMMARY_BLOCKING_COUNT" -gt 0 ]; then
  SUMMARY_FINDINGS_FINGERPRINT=$(
    summary_findings_fingerprint "$SUMMARY_FINDINGS_FINGERPRINT_INPUT"
  )
  SUMMARY_ACK_TOKEN="[mergepath-summary-ack: $HEAD_SHA $SUMMARY_FINDINGS_FINGERPRINT]"
  if echo "$ISSUE_COMMENTS_JSON" | jq -e --arg tok "$SUMMARY_ACK_TOKEN" '
    any(.[];
      ((.user.login // "") | endswith("[bot]") | not)
      and ((.author_association // "") as $aa
           | (["OWNER", "MEMBER", "COLLABORATOR"] | index($aa)) != null)
      and (((.body // "") | gsub("\r"; "") | split("\n")) as $lines
           | (($lines[0] // "") | sub("[ \t]+$"; "")) == $tok
             # A RATIONALE IS PART OF THE ACK (Codex P2 round 2 on #886). The
             # spec and REVIEW_POLICY both say the reason goes on the lines
             # below the token; without this the bare token cleared a required
             # gate with no recorded disposition at all, so the documented
             # contract and the enforced one disagreed. The test is mechanical
             # — at least one non-blank line after the token — deliberately not
             # a "substantive text" heuristic, which would be unpredictable to
             # satisfy and is not the kind of judgement a merge gate should be
             # making.
             and (($lines[1:] | map(sub("^[ \t]+"; "") | sub("[ \t]+$"; ""))
                   | map(select(. != "")) | length) > 0))
    )
  ' >/dev/null 2>&1; then
    log "summary findings acknowledged for $HEAD_SHA (finding set $SUMMARY_FINDINGS_FINGERPRINT) by a collaborator ack comment — not gating"
    SUMMARY_BLOCKING='[]'
    SUMMARY_BLOCKING_COUNT=0
  fi
fi

# Withhold a PASS while a newer head-pinned run remains unread (Codex P1 round
# 15 on #886). Called from BOTH clean exits — the summary-only one below and
# report_verdict's, which is reached with a zero count once every inline thread
# is resolved. Guarded on REQUIRE_REVIEW_SUMMARY for the same reason the
# correlation filter is: with the flag set, a hold withholds a verdict the
# publishers know how to handle (the event arm goes non-green, the sweep declines
# to publish), while an ad-hoc caller has no publication to withhold and gets the
# arrival-independent answer it asked for.
hold_on_unrecognised_newer_run() {
  [ "$REQUIRE_REVIEW_SUMMARY" = "true" ] || return 0
  [ -n "$HEAD_UNRECOGNISED_NEWER_IDS" ] || return 0
  echo "CodeRabbit published a later review run on $HEAD_SHA whose body matches no summary acceptor, so the clean verdict in hand is from an earlier publication; holding this gate run. (unrecognised head-pinned review run object(s): $HEAD_UNRECOGNISED_NEWER_IDS)" >&2
  echo "CodeRabbit blocking-tier unresolved: pending (summary publication in flight)"
  exit 3
}

if [ "$BLOCKING_COUNT" -eq 0 ] && [ "$SUMMARY_BLOCKING_COUNT" -eq 0 ]; then
  hold_on_unrecognised_newer_run
  echo "CodeRabbit blocking-tier unresolved: 0"
  exit 0
fi

# --- verdict reporting ------------------------------------------------------
#
# A function because the two paths below reach it from different depths: when
# the inline surface produced no candidates, the only findings left are summary
# ones, which carry no review thread — so the reviewThreads scan has nothing to
# look up and is skipped entirely rather than run for its side effects.
report_verdict() {
  local unresolved=$1 count inline_count
  count=$(echo "$unresolved" | jq 'length')
  # Derived from what is actually being REPORTED, not from BLOCKING_COUNT
  # (Codex P2 round 4 on #886). BLOCKING_COUNT counts pre-resolution inline
  # CANDIDATES, so with every inline thread already resolved and only a summary
  # finding left it is still nonzero — and the remediation block below would
  # tell the reader to resolve inline threads that are neither listed nor
  # unresolved. Counting the reported findings makes the instruction true by
  # construction in both call sites, including the summary-only path where
  # UNRESOLVED_BLOCKING does not exist yet.
  inline_count=$(echo "$unresolved" | jq '[ .[] | select(.path != "(PR-level summary comment)") ] | length')

  if [ "$count" -gt 0 ]; then
    echo ""
    echo "Unresolved CodeRabbit blocking-tier findings on current HEAD ($HEAD_SHA):"
    echo "$unresolved" | jq -r '
      .[] | "  - [\(.tier | ascii_upcase)] \(.path):\(.line) (comment id \(.id))\n      \(.body_snippet)"
    '
    # Guarded on the REPORTED inline count (CodeRabbit, #886): on a
    # summary-only failure there is no thread to resolve, and printing an
    # instruction the reader cannot follow on the findings in front of them is
    # worse than printing nothing — the summary block below is the applicable
    # one.
    if [ "$inline_count" -gt 0 ]; then
      echo ""
      echo "Resolve each inline thread via the GitHub UI (or the GraphQL"
      echo "resolveReviewThread mutation) once the finding is addressed."
    fi
    if [ "$SUMMARY_BLOCKING_COUNT" -gt 0 ]; then
      echo ""
      echo "Findings listed against \"(PR-level summary comment)\" have no review"
      echo "thread to resolve. Fixing one clears it on its own: the next push"
      echo "produces a summary for the new head without the finding. To record a"
      echo "rebuttal or a deferral instead, post a PR comment whose FIRST LINE is"
      echo "the token below, unindented, with the rationale on the lines under it"
      echo "(at least one non-blank line of rationale is required):"
      echo "    $SUMMARY_ACK_TOKEN"
      echo "The ack must come from a collaborator. It is pinned both to this head"
      echo "and to the finding set above, so a later push OR a re-review that"
      echo "changes the summary invalidates it. Quoting this output back into a"
      echo "comment does NOT ack anything: the token is printed indented here and"
      echo "on its own it acks nothing unless it leads the comment."
    fi
    echo ""
  fi

  if [ "$count" -gt 0 ]; then
    echo "CodeRabbit blocking-tier unresolved: $count"
    exit 1
  fi
  # A zero count here is a PASS reached after thread classification, so it is
  # subject to the same unread-newer-run hold as the summary-only exit above.
  # The verdict line is printed inside each branch rather than before them
  # because the hold prints its own, and a run must emit exactly one.
  hold_on_unrecognised_newer_run
  echo "CodeRabbit blocking-tier unresolved: $count"
  exit 0
}

if [ "$BLOCKING_COUNT" -eq 0 ]; then
  report_verdict "$SUMMARY_BLOCKING"
fi

# --- fetch review-thread resolution state via GraphQL ----------------------

# Build a mapping (comment_id → isResolved) across ALL review threads and ALL
# comments in each thread, then look each blocking-tier comment up.
#
# PAGINATION (#592). The GraphQL `reviewThreads` connection and each thread's
# nested `comments` connection each cap at 100 items per page. A PR with >100
# review threads, or a thread with >100 comments (the gap nathanpayne-codex
# flagged as P1 on #590), would truncate the map — a blocking comment id beyond
# the cap would be absent, fall to `// false` in the classification below, and
# be counted as unresolved. That is already fail-SAFE (over-block, never
# false-clear), but it turns an extreme-but-legitimate PR into a hard exit 2.
# So instead of erroring on overflow, we PAGINATE both connections with a
# cursor loop and classify precisely.
#
# FAIL-CLOSED POSTURE IS PRESERVED (#592). The loop fails closed (die 2, the
# same exit code as the pre-pagination hard errors) on ANY of: a GraphQL error,
# a null/malformed page (missing reviewThreads), or exceeding the max-page
# safety cap. It never treats a partial or failed scan as complete, so a
# truncated map can NEVER silently under-count blocking findings. This block is
# mirrored verbatim (bar the log prefix) in scripts/codex-p1-gate.sh — keep the
# two in lockstep; a shared paginator was considered but the shared lib
# (scripts/lib/feedback-policy-helpers.sh) is contractually gh/network-free.

OWNER=${REPO%/*}
NAME=${REPO#*/}

# Safety cap: 100 threads/page × 100 pages = 10k threads; 100 comments/page ×
# 100 pages = 10k comments/thread. Far beyond any real PR; a loop that reaches
# it indicates a cursor-stall / non-terminating pagination bug, so we fail
# closed rather than spin.
MAX_PAGES=100

# Top-level reviewThreads query (paged via $cursor). Each thread carries its
# first page of comments plus that connection's pageInfo so we can detect a
# >100-comment thread and page it separately below.
THREADS_QUERY=$(cat <<'EOF'
query($owner: String!, $name: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { databaseId }
          }
        }
      }
    }
  }
}
EOF
)

# Per-thread comments query (paged via $cursor) for a thread whose comments
# connection overflowed 100. Keyed by the thread node id.
THREAD_COMMENTS_QUERY=$(cat <<'EOF'
query($id: ID!, $cursor: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { databaseId }
      }
    }
  }
}
EOF
)

# Accumulate every thread node (with a fully-paginated comment id list) into
# ALL_THREADS as a JSON array of { isResolved, comment_ids: [databaseId,...] }.
ALL_THREADS='[]'
CURSOR=""
PAGE=0
while :; do
  PAGE=$((PAGE + 1))
  if [ "$PAGE" -gt "$MAX_PAGES" ]; then
    die 2 "reviewThreads pagination exceeded $MAX_PAGES pages (#592 safety cap) — failing closed."
  fi
  if [ -z "$CURSOR" ]; then
    THREADS_JSON=$(gh api graphql -F owner="$OWNER" -F name="$NAME" \
      -F pr="$PR_NUMBER" -F cursor=null -f query="$THREADS_QUERY" 2>&1) \
      || die 2 "failed to query reviewThreads (page $PAGE): $THREADS_JSON"
  else
    THREADS_JSON=$(gh api graphql -F owner="$OWNER" -F name="$NAME" \
      -F pr="$PR_NUMBER" -f cursor="$CURSOR" -f query="$THREADS_QUERY" 2>&1) \
      || die 2 "failed to query reviewThreads (page $PAGE): $THREADS_JSON"
  fi
  # Fail closed on a malformed / null page: a missing reviewThreads object
  # means the scan cannot be trusted complete.
  if ! echo "$THREADS_JSON" | jq -e '.data.repository.pullRequest.reviewThreads.nodes' >/dev/null 2>&1; then
    die 2 "malformed reviewThreads response (page $PAGE) — failing closed."
  fi

  # For each thread on this page, resolve its comment id list — paginating the
  # nested comments connection if it overflowed 100.
  PAGE_NODE_COUNT=$(echo "$THREADS_JSON" | jq '.data.repository.pullRequest.reviewThreads.nodes | length')
  n=0
  while [ "$n" -lt "$PAGE_NODE_COUNT" ]; do
    NODE=$(echo "$THREADS_JSON" | jq -c ".data.repository.pullRequest.reviewThreads.nodes[$n]")
    NODE_RESOLVED=$(echo "$NODE" | jq '.isResolved')
    NODE_ID=$(echo "$NODE" | jq -r '.id')
    COMMENT_IDS=$(echo "$NODE" | jq -c '[.comments.nodes[].databaseId]')
    C_HAS_NEXT=$(echo "$NODE" | jq -r '.comments.pageInfo.hasNextPage')
    C_CURSOR=$(echo "$NODE" | jq -r '.comments.pageInfo.endCursor')
    C_PAGE=1
    while [ "$C_HAS_NEXT" = "true" ]; do
      C_PAGE=$((C_PAGE + 1))
      if [ "$C_PAGE" -gt "$MAX_PAGES" ]; then
        die 2 "thread comments pagination exceeded $MAX_PAGES pages (#592 safety cap) — failing closed."
      fi
      CJSON=$(gh api graphql -F id="$NODE_ID" -f cursor="$C_CURSOR" \
        -f query="$THREAD_COMMENTS_QUERY" 2>&1) \
        || die 2 "failed to query thread comments (thread $NODE_ID, page $C_PAGE): $CJSON"
      if ! echo "$CJSON" | jq -e '.data.node.comments.nodes' >/dev/null 2>&1; then
        die 2 "malformed thread comments response (thread $NODE_ID, page $C_PAGE) — failing closed."
      fi
      COMMENT_IDS=$(jq -c -n --argjson acc "$COMMENT_IDS" --argjson pg \
        "$(echo "$CJSON" | jq -c '[.data.node.comments.nodes[].databaseId]')" '$acc + $pg')
      C_HAS_NEXT=$(echo "$CJSON" | jq -r '.data.node.comments.pageInfo.hasNextPage')
      C_CURSOR=$(echo "$CJSON" | jq -r '.data.node.comments.pageInfo.endCursor')
    done
    ALL_THREADS=$(jq -c -n --argjson acc "$ALL_THREADS" \
      --argjson resolved "$NODE_RESOLVED" --argjson ids "$COMMENT_IDS" \
      '$acc + [{ isResolved: $resolved, comment_ids: $ids }]')
    n=$((n + 1))
  done

  HAS_NEXT=$(echo "$THREADS_JSON" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
  [ "$HAS_NEXT" = "true" ] || break
  CURSOR=$(echo "$THREADS_JSON" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  if [ -z "$CURSOR" ] || [ "$CURSOR" = "null" ]; then
    die 2 "reviewThreads reported hasNextPage but no endCursor — failing closed."
  fi
done

# Build a JSON object: { "<comment_id>": isResolved, ... } from the fully
# paginated thread set.
RESOLUTION_MAP=$(echo "$ALL_THREADS" | jq '
  map(
      (.isResolved) as $resolved
      | .comment_ids
      | map({ key: (. | tostring), value: $resolved })
    )
  | flatten
  | from_entries
')

# --- classify blocking-tier comments by resolution -------------------------

UNRESOLVED_BLOCKING=$(echo "$BLOCKING_COMMENTS" | jq \
  --argjson map "$RESOLUTION_MAP" '
  [ .[]
    | . as $c
    | ($map[($c.id | tostring)] // false) as $resolved
    | select($resolved != true)
  ]
')

# --- report ----------------------------------------------------------------

# Summary findings are appended AFTER the thread-classified inline ones: they
# carry no thread, so the resolution map above says nothing about them, and any
# ack that would clear them was already applied when SUMMARY_BLOCKING was built.
report_verdict "$(jq -c -n \
  --argjson inline "$UNRESOLVED_BLOCKING" \
  --argjson summary "$SUMMARY_BLOCKING" \
  '$inline + $summary')"
