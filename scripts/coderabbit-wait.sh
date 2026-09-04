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
#              dispositions, reported as `potential_issue_count: 1` — since
#              #1178 including one masked by a rate-limit stanza written
#              into that same body); rc 7
#              means not yet. Equivalent to
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
#   4. On rate_limit: parse "X minutes and Y seconds" (or "X seconds") into a
#      window, sleep the portion of it that REMAINS after subtracting the time
#      already elapsed since the notice was posted (#727 — the window runs from
#      the notice's post time, not from when this helper first sees it), + 30s
#      buffer, then post `@coderabbitai, try again.`, increment the retry
#      counter, and continue polling. An already-expired window sleeps 0.
#      A notice whose PUBLISHED window is still open reaches this arm even
#      after it has aged past the wall-clock freshness floor (#891/#912): the
#      floor exists to stop a STALE notice blocking a current head, and a
#      notice's staleness is not evidence that the limit it announces lifted.
#      CodeRabbit's observed windows (59 min) outrun the default 1800s floor.
#   4b. On paused: post `@coderabbitai resume` (a one-shot `review`
#      re-pauses after the next push, so resume is the correct verb),
#      increment a resume-retry counter, and continue polling. If
#      resume_retries > max_resume_retries: exit 6 (SKIPPED) with
#      status=paused and skip_reason=paused so the caller can raise
#      `auto_pause_after_reviewed_commits` or intervene.
#   5. On review (non-rate-limit, non-in-progress): emit JSON, exit 0.
#      Also grades inline diff comments with the shared `coderabbit_tier_of`
#      classifier (scripts/lib/feedback-policy-helpers.sh) and surfaces the
#      blocking (p0/p1) count in the JSON so callers can decide (#837).
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
#       # The StatusContext fast path emits the synthetic
#       # "status_context" endpoint, where there is no GitHub review object:
#       # `id` is null and `created_at` is the STATUS' own creation time,
#       # never the synthesis time (#912) — a verdict off a status that has
#       # sat untouched for 40 minutes must not read as current. The
#       # synthesis time is carried separately as `observed_at`, emitted on
#       # that endpoint only.
#       "observed_at": "<iso-8601>",
#       "endpoint": "issues" | "pulls" | "reviews" | "status_context",
#       # "reviews" evidence only (#869, additive): the object's own
#       # submitted_at — the same instant created_at carries on that
#       # endpoint, named explicitly so the Phase 4b barrier's temporal
#       # conjunct (probe.context_updated_at at-or-after this) reads a
#       # field whose meaning cannot drift with the endpoint. The object is
#       # the newest head-pinned review RUN, never a body-less review object
#       # created for a conversational thread reply (#900) — a reply refreshes
#       # no status, so anchoring the conjunct on one made it unsatisfiable.
#       "submitted_at": "<iso-8601>",
#       "body_excerpt": "<first 200 chars>"
#     },
#     # Count of unaddressed inline findings on HEAD that the shared
#     # `coderabbit_tier_of` classifier grades BLOCKING (its p0/p1 rungs:
#     # 🟠 Major, Potential issue, ⚠️). Same classifier the required gate
#     # scripts/coderabbit-severity-gate.sh uses, so the advisory count and the
#     # blocking gate read one vendor format (#837).
#     #
#     # On a `--probe` run this is NOT a findings verdict (#834): a probe never
#     # counts inline findings, so the value is 0 on every probe terminal
#     # EXCEPT the one verdict probe mode makes — the summary-only blocking
#     # marker below, which emits status `findings`, rc 2, and the literal
#     # count 1 standing for that single summary-carried finding.
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
#       #
#       # Two of these values do not require a comment inside the wall-clock
#       # freshness window. `rate_limit` is also emitted when CodeRabbit's
#       # newest comment is a rate-limit notice whose PUBLISHED window has not
#       # expired, however old the notice is (#891/#912) — otherwise the
#       # observation flipped `rate_limit` → `none` with no provider-side
#       # change, purely because a clock advanced. `in_progress` is also
#       # emitted when the per-SHA StatusContext reads exactly `pending` on a
#       # head that would otherwise be terminal (#919), because a run that is
#       # underway makes the published artifacts activity rather than a
#       # finished review.
#       "observed": "none" | "rate_limit" | "paused" | "in_progress"
#                   | "summary-without-head-review" | "awaiting-summary"
#                   | "terminal",
#       # `paused` is reported from TWO surfaces (#857): the head-anchored
#       # triage, and — when the anchor has moved past the notice after a fix
#       # push — the anchor-free summarize comment, whose evidence carries the
#       # pause note's id so the Phase 4b barrier's #847 resume path can key on
#       # it. rate_limit and in_progress stay anchored: an ancient window or a
#       # transient marker must not decline the trigger forever.
#       # The per-SHA CodeRabbit StatusContext state on the HEAD
#       # (success|failure|pending|error|missing), sampled ONLY when the
#       # rc-7 verdict carries a HEAD-pinned review object (endpoint
#       # "reviews") and trust_status_context_for_clearance is true; null
#       # otherwise (#869). The Phase 4b barrier requires "success" here
#       # before counting rc-7 review-object evidence as reported: a bare
#       # just-posted review object can precede a PR-level summary that
#       # carries the ONLY blocking marker (#535), and the per-SHA success
#       # is what discriminates the wedged-but-complete #866 state from
#       # that mid-publication one.
#       # `missing` means the surface was read and CodeRabbit published no
#       # status; `unreadable` means the read itself failed and nothing was
#       # observed (#936). The barrier opens only on "success", so both hold
#       # it closed — they are kept apart so its input never reports an
#       # absence it did not actually observe.
#       "context_state": null | "success" | "failure" | "pending"
#                        | "error" | "missing" | "unreadable",
#       # The refresh time of that same status, sampled and nulled
#       # together with context_state. The barrier additionally requires
#       # this to be at-or-after the evidence object's submitted_at
#       # (emitted as review.submitted_at on the rc-7 reviews-endpoint
#       # evidence): on a same-SHA rerun the statuses endpoint still
#       # exposes the PREVIOUS run's success while the new object's
#       # summary and status refresh are pending, and a success predating
#       # the object belongs to a different run.
#       "context_updated_at": null | "<iso-8601>"
#     },
#     "codex_failover_requested": true | false,
#     "waited_seconds": N
#   }
#
# The StatusContext fast path (`trust_status_context_for_clearance: true`)
# short-circuits the poll when CodeRabbit has already published a per-SHA
# success. Three things must hold before it clears, because `state: success`
# alone means neither "reviewed" nor "clean":
#   - the status' own `description` must name a COMPLETED review. CodeRabbit
#     publishes its rate-limited state AS a success and says so only there
#     ("Review rate limited"), so a success with a refusal description — or any
#     description this helper does not recognize — is not clearance
#     (#891/#897/#912).
#   - no CodeRabbit comment may contradict it: a rate_limit / paused /
#     in_progress notice near or after the status (#446/#596/#599), or a
#     rate-limit notice whose published window has not expired (#891/#912).
#   - neither the inline findings on the SHA nor the head-anchored PR-level
#     summary may carry a blocking marker (#224/#837, and #877 for the
#     summary-only surface the fast path used to skip).
#
# Exit codes:
#   0   CodeRabbit posted a real review on current HEAD and nothing on it
#       grades P0/P1-equivalent under the shared `coderabbit_tier_of`
#       classifier. Safe to proceed.
#   2   CodeRabbit posted a real review carrying at least one P0/P1-equivalent
#       finding — an inline finding, or one carried solely by the PR-level
#       summary (#535). Caller should address before proceeding.
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
#       exists, or the summarize comment is head-pinned and completed (#851).
#       It does NOT mean "no findings". rc 2 is the ONE verdict probe mode
#       makes, unchanged in meaning (#535): a blocking marker carried solely
#       by the PR-level summary, which no required gate dispositions. Since
#       #1178 it also fires when that marker is MASKED by a rate-limit stanza
#       CodeRabbit wrote into the same comment: classify_comment is
#       marker-first, so such a body reads `rate_limit` and short-circuits
#       before the summary scan — and `observed: "rate_limit"` is a class the
#       Phase 4b barrier may now OPEN on, so a bare refusal has to mean there
#       is nothing unread sitting behind it.
#       `potential_issue_count` carries no verdict on a probe run: 0 on every
#       probe terminal except that rc-2 one, where it is the literal 1 of the
#       summary-carried finding rather than a scan of the inline surface. Use
#       the polling mode for a verdict.
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

# Shared finding-severity classifier (#576). Hard-required for the same reason
# reviewers-helpers is: since #837 the potential-issue COUNTING path grades
# findings with `coderabbit_tier_of` — the one classifier
# scripts/coderabbit-severity-gate.sh already uses — instead of this script's
# own `Potential issue`/⚠️ grep, which missed CodeRabbit's current severity-badge
# format and reported `cleared` on a 🟠 Major finding. A missing lib would
# degrade every count to a crash-or-zero, i.e. back to the false clearance this
# helper exists to prevent, so it must error rather than fall back. The lib is
# `type: canonical, consumers: all` in .mergepath-sync.yml, so every consumer
# already carries it.
if [ ! -r "$__CODERABBIT_WAIT_DIR/lib/feedback-policy-helpers.sh" ]; then
  echo "ERROR: feedback-policy-helpers missing: $__CODERABBIT_WAIT_DIR/lib/feedback-policy-helpers.sh" >&2
  exit 3
fi
# shellcheck source=lib/feedback-policy-helpers.sh
. "$__CODERABBIT_WAIT_DIR/lib/feedback-policy-helpers.sh"

# The ONE CommonMark fence reader (#1178 round 5). HARD-sourced, beside its
# siblings and through the same resolved dir: the range predicates below read
# UNFENCED text only, and a missing lib must stop the script rather than let
# them silently degrade to a whole-body match — the fail-open shape that let a
# QUOTED `between X and Y` suppress a real finding.
if [ ! -r "$__CODERABBIT_WAIT_DIR/lib/coderabbit-fence.sh" ]; then
  echo "ERROR: coderabbit-fence missing: $__CODERABBIT_WAIT_DIR/lib/coderabbit-fence.sh" >&2
  exit 3
fi
# shellcheck source=lib/coderabbit-fence.sh
. "$__CODERABBIT_WAIT_DIR/lib/coderabbit-fence.sh"

# Shared paginated-list reader (#1008). Owns the fetch → capture → flatten
# algorithm the two wrappers below used to carry inline, so a correctness fix
# to it lands once instead of eight times. Hard-required for the same reason
# the three libs above are: every sensing read on this path routes through it,
# and the degraded mode (an undefined function) is a `command not found` on the
# very reads whose failure contract #831/#965 exist to keep honest.
if [ ! -r "$__CODERABBIT_WAIT_DIR/lib/gh-api-array.sh" ]; then
  echo "ERROR: gh-api-array helper missing: $__CODERABBIT_WAIT_DIR/lib/gh-api-array.sh" >&2
  exit 3
fi
# shellcheck source=lib/gh-api-array.sh
. "$__CODERABBIT_WAIT_DIR/lib/gh-api-array.sh"

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

# #888: the flag scan above is LEADING-only, so a flag written after the PR
# number is not a flag — it is the REPO positional. `coderabbit-wait.sh 884
# --probe` therefore ran a full POLLING wait against the repo named `--probe`
# and died with a confusing `failed to fetch PR metadata: 404`. A repo name
# cannot begin with `-`, so rejecting that shape turns the 404 into a usage
# error that names the working form. The leading-flag design itself is
# deliberate (it avoids a bash 3.2 empty-array hazard under `set -u` and keeps
# every existing `<PR> [REPO]` caller working); only the mis-read is fixed.
case "${2:-}" in
  -*)
    echo "ERROR: REPO must be 'owner/repo'; got the flag-shaped argument '$2'." >&2
    echo "       Options are leading-only — write '$0 --probe <PR_NUMBER> [REPO]'." >&2
    echo "Usage: $0 [--probe] <PR_NUMBER> [REPO]" >&2
    exit 3
    ;;
esac

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
# Additive tier-awareness layered ON TOP of the binary blocking-finding
# detector — it NEVER replaces the exit-code fast-paths below (HEAD-anchoring,
# rate-limit, auto-pause). When the feedback_policy block is PRESENT, this
# surfaces a `blocking_tier_unresolved` count (findings on HEAD whose
# coderabbit_tier_of tier is in the resolved required set) in the emitted JSON.
# When the block is ABSENT, BLOCKING_TIER_UNRESOLVED stays `null` and the
# exit-code contract is byte-identical to before: surfacing is best-effort, not
# a gate. The classifier itself is hard-sourced at the top of this script
# (#837) — the binary count depends on it — so only the CONFIG block presence
# is conditional here.
#
# NOTE: the merge-BLOCKING CodeRabbit gate is scripts/coderabbit-severity-gate.sh
# (a required check); this helper only REPORTS the count so the authoring
# agent can prioritize, mirroring codex-review-request.sh's per-finding
# `blocking` flag. It does not itself block.
BLOCKING_TIER_UNRESOLVED="null"
FEEDBACK_POLICY_PRESENT=false
if [ -f "$CONFIG" ] && grep -qE '^feedback_policy:' "$CONFIG"; then
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

# Paginated array read. RETURNS 3 on failure; it cannot abort its caller.
#
# The contract used to be written as `die 3`, and that wording was the whole of
# #831. `die` runs `exit`, but every call site is a command substitution, so
# the exit killed only that subshell: the wrapping helper resumed with an empty
# string and its own status 0, and a caller that infers "no results" from
# emptiness read a failed API call as a confident negative — "an outage
# manufacturing a clean verdict". It was patched one helper at a time — #590,
# then three more found in a single review round on #823, then #936 — before
# the contract itself was corrected here.
#
# `return` is not a weaker `die`; it is the SAME signal, honestly named. The
# status is identical to the one the subshell exit produced, so a top-level
# `VAR=$(fetch_api_array …)` still trips `set -e` and still leaves the script
# with status 3. What changes is that the source no longer claims a power it
# does not have, so nobody can read a call site as safe because "it dies".
#
# The obligation this puts on callers is unconditional: check the status, at
# EVERY call site. Inside a function it is the only signal there is — errexit
# is suspended for the whole body of a function invoked in a condition, an
# OR-list, or a command substitution, which is how every wrapper below is
# reached. Use `|| return`/`|| die` explicitly rather than relying on the
# caller's context, or use fetch_api_array_best_effort when an unreadable
# surface genuinely is not fatal.
#
# The algorithm itself lives in scripts/lib/gh-api-array.sh (#1008); what
# stays here is this file's failure ACTION, which is the part that genuinely
# differs between consumers. `gh_api_array` is called DIRECTLY (not in a
# nested command substitution), which is what lets its diagnostic reach this
# wrapper through GH_API_ARRAY_* even when the wrapper itself is invoked from
# inside `VAR=$(fetch_api_array …)`.
fetch_api_array() {
  gh_api_array "$1" "$2" || {
    log "ERROR: $GH_API_ARRAY_ERROR"
    return 3
  }
}

# The best-effort twin. Its contract is deliberately DIFFERENT — rc 1, not
# rc 3 — because its callers treat an unreadable surface as non-fatal rather
# than as an infra failure, and collapsing the two statuses would hand those
# callers the fatal one. It keeps each of its own message forms, which is why
# gh_api_array reports WHICH step failed rather than only that one did.
#
# The `shape` arm (#967) forwards the lib's composed message verbatim rather
# than re-phrasing it: that diagnostic names the endpoint and the shape
# received, and neither is reconstructible from GH_API_ARRAY_DETAIL — which is
# gh's stderr and is EMPTY on this path, because the read itself succeeded.
fetch_api_array_best_effort() {
  gh_api_array "$1" "$2" || {
    if [ "$GH_API_ARRAY_ERROR_KIND" = "flatten" ]; then
      log "best-effort fetch failed to flatten $2 pagination output"
    elif [ "$GH_API_ARRAY_ERROR_KIND" = "shape" ]; then
      log "best-effort fetch refused $GH_API_ARRAY_ERROR"
    else
      log "best-effort fetch failed for $2: $GH_API_ARRAY_DETAIL"
    fi
    return 1
  }
}

# BEGIN coderabbit_status_description_helpers
# True when a CodeRabbit StatusContext `success` may be trusted as CLEARANCE,
# judged by the status' own `description` string. Pure: no globals, no I/O —
# extracted by sentinel and sourced directly by
# tests/test_coderabbit_wait_statuscontext_ratelimit.sh.
#
# #891 / #897 / #912 are ONE defect filed three times from three sessions:
# `state: success` does not mean "reviewed". CodeRabbit publishes its
# rate-limited state AS a success status and carries the truth only in the
# description. The observed vocabulary, from the three live captures:
#
#   success | Review completed      a run finished        (#912, af8496f @03:06:48Z)
#   success | Review rate limited   NO review ran         (#897 c00abf0, #891 f0198d9,
#                                                          #912 af8496f)
#   pending | Review in progress    a run is underway     (#897, #919)
#   pending | Review queued         a run is queued       (#897)
#
# Only `success` ever reaches the fast path, so the discriminator that matters
# is between the first two. `emit_status_context_verdict` already knows success
# means "completed, not clean" (#224) and scans inline findings before
# clearing — but a rate-limited head has zero inline findings for the trivial
# reason that nothing was scanned, so the finding scan cannot tell it from a
# genuinely clean review.
#
# The test is POSITIVE — clear only on a description that names a completed
# review. A deny-list of the known refusal wordings goes blind the moment
# CodeRabbit renames one, and "the guard had no scope over a wording it had
# never seen" is precisely the #891/#912 defect. An unrecognized NON-empty
# description therefore suppresses the fast path, and the wait falls through to
# the comment-driven poll that reaches its own verdict.
#
# The one escape is an EMPTY description, which is permitted. That is not a
# hole: `description` is optional metadata in the statuses API, every observed
# false clear carries a non-empty one, and refusing an empty description would
# disable the fast path for any status posted without one — while the fast path
# is what keeps a clean fix-up push from burning the whole poll budget (#221).
# A liveness cost paid on a shape that has never false-cleared is the wrong
# trade.
#
# The permitted wordings are an EXACT allowlist over the normalized string, not
# a substring or prefix match (Codex P1 on #936). `*"review complete"*` read
# "names a completed review" off any description CONTAINING that phrase, and
# three wordings contain it while meaning the opposite or less:
#
#   No review completed        the review did NOT happen
#   Review completely skipped  the review did NOT happen
#   Review complete — 0 files reviewed   (a prefix-anchored fix accepts this too)
#
# A guard whose whole job is to reject descriptions that deny a completed review
# cannot be satisfied by a longer wording that embeds one. Exactness is what
# makes the doctrine above hold in both directions: only a description that IS
# one of the completed-review wordings clears, and every other non-empty string
# — refusal, pending, extended, or unseen — falls through to the comment-driven
# poll. The set is small and vendor-published, so enumerating it costs nothing;
# a wording CodeRabbit adds later suppresses the fast path until it is added
# here, which is a liveness cost on the safe side.
#
# Normalization is case and SURROUNDING whitespace only — transport noise, not
# vocabulary. A whitespace-only description normalizes to empty and takes the
# empty-description escape above, since it is indistinguishable from an absent
# field. Nothing else is stripped: trailing punctuation or an appended clause
# makes the string a wording nobody has shipped, which is exactly the case the
# positive test is meant to refuse.
crw_status_description_permits_clearance() {
  local desc=${1:-} lower
  lower=$(printf '%s' "$desc" | tr '[:upper:]' '[:lower:]')
  # Bash 3.2 trim: strip the leading, then the trailing, whitespace run.
  lower="${lower#"${lower%%[![:space:]]*}"}"
  lower="${lower%"${lower##*[![:space:]]}"}"
  [ -n "$lower" ] || return 0
  case "$lower" in
    "review complete"|"review completed") return 0 ;;
  esac
  return 1
}
# END coderabbit_status_description_helpers

