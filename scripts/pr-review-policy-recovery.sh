#!/usr/bin/env bash
# scripts/pr-review-policy-recovery.sh
#
# Recovery lane for the two required contexts `.github/workflows/
# pr-review-policy.yml` publishes — `Self-Review Required` and `Label Gate`
# (nathanjohnpayne/mergepath#931).
#
# ─────────────────────────────────────────────────────────────────────
# The gap this closes
# ─────────────────────────────────────────────────────────────────────
#
# Both contexts had exactly ONE producer path: the `pull_request` event. Every
# sibling required context carries a second way in — codex-p1-gate.yml and
# coderabbit-severity-gate.yml have a */15 sweep, merge-clearance-gate.yml has
# a sweep AND a repository_dispatch, and the three of them are additionally
# republished by required-check-publisher.yml. These two had neither, so a
# `pull_request` delivery that never arrived left both contexts at
# "Expected — Waiting for status to be reported" forever: branch protection
# blocks, no event can re-fire them, and there is no manual re-run path.
#
# That is not hypothetical. gaycruisebingo#662 saw the whole pull_request
# family run 6–32 minutes late while push-triggered workflows fired normally;
# gaycruisebingo#644 and #649 each merged with NO check run at all for either
# context on their merge head.
#
# ─────────────────────────────────────────────────────────────────────
# What this script does, and the line it does NOT cross
# ─────────────────────────────────────────────────────────────────────
#
# For every open PR it re-derives both contexts from live PR state and
# publishes them on the PR head through the Checks API. It publishes ONLY
# where recovery is genuinely what is missing:
#
#   absent     nothing has reported on that head. This is the stuck-forever
#              shape, and the only verdict that can be wrong here is one
#              nobody would otherwise get.
#   refresh    only this lane has reported. It still owns the slot, so it
#              keeps the verdict current: GitHub requires the newest run of
#              EACH lineage to be green, so a stale recovery red left standing
#              would strand the PR just as hard as the original gap (the
#              two-lineage behaviour measured on #828 / #835 / #1216).
#   standdown  the event-driven producer has reported and this lane's newest
#              word is still a verdict. It publishes ONE non-blocking
#              `neutral` run to retire its own lineage and hands the slot
#              back. See § Ownership below.
#   skip       nothing to do — the lane never touched this head, or it has
#              already stood down.
#
# A read that fails is skipped too, and reported as an infra error:
# publishing into unknown state is how a recovery lane turns into an outage.
#
# ─────────────────────────────────────────────────────────────────────
# Ownership: the lane is a stand-in, never an owner
# ─────────────────────────────────────────────────────────────────────
#
# The full contract is specs/pr_review_policy_recovery.md; the rule in one
# line is that the event-driven producer always wins, and the lane's job is to
# get out of its way cleanly.
#
# The earlier rule got this wrong and shipped as a defect (#1240 Codex round
# 4): it asked only whether a RECOVERY run existed, so once the lane had
# published anything the answer was `refresh` forever — including after the
# event-driven job reported. A real case: auto-clear-blocking-labels.yml
# validly removes `needs-external-review`, the `unlabeled` event publishes a
# native green Label Gate, and the next sweep overwrote it with the lane's own
# stale red, every 15 minutes, wedging a PR that had been legitimately
# cleared.
#
# The rule now reads the two sides differently, because the two questions are
# different:
#
#   the native side is PRESENCE. A native run on this head means the producer
#   this lane substitutes for is working, so the lane yields — no comparison
#   with it, in either direction. "Yield only if the native run is newer than
#   mine" would be the same defect one ordering later, leaving the lane's
#   verdict overriding the real one.
#
#   this lane's own side is RECENCY, and only to answer "have I already stood
#   down?". Check runs are append-only and their ids increase monotonically,
#   so the retirement is in force exactly while it is the highest-numbered run
#   this lane owns. That is what stops the sweep posting a fresh neutral every
#   15 minutes forever.
#
# `external_id` is the discriminator because it is exact. Actions job-native
# check runs carry a UUID there and plain Checks-API POSTs carry an empty
# string; this lane stamps its own two constants, so "did this lane write it,
# and was that its retirement?" is string equality rather than an inference
# about UUID shape.
#
# A HEAD CARRIED BY MORE THAN ONE OPEN PR is published RED on both contexts
# and evaluated for neither (#1240 Codex P1). Check-run verdicts attach to a
# COMMIT while the policy state they encode (labels, body, base) is per-PR, so
# one slot cannot honestly carry two PRs' verdicts: a clean PR swept after a
# `human-hold` PR would turn the held PR's `Label Gate` green. Red until
# disambiguated is the only verdict that cannot be wrong for either. Same
# posture required-check-publisher.yml takes for its per-commit slots.
#
# EVERY PUBLICATION IS FENCED BY A COMPARE-AND-SWAP on the check runs the
# decision was made over (#1240 Codex P1). The run-id set is captured when the
# decision is taken and re-read immediately before the POST; if it changed,
# something else published for that (head, context) while this pass was
# evaluating — a native job run arriving mid-sweep, or a newer pass — and this
# now-stale verdict is withheld rather than posted over it. Overlapping passes
# are additionally serialized by the workflow's `concurrency` group, because a
# label change moves no head SHA and the head re-read cannot see it. The
# residual window is the gap between that re-read and the POST, which is the
# floor without conditional writes.
#
# ─────────────────────────────────────────────────────────────────────
# Verdict sources — one implementation, not a second copy
# ─────────────────────────────────────────────────────────────────────
#
#   Self-Review Required — `scripts/validate-pr-body.sh --self-review-only`,
#     the same single tested entrypoint the workflow's event-driven job pipes
#     the body into, invoked the same way (body on STDIN, never argv).
#     Dependabot is exempt there via a job-level `if:`; the exemption is
#     reproduced here by publishing `skipped`, which is the conclusion a
#     skipped job reports and which branch protection already treats as
#     satisfied.
#   Label Gate — `mergepath_blocking_labels_csv` from
#     scripts/lib/blocking-labels.sh, the shared predicate agent-review.yml
#     already uses for the same four labels, over a label list read as late as
#     possible; AND, before any green, `scripts/merge-clearance-gate.sh
#     --derive-phase-4-requiredness` (see below).
#
# Neither verdict is re-implemented here, so the recovery reading and the
# event-driven reading cannot drift.
#
# ─────────────────────────────────────────────────────────────────────
# Why Label Gate cannot be published from the label list alone
# ─────────────────────────────────────────────────────────────────────
#
# `needs-external-review` is applied by pr-review-policy.yml's OWN
# `External Review Check` job, in the same workflow run as the two gates. So
# in exactly the case this lane exists for — the `pull_request` delivery never
# arrived — the classification that would have applied the label never ran
# either. "No blocking label" is then a SYMPTOM of the missing event, not
# evidence that no review was required, and publishing a green `Label Gate`
# from it manufactures a Phase 4 bypass. On consumers, where
# `codex.external_review_gate` keeps its documented default of disabled, that
# label is the only enforced Phase 4 stop, so the bypass is total
# (#1240 Codex P1).
#
# Withholding is not an answer either — it reinstates #931. So the lane
# RE-DERIVES the classification before it will publish a green, through
# `scripts/merge-clearance-gate.sh --derive-phase-4-requiredness`: the same
# threshold, protected-path, force-on-label and head-pinned
# propagation-lane-exemption calculation, over the policy resolved from the
# PR's BASE commit, reusing the very helpers pr-review-policy.yml uses. It
# prints `true` or `false` and exits 0; any other outcome is fail-closed by
# its own documented contract.
#
#   requires Phase 4 + no blocking label  -> publish FAILURE. The label the
#     classifier would have applied is missing only because the classifier
#     never ran; blocking is what the native path produces once it does.
#   does not require Phase 4               -> the green is justified.
#   derivation failed                      -> publish FAILURE and redden the
#     run. The next pass refreshes its own lineage, so a transient failure
#     costs one interval of a red, not a permanent one.
#
# Usage:
#   scripts/pr-review-policy-recovery.sh <owner/repo>
#   REPO=<owner/repo> scripts/pr-review-policy-recovery.sh
#
# Requires GH_TOKEN with `checks: write` and `pull-requests: read`.
#
# Exit codes:
#   0 — the sweep completed; every open PR was evaluated or deliberately
#       skipped.
#   1 — the sweep completed but at least one read or write failed. Nothing was
#       published from unknown state; the run is red so the failure is visible
#       and the next interval retries.
#   2 — usage / environment error (no repo, no gh, no jq).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { local rc="$1"; shift; printf 'pr-review-policy-recovery: %s\n' "$*" >&2; exit "$rc"; }
log() { printf 'pr-review-policy-recovery: %s\n' "$*"; }

