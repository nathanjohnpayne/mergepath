#!/usr/bin/env bash
# scripts/coderabbit-wait.sh — Phase 2.5 CodeRabbit wait + rate-limit retry
#
# Polls a pull request for a CodeRabbit review anchored on the current HEAD
# commit. Handles three CodeRabbit behaviors that the naive "just wait"
# pattern in AGENTS.md step 5 does not:
#
#   1. **Rate-limit state.** CodeRabbit posts a comment matching
#      "Rate limit exceeded" with a specific retry window
#      ("Please wait X minutes and Y seconds before requesting another
#      review") and then does NOT auto-retry when the window elapses.
#      This script detects that state, sleeps the window + buffer, posts
#      `@coderabbitai, try again.` to re-trigger, and continues polling.
#      See nathanjohnpayne/mergepath#138.
#
#   2. **Auto-pause state.** After N reviewed commits
#      (`reviews.auto_review.auto_pause_after_reviewed_commits`, default 5)
#      CodeRabbit auto-pauses incremental review and posts a "Reviews
#      paused" NOTE carrying the stable marker
#      `<!-- This is an auto-generated comment: review paused by
#      coderabbit.ai -->`. The platform does NOT auto-resume. Our agent
#      loop pushes many fix-up commits per PR, so long PRs cross the
#      threshold and silently stop being reviewed (confirmed on #485).
#      This script detects that marker, posts `@coderabbitai resume`
#      (NOT a one-shot `review`, which re-pauses after the next push),
#      and continues polling — bounded by `max_resume_retries`. Distinct
#      from the rate-limit and in-progress states. See
#      nathanjohnpayne/mergepath#490.
#
#   3. **HEAD freshness.** Auto-merge-on-approval workflows in downstream
#      repos race CodeRabbit: an internal reviewer can post APPROVED before
#      CodeRabbit's review lands (measured p50 ~6 min, p99 ~19 min — #623,
#      not the old "~2–3 min" folklore), and the PR auto-merges pre-review.
#      The script only returns "cleared" when CodeRabbit has posted a
#      non-rate-limited, non-in-progress comment on or after the HEAD
#      committer date. See nathanjohnpayne/mergepath#136.
#
# It also surfaces — without re-invoking — the other detectable reasons
# CodeRabbit auto-review never fires: a PR base branch matched by none of
# the configured `base_branches` REGEX patterns (and not the repo default
# branch, which CodeRabbit always reviews), and a draft PR when
# `drafts: false`. These are reported in the JSON `skip_reason` field
# (paused / non-base-branch / draft) so the caller can act instead of
# waiting out a full timeout. The base-branch check evaluates each entry as
# a regex and fails SAFE (suppresses the skip) on an unparseable pattern.
# See nathanjohnpayne/mergepath#490.
#
# Usage:
#   scripts/coderabbit-wait.sh [--probe] <PR_NUMBER> [REPO]
#
# Arguments:
#   PR_NUMBER  Required. The pull request number (integer).
#   REPO       Optional. Fully-qualified "owner/repo". Defaults to the
#              current repository detected by `gh repo view`.
#
# Options:
#   --probe    Read-only single-scan mode (#814). ONE classification pass
#              over the surfaces the poll loop reads, then exit. Never
#              sleeps, never waits out max_wait_seconds, posts NOTHING: no
#              retry trigger, no `resume`, no status-probe mention, no Codex
#              failover. Answers ONE question — has CodeRabbit reported on
#              this head — and does not judge findings beyond the #535
#              summary-only class: rc 0 means REPORTED, NOT clean; rc 2 is
#              the one verdict probe mode makes (a blocking marker carried
#              solely by the PR-level summary, which no required gate
#              dispositions); rc 7 means not yet. Equivalent to
#              CODERABBIT_WAIT_PROBE=1. Use the polling mode for a verdict.
#
# Environment:
#   GH_TOKEN   Required unless a fresh op-preflight cache is available.
#              Must resolve to the reviewer identity for retry-trigger
#              writes. In the template flow this helper auto-sources
#              $OP_PREFLIGHT_REVIEWER_PAT after preflight.
#   CODERABBIT_WAIT_PROBE
#              Set to 1/true/yes to run in --probe mode without changing a
#              caller's argument list. Reads still need a token.
#
# Behavior:
#   1. Reads coderabbit.max_wait_seconds (default 1245; measured full-fleet max + one poll interval, #623) and
#      coderabbit.max_rate_limit_retries (default 2) from
#      .github/review-policy.yml.
#   2. Fetches PR HEAD SHA + committer date.
#   0. Before polling, check the static skips that mean auto-review will
#      never fire on this PR: base branch matched by none of the
#      `base_branches` regex patterns AND not the repo default branch
#      (#490), and draft when `drafts: false`. On either, emit JSON with
#      the `skip_reason` set and exit 6 (SKIPPED) rather than burning the
#      whole budget on a review that cannot land.
#   3. Polls issue + review comments every 15s. For each CodeRabbit
#      comment newer than HEAD committer date, classifies as:
#        - rate_limit  — body matches /Rate limit exceeded/i
#        - paused      — body carries the "review paused by coderabbit.ai"
#                        auto-generated marker (the #485 auto-pause NOTE)
#        - in_progress — body matches /review in progress|currently reviewing/i
#        - review      — anything else authored by coderabbitai[bot]
#      Precedence (#869): a body whose "Actions performed" block states the
#      review FINISHED is a completed review signal even when the fair-use
#      limit note (which carries the rate-limit marker) is appended to the
#      same comment — completion evidence beats an appended limit notice,
#      but ONLY when head-anchored corroboration exists that the claim
#      temporally FOLLOWS (P1s on #875): a CodeRabbit review object whose
#      commit_id is the current HEAD, or — when
#      trust_status_context_for_clearance is true — the per-SHA CodeRabbit
#      StatusContext reading success on the HEAD, in either case with the
#      finished comment's fresh_at at-or-after the evidence (a completion
#      statement always follows its own review, so evidence that postdates
#      the claim cannot be what the claim reported on). The comment body
#      itself carries no head identity, so with a cherry-picked /
#      old-committer-date new head the wallclock freshness floor admits the
#      PRIOR head's finished comment into the scan — and a review object
#      CodeRabbit just posted for the NEW head is co-present with that
#      stale claim without corroborating it. Uncorroborated, the body falls
#      through to the classification it would have had without this rule
#      (rate_limit when the limit marker is present), preserving the
#      #714/#489 rate-limit semantics. A comment that is ONLY a limit
#      notice still classifies rate_limit. Even corroborated, the finished
#      reply is TERMINALITY evidence only — verdicts (rc 0 vs rc 2, the
#      #535 summary-marker check) are decided on the genuine summary,
#      never on the actions reply, so a reply that is newer than (or
#      edited after) the real summary cannot shadow a blocking marker the
#      summary alone carries.
#   4. On rate_limit: parse "X minutes and Y seconds" (or "X seconds") into a
#      window, sleep the portion of it that REMAINS after subtracting the time
#      already elapsed since the notice was posted (#727 — the window runs from
#      the notice's post time, not from when this helper first sees it), + 30s
#      buffer, then post `@coderabbitai, try again.`, increment the retry
#      counter, and continue polling. An already-expired window sleeps 0.
#   4b. On paused: post `@coderabbitai resume` (a one-shot `review`
#      re-pauses after the next push, so resume is the correct verb),
#      increment a resume-retry counter, and continue polling. If
#      resume_retries > max_resume_retries: exit 6 (SKIPPED) with
#      status=paused and skip_reason=paused so the caller can raise
#      `auto_pause_after_reviewed_commits` or intervene.
#   5. On review (non-rate-limit, non-in-progress): emit JSON, exit 0.
#      Also scans inline diff comments for "Potential issue" / "⚠️"
#      markers and surfaces them in the JSON so callers can decide.
#   6. If total elapsed > max_wait_seconds: if a pause was OBSERVED during
#      polling (a durable same-id pause NOTE never advances the resume
#      budget to its cap), exit 6 (SKIPPED) with status=paused /
#      skip_reason=paused — a still-paused PR must not fall through to the
#      advisory timeout that agent-review.yml merges past. Otherwise
#      optionally post `@coderabbitai, how is the review going?`, wait a
#      short bounded status-probe window for CodeRabbit's reply, then exit 4
#      (TIMEOUT) with the reply excerpt surfaced in JSON. The probe is
#      narration only, never a review / clearance signal.
#   7. If rate_limit_retries > max_rate_limit_retries: exit 5 (STALLED),
#      emit JSON with status=rate_limit_stalled.
#
# Output JSON shape (stdout):
#   {
#     "pr_number": 123,
#     "repo": "owner/repo",
#     "head_sha": "<full sha>",
#     "head_committer_date": "<iso-8601>",
#     "bot_login": "coderabbitai[bot]",
#     "status": "cleared" | "findings" | "timeout" | "rate_limit_stalled"
#               | "paused" | "skipped" | "no_review_yet" | "reported",
#     "skip_reason": null | "paused" | "non-base-branch" | "draft",
#     "review": null | {
#       "id": N,
#       "created_at": "<iso-8601>",
#       # "reviews" is emitted only by --probe, whose primary evidence is a
#       # HEAD-pinned review object. A probe can instead report on "issues"
#       # evidence: the head-pinned completed summarize comment (#851). That
#       # form also carries updated_at and fresh_at, and its created_at is the
#       # comment's ORIGINAL creation time — CodeRabbit edits one summary in
#       # place, so created_at can predate the head it attests by a day or
#       # more. fresh_at carries the edit time; consumers needing head
#       # identity read head_sha, never a timestamp.
#       "endpoint": "issues" | "pulls" | "reviews",
#       # "reviews" evidence only (#875 round 2, additive): the object's
#       # own submitted_at — the same instant created_at carries on that
#       # endpoint, named explicitly so the Phase 4b barrier's temporal
#       # conjunct (probe.context_updated_at at-or-after this) reads a
#       # field whose meaning cannot drift with the endpoint.
#       "submitted_at": "<iso-8601>",
#       "body_excerpt": "<first 200 chars>"
#     },
#     "potential_issue_count": N,
#     # blocking_tier_unresolved (#577): count of unaddressed inline HEAD
#     # findings whose coderabbit_tier_of tier is in the resolved
#     # feedback_policy required set. null when the feedback_policy block is
#     # ABSENT (preserving the historical shape + exit-code contract) or on
#     # any non-findings/cleared terminal. Report-only — it never affects the
#     # exit code; the merge-blocking CodeRabbit gate is
#     # scripts/coderabbit-severity-gate.sh.
#     "blocking_tier_unresolved": null | N,
#     "rate_limit_retries": N,
#     "resume_retries": N,
#     "status_probe": {
#       "enabled": true | false,
#       "posted": true | false,
#       "reply_present": true | false,
#       "reply": null | {
#         "id": N,
#         "created_at": "<iso-8601>",
#         "updated_at": "<iso-8601>",
#         "fresh_at": "<iso-8601>",
#         "body_excerpt": "<first 500 chars>"
#       },
#       "waited_seconds": N
#     },
#     # --probe only (#814); null on every polling run. Distinct from
#     # status_probe above, which is the timeout-time narration request a
#     # --probe run never sends.
#     "probe": null | {
#       "mode": true,
#       # `status_probe` is deliberately absent: both probe scans keep
#       # narration replies out of the observed class — the no-review-object
#       # triage drops them pre-classification, and the review-object
#       # publication scan skips their latch (#833: narration landing after
#       # the review object reads as awaiting-summary, or as the pending
#       # notice beneath it) — so the value is not reachable and advertising
#       # it would be a contract nobody can meet.
#       "observed": "none" | "rate_limit" | "paused" | "in_progress"
#                   | "summary-without-head-review" | "awaiting-summary"
#                   | "terminal",
#       # The per-SHA CodeRabbit StatusContext state on the HEAD
#       # (success|failure|pending|error|missing), sampled ONLY when the
#       # rc-7 verdict carries a HEAD-pinned review object (endpoint
#       # "reviews") and trust_status_context_for_clearance is true; null
#       # otherwise (#869 / P1 on #875). The Phase 4b barrier requires
#       # "success" here before counting rc-7 review-object evidence as
#       # reported: a bare just-posted review object can precede a PR-level
#       # summary that carries the ONLY blocking marker (#535), and the
#       # per-SHA success is what discriminates the wedged-but-complete
#       # #866 state from that mid-publication one.
#       "context_state": null | "success" | "failure" | "pending"
#                        | "error" | "missing",
#       # The refresh time of that same status (#875 round 2), sampled and
#       # nulled together with context_state. The barrier additionally
#       # requires this to be at-or-after the evidence object's
#       # submitted_at (emitted as review.submitted_at on the rc-7
#       # reviews-endpoint evidence): on a same-SHA rerun the statuses
#       # endpoint still exposes the PREVIOUS run's success while the new
#       # object's summary and status refresh are pending, and a success
#       # predating the object belongs to a different run.
#       "context_updated_at": null | "<iso-8601>"
#     },
#     "codex_failover_requested": true | false,
#     "waited_seconds": N
#   }
#
# Exit codes:
#   0   CodeRabbit posted a real review on current HEAD with no
#       "Potential issue"/⚠️ markers. Safe to proceed.
#   2   CodeRabbit posted a real review with at least one P0/P1-equivalent
#       marker. Caller should address before proceeding.
#   3   API / infrastructure error. Error on stderr.
#   4   Timeout — max_wait_seconds elapsed without a real review. Caller
#       may log a warning and proceed (CodeRabbit is advisory), or block.
#   5   Rate-limit stalled — max_rate_limit_retries exceeded. Distinct
#       from timeout so callers can alert the human instead of proceeding.
#   6   Auto-review skipped and not (re-)invocable. Either the static
#       skip — base branch ∉ base_branches, or draft when drafts:false —
#       or an auto-pause whose `@coderabbitai resume` retries are
#       exhausted (max_resume_retries). The JSON `skip_reason` field
#       names the cause (paused / non-base-branch / draft). Distinct from
#       a slow-review timeout (4): the review cannot land as-is, so the
#       caller should raise `auto_pause_after_reviewed_commits`, retarget
#       the base, mark the PR ready, or escalate — not merely log and
#       proceed. See nathanjohnpayne/mergepath#490.
#   7   PROBE_NO_REVIEW — `--probe` only. No CodeRabbit review object is
#       pinned to the current HEAD. NOT a timeout (4), NOT a stalled retry
#       budget (5), NOT an un-invocable skip (6): a probe posts no retry and
#       no `resume`, so it can never have exhausted either budget, and 5 or 6
#       would escalate or excuse a PR CodeRabbit may be about to review.
#       `probe.observed` names which surface the scan landed on. Callers
#       using this as an ordering barrier re-probe on a bound of their own.
#       NOT 1: under `set -euo pipefail` any unguarded failure exits 1 with
#       no JSON, so a caller could not tell rc 1 from a crashed run.
#
#       In `--probe` mode rc 0 means REPORTED — a HEAD-pinned review object
#       exists, or the summarize comment is head-pinned and completed (#851) —
#       and NOT "no findings". rc 2 is the ONE verdict probe mode makes,
#       unchanged in meaning (#535): a blocking marker carried solely by the
#       PR-level summary, which no required gate dispositions.
#       `potential_issue_count` carries no verdict on a probe run. Use the
#       polling mode for a verdict.
#
# Design notes:
#   - Read-only except for retry-trigger comments, the auto-pause
#     `@coderabbitai resume` re-invocation, and timeout status-probe
#     comments. Does not push commits, does not modify labels, does not
#     merge.
#   - `--probe` is read-only with no exceptions. It returns before all
#     three writers above and before the #489 Codex failover, so a probe
#     run performs zero mutations on the PR.
#   - Idempotent across reruns on the same HEAD. A freshly-landed review
#     is detected on the next poll regardless of how many times the script
#     has been run.
#   - JSON emission uses `jq`. Pattern matching on CodeRabbit comment
#     bodies is intentionally heuristic — the bot's output format is not
#     versioned and may drift. See nathanjohnpayne/mergepath#138 for the
#     observed rate-limit string.

set -euo pipefail

# --- preflight auto-source (#282) ------------------------------------------
# If GH_TOKEN is unset and a fresh op-preflight cache exists for this
# agent, source it and export OP_PREFLIGHT_REVIEWER_PAT as GH_TOKEN.
# This lets agents drop the explicit `GH_TOKEN=...` prefix when their
# preflight cache is already warm. Preserves existing behavior when
# GH_TOKEN is already set. The existing
# `[ -z "${GH_TOKEN:-}" ] && exit 3` guard below still fires on a
# missing cache + missing env var (no regression).
__CODERABBIT_WAIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$__CODERABBIT_WAIT_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__CODERABBIT_WAIT_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi
if [ ! -r "$__CODERABBIT_WAIT_DIR/lib/gh-token-resolver.sh" ]; then
  echo "ERROR: gh-token-resolver helper missing: $__CODERABBIT_WAIT_DIR/lib/gh-token-resolver.sh" >&2
  exit 3
fi
# shellcheck source=lib/gh-token-resolver.sh
. "$__CODERABBIT_WAIT_DIR/lib/gh-token-resolver.sh"

# Shared available_reviewers reader (#453) — one strongest-form parser so
# the token-derived expected-identity allow-list (login_is_available_reviewer,
# used at write time) can't be weakened by a quoted/commented reviewer
# entry. Hard-require it: the token-login derivation is a fail-closed
# security check, so a missing helper must error, not silently degrade.
if [ ! -r "$__CODERABBIT_WAIT_DIR/lib/reviewers-helpers.sh" ]; then
  echo "ERROR: reviewers-helpers missing: $__CODERABBIT_WAIT_DIR/lib/reviewers-helpers.sh" >&2
  exit 3
fi
# shellcheck source=lib/reviewers-helpers.sh
. "$__CODERABBIT_WAIT_DIR/lib/reviewers-helpers.sh"

# --- argument parsing -------------------------------------------------------

# --probe (#814): read-only, zero-budget, single-scan mode.
#
# It is NOT MAX_WAIT_SECONDS=0. With a zero budget the loop's top-of-
# iteration ceiling check fires BEFORE the first scan and routes into
# emit_timeout, which POSTS `@coderabbitai, how is the review going?` and
# returns 4 — so zero-budget-as-max-wait would post on every call and never
# actually look. That is why this is a mode, not a value.
PROBE_EXIT_CODE=7
PROBE_MODE=false
case "${CODERABBIT_WAIT_PROBE:-}" in
  1|true|TRUE|True|yes|YES) PROBE_MODE=true ;;
esac

# Leading-flag scan only: the first non-option argument ends the scan, so
# "$@" is left holding exactly the positionals the arity check below already
# validates. Every existing caller passes `<PR_NUMBER> [REPO]` with no flags
# and breaks immediately on $1, so none regress. No array is built, so there
# is no bash 3.2 empty-array-under-set-u hazard.
while [ $# -gt 0 ]; do
  case "$1" in
    --probe)
      PROBE_MODE=true
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      echo "Usage: $0 [--probe] <PR_NUMBER> [REPO]" >&2
      exit 3
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 [--probe] <PR_NUMBER> [REPO]" >&2
  exit 3
fi

PR_NUMBER=$1
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: PR_NUMBER must be an integer; got '$PR_NUMBER'" >&2
  exit 3
fi

REPO=${2:-}
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  if [ -z "$REPO" ]; then
    echo "ERROR: could not detect current repo via 'gh repo view'. Pass REPO explicitly." >&2
    exit 3
  fi
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN is required. Either:" >&2
  echo "  - Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode all)\"" >&2
  echo "    so this helper auto-sources OP_PREFLIGHT_REVIEWER_PAT, OR" >&2
  echo "  - Set GH_TOKEN to the expected reviewer PAT." >&2
  exit 3
fi

# Expected reviewer identity for helper-comment writes. When any of
# the explicit identity envs is set, honor it via
# gh_default_reviewer_identity. Otherwise — e.g. agent-review.yml
# passes only `GH_TOKEN: secrets.REVIEWER_ASSIGNMENT_TOKEN` with no
# MERGEPATH_AGENT / OP_PREFLIGHT_AGENT / GH_AS_REVIEWER_IDENTITY —
# leave it empty so verify_reviewer_write_identity derives the
# expected login from the token itself, constrained to
# available_reviewers (#438). The old behavior hard-defaulted to
# nathanpayne-claude, so a repo whose REVIEWER_ASSIGNMENT_TOKEN is a
# different allowed reviewer failed identity verification before
# posting a retry/status-probe comment — a rate-limited CodeRabbit
# run then exited as infra error instead of retrying.
if [ -n "${GH_AS_REVIEWER_IDENTITY:-}" ] || [ -n "${MERGEPATH_AGENT:-}" ] || [ -n "${OP_PREFLIGHT_AGENT:-}" ]; then
  EXPECTED_REVIEWER_IDENTITY="$(gh_default_reviewer_identity)"