# Fetch the CodeRabbit `StatusContext` check on the current HEAD SHA.
# Emits compact JSON with:
#   { "state": "success|failure|pending|error|missing|unreadable",
#     "created_at": "...", "updated_at": "...", "description": "..." }
#
# `missing` is a POSITIVE OBSERVATION: the statuses surface was read and
# CodeRabbit has published no status on this head. `unreadable` is the
# absence of an observation: the fetch or the parse failed and we know
# nothing. Keeping them apart is the whole point of this record (#936).
#
# They used to be the same value, and for every consumer that existed at
# the time that was harmless — each one acts only on `success`, so a
# failed read fell through to the comment-driven path, which is the
# conservative direction. The #919 `pending` gate is the first consumer
# for which the two have different correct answers: it blocks on exactly
# `pending`, so a transient read failure read as "not pending", the probe
# emitted `reported`, and the Phase 4b barrier could open on
# pre-completion artifacts (Codex P1 on #936). A failed read is not
# evidence that a run has finished.
#
# Read every consumer's state through crw_status_record_state below rather
# than a bare `jq -r '.state'`: under `set -e` suppression inside an `if`
# condition a failed record read collapses to an EMPTY string, which is
# equally not-`pending` and equally permissive. The helper maps every
# unusable shape onto `unreadable` so no consumer can silently inherit a
# permissive default.
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
#
# The record emitted when the statuses surface could not be read or parsed.
# Same shape as every other record so consumers need no special case beyond
# the state value itself.
CRW_STATUS_RECORD_UNREADABLE='{"state":"unreadable","created_at":"","updated_at":"","description":""}'