REPO="${1:-${REPO:-}}"
[ -n "$REPO" ] || die 2 "usage: scripts/pr-review-policy-recovery.sh <owner/repo>"
case "$REPO" in
  */*) ;;
  *) die 2 "repo must be owner/name, got '$REPO'" ;;
esac

command -v gh >/dev/null 2>&1 || die 2 "gh is required"
command -v jq >/dev/null 2>&1 || die 2 "jq is required"

# shellcheck source=lib/gh-api-scalar.sh
. "$ROOT/scripts/lib/gh-api-scalar.sh"

# The trusted default-branch checkout can lag an atomic workflow+helper
# rollout by one merge, so keep the exact bootstrap predicate for the first
# mergepath or consumer rollout — the same shape agent-review.yml uses. The
# four names are the canonical blocking set; the fallback exists so a
# pre-wave tree recovers PRs instead of failing the sweep.
if [ -f "$ROOT/scripts/lib/blocking-labels.sh" ]; then
  # shellcheck source=lib/blocking-labels.sh
  . "$ROOT/scripts/lib/blocking-labels.sh"
else
  mergepath_blocking_labels_csv() {
    awk '$0 == "needs-external-review" || $0 == "needs-human-review" || $0 == "policy-violation" || $0 == "human-hold"' \
      | paste -sd, -
  }
fi

VALIDATOR="$ROOT/scripts/validate-pr-body.sh"
# Phase 4 applicability is asked of the gate script that already owns that
# calculation. Overridable for tests ONLY — the fence
# scripts/ci/check_pr_review_policy_recovery asserts the default is
# scripts/merge-clearance-gate.sh, exactly as merge-clearance-gate.sh itself
# exposes MERGE_CLEARANCE_WORKFLOW_DIR for its own suite.
DERIVE_BIN="${PR_REVIEW_POLICY_RECOVERY_DERIVE_BIN:-$ROOT/scripts/merge-clearance-gate.sh}"

SELF_REVIEW_CONTEXT="Self-Review Required"
LABEL_GATE_CONTEXT="Label Gate"
# Stamped into every check run this lane publishes and matched on the way back
# in. Keep it in sync with scripts/ci/check_pr_review_policy_recovery.
RECOVERY_EXTERNAL_ID="mergepath-pr-review-policy-recovery"
# Stamped on the single non-blocking run that retires this lane's lineage once
# the event-driven producer reports. A SECOND id, not a flag on the first:
# check runs are append-only, so "have we already stood down?" can only be
# answered by what the newest run of our lineage IS.
RETIRED_EXTERNAL_ID="mergepath-pr-review-policy-recovery-superseded"
DEPENDABOT_LOGIN='dependabot[bot]'

had_infra_error=0
infra() { had_infra_error=1; printf 'pr-review-policy-recovery: ERROR: %s\n' "$*" >&2; }

# urlencode <string> — jq's @uri, so a context name with spaces survives the
# query string without a hand-rolled encoder.
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

# read_runs <head> <context>
#
# Prints one `<id> <external_id>` line per check run for that (head, context),
# sorted so the output is a stable set fingerprint. A failed read prints
# nothing and returns 3, so an outage can never be read as "no runs".
read_runs() {
  local head="$1" context="$2"
  gh_api_scalar "check runs for '$context' on $head" \
    --paginate "repos/$REPO/commits/$head/check-runs?check_name=$(urlencode "$context")&per_page=100" \
    --jq '.check_runs[] | "\(.id) \(.external_id // "")"' | sort
}

# decide_from_runs <runs> — the OWNERSHIP decision for one (head, context).
#
# Prints exactly one of:
#
#   absent     nothing has reported. Publish the recovered verdict; this is
#              the stuck-forever shape the lane exists for.
#   refresh    only this lane has reported. It still owns the slot, so keep
#              the verdict current against live state.
#   standdown  the event-driven producer has now reported, and this lane's
#              own newest run is a verdict. Retire that lineage with one
#              non-blocking run and hand the slot back.
#   skip       nothing for this lane to do — either it never touched the head,
#              or it has already stood down.
#
# Decided by RECENCY, not presence (#1240 Codex round 4 P1). The earlier rule
# asked only whether a recovery run existed, so once the lane had published
# anything it answered `refresh` forever — including after the event-driven
# job reported. A real case: auto-clear-blocking-labels.yml validly removes
# `needs-external-review`, the `unlabeled` event publishes a native green
# Label Gate, and the next sweep overwrote it with the lane's own stale red,
# every 15 minutes, wedging a PR that was legitimately cleared. A stand-in for
# a missing producer must stand down when the real one returns.
#
# Yielding SILENTLY is not enough either, and that is why `standdown` exists
# rather than just widening `skip`. GitHub requires the newest run of EACH
# lineage to be green (measured on #828 / #835, stranding #1216), so a lane
# red left standing beside a later native green blocks just as hard as the
# original gap. The lane can only retire its own lineage by publishing into
# it, so it posts one `neutral` run — a conclusion branch protection already
# treats as satisfied — stamped with a DIFFERENT external_id. That second id
# is what makes the retirement idempotent: once it is the newest run of this
# lane's lineage, the answer is `skip` and the sweep stops writing.
decide_from_runs() {
  local runs="$1"
  if [ -z "$runs" ]; then
    printf 'absent'
    return 0
  fi
  # The native side is a PRESENCE test — any run that is not one of this
  # lane's two stamps means the producer it substitutes for is working.
  if ! printf '%s\n' "$runs" \
    | awk -v a="$RECOVERY_EXTERNAL_ID" -v b="$RETIRED_EXTERNAL_ID" \
        '$2 != a && $2 != b { found = 1 } END { exit found ? 0 : 1 }'; then
    # Nothing but this lane has reported. It is the producer here.
    printf 'refresh'
    return 0
  fi
  # This lane's own side is RECENCY, and only to answer whether it has already
  # retired. Ids increase monotonically, so the highest id this lane owns is
  # its newest word.
  local newest_ours newest_retired
  newest_ours=$(printf '%s\n' "$runs" | awk -v id="$RECOVERY_EXTERNAL_ID" '$2 == id {print $1}' | sort -n | tail -1)
  newest_retired=$(printf '%s\n' "$runs" | awk -v id="$RETIRED_EXTERNAL_ID" '$2 == id {print $1}' | sort -n | tail -1)
  if [ -z "$newest_ours" ] && [ -z "$newest_retired" ]; then
    # Never touched this head, and the real producer has it. Leave it alone.
    printf 'skip'
    return 0
  fi
  if [ -n "$newest_retired" ] && { [ -z "$newest_ours" ] || [ "$newest_retired" -gt "$newest_ours" ]; }; then
    printf 'skip'
    return 0
  fi
  printf 'standdown'
}

# publish <pr> <head> <observed-runs> <expected-sole-owner> <external-id> \
#         <context> <conclusion> <title> <summary>
#
# One POST per verdict. A fresh POST rather than a PATCH of an earlier run:
# every Checks-API POST for a head coalesces into the shared suite where the
# newest run wins, and no run id has to cross a sweep boundary.
#
# THREE fences run first, all immediately before the write so the stale window
# is as small as it can be without conditional writes:
#
#   1. the head must still be the PR's head. Both verdicts come from LIVE PR
#      state, so a push between evaluation and publication would pin
#      fresh-state conclusions to a superseded SHA.
#   2. this PR must still be the ONLY open PR carrying that head, or still not
#      be — whichever the decision was taken under. The duplicate-head set is
#      computed once from the opening listing, and a reopen or a force-push
#      onto another open PR's head invalidates it mid-sweep (#1240 Codex
#      round 4 P1). Fence 3 covers the artifact; this one covers the SET
#      MEMBERSHIP that made publishing that artifact safe.
#   3. the check runs for this (head, context) must be EXACTLY the set the
#      decision was taken over. Anything else means a native run or a newer
#      pass published while this one evaluated, and this verdict is stale. A
#      label change moves no head SHA, so fence 1 cannot see that case and
#      fence 3 is the one that catches it (#1240 Codex round 1 P1).
#
# A failed re-read withholds at every fence: unknown state is possibly-newer
# state.
publish() {
  local pr="$1" head="$2" observed="$3" sole_owner="$4" external_id="$5"
  local context="$6" conclusion="$7" title="$8" summary="$9"
  local live="" current="" owners="" live_sole="" rc=0
  if ! live=$(gh_api_scalar --shape sha "PR #$pr head" "repos/$REPO/pulls/$pr" --jq '.head.sha'); then
    infra "could not revalidate the head of PR #$pr before publishing '$context'"
    return 1
  fi
  if [ "$live" != "$head" ]; then
    log "PR #$pr moved from $head to $live during evaluation; publishing nothing for the superseded head"
    return 1
  fi
  # One call, and it asks the question directly rather than re-walking the
  # open-PR listing: which PRs carry this commit?
  if ! owners=$(gh_api_scalar "open PRs carrying $head" \
    "repos/$REPO/commits/$head/pulls" --jq '[.[] | select(.state == "open") | .number] | join(",")'); then
    infra "could not revalidate which open PRs carry $head before publishing '$context'"
    return 1
  fi
  live_sole=false
  [ "$owners" = "$pr" ] && live_sole=true
  if [ "$live_sole" != "$sole_owner" ]; then
    log "PR #$pr: the set of open PRs carrying $head changed to [$owners] while this pass evaluated; withholding the now-stale verdict"
    return 1
  fi
  current=$(read_runs "$head" "$context") || rc=$?
  if [ "$rc" -ne 0 ]; then
    infra "could not re-read the '$context' check runs on $head before publishing; withholding"
    return 1
  fi
  if [ "$current" != "$observed" ]; then
    log "PR #$pr: the '$context' check runs on $head changed while this pass evaluated; withholding the now-stale verdict"
    return 1
  fi
  local fields=(
    -f "name=$context"
    -f "head_sha=$head"
    -f "external_id=$external_id"
    -f "status=completed"
    -f "conclusion=$conclusion"
    -f "output[title]=$title"
    -f "output[summary]=$summary"
  )
  # The call is assembled into an array so the exemption marker below can sit
  # on the invoking line, where scripts/ci/check_no_bare_gh_writes reads it.
  if ! gh api -X POST "repos/$REPO/check-runs" "${fields[@]}" >/dev/null; then  # NO_BARE_GH_WRITE_EXEMPT: a check-run POST carries no byline to attribute or verify. scripts/gh-as-author.sh / gh-as-reviewer.sh exist to prove WHICH identity authored a PR or issue write; this publishes a commit status as the workflow's own GITHUB_TOKEN, exactly as codex-p1-gate.yml, coderabbit-severity-gate.yml, merge-clearance-gate.yml and required-check-publisher.yml already do inline in their YAML. Routing it through an identity wrapper would attribute a gate verdict to a human PAT, which is strictly worse.
    infra "could not publish '$context' on $head"
    return 1
  fi
  log "published '$context' = $conclusion on $head"
}

# stand_down <pr> <head> <observed-runs> <sole-owner> <context>
#
# Retire this lane's lineage for one (head, context) with a single `neutral`
# run, so the event-driven producer's verdict is the only one that can block.
# `neutral` is one of the conclusions branch protection already treats as
# satisfied, and the distinct external_id makes the retirement idempotent —
# the next pass reads it as this lane's newest word and answers `skip`.
stand_down() {
  local pr="$1" head="$2" observed="$3" sole="$4" context="$5"
  publish "$pr" "$head" "$observed" "$sole" "$RETIRED_EXTERNAL_ID" "$context" neutral \
    "$context — recovery lane stood down" \
    "The event-driven job has reported '$context' for $head, so the pr-review-policy recovery lane is handing the slot back and retiring its own entries. This run is deliberately non-blocking; the event-driven verdict governs. See nathanjohnpayne/mergepath#931."
}

# pr_author <pr> — read the login on demand. It is only needed on the path
# that actually publishes a Self-Review verdict, and a pass over a healthy
# repository publishes nothing, so reading it per PR up front spent one REST
# call per PR per 15 minutes for nothing (#1240 Codex round 4 P2). Prints
# empty on a failed read, which simply means the Dependabot exemption does not
# apply — the safe direction, since the exemption can only relax the gate.
pr_author() {
  gh_api_scalar "author of PR #$1" "repos/$REPO/pulls/$1" --jq '.user.login // ""' 2>/dev/null || printf ''
}

# requires_phase_4 <pr> — `true`, `false`, or rc 1 when the derivation could
# not be made. Delegates to the gate script that already owns the threshold,
# protected-path, force-on-label and propagation-lane-exemption calculation
# over the policy resolved from the PR's BASE commit; anything other than a
# clean `true`/`false` on exit 0 is fail-closed by that script's own contract.
requires_phase_4() {
  local pr="$1" out="" rc=0
  out=$(bash "$DERIVE_BIN" --derive-phase-4-requiredness "$pr" "$REPO" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  case "$out" in
    true|false) printf '%s' "$out" ;;
    *) return 1 ;;
  esac
}

open_prs=""
if ! open_prs=$(gh_api_scalar "open pull requests on $REPO" \
  --paginate "repos/$REPO/pulls?state=open&per_page=100" \
  --jq '.[] | "\(.number)\t\(.head.sha // "")"'); then
  die 1 "could not list open pull requests on $REPO; nothing swept"
fi
if [ -z "$open_prs" ]; then
  log "no open PRs on $REPO; sweep is a no-op"
  exit 0
fi

# Heads carried by MORE than one open PR are published RED on both contexts
# and evaluated for neither. One commit slot cannot honestly carry two PRs'
# verdicts (#1240 Codex P1) — see the header. Computed once, from the listing
# both verdicts are driven by, so the two contexts cannot disagree about which
# heads are ambiguous.
dup_heads=$(printf '%s\n' "$open_prs" | cut -f2 | sort | uniq -d)

# Rotate the starting point each pass. Every read this sweep makes counts
# against a GITHUB_TOKEN allowance that is 1,000 requests per HOUR PER REPO,
# and a no-op pass costs two calls per open PR, so a repository somewhere north
# of ~120 open PRs cannot complete a pass. Walking the same order every time
# would make that failure silent AND permanent for the tail of the list: the
# same PRs would be recovered every pass and the same ones never. A rotation
# derived from the clock — no stored cursor, nothing to get out of sync —
# converts that into round-robin degradation, so every PR is reached within a
# bounded number of passes. It changes nothing while the budget holds.
# See specs/pr_review_policy_recovery.md § Budget (#1240 Codex round 4 P2).
pr_count=$(printf '%s\n' "$open_prs" | grep -c .)
# Overridable so the rotation is a testable function of a known instant rather
# than of when the suite happens to run. Tests only; the fence asserts the
# default is the clock.
rotate_now="${PR_REVIEW_POLICY_RECOVERY_NOW:-$(date -u +%s)}"
rotate=0
[ "$pr_count" -gt 1 ] && rotate=$(( (rotate_now / 900) % pr_count ))
# `head -n 0` is an error on BSD head, so a zero rotation skips the splice
# entirely rather than relying on it being a no-op.
if [ "$rotate" -gt 0 ]; then
  open_prs=$(printf '%s\n' "$open_prs" | tail -n "+$((rotate + 1))"; printf '%s\n' "$open_prs" | head -n "$rotate")
fi

# The PR list is fed on FD 3, not on the loop's stdin. `gh` and the validator
# both run inside this loop, and a command that reads stdin would otherwise
# swallow the remaining PR numbers and end the sweep early after one PR.
while IFS=$'\t' read -r PR head <&3; do
  [ -n "$PR" ] || continue

  ambiguous=false
  sole_owner=true
  if [ -n "$head" ] && printf '%s\n' "$dup_heads" | grep -qxF "$head"; then
    ambiguous=true
    sole_owner=false
    infra "head $head is carried by more than one open PR; publishing red on both contexts rather than one PR's verdict"
  fi

  # ── Self-Review Required ────────────────────────────────────────────
  runs=""
  runs_rc=0
  runs=$(read_runs "$head" "$SELF_REVIEW_CONTEXT") || runs_rc=$?
  if [ "$runs_rc" -ne 0 ]; then
    infra "could not read the '$SELF_REVIEW_CONTEXT' check runs on $head (PR #$PR); withholding"
  elif [ "$(decide_from_runs "$runs")" = "skip" ]; then
    log "PR #$PR: '$SELF_REVIEW_CONTEXT' on $head needs nothing from this lane; not publishing"
  elif [ "$(decide_from_runs "$runs")" = "standdown" ]; then
    stand_down "$PR" "$head" "$runs" "$sole_owner" "$SELF_REVIEW_CONTEXT" || true
  else
    decision=$(decide_from_runs "$runs")
    if [ "$ambiguous" = true ]; then
      conclusion="failure"
      title="$SELF_REVIEW_CONTEXT — ambiguous head"
      summary="More than one open PR carries $head, and one commit slot cannot carry both PRs' verdicts. Close or rebase one of them."
    elif [ "$(pr_author "$PR")" = "$DEPENDABOT_LOGIN" ]; then
      conclusion="skipped"
      title="$SELF_REVIEW_CONTEXT — Dependabot-exempt (recovery sweep)"
      summary="PR #$PR is authored by $DEPENDABOT_LOGIN, which the event-driven job exempts. Reported as skipped so the required context resolves the way the skipped job would have reported it."
    else
      # Read the body HERE, not once per PR at the top of the iteration. An
      # ordinary body edit fires `edited` and so lands a native check run the
      # compare-and-swap below would catch — but a GITHUB_TOKEN-authored edit
      # creates no workflow run at all, so for that case a late read is the
      # only thing that narrows the window (#1240). Same reasoning as the
      # label list; the two verdict inputs are treated alike.
      body=""
      conclusion=""
      if ! body=$(gh_api_scalar "body of PR #$PR" "repos/$REPO/pulls/$PR" --jq '.body // ""'); then
        infra "could not read the body of PR #$PR; withholding '$SELF_REVIEW_CONTEXT'"
      else
        rc=0
        output=$(printf '%s\n' "$body" | "$VALIDATOR" --self-review-only 2>&1) || rc=$?
        case "$rc" in
          0)
            conclusion="success"
            title="$SELF_REVIEW_CONTEXT (recovery sweep)"
            summary="$output"
            ;;
          1)
            conclusion="failure"
            title="$SELF_REVIEW_CONTEXT (recovery sweep)"
            summary="$output"
            ;;
          *)
            infra "validate-pr-body.sh exited $rc on PR #$PR (config/usage error); withholding '$SELF_REVIEW_CONTEXT'"
            ;;
        esac
      fi
    fi
    if [ -n "$conclusion" ]; then
      summary="$summary
Published by the pr-review-policy recovery lane ($decision) because the \`pull_request\` run that normally reports this context did not. See nathanjohnpayne/mergepath#931."
      publish "$PR" "$head" "$runs" "$sole_owner" "$RECOVERY_EXTERNAL_ID" \
        "$SELF_REVIEW_CONTEXT" "$conclusion" "$title" "${summary:0:60000}" || true
    fi
  fi

  # ── Label Gate ──────────────────────────────────────────────────────
  runs=""
  runs_rc=0
  runs=$(read_runs "$head" "$LABEL_GATE_CONTEXT") || runs_rc=$?
  if [ "$runs_rc" -ne 0 ]; then
    infra "could not read the '$LABEL_GATE_CONTEXT' check runs on $head (PR #$PR); withholding"
    continue
  fi
  if [ "$(decide_from_runs "$runs")" = "skip" ]; then
    log "PR #$PR: '$LABEL_GATE_CONTEXT' on $head needs nothing from this lane; not publishing"
    continue
  fi
  if [ "$(decide_from_runs "$runs")" = "standdown" ]; then
    stand_down "$PR" "$head" "$runs" "$sole_owner" "$LABEL_GATE_CONTEXT" || true
    continue
  fi
  decision=$(decide_from_runs "$runs")
  if [ "$ambiguous" = true ]; then
    conclusion="failure"
    title="$LABEL_GATE_CONTEXT — ambiguous head"
    summary="More than one open PR carries $head, and one commit slot cannot carry both PRs' verdicts. Close or rebase one of them."
  else
    # Read the labels HERE, immediately before the verdict. A label
    # add or remove moves no head SHA, and a GITHUB_TOKEN-driven one fires no
    # workflow run at all, so neither publish() fence can see it: reading as
    # late as possible is what shrinks that window (#1240 Codex P1).
    title="$LABEL_GATE_CONTEXT (recovery sweep)"
    labels=""
    if ! labels=$(gh_api_scalar "labels on PR #$PR" "repos/$REPO/pulls/$PR" --jq '(.labels // [])[].name'); then
      infra "could not read the labels of PR #$PR; withholding '$LABEL_GATE_CONTEXT'"
      continue
    fi
    blockers=$(printf '%s\n' "$labels" | mergepath_blocking_labels_csv)
    if [ -n "$blockers" ]; then
      conclusion="failure"
      summary="Merge blocked by label(s): $blockers. Per REVIEW_POLICY.md, the human is the tiebreaker and resolves blocking labels."
    else
      # A green here needs the CLASSIFICATION, not just the label list — see
      # the header. `needs-external-review` is applied by the same workflow
      # run that reports this context, so its absence is a symptom of the
      # missing event, not evidence that no review was required.
      phase_4=""
      if ! phase_4=$(requires_phase_4 "$PR"); then
        conclusion="failure"
        summary="Phase 4 applicability could not be derived for PR #$PR, so the absence of a blocking label is not evidence that none is required; failing closed. The next sweep re-evaluates."
        infra "could not derive Phase 4 requiredness for PR #$PR; published '$LABEL_GATE_CONTEXT' red"
      elif [ "$phase_4" = "true" ]; then
        conclusion="failure"
        summary="PR #$PR requires Phase 4 external review, and the External Review Check job that applies \`needs-external-review\` never ran for this head — the same missing \`pull_request\` delivery this lane is recovering from. The absent label is a symptom, not a clearance, so this gate blocks until the classification runs. Push, edit the body, or toggle a label to re-fire the workflow."
      else
        conclusion="success"
        summary="No blocking labels on PR #$PR, and Phase 4 external review does not apply to it (re-derived from the policy governing its base)."
      fi
    fi
  fi
  summary="$summary
Published by the pr-review-policy recovery lane ($decision) because the \`pull_request\` run that normally reports this context did not. See nathanjohnpayne/mergepath#931."
  publish "$PR" "$head" "$runs" "$sole_owner" "$RECOVERY_EXTERNAL_ID" \
    "$LABEL_GATE_CONTEXT" "$conclusion" "$title" "${summary:0:60000}" || true
done 3<<EOF
$open_prs
EOF

if [ "$had_infra_error" -ne 0 ]; then
  die 1 "sweep finished with one or more read/write failures"
fi
log "sweep complete on $REPO"