else
  EXPECTED_REVIEWER_IDENTITY=""   # derived lazily from the token at write time
fi

gh_reviewer() (
  unset GITHUB_TOKEN
  # Pin reviewer writes to the reviewer PAT rather than inheriting ambient
  # creds (#533): prefer the preflight-cached reviewer PAT, falling back to
  # GH_TOKEN. Mirrors scripts/resolve-pr-threads.sh's PAT_GH_TOKEN pattern.
  GH_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-${GH_TOKEN:-}}" gh "$@"
)

# --- config readers ---------------------------------------------------------

CONFIG=".github/review-policy.yml"

# Extract a scalar field from the coderabbit: block in review-policy.yml.
# Mirrors the state-machine pattern used by codex-review-request.sh: stops
# at the next top-level key, tolerates column-0 comments. Empty string if
# field missing — caller turns into default.
coderabbit_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^coderabbit:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block {
      if ($1 == field":") {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
        gsub(/^"/, "", $0)
        gsub(/"[[:space:]]*(#.*)?$/, "", $0)
        gsub(/[[:space:]]*#.*$/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        print
        exit
      }
    }
  ' "$CONFIG"
}

# read_available_reviewers + login_is_available_reviewer now live in
# scripts/lib/reviewers-helpers.sh (sourced above, #453). They default to
# $CONFIG, so the call sites below are unchanged. The token-derived
# expected-identity path (#438) still consumes login_is_available_reviewer
# to keep the derivation fail-closed.

# --- .coderabbit.yml readers (#490) -----------------------------------------
#
# The auto-review skip conditions (base_branches allow-list, drafts gate)
# live in CodeRabbit's own config, not review-policy.yml. Read them with the
# same dependency-free awk-state-machine style used for coderabbit_field so
# this helper picks up no new `yq` runtime dependency (it already requires
# only `gh`/`jq`). Both readers walk the nested
# `reviews:` → `auto_review:` block by indentation. Absent file / key →
# empty output, and the caller treats that as "no configured constraint"
# (the skip check is suppressed) so a consumer without the keys is never
# falsely reported as skipped.
CODERABBIT_YML=".coderabbit.yml"

# Emit each configured base branch (one per line) from
# reviews.auto_review.base_branches. Tolerates quotes, inline comments, and
# leading-dash list syntax. Empty output when the key is absent.
coderabbit_yml_base_branches() {
  [ -f "$CODERABBIT_YML" ] || return 0
  awk '
    # Track the two-level path into reviews: -> auto_review: -> base_branches:
    /^reviews:[[:space:]]*$/ { in_reviews=1; in_auto=0; in_list=0; next }
    in_reviews && /^[^[:space:]#]/ { in_reviews=0; in_auto=0; in_list=0 }
    in_reviews && /^  auto_review:[[:space:]]*$/ { in_auto=1; in_list=0; next }
    # A new 2-space key under reviews: closes auto_review:
    in_auto && /^  [^[:space:]#]/ && $0 !~ /^  auto_review:/ { in_auto=0; in_list=0 }
    in_auto && /^    base_branches:[[:space:]]*$/ { in_list=1; next }
    # A new 4-space key under auto_review: closes the base_branches list
    in_list && /^    [^[:space:]#-]/ { in_list=0 }
    in_list && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/[[:space:]]*#.*$/, "", line)
      gsub(/^["'"'"']/, "", line)
      gsub(/["'"'"'][[:space:]]*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") print line
    }
  ' "$CODERABBIT_YML"
}

# Emit the literal value of reviews.auto_review.drafts (true|false), or
# empty when the key is absent.
coderabbit_yml_drafts() {
  [ -f "$CODERABBIT_YML" ] || return 0
  awk '
    /^reviews:[[:space:]]*$/ { in_reviews=1; in_auto=0; next }
    in_reviews && /^[^[:space:]#]/ { in_reviews=0; in_auto=0 }
    in_reviews && /^  auto_review:[[:space:]]*$/ { in_auto=1; next }
    in_auto && /^  [^[:space:]#]/ && $0 !~ /^  auto_review:/ { in_auto=0 }
    in_auto && /^    drafts:[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*drafts:[[:space:]]*/, "", line)
      gsub(/[[:space:]]*#.*$/, "", line)
      gsub(/^["'"'"']/, "", line)
      gsub(/["'"'"'][[:space:]]*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$CODERABBIT_YML"
}

# max_wait_seconds: the poll ceiling before an advisory exit 4. Default 1245s
# is measured (#623): the mined CodeRabbit review latency (commit → first
# body-bearing review, rate-limited rounds excluded) across ALL EIGHT
# CodeRabbit-active consumers is p50 414s / p90 861s / p99 1136s / max 1219s
# (n=142, docs/audits/data/review-latency-2026-07/). The prior 300s sat below
# even the p50, so >50% of PRs timed the wait out before CodeRabbit reviewed —
# reopening the #136 pre-review-merge race. 1245s = 83 × POLL_INTERVAL_SECONDS
# = one full poll interval BEYOND the observed max (1219s): the loop below
# checks ELAPSED >= MAX_WAIT_SECONDS at the TOP of each iteration and times out
# with no final scan, so a review landing in the last poll window would be
# missed by a ceiling set exactly at the tail (Codex P2 on #688 caught both the
# blind spot and that a 5-repo subset understated the max at 1136s). One
# interval of headroom guarantees the slowest observed review still gets a poll
# scan before the timeout. It is a CEILING (the poll returns as soon as the
# review lands, ~p50 7 min); paused/rate-limit/skip fast-paths short-circuit
# genuinely-stuck rounds.
MAX_WAIT_SECONDS=$(coderabbit_field max_wait_seconds)
MAX_WAIT_SECONDS=${MAX_WAIT_SECONDS:-1245}
if ! [[ "$MAX_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.max_wait_seconds must be an integer; got '$MAX_WAIT_SECONDS'" >&2
  exit 3
fi

MAX_RATE_LIMIT_RETRIES=$(coderabbit_field max_rate_limit_retries)
MAX_RATE_LIMIT_RETRIES=${MAX_RATE_LIMIT_RETRIES:-2}
if ! [[ "$MAX_RATE_LIMIT_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.max_rate_limit_retries must be an integer; got '$MAX_RATE_LIMIT_RETRIES'" >&2
  exit 3
fi

# Auto-pause (#490): how many times to post `@coderabbitai resume` before
# giving up and exiting 6 (skipped, status=paused). Mirrors
# max_rate_limit_retries but for the durable auto-pause state — a single
# resume can re-pause once more fix-up commits land, so a small cap keeps
# us from a resume↔pause ping-pong while still recovering the common case.
MAX_RESUME_RETRIES=$(coderabbit_field max_resume_retries)
MAX_RESUME_RETRIES=${MAX_RESUME_RETRIES:-2}
if ! [[ "$MAX_RESUME_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.max_resume_retries must be an integer; got '$MAX_RESUME_RETRIES'" >&2
  exit 3
fi

WALLCLOCK_FRESHNESS_WINDOW_SECONDS=$(coderabbit_field wallclock_freshness_window_seconds)
WALLCLOCK_FRESHNESS_WINDOW_SECONDS=${WALLCLOCK_FRESHNESS_WINDOW_SECONDS:-1800}
if ! [[ "$WALLCLOCK_FRESHNESS_WINDOW_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.wallclock_freshness_window_seconds must be an integer; got '$WALLCLOCK_FRESHNESS_WINDOW_SECONDS'" >&2
  exit 3
fi

BOT_LOGIN=$(coderabbit_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"coderabbitai[bot]"}
POLL_INTERVAL_SECONDS=15
STATUS_PROBE_POLL_INTERVAL_SECONDS=5
RATE_LIMIT_BUFFER_SECONDS=30

# #596: CodeRabbit flips its commit StatusContext to `success` while
# rate-limited, ~1s AFTER posting the rate-limit notice (the #595 spurious
# success). When the latest HEAD-referencing CodeRabbit comment is a
# non-review notice (rate_limit/paused/in_progress), a `success` that lands
# within this many seconds of it is treated as that near-simultaneous flip and
# suppressed (keep polling); a `success` that postdates the notice by MORE than
# this is a genuine later re-review — which per #221 can be silent (no new
# summary comment) — and stays authoritative. Comfortably above CodeRabbit's
# flip latency (seconds) yet below its minutes-long rate-limit windows, so the
# #595 false success is caught while a real recovery review still clears.
STATUS_SUCCESS_GRACE_SECONDS=120

# --- tier-aware classification (#577) ---------------------------------------
# Additive tier-awareness layered ON TOP of the existing binary
# `Potential issue`/⚠️ detector — it NEVER replaces the exit-code fast-paths
# below (HEAD-anchoring, rate-limit, auto-pause). When the feedback_policy
# block is PRESENT, this surfaces a `blocking_tier_unresolved` count (findings
# on HEAD whose coderabbit_tier_of tier is in the resolved required set) in
# the emitted JSON. When the block is ABSENT — or the shared lib is not on
# disk (some test harnesses stage this script without scripts/lib) —
# BLOCKING_TIER_UNRESOLVED stays `null` and the exit-code contract is
# byte-identical to before. Guarded source, same posture as the preflight
# helpers above: surfacing is best-effort, not a gate.
#
# NOTE: the merge-BLOCKING CodeRabbit gate is scripts/coderabbit-severity-gate.sh
# (a required check); this helper only REPORTS the count so the authoring
# agent can prioritize, mirroring codex-review-request.sh's per-finding
# `blocking` flag. It does not itself block.
BLOCKING_TIER_UNRESOLVED="null"
FEEDBACK_POLICY_PRESENT=false
if [ -f "$CONFIG" ] && grep -qE '^feedback_policy:' "$CONFIG" \
    && [ -r "$__CODERABBIT_WAIT_DIR/lib/feedback-policy-helpers.sh" ]; then
  # shellcheck source=lib/feedback-policy-helpers.sh
  . "$__CODERABBIT_WAIT_DIR/lib/feedback-policy-helpers.sh"
  set +e
  __CRW_REQUIRED_TIERS=$(resolve_required_tiers "$CONFIG")
  __CRW_RT_RC=$?
  set -e
  if [ "$__CRW_RT_RC" -eq 2 ]; then
    echo "ERROR: malformed feedback_policy block in $CONFIG (resolve_required_tiers exit 2)" >&2
    exit 3
  fi
  FEEDBACK_POLICY_PRESENT=true
fi

# Return 0 iff $1 (a tier like p0..p3|nitpick) is in the resolved set.
# Only meaningful when FEEDBACK_POLICY_PRESENT=true.
crw_tier_is_required() {
  local needle=$1 t
  [ -n "$needle" ] || return 1
  while IFS= read -r t; do
    [ "$t" = "$needle" ] && return 0
  done <<< "${__CRW_REQUIRED_TIERS:-}"
  return 1
}

# #489: CodeRabbit→Codex rate-limit failover. When CodeRabbit posts a
# rate-limit notice, request `@codex review` once so the PR advances via the
# real blocking gate (Codex) instead of idling on the advisory bot's hourly
# allowance. Composes with codex.request_by_default (#486) but fires regardless
# of it (MERGEPATH_PHASE_4A_GATED=true) for the duration of the stall. It is
# time-boxed and self-reverting: a single HEAD-pinned trigger per run, so once
# CodeRabbit recovers the steady-state posture returns with no permanent Codex
# pin. Default true (opt out with coderabbit.codex_failover_on_rate_limit:
# false). Only an explicit "false" disables it; a missing key keeps it on.
CODEX_FAILOVER_ON_RATE_LIMIT=$(coderabbit_field codex_failover_on_rate_limit)
CODEX_FAILOVER_ON_RATE_LIMIT=${CODEX_FAILOVER_ON_RATE_LIMIT:-true}
# The Codex request helper, invoked in --trigger-only mode on rate-limit.
# Overridable for tests via CODERABBIT_WAIT_CODEX_REQUEST_CMD.
CODEX_REQUEST_CMD="${CODERABBIT_WAIT_CODEX_REQUEST_CMD:-$__CODERABBIT_WAIT_DIR/codex-review-request.sh}"

# Stable marker CodeRabbit wraps its auto-pause "Reviews paused" NOTE in
# (#490 / #485). Keyed on directly — the prose ("## Reviews paused", the
# resume/review bullet list) is not versioned, but this HTML-comment marker
# is the same shape CodeRabbit emits for its other auto-generated notices
# (cf. the `rate limited by coderabbit.ai` marker on the same surface).
PAUSED_MARKER='review paused by coderabbit.ai'

# Stable marker CodeRabbit wraps its rate-limit notice in, on the same
# auto-generated surface as PAUSED_MARKER. Keyed on directly because the
# user-facing prose is NOT versioned and has already drifted: the original
# notice (#138) read "Rate limit exceeded" / "Please wait X minutes and Y
# seconds", but CodeRabbit's adaptive "Fair Usage Limits" variant reads
# "Review limit reached" / "Next review available in: N minutes" — matching
# NONE of the old text patterns. The HTML-comment marker is identical across
# both, so classify_comment() keys on it first (see #593: a drifted notice
# misclassified as a clean `review` false-cleared the gate and merged #591
# with no CodeRabbit review).
RATE_LIMIT_MARKER='rate limited by coderabbit.ai'

# Stable marker CodeRabbit wraps its MID-REVIEW summary state in, on the same
# auto-generated surface as PAUSED_MARKER / RATE_LIMIT_MARKER. Load-bearing:
# CodeRabbit edits ONE summary comment in place and writes the `📥 Commits`
# range at review START (recovered from #849's edit history), so the
# processing state ALREADY names the new head — and its prose ("Currently
# processing new changes") matches NONE of classify_comment's in_progress
# patterns. The state classifies correctly today only because this marker's
# text happens to contain the literal "review in progress"; one accidental
# substring must not be the whole defence. See #593.
IN_PROGRESS_MARKER='review in progress by coderabbit.ai'

# CodeRabbit keeps exactly ONE comment carrying this marker per PR (19/19
# sampled for #851) and edits it in place — it is the bot's own head-tracking
# state, not any one message. Selecting BY this marker, never "the newest
# non-narration bot comment", is what makes a CodeRabbit CHAT REPLY
# structurally unable to supply probe evidence: two live replies (#794, #518)
# classify `review`, carry no stanzas, and embed a full 40-hex head SHA lifted
# from a `gh pr view` snippet — and on #794 that reply predated the round's
# review object by ~6 minutes, the exact ordering failure the same-head
# barrier exists to prevent.
SUMMARY_MARKER='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->'

# Every CodeRabbit outcome stanza in the summary is wrapped in
#   <!-- This is an auto-generated comment: <KIND> by coderabbit.ai -->
# and the commits range describes whatever run last touched the comment,
# INCLUDING runs that produced no review: `rate limited`, `failure` (#790
# names its head exactly while saying "Review failed"), `review in progress`.
# The summary counts as a completed report only when the ONLY stanzas present
# are its identity marker and the release-notes wrapper — the TOTAL is counted
# from the bare wrapper prefix in summary_stanzas_all_benign, so any KIND
# registers whatever characters it uses. ALLOW-list, not deny-list: a KIND
# CodeRabbit has not shipped yet must read as not-yet, never clean — also the
# independent defence against IN_PROGRESS_MARKER drift.
CR_SUMMARY_BENIGN_STANZA_RE='auto-generated comment: (summarize|release notes) by coderabbit\.ai'

# CodeRabbit's pre-merge check table grades PR hygiene and renders a
# `⚠️ Warning` row for a below-threshold docstring score — not a code finding
# (3 of 5 sampled summaries carry one). Both delimiters must be present or
# nothing is stripped, so delimiter drift degrades to the louder behaviour
# (rc 2 → a human), never a quieter one.
CR_PRE_MERGE_BLOCK_START='<!-- pre_merge_checks_walkthrough_start -->'
CR_PRE_MERGE_BLOCK_END='<!-- pre_merge_checks_walkthrough_end -->'

# CodeRabbit emits two distinct per-SHA signals:
#   1. Narrative review comment (issue/PR comment + inline diff comments).
#      The freshness-anchored polling loop watches for this. Posted only
#      when there's commentary to add — clean re-reviews on fix-up pushes
#      can skip it entirely.
#   2. `CodeRabbit` StatusContext check on the commit status API. Always
#      posted per-SHA, terminal state SUCCESS/FAILURE.
# The narrative comment alone is the historical terminal-state source,
# but on a fix-up push that genuinely cleared all prior findings, signal
# (2) flips to SUCCESS while signal (1) stays silent — and this script
# would burn its full MAX_WAIT_SECONDS budget waiting for a comment that
# never comes. Toggle off via `coderabbit.trust_status_context_for_clearance:
# false` in `.github/review-policy.yml` for repos that prefer the
# strict comment-driven gate. See nathanjohnpayne/mergepath#221.
TRUST_STATUS_CONTEXT=$(coderabbit_field trust_status_context_for_clearance)
TRUST_STATUS_CONTEXT=${TRUST_STATUS_CONTEXT:-true}
case "$TRUST_STATUS_CONTEXT" in
  true|false) ;;
  *)
    echo "ERROR: coderabbit.trust_status_context_for_clearance must be true|false; got '$TRUST_STATUS_CONTEXT'" >&2
    exit 3
    ;;
esac

STATUS_PROBE_ENABLED=$(coderabbit_field status_probe_enabled)
STATUS_PROBE_ENABLED=${STATUS_PROBE_ENABLED:-true}
case "$STATUS_PROBE_ENABLED" in
  true|false) ;;
  *)
    echo "ERROR: coderabbit.status_probe_enabled must be true|false; got '$STATUS_PROBE_ENABLED'" >&2
    exit 3
    ;;
esac

STATUS_PROBE_WAIT_SECONDS=$(coderabbit_field status_probe_wait_seconds)
STATUS_PROBE_WAIT_SECONDS=${STATUS_PROBE_WAIT_SECONDS:-60}
if ! [[ "$STATUS_PROBE_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: coderabbit.status_probe_wait_seconds must be an integer; got '$STATUS_PROBE_WAIT_SECONDS'" >&2
  exit 3
fi

# --- logging helpers --------------------------------------------------------

log() {
  echo "[coderabbit-wait] $*" >&2
}

die() {
  local code=$1
  shift
  echo "[coderabbit-wait] ERROR: $*" >&2
  exit "$code"
}

# An exit-0 `gh api` invocation that writes NOTHING is not an empty array —
# it is an unreadable payload, and the two helpers below must not launder it
# into one. `jq -s 'add // []'` maps empty input to `[]`, and a downstream
# `type == "array"` guard cannot tell that `[]` apart from a real one, so
# every caller that distinguishes "the lookup CONFIRMED zero rows" from "the
# lookup failed" would read the outage as a confident negative — the exact
# collapse the three-outcome rule at newest_head_pinned_review_submitted_at
# exists to prevent (a blank read there would fall through to the
# StatusContext leg the failed-lookup case denies outright). A REST array
# endpoint always writes at least `[]`, so blank stdout is only ever a
# failure. Whitespace-only is the same case: command substitution already
# strips trailing newlines, and any remaining blank run is still no JSON.
raw_body_is_blank() {
  case $1 in
    *[![:space:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

fetch_api_array() {
  local endpoint=$1
  local label=$2
  local raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || die 3 "failed to fetch $label: $raw"
  if raw_body_is_blank "$raw"; then
    die 3 "empty response body fetching $label (not an empty array)"
  fi
  echo "$raw" | jq -s 'add // []' 2>/dev/null \
    || die 3 "failed to flatten $label pagination output"
}

fetch_api_array_best_effort() {
  local endpoint=$1
  local label=$2
  local raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || {
    log "best-effort fetch failed for $label: $raw"
    return 1
  }
  if raw_body_is_blank "$raw"; then
    log "best-effort fetch returned an empty response body for $label (not an empty array) — treating as a failed read"
    return 1
  fi
  echo "$raw" | jq -s 'add // []' 2>/dev/null || {
    log "best-effort fetch failed to flatten $label pagination output"
    return 1
  }
}

# Fetch the CodeRabbit `StatusContext` check on the current HEAD SHA.
# Emits compact JSON with:
#   { "state": "success|failure|pending|error|missing", "created_at": "..." }
#
# `missing` covers both the no-statuses-yet case and any transient API
# hiccup (network, 5xx, etc.) — caller treats it as "fall through to
# the existing comment-driven path."
#
# Two defensive guards (CodeRabbit ⚠️ Critical on PR #224 round 1):
#
# 1. Filter by `creator.login == $BOT_LOGIN` in addition to context.
#    Anyone with write access to commit statuses can post a status
#    with the literal context string "CodeRabbit"; without the
#    creator filter, that's a spoof vector. The configured bot login
#    is the only signal we trust.
#
# 2. Use `sort_by(.created_at) | last` to pick the latest status, not
#    `head -n 1`. The /statuses endpoint does not guarantee chronological
#    ordering across calls, so `head` could return a stale status if
#    multiple have been posted on the same SHA (e.g., re-evaluation
#    after a CodeRabbit retry).
#
# Endpoint choice: `/commits/{sha}/statuses` (plural) returns each
# status object with full `creator` details. The singular
# `/commits/{sha}/status` rolls up state but omits per-status creator
# fields, which would defeat guard 1. Confirmed empirically — see
# PR #224 round 2.
check_status_context_record() {
  local resp
  # Pagination (CodeRabbit ⚠️ Minor @ line 267 on PR #224 round 2):
  # `/commits/{ref}/statuses` defaults to per_page=30 and returns
  # statuses in reverse chronological order. Without `--paginate`, a
  # commit with >30 statuses (e.g., long-running PR with retries)
  # could miss the latest CodeRabbit entry in the unpaginated first
  # page if non-CodeRabbit statuses crowd it out. `--paginate` plus
  # `jq -s 'add // []'` flattens all pages into a single array before
  # the context+creator filter runs.
  #
  # `updated_at` (#875 round 2, additive): the newest status' refresh time,
  # used by the temporal-correlation checks (head_completion_corroborated
  # and probe.context_updated_at). The REST API cannot update a commit
  # status in place — each run POSTs a new status object — so updated_at
  # and created_at coincide in practice; the `// .created_at` fallback
  # keeps the field meaningful if a proxy strips one of them.
  resp=$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/statuses" 2>/dev/null \
    | jq -s 'add // []' 2>/dev/null) || {
    jq -nc '{state: "missing", created_at: "", updated_at: ""}'
    return
  }
  echo "$resp" | jq -c --arg bot "$BOT_LOGIN" '
    [ .[]?
      | select(.context == "CodeRabbit")
      | select((.creator.login // "") == $bot)
    ]
    | sort_by(.created_at)
    | last
    | if . == null then
        {state: "missing", created_at: "", updated_at: ""}
      else
        {state: (.state // "missing"), created_at: (.created_at // ""),
         updated_at: (.updated_at // .created_at // "")}
      end
  '
}

check_status_context() {
  check_status_context_record | jq -r '.state'
}

# --- fetch PR metadata ------------------------------------------------------

log "PR $REPO#$PR_NUMBER — fetching HEAD commit metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) || die 3 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 3 "could not determine HEAD sha for PR #$PR_NUMBER"
fi

# Base branch + draft state for the #490 static-skip checks below. All
# come from the PR metadata already in hand — no extra API call. The
# repo default branch is needed because CodeRabbit always reviews PRs
# into the default branch even when it is not redundantly listed in
# base_branches, so the non-base-branch skip must never fire for it.
PR_BASE_REF=$(echo "$PR_JSON" | jq -r '.base.ref // ""')
PR_IS_DRAFT=$(echo "$PR_JSON" | jq -r 'if .draft == true then "true" else "false" end')
PR_DEFAULT_BRANCH=$(echo "$PR_JSON" | jq -r '.base.repo.default_branch // ""')

HEAD_COMMITTER_DATE=$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>&1) \
  || die 3 "failed to fetch commit date for $HEAD_SHA: $HEAD_COMMITTER_DATE"

# HEAD freshness anchor. Two stacked guards — committer date alone is
# unreliable:
#
#   Layer 1 (force-push): advance the anchor past any
#     `head_ref_force_pushed` event on this PR's timeline. Closes the
#     force-push-with-old-commit false-clear. See #140 round-2 Codex
#     finding (P1, line 270).
#
#   Layer 2 (wallclock floor): max the anchor with NOW - window.
#     Without this, an ordinary push of a commit with an old committer
#     date (cherry-pick, rebase with `--committer-date-is-author-date`,
#     or a commit whose metadata was rewritten) lets CodeRabbit comments
#     from a prior review round pass the filter and the script exits
#     cleared/findings without waiting for a real review on the new
#     HEAD. See #51/#52/#30/#35 round-3 Codex findings ("Anchor
#     CodeRabbit freshness to push time", "Gate reviews against a
#     fresh poll anchor", "Tie CodeRabbit freshness to push time",
#     "Filter CodeRabbit state by current HEAD SHA", "Gate on review
#     commit rather than comment timestamp").
#
# The two layers compose: force-push events get exact timestamps when
# available, and the wallclock floor bounds residual exposure for the
# ordinary-push path where the GitHub API does not expose a reliable
# per-push time for non-force pushes.
#
# Mirrors the REACTION_THRESHOLD computation in codex-review-request.sh,
# which uses `reaction_freshness_window_seconds` as its floor. Here the
# knob is `coderabbit.wallclock_freshness_window_seconds` (default
# 1800s / 30min — long enough for a typical Phase 2.5 cycle to land,
# short enough that cross-cycle staleness is caught).
HEAD_ANCHOR="$HEAD_COMMITTER_DATE"
ANCHOR_SOURCE="HEAD committer date"
TIMELINE_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/timeline" "PR timeline")
LATEST_FORCE_PUSH_TIME=$(echo "$TIMELINE_JSON" | jq -r '
  [ .[] | select(.event == "head_ref_force_pushed") | .created_at ]
  | max // ""
')
if [ -n "$LATEST_FORCE_PUSH_TIME" ] && [[ "$LATEST_FORCE_PUSH_TIME" > "$HEAD_ANCHOR" ]]; then
  HEAD_ANCHOR="$LATEST_FORCE_PUSH_TIME"
  ANCHOR_SOURCE="head_ref_force_pushed @ $LATEST_FORCE_PUSH_TIME"
fi
HEAD_IDENTITY_ANCHOR="$HEAD_ANCHOR"

# Layer 2 — wallclock freshness floor.
EPOCH_NOW=$(date +%s)
EPOCH_FLOOR=$((EPOCH_NOW - WALLCLOCK_FRESHNESS_WINDOW_SECONDS))
if FLOOR_ISO=$(date -u -r "$EPOCH_FLOOR" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  :
else
  FLOOR_ISO=$(date -u -d "@$EPOCH_FLOOR" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
    || die 3 "could not compute wallclock freshness floor from epoch $EPOCH_FLOOR"
fi
if [[ "$FLOOR_ISO" > "$HEAD_ANCHOR" ]]; then
  HEAD_ANCHOR="$FLOOR_ISO"
  ANCHOR_SOURCE="wallclock floor (NOW - ${WALLCLOCK_FRESHNESS_WINDOW_SECONDS}s)"
fi

log "HEAD = $HEAD_SHA committed at $HEAD_COMMITTER_DATE"
log "anchor = $HEAD_ANCHOR (source: $ANCHOR_SOURCE)"

# #727: post-clearance fast path. When the caller (auto-merge-on-approval) has
# already confirmed — on THIS head — a verified ACTUAL Codex/Phase-4b clearance
# AND a reviewer-identity APPROVED, it sets CODERABBIT_WAIT_POST_CLEARANCE=1.
# The real blocking bot-review signal is already in, so cap the CodeRabbit poll
# budget to post_clearance_max_wait_seconds (default 240) instead of the full
# max_wait_seconds — CodeRabbit still gets that window to land a clear (exit 0)
# or a Potential issue / ⚠️ finding (exit 2), both handled exactly as before; a
# still-pending CodeRabbit after the cap falls through to the same advisory
# exit-4 timeout. Only ever SHORTENS the ceiling (min of the two), never
# lengthens it. Placed AFTER head resolution so it can head-pin the clearance.
case "${CODERABBIT_WAIT_POST_CLEARANCE:-}" in
  1|true|TRUE|True|yes|YES)
    POST_CLEARANCE_MAX_WAIT_SECONDS=$(coderabbit_field post_clearance_max_wait_seconds)
    POST_CLEARANCE_MAX_WAIT_SECONDS=${POST_CLEARANCE_MAX_WAIT_SECONDS:-240}
    # Head-pin (#727, Codex P2 on #729): the caller proved clearance for a
    # specific head, passed as CODERABBIT_WAIT_POST_CLEARANCE_SHA. The cap
    # applies ONLY when that SHA is non-empty AND equals the head we resolved.
    # FAIL CLOSED on empty or mismatched (Codex P2 r-comment on #729): an empty
    # SHA means the caller could not resolve/verify the cleared head (e.g. a
    # transient API read failure during the probe) — treating "absent" as
    # "no pin needed" would let the shortened budget apply to a head that was
    # never cleared, reopening the very TOCTOU race the pin closes. A mismatch
    # means a push landed after the caller's clearance check. Either way, use
    # the full max_wait budget. HEAD_SHA is always non-empty here, so a simple
    # `!=` covers both the empty-SHA and drifted-SHA cases.
    if [ "${CODERABBIT_WAIT_POST_CLEARANCE_SHA:-}" != "$HEAD_SHA" ]; then
      echo "[coderabbit-wait] WARNING: post-clearance head-pin '${CODERABBIT_WAIT_POST_CLEARANCE_SHA:-<empty>}' does not match the live head $HEAD_SHA (empty ⇒ the caller could not resolve/verify the cleared head) — failing closed: ignoring the fast path and using the full max_wait budget (#727)" >&2
    # Validate ONLY when the fast path is actually engaged (#727, CodeRabbit
    # Major on #729): a fail-safe opt-in latency knob must never break an
    # unrelated wait, so a bad value here DISARMS the cap (full budget) with a
    # warning rather than aborting — the "only ever shortens, never breaks the
    # wait" invariant.
    elif ! [[ "$POST_CLEARANCE_MAX_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
      echo "[coderabbit-wait] WARNING: coderabbit.post_clearance_max_wait_seconds must be an integer; got '$POST_CLEARANCE_MAX_WAIT_SECONDS' — ignoring the post-clearance fast path and using the full max_wait budget (#727)" >&2
    elif [ "$POST_CLEARANCE_MAX_WAIT_SECONDS" -lt "$MAX_WAIT_SECONDS" ]; then
      echo "[coderabbit-wait] post-clearance fast path: HEAD $HEAD_SHA has verified Codex/Phase-4b clearance + reviewer APPROVED; capping max_wait ${MAX_WAIT_SECONDS}s -> ${POST_CLEARANCE_MAX_WAIT_SECONDS}s (#727)" >&2
      MAX_WAIT_SECONDS=$POST_CLEARANCE_MAX_WAIT_SECONDS
    fi
    ;;
esac

log "max_wait = ${MAX_WAIT_SECONDS}s   max_rate_limit_retries = $MAX_RATE_LIMIT_RETRIES   freshness_window = ${WALLCLOCK_FRESHNESS_WINDOW_SECONDS}s"
log "status_probe_enabled = $STATUS_PROBE_ENABLED   status_probe_wait = ${STATUS_PROBE_WAIT_SECONDS}s"

# --- state machine ----------------------------------------------------------

# Parse a rate-limit wait window from a CodeRabbit comment body.
# Emits seconds on stdout. Returns 1 if no window found.
parse_rate_limit_window() {
  local body=$1
  # "Please wait X minutes and Y seconds before requesting another review"
  local mins secs total
  if [[ "$body" =~ [Pp]lease\ wait\ +\*?\*?([0-9]+)\*?\*?\ +minutes?\ +and\ +\*?\*?([0-9]+)\*?\*?\ +seconds? ]]; then
    mins=${BASH_REMATCH[1]}
    secs=${BASH_REMATCH[2]}
    total=$((mins * 60 + secs))
    echo "$total"
    return 0
  fi
  if [[ "$body" =~ [Pp]lease\ wait\ +\*?\*?([0-9]+)\*?\*?\ +seconds? ]]; then
    secs=${BASH_REMATCH[1]}
    echo "$secs"
    return 0
  fi
  if [[ "$body" =~ [Pp]lease\ wait\ +\*?\*?([0-9]+)\*?\*?\ +minutes? ]]; then
    mins=${BASH_REMATCH[1]}
    total=$((mins * 60))
    echo "$total"
    return 0
  fi
  # Adaptive "Fair Usage Limits" variant (#593): "Next review available in:
  # **N minutes**" (or "... N seconds"). CodeRabbit wraps the label and value
  # in markdown bold, so the star/space run between them varies — [* ]* absorbs
  # it. Held in a variable and matched unquoted so the literal spaces are part
  # of the regex, not shell word-split (bash 3.2 safe).
  local re_next_min='[Nn]ext review available in:[* ]*([0-9]+)[* ]*minutes?'
  if [[ "$body" =~ $re_next_min ]]; then
    mins=${BASH_REMATCH[1]}
    total=$((mins * 60))
    echo "$total"
    return 0
  fi
  local re_next_sec='[Nn]ext review available in:[* ]*([0-9]+)[* ]*seconds?'
  if [[ "$body" =~ $re_next_sec ]]; then
    secs=${BASH_REMATCH[1]}
    echo "$secs"
    return 0
  fi
  return 1
}

# #869: completion evidence in an actions-performed reply. CodeRabbit edits
# its reply to a review command in place: the "Actions performed" block flips
# to "Full review finished." when the triggered review completes, and when
# that review consumed the last allowance unit the fair-use limit note —
# carrying RATE_LIMIT_MARKER — is appended to the SAME comment ("Your
# included review limit is currently reached under our Fair Usage Limits...",
# observed live on #866). The limit note describes the NEXT review's
# availability, not this review's outcome, so a body stating its review
# FINISHED is a completed/terminal review signal — PROVIDED head-anchored
# corroboration exists (head_completion_corroborated below; P1 on #875) —
# never rate_limit.
# Conjunctive on purpose: a comment that is ONLY a limit notice carries no
# actions-performed block and no "finished" claim, so genuine rate-limit
# detection (the #714/#489 paths) is untouched; and "Full review triggered."
# — the pre-completion wording of the same block — states no completion and
# still defers to an appended notice.
#
# Matched as a STANZA, not as two body-wide phrase greps (#875 round 7, Codex
# P1). Two independent greps ask "does this body mention both phrases
# anywhere", which any body DISCUSSING the mechanism satisfies — a CodeRabbit
# walkthrough of a diff that contains `grep -qiE 'actions performed'` and the
# prose "the actions-performed block states the review finished" is the live
# example, and this very file is that diff. Labelling a genuine summary an
# attestation is not a harmless misread: the probe's publication scan SKIPS
# attestations by content class, so the real summary is stepped over, and a
# correlated per-SHA success then opens the Phase 4b barrier without the
# summary-only blocker (#535) ever being inspected.
#
# The generated stanza has a shape those incidental mentions do not: a
# standalone heading line whose entire content is the words "Actions
# performed" plus non-alphanumeric decoration (`✅`, `**`, `##`), with the
# completion statement inside the SAME stanza — before the next wrapper
# comment, blockquote, heading, rule, or fence. Requiring the heading to own
# its line is what rejects a quoted `'actions performed'` inside code or a
# hyphenated mention inside prose; requiring containment is what keeps a
# "review finished" sentence far below the stanza from counting.
comment_states_review_finished() {
  printf '%s\n' "$1" | awk '
    BEGIN { in_stanza = 0; found = 0 }
    {
      line = tolower($0)
      if (in_stanza == 0) {
        if (line ~ /^[^a-z0-9]*actions performed[^a-z0-9]*$/) { in_stanza = 1 }
        next
      }
      if ($0 ~ /^[[:space:]]*(<!--|>|#|```|---[[:space:]]*$|___[[:space:]]*$)/) {
        in_stanza = 0
        next
      }
      if (line ~ /review finished/) { found = 1; exit }
    }
    END { exit (found ? 0 : 1) }
  '
}

# Strict at-or-after for the corroboration ordering below (#875 round 2):
# returns 0 iff `a >= b`. Unlike iso_on_or_after / iso_within_seconds_after
# — which fail OPEN because they guard suppressions — this one FAILS CLOSED
# on empty or unparseable input: corroboration must never be granted on a
# timestamp that cannot be read.
iso_on_or_after_strict() {
  local a=$1 b=$2
  [ -n "$a" ] && [ -n "$b" ] || return 1
  jq -en --arg a "$a" --arg b "$b" \
    '($a | fromdateiso8601) >= ($b | fromdateiso8601)' >/dev/null 2>&1
}

# #875 P1-b guard: the finished-review claim lives in a comment BODY, and a
# body carries no head identity. With a cherry-picked / old-committer-date
# new head the wallclock freshness floor (HEAD_ANCHOR layer 2) admits the
# PRIOR head's finished comment into every scan, so an unanchored
# completion-beats-notice rule would read that stale completion as terminal
# for a head CodeRabbit never reviewed — masking a GENUINE current rate
# limit. The completion claim therefore takes effect only when corroborated
# by head-anchored evidence that the claim TEMPORALLY FOLLOWS (#875 round
# 2): co-presence is not correlation — CodeRabbit can post the NEW head's
# review object while the PRIOR head's finished reply is still inside the
# freshness floor, and evidence that postdates a claim cannot be what the
# claim was reporting on. A completion statement always follows its own
# review, so the ordering conjunct is `claim at-or-after evidence`:
#
#   1. a CodeRabbit review object whose commit_id equals the current HEAD —
#      GitHub-owned and immutable, the same head-identity claim the probe's
#      primary evidence makes (anchor-free on purpose: commit_id IS head
#      identity, strictly stronger than any wallclock proxy) — AND the
#      claim's fresh_at is at-or-after the NEWEST such object's
#      submitted_at. The NEWEST, not any: on a same-head re-review round
#      the round-1 finished reply predates the round-2 object, and its
#      claim must not ride round 1's object past round 2's pending
#      publication. When an object exists its ordering is AUTHORITATIVE —
#      leg 2 is not consulted as a second chance, or a stale success from
#      the earlier run would resurrect exactly the claim leg 1 just
#      rejected. Or, only when no head-pinned object exists:
#   2. the per-SHA CodeRabbit StatusContext reading `success` on the HEAD —
#      consulted only when trust_status_context_for_clearance is true, the
#      same policy switch that governs every other status-driven clearance
#      in this script — AND the claim's fresh_at is at-or-after that
#      status' updated_at. This leg covers the #851 shape where a clean
#      incremental re-review posts no review object at all.
#
# The claim timestamp is the comment's fresh_at (max of created_at /
# updated_at), NOT created_at: CodeRabbit CREATES the actions reply when it
# acknowledges the command — before the review runs — and EDITS it to
# "finished" after the review completes (the #866 mechanics), so the
# genuine completed shape has created_at BEFORE its own review object and
# only the edit time carries when the completion was actually stated. A
# created_at ordering would reject the exact live shape #869 fixed.
#
# Uncorroborated — including a claim that PREDATES the head evidence, and a
# call with no readable claim timestamp — classify_comment falls through to
# whatever class the body would have had before #869 (rate_limit when the
# limit marker is present), keeping the #714/#489 rate-limit machinery
# intact for the prior-head shape.
#
# Residual exposure, stated plainly: CodeRabbit can flip a SPURIOUS per-SHA
# success ~1s after declining a request as rate-limited (#595/#596). For leg
# 2 to false-corroborate, that spurious flip would have to land on the NEW
# head BEFORE the stale finished reply's last edit while that reply is still
# the NEWEST bot comment in the scan — but the notice that accompanies the
# spurious flip is itself a newer bot comment carrying no finished claim, so
# it out-selects the stale comment in the newest-first scans and classifies
# rate_limit; and if CodeRabbit instead appends that notice to the stale
# reply itself, the edit that bumps fresh_at past the status also puts the
# fresh limit note in the body. Named here so a reader weakening any
# conjunct knows what stands behind it.
#
# Callers run inside command substitutions, so memoization cannot persist
# across calls — the probe instead pre-seeds CR_HEAD_REVIEW_OBJECT_PRESENT
# and CR_HEAD_REVIEW_OBJECT_SUBMITTED_AT from the head-pinned selection it
# has already made (true → only the ordering check runs, no extra read;
# false → a SUCCESSFUL probe lookup already proved zero head objects, so
# only leg 2 is consulted — the probe dies rc 3 before seeding on a failed
# fetch, so the hint never launders an outage into that proof).
#
# The reviews lookup has THREE outcomes, and they are deliberately not
# collapsed (P1 round 3 on #875): (a) lookup FAILED — corroboration is
# denied outright and leg 2 is NOT consulted, because "no object" was
# never established and on a same-SHA rerun the statuses endpoint still
# exposes the PREVIOUS run's success, which would corroborate exactly the
# stale claim the unavailable object ordering exists to reject; (b) lookup
# succeeded with NO head object — leg 2 may be consulted under its own
# ordering rule; (c) lookup succeeded with an object — the object ordering
# is authoritative. Every failure direction degrades to the pre-#869
# classification, never to a clear.
# Shared lookup for the #875 machinery: the submitted_at of the NEWEST
# CodeRabbit review object pinned to the current HEAD by commit_id.
# Returns 0 with the timestamp on stdout, 0 with EMPTY stdout when the
# lookup succeeded and confirmed no head object, and non-zero when the
# lookup itself failed (fetch error or unreadable payload) — callers must
# keep those last two apart (the three-outcome rule below).
newest_head_pinned_review_submitted_at() {
  local reviews out
  reviews=$(fetch_api_array_best_effort "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews (head completion evidence)") || return 1
  out=$(printf '%s' "$reviews" | jq -r --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    [ .[] | select(.user.login == $bot) | select(.commit_id == $sha)
      | (.submitted_at // empty) ] | max // empty' 2>/dev/null) || return 1
  printf '%s' "$out"
}

head_completion_corroborated() {
  local comment_at=${1:-} newest ctx_record ctx_state ctx_at
  # No claim timestamp means no ordering is checkable — fail closed.
  [ -n "$comment_at" ] || return 1
  case "${CR_HEAD_REVIEW_OBJECT_PRESENT:-}" in
    true)
      iso_on_or_after_strict "$comment_at" "${CR_HEAD_REVIEW_OBJECT_SUBMITTED_AT:-}"
      return
      ;;
    false) : ;;  # outcome (b) via the probe's own successful lookup
    *)
      # Outcome (a): a failed fetch or an unreadable payload means the
      # object question is UNANSWERED — deny, and do not let leg 2 stand
      # in for the ordering that could not be evaluated.
      newest=$(newest_head_pinned_review_submitted_at) || return 1
      if [ -n "$newest" ]; then
        # Outcome (c): a head-pinned object exists — its ordering is
        # authoritative.
        iso_on_or_after_strict "$comment_at" "$newest"
        return
      fi
      # Outcome (b): confirmed zero head objects — fall through to leg 2.
      ;;
  esac
  [ "$TRUST_STATUS_CONTEXT" = "true" ] || return 1
  ctx_record=$(check_status_context_record)
  ctx_state=$(printf '%s' "$ctx_record" | jq -r '.state // "missing"' 2>/dev/null) || return 1
  ctx_at=$(printf '%s' "$ctx_record" | jq -r '.updated_at // ""' 2>/dev/null) || return 1
  [ "$ctx_state" = "success" ] || return 1
  iso_on_or_after_strict "$comment_at" "$ctx_at"
}

# Classify a CodeRabbit comment body. Emits one of:
#   rate_limit | paused | in_progress | status_probe | review
#
# The optional second argument is the comment's fresh_at (max of
# created_at / updated_at) — the time the body's content was last stated.
# It feeds ONLY the #869/#875 finished-review corroboration ordering below;
# every other classification is timestamp-free, and callers that cannot
# supply it simply forgo the finished-review precedence (fail closed).
classify_comment() {
  local body=$1 comment_fresh_at=${2:-} review_finished=false
  # #869 precedence: completion evidence beats an appended limit notice, so
  # the two rate-limit checks below are bypassed for a finished-review body —
  # but only a CORROBORATED one (P1 on #875): the body carries no head
  # identity, so the completion claim counts only alongside head-anchored
  # evidence the claim temporally FOLLOWS (a review object pinned to the
  # current HEAD, or the per-SHA StatusContext success, each ordered
  # against the claim's fresh_at — see head_completion_corroborated).
  # Scoped narrowly — the paused / in-progress MARKER checks keep their
  # precedence (a durable pause or a mid-review state on the same body must
  # still win, fail-closed), and a corroborated finished body that matches
  # nothing stronger classifies `review` explicitly before the
  # narration/prose fallbacks so an appended note's wording cannot demote
  # it. An UNCORROBORATED finished body — no head evidence, or evidence the
  # claim predates — takes the class it would have had before #869 —
  # rate_limit when the limit marker is present — keeping the #714/#489
  # rate-limit machinery intact for the prior-head shape.
  if comment_states_review_finished "$body" && head_completion_corroborated "$comment_fresh_at"; then
    review_finished=true
  fi
  # #593: key on the stable auto-generated marker FIRST, before any prose
  # match, so a rate-limit notice is recognized regardless of CodeRabbit's
  # user-facing wording ("Rate limit exceeded" vs "Review limit reached" /
  # "Fair Usage Limits"). Fixed-string grep (-F) so the literal dots in
  # "coderabbit.ai" are not treated as regex wildcards, mirroring PAUSED_MARKER.
  if [ "$review_finished" != true ] \
     && printf '%s' "$body" | grep -Fqi "$RATE_LIMIT_MARKER"; then
    echo "rate_limit"
    return
  fi
  # Legacy prose fallback: the original notice text, retained so a notice that
  # somehow lacks the marker (or an older cached body) still classifies.
  if [ "$review_finished" != true ] \
     && echo "$body" | grep -qiE 'rate[- ]limit exceeded'; then
    echo "rate_limit"
    return
  fi
  # Auto-pause (#490 / #485): the "Reviews paused" NOTE carries a stable
  # auto-generated marker. Match the marker with a fixed-string grep so the
  # literal dots in "coderabbit.ai" are not treated as regex wildcards.
  # Checked before in_progress/review so the durable pause is never mistaken
  # for a slow review.
  if printf '%s' "$body" | grep -Fqi "$PAUSED_MARKER"; then
    echo "paused"
    return
  fi
  # Marker-first, before the prose fallbacks, mirroring the two checks above —
  # the #593 principle applied to the one state that still relied on prose.
  # The mid-review summary already names the NEW head in its commits range
  # (see IN_PROGRESS_MARKER), so classifying it as anything but in_progress
  # would let a run still underway read as a completed report. Placed BEFORE
  # the narration check on purpose: a body carrying both is mid-review first
  # and narration second, and no observed body carries both.
  if printf '%s' "$body" | grep -Fqi "$IN_PROGRESS_MARKER"; then
    echo "in_progress"
    return
  fi
  # #869: a corroborated finished-review body that carries neither a pause
  # nor a mid-review marker is terminal NOW, before the narration and prose
  # fallbacks — the appended limit note (or any future wording CodeRabbit
  # bolts onto the same reply) must not be able to demote a stated
  # completion to narration or in_progress.
  if [ "$review_finished" = true ]; then
    echo "review"
    return
  fi
  # CodeRabbit's free-form command replies, including
  # `@coderabbitai, how is the review going?`, are narration. They
  # summarize current state and may mention open threads, but they are
  # not a review on HEAD and must never clear the #136 freshness gate.
  if echo "$body" | grep -qiE 'CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits'; then
    echo "status_probe"
    return
  fi
  if echo "$body" | grep -qiE 'review in progress|currently reviewing|commits? under review'; then
    echo "in_progress"
    return
  fi
  echo "review"
}

# BEGIN coderabbit_summary_helpers
# Pure string predicates over a CodeRabbit summary body. No globals beyond the
# constants defined above, no I/O — extracted by sentinel and sourced directly
# by tests/test_coderabbit_wait_status_probe.sh, the pattern
# tests/test_audit_branch_protection.sh already uses.

# True when the body carries at least one outcome stanza AND every stanza is
# benign. TOTAL counts occurrences of the bare wrapper prefix, not a KIND
# pattern: a KIND containing angle brackets (`failure <head-changed>`) escapes
# any [^<>]-class match, and leftmost-longest matching can swallow two stanzas
# on one line into one count — either way an equality over the narrower
# pattern reads a refusing body as benign (adversarial verification on this
# change). The prefix registers every wrapper whatever its KIND spells.
# `grep -o | wc -l` counts OCCURRENCES; `grep -oc` counts LINES and is wrong
# here. The `-gt 0` guard is load-bearing, not defensive: a CodeRabbit chat
# reply carries ZERO stanzas, and without the guard the equality passes
# vacuously on exactly the two live bodies (#794, #518) that embed a full head
# SHA while being no report at all.
summary_stanzas_all_benign() {
  local total benign
  total=$(printf '%s' "$1" | grep -oiE 'auto-generated comment: ' | wc -l | tr -d ' ')
  benign=$(printf '%s' "$1" | grep -oiE "$CR_SUMMARY_BENIGN_STANZA_RE" | wc -l | tr -d ' ')
  [ "$total" -gt 0 ] && [ "$total" = "$benign" ]
}

# True when the head is the RANGE END of the summary's commits line —
# `between <prev> and <head>` — not merely a 40-hex token anywhere. Position
# matters twice over (adversarial verification on this change): the range
# START is the PREVIOUSLY-reviewed head, so a force-push back to it would
# read a later round's summary as this head's; and a "Review failed" body
# names the abandoned NEW head in refusal prose ("changed during the review
# from X to Y"), which a position-blind token match accepts. The boundary
# class keeps a longer digest containing the head from matching.
summary_names_head() {
  printf '%s' "$1" | grep -qiE "between [0-9a-f]{40} and $2([^0-9a-fA-F]|\$)"
}

# True when the body carries a `Potential issue` / ⚠️ blocking marker OUTSIDE
# the pre-merge check table. awk with fixed-string index() rather than a sed
# range so the delimiters carry zero regex exposure. The strip runs only when
# the START delimiter precedes the END: with only presence checked, an END
# rendered before a START would latch the suppressor at START and quietly
# drop everything to EOF — including a real marker. Single definition, used
# by both probe verdict sites AND the polling summary-marker gate so the
# heuristic cannot drift between them.
summary_blocking_marker_present() {
  local body=$1 scan=$1 s_line e_line
  s_line=$(printf '%s\n' "$body" | grep -nF "$CR_PRE_MERGE_BLOCK_START" | head -1 | cut -d: -f1)
  e_line=$(printf '%s\n' "$body" | grep -nF "$CR_PRE_MERGE_BLOCK_END" | head -1 | cut -d: -f1)
  if [ -n "$s_line" ] && [ -n "$e_line" ] && [ "$s_line" -lt "$e_line" ]; then
    scan=$(printf '%s' "$body" | awk \
      -v s="$CR_PRE_MERGE_BLOCK_START" -v e="$CR_PRE_MERGE_BLOCK_END" \
      'index($0,s){k=1} !k; index($0,e){k=0}')
  fi
  printf '%s' "$scan" | grep -qiE 'Potential issue|⚠️'
}
# END coderabbit_summary_helpers

# Scan the PR-level `issues/{pr}/comments` endpoint for the latest
# CodeRabbit comment on or after HEAD_ANCHOR. CodeRabbit edits its
# summary comment in place, so freshness is max(created_at, updated_at)
# rather than created_at alone. Emits JSON to stdout.
# Empty object {} if nothing qualifying yet.
#
# Only the issues endpoint is the terminal-state source. CodeRabbit's
# PR-level summary/status comments (walkthrough, "No actionable
# comments generated", rate-limit WARNING, in-progress markers) all
# land here. Inline `pulls/{pr}/comments` are per-line findings that
# CodeRabbit can emit BEFORE the PR-level summary lands during a
# single review cycle — treating an inline comment as terminal state
# could cause a "cleared"/"findings" exit while the bot is still
# writing more findings or still mid-walkthrough. See #140 round-3
# Codex finding (P1, line 285). Inline findings are instead scanned
# separately by count_potential_issues() only after this function
# reports a PR-level terminal state.
latest_comment_from_issue_comments() {
  local issue_comments=$1
  local latest
  latest=$(echo "$issue_comments" | jq --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" '
    def status_probe_reply:
      ((.body // "") | test("CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits"; "i"));
    [ .[]
      | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(.fresh_at >= $after)
      | select(status_probe_reply | not)
    ]
    | sort_by(.fresh_at)
    | last // null
  ')

  if [ "$latest" = "null" ]; then
    echo '{}'
    return
  fi
  echo "$latest" | jq '{id, created_at, updated_at, fresh_at, endpoint: "issues", body}'
}

scan_latest_comment() {
  local issue_comments
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments")
  latest_comment_from_issue_comments "$issue_comments"
}

scan_latest_comment_best_effort() {
  local issue_comments
  issue_comments=$(fetch_api_array_best_effort "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") || {
    echo '{}'
    return 0
  }
  latest_comment_from_issue_comments "$issue_comments"
}

# Count unaddressed "Potential issue" / ⚠️ markers in the pulls inline
# comment list, scoped to the LATEST CodeRabbit review on the current
# HEAD. The naive "all bot comments after HEAD_ANCHOR" shape would keep
# stale findings from an earlier review round (same HEAD, pre-retry) in
# the count forever, so a PR could stay permanently in the `findings`
# state even after the next review comes back clean. Mirror the latest-
# review-scoping pattern codex-review-request.sh uses via
# `pull_request_review_id`. See propagation-round Codex finding (P1)
# on device-platform-reporting#51.
#
# CodeRabbit may later reply to a finding thread with its hidden
# `review_comment_addressed` marker after an agent fixes/rebuts the
# finding. Treat that bot-authored marker as authoritative for this
# helper's advisory gate; ordinary human/agent replies do not clear a
# finding by themselves.
# Id of the latest CodeRabbit review object pinned to the current HEAD, or
# empty. Pin the selection to the current HEAD commit (`commit_id ==
# HEAD_SHA`), not just freshness (`submitted_at >= HEAD_ANCHOR`). A review
# submitted after the anchor but referencing an intermediate commit (e.g. a
# rapid push sequence where CodeRabbit reviewed an earlier SHA) must not be
# chosen as the HEAD review. Mirror the HEAD-pinning in
# scripts/codex-review-check.sh (commit_id == $sha).
#
# Factored out of count_potential_issues (#814) so the probe-mode evidence
# check below reuses this selection rather than adding a second copy of it —
# scripts/ci/check_workflow_parsers exists to police exactly that.
latest_head_pinned_review() {
  local reviews
  # Explicit propagation, not errexit. fetch_api_array's `die 3` exits only
  # its own command-substitution subshell; this function would otherwise carry
  # on with an empty $reviews and return 0 from the jq below, turning a failed
  # API read into a confident "no review on this head". Whether errexit fires
  # depends on the caller's context, so it cannot be relied on — check here.
  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews") || return 3
  echo "$reviews" | jq -c --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" --arg head_sha "$HEAD_SHA" '
    [ .[]
      | select(.user.login == $bot)
      | select(.submitted_at >= $after)
      | select(.commit_id == $head_sha)
    ]
    | sort_by(.submitted_at) | last
    | if . == null then empty else {id, submitted_at} end
  '
}

latest_head_pinned_review_id() {
  latest_head_pinned_review | jq -r '.id // empty'
}

count_potential_issues() {
  local pulls_comments latest_review_id
  latest_review_id=$(latest_head_pinned_review_id)

  if [ -z "$latest_review_id" ] || [ "$latest_review_id" = "null" ]; then
    echo "0"
    return
  fi

  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments")
  echo "$pulls_comments" | jq \
    --arg bot "$BOT_LOGIN" \
    --argjson review_id "$latest_review_id" '
    [ .[]
      | select(.user.login == $bot)
      | select(.in_reply_to_id != null)
      | select((.body // "") | test("review_comment_addressed"; "i"))
      | .in_reply_to_id
    ] as $addressed_root_ids
    | [ .[]
      | select(.user.login == $bot)
      | select(.pull_request_review_id == $review_id)
      | select(.in_reply_to_id == null)
      | select((.body // "") | test("Potential issue|⚠️"; "i"))
      | select(.id as $id | ($addressed_root_ids | index($id)) == null)
    ] | length
  '
}

# Count unaddressed inline findings on HEAD whose coderabbit_tier_of tier is
# in the resolved required set (#577). Tier-aware sibling of
# count_potential_issues: SAME latest-review-on-HEAD + review_comment_addressed
# scoping, but stage 1 (jq) emits the candidate finding BODIES and stage 2
# (bash) classifies each with the shared coderabbit_tier_of and keeps only
# required-tier ones — reusing the classifier rather than re-implementing its
# heuristic in jq. Additive/advisory only: the return value populates the
# JSON's blocking_tier_unresolved and NEVER feeds an exit code. Guarded by
# FEEDBACK_POLICY_PRESENT at the single call site, so it never runs (and the
# lib functions are never referenced) when the block is absent.
count_blocking_tier_issues() {
  local reviews pulls_comments latest_review_id candidates cand_count blocking body tier i
  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")
  latest_review_id=$(echo "$reviews" | jq --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" --arg head_sha "$HEAD_SHA" '
    [ .[]
      | select(.user.login == $bot)
      | select(.submitted_at >= $after)
      | select(.commit_id == $head_sha)
    ]
    | sort_by(.submitted_at) | last
    | if . == null then null else .id end
  ')

  if [ -z "$latest_review_id" ] || [ "$latest_review_id" = "null" ]; then
    echo "0"
    return
  fi

  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments")
  # Stage 1: same addressed-root exclusion + latest-review scoping as
  # count_potential_issues, but emit each candidate's body (NOT a count) so
  # stage 2 can tier-classify. We keep the `Potential issue|⚠️` prefilter OFF
  # here on purpose: coderabbit_tier_of also grades 🧹 Nitpick / Refactor
  # findings, which a required nitpick/p2 tier must be able to catch.
  candidates=$(echo "$pulls_comments" | jq -c \
    --arg bot "$BOT_LOGIN" \
    --argjson review_id "$latest_review_id" '
    [ .[]
      | select(.user.login == $bot)
      | select(.in_reply_to_id != null)
      | select((.body // "") | test("review_comment_addressed"; "i"))
      | .in_reply_to_id
    ] as $addressed_root_ids
    | [ .[]
      | select(.user.login == $bot)
      | select(.pull_request_review_id == $review_id)
      | select(.in_reply_to_id == null)
      | select(.id as $id | ($addressed_root_ids | index($id)) == null)
      | (.body // "")
    ]
  ')

  blocking=0
  cand_count=$(echo "$candidates" | jq 'length')
  i=0
  while [ "$i" -lt "$cand_count" ]; do
    body=$(echo "$candidates" | jq -r ".[$i]")
    tier=$(coderabbit_tier_of "$body")
    if crw_tier_is_required "$tier"; then
      blocking=$((blocking + 1))
    fi
    i=$((i + 1))
  done
  echo "$blocking"
}

# Returns 0 (true) if the latest PR-level CodeRabbit SUMMARY comment body
# carries a `Potential issue` / ⚠️ marker, else 1.
#
# count_potential_issues() scans only INLINE `pulls/{pr}/comments`. When
# CodeRabbit surfaces a finding solely in its PR-level summary body
# (issues/{pr}/comments) while the inline count is zero, the findings gate
# would otherwise wrongly clear. This OR-side check closes that gap (#535).
# Mirrors latest_comment_from_issue_comments: filter to the bot login,
# newest comment on/after the HEAD anchor (max of created_at/updated_at,
# since CodeRabbit edits the summary in place).
summary_body_has_potential_issue_marker() {
  local issue_comments latest_body
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments")
  # Mirror latest_comment_from_issue_comments: exclude status-probe narration
  # replies so a newer probe comment doesn't mask an earlier real summary that
  # contains a "Potential issue" marker (false-clear of the #535 gate).
  latest_body=$(echo "$issue_comments" | jq -r --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" '
    def status_probe_reply:
      ((.body // "") | test("CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits"; "i"));
    [ .[]
      | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(.fresh_at >= $after)
      | select(status_probe_reply | not)
    ]
    | sort_by(.fresh_at)
    | last
    | (.body // "")
  ')
  # #875 rounds 5–6: a finished ACTIONS reply can be the newest bot comment
  # — posted after, or edited after, the real summary — and it structurally
  # carries no findings, so inspecting IT would clear past a blocking
  # marker carried solely by the genuine summary. The reply attests
  # terminality, never marker material: when the newest body is a finished
  # attestation, re-select through polling_head_summary_body — by MARKER
  # IDENTITY with the head-anchored at-or-after floor — never by
  # newest-first position or by the wallclock anchor alone (round 6: the
  # bare-anchor re-selection could pick a PRIOR head summary that slipped
  # inside the freshness window). An empty selection means there is no
  # summary-level material to inspect; both live callers pre-gate that
  # state (the poll loop keeps polling, the probe-wait boundary stays an
  # advisory timeout), so this branch decides only the one-poll-cycle race
  # where a fresh attestation lands between the caller's scan and this
  # fetch. The inline count (this helper's OR-sibling) still owns inline
  # findings.
  if comment_states_review_finished "$latest_body"; then
    latest_body=$(polling_head_summary_body || true)
  fi
  # Through the shared helper, not a raw grep: the pre-merge check table's
  # hygiene `⚠️ Warning` rows are not findings, and the probe already reads
  # them that way — a raw grep here made the SAME body a `findings` verdict in
  # polling and a `reported` one in probe, so agent-review and the Phase 4b
  # barrier disagreed about one head (adversarial verification on #851).
  summary_blocking_marker_present "$latest_body"
}

# #875 round 6: the genuine head-anchored summarize-marker summary body for
# POLLING verdicts, or empty when none qualifies. Selection is by marker
# identity (the summarize marker at byte 0 — CodeRabbit keeps exactly one
# such comment per PR and edits it in place) AND by a head-anchored
# at-or-after ordering floor: the NEWEST head-pinned review object's
# submitted_at when one exists — a summary last refreshed BEFORE that
# object was written for a PRIOR head or run, however recently the
# wallclock freshness window admitted it — else HEAD_ANCHOR, the polling
# mode's ordinary freshness floor. Every lookup failure fails closed to
# empty (no verdict material; the caller keeps polling or stays on the
# advisory timeout), never to a stale selection.
#
# Round 7 (Codex P1): marker identity and the ordering floor establish WHICH
# comment, never that it is a VERDICT. CodeRabbit keeps one summarize comment
# per PR and edits it in place, so the same marker rides the mid-review body
# (IN_PROGRESS_MARKER), a paused or rate-limited state appended to it, and a
# refusal stanza — each of which is a summary comment refreshed after the head
# review object while carrying no findings BECAUSE the review has not finished.
# Selecting one of those as the verdict body clears rc 0 ahead of the real
# summary, which is the failure this helper exists to prevent, merely reached
# by a different door. So each candidate is classified the way the probe's
# publication scan classifies its rows — only `review` is verdict material —
# and a finished attestation is excluded for the round-5 shadowing reason even
# though it, too, classifies `review`.
polling_head_summary_body() {
  local object_at floor issue_comments rows row body fresh class
  object_at=$(newest_head_pinned_review_submitted_at) || return 1
  floor=${object_at:-$HEAD_ANCHOR}
  issue_comments=$(fetch_api_array_best_effort "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments (head summary selection)") || return 1
  rows=$(printf '%s' "$issue_comments" | jq -r --arg bot "$BOT_LOGIN" --arg floor "$floor" --arg m "$SUMMARY_MARKER" '
    [ .[]
      | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(.fresh_at >= $floor)
      | select((.body // "") | startswith($m)) ]
    | sort_by(.fresh_at)
    | reverse
    | .[]
    | @base64
  ' 2>/dev/null) || return 1
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    body=$(printf '%s' "$row" | base64 --decode | jq -r '.body // ""') || continue
    fresh=$(printf '%s' "$row" | base64 --decode | jq -r '.fresh_at // empty') || continue
    class=$(classify_comment "$body" "$fresh")
    [ "$class" = "review" ] || continue
    if comment_states_review_finished "$body"; then
      continue
    fi
    printf '%s' "$body"
    return 0
  done <<EOF
$rows
EOF
  return 0
}

# SHA-scoped variant of count_potential_issues, used by the StatusContext
# fast-path. Counts CodeRabbit inline findings whose `commit_id` (the SHA
# GitHub considers the comment currently anchored to, after rebases / new
# commits) equals the given SHA and whose creation time is not older than
# HEAD_IDENTITY_ANCHOR.
#
# Why this is needed (codex CHANGES_REQUESTED on PR #224 round 2 +
# CodeRabbit ⚠️ Major @ line 581): the freshness-anchored count_potential_
# issues filters reviews with `submitted_at >= HEAD_ANCHOR`. Once the same
# unchanged HEAD sits longer than `coderabbit.wallclock_freshness_window_
# seconds` (default 1800s / 30 min), HEAD_ANCHOR advances past the prior
# CodeRabbit review's submitted_at, latest_review_id becomes null, and the
# helper returns 0 — false-clearing the fast-path even while the same SHA
# still has unresolved Potential issue/⚠️ inline findings. The fast-path is
# the only caller that has authoritative per-SHA scope (from the StatusContext
# check) and should leverage it.
#
# Why still keep a non-wallclock freshness floor: GitHub can preserve or
# remap inline review comments across a rebase/force-push so an old comment
# appears to have `commit_id == HEAD_SHA`. HEAD_IDENTITY_ANCHOR is captured
# before the moving wallclock floor is applied, so stale pre-head inline
# comments are ignored without losing genuine old-but-still-current findings
# on an unchanged head.
#
# Filter shape: root inline review comments where the bot author posted
# a comment whose `commit_id == HEAD_SHA` (i.e., GitHub still considers
# it applicable to HEAD after any rebases) and whose body contains a
# `Potential issue` / `⚠️` marker, excluding roots CodeRabbit itself
# later marked with `review_comment_addressed`. Resolved-thread state is
# not consulted directly; the explicit bot marker is the narrow signal
# that a current-head finding has been addressed without relying on
# GitHub conversation-resolution state.
count_potential_issues_for_sha() {
  local sha=$1
  local pulls_comments
  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments")
  echo "$pulls_comments" | jq \
    --arg bot "$BOT_LOGIN" \
    --arg sha "$sha" \
    --arg after "$HEAD_IDENTITY_ANCHOR" '
    [ .[]
      | select(.user.login == $bot)
      | select(.in_reply_to_id != null)
      | select((.body // "") | test("review_comment_addressed"; "i"))
      | .in_reply_to_id
    ] as $addressed_root_ids
    | [ .[]
      | select(.user.login == $bot)
      | select(.commit_id == $sha)
      | select((.created_at // "") >= $after)
      | select(.in_reply_to_id == null)
      | select((.body // "") | test("Potential issue|⚠️"; "i"))
      | select(.id as $id | ($addressed_root_ids | index($id)) == null)
    ] | length
  '
}

iso_on_or_after() {
  local lhs=$1 rhs=$2 rc
  if [ -z "$lhs" ] || [ "$lhs" = "null" ] || [ -z "$rhs" ] || [ "$rhs" = "null" ]; then
    return 0
  fi

  jq -en --arg lhs "$lhs" --arg rhs "$rhs" \
    '($lhs | fromdateiso8601) >= ($rhs | fromdateiso8601)' >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 0 ;;
  esac
}

# #596: return 0 (true) when `status` landed at most `grace` seconds after
# `comment` — i.e. status <= comment + grace. Used to recognize CodeRabbit's
# near-simultaneous rate-limit StatusContext flip (a `status` within `grace` of
# the notice) versus a genuinely later re-review (`status` well after it). Fails
# OPEN (true → suppress the fast-path) on unparseable input, matching the
# conservative posture of iso_on_or_after.
iso_within_seconds_after() {
  local comment=$1 status=$2 grace=$3 rc
  if [ -z "$comment" ] || [ "$comment" = "null" ] || [ -z "$status" ] || [ "$status" = "null" ]; then
    return 0
  fi
  jq -en --arg c "$comment" --arg s "$status" --argjson g "$grace" \
    '($s | fromdateiso8601) <= ($c | fromdateiso8601) + $g' >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 0 ;;
  esac
}

# #727: how many seconds of a CodeRabbit rate-limit window have ALREADY
# elapsed between when CodeRabbit posted the notice (fresh_at = max of
# created_at/updated_at) and now. The published "try again in N" window is
# measured from the notice's post time, NOT from when this helper first
# observes it — auto-merge-on-approval routinely starts this wait minutes
# after the notice landed (the reviewer approval that ARMS the job can post
# long after CodeRabbit rate-limited), so the sleep should cover only the
# window that REMAINS, not a fresh full copy of it. Emits max(0, now -
# fresh_at) on stdout. Fails SAFE to 0 (⇒ the caller sleeps the full window,
# the pre-#727 behavior) on empty/unparseable input, so a bad timestamp can
# never SHORTEN a genuine rate-limit wait — only a parseable, already-elapsed
# window trims the sleep.
rate_limit_window_elapsed_seconds() {
  local fresh_at=$1 now_epoch=$2 elapsed
  if [ -z "$fresh_at" ] || [ "$fresh_at" = "null" ]; then
    echo 0
    return 0
  fi
  elapsed=$(jq -rn --arg t "$fresh_at" --argjson now "$now_epoch" \
    '($now - ($t | fromdateiso8601)) | floor' 2>/dev/null) || { echo 0; return 0; }
  case "$elapsed" in
    ''|*[!0-9-]*) echo 0; return 0 ;;
  esac
  if [ "$elapsed" -lt 0 ]; then elapsed=0; fi
  echo "$elapsed"
}

status_context_fast_path_blocked_by_comment() {
  local status_created_at=$1
  local latest class comment_id comment_created_at comment_fresh_at comment_body
  latest=$(scan_latest_comment)
  if [ "$(echo "$latest" | jq 'length')" = "0" ]; then
    return 1
  fi

  # fresh_at rides along for the #869/#875 finished-review corroboration
  # ordering; the rate_limit/paused/in_progress arms below are unaffected.
  class=$(classify_comment "$(echo "$latest" | jq -r '.body')" \
    "$(echo "$latest" | jq -r '.fresh_at // .updated_at // .created_at // empty')")
  case "$class" in
    rate_limit|paused|in_progress)
      # #490: `paused` joins rate_limit/in_progress here. An auto-pause NOTE
      # is durable and, like the rate-limit notice, does not reference HEAD;
      # a pause posted at/after a stale StatusContext success must suppress
      # the fast-path so the wait keeps polling (and re-invokes `resume`)
      # instead of false-clearing over a paused review.
      comment_id=$(echo "$latest" | jq -r '.id')
      comment_created_at=$(echo "$latest" | jq -r '.created_at // .fresh_at // .updated_at')
      comment_fresh_at=$(echo "$latest" | jq -r '.fresh_at // .updated_at // .created_at')
      comment_body=$(echo "$latest" | jq -r '.body')
      if printf '%s' "$comment_body" | grep -Fq "$HEAD_SHA"; then
        # #596: a HEAD-referencing rate_limit/paused/in_progress notice means
        # CodeRabbit has not (yet) completed a review of this HEAD. CodeRabbit
        # nonetheless flips its commit StatusContext to success while
        # rate-limited, ~1s AFTER posting the notice, so the previous
        # `iso_on_or_after comment_fresh_at status_created_at` gate treated that
        # 1s-newer success as authoritative and false-cleared (the #595 dogfood:
        # notice @07:49:36, status success @07:49:37, zero review). Distinguish
        # by latency rather than raw ordering: SUPPRESS a success that landed
        # within an effective grace window of the notice; TRUST a success that
        # postdates it by more (a genuine later re-review, which per #221 can be
        # silent, i.e. flip the status with no new summary comment).
        #
        # The effective grace is the base near-simultaneous-flip window
        # (STATUS_SUCCESS_GRACE_SECONDS), WIDENED to CodeRabbit's own published
        # wait window when the notice carries one. A rate-limit notice ("Next
        # review available in: N minutes") promises no review before
        # comment_created + N, so a success anywhere inside that window cannot be
        # a completed review no matter how far past the base grace it lands
        # (#599 Codex P2: with a fixed 120s grace, a success at 121s but still
        # mid-13-minute-window would false-clear). paused/in_progress notices
        # carry no parseable window, so they keep the base grace. The
        # RATE_LIMIT_BUFFER_SECONDS margin mirrors the retry-sleep path.
        local effective_grace=$STATUS_SUCCESS_GRACE_SECONDS
        local published_window
        published_window=$(parse_rate_limit_window "$comment_body" || echo "")
        if [ -n "$published_window" ]; then
          local windowed=$((published_window + RATE_LIMIT_BUFFER_SECONDS))
          if [ "$windowed" -gt "$effective_grace" ]; then
            effective_grace=$windowed
          fi
        fi
        if iso_within_seconds_after "$comment_fresh_at" "$status_created_at" "$effective_grace"; then
          log "StatusContext success ignored because latest CodeRabbit comment id=$comment_id class=$class references current HEAD $HEAD_SHA and the success (status_created=$status_created_at) is within the ${effective_grace}s window after the notice (fresh_at=$comment_fresh_at) — CodeRabbit has not completed a review of this HEAD (near-simultaneous rate-limit status flip, or a success still inside the published wait window)"
          return 0
        fi
        log "StatusContext success remains authoritative: it postdates the HEAD-referencing $class notice id=$comment_id ($HEAD_SHA) by more than ${effective_grace}s (fresh_at=$comment_fresh_at, status_created=$status_created_at) — a genuine later re-review of the current HEAD"
        return 1
      fi
      # #446: a rate_limit/paused/in_progress comment POSTED (created) at/after
      # the StatusContext flipped to success means CodeRabbit re-entered a
      # rate-limited / paused / in-progress state — the fast-path must not
      # declare clearance over it even though the notice does not reference
      # HEAD. Compare CREATED_AT, not fresh_at: an OLD comment from a prior
      # round that merely got edited after the success is stale and must NOT
      # suppress (the 263caf3 "Bug 6" regression — an unscoped non-HEAD
      # comment created before the success still clears). Only a comment
      # actually posted at/after the success suppresses.
      if iso_on_or_after "$comment_created_at" "$status_created_at"; then
        log "StatusContext success suppressed because latest CodeRabbit comment id=$comment_id class=$class created=$comment_created_at is at/after status_created=$status_created_at (no HEAD $HEAD_SHA reference, but a post-success rate-limit/paused/in-progress notice) — keep polling"
        return 0
      fi
      log "StatusContext success remains authoritative because latest CodeRabbit comment id=$comment_id class=$class does not reference current HEAD $HEAD_SHA and was created=$comment_created_at before status_created=$status_created_at"
      return 1
      ;;
    review)
      # #875 round 7 (Codex P1): the StatusContext fast path is a THIRD route
      # to rc 0, and #869 opened it. A corroborated finished attestation now
      # classifies `review`, so it stopped suppressing this path — and
      # emit_status_context_verdict scans INLINE findings only, never the
      # PR-level summary. On a repo with trust_status_context_for_clearance
      # enabled (mergepath's own setting) an attestation plus a per-SHA
      # success would therefore clear before the summary that can carry the
      # only blocking marker (#535) publishes, which is exactly what the poll
      # arm and the probe-wait boundary were taught to wait for in round 6.
      # Same rule here: an attestation with no genuine head-anchored summary
      # BLOCKS the fast path and the loop keeps polling on its ordinary
      # budget. A summary that HAS published leaves the pre-#869 behaviour
      # untouched.
      comment_body=$(echo "$latest" | jq -r '.body')
      if comment_states_review_finished "$comment_body"; then
        if [ -z "$(polling_head_summary_body || true)" ]; then
          log "StatusContext success suppressed: the newest CodeRabbit comment is a corroborated finished attestation and no genuine head-anchored summary has published — this fast path scans inline findings only, so clearing here could miss a summary-only blocker (#535); keep polling"
          return 0
        fi
      fi
      return 1
      ;;
  esac

  return 1
}

verify_reviewer_write_identity() {
  local purpose=$1
  # Identity check (#412): CodeRabbit helper comments are reviewer-token
  # writes. Fail closed BEFORE the REST mutation if the GH_TOKEN that
  # will sign the call does not resolve to the expected reviewer
  # identity. Opt-out via CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 for
  # tests only.
  #
  # r3 (#284): fail CLOSED if the helper is missing or non-executable.
  # The previous shape ANDed the opt-out and `[ -x "$CHECKER" ]` so a
  # rename / delete / chmod -x silently skipped the gate. Helper
  # presence is now a hard error inside the opt-out branch.
  if [ "${CODERABBIT_WAIT_SKIP_IDENTITY_CHECK:-0}" != "1" ]; then
    local checker="$(dirname "${BASH_SOURCE[0]}")/identity-check.sh"
    if [ ! -x "$checker" ]; then
      echo "ERROR: identity-check helper missing or non-executable: $checker" >&2
      echo "       Refusing to post $purpose comment without identity verification." >&2
      echo "       Restore the helper, or opt out via" >&2
      echo "       CODERABBIT_WAIT_SKIP_IDENTITY_CHECK=1 (dev only)." >&2
      return 1
    fi
    # Lazy token-derived expected identity (#438): no explicit identity
    # env was set at startup, so derive the expected login from the
    # token that will sign this write — constrained to
    # available_reviewers. An unconstrained derivation would make the
    # check below a tautology; the allow-list keeps it fail-closed: a
    # non-reviewer token falls back to the static default and fails
    # verification exactly as before. Derived here (write time) rather
    # than at startup so read-only runs never pay the extra API call.
    if [ -z "$EXPECTED_REVIEWER_IDENTITY" ]; then
      local token_login
      token_login=$(gh_reviewer api user --jq .login 2>/dev/null || true)
      if login_is_available_reviewer "$token_login"; then
        EXPECTED_REVIEWER_IDENTITY="$token_login"
        log "derived expected reviewer identity '$token_login' from GH_TOKEN (allow-listed in available_reviewers)"
      else
        EXPECTED_REVIEWER_IDENTITY="$(gh_default_reviewer_identity)"
        log "GH_TOKEN login '${token_login:-<unresolvable>}' is not in available_reviewers; falling back to default expected reviewer '$EXPECTED_REVIEWER_IDENTITY'"
      fi
    fi
    GH_TOKEN="$GH_TOKEN" "$checker" --expect-token-identity "$EXPECTED_REVIEWER_IDENTITY" \
      || return 1
  fi
}

post_reviewer_comment() {
  local purpose=$1
  local body=$2
  local raw
  verify_reviewer_write_identity "$purpose" || return 1
  raw=$(gh_reviewer api --method POST "repos/$REPO/issues/$PR_NUMBER/comments" \
    -f body="$body" 2>&1) || {
    log "failed to post $purpose comment: $raw"
    return 1
  }
  printf '%s\n' "$raw"
}

# #829: the re-invocation POSTs below are NON-idempotent, and the loop's
# dedupe latches (LAST_RATE_LIMIT_COMMENT_ID / LAST_PAUSED_COMMENT_ID) are
# PROCESS-LOCAL shell variables. They dedupe correctly WITHIN one run and are
# inert ACROSS concurrent runs: every process starts with an empty latch, so
# N sessions waiting on the same PR each re-nudge the same notice (observed on
# #797: 5 identical "@coderabbitai, try again." inside 22s, which drew 5
# replies — 10 comments of noise). Same defect class as #827: a non-idempotent
# write gated on state that does not attribute the action to the writer.
#
# Gate on OBSERVABLE SHARED STATE instead — an identical trigger body already
# on the PR at/after the notice means someone already nudged this window.
#
# Deliberately FAIL-OPEN: any scan error returns "not posted" so we still
# nudge. A missed nudge stalls the PR; a rare duplicate is cosmetic. This
# narrows rather than closes the race — two processes scanning simultaneously
# can still both post — but it collapses the common case from N-per-process
# to ~1. Closing it fully would need a lock GitHub does not offer.
# Codex P2 #830 (a): match ONLY comments authored by a configured reviewer
# identity. Body text alone is forgeable — on a public PR any participant can
# post the exact trigger string, and treating that as proof the helper already
# nudged would SUPPRESS the real identity-verified POST. CodeRabbit ignores
# commands from unauthorized accounts, so the window would never be
# re-invoked and the process-local latch would block a second attempt: the
# wait stalls. Fail-closed on the allow-list — an unreadable/empty
# available_reviewers yields no trusted authors, so nothing matches and we
# post (the safe direction).
#
# Codex P2 #830 (b): GitHub `created_at` has only SECOND precision, so a
# trigger and a newly-posted notice can tie. A plain `>= since` would credit
# the OLD trigger to the NEW notice, skip its nudge, and stall that window.
# Compare by (created_at, id): strictly-later timestamp, or equal timestamp
# with a higher comment id (ids increase monotonically), so a tie resolves by
# true post order.
# rc 0 = a matching trigger exists; rc 1 = confirmed absent; rc 2 = the scan
# itself FAILED. The distinction is load-bearing: a transient read failure
# collapsed into "absent" made both callers post, so one GitHub hiccup could
# produce a duplicate retry or resume — the same read-error-is-not-empty class
# the Phase 4b barrier already fixed (#842). Callers decline on rc 2.
trigger_already_posted() {  # <since-iso8601> <notice-comment-id> <exact-body>
  local since=$1
  local notice_id=$2
  local body=$3
  local comments reviewers_json
  comments=$(fetch_api_array_best_effort "repos/$REPO/issues/$PR_NUMBER/comments" \
    "re-invocation dedupe scan") || return 2
  # Trusted-author allow-list as a JSON array. `$l` is bound BEFORE the array
  # literal so the literal cannot rebind `.` out from under the lookup.
  reviewers_json=$(read_available_reviewers | jq -R . | jq -sc .) || return 2
  # Exact body OR the body as a first line: the Phase 4b barrier posts the
  # same command with a dedup marker appended on later lines (#847), and two
  # recovery paths that cannot read each other's writes both post against one
  # pause note. Prefix-with-newline keeps the match anchored to the whole
  # command line, so "@bot resume" never matches "@bot resumed something".
  printf '%s' "$comments" | jq -e \
    --arg b "$body" --arg since "$since" --argjson nid "${notice_id:-0}" \
    --argjson revs "$reviewers_json" \
    'any(.[]?;
       ((.body // "") == $b or ((.body // "") | startswith($b + "\n")))
       and ((.user.login // "") as $l | $revs | index($l) != null)
       and ( (.created_at // "") > $since
             or ((.created_at // "") == $since and ((.id // 0) > $nid)) ))' \
    >/dev/null 2>&1
}

post_retry_trigger() {  # [<notice-fresh-at> <notice-comment-id>]
  # Strip the `[bot]` suffix that GitHub REST uses for App logins —
  # @-mentions address the user-facing handle (`@coderabbitai`), not
  # the API login (`coderabbitai[bot]`). Using the configured
  # BOT_LOGIN here instead of a hardcoded string means a repo that
  # overrides `coderabbit.bot_login` (e.g., to point at a fork or a
  # differently-named review bot) gets consistent polling and
  # triggering identities. See #140 round-3 Codex finding (P2, line 320).
  local since=${1:-}
  local notice_id=${2:-0}
  local mention="@${BOT_LOGIN%\[bot\]}"
  local body="${mention}, try again."
  local dedupe_rc=0
  [ -n "$since" ] && { trigger_already_posted "$since" "$notice_id" "$body" || dedupe_rc=$?; }
  if [ -n "$since" ] && [ "$dedupe_rc" = 0 ]; then
    log "retry trigger already present for this rate-limit window (after notice $notice_id @ $since) — skipping duplicate POST (#829)"
    return 0
  fi
  if [ "$dedupe_rc" = 2 ]; then
    log "dedupe scan failed — declining to post the retry trigger rather than risking a duplicate; the poll loop retries"
    return 0
  fi
  log "posting retry trigger comment to PR #$PR_NUMBER as $mention"
  post_reviewer_comment "retry-trigger" "$body" >/dev/null \
    || die 3 "failed to post retry-trigger comment"
}

# Re-invoke CodeRabbit out of an auto-pause (#490). MUST be `resume`, not a
# one-shot `review`: the auto-pause is durable and a single `review`
# re-pauses after the next fix-up push, whereas `resume` re-enables
# incremental auto-review. Same BOT_LOGIN-derived mention as the retry
# trigger so a bot_login override stays consistent.
post_resume_trigger() {
  # #829: LAST_PAUSED_COMMENT_ID is process-local exactly like the rate-limit
  # latch, so the auto-pause path carries the same cross-run duplication bug.
  # Same shared-state guard, same fail-open posture — see trigger_already_posted.
  local since=${1:-}
  local notice_id=${2:-0}
  local mention="@${BOT_LOGIN%\[bot\]}"
  local body="${mention} resume"
  local dedupe_rc=0
  [ -n "$since" ] && { trigger_already_posted "$since" "$notice_id" "$body" || dedupe_rc=$?; }
  if [ -n "$since" ] && [ "$dedupe_rc" = 0 ]; then
    log "resume trigger already present for this pause NOTE (after notice $notice_id @ $since) — skipping duplicate POST (#829)"
    return 0
  fi
  if [ "$dedupe_rc" = 2 ]; then
    log "dedupe scan failed — declining to post the resume rather than risking a duplicate; the poll loop retries"
    return 0
  fi
  log "posting auto-pause resume trigger comment to PR #$PR_NUMBER as $mention"
  post_reviewer_comment "resume-trigger" "$body" >/dev/null \
    || die 3 "failed to post resume-trigger comment"
}

find_status_probe_reply() {
  local after=$1
  local issue_comments
  issue_comments=$(fetch_api_array_best_effort "repos/$REPO/issues/$PR_NUMBER/comments" "status probe reply issue comments") || return 1

  echo "$issue_comments" | jq --arg bot "$BOT_LOGIN" --arg after "$after" '
    def status_probe_reply:
      ((.body // "") | test("CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits"; "i"));
    [ .[]
      | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(.fresh_at >= $after)
      | select(status_probe_reply)
    ]
    | sort_by(.fresh_at)
    | last // null
  '
}

emit_terminal_review_after_probe_if_present() {
  local latest class potential_issues review_json vbody=""
  latest=$(scan_latest_comment_best_effort)
  if [ "$(echo "$latest" | jq 'length')" = "0" ]; then
    return 0
  fi

  class=$(classify_comment "$(echo "$latest" | jq -r '.body')" \
    "$(echo "$latest" | jq -r '.fresh_at // .updated_at // .created_at // empty')")
  case "$class" in
    review)
      # #875 round 6: the same attestation rule as the poll loop. At the
      # probe-wait boundary a finished attestation without the genuine
      # head-anchored summary keeps the ADVISORY timeout (rc 4) instead of
      # clearing on a verdict body that has not published.
      if comment_states_review_finished "$(echo "$latest" | jq -r '.body')"; then
        vbody=$(polling_head_summary_body || true)
        if [ -z "$vbody" ]; then
          log "finished attestation without a genuine head-anchored summary at the probe-wait boundary — continuing to advisory timeout"
          return 0
        fi
      fi
      potential_issues=$(count_potential_issues)
      review_json=$(echo "$latest" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
      # #535: also honor a PR-level summary-body marker (the inline count
      # scans only pulls/{pr}/comments) so the probe-wait clearance path
      # cannot false-clear over a summary-only finding either. On the
      # attestation path the marker is read from the SELECTED summary.
      if [ "$potential_issues" -gt 0 ]; then
        log "CodeRabbit review landed during status-probe wait with $potential_issues Potential issue/⚠️ marker(s) — emitting findings (exit 2)"
        emit_json_and_exit "findings" 2 "$review_json" "$potential_issues"
      elif { [ -n "$vbody" ] && summary_blocking_marker_present "$vbody"; } \
        || { [ -z "$vbody" ] && summary_body_has_potential_issue_marker; }; then
        log "CodeRabbit review landed during status-probe wait with 0 inline markers but a Potential issue/⚠️ marker in the PR-level summary body — emitting findings (exit 2)"
        emit_json_and_exit "findings" 2 "$review_json" "$potential_issues"
      fi
      log "CodeRabbit review landed during status-probe wait with no high-severity markers — emitting cleared (exit 0)"
      emit_json_and_exit "cleared" 0 "$review_json" 0
      ;;
    *)
      log "latest CodeRabbit comment after status-probe wait is class=$class; continuing timeout"
      ;;
  esac
}

status_probe_no_reply_json() {
  local posted=$1
  local comment_id=$2
  local waited=$3
  jq -nc \
    --argjson posted "$posted" \
    --argjson comment_id "$comment_id" \
    --argjson waited "$waited" '
    {
      enabled: true,
      posted: $posted,
      reply_present: false,
      reply: null,
      waited_seconds: $waited
    } + (if $posted then {comment_id: $comment_id} else {} end)
  '
}

run_status_probe_once() {
  local mention body posted_json probe_comment_id probe_anchor probe_start probe_deadline
  local now remaining sleep_for reply waited

  [ "$STATUS_PROBE_RAN" = "false" ] || return 0
  STATUS_PROBE_RAN=true

  if [ "$STATUS_PROBE_ENABLED" != "true" ]; then
    log "status probe disabled — timeout JSON will include status_probe.posted=false"
    STATUS_PROBE_JSON=$(jq -nc '{enabled:false, posted:false, reply_present:false, reply:null, waited_seconds:0}')
    return 0
  fi

  mention="@${BOT_LOGIN%\[bot\]}"
  body="${mention}, how is the review going?"
  log "posting CodeRabbit status probe before timeout (${STATUS_PROBE_WAIT_SECONDS}s wait budget)"
  if ! posted_json=$(post_reviewer_comment "status-probe" "$body"); then
    log "status probe post failed; timeout remains advisory"
    STATUS_PROBE_JSON=$(status_probe_no_reply_json false null 0)
    return 0
  fi
  probe_comment_id=$(echo "$posted_json" | jq -r '.id // null' 2>/dev/null || echo "null")
  case "$probe_comment_id" in
    ""|null) probe_comment_id=null ;;
    *[!0-9]*) probe_comment_id=null ;;
  esac
  probe_anchor=$(echo "$posted_json" | jq -r '.created_at // empty' 2>/dev/null || true)
  if [ -z "$probe_anchor" ]; then
    probe_anchor=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi

  probe_start=$(date +%s)
  probe_deadline=$((probe_start + STATUS_PROBE_WAIT_SECONDS))
  reply='null'

  while :; do
    if ! reply=$(find_status_probe_reply "$probe_anchor"); then
      waited=$(( $(date +%s) - probe_start ))
      log "status probe reply poll failed; timeout remains advisory"
      STATUS_PROBE_JSON=$(status_probe_no_reply_json true "$probe_comment_id" "$waited")
      return 0
    fi
    if [ "$reply" != "null" ]; then
      break
    fi

    now=$(date +%s)
    if [ "$now" -ge "$probe_deadline" ]; then
      break
    fi

    remaining=$((probe_deadline - now))
    sleep_for=$STATUS_PROBE_POLL_INTERVAL_SECONDS
    if [ "$remaining" -lt "$sleep_for" ]; then
      sleep_for=$remaining
    fi
    [ "$sleep_for" -gt 0 ] || break
    sleep "$sleep_for"
  done

  waited=$(( $(date +%s) - probe_start ))
  if [ "$reply" != "null" ]; then
    log "CodeRabbit status probe reply received after ${waited}s: $(echo "$reply" | jq -r '(.body // "")[0:200] | gsub("[\r\n]+"; " ")')"
    STATUS_PROBE_JSON=$(echo "$reply" | jq \
      --argjson comment_id "$probe_comment_id" \
      --argjson waited "$waited" '
      {
        enabled: true,
        posted: true,
        comment_id: $comment_id,
        reply_present: true,
        reply: {
          id,
          created_at,
          updated_at,
          fresh_at,
          body_excerpt: ((.body // "")[0:500])
        },
        waited_seconds: $waited
      }
    ')
  else
    log "no CodeRabbit status probe reply within ${STATUS_PROBE_WAIT_SECONDS}s"
    STATUS_PROBE_JSON=$(status_probe_no_reply_json true "$probe_comment_id" "$waited")
  fi
}

emit_timeout() {
  local message=$1
  log "$message"
  # Once a pause has been observed, a timeout is a still-paused condition,
  # not an advisory timeout. Exit 6 (skip_reason=paused) so callers that
  # treat exit 4 as advisory (agent-review.yml) cannot merge past a PR that
  # CodeRabbit is still refusing to review. A durable same-id pause NOTE
  # never advances the resume budget to the cap, so without this latch the
  # loop would fall through to exit 4. See #490.
  if [ "${PAUSE_OBSERVED:-false}" = "true" ]; then
    log "timeout reached while CodeRabbit auto-review remains paused — reporting paused (exit 6), not advisory timeout (exit 4)"
    SKIP_REASON="paused"
    emit_json_and_exit "paused" 6 "null" 0
  fi
  run_status_probe_once
  emit_terminal_review_after_probe_if_present
  emit_json_and_exit "timeout" 4 "null" 0
}

# Emit the read-only probe verdict and exit PROBE_EXIT_CODE. `observed`
# records WHICH non-terminal surface the scan landed on, so a caller can
# tell "said nothing at all" from "rate-limited" or "paused" without
# re-reading the PR. No write, no sleep, no second scan.
probe_not_yet() {
  local observed=$1 review_json=$2
  PROBE_OBSERVED="$observed"
  log "probe: no CodeRabbit review on $HEAD_SHA yet (observed=$observed) — exiting $PROBE_EXIT_CODE without posting"
  emit_json_and_exit "no_review_yet" "$PROBE_EXIT_CODE" "$review_json" 0
}

# --- poll loop --------------------------------------------------------------

START_EPOCH=$(date +%s)
RATE_LIMIT_RETRIES=0
RESUME_RETRIES=0
LAST_RATE_LIMIT_COMMENT_ID=""
LAST_PAUSED_COMMENT_ID=""
# Latched the first time a "Reviews paused" NOTE is seen. Once a pause has
# been OBSERVED, the timeout path must NOT fall back to the advisory exit 4
# (which agent-review.yml treats as advisory and merges past) — a PR must
# never merge while CodeRabbit is still paused. When CodeRabbit leaves the
# SAME durable pause NOTE (unchanged comment id), the resume retry budget
# never advances and the loop would otherwise time out exit 4; with this
# latched, emit_timeout exits 6 (skip_reason=paused) instead. See #490.
PAUSE_OBSERVED=false
# Skip reason surfaced in the JSON. Empty for the normal review/timeout/
# rate-limit paths; set to paused / non-base-branch / draft on a #490 skip.
SKIP_REASON=""
STATUS_PROBE_RAN=false
# --probe bookkeeping (#814). PROBE_JSON stays null outside probe mode — the
# same additive posture blocking_tier_unresolved takes when it does not apply.
PROBE_OBSERVED=""
PROBE_JSON=null
# Per-SHA StatusContext state and refresh time sampled by the probe's rc-7
# review-object branch (#869 / P1 on #875); empty (→ null in the JSON)
# everywhere else, including every polling run and every trust-opted-out
# policy. The timestamp exists so the barrier can require the success to be
# at-or-after the review object it corroborates (#875 round 2 — a same-SHA
# rerun exposes the previous run's success while the new summary is
# pending).
PROBE_CONTEXT_STATE=""
PROBE_CONTEXT_UPDATED_AT=""
# #875 corroboration hints for head_completion_corroborated: empty PRESENT
# means unknown (the helper fetches for itself); the probe sets true/false
# plus the newest head-pinned object's submitted_at from the selection it
# has already made.
CR_HEAD_REVIEW_OBJECT_PRESENT=""
CR_HEAD_REVIEW_OBJECT_SUBMITTED_AT=""
# #489 rate-limit→Codex failover state. CODEX_FAILOVER_FIRED latches after the
# first attempt so retries within a run don't re-post. CODEX_FAILOVER_REQUESTED
# records whether Codex was actually engaged (the helper posted, or found an
# existing trigger on HEAD) — surfaced in the JSON so the caller can downgrade a
# rate_limit_stalled (exit 5) from a hard human-alert to a non-blocking note.
CODEX_FAILOVER_FIRED=false
CODEX_FAILOVER_REQUESTED=false
STATUS_PROBE_JSON=$(jq -nc \
  --argjson enabled "$([ "$STATUS_PROBE_ENABLED" = "true" ] && echo true || echo false)" \
  '{enabled:$enabled, posted:false, reply_present:false, reply:null, waited_seconds:0}')

emit_json_and_exit() {
  local status=$1 exit_code=$2 review_json=$3 potential_issues=$4
  local now_epoch waited skip_reason_json
  now_epoch=$(date +%s)
  waited=$((now_epoch - START_EPOCH))

  # skip_reason is null unless a #490 skip set it.
  if [ -n "$SKIP_REASON" ]; then
    skip_reason_json=$(jq -n --arg r "$SKIP_REASON" '$r')
  else
    skip_reason_json="null"
  fi

  # blocking_tier_unresolved (#577): lazily compute the required-tier finding
  # count ONLY when the feedback_policy block is present AND this is a
  # findings-relevant terminal (`findings` / `cleared`) — the statuses where
  # inline HEAD findings are meaningful and API access is in play. Every other
  # terminal (timeout / rate_limit_stalled / paused / skip / config error)
  # leaves it null, so no extra API calls are made on those paths and the
  # historical JSON shape is unchanged except for one additive null field.
  # This never affects $exit_code — the value is report-only.
  if [ "$FEEDBACK_POLICY_PRESENT" = true ] && [ "$BLOCKING_TIER_UNRESOLVED" = "null" ]; then
    case "$status" in
      findings|cleared)
        # Guard the advisory decoration so it can NEVER flip the terminal exit
        # code or break the JSON emit (nathanpayne-codex P2 on #590). Two
        # layers: `|| true` stops a die inside count_blocking_tier_issues from
        # aborting under set -e, and the numeric-or-null validation forces a
        # value the downstream `jq --argjson` accepts. The earlier `$(...) ||
        # VAR=null` was insufficient: when an internal fetch_api_array dies,
        # count_blocking_tier_issues can exit 0 with EMPTY output, so the `||`
        # never fired and the empty value broke `jq --argjson` — a hard failure
        # on an otherwise-terminal path. Validation catches empty/non-numeric.
        BLOCKING_TIER_UNRESOLVED=$(count_blocking_tier_issues 2>/dev/null || true)
        case "$BLOCKING_TIER_UNRESOLVED" in
          ''|*[!0-9]*) BLOCKING_TIER_UNRESOLVED=null ;;
        esac
        ;;
    esac
  fi

  # --probe (#814): `terminal` covers a probe run that reached a real
  # verdict (0 / 2 / 6). Null on every polling run. context_state and
  # context_updated_at carry the per-SHA StatusContext (state + refresh
  # time) sampled by the rc-7 review-object branch (#869 / #875) and are
  # null on every other path.
  if [ "$PROBE_MODE" = "true" ]; then
    PROBE_JSON=$(jq -nc --arg observed "${PROBE_OBSERVED:-terminal}" \
      --arg ctx "${PROBE_CONTEXT_STATE:-}" \
      --arg ctxat "${PROBE_CONTEXT_UPDATED_AT:-}" \
      '{mode: true, observed: $observed,
        context_state: (if $ctx == "" then null else $ctx end),
        context_updated_at: (if $ctxat == "" then null else $ctxat end)}')
  fi

  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg head_sha "$HEAD_SHA" \
    --arg head_committer_date "$HEAD_COMMITTER_DATE" \
    --arg bot_login "$BOT_LOGIN" \
    --arg status "$status" \
    --argjson skip_reason "$skip_reason_json" \
    --argjson review "$review_json" \
    --argjson potential_issue_count "$potential_issues" \
    --argjson blocking_tier_unresolved "$BLOCKING_TIER_UNRESOLVED" \
    --argjson rate_limit_retries "$RATE_LIMIT_RETRIES" \
    --argjson resume_retries "$RESUME_RETRIES" \
    --argjson status_probe "$STATUS_PROBE_JSON" \
    --argjson probe "$PROBE_JSON" \
    --argjson waited_seconds "$waited" \
    --argjson codex_failover_requested "$CODEX_FAILOVER_REQUESTED" \
    '{
      pr_number: $pr_number,
      repo: $repo,
      head_sha: $head_sha,
      head_committer_date: $head_committer_date,
      bot_login: $bot_login,
      status: $status,
      skip_reason: $skip_reason,
      review: $review,
      potential_issue_count: $potential_issue_count,
      blocking_tier_unresolved: $blocking_tier_unresolved,
      rate_limit_retries: $rate_limit_retries,
      resume_retries: $resume_retries,
      status_probe: $status_probe,
      probe: $probe,
      waited_seconds: $waited_seconds,
      codex_failover_requested: $codex_failover_requested
    }'

  exit "$exit_code"
}

# Sleep for up to `requested` seconds, clamped to the remaining
# max_wait_seconds budget. Without this guard, fixed 15s polling
# sleeps could overshoot the configured budget (caller sees
# `waited_seconds > max_wait_seconds`). An earlier version of this
# helper exited early whenever `requested >= remaining` to avoid the
# overshoot — but that shortens the effective budget by up to one
# poll interval (iterations at elapsed 286..299 exit immediately
# for a 300s budget, missing a review that lands right before the
# deadline). The right shape: sleep min(requested, remaining), then
# let the next iteration's top-of-loop check hit the exact-elapsed
# timeout. See #140 round-3 CodeRabbit finding (Major, line 380)
# and #140 round-4 Codex finding (P2, line 391).
sleep_or_timeout() {
  local requested=$1
  local now elapsed remaining actual
  now=$(date +%s)
  elapsed=$((now - START_EPOCH))
  remaining=$((MAX_WAIT_SECONDS - elapsed))
  if [ "$remaining" -le 0 ]; then
    emit_timeout "budget exhausted (remaining=${remaining}s) — timing out"
  fi
  actual=$requested
  if [ "$actual" -gt "$remaining" ]; then
    actual=$remaining
    log "clamping sleep from ${requested}s to remaining budget ${remaining}s"
  fi
  sleep "$actual"
}

emit_status_context_verdict() {
  local state=$1
  # CodeRabbit's StatusContext SUCCESS state means "review completed"
  # — NOT "no findings remain." With CodeRabbit's default
  # `request_changes_workflow: false`, the status flips to success
  # whenever the review finishes, even if Potential issue / ⚠️
  # comments were posted. Codex (chatgpt-codex-connector[bot]) caught
  # this on PR #224 round 1 (P1 finding, line 546). The fix: scan
  # inline `Potential issue` / `⚠️` markers anchored on HEAD before
  # declaring clearance.
  #
  # Round 2 sharpening (codex CHANGES_REQUESTED + CodeRabbit ⚠️ Major
  # @ line 581 on the round 1 fix): use `count_potential_issues_for_sha
  # "$HEAD_SHA"` rather than `count_potential_issues`. The latter is
  # filtered by HEAD_ANCHOR (wallclock freshness floor); after 30 min
  # on the same unchanged HEAD, anchor advances past prior reviews and
  # the count drops to 0 — false-clearing the fast-path. The
  # SHA-scoped variant ignores the wallclock anchor entirely and counts
  # findings whose `commit_id == HEAD_SHA`, which is the right scope
  # given the fast-path already has authoritative SHA-level evidence
  # from the StatusContext check.
  local potential_issues synthetic
  potential_issues=$(count_potential_issues_for_sha "$HEAD_SHA")
  # Keep the synthetic review object compatible with the documented
  # contract at the top of this file: `{ id, created_at, endpoint,
  # body_excerpt }`. The fast-path has no underlying GitHub review,
  # so `id` is null and `created_at` is the synthesis time — but a
  # caller reading `review.id` or `review.created_at` no longer hits
  # a missing key and breaks. `endpoint` keeps the new
  # "status_context" value (a documented extension for this path); the
  # extra `head_sha` / `context_state` / `potential_issue_count`
  # fields are additive. (CodeRabbit Major, #272.)
  synthetic=$(jq -nc \
    --arg sha "$HEAD_SHA" \
    --arg state "$state" \
    --argjson p "$potential_issues" \
    '{
      id: null,
      created_at: (now | todateiso8601),
      endpoint: "status_context",
      head_sha: $sha,
      context_state: $state,
      potential_issue_count: $p,
      body_excerpt: ("CodeRabbit StatusContext = " + $state + " on " + $sha + " (potential_issue_count=" + ($p | tostring) + ")")
    }')
  if [ "$potential_issues" -gt 0 ]; then
    log "StatusContext $state but $potential_issues Potential issue/⚠️ marker(s) on HEAD — emitting findings (exit 2)"
    emit_json_and_exit "findings" 2 "$synthetic" "$potential_issues"
  fi
  log "StatusContext $state and 0 Potential issue/⚠️ markers — emitting cleared (exit 0)"
  emit_json_and_exit "cleared" 0 "$synthetic" 0
}

# --- probe verdict (#814) ---------------------------------------------------
#
# Probe mode answers ONE question and never enters the poll loop:
#
#   has CodeRabbit reported on this exact head?
#
# It deliberately does NOT decide whether the review was clean. That is a
# verdict, and reproducing it correctly is what the polling path below exists
# to do — it has to reconcile inline findings, summary-only findings (#535),
# the StatusContext and its spurious-success suppression, addressed-marker
# replies, and two freshness anchors. Six review rounds on #823 showed that
# borrowing any of that machinery imports assumptions written for an ADVISORY
# caller, where a read degrading to "no findings" costs a warning rather than
# an approval.
#
# The barrier does not need the verdict. It needs ORDERING: do not let Phase 4b
# approve before the providers have spoken. Whether CodeRabbit found anything
# is already enforced downstream by scripts/coderabbit-severity-gate.sh and the
# pre-merge conversation-resolution gate. Answering the narrow question needs
# one API read and no shared helpers.
#
# Evidence is a CodeRabbit review object whose `commit_id` is this head.
# GitHub-owned, immutable, and it does not expire — no wall-clock floor, so a
# head that has been sitting for an hour still reads as reported.
#
# A second evidence form is admitted when no review object exists (#851): the
# PR's single summarize comment, head-pinned by CONTENT — its commits range
# names this head — completed (every outcome stanza benign) and classifying as
# a review. Same author, same GitHub-owned surface, same head-identity claim a
# commit_id makes. It is NOT the same grade of evidence: a comment body is
# mutable where a commit_id is not, so a CodeRabbit-side rewrite that dropped
# the range would flip a reported head back to not-yet. That direction is safe
# — liveness, not correctness — and accepted, because without this form a
# clean incremental re-review (which posts no review object at all) reads as
# not-yet forever.
#
# What the admission rests on, stated plainly: for the three pending states
# (rate-limited, paused, mid-review) the class check and the stanza allow-list
# both key on the same `auto-generated comment:` wrapper family, and every
# prose fallback behind them is dead against CodeRabbit's current wording. The
# wrapper is present in every observed comment and edit version (3,116 live
# comments, 512 reconstructed versions), and its loss would also break the
# pre-existing PAUSED_MARKER / RATE_LIMIT_MARKER keys — but it is one
# convention, not two independent signals. A reader weakening either conjunct
# should know there is no third.
#
# The StatusContext is deliberately NOT consulted as EXISTENCE evidence. It
# is SHA-pinned, but CodeRabbit emits a spurious success shortly after a
# rate-limit notice (the case status_context_fast_path_blocked_by_comment
# exists to suppress), so using it alone would report a head as reviewed when
# it was not. A silent clean review that posts only a status therefore reads
# as NOT-YET; the barrier's trigger step then asks for a review explicitly,
# which always produces a review object, so it self-heals at the cost of one
# allowance unit rather than by risking a false REPORTED. Two narrower,
# CONJUNCTIVE roles are admitted (#869 / P1 on #875), both trust-gated by
# trust_status_context_for_clearance: corroborating an explicit
# finished-review claim in a comment body (head_completion_corroborated —
# the claim exists independently; the status only anchors it to this head),
# and riding along in the rc-7 JSON as probe.context_state when the evidence
# is a HEAD-pinned review object, so the Phase 4b barrier can require
# per-SHA completion before opening on an object whose PR-level summary is
# still in flight. In both, the status upgrades nothing on its own — it
# seconds a claim another surface already made.
probe_emit_verdict() {
  local reviews review review_at issue_comments cand row body class ctx_record
  local summary_body="" newest_class="" rescan_done=false finished_attestation=false

  # Both reads are made DIRECTLY here, never through a helper. fetch_api_array
  # signals failure with `die 3`, which inside a command substitution exits
  # only that subshell — so a helper wrapping it (scan_latest_comment,
  # count_potential_issues_for_sha, latest_head_pinned_review) carries on with
  # empty input and returns 0. Any caller in a conditional or OR-list context
  # then reads a failed API call as a confident negative. That pattern was
  # found three times in three different helpers during review of this change;
  # calling fetch_api_array directly is what makes `|| die 3` actually fire,
  # because the failing status reaches this assignment rather than being
  # swallowed by an intermediate function.
  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews") \
    || die 3 "failed to fetch reviews for the probe verdict"
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") \
    || die 3 "failed to fetch issue comments for the probe verdict"

  # `submitted_at` is additive (#875 round 2): the same instant created_at
  # already carries on this endpoint, but named explicitly so the Phase 4b
  # barrier's temporal conjunct (context_updated_at at-or-after the object)
  # reads a field whose meaning cannot drift with the endpoint.
  review=$(printf '%s' "$reviews" | jq -c --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    [ .[] | select(.user.login == $bot) | select(.commit_id == $sha) ]
    | sort_by(.submitted_at) | last
    | if . == null then empty
      else {id, created_at: .submitted_at, submitted_at, endpoint: "reviews",
            body_excerpt: ((.body // "")[0:200])} end
  ') || die 3 "failed to select the HEAD-pinned review"

  # Pre-seed the #875 corroboration hints for every classify_comment call in
  # this scan: the selection above IS the newest head-pinned review-object
  # check, so a positive result leaves only the claim-ordering comparison
  # (no extra read), and a negative one lets head_completion_corroborated
  # skip the redundant refetch (only the trust-gated StatusContext leg
  # remains).
  if [ -n "$review" ]; then
    CR_HEAD_REVIEW_OBJECT_PRESENT=true
    CR_HEAD_REVIEW_OBJECT_SUBMITTED_AT=$(printf '%s' "$review" | jq -r '.submitted_at // empty')
  else
    CR_HEAD_REVIEW_OBJECT_PRESENT=false
    CR_HEAD_REVIEW_OBJECT_SUBMITTED_AT=""
  fi

  if [ -n "$review" ]; then
    review_at=$(printf '%s' "$review" | jq -r '.created_at // empty')
    # Publication completes when a bot comment at or after the review actually
    # CLASSIFIES as a review summary. Excluding narration alone is not enough:
    # a rate-limit, paused, or in-progress notice updated after the review
    # object would otherwise satisfy this while the summary is still pending.
    # Scanned newest-first, and a later non-terminal notice does not hide an
    # already-published summary. Anchor-free on purpose — HEAD_ANCHOR carries a
    # moving wall-clock floor that would make a completed publication stop
    # counting once the head had sat long enough.
    #
    # The scan runs in a loop bounded to ONE re-fetch (#875 round 4): the
    # issue-comments snapshot predates the status read below, so the
    # summary can land in the gap — emitting the rc-7 success payload from
    # the stale snapshot would let the barrier open past a just-published
    # summary that was never scanned (and that can carry the only blocking
    # marker). After a per-SHA success is observed with the summary still
    # unseen, the comments are re-fetched once and re-scanned; only a
    # still-absent summary emits the rc-7 payload.
    while :; do
      summary_body=""
      newest_class=""
      cand=$(printf '%s' "$issue_comments" | jq -r --arg bot "$BOT_LOGIN" --arg at "$review_at" '
        [ .[] | select(.user.login == $bot)
          | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
          | select(.fresh_at >= $at) ]
        | sort_by(.fresh_at) | reverse | .[] | @base64
      ') || die 3 "failed to select the review summary"
      while IFS= read -r row; do
        [ -z "$row" ] && continue
        body=$(printf '%s' "$row" | base64 --decode | jq -r '.body // ""')
        class=$(classify_comment "$body" \
          "$(printf '%s' "$row" | base64 --decode | jq -r '.fresh_at // empty')")
        # Narration replies carry no publication state, and the probe.observed
        # enum deliberately omits status_probe — the no-review-object triage
        # drops narration in its jq filter, but this scan classifies every row,
        # so without this skip a narration reply landing after the review
        # object leaks `observed: "status_probe"` (#833, seen live on #852).
        # Skipped, not latched as blank: a pending notice BENEATH the narration
        # still names the observed state, and no narration hides a published
        # summary deeper in the scan.
        [ "$class" = "status_probe" ] && continue
        # #875 round 5: a CORROBORATED finished actions reply classifies
        # `review`, but it attests TERMINALITY only — it is never
        # marker-inspection material. Storing it as summary_body would hand
        # the #535 blocking-marker check a body that structurally carries no
        # findings, shadowing the REAL summary whenever the reply is newer
        # (posted after, or edited after) — the newest-first scan would stop
        # on it and a blocking marker carried solely by the genuine summary
        # would clear. Skip it WITHOUT latching newest_class (like
        # narration): the attestation asserts no pending adverse state, and
        # the scan continues to the real summary, selected by its content
        # class with attestations excluded — so the reply's position or
        # edit time cannot out-select the summary it postdates. When no
        # real summary exists the loop falls through to the
        # awaiting-summary / rc-7 path (with the round-4 bounded re-fetch),
        # where the attestation's terminality is carried by the corroborated
        # status conjuncts the barrier requires, not by a verdict here.
        if [ "$class" = "review" ] && comment_states_review_finished "$body"; then
          finished_attestation=true
          continue
        fi
        [ -n "$newest_class" ] || newest_class="$class"
        if [ "$class" = "review" ]; then summary_body="$body"; break; fi
      done <<< "$cand"

      [ -n "$summary_body" ] && break

      PROBE_OBSERVED="${newest_class:-awaiting-summary}"
      # #869 / P1 on #875: this is the ONE probe state whose rc-7 JSON
      # carries review-object evidence, and the barrier must not open on
      # that object alone — the PR-level summary still in flight can carry
      # the ONLY blocking marker (the #535 summary-only class, e.g. the
      # auto-pause note). Sample the per-SHA StatusContext — state AND
      # refresh time — into probe.context_state / probe.context_updated_at
      # so the barrier can require `success` that is at-or-after this
      # review object's submitted_at (#875 round 2): on a same-SHA rerun
      # the statuses endpoint still exposes the PREVIOUS run's success
      # while the new object's summary and status refresh are pending, and
      # a success that PREDATES the object it would corroborate belongs to
      # a different run. Trust-gated by the same policy switch as every
      # other status read; both fields left null when the policy opts out,
      # which fails closed at the barrier (not-yet). Sampled once — the
      # re-scan pass reuses the first sample rather than reading a surface
      # that postdates it.
      if [ "$TRUST_STATUS_CONTEXT" = "true" ] && [ -z "$PROBE_CONTEXT_STATE" ]; then
        ctx_record=$(check_status_context_record)
        PROBE_CONTEXT_STATE=$(printf '%s' "$ctx_record" | jq -r '.state // "missing"')
        PROBE_CONTEXT_UPDATED_AT=$(printf '%s' "$ctx_record" | jq -r '.updated_at // ""')
      fi
      # #875 round 4 TOCTOU: the success just observed post-dates the
      # comments snapshot, so the summary may already be up. One re-fetch,
      # one re-scan; a summary found on the second pass takes the normal
      # rc-0/rc-2 verdict below instead of the rc-7 evidence. The re-fetch
      # failing is an infra rc 3 like every other probe read — emitting
      # the rc-7 success payload after a failed re-fetch would be exactly
      # the unscanned-summary hazard this loop exists to close.
      if [ "$PROBE_CONTEXT_STATE" = "success" ] && [ "$rescan_done" != true ]; then
        rescan_done=true
        log "probe: per-SHA success observed while the summary is unseen — re-fetching issue comments once (#875 round 4)"
        issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments (post-success re-scan)") \
          || die 3 "failed to re-fetch issue comments for the post-success re-scan"
        continue
      fi
      log "probe: review object on $HEAD_SHA but no terminal summary yet (newest=${newest_class:-none}, finished_attestation=$finished_attestation, context_state=${PROBE_CONTEXT_STATE:-unsampled}, context_updated_at=${PROBE_CONTEXT_UPDATED_AT:-unsampled})"
      probe_not_yet "$PROBE_OBSERVED" "$review"
    done

    # A published summary is the verdict source, not the rc-7 payload —
    # clear the rc-7-only status fields (possibly sampled on a first pass
    # of the loop above) so the documented contract holds: context_state /
    # context_updated_at are null on every non-rc-7 path.
    PROBE_CONTEXT_STATE=""
    PROBE_CONTEXT_UPDATED_AT=""

    # The one verdict this mode does make, and only because nothing else can.
    # A blocking finding carried SOLELY by the PR-level summary (#535) is
    # dispositioned by no required gate: scripts/coderabbit-severity-gate.sh
    # reads only pulls/{pr}/comments, the conversation gate covers threads, and
    # the Phase 4b adapter sees only the diff. Waiting for publication does not
    # help if nothing evaluates what was published. Inline findings are NOT
    # counted here — the severity gate already owns those.
    # Via the shared helper so the pre-merge check table's hygiene `⚠️
    # Warning` rows (docstring coverage, description score) cannot read as a
    # blocking finding — 3 of 5 sampled summaries carry one and none is a
    # finding. One definition for both probe verdict sites.
    if summary_blocking_marker_present "$summary_body"; then
      PROBE_OBSERVED="terminal"
      log "probe: CodeRabbit reported on $HEAD_SHA with a summary-only blocking marker"
      emit_json_and_exit "findings" 2 "$review" 1
    fi
    PROBE_OBSERVED="terminal"
    log "probe: CodeRabbit has reported on $HEAD_SHA (summary published, no summary-level marker)"
    emit_json_and_exit "reported" 0 "$review" 0
  fi

  # No review object. Classify the newest non-narration bot comment to see
  # whether a review is actively underway — these PRs can be reviewed after a
  # manual trigger, and reporting WILL-NOT-REPORT while one is in flight lets
  # the barrier proceed ahead of it.
  cand=$(printf '%s' "$issue_comments" | jq -r --arg bot "$BOT_LOGIN" --arg after "$HEAD_ANCHOR" '
    def narration:
      ((.body // "") | test("CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits"; "i"));
    [ .[] | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(.fresh_at >= $after)
      | select(narration | not) ]
    | sort_by(.fresh_at) | last
    | if . == null then empty
      else {json: ({id, created_at, updated_at, fresh_at, endpoint: "issues",
                    body_excerpt: ((.body // "")[0:200])} | tojson),
            body: (.body // "")} | @base64 end
  ') || die 3 "failed to classify the latest comment"

  local latest_json="null"
  if [ -n "$cand" ]; then
    body=$(printf '%s' "$cand" | base64 --decode | jq -r '.body')
    latest_json=$(printf '%s' "$cand" | base64 --decode | jq -r '.json')
    newest_class=$(classify_comment "$body" \
      "$(printf '%s' "$latest_json" | jq -r '.fresh_at // empty')")
    case "$newest_class" in
      in_progress|rate_limit|paused)
        probe_not_yet "$newest_class" "$latest_json"
        ;;
    esac
  fi

  # #851: a CLEAN incremental re-review posts NO review object. CodeRabbit
  # records the outcome by editing its PR-level summary in place, whose
  # commits range then names THIS head — the same claim a review object's
  # commit_id makes, from the same author, on a GitHub-owned surface. Without
  # this, every previously-reviewed PR reads not-yet forever and the barrier
  # burns its whole budget.
  #
  # Selected BY the summarize marker AT THE START of the body, not as "the
  # newest candidate": every rate-limit/pause/in-progress notice is written
  # INTO that one comment, so the state that would mask this evidence is
  # carried by the very body being classified. startswith, not containment
  # (adversarial verification on this change): CodeRabbit pastes `rg`/`git
  # diff` output into chat replies, and this repository itself carries the
  # marker literal in source and tests — a reply QUOTING it mid-body would
  # satisfy containment, be the freshest carrier, and either supply false
  # evidence or out-select the real summary. Every live summarize comment
  # (40/40 sampled) begins with the marker at byte 0; no reply does.
  #
  # ANCHOR-FREE on purpose: the SHA conjunct IS head identity, strictly
  # stronger than the wall-clock proxy, and an anchored read would spend a
  # CodeRabbit request on an already-reviewed head once the floor passed it —
  # the review-object branch's own argument. The anchored triage above stays
  # anchored; dropping ITS anchor would let an ancient rate-limit notice
  # decline the trigger and deadlock differently.
  local summary sbody sjson
  summary=$(printf '%s' "$issue_comments" | jq -r --arg bot "$BOT_LOGIN" --arg m "$SUMMARY_MARKER" '
    [ .[] | select(.user.login == $bot) | select((.body // "") | startswith($m))
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)} ]
    | sort_by(.fresh_at) | last
    | if . == null then empty
      else {json: ({id, created_at, updated_at, fresh_at, endpoint: "issues",
                    body_excerpt: ((.body // "")[0:200])} | tojson),
            body: (.body // "")} | @base64 end
  ') || die 3 "failed to select the CodeRabbit summary comment"
  if [ -n "$summary" ]; then
    sbody=$(printf '%s' "$summary" | base64 --decode | jq -r '.body')
    # Three conjuncts. Each one alone admits a head-naming non-report state:
    #   class == review       rate-limited / paused / in-progress, including
    #                         the LEGACY prose forms that carry no marker.
    #   stanzas all benign    `failure` (#790, #783), `skip review` (#797), a
    #                         drifted in-progress KIND, and anything CodeRabbit
    #                         ships next. Fail-closed by construction.
    #   head SHA present      a prior head's summary (#789), however recently
    #                         a Finishing-Touches checkbox edit bumped it.
    if [ "$(classify_comment "$sbody" "$(printf '%s' "$summary" | base64 --decode | jq -r '(.json | fromjson).fresh_at // empty')")" = "review" ] \
       && summary_stanzas_all_benign "$sbody" \
       && summary_names_head "$sbody" "$HEAD_SHA"; then
      sjson=$(printf '%s' "$summary" | base64 --decode | jq -r '.json')
      PROBE_OBSERVED="terminal"
      # #535 parity. A blocking finding carried SOLELY by the summary is
      # dispositioned by no required gate, and that is as true with no review
      # object as with one. Previously this state returned rc 7, held the
      # barrier's full budget and escalated with the WRONG reason; now it
      # escalates immediately with the right one.
      if summary_blocking_marker_present "$sbody"; then
        log "probe: head-pinned summary on $HEAD_SHA carries a summary-only blocking marker"
        emit_json_and_exit "findings" 2 "$sjson" 1
      fi
      log "probe: CodeRabbit reported on $HEAD_SHA via a head-pinned summary (clean incremental re-review, no review object)"
      emit_json_and_exit "reported" 0 "$sjson" 0
    fi
  fi

  # Nothing active. Only NOW does auto-review eligibility settle it.
  if [ -n "${PROBE_STATIC_SKIP:-}" ]; then
    SKIP_REASON="$PROBE_STATIC_SKIP"
    PROBE_OBSERVED="terminal"
    log "probe: no CodeRabbit review on $HEAD_SHA and auto-review will not fire ($PROBE_STATIC_SKIP)"
    emit_json_and_exit "skipped" 6 "null" 0
  fi

  if [ -z "$cand" ]; then
    probe_not_yet "none" "null"
  fi
  # A summary exists but nothing is SHA-pinned to this head — the shape a prior
  # head's summary takes after a new push.
  probe_not_yet "summary-without-head-review" "$latest_json"
}

# --- static skip checks (#490) ----------------------------------------------
#
# Two configured conditions mean CodeRabbit auto-review will NEVER fire on
# this PR, so there is nothing to poll for. Detect them up front and exit 6
# (skipped) with the reason in JSON rather than burning the whole
# max_wait_seconds budget on a review that cannot land:
#
#   1. base branch ∉ reviews.auto_review.base_branches — a PR onto a base
#      CodeRabbit isn't configured to review (stacked / non-main bases).
#   2. draft PR when reviews.auto_review.drafts: false — drafts aren't
#      reviewed until marked ready.
#
# Both are read from .coderabbit.yml. When the relevant key is absent (a
# consumer that doesn't constrain bases, or doesn't set drafts), the reader
# yields nothing and the corresponding check is suppressed — no false skip.
# Neither is re-invocable (resume/review won't help), so the JSON surfaces
# the reason and the caller decides (retarget the base, mark ready, escalate).
#
# base_branches semantics: CodeRabbit documents each entry as a REGEX
# pattern that names ADDITIONAL non-default bases to review, and it ALWAYS
# reviews the repo default branch regardless of whether the default is
# listed. So the non-base-branch skip must (a) always allow the default
# branch, and (b) match each configured entry as a regex (anchored — the
# whole base ref must match), not as a fixed string. A repo configuring
# `base_branches: ["release/.*"]` must NOT skip a PR into `release/2026`,
# and a default-branch PR must NOT skip just because the default is not
# redundantly listed. Fail SAFE: if an entry is not a valid regex, suppress
# the skip rather than risk a false skip that blocks review/merge.
CONFIGURED_BASE_BRANCHES=$(coderabbit_yml_base_branches)
if [ -n "$CONFIGURED_BASE_BRANCHES" ] && [ -n "$PR_BASE_REF" ]; then
  base_is_allowed=no
  # The repo default branch is always reviewed by CodeRabbit, listed or not.
  if [ -n "$PR_DEFAULT_BRANCH" ] && [ "$PR_BASE_REF" = "$PR_DEFAULT_BRANCH" ]; then
    base_is_allowed=yes
  fi
  if [ "$base_is_allowed" = "no" ]; then
    while IFS= read -r base_pattern; do
      [ -n "$base_pattern" ] || continue
      # Anchor the pattern so the whole base ref must match (CodeRabbit's
      # base_branches regexes are full-match). grep exits 2 on a malformed
      # ERE (vs 0/1 for match/no-match). An entry we cannot evaluate is one
      # we cannot reason about, so fail SAFE (allow) rather than risk a
      # false skip that blocks review/merge. The `|| grep_rc=$?` captures
      # grep's status without `set -e`/`pipefail` aborting on the
      # no-match (1) or bad-regex (2) cases.
      grep_rc=0
      printf '%s\n' "$PR_BASE_REF" | grep -Eq -e "^(${base_pattern})\$" >/dev/null 2>&1 || grep_rc=$?
      case "$grep_rc" in
        0)
          base_is_allowed=yes
          break
          ;;
        1)
          : # valid pattern, this base simply did not match — keep checking
          ;;
        *)
          log "base_branches entry '$base_pattern' is not a valid regex — suppressing non-base-branch skip (fail-safe)"
          base_is_allowed=yes
          break
          ;;
      esac
    done <<EOF
$CONFIGURED_BASE_BRANCHES
EOF
  fi
  if [ "$base_is_allowed" = "no" ]; then
    SKIP_REASON="non-base-branch"
    log "PR base branch '$PR_BASE_REF' matches no configured base_branches regex and is not the default branch — CodeRabbit auto-review will not fire (skip)"
    # Probe mode defers the skip (#814): such a PR can already carry a real
    # HEAD review — after a manual trigger, a retarget, or a later conversion
    # to draft — and exiting here without looking would report WILL-NOT-REPORT
    # over real findings. Record it; probe_emit_verdict uses it only when no
    # HEAD evidence exists.
    if [ "$PROBE_MODE" = "true" ]; then
      PROBE_STATIC_SKIP="non-base-branch"
      SKIP_REASON=""
    else
      emit_json_and_exit "skipped" 6 "null" 0
    fi
  fi
fi

CONFIGURED_DRAFTS=$(coderabbit_yml_drafts)
if [ "$CONFIGURED_DRAFTS" = "false" ] && [ "$PR_IS_DRAFT" = "true" ]; then
  SKIP_REASON="draft"
  log "PR is a draft and reviews.auto_review.drafts is false — CodeRabbit auto-review will not fire until marked ready (skip)"
  if [ "$PROBE_MODE" = "true" ]; then
    PROBE_STATIC_SKIP="draft"
    SKIP_REASON=""
  else
    emit_json_and_exit "skipped" 6 "null" 0
  fi
fi

# Probe mode answers here and always exits — it never reaches the poll loop.
if [ "$PROBE_MODE" = "true" ]; then
  probe_emit_verdict
  die 3 "internal: probe_emit_verdict returned without exiting"
fi

# Pre-loop fast-path. If CodeRabbit posted SUCCESS on this SHA before
# the script started polling, we can short-circuit immediately and
# avoid the first 15s sleep. See #221 — the historical comment-driven
# poll burned the full 300s budget on every clean fix-up push because
# CodeRabbit doesn't re-narrate when there's nothing new to flag.
if [ "$TRUST_STATUS_CONTEXT" = "true" ]; then
  INITIAL_CTX_RECORD=$(check_status_context_record)
  INITIAL_CTX=$(echo "$INITIAL_CTX_RECORD" | jq -r '.state')
  INITIAL_CTX_CREATED=$(echo "$INITIAL_CTX_RECORD" | jq -r '.created_at')
  log "initial CodeRabbit StatusContext = $INITIAL_CTX on $HEAD_SHA"
  if [ "$INITIAL_CTX" = "success" ]; then
    if ! status_context_fast_path_blocked_by_comment "$INITIAL_CTX_CREATED"; then
      log "StatusContext success — entering fast-path verdict (scans inline findings before clearance)"
      emit_status_context_verdict "$INITIAL_CTX"
    fi
  fi
fi

while :; do
  NOW_EPOCH=$(date +%s)
  ELAPSED=$((NOW_EPOCH - START_EPOCH))
  if [ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]; then
    emit_timeout "max_wait_seconds ($MAX_WAIT_SECONDS) exceeded after ${ELAPSED}s — timing out"
  fi

  # In-loop fast-path — same intent as the pre-loop check, for the case
  # where CodeRabbit posts SUCCESS while we're already polling. Cheaper
  # API call than `scan_latest_comment` so it's worth doing first each
  # iteration; falls through to the comment scan if not success/failure.
  if [ "$TRUST_STATUS_CONTEXT" = "true" ]; then
    LOOP_CTX_RECORD=$(check_status_context_record)
    LOOP_CTX=$(echo "$LOOP_CTX_RECORD" | jq -r '.state')
    LOOP_CTX_CREATED=$(echo "$LOOP_CTX_RECORD" | jq -r '.created_at')
    if [ "$LOOP_CTX" = "success" ]; then
      if ! status_context_fast_path_blocked_by_comment "$LOOP_CTX_CREATED"; then
        log "CodeRabbit StatusContext flipped to success mid-loop on $HEAD_SHA — entering fast-path verdict"
        emit_status_context_verdict "$LOOP_CTX"
      fi
    fi
  fi

  LATEST=$(scan_latest_comment)

  if [ "$(echo "$LATEST" | jq 'length')" = "0" ]; then
    log "no CodeRabbit comment yet (elapsed ${ELAPSED}s); sleeping ${POLL_INTERVAL_SECONDS}s"
    sleep_or_timeout "$POLL_INTERVAL_SECONDS"
    continue
  fi

  COMMENT_ID=$(echo "$LATEST" | jq -r '.id')
  COMMENT_BODY=$(echo "$LATEST" | jq -r '.body')
  COMMENT_ENDPOINT=$(echo "$LATEST" | jq -r '.endpoint')
  COMMENT_CREATED=$(echo "$LATEST" | jq -r '.created_at')
  COMMENT_FRESH_AT=$(echo "$LATEST" | jq -r '.fresh_at // .updated_at // .created_at')

  CLASS=$(classify_comment "$COMMENT_BODY" "$COMMENT_FRESH_AT")
  log "latest CodeRabbit comment id=$COMMENT_ID endpoint=$COMMENT_ENDPOINT class=$CLASS created=$COMMENT_CREATED fresh_at=$COMMENT_FRESH_AT"

  case "$CLASS" in
    rate_limit)
      if [ "$COMMENT_ID" = "$LAST_RATE_LIMIT_COMMENT_ID" ]; then
        # Same rate-limit comment as last iteration — still sleeping/waiting
        # through our own retry window. Don't double-count retries.
        log "still inside prior rate-limit window; sleeping ${POLL_INTERVAL_SECONDS}s"
        sleep_or_timeout "$POLL_INTERVAL_SECONDS"
        continue
      fi
      LAST_RATE_LIMIT_COMMENT_ID=$COMMENT_ID

      # #489: fire the Codex failover once, on the first rate-limit notice, so
      # Codex (the real blocking gate) reviews in parallel instead of the PR
      # idling on CodeRabbit's hourly allowance. Fired BEFORE the stall checks
      # below so a budget/retry stall still leaves Codex engaged. Idempotent +
      # HEAD-pinned: --trigger-only posts at most one @codex trigger per HEAD
      # (its own scan dedupes across runs); the FIRED latch prevents re-posting
      # across this run's retries. MERGEPATH_PHASE_4A_GATED=true forces the
      # request even when codex.request_by_default is false; if Codex is
      # disabled/opted out the helper no-ops and the failover stays unrecorded.
      if [ "$CODEX_FAILOVER_ON_RATE_LIMIT" != "false" ] && [ "$CODEX_FAILOVER_FIRED" != "true" ]; then
        CODEX_FAILOVER_FIRED=true
        log "codex failover: CodeRabbit rate-limited — requesting @codex review (trigger-only)"
        if MERGEPATH_PHASE_4A_GATED=true "$CODEX_REQUEST_CMD" --trigger-only "$PR_NUMBER" "$REPO" >&2; then
          CODEX_FAILOVER_REQUESTED=true
          log "codex failover: @codex review requested (or already present) on HEAD"
        else
          log "codex failover: codex-review-request did not post (Codex disabled/opted out or read error) — continuing CodeRabbit retry"
        fi
      fi

      if [ "$RATE_LIMIT_RETRIES" -ge "$MAX_RATE_LIMIT_RETRIES" ]; then
        log "max_rate_limit_retries ($MAX_RATE_LIMIT_RETRIES) exceeded — stalling"
        RATE_LIMIT_REVIEW=$(echo "$LATEST" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
        emit_json_and_exit "rate_limit_stalled" 5 "$RATE_LIMIT_REVIEW" 0
      fi

      WINDOW_SECONDS=$(parse_rate_limit_window "$COMMENT_BODY" || echo "")
      if [ -z "$WINDOW_SECONDS" ]; then
        log "could not parse rate-limit window from comment; falling back to 60s"
        WINDOW_SECONDS=60
      fi
      # #727: sleep only the window that REMAINS. The published window runs
      # from the notice's post time (COMMENT_FRESH_AT), so subtract however
      # much of it already elapsed before we reached this point. An
      # already-expired window ⇒ SLEEP_FOR clamps to 0 and we fall straight
      # through to the retry + re-poll instead of re-waiting time that has
      # already passed (auto-merge PR #725 re-waited a fresh 210s for a window
      # that expired ~5 min earlier). A genuinely-fresh notice (elapsed≈0)
      # still sleeps ~the full window, so the rate-limit contract is unchanged
      # for the common case.
      NOW_EPOCH=$(date +%s)
      WINDOW_ELAPSED=$(rate_limit_window_elapsed_seconds "$COMMENT_FRESH_AT" "$NOW_EPOCH")
      SLEEP_FOR=$((WINDOW_SECONDS + RATE_LIMIT_BUFFER_SECONDS - WINDOW_ELAPSED))
      if [ "$SLEEP_FOR" -lt 0 ]; then SLEEP_FOR=0; fi
      # Clamp against remaining budget — if the (remaining) rate-limit
      # window still exceeds max_wait_seconds, there's no point burning
      # through the entire sleep. Surface it as the same hard rate-limit
      # stalled state callers already treat as non-advisory instead of a
      # generic timeout that auto-merge may skip past. See #140 round-2 Codex
      # finding (P2, line 392), then #386. Uses the remaining SLEEP_FOR (not
      # the full window), so a window that mostly elapsed no longer stalls a
      # PR that can afford the small remainder (#727).
      ELAPSED=$((NOW_EPOCH - START_EPOCH))
      REMAINING=$((MAX_WAIT_SECONDS - ELAPSED))
      if [ "$SLEEP_FOR" -ge "$REMAINING" ]; then
        log "rate-limit window (${SLEEP_FOR}s remaining) exceeds remaining budget (${REMAINING}s) — stalling"
        RATE_LIMIT_REVIEW=$(echo "$LATEST" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
        emit_json_and_exit "rate_limit_stalled" 5 "$RATE_LIMIT_REVIEW" 0
      fi
      log "rate-limited; sleeping ${SLEEP_FOR}s (window=${WINDOW_SECONDS}s + ${RATE_LIMIT_BUFFER_SECONDS}s buffer, ${WINDOW_ELAPSED}s already elapsed)"
      sleep "$SLEEP_FOR"
      # Pass the notice's freshness anchor so the cross-run dedupe scan only
      # considers triggers posted for THIS rate-limit window (#829). Checked
      # after the sleep, so a concurrent run's nudge during the wait is seen.
      post_retry_trigger "$COMMENT_FRESH_AT" "$COMMENT_ID"
      RATE_LIMIT_RETRIES=$((RATE_LIMIT_RETRIES + 1))
      continue
      ;;
    paused)
      # Auto-pause (#490 / #485). Re-invoke with `@coderabbitai resume`
      # (NOT a one-shot `review` — that re-pauses after the next push),
      # bounded by max_resume_retries, then resume polling. Distinct from
      # rate_limit (no published wait window; the resume verb differs) and
      # from in_progress (durable, never self-clears).
      #
      # Latch PAUSE_OBSERVED on EVERY pause sighting — including the
      # same-id branch below. If CodeRabbit leaves the SAME durable pause
      # NOTE (unchanged id) the resume budget never advances to the cap, so
      # the loop would otherwise time out exit 4 (advisory) and let
      # agent-review.yml merge past a still-paused PR. With the latch set,
      # emit_timeout converts that timeout into exit 6 / skip_reason=paused.
      PAUSE_OBSERVED=true
      if [ "$COMMENT_ID" = "$LAST_PAUSED_COMMENT_ID" ]; then
        # Same pause NOTE as last iteration — our resume hasn't taken
        # effect yet. Keep polling without re-posting / double-counting.
        log "still inside prior auto-pause (same NOTE id=$COMMENT_ID); sleeping ${POLL_INTERVAL_SECONDS}s"
        sleep_or_timeout "$POLL_INTERVAL_SECONDS"
        continue
      fi
      LAST_PAUSED_COMMENT_ID=$COMMENT_ID

      if [ "$RESUME_RETRIES" -ge "$MAX_RESUME_RETRIES" ]; then
        log "max_resume_retries ($MAX_RESUME_RETRIES) exceeded — CodeRabbit auto-review remains paused (skip)"
        SKIP_REASON="paused"
        PAUSED_REVIEW=$(echo "$LATEST" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
        emit_json_and_exit "paused" 6 "$PAUSED_REVIEW" 0
      fi
      log "CodeRabbit auto-review paused; posting @coderabbitai resume (retry $((RESUME_RETRIES + 1))/$MAX_RESUME_RETRIES) and continuing to poll"
      # Anchor the cross-run dedupe scan to this pause NOTE (#829).
      post_resume_trigger "$COMMENT_FRESH_AT" "$COMMENT_ID"
      RESUME_RETRIES=$((RESUME_RETRIES + 1))
      sleep_or_timeout "$POLL_INTERVAL_SECONDS"
      continue
      ;;
    in_progress)
      log "CodeRabbit review in progress; sleeping ${POLL_INTERVAL_SECONDS}s"
      sleep_or_timeout "$POLL_INTERVAL_SECONDS"
      continue
      ;;
    status_probe)
      log "CodeRabbit status-probe reply is narration, not clearance; sleeping ${POLL_INTERVAL_SECONDS}s"
      sleep_or_timeout "$POLL_INTERVAL_SECONDS"
      continue
      ;;
    review)
      # #875 round 6: a corroborated finished ACTIONS reply is terminality
      # evidence, never a verdict body — the round-5 rule applied to the
      # polling arm. When the newest comment is a finished attestation the
      # rc-0/rc-2 verdict must be decided on the genuine head-anchored
      # summarize-marker summary: with NONE published yet the poll
      # CONTINUES (clearing here would emit rc 0 before a summary that can
      # carry the sole blocking marker, #535, publishes), bounded by the
      # existing max_wait_seconds timeout semantics; and a summary whose
      # ordering places it with a PRIOR head — refreshed before the newest
      # head-pinned review object — is never selected, however recently
      # the wallclock freshness window admitted it.
      VERDICT_SUMMARY_BODY=""
      if comment_states_review_finished "$COMMENT_BODY"; then
        VERDICT_SUMMARY_BODY=$(polling_head_summary_body || true)
        if [ -z "$VERDICT_SUMMARY_BODY" ]; then
          log "finished attestation is the newest comment but no genuine head-anchored summary has published — verdict body missing; sleeping ${POLL_INTERVAL_SECONDS}s"
          sleep_or_timeout "$POLL_INTERVAL_SECONDS"
          continue
        fi
      fi
      POTENTIAL_ISSUES=$(count_potential_issues)
      REVIEW_JSON=$(echo "$LATEST" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
      # #535: the inline count scans only pulls/{pr}/comments. Also honor a
      # PR-level summary-body marker so a finding surfaced solely in the
      # summary body still yields findings instead of false-clearing. On
      # the attestation path the marker is read from the SELECTED summary;
      # otherwise from the newest-body helper as before.
      if [ "$POTENTIAL_ISSUES" -gt 0 ]; then
        log "CodeRabbit review posted with $POTENTIAL_ISSUES Potential issue/⚠️ markers"
        emit_json_and_exit "findings" 2 "$REVIEW_JSON" "$POTENTIAL_ISSUES"
      elif { [ -n "$VERDICT_SUMMARY_BODY" ] && summary_blocking_marker_present "$VERDICT_SUMMARY_BODY"; } \
        || { [ -z "$VERDICT_SUMMARY_BODY" ] && summary_body_has_potential_issue_marker; }; then
        log "CodeRabbit review posted with 0 inline markers but a Potential issue/⚠️ marker in the PR-level summary body — findings"
        emit_json_and_exit "findings" 2 "$REVIEW_JSON" "$POTENTIAL_ISSUES"
      else
        log "CodeRabbit review posted with no high-severity markers — cleared"
        emit_json_and_exit "cleared" 0 "$REVIEW_JSON" 0
      fi
      ;;
  esac
done