check_status_context_record() {
  # Pagination (CodeRabbit ⚠️ Minor @ line 267 on PR #224 round 2):
  # `/commits/{ref}/statuses` defaults to per_page=30 and returns
  # statuses in reverse chronological order. Without `--paginate`, a
  # commit with >30 statuses (e.g., long-running PR with retries)
  # could miss the latest CodeRabbit entry in the unpaginated first
  # page if non-CodeRabbit statuses crowd it out. `--paginate` plus
  # `jq -s 'add // []'` flattens all pages into a single array before
  # the context+creator filter runs.
  # `updated_at` (#869 barrier corroboration, additive): the newest status'
  # refresh time, sampled by the probe's rc-7 review-object branch into
  # probe.context_updated_at so the Phase 4b barrier can require the
  # success to be at-or-after the review object it corroborates. The REST
  # API cannot update a commit status in place — each run POSTs a new
  # status object — so updated_at and created_at coincide in practice; the
  # `// .created_at` fallback keeps the field meaningful if a proxy strips
  # one of them.
  #
  # `description` (#891/#897/#912): CodeRabbit publishes its own disqualifier
  # in this field. `state: success` does NOT mean "reviewed" — it also means
  # "I am not reviewing this head at all", and the only place that says so is
  # the description string `Review rate limited`. Carried here so
  # crw_status_description_permits_clearance can read it at the fast path.
  #
  # The gh DIAGNOSTIC is captured and logged (#963). It used to go to
  # `2>/dev/null`, so a 401, a 403, a 5xx, a secondary rate limit and a DNS
  # failure all collapsed into the same silent `unreadable` record. That cost
  # nothing while an unreadable statuses read merely fell through to the
  # comment-driven poll; #936 made it consequential —
  # `crw_probe_head_review_in_progress` exits rc 3 on it and
  # `p4b_barrier_class_coderabbit` classes rc 3 as `escalate`, which pages a
  # human — so the one reader who now needs the cause was the one who could not
  # see it.
  #
  # `fetch_api_array`'s `2>&1` cannot be copied verbatim here, which is the
  # whole reason this was filed separately: that form merges gh's error text
  # into the stdout stream, and this call's stdout is the JSON `jq` parses.
  # Splitting the pipeline is what makes the capture possible — the fetch and
  # the flatten become two status-checked steps with stderr routed to a temp
  # file, so `jq` only ever sees the response body. The split is also a
  # diagnostic gain on its own: a transport failure and a malformed page now
  # report as different things instead of one shrug.
  #
  # A missing `mktemp` costs the detail, never the verdict: the status checks
  # below decide, and they are unaffected. Same posture as
  # scripts/lib/gh-api-scalar.sh.
  local resp out raw rc=0 err_file="" detail=""
  err_file=$(mktemp "${TMPDIR:-/tmp}/crw-statuses-err.XXXXXX" 2>/dev/null) || err_file=""
  if [ -n "$err_file" ]; then
    raw=$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/statuses" 2>"$err_file") || rc=$?
    detail=$(tr '\n' ' ' <"$err_file" 2>/dev/null || true)
    rm -f "$err_file"
  else
    raw=$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/statuses" 2>/dev/null) || rc=$?
    detail='(stderr not captured: mktemp unavailable)'
  fi
  if [ "$rc" -ne 0 ]; then
    log "ERROR: failed to read the CodeRabbit StatusContext statuses on $HEAD_SHA (gh rc=$rc): $detail"
    printf '%s\n' "$CRW_STATUS_RECORD_UNREADABLE"
    return
  fi
  resp=$(printf '%s' "$raw" | jq -s 'add // []' 2>/dev/null) || {
    log "ERROR: failed to flatten the statuses pagination output on $HEAD_SHA — the statuses surface is UNREAD"
    printf '%s\n' "$CRW_STATUS_RECORD_UNREADABLE"
    return
  }
  # The filter's own failure is the second half of the same hazard: a
  # malformed page that survives `add // []` but breaks this expression used
  # to emit NOTHING, and an empty record reads as not-`pending` just as
  # permissively as the old `missing` did.
  out=$(printf '%s' "$resp" | jq -c --arg bot "$BOT_LOGIN" '
    [ .[]?
      | select(.context == "CodeRabbit")
      | select((.creator.login // "") == $bot)
    ]
    | sort_by(.created_at)
    | last
    | if . == null then
        {state: "missing", created_at: "", updated_at: "", description: ""}
      else
        {state: (.state // "missing"), created_at: (.created_at // ""),
         updated_at: (.updated_at // .created_at // ""),
         description: (.description // "")}
      end
  ' 2>/dev/null) || {
    printf '%s\n' "$CRW_STATUS_RECORD_UNREADABLE"
    return
  }
  if [ -z "$out" ]; then
    printf '%s\n' "$CRW_STATUS_RECORD_UNREADABLE"
    return
  fi
  printf '%s\n' "$out"
}

# The single reader for a check_status_context_record record (#936).
#
# A well-formed record's state passes through verbatim — this does NOT
# second-guess GitHub's status vocabulary, so a state the API adds later is
# reported as itself rather than masked. Everything that is not a usable
# observation — an empty string, a non-object, unparseable JSON, a missing or
# non-string `.state` — reads `unreadable`. That is the one value every
# consumer below is required to treat as "no observation", never as a
# permissive default.
crw_status_record_state() {
  local rec=${1:-} state
  state=$(printf '%s' "$rec" | jq -r '
    if type == "object" and (.state | type) == "string" and (.state | length) > 0
    then .state else "unreadable" end
  ' 2>/dev/null) || state="unreadable"
  [ -n "$state" ] || state="unreadable"
  printf '%s' "$state"
}

check_status_context() {
  crw_status_record_state "$(check_status_context_record)"
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
# Stated, not left to errexit: this one IS a top-level assignment, so `set -e`
# would abort here anyway — but writing the check makes the file uniform, so a
# reader never has to work out which fetch_api_array call sites are protected
# by their context and which carry their own guard (#831).
TIMELINE_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/timeline" "PR timeline") \
  || die 3 "failed to read the PR timeline for the force-push freshness anchor"
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
# or a blocking p0/p1 finding (exit 2), both handled exactly as before; a
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

# BEGIN coderabbit_comment_classifier
# Classify a CodeRabbit comment body. Emits one of:
#   rate_limit | paused | in_progress | status_probe | review
#
# Pure: string predicates over the passed body, reading only the marker
# constants above. No globals beyond those and no I/O — extracted by sentinel
# and sourced directly by tests/test_coderabbit_wait_status_probe.sh, the same
# pattern as the coderabbit_summary_helpers block below.
#
# EVERY predicate below is fed by HERE-STRING, never through a pipe (#1005).
# `set -o pipefail` is on and `grep -q` exits the instant it matches, so in
# `producer | grep -q PATTERN` a body larger than the platform's pipe buffer
# (64 KiB on both Linux and macOS) whose match sits near the START leaves the
# producer still writing when grep returns: it takes SIGPIPE and the PIPELINE
# reports 141, i.e. the predicate answers "no match" on a body that plainly
# matches. Measured on the pre-fix idiom at 245894 bytes: `printf '%s' "$body"
# | grep -Fqi "$RATE_LIMIT_MARKER"` returned 141 with the marker on line 1,
# while the here-string form returned 0.
#
# The direction is what makes this ladder a false-CLEAR rather than a stall,
# unlike the two summary predicates #995 corrected. A false negative here drops
# a body OUT of rate_limit / paused / in_progress and into the `review` default
# — the one class whose arm can emit a clearance — so a rate-limited, paused or
# mid-review CodeRabbit reads as a completed clean report. `summary_names_head`
# and `summary_names_only_other_head` below carry the same correction; this
# block is the rest of the #1005 sweep.
classify_comment() {
  local body=$1
  # #593: key on the stable auto-generated marker FIRST, before any prose
  # match, so a rate-limit notice is recognized regardless of CodeRabbit's
  # user-facing wording ("Rate limit exceeded" vs "Review limit reached" /
  # "Fair Usage Limits"). Fixed-string grep (-F) so the literal dots in
  # "coderabbit.ai" are not treated as regex wildcards, mirroring PAUSED_MARKER.
  if grep -Fqi "$RATE_LIMIT_MARKER" <<<"$body"; then
    echo "rate_limit"
    return
  fi
  # Legacy prose fallback: the original notice text, retained so a notice that
  # somehow lacks the marker (or an older cached body) still classifies.
  if grep -qiE 'rate[- ]limit exceeded' <<<"$body"; then
    echo "rate_limit"
    return
  fi
  # Auto-pause (#490 / #485): the "Reviews paused" NOTE carries a stable
  # auto-generated marker. Match the marker with a fixed-string grep so the
  # literal dots in "coderabbit.ai" are not treated as regex wildcards.
  # Checked before in_progress/review so the durable pause is never mistaken
  # for a slow review.
  if grep -Fqi "$PAUSED_MARKER" <<<"$body"; then
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
  if grep -Fqi "$IN_PROGRESS_MARKER" <<<"$body"; then
    echo "in_progress"
    return
  fi
  # CodeRabbit's free-form command replies, including
  # `@coderabbitai, how is the review going?`, are narration. They
  # summarize current state and may mention open threads, but they are
  # not a review on HEAD and must never clear the #136 freshness gate.
  if grep -qiE 'CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits' <<<"$body"; then
    echo "status_probe"
    return
  fi
  if grep -qiE 'review in progress|currently reviewing|commits? under review' <<<"$body"; then
    echo "in_progress"
    return
  fi
  # The `review` default is deliberate, and it is only safe because NO CALLER
  # MAY REACH IT WITH AN UNREAD BODY (#957 acceptance criterion 3).
  #
  # This is a pure classifier over a body a caller has already obtained. It has
  # no way to tell "" apart from a body CodeRabbit really wrote that matches no
  # marker, so it cannot itself distinguish absence from failure — and `review`
  # is the right answer for the case it CAN see, because CodeRabbit's ordinary
  # terminal report matches none of the markers above (the two live bodies in
  # #880/#849 open with a bare `<details>`). Making the default `unknown`
  # instead would move the fail-open from here to every arm's `case`, where a
  # new class silently falls through: it relocates the hazard rather than
  # removing it.
  #
  # What made the default dangerous was the READERS, not the ladder: a failed
  # `issues/{pr}/comments` read used to hand the poll loop an empty body, which
  # graded `review` — the one class whose arm can emit a clearance — so a dead
  # API did not stall the loop, it ADVANCED it to a verdict (#957, captured
  # live on #936 head d361075). Every reader that feeds this function now
  # reports an unreadable surface as rc 3 with nothing on stdout
  # (`fetch_api_array` #831/#965, `latest_comment_from_issue_comments` and
  # `newest_bot_comment_from_issue_comments` #959), and every caller checks it,
  # so `""` no longer arrives here from a failed read at all.
  echo "review"
}
# END coderabbit_comment_classifier

# #1005 sweep record. Every `grep -q…` in this file that grades a COMMENT BODY
# is now fed by here-string; the remaining pipelines are recorded here with the
# reason they are out of scope, so the next reader does not have to re-derive
# which ones matter:
#
#   - classify_comment's six marker/prose predicates and
#     `status_context_fast_path_blocked_by_comment`'s HEAD-reference test —
#     FIXED above and below. All seven grade a body a caller fetched from the
#     API, which is unbounded and routinely large.
#   - `summary_names_head` / `summary_names_only_other_head` — fixed in #995.
#   - the base-branch pattern test (`printf '%s\n' "$PR_BASE_REF" | grep -Eq`)
#     — the producer is a single ref NAME, bounded by git's own
#     `check-ref-format` limits and orders of magnitude under the 64 KiB pipe
#     buffer, so the producer has always finished before grep can leave. Its rc
#     is captured explicitly rather than tested, so a 141 would be visible as a
#     third value rather than silently read as "no match".
#
# The six sibling scripts named in #1005 AC3 were swept too:
#   - `codex-review-check.sh` — its one body-grading predicate
#     (`^Authoring-Agent:` over `$PR_BODY`) is ALREADY a here-string; #283 r3
#     found and fixed this exact shape there, and the reasoning is preserved in
#     that file's comment block.
#   - `coderabbit-severity-gate.sh` and `merge-clearance-gate.sh` — their
#     `echo "$PR_NUMBER" | grep -qE '^[0-9]+$'` argument validators grade a
#     command-line integer, not a body.
#   - `merge-clearance-gate.sh`'s `printf '%s' "$contexts" | grep -Fxq` grades a
#     locally-built newline list of required-check NAMES (single digits of
#     entries), not an API body; and a false negative there returns 1 from the
#     enforcement probe, which is the fail-closed direction.
#   - `coderabbit-record-feedback.sh`, `codex-record-feedback.sh` and
#     `codex-review-request.sh` — no `grep -q` pipeline at all.
#   - `scripts/lib/feedback-policy-helpers.sh` — its one `grep -qE` reads a
#     FILE, so there is no producer process to signal.

# BEGIN coderabbit_summary_helpers
# Pure string predicates over a CodeRabbit summary body. No globals beyond the
# constants defined above, no I/O — extracted by sentinel and sourced directly
# by tests/test_coderabbit_wait_status_probe.sh, the pattern
# tests/test_audit_branch_protection.sh already uses. Their only external
# dependency is the shared `coderabbit_tier_of` ladder in
# scripts/lib/feedback-policy-helpers.sh (#837), which the extracting test
# sources alongside this block.

# True when a body classifies as a BLOCKING CodeRabbit finding: the p0/p1 rungs
# of the shared `coderabbit_tier_of` ladder (CodeRabbit never maps to p0 today;
# both are named so a future lib change cannot silently downgrade one).
#
# This is the whole of #837. The counting path used to key on a private
# `grep -iE 'Potential issue|⚠️'`, which CodeRabbit's current finding format no
# longer satisfies: a Major security finding renders as the severity-badge
# prefix `_🔒 Security & Privacy_ | _🟠 Major_ | _⚡ Quick win_` and carries the
# machine tag `cr-indicator-types:potential_issue`, but no literal
# "Potential issue" / ⚠️ text — so the count came back 0 and the wait reported
# `cleared` on a blocking finding (observed live on #835). The shared
# classifier already reads `🟠 Major`, and scripts/coderabbit-severity-gate.sh
# — the REQUIRED gate — already classifies through it. Routing this path
# through the same function means the advisory count and the blocking gate read
# one vendor format, and a future format drift is fixed in one place.
#
# Two consequences of adopting the shared contract, both deliberate:
#   - it is case-SENSITIVE where the old grep was case-insensitive. CodeRabbit
#     emits the title-case marker, and agreeing byte-for-byte with the required
#     gate is the point of the change.
#   - it grades the first 600 chars of what it is given (the lib's documented
#     anchor — the badge sits at the top of a finding), so callers pass one
#     finding body, or one line of a multi-finding summary, never a whole
#     multi-finding document.
crw_body_is_blocking_finding() {
  case "$(coderabbit_tier_of "${1:-}")" in
    p0|p1) return 0 ;;
  esac
  return 1
}

# True when ANY line of the given scan classifies as a blocking finding.
#
# LINE-wise, not body-wise, because a PR-level summary is a document holding
# many finding stanzas: the ladder answers "what tier is THIS finding", so the
# summary is fed to it one line at a time — which is also the granularity at
# which CodeRabbit renders the badge. Blank lines are skipped; they cannot
# carry a marker.
crw_scan_has_blocking_marker() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if crw_body_is_blocking_finding "$line"; then
      return 0
    fi
  done <<< "${1:-}"
  return 1
}

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
#
# The body is fed to grep by HERE-STRING, never through a pipe (Codex P1 on
# #995). `set -o pipefail` is on, and `grep -q` exits the instant it matches:
# on a body larger than the platform's pipe buffer whose range line is near
# the start, the producer is still writing when grep leaves, takes SIGPIPE,
# and the pipeline reports 141. Reproduced at 200 KiB: the predicate answers
# "no match" on a body that plainly matches. Its two callers both take that
# answer in the SAFE direction — this one only ever declines to clear — but
# `summary_names_only_other_head` below does not, so the idiom is corrected in
# both rather than left to be re-derived from which caller happens to read it.
# UNFENCED text only, through the shared CommonMark reader (#1178 round 5).
#
# Arity note: the gate's copy of this predicate carries a THREE-rung contract
# (rc 3 = "I could not read this body"), and its comment records that flattening
# rc 3 into rc 1 was itself a defect. This copy stays 0/1, and that is safe only
# because an unreadable body flattens to "names no range", which
# summary_names_only_other_head turns into `escalate` — the fail-closed
# direction. Anyone unifying the two predicates must preserve that sign: the `!`
# at the demotion's call site inverts a wrong-branch non-zero into a SUPPRESS.
# Asserted below rather than left to inspection.
# The severity gate's copy of this predicate was hardened for exactly this on
# #886 — a `between X and Y` string CodeRabbit was merely QUOTING from a diff is
# enough to make a stale summary read as the current head's report — and this
# copy was left on a raw whole-body grep. The divergence was latent until a new
# consumer read it in a fail-OPEN direction; both copies now answer the fence
# question the same way, which is what specs/coderabbit_review_sensing.md
# already required of them.
# THREE rungs, not two (Codex P1 round 6). rc 0 = read, rc 3 = the reader
# FAILED. An awk failure — locale, encoding, pathological input — used to print
# nothing and exit 0 through the pipeline, so "the reader broke" and "this body
# has no unfenced text" were the same answer. That conflation is only safe where
# the consumer's fail direction happens to point the right way, and it did not:
# see crw_head_summary_holds_blocking_marker, where an unread summary read as
# "belongs to another head" and suppressed a published finding.
#
# The gate's copy of these predicates has carried an rc-3 rung all along, and
# its comment records that flattening rc 3 into rc 1 was itself a defect. This
# is the same lesson reaching the waiter's copy.
crw_unfenced_body() {
  local out
  out=$(printf '%s\n' "$1" | awk "$CR_AWK_FENCE_PRELUDE"'
    { line = $0; sub(/\r$/, "", line)
      if (fence_update(line)) next
      if (FENCE) next
      print line }
  ') || return 3
  printf '%s\n' "$out"
}

summary_names_head() {
  local unfenced
  unfenced=$(crw_unfenced_body "$1") || return 3
  grep -qiE "between [0-9a-f]{40} and $2([^0-9a-fA-F]|\$)" <<<"$unfenced"
}

# True when the body carries a machine-readable commits range AND none of its
# ranges ends at this head — i.e. the body is a verdict about a DIFFERENT
# commit (#968).
#
# The defect it closes: `fresh_at` is `max(created_at, updated_at)` because
# CodeRabbit edits its summary in place and #824 records that reading
# `created_at` alone rejects a genuine re-review. That is right as far as it
# goes, and the other direction was missing — an EDIT IS NOT A RE-REVIEW.
# CodeRabbit rewrites that comment for reasons unrelated to reviewing the new
# head (the Review Change Stack widget, the walkthrough, the release-note
# block), and each rewrite bumps `updated_at`, at which point a verdict about
# commit N reads as current for commit N+1. Measured live on #965: push at
# 04:58:00Z, the PREVIOUS head's summary edited at 04:58:53Z, `cleared` in two
# seconds, and no CodeRabbit comment ever named the pushed head.
#
# The published freshness contract has two rungs — an exact SHA match wins
# outright, and only a review with NO matching SHA falls to the
# HEAD-committer-date floor. Such a body DOES carry a SHA; it is simply the
# wrong one, and nothing looked at it, so the case fell to the floor rung as
# though the body were silent.
#
# Direction matters. This predicate can only ever REFUSE a clearance, never
# make one — the same posture the file already takes for the per-SHA
# StatusContext at the probe's terminal emits. That is what makes a MUTABLE
# comment body acceptable evidence here: a CodeRabbit-side rewrite that dropped
# the range costs liveness (the wait keeps polling and eventually times out
# advisory), never correctness.
#
# Both conjuncts are anchored in the SAME shape summary_names_head reads, so
# the two cannot drift: a range is 40-hex on both ends, `between <base> and
# <head>`. A body whose range is unparseable — a format drift, or a body that
# never carried one — yields NO ranges and is therefore not a mismatch, which
# keeps the `fresh_at >= HEAD_ANCHOR` floor the only test for silent bodies
# exactly as before (#968 AC3). Failing the other way would stall every PR on
# CodeRabbit's next wording change.
#
# HERE-STRING, not a pipe, and the direction is why (Codex P1 on #995). With
# `set -o pipefail` on, `printf … | grep -q` reports 141 when grep matches and
# leaves before the producer has finished writing — which happens once the body
# exceeds the pipe buffer and the range line sits near its start. `|| return 1`
# then reads that as "this body makes no head claim", the demotion never fires,
# and the previous head's summary clears this head: the exact #968 false clear
# this predicate exists to close, restored on the large summaries most likely
# to carry one. Reproduced at 200 KiB before the fix.
summary_names_only_other_head() {  # <body> <head_sha>
  local unfenced
  # ONE read, reused for both questions (Codex P2 round 7). Delegating the
  # second question to summary_names_head performed a SECOND fence read, and if
  # only that one failed its rc 3 merely skipped the `&&`, so the unconditional
  # `return 0` claimed the summary belonged to another head — suppressing a
  # current-head finding on the masking path.
  unfenced=$(crw_unfenced_body "$1") || return 3
  grep -qiE "between [0-9a-f]{40} and [0-9a-f]{40}([^0-9a-fA-F]|$)" <<<"$unfenced" || return 1
  grep -qiE "between [0-9a-f]{40} and $2([^0-9a-fA-F]|$)" <<<"$unfenced" && return 1
  return 0
}

# True when the body carries a blocking finding marker OUTSIDE the pre-merge
# check table — classified by crw_scan_has_blocking_marker above, so the
# summary surface and the inline surface grade one vendor format (#837). awk
# with fixed-string index() rather than a sed
# range so the delimiters carry zero regex exposure. The strip runs only when
# the START delimiter precedes the END: with only presence checked, an END
# rendered before a START would latch the suppressor at START and quietly
# drop everything to EOF — including a real marker. Single definition, used
# by both probe verdict sites AND the polling summary-marker gate so the
# heuristic cannot drift between them.
summary_blocking_marker_present() {
  local body=$1 unfenced scan s_line e_line
  # ONE fence read, and DELIBERATELY NOT tri-state (Codex P1 round 7). Round 6
  # made this return 3 on a reader failure and audited only the two new callers;
  # six others consume it as a boolean, so an awk/locale failure became a CLEAN
  # result at three of them. The contract is restored: a reader failure falls
  # back to scanning the RAW body, which is strictly WIDER text and therefore
  # more likely to find a marker — fail-closed, and no caller has to change.
  if ! unfenced=$(crw_unfenced_body "$body"); then
    # Reader failed: scan the COMPLETE raw body with NO structural stripping
    # (Codex P1 round 8). Round 7's fallback set `unfenced="$body"` and carried
    # on into the delimiter search, which is where it broke: on the raw body a
    # FENCED quotation of the start delimiter pairs with the real table end, and
    # the strip deletes the genuine marker sitting between them — so the widened
    # scan I reasoned was fail-closed could delete more than it saw.
    #
    # Stripping structure out of text whose structure could not be read is the
    # error. Skipping the strip cannot lose a marker: the scan is a superset of
    # every narrower one, and the only cost is a fenced quote grading as a
    # finding, which is a spurious escalation — fail-closed in the direction
    # that matters.
    crw_scan_has_blocking_marker "$body"
    return
  fi
  scan="$unfenced"
  # Delimiters located in the UNFENCED text, not the raw body (Codex P1 round
  # 7). A fenced walkthrough QUOTING the start delimiter above a genuine
  # summary-only finding, with the real table end below it, made the strip span
  # from the quote to the real end and delete the finding in between — the same
  # latching failure the gate's summary_strip_pre_merge_block already avoids by
  # selecting from structural lines only.
  s_line=$(printf '%s\n' "$unfenced" | grep -nF "$CR_PRE_MERGE_BLOCK_START" | head -1 | cut -d: -f1)
  e_line=$(printf '%s\n' "$unfenced" | grep -nF "$CR_PRE_MERGE_BLOCK_END" | head -1 | cut -d: -f1)
  if [ -n "$s_line" ] && [ -n "$e_line" ] && [ "$s_line" -lt "$e_line" ]; then
    scan=$(printf '%s' "$unfenced" | awk \
      -v s="$CR_PRE_MERGE_BLOCK_START" -v e="$CR_PRE_MERGE_BLOCK_END" \
      'index($0,s){k=1} !k; index($0,e){k=0}')
  fi
  crw_scan_has_blocking_marker "$scan"
}
# END coderabbit_summary_helpers

# BEGIN coderabbit_rate_limit_marker_guard
# crw_rate_limit_masks_blocking_marker <observed> <body>
# True when a `rate_limit` classification was read off a body that ALSO carries
# a summary-level blocking marker (#1178).
#
# classify_comment is marker-FIRST by design (#593): the rate-limit marker is
# tested before every other predicate so a notice is recognized whatever
# CodeRabbit calls it this month. That ordering is right for naming the state
# and wrong for deciding what to do about it, because CodeRabbit writes its
# rate-limit stanza INTO the one summarize comment it edits in place — the same
# comment that carries the #535 summary-only finding. So one body can say both
# "I refused" and "here is a blocking finding", and the refusal wins the
# classification and short-circuits the scan before summary_blocking_marker_present
# is ever reached.
#
# That was survivable while every rate_limit read as not-yet downstream: the
# Phase 4b barrier held its budget and escalated, and a human read the summary.
# #1178 lets a rate-limited head OPEN that barrier on a Codex report alone, and
# nothing else disposition s the summary-only class — coderabbit-severity-gate.sh
# reads only pulls/{pr}/comments, the conversation gate covers threads, and the
# Phase 4b adapter sees only the diff. Without this guard the approval posts
# over a finding no required gate ever read (Codex P1 on #1179).
#
# Scoped to `rate_limit` deliberately. `paused` and `in_progress` still map to
# not-yet at the barrier, so they keep ending at a human by way of the bounded
# wait; rate_limit is the only class #1178 gave an opening path, so it is the
# only one whose masking now changes an outcome. Widening this to the other two
# would convert their self-clearing waits into immediate escalations for a
# hazard they do not have.
#
# The response is rc 2, not a suppression: this is the same move #535 made for
# the head-pinned summary, and the head-pinned-summary path's own comment
# records the reasoning — that state "previously returned rc 7, held the
# barrier full budget and escalated with the WRONG reason; now it escalates
# immediately with the right one". Same class, same answer, third site.
# <head_sha> is REQUIRED for the demotion below (Codex P1, round 4). Without it
# this predicate was head-BLIND while its round-3 sibling was head-anchored, and
# the asymmetry ran the wrong way: CodeRabbit edits ONE summary in place across
# revisions, so an old-head summary still carrying `_⚠️ Potential issue_` that
# picks up a rate-limit stanza after a new push made all three call sites emit
# rc 2 for a PRIOR head's finding. That is not a false clear, it is a false
# ESCALATE — a stale head holding the current one hostage, forcing the manual
# fallback the partial-quorum path exists to avoid, exactly the case
# crw_head_summary_holds_blocking_marker was careful to exclude.
#
# The demotion is `summary_names_only_other_head`, NOT a `summary_names_head`
# requirement, and the difference is the fail direction. Requiring a head
# reference would drop escalation for any marker-carrying body with NO commits
# range at all — a shape this predicate cannot rule out and whose absence proves
# nothing — reopening the round-2 hole from underneath. Demoting only on a range
# that names ANOTHER head fixes the hostage case while leaving every unrangeable
# body fail-closed. Same asymmetry #968 drew for the clearance demotion, for the
# same reason.
# Residual, named so the next round does not rediscover it as new: fence
# awareness does not make this shape-complete, it moves ONE error from
# fail-open to fail-closed. If CodeRabbit ever fenced its authoritative commits
# row, a stale-head body would read as no-range, escalate, and reintroduce the
# round-4 hostage case. The severity gate's copy asserts "CodeRabbit's own
# commits row is never inside a fence"; that is asserted rather than measured.
# Fail-closed is the right direction to be wrong in, so this ships as-is.
#
# Second conjunct dependency: `summary_blocking_marker_present` still locates
# its delimiters with a `grep -nF | head -1` pipeline under `set -euo pipefail`,
# which is the #1038 SIGPIPE-141 shape (#520/#947/#1147). Left to that issue
# rather than widened into here — but the reason this call site is SAFE is not
# the one it looks like, and getting it wrong is how a later fix inverts it.
#
# It is NOT "the abort escalates". Calling it as `... || return 1` puts it on
# the left of a `||`, which suspends errexit for the whole dynamic extent of the
# call, so a SIGPIPE inside it does not abort anything: `s_line` is simply empty
# and the function runs to completion. Measured, not reasoned.
#
# What makes it fail-closed is the FIRST LINE of that function: `local body=$1
# scan=$1`. `scan` defaults to the WHOLE body and is narrowed to the pre-merge
# block only inside `if [ -n "$s_line" ] && [ -n "$e_line" ]`. Losing the
# delimiters therefore WIDENS the scan rather than blinding it — the marker is
# still found and this guard still escalates.
#
# So a #1038 fix must preserve that default, not merely remove the pipe. Three
# plausible cleanups flip this call site from fail-closed to fail-open:
# initialising `scan=""`, restructuring so the narrowed block is the default, or
# adding `|| return 1` to the `s_line=` assignment "for hygiene" — that last one
# turns a widened scan into "no marker found", i.e. suppress, i.e. a false clear
# on a published required finding. The invariant is asserted in the guard's unit
# test (delimiters absent must still escalate) rather than left to inspection.
# Returns 0 (masked, escalate), 1 (bare refusal) or 3 (the fence reader failed,
# so nothing was decided). rc 3 is NOT folded into either verdict: a read that
# did not happen is not evidence, which is the same rule #957 applied to the
# comment-list reads.
crw_rate_limit_masks_blocking_marker() {
  local rc=0
  [ "${1:-}" = "rate_limit" ] || return 1
  [ -n "${2:-}" ] || return 1
  # Only the SECOND conjunct propagates rc 3, and the asymmetry is deliberate.
  # `summary_blocking_marker_present` fails closed INTERNALLY — on a reader
  # failure it scans the raw body with no structural stripping — so it is a
  # boolean here and has no rc 3 to propagate. Do not restore the tri-state
  # version: an earlier round made it rc-3-aware, audited only its two new
  # callers, and silently converted a reader failure into a CLEAN result at six
  # boolean ones. The head question below is different, and there the rung is
  # load-bearing: an unreadable body must never read as "belongs to another
  # head", because the demotion's `!` would invert that into a suppress.
  summary_blocking_marker_present "$2" || return 1
  summary_names_only_other_head "$2" "${3:-}" || rc=$?
  case "$rc" in
    0) return 1 ;;   # names ANOTHER head — prior-head finding, do not escalate
    1) return 0 ;;   # no other-head range — this body's marker stands
    *) return 3 ;;   # unreadable — the caller decides, and it decides infra
  esac
}

# crw_head_summary_holds_blocking_marker <head_sha> <summary_body>
# True when the marker-selected PR-level summary is pinned to THIS head AND
# carries a blocking marker (#1178, Codex P1 round 3).
#
# The sibling predicate above closes the case where ONE body says both things.
# This closes the case where they are two DIFFERENT comments: a no-review-object
# incremental review whose head-pinned summary carries a summary-only finding,
# followed by a separate rate-limit notice that becomes the newest comment. The
# notice body alone is clean, so the masking check passes it, and the
# no-review-object triage's `probe_not_yet` then exits BEFORE the
# marker-selected summary scan further down ever runs. The finding is never
# looked at.
#
# That was survivable while rate_limit read as not-yet downstream. It is not now
# that the Phase 4b barrier opens on a bare `rate_limit` whenever Codex has
# reported: the approval posts over a head-pinned summary-only finding that no
# required gate reads.
#
# Head identity is the whole safety of this: `summary_names_head` is the same
# SHA conjunct the #851 clearance path uses, so a PRIOR head's summary (#789)
# cannot hold this head hostage. The class is deliberately NOT constrained to
# `review` — a summary that itself classifies rate_limit is exactly the shape
# being guarded against, and requiring `review` here would reopen the hole from
# the other side.
# Same three rungs, and this is the site Codex round 6 caught: `summary_names_head
# ... || return 1` read an UNREAD summary as "belongs to another head", so a
# reader failure suppressed the escalation and let the barrier open past a
# published finding. rc 3 now propagates.
crw_head_summary_holds_blocking_marker() {
  local head="${1:-}" sbody="${2:-}" rc=0
  [ -n "$head" ] || return 1
  [ -n "$sbody" ] || return 1
  summary_names_head "$sbody" "$head" || rc=$?
  case "$rc" in
    0) ;;            # pinned to this head — fall through to the marker scan
    1) return 1 ;;   # a different head's summary; not this head's problem
    *) return 3 ;;   # unreadable — never "not this head"
  esac
  summary_blocking_marker_present "$sbody"
}
# crw_rate_limit_hides_a_finding <head> <notice_body> <review_body> <issue_comments>
# ONE question, asked once, over EVERY surface a blocking finding can occupy
# while `observed` reads `rate_limit` (#1178, Codex rounds 3/5/7/9).
#
# The four rounds that produced this each found the same defect behind a
# different door, because "has CodeRabbit published a finding?" was being
# re-asked inline at each exit of a control flow with many exits, and each exit
# knew about a different subset of surfaces:
#
#   round 3  the notice body itself, one comment carrying refusal AND finding
#   round 5  a head-pinned marker-selected summary, with a later bare notice
#   round 7  the same, reached via the review-object branch
#   round 9  the review OBJECT's own body, and the anchor-free open-window path
#
# Consolidating is the fix rather than a fifth inline block: a new exit added
# later calls this and inherits every surface, instead of inheriting whichever
# subset its author remembered. specs/coderabbit_review_sensing.md names the
# review object as the PRIMARY summary surface, which is precisely the one the
# per-site blocks kept omitting.
#
# Returns 0 (a finding is hidden behind this refusal — escalate), 1 (a bare
# refusal), or 3 (a surface could not be read, so nothing was decided). On 0 it
# sets CRW_HIDDEN_FINDING_JSON to the evidence for the caller to emit.
#
# Every surface is head-anchored or head-owned: the notice body and the
# marker-selected summary through crw_head_summary_holds_blocking_marker's
# summary_names_head conjunct, and the review body through the object's own
# GitHub-owned commit_id, which the caller has already matched. A prior head's
# summary therefore cannot hold this head hostage on any of them.
crw_rate_limit_hides_a_finding() {
  local head="${1:-}" notice="${2:-}" review_body="${3:-}" comments="${4:-}"
  local rc=0 sel sbody
  CRW_HIDDEN_FINDING_JSON=""

  # 1. the notice body itself
  if [ -n "$notice" ]; then
    rc=0; crw_rate_limit_masks_blocking_marker rate_limit "$notice" "$head" || rc=$?
    [ "$rc" = 3 ] && return 3
    [ "$rc" = 0 ] && return 0
  fi

  # 2. the head-pinned review OBJECT's own body. The spec calls this the primary
  #    summary surface, and it is scoped by the object's commit_id rather than by
  #    a commits range, so summary_names_head does not apply and must not be
  #    required — the caller only reaches here with a head-matched object.
  if [ -n "$review_body" ]; then
    rc=0; summary_blocking_marker_present "$review_body" || rc=$?
    [ "$rc" = 0 ] && return 0
  fi

  # 3. the marker-selected PR-level summary, head-anchored
  if [ -n "$comments" ]; then
    sel=$(crw_select_summary_comment "$comments" "$BOT_LOGIN" "$SUMMARY_MARKER") || return 3
    if [ -n "$sel" ]; then
      # rc 3 on a failed decode, never a bare refusal (#1178 round 10). Discarding
      # this status left `sbody` empty, which the head predicate's `[ -n ]` guard
      # turns into 1, which this helper reports as "no finding" — a verdict about
      # a surface that was never read. crw_summary_names_only_other_head already
      # guards the same read this way.
      sbody=$(printf '%s' "$sel" | base64 --decode | jq -r '.body') || return 3
      [ -n "$sbody" ] || return 3
      rc=0; crw_head_summary_holds_blocking_marker "$head" "$sbody" || rc=$?
      [ "$rc" = 3 ] && return 3
      if [ "$rc" = 0 ]; then
        CRW_HIDDEN_FINDING_JSON=$(printf '%s' "$sel" | base64 --decode | jq -r '.json')
        return 0
      fi
    fi
  fi
  return 1
}
# END coderabbit_rate_limit_marker_guard

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
#
# Return codes, and ALL call sites must honour all three (#959):
#   0  the comment list was DECODED. Stdout is `{}` (nothing qualifying) or the
#      selected comment object — always non-empty.
#   3  the comment list could NOT be decoded. NOTHING on stdout.
#
# The rc-3 rung is the same one `summary_body_has_potential_issue_marker` and
# `fetch_api_array` already carry, and it was the one reader on this path
# without it. #936 hardened the FETCH here; the DECODE that follows it stayed
# unchecked, so a payload the fetch's own `add // []` accepts but this jq
# chokes on — a well-formed array whose elements are not comment objects — left
# `latest` EMPTY with status 0. Empty is not `{}`: `echo "" | jq 'length'` runs
# the filter zero times, printing nothing and exiting 0, so the callers'
# `[ "$(… | jq 'length')" = "0" ]` guard — written for "no qualifying comment" —
# does not fire for "could not read the comments". Control then fell through to
# `classify_comment ""`, which grades `review`, the one class whose arm can
# emit a clearance.
latest_comment_from_issue_comments() {
  local issue_comments=$1
  local latest projected
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
  ') || {
    log "ERROR: failed to decode the CodeRabbit comment list — the comments are UNREAD, not empty"
    return 3
  }

  # `jq` exiting 0 with empty stdout is not a state this filter can reach
  # (`last // null` always emits one value), so an empty `$latest` means the
  # decode did not really happen. Refusing it is what keeps the emptiness
  # inference at the callers honest rather than dead.
  if [ -z "$latest" ]; then
    log "ERROR: the CodeRabbit comment-list decode produced no value at all — treating the comments as UNREAD"
    return 3
  fi

  if [ "$latest" = "null" ]; then
    echo '{}'
    return 0
  fi
  projected=$(echo "$latest" | jq '{id, created_at, updated_at, fresh_at, endpoint: "issues", body}') || {
    log "ERROR: failed to project the selected CodeRabbit comment — the comment is UNREAD, not absent"
    return 3
  }
  printf '%s\n' "$projected"
}

