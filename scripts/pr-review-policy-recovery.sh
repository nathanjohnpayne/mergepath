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
#   absent  — the context has NO check run at all on that head. This is the
#             stuck-forever shape, and the only verdict that can be wrong here
#             is one nobody would otherwise get.
#   refresh — the newest reading already contains a run THIS lane published
#             (matched by `external_id`, below). Once the lane owns a head it
#             must keep owning it: GitHub requires the newest run of EACH
#             lineage to be green, so a stale recovery red left standing beside
#             a later native green strands the PR just as hard as the original
#             gap (the two-lineage behaviour measured on #828/#835/#1216).
#
# Anything else is SKIPPED. A head whose native job check already reported is
# not touched, so the common case gains no second lineage and no new strand
# surface. A read that fails is also skipped, and reported as an infra error:
# publishing into unknown state is how a recovery lane turns into an outage.
#
# `external_id` is the discriminator because it is exact. Actions job-native
# check runs carry a UUID there and plain Checks-API POSTs carry an empty
# string; this lane stamps its own constant, so "did this lane write it?" is a
# string equality rather than an inference about UUID shape.
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
#     already uses for the same four labels.
#
# Neither verdict is re-implemented here, so the recovery reading and the
# event-driven reading cannot drift.
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

SELF_REVIEW_CONTEXT="Self-Review Required"
LABEL_GATE_CONTEXT="Label Gate"
# Stamped into every check run this lane publishes and matched on the way back
# in. Keep it in sync with scripts/ci/check_pr_review_policy_recovery.
RECOVERY_EXTERNAL_ID="mergepath-pr-review-policy-recovery"
DEPENDABOT_LOGIN='dependabot[bot]'

had_infra_error=0
infra() { had_infra_error=1; printf 'pr-review-policy-recovery: ERROR: %s\n' "$*" >&2; }

# urlencode <string> — jq's @uri, so a context name with spaces survives the
# query string without a hand-rolled encoder.
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

# publish_decision <head> <context>
#
# Prints `absent`, `refresh` or `skip`. A failed read prints nothing and
# returns 3, which the caller treats as "withhold and flag", never as "skip
# quietly" — the two are the same action but only one of them is a defect.
publish_decision() {
  local head="$1" context="$2" listing=""
  if ! listing=$(gh_api_scalar "check runs for '$context' on $head" \
    --paginate "repos/$REPO/commits/$head/check-runs?check_name=$(urlencode "$context")&per_page=100" \
    --jq '.check_runs[] | "external_id=" + (.external_id // "")'); then
    return 3
  fi
  if [ -z "$listing" ]; then
    printf 'absent'
    return 0
  fi
  if printf '%s\n' "$listing" | grep -qxF "external_id=$RECOVERY_EXTERNAL_ID"; then
    printf 'refresh'
    return 0
  fi
  printf 'skip'
}