scan_latest_comment() {
  local issue_comments
  # Explicit propagation (#831/#957) — the last wrapper in this file that
  # inferred "no comment" from an unchecked read, and the worst-placed one.
  # This is the POLLING arm, which every caller reaches; the StatusContext
  # fast path is opt-in behind trust_status_context_for_clearance. And
  # `classify_comment ""` grades an empty body `review` — the one class whose
  # arm can emit a clearance — so a failed read did not stall the loop, it
  # ADVANCED it to a verdict on evidence nobody read. Captured live on #936
  # head d361075: a transient TLS failure produced
  # `latest CodeRabbit comment id= endpoint= class=review` and then
  # `CodeRabbit review posted with no high-severity markers — cleared`, saved
  # from exit 0 only by the emitter's `--argjson` crash on the empty object —
  # an accident, not a guard.
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") || return 3
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

# BEGIN coderabbit_graded_review_selector
# The head-pinned CodeRabbit review object whose inline findings the counters
# GRADE, as `{id, submitted_at}`, or nothing.
#
# Extracted (#1031) because two decisions now have to agree about which object
# that is. `latest_head_pinned_review` below feeds head_review_finding_bodies
# and therefore count_potential_issues; `crw_head_pinned_clean_review_run`
# credits a run as clean and may only credit the run the counter actually
# graded. The two read the SAME endpoint through DIFFERENT filters — the
# evidence helper keeps only body-BEARING objects (#900), this selection keeps
# every head-pinned one — so a private copy of the selection in the second
# reader is exactly how the two came to disagree about one head.
#
# Naming it is necessary but NOT sufficient, and that distinction is the whole
# of #1031 round 2: two CALLS to this one function still read two different
# snapshots of a live endpoint, so a run published between them makes both
# answers correct and different. The agreement is therefore established by
# calling this ONCE per decision and passing the resulting id down — into the
# count it scopes (`count_potential_issues <id>`) and into the rung that
# credits it (`crw_head_pinned_clean_review_run <head> <id>`) — never by
# re-deriving it at each reader.
#
# Pure: jq over the passed strings only, no globals and no I/O.
#
# crw_select_head_pinned_graded_review <reviews-json> <bot-login> <head-sha>
crw_select_head_pinned_graded_review() {
  printf '%s' "${1:-}" | jq -c --arg bot "${2:-}" --arg head_sha "${3:-}" '
    [ .[]
      | select(.user.login == $bot)
      | select(.commit_id == $head_sha)
    ]
    | sort_by(.submitted_at) | last
    | if . == null then empty else {id, submitted_at} end
  '
}
# END coderabbit_graded_review_selector

# CodeRabbit may later reply to a finding thread with its hidden
# `review_comment_addressed` marker after an agent fixes/rebuts the
# finding. Treat that bot-authored marker as authoritative for the counting
# helpers below; ordinary human/agent replies do not clear a finding by
# themselves.
#
# Id of the latest CodeRabbit review object pinned to the current HEAD, or
# empty. Pin the selection to the current HEAD commit (`commit_id ==
# HEAD_SHA`). A review submitted recently but referencing an intermediate
# commit (e.g. a rapid push sequence where CodeRabbit reviewed an earlier SHA)
# must not be chosen as the HEAD review. Mirror the HEAD-pinning in
# scripts/codex-review-check.sh (commit_id == $sha).
#
# The SHA match is the WHOLE test; there is deliberately no
# `submitted_at >= HEAD_ANCHOR` conjunct (#824). HEAD_ANCHOR derives from the
# HEAD committer date, which whoever pushed controls: a metadata-rewritten
# commit or a skewed local clock dates the head into the future, and a
# legitimate review OF THAT EXACT SHA then has `submitted_at < HEAD_ANCHOR` and
# was discarded until wall-clock caught up — failing CLOSED, so a genuinely
# reviewed PR reported no findings-scope review and paged an operator. Requiring
# both let the weaker, pusher-controlled condition veto the stronger,
# GitHub-owned one. commit_id is immutable head identity and does not expire,
# which is the same argument probe_emit_verdict's own anchor-free selection
# already makes below.
#
# Dropping the anchor STRENGTHENS the count it feeds rather than loosening it:
# the filter could only ever remove SHA-matched reviews, so the counts below can
# now only rise. In particular an unchanged head that has sat longer than
# `coderabbit.wallclock_freshness_window_seconds` no longer loses its own review
# — the #224 false-clear that count_potential_issues_for_sha was introduced to
# route around.
latest_head_pinned_review() {
  local reviews
  # Explicit propagation, not errexit. fetch_api_array signals a failed read
  # only by returning 3 (#831); this function would otherwise carry on with an
  # empty $reviews and return 0 from the jq below, turning a failed API read
  # into a confident "no review on this head". Whether errexit fires depends on
  # the caller's context, so it cannot be relied on — check here.
  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews") || return 3
  crw_select_head_pinned_graded_review "$reviews" "$BOT_LOGIN" "$HEAD_SHA"
}

latest_head_pinned_review_id() {
  latest_head_pinned_review | jq -r '.id // empty'
}

# JSON array of the UNADDRESSED root inline finding bodies belonging to the
# latest CodeRabbit review on the current HEAD; `[]` when no review is pinned
# to HEAD. One selection shared by BOTH counters below, so the scoping — latest
# review on HEAD, root comments only, minus the roots CodeRabbit itself later
# marked `review_comment_addressed` — cannot drift between them (#824: the
# tier-aware counter carried its own copy of the HEAD-pinned review selection,
# which would otherwise have kept the timestamp veto that copy embedded).
#
# Emits BODIES, not a count: severity classification belongs to the shared
# `coderabbit_tier_of` in bash, not to a re-implementation of its heuristic in
# jq. Bodies are unfiltered by severity here on purpose — the potential-issue
# counter keeps p0/p1 and the tier-aware counter keeps the configured required
# set, which can include 🧹 Nitpick / 🟡 Minor.
#
# Takes the graded review id as an OPTIONAL first argument (#1031 round 2).
# When the caller supplies one — even the empty string, which is the real
# "no review pinned to this head" answer — it is used verbatim and no reviews
# fetch happens here. That is what lets a caller COUNT and later CREDIT the
# same object: the id it passes in is provably the id this count was scoped to,
# rather than one re-derived from a later snapshot of the same endpoint.
# Callers that do not care pass nothing and the id is derived here as before.
head_review_finding_bodies() {
  local pulls_comments latest_review_id
  # Explicit propagation, for the reason latest_head_pinned_review states one
  # level down: this runs inside the nested command substitution in
  # count_potential_issues, where errexit cannot be relied on. Without the
  # check a failed reviews read is indistinguishable from a genuine "no review
  # on this head" — both leave $latest_review_id empty — so the function would
  # emit `[]`, the counter would read a confident zero, and a transient API
  # failure would surface as `cleared`. An empty id with a SUCCESSFUL lookup is
  # still the real no-review state and still emits `[]`.
  if [ "$#" -ge 1 ]; then
    latest_review_id="$1"
  else
    latest_review_id=$(latest_head_pinned_review_id) || {
      log "FATAL: could not read the HEAD-pinned review id — refusing to report an empty finding set"
      return 3
    }
  fi

  if [ -z "$latest_review_id" ] || [ "$latest_review_id" = "null" ]; then
    echo '[]'
    return
  fi

  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments") || {
    log "FATAL: could not read the inline comments for the HEAD-pinned review — refusing to report an empty finding set"
    return 3
  }
  echo "$pulls_comments" | jq -c \
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
  '
}

# BEGIN coderabbit_count_helpers
# Length of a JSON array, or a NON-ZERO return when the input is not one.
#
# The counting paths below used a bare `jq 'length'` on the stated assumption
# that a dead upstream `fetch_api_array` would make jq "fail loudly". It does
# not, and the assumption inverted the very guarantee #837 exists to provide:
#
#   * `jq 'length'` on EMPTY stdin runs the filter zero times — it prints
#     nothing and exits 0. `total` came back empty, `[ "$i" -lt "" ]` errored,
#     and because a `while` CONDITION is exempt from errexit the loop was
#     simply skipped and the function echoed `0` with status 0. An upstream
#     API death therefore read as "zero blocking findings" — a silent
#     false-clear, the exact failure #837 fixes elsewhere in this file.
#   * A non-array JSON value is the same hazard by another route: `{}` has
#     length 0, and a string reports its character count.
#   * A multi-VALUE stream is a third route, and the one a per-value filter
#     cannot see: `[] []` makes jq run the filter twice and print `0\n0`,
#     which is not an integer, so `[ "$i" -lt "0\n0" ]` errors and the loop is
#     skipped exactly as in the empty case.
#
# `-s` (slurp) collapses the whole stream into ONE array, which turns all
# three routes into a single assertion: the stream must hold exactly one
# value, and that value must be an array. Empty slurps to `[]` (length 0),
# multi-value to length > 1, and a non-array to a length-1 stream whose sole
# element fails the type test — every one of them an error, never a count.
#
# Reported by CodeRabbit (🟠 Major) on #884; the multi-value route was a
# second 🟠 Major against the first version of this guard.
crw_json_array_length() {
  printf '%s' "${1:-}" \
    | jq -s -e '
        if ((length == 1) and (.[0] | type == "array"))
        then (.[0] | length)
        else error("expected exactly one JSON array")
        end' 2>/dev/null
}

# Count the bodies in a JSON array that classify as BLOCKING findings (#837).
# Fails closed on an empty/malformed argument, which happens when a
# `fetch_api_array` upstream died inside its command substitution: returning
# non-zero makes the `$( )` callers trip `set -e` and fail loudly, rather than
# letting an API error read as zero findings.
#
# Its two dependencies are `crw_body_is_blocking_finding` from the
# coderabbit_summary_helpers block and the script's stderr `log`, so the
# extracting test sources that block alongside this one.
crw_count_blocking_bodies() {
  local bodies=${1:-} total count=0 body i=0
  total=$(crw_json_array_length "$bodies") || {
    log "FATAL: blocking-finding count received input that is not a JSON array — refusing to report a count (an upstream fetch almost certainly failed)"
    return 3
  }
  while [ "$i" -lt "$total" ]; do
    body=$(printf '%s' "$bodies" | jq -r ".[$i]")
    if crw_body_is_blocking_finding "$body"; then
      count=$((count + 1))
    fi
    i=$((i + 1))
  done
  echo "$count"
}
# END coderabbit_count_helpers

# Count unaddressed blocking inline findings in the pulls inline comment list,
# scoped to the LATEST CodeRabbit review on the current HEAD. The naive "all
# bot comments after HEAD_ANCHOR" shape would keep stale findings from an
# earlier review round (same HEAD, pre-retry) in the count forever, so a PR
# could stay permanently in the `findings` state even after the next review
# comes back clean. Mirror the latest-review-scoping pattern
# codex-review-request.sh uses via `pull_request_review_id`. See
# propagation-round Codex finding (P1) on device-platform-reporting#51.
#
# Takes the graded review id as an OPTIONAL first argument and forwards it
# verbatim (#1031 round 2); see head_review_finding_bodies for why.
count_potential_issues() {
  local bodies
  # Propagated rather than inlined into the argument: a `$( )` failure inside
  # an argument list is invisible, and crw_count_blocking_bodies would then be
  # asked to grade the empty string. It refuses that too, but only this form
  # reports the actual cause.
  if [ "$#" -ge 1 ]; then
    bodies=$(head_review_finding_bodies "$1") || return 3
  else
    bodies=$(head_review_finding_bodies) || return 3
  fi
  crw_count_blocking_bodies "$bodies"
}

# Count unaddressed inline findings on HEAD whose coderabbit_tier_of tier is
# in the resolved required set (#577). Tier-aware sibling of
# count_potential_issues over the SAME candidate set, differing only in which
# tiers it keeps. Additive/advisory only: the return value populates the JSON's
# blocking_tier_unresolved and NEVER feeds an exit code. Guarded by
# FEEDBACK_POLICY_PRESENT at the single call site, so it never runs when the
# block is absent.
count_blocking_tier_issues() {
  local candidates cand_count blocking body tier i
  candidates=$(head_review_finding_bodies) || {
    log "blocking-tier count could not read the HEAD-pinned findings — reporting unknown rather than a count"
    return 3
  }

  blocking=0
  # Same fail-closed shape check as crw_count_blocking_bodies. Safe on this
  # advisory path: the single call site already wraps it in `|| true` and
  # validates the result as numeric-or-null, so refusing here surfaces as
  # `blocking_tier_unresolved: null` (unknown) instead of a false 0.
  cand_count=$(crw_json_array_length "$candidates") || {
    log "blocking-tier count received input that is not a JSON array — reporting unknown rather than a count"
    return 3
  }
  i=0
  while [ "$i" -lt "$cand_count" ]; do
    body=$(printf '%s' "$candidates" | jq -r ".[$i]")
    tier=$(coderabbit_tier_of "$body")
    if crw_tier_is_required "$tier"; then
      blocking=$((blocking + 1))
    fi
    i=$((i + 1))
  done
  echo "$blocking"
}

# Returns 0 (true) if the latest PR-level CodeRabbit SUMMARY comment body
# carries a line the shared `coderabbit_tier_of` classifier grades blocking
# (p0/p1 — 🟠 Major, Potential issue, ⚠️; #837), else 1.
#
# count_potential_issues() scans only INLINE `pulls/{pr}/comments`. When
# CodeRabbit surfaces a finding solely in its PR-level summary body
# (issues/{pr}/comments) while the inline count is zero, the findings gate
# would otherwise wrongly clear. This OR-side check closes that gap (#535).
# Mirrors latest_comment_from_issue_comments: filter to the bot login,
# newest comment on/after the HEAD anchor (max of created_at/updated_at,
# since CodeRabbit edits the summary in place).
#
# `$1` is the freshness anchor, defaulting to HEAD_ANCHOR — which is what the
# two POLL-side callers want, because each is reached only after a comment
# already survived that same floor, and the verdict must be read off the very
# comment they classified. The StatusContext fast path passes
# HEAD_IDENTITY_ANCHOR instead; the argument for that is at ITS call site, and
# the short version is that it is the one caller reached when NOTHING survived
# the floor.
#
# Return codes, and ALL call sites must honour all three:
#   0  a blocking marker is present in the head-anchored summary
#   1  no blocking marker
#   3  the summary could NOT be read (infra)
#
# The rc-3 rung exists because this helper is used as an `if` condition, and a
# `die 3` inside `fetch_api_array` exits only its own command substitution
# (CodeRabbit 🟠 Major on #936). Without the explicit propagation the function
# carried on with empty input, `summary_blocking_marker_present ""` returned
# false, and the caller read a dead API as "no summary-only finding" — a
# false clear, on the exact route #877 added this check to close. Treating rc 3
# as "absent" anywhere re-opens it; the callers `die 3` instead, which is what
# every other failed read in this file already does.
#
# The SAME rung covers the jq that derives the body, not only the fetch (Codex
# P1 on #936). An `if`/`||` call context disables errexit inside the function,
# so an unchecked assignment let a failed derive — a well-formed but
# unexpectedly-shaped payload, where the fetch's own `add // []` succeeds and
# `.user.login` then errors — carry on with an empty body and return 1 (`no
# marker`): clearance off a summary nothing ever read. Every read on this path
# is status-checked; there is no rung that means "I could not tell" other than
# 3.
#
# SELECTION — the latest review SUMMARY, not the latest bot comment of any
# class (Codex P1 on #936, a hazard the #877 fast-path caller opened). The
# helper originally served only the two POLL callers, and there the two
# selections coincide: each runs inside `case class in review)`, so the newest
# head-anchored bot comment is already known to be a review summary and
# re-picking it returns the very comment the caller classified. The
# StatusContext fast path establishes no such precondition, and a class-blind
# "newest bot comment" pick is wrong exactly there.
#
# The reachable shape is a later notice sitting ABOVE the summary. A
# rate-limit / paused / in-progress notice suppresses the fast path only while
# `status_context_fast_path_blocked_by_comment` still holds it against the
# status — and that arbitration deliberately releases an unscoped notice
# CREATED BEFORE the success (#446, the 263caf3 "Bug 6" regression). Once it
# does, the notice is still the newest comment: this helper graded the NOTICE,
# found no badge in a body that carries none by construction, and cleared over
# a blocking summary two comments down that the polling `review` arm and
# `--probe` both report as findings.
#
# Classified through `classify_comment`, the same ladder the poll loop routes
# every comment through, rather than a second jq predicate — a duplicated
# classifier is how the summary and inline surfaces drifted apart in #837/#851,
# and the vendor's own markers change. Non-review classes are SKIPPED rather
# than terminating the scan, so a notice cannot mask the summary underneath it
# by position; the class filter also subsumes the status-probe exclusion the
# old jq spelled out itself, since `status_probe` is one of the classes.
#
# The class filter is a PREFERENCE, never an EXCLUSION (CodeRabbit 🟠 Major on
# the first cut of this selection). `classify_comment` is a fixed-string grep
# over the whole body with no fence awareness, so a genuine summary that merely
# QUOTES one of the markers grades as that class — and on this file that is not
# hypothetical, because the markers ARE the literal constants a CodeRabbit
# summary quotes whenever it reports a finding on the classifier. Skipping such
# a body outright left no review-class candidate and returned `no marker` from a
# summary carrying a badge. Measured: on that fixture the class-blind selection
# exits 2 (findings) and an exclusion-shaped filter exits 0 (cleared) — a false
# clear this selection would have INTRODUCED.
#
# So the newest review-class body wins when one exists, and otherwise the helper
# grades the newest candidate — exactly what it did before the filter existed.
# That makes the change monotone: it can promote a summary over a later notice,
# and it can never demote one to nothing. The residual (a misclassified summary
# with a later notice above it) is unchanged from the pre-filter behaviour
# rather than made worse, and the classifier's own fence-blindness belongs to
# the machine-marker redesign in #878.
#
# No candidate at all is rc 1 (`no marker`), not rc 3: an absent summary is a
# definite answer — there is no summary-only finding on this head — and
# `summary_blocking_marker_present ""` is the same answer the previous shape
# gave when nothing survived the anchor. Only a failed READ is rc 3.
summary_body_has_potential_issue_marker() {
  local anchor="${1:-$HEAD_ANCHOR}"
  local issue_comments candidates candidate_count newest_body body i
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") || return 3
  # Newest-first bodies of the head-anchored bot comments. Ordering is the
  # whole point: the scan below takes the FIRST review-class body, which is the
  # LATEST summary.
  candidates=$(printf '%s' "$issue_comments" | jq -c --arg bot "$BOT_LOGIN" --arg after "$anchor" '
    [ .[]
      | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(.fresh_at >= $after)
    ]
    | sort_by(.fresh_at)
    | reverse
    | map(.body // "")
  ') || return 3
  candidate_count=$(crw_json_array_length "$candidates") || return 3
  # The pre-filter selection, captured before the scan so the fallback below is
  # literally the old behaviour rather than a reconstruction of it. Empty when
  # there are no candidates, which is the old empty-body answer too.
  newest_body=$(printf '%s' "$candidates" | jq -r '.[0] // ""') || return 3
  i=0
  while [ "$i" -lt "$candidate_count" ]; do
    body=$(printf '%s' "$candidates" | jq -r ".[$i]") || return 3
    if [ "$(classify_comment "$body")" = "review" ]; then
      # Through the shared helper, not a raw grep: the pre-merge check table's
      # hygiene `⚠️ Warning` rows are not findings, and the probe already reads
      # them that way — a raw grep here made the SAME body a `findings` verdict
      # in polling and a `reported` one in probe, so agent-review and the Phase
      # 4b barrier disagreed about one head (adversarial verification on #851).
      summary_blocking_marker_present "$body"
      return $?
    fi
    i=$((i + 1))
  done
  summary_blocking_marker_present "$newest_body"
}

# SHA-scoped variant of count_potential_issues, used by the StatusContext
# fast-path. Counts CodeRabbit inline findings whose `commit_id` (the SHA
# GitHub considers the comment currently anchored to, after rebases / new
# commits) equals the given SHA and whose creation time is not older than
# HEAD_IDENTITY_ANCHOR.
#
# Why this was INTRODUCED (codex CHANGES_REQUESTED on PR #224 round 2 +
# CodeRabbit ⚠️ Major @ line 581): count_potential_issues was freshness-anchored
# then — it filtered reviews with `submitted_at >= HEAD_ANCHOR`, so once the
# same unchanged HEAD sat longer than `coderabbit.wallclock_freshness_window_
# seconds` (default 1800s / 30 min), HEAD_ANCHOR advanced past the prior
# CodeRabbit review's submitted_at, latest_review_id became null, and the
# helper returned 0 — false-clearing the fast-path even while the same SHA
# still had unresolved blocking inline findings.
#
# That #224 cause is GONE since #824: latest_head_pinned_review now selects on
# `commit_id == HEAD_SHA` alone, so count_potential_issues can no longer lose a
# SHA-matched review to the wall-clock floor. Do not read the paragraph above
# as current behaviour of the sibling. This variant is kept because its SCOPE
# is still the right one for the fast-path caller, not because the sibling is
# broken: the fast-path is the only caller holding authoritative per-SHA
# evidence (from the StatusContext check), and this helper scopes by each
# inline comment's own `commit_id` — which survives GitHub's rebase remapping —
# rather than by the review object the comment belongs to.
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
# it applicable to HEAD after any rebases), excluding roots CodeRabbit itself
# later marked with `review_comment_addressed`; severity is graded in bash by
# the shared classifier (#837), not by a jq pattern. Resolved-thread state is
# not consulted directly; the explicit bot marker is the narrow signal
# that a current-head finding has been addressed without relying on
# GitHub conversation-resolution state.
count_potential_issues_for_sha() {
  local sha=$1
  local pulls_comments bodies
  # Same explicit propagation as head_review_finding_bodies: this counter is
  # also reached through command substitution, so a `die 3` inside the fetch
  # exits only its own subshell and would otherwise leave an empty list to be
  # graded as zero findings.
  pulls_comments=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "pulls comments") || {
    log "FATAL: could not read the inline comments for $sha — refusing to report an empty finding set"
    return 3
  }
  bodies=$(echo "$pulls_comments" | jq -c \
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
      | select(.id as $id | ($addressed_root_ids | index($id)) == null)
      | (.body // "")
    ]
  ')
  crw_count_blocking_bodies "$bodies"
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

# The newest CodeRabbit comment on the PR, ANCHOR-FREE. Mirrors
# latest_comment_from_issue_comments' selection (same bot filter, same
# fresh_at = max(created_at, updated_at), same status-probe narration
# exclusion) MINUS the `fresh_at >= HEAD_ANCHOR` filter. `{}` when the bot has
# said nothing on this PR at all.
#
# Anchor-free on purpose: the caller below asks "what was CodeRabbit's LAST
# WORD", a question the moving wall-clock freshness floor answers wrongly by
# construction — see crw_active_rate_limit_notice.
#
# Same three-rung decode contract as latest_comment_from_issue_comments
# (#959): rc 3, nothing on stdout, when the payload cannot be decoded. The
# swallow mattered here for the mirror-image reason — this feeds
# `crw_active_rate_limit_notice`, whose `|| return 1` reads "I could not decode
# the comments" as "there is no active rate-limit notice", which is the
# NON-suppressing answer.
newest_bot_comment_from_issue_comments() {
  local issue_comments=$1
  local latest projected
  latest=$(echo "$issue_comments" | jq --arg bot "$BOT_LOGIN" '
    def status_probe_reply:
      ((.body // "") | test("CodeRabbit review command invocation|Here.s a summary of where things stand|CodeRabbit is an incremental review system|does not re-review already reviewed commits"; "i"));
    [ .[]
      | select(.user.login == $bot)
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
      | select(status_probe_reply | not)
    ]
    | sort_by(.fresh_at)
    | last // null
  ') || {
    log "ERROR: failed to decode the CodeRabbit comment list while looking for its newest comment — the comments are UNREAD, not empty"
    return 3
  }
  if [ -z "$latest" ]; then
    log "ERROR: the newest-comment decode produced no value at all — treating the comments as UNREAD"
    return 3
  fi
  if [ "$latest" = "null" ]; then
    echo '{}'
    return 0
  fi
  projected=$(echo "$latest" | jq '{id, created_at, updated_at, fresh_at, endpoint: "issues", body}') || {
    log "ERROR: failed to project the newest CodeRabbit comment — the comment is UNREAD, not absent"
    return 3
  }
  printf '%s\n' "$projected"
}

# Seconds still remaining on the published window ride along ON the emitted
# notice, as the additive `rate_limit_remaining_seconds` field, rather than in
# a global. Every call site captures this function in a command substitution
# (`notice=$(crw_active_rate_limit_notice …)`), so an assignment made inside it
# dies with the subshell and the parent keeps whatever it had — the three
# suppression-path log lines reported `0s remaining` for the entire published
# window (Codex P3 / CodeRabbit 🟡 Minor on #936). Log-only, no verdict reads
# it, but a diagnostic that always prints the same wrong number is worse than
# none on exactly the path #909 was hard to read from.

# Emits CodeRabbit's newest comment when it is a rate-limit notice whose
# PUBLISHED window has not yet expired; returns non-zero (no output) otherwise.
#
#   crw_active_rate_limit_notice [<issue-comments-json>]
#
# The emitted object is the comment plus one additive field,
# `rate_limit_remaining_seconds` — see the note above for why it rides on the
# output rather than in a global. Additive because the poll loop adopts this
# object as its `LATEST` comment, and every consumer there either reads named
# fields or re-projects (`{id, created_at, endpoint, body_excerpt}`), so the
# extra key reaches no emitted JSON.
#
# #891 / #912. Rate-limit detection is gated on a comment that survives the
# `NOW - wallclock_freshness_window_seconds` floor (default 1800s). CodeRabbit's
# published windows run LONGER than that floor — 59 minutes was the observed
# one — so the notice ages out of the freshness window while the rate limit it
# announces is still in force. Once it does, `classify_comment` never sees it,
# the rate-limit branch stops firing, and control falls through to a
# StatusContext success that was set while rate-limited and never updated. On
# #909 that converted a correct exit-5 block at 02:34 into `cleared`/exit 0 at
# 03:01 on the same unchanged, unreviewed head.
#
# The freshness floor exists to stop a STALE notice from blocking a current
# head. Staleness of a notice is not evidence of recovery, and the window's own
# published end is the right scope for the suppression it carries.
#
# Both inputs are outside the pusher's control — the comment's
# created_at/updated_at are GitHub-owned and the window is CodeRabbit-published
# — so no timestamp the pusher can write participates in the decision.
#
# Three conjuncts, each load-bearing:
#   newest overall     a notice that a LATER bot comment supersedes is not
#                      CodeRabbit's current word. Without this, a 59-minute
#                      window would mask a genuine review that landed 20
#                      minutes into it.
#   classifies rate_limit  via the shared classifier, marker-first (#593).
#   window still open  `parse_rate_limit_window` must yield a window AND
#                      fresh_at + window + buffer must be in the future. A
#                      notice publishing no parseable window governs nothing
#                      here; it is still handled while it is fresh.
#
# rate_limit_window_elapsed_seconds fails SAFE to 0 on an unparseable
# timestamp, which here means "treat the window as fully open" — the
# suppressing direction.
crw_active_rate_limit_notice() {
  local issue_comments=${1:-}
  local latest body window fresh_at elapsed remaining
  if [ -z "$issue_comments" ]; then
    issue_comments=$(fetch_api_array_best_effort "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") || return 3
  fi
  # rc 3 propagates as rc 3, never as "no notice" (#959): this helper's rc 1
  # means "CodeRabbit's last word is not an open rate-limit window", which
  # RELEASES a suppression, and an unread comment list is no basis for that.
  latest=$(newest_bot_comment_from_issue_comments "$issue_comments") || return 3
  [ "$(echo "$latest" | jq 'length')" != "0" ] || return 1
  body=$(echo "$latest" | jq -r '.body')
  [ "$(classify_comment "$body")" = "rate_limit" ] || return 1
  window=$(parse_rate_limit_window "$body") || return 1
  fresh_at=$(echo "$latest" | jq -r '.fresh_at // .updated_at // .created_at')
  elapsed=$(rate_limit_window_elapsed_seconds "$fresh_at" "$(date +%s)")
  remaining=$((window + RATE_LIMIT_BUFFER_SECONDS - elapsed))
  [ "$remaining" -gt 0 ] || return 1
  printf '%s' "$latest" | jq -c --argjson r "$remaining" '. + {rate_limit_remaining_seconds: $r}'
}

status_context_fast_path_blocked_by_comment() {
  local status_created_at=$1
  local issue_comments latest class comment_id comment_created_at comment_fresh_at comment_body
  local active_notice active_id active_remaining active_rc
  # ONE fetch, shared by both checks below. Explicitly status-checked: a failed
  # fetch_api_array read reaches a caller only as a return status (#831), so an
  # unchecked read failure left the scan with empty input, every classifier
  # below saw nothing adverse, and the fast path CLEARED on a transient API
  # error — the same false-clear shape this whole function exists to prevent.
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") || {
    log "StatusContext success suppressed: the issue-comments read failed, so a pending rate-limit / paused / in-progress notice cannot be ruled out — keep polling"
    return 0
  }

  # The DECODE is status-checked too, not only the fetch above (#959). #936
  # hardened the fetch and left this line bare, so a payload that survives
  # `add // []` and then breaks this jq left `latest` empty — which does NOT
  # take the empty-comment branch below, because `echo "" | jq 'length'` prints
  # nothing rather than `0`. Control reached `classify_comment ""`, which grades
  # `review`, which the `rate_limit|paused|in_progress` case does not match, and
  # the function returned 1 — "not blocked" — clearing the fast path on comment
  # evidence nothing ever read. Same verdict as the failed fetch above, for the
  # same reason: an unread comment list cannot rule out an adverse notice.
  latest=$(latest_comment_from_issue_comments "$issue_comments") || {
    log "StatusContext success suppressed: the issue-comments list could not be DECODED, so a pending rate-limit / paused / in-progress notice cannot be ruled out — keep polling (#959)"
    return 0
  }
  if [ "$(echo "$latest" | jq 'length')" = "0" ]; then
    # #891/#912, and ONLY here. Nothing survived the wall-clock freshness
    # floor, so the arbitration below has no input at all — this is the one
    # state in which an aged-out rate-limit notice is invisible to it. A
    # notice whose PUBLISHED window has not expired is still CodeRabbit's
    # current word: its windows (59 min observed) outrun the default 1800s
    # floor, so it ages out mid-window and a stale success set while
    # rate-limited clears an unreviewed head (#909).
    #
    # Deliberately NOT applied when the floor did admit a comment. The
    # arbitration below already weighs a visible notice against the status —
    # by HEAD reference, by the published window widening the grace
    # (#596/#599), and by created_at ordering for an unscoped one (#446) —
    # and a window rule that ignores the status timestamp would override all
    # three, turning a genuinely-later success into a permanent suppression.
    # The defect is the notice going BLIND, not the arbitration being wrong.
    #
    # Three-way, not a boolean (#959). `crw_active_rate_limit_notice` returns 3
    # when the comment list could not be READ, and an `if …; then` collapses
    # that into its rc 1 — "there is no open window" — which is the releasing
    # answer. Take the suppressing one instead: an unread list rules nothing
    # out.
    active_rc=0
    active_notice=$(crw_active_rate_limit_notice "$issue_comments") || active_rc=$?
    if [ "$active_rc" = "3" ]; then
      log "StatusContext success suppressed: no CodeRabbit comment survived the ${WALLCLOCK_FRESHNESS_WINDOW_SECONDS}s freshness floor AND the comment list could not be read well enough to rule out an open rate-limit window — keep polling (#959)"
      return 0
    fi
    if [ "$active_rc" = "0" ]; then
      active_id=$(echo "$active_notice" | jq -r '.id')
      active_remaining=$(echo "$active_notice" | jq -r '.rate_limit_remaining_seconds // "unknown"')
      log "StatusContext success suppressed because no CodeRabbit comment survived the ${WALLCLOCK_FRESHNESS_WINDOW_SECONDS}s freshness floor, but its newest comment id=$active_id is a rate-limit notice whose published window has NOT expired (${active_remaining}s remaining) — the published window governs for its full duration (#891/#912)"
      return 0
    fi
    return 1
  fi

  class=$(classify_comment "$(echo "$latest" | jq -r '.body')")
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
      # HERE-STRING, not a pipe, and the direction is why (#1005). A rate-limit
      # or pause NOTE that references HEAD is often the LONGEST body on the PR
      # — CodeRabbit appends its walkthrough to it — and the reference sits in
      # the first stanza. Under `set -o pipefail` the producer takes SIGPIPE
      # once the body outruns the pipe buffer, the pipeline reports 141, the
      # `if` reads false, and the notice falls through to the #446 arbitration
      # below, which can leave the StatusContext success authoritative: a false
      # CLEAR over a CodeRabbit that has demonstrably not reviewed this head.
      if grep -Fq "$HEAD_SHA" <<<"$comment_body"; then
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
  local latest body class potential_issues review_json summary_marker_rc
  local summary_head_claim_rc head_run_rc head_run_id graded_review_id
  # Status-checked (#957/#959). "Best effort" governs the FETCH — an
  # unreadable surface is not fatal on the timeout path — but the DECODE now
  # reports rc 3, and an unchecked assignment would leave `latest` empty, skip
  # the length guard exactly as at the fast path, and reach
  # `classify_comment ""` = `review`, whose arm can `emit_json_and_exit
  # "cleared" 0`. Declining to emit anything is the conservative answer here:
  # this helper only ever UPGRADES a timeout into a verdict, so returning
  # without one leaves the advisory exit 4 in place.
  latest=$(scan_latest_comment_best_effort) || {
    log "post-probe terminal-review check: the comment list could not be read — leaving the advisory timeout in place rather than grading an unread head"
    return 0
  }
  if [ "$(echo "$latest" | jq 'length')" = "0" ]; then
    return 0
  fi

  # Derived ONCE and status-checked. A `$(… | jq -r '.body')` written inline in
  # an `if` condition would run with errexit suspended: a jq failure there
  # yields the empty string, which `classify_comment` grades `review` — the one
  # class whose arm can clear. One read, checked, cannot. (#1023 removed the
  # second consumer this body used to have; the class ladder is now the only
  # one, and the read still has to be checked for the same reason.)
  body=$(echo "$latest" | jq -r '.body') || {
    log "post-probe terminal-review check: the selected comment body could not be derived — leaving the advisory timeout in place rather than grading an unread comment"
    return 0
  }
  class=$(classify_comment "$body")
  case "$class" in
    review)
      # #1031 round 2: select the graded review object ONCE, here, and use the
      # same id for both the count below and the exact-SHA rung further down.
      # Letting each derive its own would let a run published between the two
      # reads be credited by the rung without ever being counted.
      graded_review_id=$(latest_head_pinned_review_id) || {
        log "post-probe terminal-review check: the HEAD-pinned review id could not be read — leaving the advisory timeout in place rather than counting against an unread selection"
        return 0
      }
      potential_issues=$(count_potential_issues "$graded_review_id")
      review_json=$(echo "$latest" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
      # #535: also honor a PR-level summary-body marker (the inline count
      # scans only pulls/{pr}/comments) so the probe-wait clearance path
      # cannot false-clear over a summary-only finding either.
      if [ "$potential_issues" -gt 0 ]; then
        log "CodeRabbit review landed during status-probe wait with $potential_issues blocking (p0/p1) inline finding(s) — emitting findings (exit 2)"
        emit_json_and_exit "findings" 2 "$review_json" "$potential_issues"
      fi
      # Three-way, not a boolean, exactly as the polling `review` arm reads it.
      # An `elif summary_body_has_potential_issue_marker` collapses the
      # helper's rc 3 (summary UNREADABLE) into rc 1 (no marker) and falls
      # straight through to `cleared` — a dead API reading as a clean summary,
      # on the one route that emits a verdict after the probe wait rather than
      # from the poll loop (Codex P1 on #936). The helper's contract is that
      # ALL THREE states are honoured at every call site; this was the site
      # that did not.
      summary_marker_rc=0
      summary_body_has_potential_issue_marker || summary_marker_rc=$?
      case "$summary_marker_rc" in
        0)
          log "CodeRabbit review landed during status-probe wait with 0 blocking inline findings but a blocking marker in the PR-level summary body — emitting findings (exit 2)"
          emit_json_and_exit "findings" 2 "$review_json" "$potential_issues"
          ;;
        1)
          # #968, mirroring the polling `review` arm — including its AC1
          # correction: the head claim is read off the SUMMARY, because `$body`
          # is only the newest bot comment and a later benign chat reply makes
          # no head claim at all.
          #
          # rc 3 is not fatal HERE, unlike at the polling arm. This helper only
          # ever UPGRADES the advisory timeout into a verdict, so declining to
          # emit leaves exit 4 in place — the same conservative answer it
          # already gives when the comment list cannot be read.
          #
          # #1003 / #1022: the same rung ordering the polling arm now applies —
          # the mutable third rung is consulted only when no immutable
          # head-pinned review run answers first. rc 1 and rc 3 both leave the
          # demotion deciding.
          head_run_rc=0
          head_run_id=$(crw_head_pinned_clean_review_run "$HEAD_SHA" "$graded_review_id") || head_run_rc=$?
          if [ "$head_run_rc" = "0" ]; then
            log "post-probe terminal-review check: CodeRabbit review run id=$head_run_id is pinned to $HEAD_SHA by commit_id, is the run the finding counter graded, and carries a clean report body — the exact-SHA rung wins outright, so the mutable summary's commits range does not demote this head (#1003/#1022)"
          else
            summary_head_claim_rc=0
            crw_summary_names_only_other_head "$HEAD_SHA" || summary_head_claim_rc=$?
            case "$summary_head_claim_rc" in
              0)
                log "post-probe terminal-review check: the PR's CodeRabbit summary has no blocking markers, but its commits range names a different commit than $HEAD_SHA — leaving the advisory timeout in place rather than clearing on another commit's verdict (#968)"
                return 0
                ;;
              1) : ;;
              *)
                log "post-probe terminal-review check: the CodeRabbit summary comment could not be read, so a verdict about another commit cannot be ruled out — leaving the advisory timeout in place"
                return 0
                ;;
            esac
          fi
          # #1023: the second carrier that read `$body` — the newest bot
          # comment, not the marker-selected summary — is gone here for the
          # reason the polling arm records at the equivalent site.
          log "CodeRabbit review landed during status-probe wait with no high-severity markers — emitting cleared (exit 0)"
          emit_json_and_exit "cleared" 0 "$review_json" 0
          ;;
        *)
          die 3 "could not read the PR-level summary to rule out a summary-only blocking marker on $HEAD_SHA — refusing to report a clearance"
          ;;
      esac
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
# review-object branch (#869); empty (→ null in the JSON) everywhere else,
# including every polling run and every trust-opted-out policy. The
# timestamp exists so the Phase 4b barrier can require the success to be
# at-or-after the review object it corroborates — a same-SHA rerun exposes
# the previous run's success while the new summary is pending.
PROBE_CONTEXT_STATE=""
PROBE_CONTEXT_UPDATED_AT=""
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