# publish <head> <context> <conclusion> <title> <summary>
#
# One POST per verdict. A fresh POST rather than a PATCH of an earlier run:
# every Checks-API POST for a head coalesces into the shared suite where the
# newest run wins, and no run id has to cross a sweep boundary.
publish() {
  local head="$1" context="$2" conclusion="$3" title="$4" summary="$5"
  local fields=(
    -f "name=$context"
    -f "head_sha=$head"
    -f "external_id=$RECOVERY_EXTERNAL_ID"
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

# head_unchanged <pr> <head> — re-read the head immediately before a POST.
# Both verdicts are derived from LIVE PR state, so a push between evaluation
# and publication would pin fresh-state conclusions to a superseded SHA. On
# drift, or on a read that fails, publish nothing: the new head carries no
# check run either, so the next interval recovers it from scratch.
head_unchanged() {
  local pr="$1" head="$2" live=""
  if ! live=$(gh_api_scalar --shape sha "PR #$pr head" "repos/$REPO/pulls/$pr" --jq '.head.sha'); then
    infra "could not revalidate the head of PR #$pr"
    return 1
  fi
  [ "$live" = "$head" ] && return 0
  log "PR #$pr moved from $head to $live during evaluation; publishing nothing for the superseded head"
  return 1
}

open_prs=""
if ! open_prs=$(gh_api_scalar "open pull requests on $REPO" \
  --paginate "repos/$REPO/pulls?state=open&per_page=100" --jq '.[].number'); then
  die 1 "could not list open pull requests on $REPO; nothing swept"
fi
if [ -z "$open_prs" ]; then
  log "no open PRs on $REPO; sweep is a no-op"
  exit 0
fi

# The PR list is fed on FD 3, not on the loop's stdin. `gh` and the validator
# both run inside this loop, and a command that reads stdin would otherwise
# swallow the remaining PR numbers and end the sweep early after one PR.
while IFS= read -r PR <&3; do
  [ -n "$PR" ] || continue
  # ONE detail read per PR: head, author, body and labels all come from the
  # same response, so the two verdicts cannot be computed against two
  # different snapshots of the same PR.
  detail=""
  if ! detail=$(gh_api_scalar "detail of PR #$PR" "repos/$REPO/pulls/$PR"); then
    infra "could not read PR #$PR"
    continue
  fi
  head=$(printf '%s' "$detail" | jq -r '.head.sha // ""')
  author=$(printf '%s' "$detail" | jq -r '.user.login // ""')

  # ── Self-Review Required ────────────────────────────────────────────
  decision=""
  if ! decision=$(publish_decision "$head" "$SELF_REVIEW_CONTEXT"); then
    infra "could not read the '$SELF_REVIEW_CONTEXT' check runs on $head (PR #$PR); withholding"
  elif [ "$decision" = "skip" ]; then
    log "PR #$PR: '$SELF_REVIEW_CONTEXT' already reported on $head by another producer; not publishing"
  else
    if [ "$author" = "$DEPENDABOT_LOGIN" ]; then
      conclusion="skipped"
      title="$SELF_REVIEW_CONTEXT — Dependabot-exempt (recovery sweep)"
      summary="PR #$PR is authored by $DEPENDABOT_LOGIN, which the event-driven job exempts. Reported as skipped so the required context resolves the way the skipped job would have reported it."
    else
      body=$(printf '%s' "$detail" | jq -r '.body // ""')
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
          conclusion=""
          infra "validate-pr-body.sh exited $rc on PR #$PR (config/usage error); withholding '$SELF_REVIEW_CONTEXT'"
          ;;
      esac
    fi
    if [ -n "$conclusion" ]; then
      summary="$summary
Published by the pr-review-policy recovery lane ($decision) because the \`pull_request\` run that normally reports this context did not. See nathanjohnpayne/mergepath#931."
      if head_unchanged "$PR" "$head"; then
        publish "$head" "$SELF_REVIEW_CONTEXT" "$conclusion" "$title" "${summary:0:60000}" || true
      fi
    fi
  fi

  # ── Label Gate ──────────────────────────────────────────────────────
  decision=""
  if ! decision=$(publish_decision "$head" "$LABEL_GATE_CONTEXT"); then
    infra "could not read the '$LABEL_GATE_CONTEXT' check runs on $head (PR #$PR); withholding"
    continue
  fi
  if [ "$decision" = "skip" ]; then
    log "PR #$PR: '$LABEL_GATE_CONTEXT' already reported on $head by another producer; not publishing"
    continue
  fi
  labels=$(printf '%s' "$detail" | jq -r '(.labels // [])[].name')
  blockers=$(printf '%s\n' "$labels" | mergepath_blocking_labels_csv)
  if [ -n "$blockers" ]; then
    conclusion="failure"
    summary="Merge blocked by label(s): $blockers. Per REVIEW_POLICY.md, the human is the tiebreaker and resolves blocking labels."
  else
    conclusion="success"
    summary="No blocking labels on PR #$PR."
  fi
  summary="$summary
Published by the pr-review-policy recovery lane ($decision) because the \`pull_request\` run that normally reports this context did not. See nathanjohnpayne/mergepath#931."
  if head_unchanged "$PR" "$head"; then
    publish "$head" "$LABEL_GATE_CONTEXT" "$conclusion" "$LABEL_GATE_CONTEXT (recovery sweep)" "${summary:0:60000}" || true
  fi
done 3<<EOF
$open_prs
EOF

if [ "$had_infra_error" -ne 0 ]; then
  die 1 "sweep finished with one or more read/write failures"
fi
log "sweep complete on $REPO"