# BEGIN coderabbit_emit_json
# Sentinel-delimited so tests/test_coderabbit_wait_statuscontext_ratelimit.sh
# can extract and drive the emitter directly. There is deliberately no live
# route left that reaches it with an unusable review object — the reader guards
# are what close those — so the invariant below is only assertable this way.
emit_json_and_exit() {
  local status=$1 exit_code=$2 review_json=$3 potential_issues=$4
  local now_epoch waited skip_reason_json

  # #985. `--argjson review "$review_json"` at the bottom of this function
  # rejects an empty or unparseable value by DYING INSIDE jq: the process exits
  # 2 with nothing on stdout. Both halves of that are wrong.
  #
  #   - rc 2 is the code callers read as `findings` (blocking review feedback),
  #     so a run that died in the emitter reported the same status as a run that
  #     found a real Major, and neither agent-review.yml nor the Phase 4b
  #     barrier could tell the two apart.
  #   - no JSON reaches stdout at all, so every consumer that parses the emitted
  #     object gets a parse error instead of a status, on the one path where the
  #     cause matters most.
  #
  # That crash is also what #957 measured standing between a false clearance and
  # a real exit 0 on mergepath#936 head d361075 — `emit_json_and_exit "cleared"
  # 0` WAS called, and jq killed the run. #957 was explicit that the emitter must
  # not be hardened until the READS fail closed first; that ordering is now
  # satisfied (#831/#965, #942/#957/#959/#963), so the accidental guard can be
  # replaced by an honest one.
  #
  # `--argjson review "${review_json:-null}"` would be the WRONG fix: it papers
  # over the invariant by silently emitting `review: null`, which is the
  # "cannot decide reads as nothing to decide" shape this whole family exists to
  # close. An unusable value here is an INTERNAL invariant violation — a caller
  # bug, not a provider state — so it takes the infra exit and names its caller.
  #
  # The literal string `null` is NOT a violation: `timeout`, `paused` and
  # `skipped` legitimately emit `review: null`, and a parse test accepts it.
  # `jq -e` would not — it exits 1 on a `null` output — so the check is a parse
  # test and not a truthiness test.
  #
  # The parse test is `jq -s 'length' == 1`, not `jq empty` (Codex P2 on #995).
  # `jq empty` asks only "does every value here parse", which is a WEAKER
  # question than the one `--argjson` asks: it exits 0 on a whitespace-only
  # string (zero values) and on two concatenated documents (`{} {}`), both of
  # which `--argjson` rejects — so the guard passed and the run still died
  # inside jq with rc 2 and no stdout, which is precisely the
  # findings/infra misclassification this change exists to remove. Slurping
  # counts values instead: 0 for empty-or-whitespace, 2 for the double
  # document, exactly 1 for `null` and for any single object, and a parse
  # failure makes jq exit non-zero with no count at all.
  local review_json_values
  review_json_values=$(jq -s 'length' 2>/dev/null <<<"$review_json") || review_json_values=""
  if [ -z "$review_json" ] || [ "$review_json_values" != "1" ]; then
    die 3 "internal invariant violated: emit_json_and_exit was called from ${FUNCNAME[1]:-<top-level>} (line ${BASH_LINENO[0]:-?}) with a review object jq cannot accept for status '$status' — refusing to emit rather than dying inside jq with the findings exit code (#985)"
  fi

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
        # layers: `|| true` stops a nonzero return from count_blocking_tier_issues
        # from aborting under set -e, and the numeric-or-null validation forces a
        # value the downstream `jq --argjson` accepts. The earlier `$(...) ||
        # VAR=null` was insufficient: when an internal fetch_api_array read
        # failed, count_blocking_tier_issues could exit 0 with EMPTY output, so
        # the `||` never fired and the empty value broke `jq --argjson` — a hard
        # failure on an otherwise-terminal path.
        #
        # KEPT as belt-and-braces, not because that route is still open (#831
        # acceptance 3). count_blocking_tier_issues propagates its read failure
        # as rc 3 since #837, and every fetch_api_array wrapper in this file
        # propagates since #831, so `|| true` is what converts that honest
        # nonzero into the advisory `null` this decoration wants. The numeric
        # validation still earns its place: it is the only layer that does not
        # depend on any helper's return convention, and this is a report-only
        # field that must never flip a terminal exit code.
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
  # time) sampled by the rc-7 review-object branch (#869) and are null on
  # every other path.
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
# END coderabbit_emit_json

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
  # inline findings anchored on HEAD and count the ones the shared
  # classifier grades blocking (#837) before declaring clearance.
  #
  # Round 2 sharpening (codex CHANGES_REQUESTED + CodeRabbit ⚠️ Major
  # @ line 581 on the round 1 fix): use `count_potential_issues_for_sha
  # "$HEAD_SHA"` rather than `count_potential_issues`. The latter WAS
  # then filtered by HEAD_ANCHOR (wallclock freshness floor), so after
  # 30 min on the same unchanged HEAD the anchor advanced past prior
  # reviews and the count dropped to 0 — false-clearing the fast-path.
  # #824 removed that timestamp conjunct, so the sibling no longer
  # false-clears that way; the SHA-scoped variant stays because it
  # counts findings by each comment's own `commit_id == HEAD_SHA`,
  # which is the right scope given the fast-path already has
  # authoritative SHA-level evidence from the StatusContext check.
  local status_created_at=${2:-}
  local potential_issues synthetic
  potential_issues=$(count_potential_issues_for_sha "$HEAD_SHA")
  # Keep the synthetic review object compatible with the documented
  # contract at the top of this file: `{ id, created_at, endpoint,
  # body_excerpt }`. The fast-path has no underlying GitHub review,
  # so `id` is null — but a caller reading `review.id` or
  # `review.created_at` no longer hits a missing key and breaks.
  # `endpoint` keeps the new "status_context" value (a documented
  # extension for this path); the extra `head_sha` / `context_state` /
  # `potential_issue_count` fields are additive. (CodeRabbit Major, #272.)
  #
  # `created_at` is the STATUS' own creation time, not the synthesis time
  # (#912). Emitting the observation time made a verdict off a stale status
  # look head-anchored and current: on #909 the JSON read
  # `created_at: 2026-08-05T03:01:04Z` while the status it trusted had been
  # sitting untouched since `02:18:59Z`, and nothing in the payload showed
  # that. The synthesis time is not lost — it moves to the additive
  # `observed_at`, so a reader can see both the evidence's age and when the
  # helper looked. Falls back to the synthesis time only when the caller
  # passed no status timestamp, so the field is never absent or null.
  synthetic=$(jq -nc \
    --arg sha "$HEAD_SHA" \
    --arg state "$state" \
    --arg status_at "$status_created_at" \
    --argjson p "$potential_issues" \
    '{
      id: null,
      created_at: (if $status_at == "" then (now | todateiso8601) else $status_at end),
      observed_at: (now | todateiso8601),
      endpoint: "status_context",
      head_sha: $sha,
      context_state: $state,
      potential_issue_count: $p,
      body_excerpt: ("CodeRabbit StatusContext = " + $state + " on " + $sha + " (potential_issue_count=" + ($p | tostring) + ")")
    }')
  if [ "$potential_issues" -gt 0 ]; then
    log "StatusContext $state but $potential_issues blocking (p0/p1) inline finding(s) on HEAD — emitting findings (exit 2)"
    emit_json_and_exit "findings" 2 "$synthetic" "$potential_issues"
  fi
  # #877: the inline scan above is only ONE of the two surfaces a blocking
  # finding can live on. The poll loop's `review` arm applies
  # summary_body_has_potential_issue_marker as an OR-sibling to its inline
  # count, and the probe's two verdict sites apply
  # summary_blocking_marker_present the same way — this fast path applied
  # neither, so a head whose sole blocking marker lives in the PR-level summary
  # (the #535 summary-only class) cleared HERE while yielding `findings` on
  # every other route. status_context_fast_path_blocked_by_comment does not
  # cover it either: that function suppresses only rate_limit / paused /
  # in_progress, and a summary carrying a finding classifies as `review`.
  #
  # Sited here rather than in the suppressor because the suppressor would only
  # push the head into the poll loop to re-derive the same verdict a poll
  # interval later, and because the extra read is paid ONLY on the branch that
  # is about to clear — never on the findings branch above, which already has
  # its answer.
  #
  # potential_issue_count stays the INLINE count (0), byte-for-byte with the
  # polling `review` arm's summary-only emit, so the two routes remain
  # indistinguishable to a caller. The exit code carries the verdict.
  #
  # HEAD_IDENTITY_ANCHOR, not the helper's HEAD_ANCHOR default — the same anchor
  # count_potential_issues_for_sha uses three lines above, and for the same
  # reason. HEAD_ANCHOR carries the moving wallclock floor
  # (`coderabbit.wallclock_freshness_window_seconds`, live value 1800s), and
  # this is the ONE site reached when nothing survived that floor: the two poll
  # callers each run after a comment already passed it, so there the floor
  # cannot hide the comment being verdicted. Here it can, and did — on an
  # unchanged head whose summary had merely aged past 30 minutes, no comment
  # qualified, `summary_blocking_marker_present ""` read false, and the fast
  # path CLEARED over a summary carrying a blocking marker. That is the #877
  # false clear this OR-sibling was added to close, re-entered through the
  # anchor. Both other routes read that same head as findings: the polling
  # `review` arm off the comment it classified, and `--probe` off its
  # anchor-free `startswith(SUMMARY_MARKER)` + summary_names_head selection. So
  # the floor made agent-review and the Phase 4b barrier disagree about one
  # head purely because a clock advanced — and the merge-gating run is the LATE
  # one (.github/workflows/agent-review.yml runs this in polling mode at
  # approval time, after the Codex loop and the 4b barrier), i.e. the run most
  # likely to be looking at an aged summary.
  #
  # Anchored, not anchor-free: HEAD_IDENTITY_ANCHOR is the head's own
  # committer/force-push time, so a summary predating this head still drops out
  # as a prior head's report. Resurrecting those would block every push that
  # follows a blocking review, with nothing able to clear it.
  local summary_marker_rc=0
  summary_body_has_potential_issue_marker "$HEAD_IDENTITY_ANCHOR" || summary_marker_rc=$?
  case "$summary_marker_rc" in
    0)
      log "StatusContext $state and 0 blocking inline findings, but the head-anchored PR-level summary carries a blocking marker — emitting findings (exit 2) (#877/#535)"
      emit_json_and_exit "findings" 2 "$synthetic" "$potential_issues"
      ;;
    1) : ;;   # no summary-only marker — fall through to clearance
    *)
      die 3 "could not read the PR-level summary to rule out a summary-only blocking marker on $HEAD_SHA — refusing to report a clearance"
      ;;
  esac
  log "StatusContext $state and 0 blocking (p0/p1) inline findings — emitting cleared (exit 0)"
  emit_json_and_exit "cleared" 0 "$synthetic" 0
}

# BEGIN coderabbit_review_run_selector
# Select the newest HEAD-pinned CodeRabbit review object that is an actual
# review RUN. This object is the rc-7 evidence the Phase 4b barrier reads, and
# its `submitted_at` is the anchor that barrier's temporal conjunct
# (`probe.context_updated_at >= review.submitted_at`) compares the per-SHA
# StatusContext refresh against.
#
# Pure: jq over the passed strings only, no globals and no I/O — extracted by
# sentinel and sourced directly by tests/test_coderabbit_wait_status_probe.sh,
# the same pattern as the coderabbit_summary_helpers block above. It makes no
# API read, so it does not re-introduce the swallowed-`die 3` hazard that keeps
# the two fetches in probe_emit_verdict inline; a jq failure here is this
# function's own nonzero status and reaches the caller's `|| die 3`.
#
# #900: the `reviews` endpoint carries two KINDS of coderabbitai[bot] object on
# one head, and only one of them is a run. CodeRabbit also creates a review
# object for a CONVERSATIONAL REPLY on a review thread — its answer to a
# rebuttal, or to the `[mergepath-resolve:<class>]` tag reply
# scripts/resolve-pr-threads.sh posts to clear the pre-merge conversation gate.
# A reply starts no run, so no further StatusContext is ever published for that
# head: taking a reply as the anchor makes the temporal conjunct false forever,
# and a provider that has demonstrably finished reads as not-yet until the
# retry budget escalates. Because the review-loop rules require replying on
# every finding thread, clearing the conversation gate re-armed the wedge on
# every PR CodeRabbit had raised a thread on.
#
# Measured on #889, head `2433fe99`: five objects — two runs carrying 1787- and
# 1722-character summary bodies, each followed by a `success` status one second
# later, and three replies carrying an empty body and no status. A NON-EMPTY
# body separated all five, so that is the discriminator: a run always publishes
# its `Actionable comments posted: N` / walkthrough summary body, while a
# reply's review-level body is `""`.
#
# The discriminator belongs here, at selection, rather than at the barrier: the
# barrier needs the newest RUN's timestamp, and a filter applied downstream
# could only reject the reply, not recover the run underneath it.
#
# Fail-closed posture is unchanged. With no body-bearing object this emits
# nothing, the rc-7 payload carries no `review`, and the barrier stays on its
# bounded not-yet wait.
#
# crw_select_head_pinned_review_run <reviews-json> <bot-login> <head-sha>
crw_select_head_pinned_review_run() {
  printf '%s' "${1:-}" | jq -c --arg bot "${2:-}" --arg sha "${3:-}" '
    [ .[] | select(.user.login == $bot) | select(.commit_id == $sha)
      | select(((.body // "") | length) > 0) ]
    | sort_by(.submitted_at) | last
    | if . == null then empty
      else {id, created_at: .submitted_at, submitted_at, endpoint: "reviews",
            body_excerpt: ((.body // "")[0:200])} end
  '
}
# END coderabbit_review_run_selector

# BEGIN coderabbit_summary_selector
# Select the PR's single summarize comment — the newest bot comment whose body
# STARTS with the auto-generated summarize marker — as base64(json+body), or
# nothing.
#
# Extracted (#857) because the probe now reads it from TWO places: the
# no-review-object branch, where it is the head evidence (#851), and the
# review-object branch, where a completed run's verdict has to be graded off
# whatever summary exists even though none landed after the object. One
# definition so the selection cannot drift between them.
#
# `startswith`, not containment, and ANCHOR-FREE — both properties are
# load-bearing and are argued at the #851 call site: CodeRabbit pastes the
# marker literal into chat replies (and this repository carries it in source),
# so a quoting reply would out-select the real summary; and the summary is
# edited in place, so a wall-clock floor would stop counting a completed
# publication once the head had sat long enough.
#
# Pure: jq over the passed strings only, no globals and no I/O.
#
# crw_select_summary_comment <issue-comments-json> <bot-login> <summary-marker>
crw_select_summary_comment() {
  printf '%s' "${1:-}" | jq -r --arg bot "${2:-}" --arg m "${3:-}" '
    [ .[] | select(.user.login == $bot) | select((.body // "") | startswith($m))
      | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)} ]
    | sort_by(.fresh_at) | last
    | if . == null then empty
      else {json: ({id, created_at, updated_at, fresh_at, endpoint: "issues",
                    body_excerpt: ((.body // "")[0:200])} | tojson),
            body: (.body // "")} | @base64 end
  '
}
# END coderabbit_summary_selector

# BEGIN coderabbit_summary_head_claim
# #968 AC1. The other-head demotion is a statement about the review SUMMARY,
# and the two clearance sites evaluated it against whatever body the poll loop
# happened to be holding instead. Those two coincide only while the summary IS
# the newest bot comment. A CodeRabbit CHAT REPLY posted after it does not
# coincide: it classifies `review`, carries no commits range, and therefore
# makes no head claim at all, so the predicate answered "no claim" and the
# exact #968 false clear returned. That shape is live, not hypothetical —
# replies #794 and #518 are the two the SUMMARY_MARKER comment above already
# records — and it reproduces on the stub-gh fixture below: a summary edited
# after the push whose range ends at the PREVIOUS head, one benign reply above
# it, verdict `cleared` with `waited_seconds: 0`.
#
# So the head claim is read from the comment the SUMMARY_MARKER selects, which
# is the same anchor-free marker-led selection `--probe` already uses and the
# reason a chat reply is STRUCTURALLY unable to supply this evidence: it does
# not start with the marker at byte zero.
#
# Direction is unchanged from the predicate it wraps — this can only ever
# REFUSE a clearance, never manufacture one — which is what makes reading a
# mutable comment body acceptable evidence here.
#
# Return codes, and both call sites honour all three:
#   0  a summary exists and every commits range in it ends at some OTHER
#      commit. Refuse the clearance.
#   1  no refusal: there is no summary comment, or its body carries no
#      machine-readable range, or one of its ranges ends at this head. Those
#      are #968 AC2/AC3 and stay exactly as they were.
#   3  the issue-comment list could not be READ, or the selected body could not
#      be derived. Never folded into 1 — "the surface is unreadable" reading as
#      "the surface says nothing to refuse on" is the same failed-read-as-clean
#      confusion #936/#959 closed at the neighbouring reads.
#
# crw_summary_names_only_other_head <head-sha>
crw_summary_names_only_other_head() {
  local head_sha=${1:?}
  local issue_comments summary sbody
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") \
    || return 3
  summary=$(crw_select_summary_comment "$issue_comments" "$BOT_LOGIN" "$SUMMARY_MARKER") \
    || return 3
  # No summary comment on the PR at all is a definite answer, not an unread
  # one: there is no verdict here about any commit, so there is nothing to
  # demote and the caller's other freshness tests keep deciding.
  [ -n "$summary" ] || return 1
  sbody=$(printf '%s' "$summary" | base64 --decode | jq -r '.body') || return 3
  summary_names_only_other_head "$sbody" "$head_sha"
}
# END coderabbit_summary_head_claim

# BEGIN coderabbit_head_run_evidence
# #1003 / #1022. The answer to "does a head-pinned CLEAN review run outrank the
# #968 summary demotion?" is YES, and this helper is the evidence test that
# decides it. AGENTS.md step 5.a and REVIEW_POLICY.md § Phase 3 now publish that
# answer alongside the ladder.
#
# The defect: the published contract is an ORDERED ladder whose first rung is
# "an exact SHA match wins outright". The #968 rung sits third and reads a
# MUTABLE comment. Evaluating the third rung unconditionally inverts the
# order — CodeRabbit reviews the current head, leaves the in-place walkthrough
# naming the previous one (a behaviour this repo already documents), and the
# demotion refuses a clearance the immutable `commit_id` evidence supports. The
# run then polls to the advisory `exit 4` after `coderabbit.max_wait_seconds`.
#
# Why the #900 selector rather than a raw `commit_id == HEAD_SHA` match: #919
# records that the bare conjunct is satisfiable by CodeRabbit ACTIVITY rather
# than by a finished review. GitHub wraps a body-less review object around a
# single inline reply, so CodeRabbit's `🐇 ✅` acknowledgement of a
# `[mergepath-resolve:…]` tag reply — which the review-loop rules make us post
# on EVERY finding thread — would otherwise read as a review run.
# `crw_select_head_pinned_review_run` exists precisely to filter that: it
# requires a NON-EMPTY review body, the discriminator measured on #889.
#
# Four further conjuncts beyond the selector, all fail-closed:
#   - the run body must classify `review`. A head-pinned object whose body is a
#     rate-limit / pause / in-progress notice is not a completed report, and
#     `classify_comment` is the same ladder every other surface is graded with.
#   - the run body must carry no blocking marker. The callers have already
#     graded the inline findings and the SUMMARY body; a marker carried solely
#     by the run body is dispositioned by neither, so it must not unlock a
#     clearance route here.
#   - if the run body carries auto-generated STANZAS at all, they must all be
#     benign — the same refusal the probe's summary site makes for `failure`
#     (#790, #783), `skip review` (#797) and any KIND CodeRabbit ships next. It
#     is written as an implication rather than as a bare
#     `summary_stanzas_all_benign` call because that predicate is vacuously
#     FALSE on zero stanzas by design (#794/#518), and a review-OBJECT body
#     carries none: this repository's own model of one is the bare
#     `**Actionable comments posted: 0**`. Requiring a stanza would make this
#     rung unreachable and silently restore the inverted ladder.
#   - the run must be the SAME object the finding counter graded (#1031). The
#     selector and `latest_head_pinned_review` read one array through different
#     filters, so they answer differently the moment the newest head-pinned
#     object carries no body — which is the #919 shape this comment block
#     already documents, and the review-loop rules make it the COMMON shape:
#     we post a `[mergepath-resolve:…]` tag reply on every finding thread, and
#     GitHub wraps a body-less review object around CodeRabbit's `🐇 ✅`
#     acknowledgement of it. The counter then scopes `pull_request_review_id`
#     to that ACK, finds no root comments beneath it and reports 0 blocking
#     findings, while this rung would credit the FINDINGS run underneath —
#     whose findings are inline, so the marker conjunct above never sees them
#     either. The demotion is withdrawn and the wait emits `cleared` on a head
#     carrying a live `_🟠 Major_ / **Potential issue**`. Binding the two makes
#     the rung mean what it claims: THIS run's findings were counted, and there
#     were none. When they differ the counter graded some other object, so the
#     rung has no counted-findings evidence to outrank a summary with and the
#     demotion decides — the same answer as "no body-bearing run at all".
#
#     The counter's OWN id, not a re-derivation of it (#1031 round 2, Phase 4b
#     P1). Deriving the graded selection here — even from the same array this
#     helper's own run came from — binds two readers of ONE fetch, and the
#     fetch is not the counter's: `count_potential_issues` reads
#     `pulls/{pr}/reviews` earlier and independently. If CodeRabbit publishes a
#     newer body-bearing run B after the counter graded a clean run A and
#     before this helper's fetch, BOTH selectors here answer B, they agree, and
#     B satisfies the rung — while B's inline findings were never counted, and
#     inline findings put no marker in the run body for the conjunct above to
#     catch. That is the same false clear one snapshot further along. So the id
#     is a REQUIRED parameter, produced by the caller and passed verbatim into
#     the count it scopes: the caller cannot count against one object and
#     credit another, whatever lands between the two reads. A newer run makes
#     the ids differ, which refuses.
#
# Direction is preserved: this can only ever WITHDRAW a refusal that rests on a
# mutable comment, in favour of GitHub-owned immutable head identity. It never
# promotes a body to clearance — the caller still has to pass the inline
# finding count, the summary-marker gate and the class ladder before it reaches
# the `cleared` emit at all.
#
# Return codes, and both call sites honour all three:
#   0  a head-pinned, body-bearing, review-class, marker-free CodeRabbit run
#      exists on this head AND it is the object <graded-review-id> names. The
#      exact-SHA rung is satisfied; skip the demotion.
#   1  no such run — including the case where the caller graded no review
#      object at all (an empty <graded-review-id>), and the case where a newer
#      run has superseded the graded one. The demotion decides, exactly as
#      before.
#   3  the reviews list could not be READ, or the selected run could not be
#      derived. Never folded into 0 — an unreadable surface must not withdraw a
#      refusal, which is the same failed-read-as-clean confusion #936/#959
#      closed at the neighbouring reads.
#
# crw_head_pinned_clean_review_run <head-sha> <graded-review-id>
crw_head_pinned_clean_review_run() {
  local head_sha=${1:?}
  # The id of the review object the CALLER's finding count was scoped to.
  # Required, and required to be passed in rather than re-derived here — see
  # the "counter's own id, not a re-derivation" conjunct in the block comment.
  # Unset (as opposed to empty) is a programming error, not a runtime state.
  local graded_id=${2?}
  local reviews run run_id rbody
  # The caller counted no findings because it graded NO review object. There is
  # no counted-findings evidence to outrank the summary with, which is the same
  # definite answer as "no body-bearing run at all".
  [ -n "$graded_id" ] || return 1
  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews") || return 3
  run=$(crw_select_head_pinned_review_run "$reviews" "$BOT_LOGIN" "$head_sha") || return 3
  # No body-bearing review object pinned to this head is a definite answer, not
  # an unread one: there is no run to outrank the summary with.
  [ -n "$run" ] || return 1
  run_id=$(printf '%s' "$run" | jq -r '.id // empty') || return 3
  [ -n "$run_id" ] || return 3
  # #1031: the counter-binding conjunct, argued in the block comment above.
  [ "$run_id" = "$graded_id" ] || return 1
  # Re-read the FULL body from the same array. The selector emits a 200-char
  # `body_excerpt` for logging, and classifying an excerpt would grade a
  # truncated document — the marker a run carries need not be in the first 200
  # bytes.
  rbody=$(printf '%s' "$reviews" | jq -r --argjson id "$run_id" \
    '[ .[] | select(.id == $id) | (.body // "") ] | first // ""') || return 3
  # The selector already required a non-empty body, so an empty one here means
  # the id did not round-trip — an unread body, not a silent one.
  [ -n "$rbody" ] || return 3
  [ "$(classify_comment "$rbody")" = "review" ] || return 1
  summary_blocking_marker_present "$rbody" && return 1
  # The stanza implication. The literal is the one summary_stanzas_all_benign
  # counts as its TOTAL, so the two cannot disagree about what a stanza is.
  if grep -qiE 'auto-generated comment: ' <<<"$rbody" \
     && ! summary_stanzas_all_benign "$rbody"; then
    return 1
  fi
  printf '%s\n' "$run_id"
  return 0
}
# END coderabbit_head_run_evidence

# #919: both of the probe's terminal conjuncts are satisfiable by artifacts of
# CodeRabbit ACTIVITY rather than by a finished review.
#
#   - the "review object on the head" conjunct was satisfied by the body-less
#     review object GitHub wraps around a single inline reply — CodeRabbit's
#     `🐇 ✅` acknowledgement of a `[mergepath-resolve:…]` tag reply. Closed
#     upstream at selection by crw_select_head_pinned_review_run (#900).
#   - the "published summary" conjunct is satisfied by a review-stack REFRESH:
#     CodeRabbit bumps the walkthrough comment's updated_at when a push arrives,
#     BEFORE the run it announces completes. Nothing above distinguishes that
#     from a summary published by a finished run, so fixing only the first
#     conjunct still admits it.
#
# Measured on #892, head 304c861: a probe 29 seconds after the push reported
# `terminal`, while the per-SHA StatusContext still read
# `pending | Review in progress` ten minutes later — and CodeRabbit published no
# body-carrying review object for that head at all. The Phase 4b barrier read
# the same status and correctly held, so the probe and the barrier disagreed
# and the barrier was right.
#
# So the probe consults the conjunct that was unambiguously correct there. The
# test is deliberately narrow: ONLY the exact state `pending` blocks, never
# `missing` / `error` / `failure` / `success`. `missing` is the shape of the
# #851 clean incremental re-review, which publishes no status at all — treating
# absence as in-progress would make every previously-reviewed PR read not-yet
# forever, which is the deadlock #851 exists to prevent.
#
# Trust-gated like every other status read here. The disclosed cost is
# liveness: a run that stalls with `pending` latched and never publishes a
# terminal status keeps the probe at not-yet until the caller's own bound
# escalates. That is a hold rather than a false clear, which is the direction
# this helper is for.
#
# #936 (Codex P1): the two non-pending outcomes are not the same outcome. A
# read that returned `missing` is CodeRabbit's own statement that it published
# no status here; a read that FAILED says nothing at all, and answering "not
# pending" from it is a claim of terminality the evidence does not support —
# in the one direction this helper exists to close. A failed read is therefore
# infra rc 3, which is what every other failed read on the probe path already
# does (the reviews fetch, the summary selection, the #869 re-scan). It is
# also fail-closed at the barrier, which classes rc 3 as escalate rather than
# reported. The `trust_status_context_for_clearance: false` opt-out remains
# the escape hatch: it returns before the endpoint is touched at all.
crw_probe_head_review_in_progress() {
  local rec state desc
  [ "$TRUST_STATUS_CONTEXT" = "true" ] || return 1
  rec=$(check_status_context_record) || rec=""
  state=$(crw_status_record_state "$rec")
  if [ "$state" = "unreadable" ]; then
    die 3 "failed to read the per-SHA CodeRabbit StatusContext on $HEAD_SHA — a failed read is not evidence that the run finished, so the probe refuses to report terminality on it (#936)"
  fi
  [ "$state" = "pending" ] || return 1
  desc=$(printf '%s' "$rec" | jq -r '.description // ""')
  log "probe: the per-SHA CodeRabbit StatusContext on $HEAD_SHA is pending (${desc:-<no description>}) — a run is still underway, so the published artifacts are activity, not a finished review (#919)"
  return 0
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
# exists to suppress), so using it alone would report a head as reviewed
# when it was not. A silent clean review that posts only a status therefore
# reads as NOT-YET; the barrier's trigger step then asks for a review
# explicitly, which always produces a review object, so it self-heals at the
# cost of one allowance unit rather than by risking a false REPORTED. One
# narrower, CONJUNCTIVE role is admitted (#869), trust-gated by
# trust_status_context_for_clearance: the status rides along in the rc-7
# JSON as probe.context_state / probe.context_updated_at when the evidence
# is a HEAD-pinned review object, so the Phase 4b barrier can require
# per-SHA completion — refreshed at-or-after that object — before opening
# on an object whose PR-level summary is still in flight. The status
# upgrades nothing on its own; it seconds a claim the review object already
# made.
#
# A SECOND, narrowing role is admitted at the two terminal emits (#919):
# crw_probe_head_review_in_progress above downgrades an otherwise-terminal head
# to rc 7 when the per-SHA status reads exactly `pending`. It is the same
# posture — the status can only ever REFUSE a claim here, never make one.
probe_emit_verdict() {
  local reviews review review_at issue_comments cand row body class ctx_record
  local active_notice active_rc
  local summary sbody sjson sclass
  local summary_body="" newest_class="" rescan_done=false

  # Both reads are made DIRECTLY here, never through a helper. fetch_api_array
  # signals a failed read only by returning 3, and an intermediate wrapper that
  # does not propagate that status swallows it — the wrapper carries on with
  # empty input and returns 0, and any caller in a conditional or OR-list
  # context then reads a failed API call as a confident negative. That pattern
  # was found three times in three different helpers during review of this
  # change; calling fetch_api_array directly is what makes `|| die 3` fire
  # here. Since #831 every wrapper in this file propagates too, so the choice
  # is now defence in depth rather than the only safe route.
  reviews=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews") \
    || die 3 "failed to fetch reviews for the probe verdict"
  issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") \
    || die 3 "failed to fetch issue comments for the probe verdict"

  # `submitted_at` is additive (#869 barrier corroboration): the same
  # instant created_at already carries on this endpoint, but named
  # explicitly so the Phase 4b barrier's temporal conjunct
  # (probe.context_updated_at at-or-after the object) reads a field whose
  # meaning cannot drift with the endpoint.
  #
  # Body-less conversational replies are excluded at selection (#900) — see
  # crw_select_head_pinned_review_run above. `review_at` below therefore
  # anchors the summary scan on the newest RUN rather than on whatever object
  # is newest, which is also the anchor that scan always meant: a run's
  # summary follows the run, and a reply landing after it never carried one.
  review=$(crw_select_head_pinned_review_run "$reviews" "$BOT_LOGIN" "$HEAD_SHA") \
    || die 3 "failed to select the HEAD-pinned review"

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
    # The scan runs in a loop bounded to ONE re-fetch (#869 TOCTOU): the
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
      rl_summary=""; rl_sbody=""; rl_sjson=""; rl_rc=0; rl_rid=""; rl_rbody=""
      # The body newest_class was read from, retained for the #1178 guard
      # below. Only the CLASS used to leave this loop, which is enough to name
      # the observed state but not to tell a bare refusal from a refusal
      # written into a summary that still carries a blocking marker.
      newest_body=""
      cand=$(printf '%s' "$issue_comments" | jq -r --arg bot "$BOT_LOGIN" --arg at "$review_at" '
        [ .[] | select(.user.login == $bot)
          | . + {fresh_at: ([.created_at, (.updated_at // .created_at)] | max)}
          | select(.fresh_at >= $at) ]
        | sort_by(.fresh_at) | reverse | .[] | @base64
      ') || die 3 "failed to select the review summary"
      while IFS= read -r row; do
        [ -z "$row" ] && continue
        body=$(printf '%s' "$row" | base64 --decode | jq -r '.body // ""')
        class=$(classify_comment "$body")
        # Narration replies carry no publication state, and the probe.observed
        # enum deliberately omits status_probe — the no-review-object triage
        # drops narration in its jq filter, but this scan classifies every row,
        # so without this skip a narration reply landing after the review
        # object leaks `observed: "status_probe"` (#833, seen live on #852).
        # Skipped, not latched as blank: a pending notice BENEATH the narration
        # still names the observed state, and no narration hides a published
        # summary deeper in the scan.
        [ "$class" = "status_probe" ] && continue
        if [ -z "$newest_class" ]; then newest_class="$class"; newest_body="$body"; fi
        if [ "$class" = "review" ]; then summary_body="$body"; break; fi
      done <<< "$cand"

      [ -n "$summary_body" ] && break

      PROBE_OBSERVED="${newest_class:-awaiting-summary}"
      # #869: this is the ONE probe state whose rc-7 JSON carries
      # review-object evidence, and the barrier must not open on that
      # object alone — the PR-level summary still in flight can carry the
      # ONLY blocking marker (the #535 summary-only class, e.g. the
      # auto-pause note). Sample the per-SHA StatusContext — state AND
      # refresh time — into probe.context_state / probe.context_updated_at
      # so the barrier can require `success` that is at-or-after this
      # review object's submitted_at: on a same-SHA rerun the statuses
      # endpoint still exposes the PREVIOUS run's success while the new
      # object's summary and status refresh are pending, and a success
      # that PREDATES the object it would corroborate belongs to a
      # different run. Trust-gated by the same policy switch as every
      # other status read; both fields left null when the policy opts out,
      # which fails closed at the barrier (not-yet). Sampled once — the
      # re-scan pass reuses the first sample rather than reading a surface
      # that postdates it.
      #
      # #936, and a DELIBERATE difference from the #919 gate above: this
      # consumer was already fail-closed, because the barrier opens only on
      # the exact value `success`, so a failed read cannot make it open no
      # matter which non-success value it carries. It therefore keeps its
      # bounded, self-clearing not-yet instead of escalating to rc 3 — a
      # transient hiccup here costs one more probe cycle rather than a human.
      # What changes is honesty: it now reports `unreadable` rather than
      # borrowing `missing`, so the barrier's input distinguishes "CodeRabbit
      # published no status" from "we could not read the statuses".
      if [ "$TRUST_STATUS_CONTEXT" = "true" ] && [ -z "$PROBE_CONTEXT_STATE" ]; then
        ctx_record=$(check_status_context_record) || ctx_record=""
        PROBE_CONTEXT_STATE=$(crw_status_record_state "$ctx_record")
        PROBE_CONTEXT_UPDATED_AT=$(printf '%s' "$ctx_record" | jq -r '.updated_at // ""' 2>/dev/null || printf '')
      fi
      # #869 TOCTOU: the success just observed post-dates the comments
      # snapshot, so the summary may already be up. One re-fetch, one
      # re-scan; a summary found on the second pass takes the normal
      # rc-0/rc-2 verdict below instead of the rc-7 evidence. The re-fetch
      # failing is an infra rc 3 like every other probe read — emitting
      # the rc-7 success payload after a failed re-fetch would be exactly
      # the unscanned-summary hazard this loop exists to close.
      if [ "$PROBE_CONTEXT_STATE" = "success" ] && [ "$rescan_done" != true ]; then
        rescan_done=true
        log "probe: per-SHA success observed while the summary is unseen — re-fetching issue comments once (#869 TOCTOU)"
        issue_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments (post-success re-scan)") \
          || die 3 "failed to re-fetch issue comments for the post-success re-scan"
        continue
      fi
      # #857 item 1, review-object arm (Phase 4b P1). The anchor-free pause
      # read below covers only the NO-review-object branch, so a durable pause
      # note that predates a HEAD-pinned run is invisible here: the anchored
      # scan finds nothing at-or-after the run, `newest_class` is empty, and
      # the probe emits `awaiting-summary` with the review OBJECT as evidence.
      # p4b_barrier_maybe_resume gates on observed=paused and keys its
      # at-most-once marker on the pause note's comment id, so neither is
      # reachable from that emission — the barrier requests a review from a
      # still-paused bot and waits out its budget, which is the exact failure
      # item 1 exists to close. The ordering is not hypothetical: #852 showed a
      # summarize comment whose last edit PREDATES this head's review objects
      # and was never refreshed; a pause stanza in that slot behaves the same.
      #
      # Gated on `newest_class` empty for the same reason the terminal is: any
      # notice at-or-after the run already names the observed state through
      # PROBE_OBSERVED, including a pause, and that anchored reading is the
      # more current one.
      #
      # Fail direction: strictly additive recovery. Today this state escalates
      # after the full budget with no resume attempted; with this arm it
      # escalates after the full budget having attempted the one resume the
      # #847 recovery is bounded to. Nothing that already opened stops opening.
      if [ -z "$newest_class" ]; then
        summary=$(crw_select_summary_comment "$issue_comments" "$BOT_LOGIN" "$SUMMARY_MARKER") \
          || die 3 "failed to select the CodeRabbit summary comment for the pause re-read"
        if [ -n "$summary" ]; then
          sbody=$(printf '%s' "$summary" | base64 --decode | jq -r '.body')
          if [ "$(classify_comment "$sbody")" = "paused" ]; then
            log "probe: no notice after the run on $HEAD_SHA, but the anchor-free summary is a PAUSE — reporting paused with the note as evidence so the resume path is reachable (#857)"
            PROBE_CONTEXT_STATE=""
            PROBE_CONTEXT_UPDATED_AT=""
            sjson=$(printf '%s' "$summary" | base64 --decode | jq -r '.json')
            probe_not_yet "paused" "$sjson"
          fi
        fi
      fi
      # #1178 guard, site 1 of 3. A refusal written into a summary that still
      # carries a blocking marker must escalate, not report a bare refusal the
      # barrier may now open on. Sited BEFORE probe_not_yet for the same reason
      # the head-pinned-summary escalation sits before its own not-yet gate: a
      # blocking marker is a signal a human must see, and downgrading it costs
      # an escalation nothing else makes.
      # The two-comment shape reaches THIS branch too (Codex P1 round 7). The
      # loop above records only the newest non-narration comment in
      # `newest_body` and breaks solely on class `review`, so a marker-selected
      # summary carrying BOTH a blocking finding and a rate-limit stanza is
      # skipped whenever a later bare notice is newest. Round 3 added the
      # summary re-read to the no-review-object branch only; without it here,
      # the same masked finding emits a bare `rate_limit` that Phase 4b may open
      # on. Same predicate, same head anchoring, same rc-3 handling.
      # ONE call, EVERY surface (#1178 rounds 3/5/7/9). This site previously
      # carried two inline blocks that between them knew about the notice body
      # and the marker-selected summary, but not the review OBJECT's own body —
      # which the spec calls the primary summary surface.
      #
      # The FULL body, re-read from the reviews array by id (#1178 round 10,
      # found independently by both reviewers). The first version passed
      # `.body_excerpt`, which `crw_select_head_pinned_review_run` truncates to
      # 200 characters FOR LOGGING — so the surface added to close this door was
      # scanning a truncated document, and a marker past byte 200 escaped. This
      # file already documents the trap a few hundred lines up, where
      # `crw_head_pinned_clean_review_run` re-reads for exactly this reason;
      # same idiom, same array, same id.
      if [ "$PROBE_OBSERVED" = "rate_limit" ]; then
        # FAIL CLOSED on an unusable id or an empty round-trip (CodeRabbit Major,
        # round 11). The first version left `rl_rbody` empty in both cases and
        # passed that to the helper, which skips an empty surface — so "I could
        # not read the primary surface" became "the primary surface carries no
        # finding". That is the fifth instance of this same
        # absence-versus-inability conflation in this PR, and the one that would
        # have silently disabled the surface added two rounds ago to close it.
        #
        # An empty body after a successful lookup means the id did not round-trip,
        # not that the review is silent: crw_select_head_pinned_review_run already
        # required a non-empty body to select this object at all, which is the
        # same reasoning crw_head_pinned_clean_review_run applies to its own
        # re-read.
        rl_rid=$(printf '%s' "$review" | jq -r '.id // empty') || die 3 "failed to read the review object id for the #1178 full-body re-read"
        case "$rl_rid" in
          ''|null) die 3 "the head-pinned review object on $HEAD_SHA carries no usable id, so its body — the PRIMARY summary surface — cannot be scanned for a blocking marker (#1178)" ;;
        esac
        rl_rbody=$(printf '%s' "$reviews" | jq -r --argjson id "$rl_rid" \
          '[ .[] | select(.id == $id) | (.body // "") ] | first // ""') \
          || die 3 "failed to re-read the head-pinned review body for the #1178 marker scan — an unread surface is not evidence that it carries no finding"
        [ -n "$rl_rbody" ] || die 3 "the head-pinned review body for id $rl_rid did not round-trip from the reviews array — the selector required a non-empty body, so this is an unread surface rather than a silent one (#1178)"
        rl_rc=0
        crw_rate_limit_hides_a_finding "$HEAD_SHA" "$newest_body" \
          "$rl_rbody" "$issue_comments" || rl_rc=$?
        [ "$rl_rc" = 3 ] && die 3 "a surface could not be read while checking whether the rate-limit state on $HEAD_SHA hides a blocking finding — an unread surface is not evidence that it carries none (#1178)"
        if [ "$rl_rc" = 0 ]; then
          PROBE_CONTEXT_STATE=""
          PROBE_CONTEXT_UPDATED_AT=""
          PROBE_OBSERVED="terminal"
          log "probe: the rate-limit state on $HEAD_SHA hides a blocking finding — escalating rather than reporting a bare refusal (#1178)"
          emit_json_and_exit "findings" 2 "${CRW_HIDDEN_FINDING_JSON:-$review}" 1
        fi
      fi
      log "probe: review object on $HEAD_SHA but no terminal summary yet (newest=${newest_class:-none}, context_state=${PROBE_CONTEXT_STATE:-unsampled}, context_updated_at=${PROBE_CONTEXT_UPDATED_AT:-unsampled})"
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
    # #919: sited AFTER the summary-marker escalation on purpose. A blocking
    # marker is a real signal a human must see, and downgrading it to not-yet
    # would delay an escalation nothing else makes. Only the clean `reported`
    # emit — the one a caller reads as "go" — is gated on the run being done.
    if crw_probe_head_review_in_progress; then
      probe_not_yet "in_progress" "$review"
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

  local latest_json="null" rl_summary rl_sbody rl_sjson rl_rc
  if [ -n "$cand" ]; then
    body=$(printf '%s' "$cand" | base64 --decode | jq -r '.body')
    latest_json=$(printf '%s' "$cand" | base64 --decode | jq -r '.json')
    newest_class=$(classify_comment "$body")
    # #1178 guard, site 2 of 3 — the no-review-object triage. Same body, same
    # masking, same answer as site 1.
    # ONE call, EVERY surface (#1178 rounds 3/5/7/9) — replaces the two inline
    # blocks this site used to carry.
    if [ "$newest_class" = "rate_limit" ]; then
      rl_rc=0
      crw_rate_limit_hides_a_finding "$HEAD_SHA" "$body" "" "$issue_comments" || rl_rc=$?
      [ "$rl_rc" = 3 ] && die 3 "a surface could not be read while checking whether the rate-limit notice on $HEAD_SHA hides a blocking finding — an unread surface is not evidence that it carries none (#1178)"
      if [ "$rl_rc" = 0 ]; then
        PROBE_OBSERVED="terminal"
        log "probe: the rate-limit notice on $HEAD_SHA hides a blocking finding — escalating (#1178)"
        emit_json_and_exit "findings" 2 "${CRW_HIDDEN_FINDING_JSON:-$latest_json}" 1
      fi
    fi
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
  summary=$(crw_select_summary_comment "$issue_comments" "$BOT_LOGIN" "$SUMMARY_MARKER") \
    || die 3 "failed to select the CodeRabbit summary comment"
  if [ -n "$summary" ]; then
    sbody=$(printf '%s' "$summary" | base64 --decode | jq -r '.body')
    sclass=$(classify_comment "$sbody")
    # #857 item 1: a DURABLE pause survives the head anchor.
    #
    # The anchored triage above drops a pause note whose fresh_at predates the
    # new head's committer date, which is what every fix push produces — so the
    # probe reported observed=none, the #847 resume path (which keys on the
    # pause note carried in this evidence) was never reached, and the barrier
    # posted a review request to a still-paused bot and waited out its budget.
    # The summarize comment carries the pause stanza and is selected
    # anchor-free, so reading ITS class recovers the state the anchor hid.
    #
    # ONLY paused. rate_limit and in_progress stay anchored deliberately: the
    # anchored triage exists so an ANCIENT notice cannot decline the trigger
    # forever, a rate-limit window expires on its own, and an in-progress
    # marker is transient — reading either anchor-free would trade one deadlock
    # for another. A pause is neither: it is PR-level, durable, and clears only
    # when something posts `resume`, so an old note is still live state.
    if [ "$sclass" = "paused" ]; then
      sjson=$(printf '%s' "$summary" | base64 --decode | jq -r '.json')
      probe_not_yet "paused" "$sjson"
    fi
    # Three conjuncts. Each one alone admits a head-naming non-report state:
    #   class == review       rate-limited / paused / in-progress, including
    #                         the LEGACY prose forms that carry no marker.
    #   stanzas all benign    `failure` (#790, #783), `skip review` (#797), a
    #                         drifted in-progress KIND, and anything CodeRabbit
    #                         ships next. Fail-closed by construction.
    #   head SHA present      a prior head's summary (#789), however recently
    #                         a Finishing-Touches checkbox edit bumped it.
    if [ "$sclass" = "review" ] \
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
      # #919, same gate as the review-object site above: a summary is
      # head-pinned by CONTENT, and CodeRabbit refreshes that content on push
      # before the run completes. A per-SHA `pending` status says the run is
      # not done, whatever the comment says.
      if crw_probe_head_review_in_progress; then
        probe_not_yet "in_progress" "$sjson"
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

  # #891/#912 AC: `--probe` must not transition `rate_limit` → `none` purely
  # because a clock advanced. The anchored triage above stops seeing the notice
  # once it ages past HEAD_ANCHOR, so a head whose review CodeRabbit is still
  # refusing reported `observed: "none"` with no provider-side change in
  # between. An unexpired published window is the provider's own statement that
  # it has not reviewed; report that rather than silence. Placed after the
  # static skip (which is the stronger "will never fire" claim) and after the
  # head-pinned summary branch (a completed review outranks an older notice).
  #
  # Three-way here too (#957 acceptance criterion 4 — the `--probe` path checked
  # for the same shape). rc 3 is an unreadable comment list, and an `if …; then`
  # collapses it into rc 1, "no open window", which falls through to
  # `probe_not_yet "none"` — reporting `observed: none`, "CodeRabbit has said
  # nothing", off a list nothing decoded. The verdict direction was already
  # safe (not-yet, never a clearance), but `observed` is what the Phase 4b
  # barrier classifies on, so the distinction is load-bearing there. rc 3 is the
  # same escalation the probe already takes for an unreadable statuses read
  # (#936), for the same reason.
  active_rc=0
  active_notice=$(crw_active_rate_limit_notice "$issue_comments") || active_rc=$?
  if [ "$active_rc" = "3" ]; then
    die 3 "could not read CodeRabbit's newest comment on $HEAD_SHA while checking for an open rate-limit window — a failed read is not evidence that CodeRabbit has said nothing, so the probe refuses to report on it (#957)"
  fi
  if [ "$active_rc" = "0" ]; then
    # #1178 guard, site 3 of 3 — the open-window path. This notice is selected
    # anchor-free by newest_bot_comment_from_issue_comments, so it can be the
    # summarize comment itself; the masking is the same and so is the answer.
    # ONE call, EVERY surface (#1178 round 9). This anchor-free open-window path
    # scanned only `active_notice`, so a current-head summary carrying both a
    # blocking marker and a rate-limit stanza that had AGED BELOW HEAD_ANCHOR —
    # while its published window stayed open — was never examined: the anchored
    # guards had already been skipped, and this one did not look. The
    # marker-selected summary read inside the helper is anchor-free by
    # construction, which is exactly what this path needs.
    rl_rc=0
    crw_rate_limit_hides_a_finding "$HEAD_SHA" \
      "$(printf '%s' "$active_notice" | jq -r '.body // ""')" "" "$issue_comments" || rl_rc=$?
    [ "$rl_rc" = 3 ] && die 3 "a surface could not be read while checking whether the open-window rate-limit notice on $HEAD_SHA hides a blocking finding — an unread surface is not evidence that it carries none (#1178)"
    if [ "$rl_rc" = 0 ]; then
      PROBE_OBSERVED="terminal"
      log "probe: the open-window rate-limit state on $HEAD_SHA hides a blocking finding — escalating (#1178)"
      emit_json_and_exit "findings" 2 \
        "${CRW_HIDDEN_FINDING_JSON:-$(printf '%s' "$active_notice" | jq -c '{id, created_at, updated_at, fresh_at, endpoint, body_excerpt: ((.body // "")[0:200])}')}" 1
    fi
    log "probe: no head evidence, and CodeRabbit's newest comment is a rate-limit notice with $(printf '%s' "$active_notice" | jq -r '.rate_limit_remaining_seconds // "unknown"')s left on its published window (#891/#912)"
    probe_not_yet "rate_limit" \
      "$(printf '%s' "$active_notice" | jq -c '{id, created_at, updated_at, fresh_at, endpoint, body_excerpt: ((.body // "")[0:200])}')"
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
  INITIAL_CTX=$(crw_status_record_state "$INITIAL_CTX_RECORD")
  INITIAL_CTX_CREATED=$(echo "$INITIAL_CTX_RECORD" | jq -r '.created_at // ""' 2>/dev/null || printf '')
  INITIAL_CTX_DESC=$(echo "$INITIAL_CTX_RECORD" | jq -r '.description // ""' 2>/dev/null || printf '')
  log "initial CodeRabbit StatusContext = $INITIAL_CTX on $HEAD_SHA (description: ${INITIAL_CTX_DESC:-<none>})"
  # #936: this arm only ever ACTS on `success`, so `unreadable` was already
  # fail-closed here — it falls through to the comment-driven poll, which is
  # the conservative path and the one a failed read should take. Named
  # explicitly so the property is asserted rather than incidental, and so the
  # log line stops calling a failed read an absent status.
  if [ "$INITIAL_CTX" = "unreadable" ]; then
    log "could not read the per-SHA CodeRabbit StatusContext on $HEAD_SHA — not treating an unreadable status as clearance or as absence; falling through to the comment-driven poll (#936)"
  elif [ "$INITIAL_CTX" = "success" ]; then
    if ! crw_status_description_permits_clearance "$INITIAL_CTX_DESC"; then
      log "StatusContext success on $HEAD_SHA carries description '$INITIAL_CTX_DESC', which does not name a completed review — CodeRabbit is reporting that it did NOT review this head, so this is not clearance; falling through to the comment-driven poll (#891/#897/#912)"
    elif ! status_context_fast_path_blocked_by_comment "$INITIAL_CTX_CREATED"; then
      log "StatusContext success — entering fast-path verdict (scans inline findings before clearance)"
      emit_status_context_verdict "$INITIAL_CTX" "$INITIAL_CTX_CREATED"
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
    LOOP_CTX=$(crw_status_record_state "$LOOP_CTX_RECORD")
    LOOP_CTX_CREATED=$(echo "$LOOP_CTX_RECORD" | jq -r '.created_at // ""' 2>/dev/null || printf '')
    LOOP_CTX_DESC=$(echo "$LOOP_CTX_RECORD" | jq -r '.description // ""' 2>/dev/null || printf '')
    # #936: same shape as the pre-loop arm — acts only on `success`, so an
    # unreadable read keeps polling rather than clearing. Stated, not implied.
    if [ "$LOOP_CTX" = "unreadable" ]; then
      log "could not read the per-SHA CodeRabbit StatusContext on $HEAD_SHA mid-loop — continuing to poll rather than treating the failed read as clearance or as absence (#936)"
    elif [ "$LOOP_CTX" = "success" ]; then
      if ! crw_status_description_permits_clearance "$LOOP_CTX_DESC"; then
        log "mid-loop StatusContext success on $HEAD_SHA carries description '$LOOP_CTX_DESC', which does not name a completed review — not clearance (#891/#897/#912)"
      elif ! status_context_fast_path_blocked_by_comment "$LOOP_CTX_CREATED"; then
        log "CodeRabbit StatusContext flipped to success mid-loop on $HEAD_SHA — entering fast-path verdict"
        emit_status_context_verdict "$LOOP_CTX" "$LOOP_CTX_CREATED"
      fi
    fi
  fi

  # rc 3 is an unreadable comment list, never an empty one (#831/#957). The
  # asymmetry this closes was stark: since #936 the `review` arm below already
  # refuses to clear when it cannot read the SUMMARY body, while the loop
  # cleared when it could not read the comment list at all.
  LATEST=$(scan_latest_comment) \
    || die 3 "could not read the CodeRabbit comment list on $HEAD_SHA — refusing to grade an unread head as a review"

  if [ "$(echo "$LATEST" | jq 'length')" = "0" ]; then
    # #891/#912: "nothing inside the freshness window" is not the same as
    # "CodeRabbit has said nothing". A rate-limit notice whose PUBLISHED window
    # is still open governs for that window's full duration — otherwise the
    # notice ages out mid-window, the rate-limit arm below never runs, and the
    # #489 Codex failover that compensates for a lost CodeRabbit round is
    # silently disarmed (`codex_failover_requested: false` on #909). Honor it as
    # THIS iteration's latest comment so the arm handles it exactly as it would
    # have while the notice was fresh.
    #
    # Read three-way here too (#959). The loop's behaviour on rc 3 is already
    # the safe one — keep polling — but the LOG line was not: "no CodeRabbit
    # comment yet" is a claim about the PR, and an operator reading it off a
    # failed read looks for a silent bot rather than for a broken surface. The
    # verdict is unchanged; only the diagnosis is.
    ACTIVE_RATE_LIMIT_RC=0
    ACTIVE_RATE_LIMIT=$(crw_active_rate_limit_notice) || ACTIVE_RATE_LIMIT_RC=$?
    if [ "$ACTIVE_RATE_LIMIT_RC" = "0" ]; then
      log "no CodeRabbit comment inside the ${WALLCLOCK_FRESHNESS_WINDOW_SECONDS}s freshness window, but its newest comment is a rate-limit notice with $(printf '%s' "$ACTIVE_RATE_LIMIT" | jq -r '.rate_limit_remaining_seconds // "unknown"')s left on the published window — honoring it (#891/#912)"
      LATEST="$ACTIVE_RATE_LIMIT"
    else
      if [ "$ACTIVE_RATE_LIMIT_RC" = "3" ]; then
        log "could not read CodeRabbit's newest comment while checking for an open rate-limit window (elapsed ${ELAPSED}s) — this is an unread surface, NOT an absent comment; sleeping ${POLL_INTERVAL_SECONDS}s and retrying (#959)"
      else
        log "no CodeRabbit comment yet (elapsed ${ELAPSED}s); sleeping ${POLL_INTERVAL_SECONDS}s"
      fi
      sleep_or_timeout "$POLL_INTERVAL_SECONDS"
      continue
    fi
  fi

  COMMENT_ID=$(echo "$LATEST" | jq -r '.id')
  COMMENT_BODY=$(echo "$LATEST" | jq -r '.body')
  COMMENT_ENDPOINT=$(echo "$LATEST" | jq -r '.endpoint')
  COMMENT_CREATED=$(echo "$LATEST" | jq -r '.created_at')
  COMMENT_FRESH_AT=$(echo "$LATEST" | jq -r '.fresh_at // .updated_at // .created_at')

  CLASS=$(classify_comment "$COMMENT_BODY")
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
      # #1031 round 2: one selection of the graded review object, reused by the
      # count immediately below and by the exact-SHA rung further down. Two
      # independent derivations would let a run that landed between them be
      # credited by the rung with its inline findings never counted.
      GRADED_REVIEW_ID=$(latest_head_pinned_review_id)
      POTENTIAL_ISSUES=$(count_potential_issues "$GRADED_REVIEW_ID")
      REVIEW_JSON=$(echo "$LATEST" | jq '{id, created_at, endpoint, body_excerpt: (.body[0:200])}')
      # #535: the inline count scans only pulls/{pr}/comments. Also honor a
      # PR-level summary-body marker so a finding surfaced solely in the
      # summary body still yields findings instead of false-clearing.
      if [ "$POTENTIAL_ISSUES" -gt 0 ]; then
        log "CodeRabbit review posted with $POTENTIAL_ISSUES blocking (p0/p1) inline finding(s)"
        emit_json_and_exit "findings" 2 "$REVIEW_JSON" "$POTENTIAL_ISSUES"
      fi
      # Three-way, not a boolean: rc 3 means the summary could not be READ, and
      # collapsing that into "no marker" is the false clear documented on the
      # helper (CodeRabbit 🟠 Major on #936).
      SUMMARY_MARKER_RC=0
      summary_body_has_potential_issue_marker || SUMMARY_MARKER_RC=$?
      case "$SUMMARY_MARKER_RC" in
        0)
          log "CodeRabbit review posted with 0 blocking inline findings but a blocking marker in the PR-level summary body — findings"
          emit_json_and_exit "findings" 2 "$REVIEW_JSON" "$POTENTIAL_ISSUES"
          ;;
        1)
          # #968, and ONLY the clearance. A summary whose commits range ends at
          # a commit that is not this head is evidence about that other commit,
          # however recently an in-place edit bumped its updated_at. The
          # findings arms above are untouched on purpose: they are decided by
          # `commit_id`-pinned inline comments and by the head-anchored summary
          # scan, and blocking is the safe direction anyway. It is the `cleared`
          # emit — the one a caller reads as "go" — that must not be reachable
          # from a verdict about another commit.
          # Read the head claim off the SUMMARY (#968 AC1), not off the body
          # this arm happens to be grading. Three-way for the same reason the
          # marker read above is: an unreadable comment list is not a body that
          # declines to make a claim.
          #
          # #1003 / #1022: the demotion is the ladder's THIRD rung and reads a
          # MUTABLE comment, so it is consulted only when the FIRST rung — an
          # exact SHA match, i.e. an immutable head-pinned review run — has
          # nothing to say. Evaluating it unconditionally inverted the
          # published order and stalled a head CodeRabbit had demonstrably
          # reviewed to the advisory timeout. rc 1 (no such run) and rc 3 (the
          # reviews list is unreadable) both leave the demotion deciding, so an
          # unreadable surface can never withdraw a refusal.
          HEAD_RUN_RC=0
          HEAD_RUN_ID=$(crw_head_pinned_clean_review_run "$HEAD_SHA" "$GRADED_REVIEW_ID") || HEAD_RUN_RC=$?
          if [ "$HEAD_RUN_RC" = "0" ]; then
            log "CodeRabbit review run id=$HEAD_RUN_ID is pinned to $HEAD_SHA by commit_id, is the run the finding counter graded, and carries a clean report body — the exact-SHA rung wins outright, so the mutable summary's commits range does not demote this head (#1003/#1022)"
          else
            SUMMARY_HEAD_CLAIM_RC=0
            crw_summary_names_only_other_head "$HEAD_SHA" || SUMMARY_HEAD_CLAIM_RC=$?
            case "$SUMMARY_HEAD_CLAIM_RC" in
              0)
                log "the PR's CodeRabbit summary comment has no blocking markers, but its commits range names a different commit than $HEAD_SHA — an in-place EDIT is not a re-review, so this is not clearance for this head (#968); sleeping ${POLL_INTERVAL_SECONDS}s"
                sleep_or_timeout "$POLL_INTERVAL_SECONDS"
                continue
                ;;
              1) : ;;
              *)
                die 3 "could not read the CodeRabbit summary comment to rule out a verdict about another commit on $HEAD_SHA — refusing to report a clearance"
                ;;
            esac
          fi
          # #1023 removed the second carrier that used to sit here: the same
          # predicate applied to `$COMMENT_BODY`, which is merely the newest bot
          # comment and need not be the marker-selected summary at all. It was
          # justified as monotone — refusals only — but the refusals it added
          # were not evidence about any review: a benign chat reply that QUOTES
          # `between <old-base> and <old-head>` (a rebuttal citing the previous
          # round, or a diff hunk from this very file) vetoed a valid
          # current-head summary and forced the advisory timeout. That
          # contradicts the published contract, which scopes the demotion to the
          # summary's OWN commits range. The summary read above is the carrier
          # of record; a non-summary comment carrying a range is quoting one.
          log "CodeRabbit review posted with no high-severity markers — cleared"
          emit_json_and_exit "cleared" 0 "$REVIEW_JSON" 0
          ;;
        *)
          die 3 "could not read the PR-level summary to rule out a summary-only blocking marker on $HEAD_SHA — refusing to report a clearance"
          ;;
      esac
      ;;
  esac
done
