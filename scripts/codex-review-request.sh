#!/usr/bin/env bash
# scripts/codex-review-request.sh — Phase 4a automated external review trigger
#
# Triggers (or awaits) a review from the ChatGPT Codex Connector GitHub App
# on a pull request, polls for a response against the current HEAD commit,
# and emits a machine-parseable JSON summary of what Codex produced so a
# caller (e.g. an authoring agent) can reason over it.
#
# Usage:
#   scripts/codex-review-request.sh [--trigger-only] [--failover] [--allow-moving-head] <PR_NUMBER> [REPO]
#
# Flags:
#   --trigger-only       Post (or confirm) the `@codex review` trigger and
#                        exit 0 without polling for clearance (#489).
#   --failover           --trigger-only for the CodeRabbit rate-limit
#                        failover in scripts/coderabbit-wait.sh only. A
#                        trigger this run posts is recorded with a failover
#                        marker comment, and the request ceiling does not
#                        count it (#2534).
#   --allow-moving-head  Downgrade the moving-head refusal (exit 8, below) to
#                        a warning and post anyway. For the exceptional
#                        callers that must request on a head the agent has
#                        not declared final: the CodeRabbit rate-limit
#                        failover in scripts/coderabbit-wait.sh, or an agent
#                        that has verified by hand that the head is final.
#
# Arguments:
#   PR_NUMBER  Required. The pull request number (integer).
#   REPO       Optional. Fully-qualified "owner/repo". Defaults to the
#              current repository detected by `gh repo view`.
#
# Environment:
#   GH_TOKEN                   Required for the read/polling calls. The
#                              load-bearing trigger and exact-head timeout
#                              determination comments are posted through
#                              gh-as-author.sh, which verifies and uses the
#                              author token for those writes.
#   MERGEPATH_PHASE_4A_GATED   Optional, recommended. Set to true/1 by the
#                              caller when the PR independently qualifies for
#                              Phase 4a (lines >= external_review_threshold, a
#                              file matches external_review_paths, or the PR
#                              carries needs-external-review). A gated PR is
#                              always requested, whatever
#                              codex.request_by_default says, because Phase 4
#                              review is mandatory (#2240). When it is not set
#                              to true and request_by_default resolves to
#                              false, the requester derives the gate from the
#                              PR itself (#2257) before it would skip; an
#                              input it cannot read counts as gated.
#   MERGEPATH_CODEX_AUTO_TRIGGER
#                              Optional. Set to true/1 by an AUTOMATIC caller
#                              (CI), never by an agent invoking this script by
#                              hand. Marks the trigger as machine-initiated,
#                              which makes it eligible to be skipped when the
#                              head introduces no reviewable content change —
#                              see auto_trigger_content_free() and #798. Only
#                              honored together with --trigger-only.
#
# IMPORTANT: a plain push (`synchronize`) never re-triggers a Codex review —
# the Codex GitHub App reviews only on PR-open, ready-for-review, or an
# explicit `@codex review` comment. Every fix-push must re-run this script
# (or otherwise re-post the trigger) to re-arm HEAD-anchored clearance;
# nothing does it automatically, and a stale prior-HEAD verdict does not
# satisfy the merge gate (#631).
#
# Behavior:
#   0. Reads codex.enabled (default true) and codex.request_by_default
#      (default false since #2240; it was true under #486) and decides
#      whether to request a Codex review at all (the Phase 4a entry
#      decision). When codex.enabled is false, Phase 4a is off and the
#      script exits 5 without triggering. A PR the caller flagged via
#      MERGEPATH_PHASE_4A_GATED is always requested. Otherwise, when
#      request_by_default is true the trigger is posted on EVERY PR; when
#      false or unset, the requester derives the Phase 4 gate from the PR
#      (the needs-external-review label, lines changed against
#      external_review_threshold, changed files against
#      external_review_paths) and requests only a gated PR (#2257); an input
#      it cannot read counts as gated. A policy that cannot be read (missing,
#      unparseable, no YAML parser, a non-boolean value) requests, with a
#      warning naming the cause.
#      request_by_default is orthogonal to enabled — it governs only WHEN
#      the trigger is posted, never WHETHER Codex participates.
#   1. Reads codex.review_timeout_seconds, codex.ack_wait_seconds,
#      codex.max_ack_retries, and codex.bot_login from
#      .github/review-policy.yml (defaults: 1800 / 30 / 1 /
#      chatgpt-codex-connector[bot]; the 1800s review_timeout (#1550) and
#      30s ack_wait are measured retunes — see #623 and the per-constant
#      comments below).
#   2. Fetches the PR's current HEAD commit SHA. Reviews and verdicts
#      count only when anchored to that head. PR issue reactions have no
#      commit attribution and never count as response or clearance (#1751).
#      Existing timestamp anchors remain for request/provider diagnostics.
#   3. Scans reviews, inline comments and issue-comment verdicts for a signal
#      already present on the current HEAD. If found, skips the trigger
#      comment and goes straight to emitting JSON — re-posting `@codex
#      review` when Codex has already responded can cause double-processing
#      or rate-limit pushback. Under --trigger-only, an AUTOMATIC caller
#      (MERGEPATH_CODEX_AUTO_TRIGGER) additionally skips when
#      scripts/workflow/codex_auto_trigger_gate.sh shows a prior Codex verdict
#      carrying forward to this head on an unchanged external-review
#      fingerprint — the content-free `update-branch` head of #798.
#   3b. In full (polling) mode, resumes instead of re-posting when the
#      latest fresh author trigger is still unanswered AND Codex's own
#      Review Summary reports a review of the current HEAD Running since
#      that trigger (#1550). The poll then waits only what remains of
#      `review_timeout_seconds` measured from that trigger; if it expires
#      with no response, a new trigger is posted as in step 4. Without that
#      provider evidence nothing proves the pending trigger targets this
#      head, so the script posts as before.
#   4. Otherwise posts `@codex review` as a PR comment, waits a short
#      bounded window for Codex's documented `eyes` acknowledgment on
#      that trigger comment, and re-posts the trigger up to
#      `max_ack_retries` if no acknowledgment appears. The eyes
#      acknowledgment is never treated as clearance.
#   5. Polls every 15 seconds for up to `review_timeout_seconds`
#      measured from the latest trigger comment, while accepting a
#      terminal response to any trigger posted in this run, for any of
#      the signals below. A poll read that fails transiently (HTTP 5xx,
#      429, a rate-limited 403, or a network error) is retried up to
#      MERGEPATH_CODEX_SCAN_RETRY_ATTEMPTS times before the run exits 3
#      (#1550); a permanent failure still exits 3 at once.
#        - a review from the Codex bot on the current HEAD, OR
#        - a HEAD-anchored Codex issue-comment verdict ("Codex Review:
#          Didn't find any major issues" + "Reviewed commit: <sha>") of
#          EITHER disposition — a non-affirmative verdict still ends the
#          poll (it is a real response), it just does not clear (#609).
#   6. Emits a JSON object to stdout summarizing what Codex produced.
#      The JSON shape is the contract with the caller; do not change
#      field names without also updating scripts/codex-review-check.sh
#      and the policy docs (CLAUDE.md, AGENTS.md, REVIEW_POLICY.md).
#
# Output JSON shape:
#   {
#     "pr_number": 123,
#     "repo": "owner/repo",
#     "head_sha": "<full sha>",
#     "head_committer_date": "<iso-8601>",
#     "bot_login": "chatgpt-codex-connector[bot]",
#     "review": null | {
#       "state": "COMMENTED",
#       "submitted_at": "<iso-8601>",
#       "commit_id": "<full sha>",
#       "body": "<top-level review body>"
#     },
#     "findings": [
#       { "path": "...", "line": N, "priority": "P0|P1|P2|P3",
#         "comment_id": N, "body": "<full finding body>",
#         "blocking": true|false, "discretionary": true|false }
#     ],
#     # `blocking` (#577) is derived from the resolved feedback_policy
#     # required-tier set (scripts/lib/feedback-policy-helpers.sh
#     # resolve_required_tiers) — true iff this finding's tier is one the
#     # codex-p1-gate would block merge on. Absent feedback_policy block ⇒
#     # only P1 is blocking. An unmarked (P?) finding is never blocking.
#     # `discretionary` (#1673) independently uses
#     # resolve_tiers_by_disposition discretionary; absent policy defaults to
#     # P2/P3/nitpick. An unmarked finding is neither. The new flag is report-only.
#     "reaction": null | {
#       "content": "+1",
#       "created_at": "<iso-8601>",
#       "reaction_id": N
#     },
#     "verdict": null | {
#       "created_at": "<iso-8601>",
#       "affirmative": true | false
#     },
#     "blocked_reason": null | "usage_limit" | "not_connected",
#     # Account-/connection-level failure marker (#722). Set when the Codex
#     # bot answered the trigger with a quota-exhaustion ("usage_limit") or
#     # app-not-connected ("not_connected") comment instead of a review. It
#     # short-circuits the poll (re-polling/re-triggering cannot clear it)
#     # and the script exits 4 (FALLBACK_REQUIRED) so the caller routes to
#     # Phase 4b — but with the real cause named rather than a generic
#     # timeout. Detected via the shared regexes in
#     # scripts/lib/codex-failure-markers.sh, the same patterns
#     # audit-codex-latency.sh classifies. null on the normal signal/timeout
#     # paths.
#     # HEAD-anchored Codex issue-comment verdict (#600/#567), recognized by
#     # this poller as of #609. "affirmative" mirrors codex-review-check.sh's
#     # CODEX_HEAD_VERDICT_TIME matcher: true only for the stable "Codex
#     # Review: Didn't find any major issues" phrasing. A non-null,
#     # non-affirmative verdict is still a real Codex response (has_signal
#     # true) but does not clear (has_cleared_signal false) — fails closed.
#     "terminal_determination": null | {
#       "provider": "codex",
#       "outcome": "timeout",
#       "marker_comment_id": N
#     },
#     # #1085: a normal bounded timeout is recorded as an author-owned,
#     # exact-head hidden PR comment bound to the confirmed trigger comment.
#     # Phase 4b consumes that durable record instead of waiting a second time.
#     # Account/connection blocks remain distinct through blocked_reason here;
#     # the later codex-review-check.sh --diagnostic-signal-only probe maps the
#     # provider-authored evidence to its Phase 4b exit-2 waiver.
#     "trigger_posted": true | false,
#     "request_checkpoint": null | {after, counted_requests, recorded, comment_id},
#     # #2657: set when this run's new request found the PR already at five
#     # or more counted requests. recorded is "posted", "existing" or "failed";
#     # it is informational and never changes the exit code.
#     "request_resumed": true | false,
#     # true when this invocation waited on an earlier unanswered request on
#     # the current head instead of posting one (#1550, #2664). Present only
#     # on this terminal JSON (exit 0 / 4); the --trigger-only, exit 5, exit 7
#     # and timeout-reuse outputs omit it. On a resume, rounds_waited_seconds
#     # counts from the resumed request's posting, so it includes time before
#     # this run started.
#     "codex_run": {request_comment_id, diagnostic, final_state,
#                   overlapping_request, handoff, provider_window},
#     # #2664, polling runs only: what Codex's Review Summary row said about
#     # the waited-on request. diagnostic is the state recorded at 300 s (or
#     # null); final_state is the state at the end of the wait (active,
#     # unknown, failed, canceled, completed, ambiguous, or answered).
#     # "ambiguous" means another request on this head overlaps, so the row
#     # cannot be tied to this one. provider_window is a retry window Codex
#     # stated, as {seconds, not_before}. All of it is reporting only: no
#     # state here posts, retries, cancels or clears anything. handoff is
#     # "timeout-recorded" or "unattributed" when the wait ended unanswered:
#     # a held request without a strong head tie records no determination.
#     "trigger_requested": true | false,
#     "rounds_waited_seconds": N
#   }
#
# Exit codes:
#   0   Codex signal received on current HEAD. JSON on stdout.
#   3   API / infrastructure error. Error message on stderr.
#   4   FALLBACK_REQUIRED — no Codex signal on current HEAD. The caller
#       should route to REVIEW_POLICY.md § Phase 4b. See #27 for the
#       explicit-review-required decision that mandates this path. Two
#       sub-cases, distinguished by the `blocked_reason` field in the JSON:
#       a plain timeout (blocked_reason:null) waited out the full window and
#       successfully recorded terminal_determination for this exact head
#       (or preserves that validated determination for the same capped request),
#       whereas a detected account-/connection-level block
#       (blocked_reason:"usage_limit"|"not_connected", #722) short-circuits
#       the wait immediately — re-polling/re-triggering cannot help until a
#       human upgrades/connects the account, so the handoff should name the
#       real cause rather than "wait longer."
#   5   NO_TRIGGER_REQUESTED — the Phase 4a entry decision (#486) chose
#       NOT to request a Codex review on this PR: either codex.enabled is
#       false (route to Phase 4b), or codex.request_by_default is false
#       or unset and the PR is not Phase-4a-gated: the caller did not flag it
#       and the derivation (#2257) read no needs-external-review label, a
#       line count under the threshold, and no protected path. JSON on stdout with trigger_requested:false and all Codex
#       signals null. This is a deliberate skip, not an error or a
#       timeout.
#   6   FEEDBACK_UNACCOUNTED — at least one earlier reviewer finding has no
#       durable disposition evidence. No new trigger is posted. Account for
#       every reported finding, then rerun this script (#1000).
#   7   CAP_EXHAUSTED — no new request is permitted, for one of two reasons
#       named by `cap_exhausted.kind` (#1560 slice 3):
#         blocking-reviews  the PR already holds max_blocking_reviews (default
#                           10) solicited blocking Codex reviews. Checked
#                           first, so it wins when both budgets are spent.
#         request-ceiling   the per-PR request-attempt cap is reached.
#       JSON on stdout names both consumed and configured counts; the caller
#       retains its existing review policy. Exhaustion adds no routing or
#       merge authority. Any observed provider block is diagnostic-only and
#       never grants Phase 4b routing authority. This requester-specific
#       status is not Phase 4b's exit-7 contract.
#   8   MOVING_HEAD — the head does not look final for a review round
#       (#2166): it is younger than codex.request_min_head_age_seconds
#       (measured from the later of the HEAD pushed-at anchor -- committer
#       date or last force-push -- and the push dispatch, i.e. the latest
#       repo-lint run for the head on the PR branch), or CI has not picked
#       the head up yet: no `repo-lint` workflow run exists for the head SHA
#       on the PR's branch (or, with the
#       codex.request_requires_check override, no check-run by that exact
#       name). A repo with no repo-lint workflow at all is not refused on
#       that signal. No trigger is posted. A Codex request is posted once per BATCH -- every known
#       finding addressed, local tests green, no further push planned --
#       because a request on a head that is still moving draws findings
#       against a commit the agent has already replaced, and each such round
#       costs about fifty minutes of wall-clock (Codex answer + fix push +
#       the lint run on the new head). Rerun once the head has settled, or
#       pass --allow-moving-head to post with a warning. JSON on stdout
#       carries the observations under `moving_head`. An automatic caller
#       (MERGEPATH_CODEX_AUTO_TRIGGER) is exempt: it fires on a provider
#       event, not on a push the agent is still amending, and a refusal
#       there would strand the head with no caller left to re-request.
#
# Design notes:
#   - Writes only author-attributed PR comments: the `@codex review` trigger,
#     and on an ordinary timeout one hidden exact-head terminal-determination
#     marker (#1085). Does not push commits, modify labels, or merge.
#   - Idempotent. Re-running on the same PR with the same HEAD is safe:
#     it will see the existing Codex response and skip the trigger.
#   - JSON emission uses `jq` throughout. No ad-hoc string concatenation.
#
# References:
#   - Project #2 — External Review (Phase 4 Review)
#   - #34 — this script
#   - #29 — live observations behind the dual-endpoint / reaction polling
#   - #419 — eyes acknowledgment gate + bounded re-trigger
#   - REVIEW_POLICY.md § Phase 4a (canonical policy)

set -euo pipefail

# --- preflight auto-source (#282) ------------------------------------------
# Auto-source the op-preflight cache when GH_TOKEN is unset and a fresh
# cache exists for this agent. No-op when GH_TOKEN is already set.
__CODEX_REQUEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$__CODEX_REQUEST_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__CODEX_REQUEST_DIR/lib/preflight-helpers.sh"
  # Author PAT is correct because every PR comment this helper may write is
  # author-owned: each `@codex review` trigger (including bounded retries)
  # and, after an ordinary timeout, the exact-head timeout determination.
  # The wrapper verifies that token before posting any such comment.
  preflight_require_token author || true
fi

# --- Codex failure-marker regexes (#722) ------------------------------------
# Source the shared usage-limit / not-connected marker patterns so the poll
# loop can recognize an account-level quota or app-not-connected comment and
# short-circuit the wait instead of running out the full review timeout (the
# generic-timeout failure described in #722). Existence-guarded like the
# preflight source above: a consumer in the middle of a sync skew may not yet
# carry the lib, in which case marker detection degrades to the pre-#722
# behavior (run to timeout) rather than hard-erroring — the lib is declared
# as a `requires:` of this script so the skew window is short.
CODEX_FAILURE_MARKERS_OK=false
if [ -r "$__CODEX_REQUEST_DIR/lib/codex-failure-markers.sh" ]; then
  # shellcheck source=lib/codex-failure-markers.sh
  . "$__CODEX_REQUEST_DIR/lib/codex-failure-markers.sh"
  CODEX_FAILURE_MARKERS_OK=true
fi

# --- scalar API reads that must fail closed (#799) --------------------------
# Hard-required, unlike the marker lib above: the one call site is the
# post-trigger timestamp that anchors every "is this review newer than my
# trigger?" comparison, and its documented wall-clock fallback was dead. A
# degraded mode here is a wrong anchor, not a lost feature. Declared as a
# `requires:` of this script in .mergepath-sync.yml.
if [ ! -r "$__CODEX_REQUEST_DIR/lib/gh-api-scalar.sh" ]; then
  echo "[codex-review-request] ERROR: missing helper: $__CODEX_REQUEST_DIR/lib/gh-api-scalar.sh (see #799)" >&2
  exit 3
fi
# shellcheck source=lib/gh-api-scalar.sh
. "$__CODEX_REQUEST_DIR/lib/gh-api-scalar.sh"

# --- paginated LIST reads that must fail closed (#1008) ---------------------
# The array twin of the scalar reader above, and hard-required for the same
# reason: every signal this script scans for — reviews, inline comments,
# reactions, issue comments, the timeline — arrives through it, and an
# undefined reader would surface as `command not found` on all of them.
# Declared as a `requires:` of this script in .mergepath-sync.yml.
if [ ! -r "$__CODEX_REQUEST_DIR/lib/gh-api-array.sh" ]; then
  echo "[codex-review-request] ERROR: missing helper: $__CODEX_REQUEST_DIR/lib/gh-api-array.sh (see #1008)" >&2
  exit 3
fi
# shellcheck source=lib/gh-api-array.sh
. "$__CODEX_REQUEST_DIR/lib/gh-api-array.sh"

# --- transient-failure classifier (#1550) ------------------------------------
# gh_failure_is_permanent decides whether a failed poll read is worth retrying.
# Declared as a `requires:` of this script. Existence-guarded: without it every
# read failure is treated as permanent, which is exactly the pre-#1550
# behaviour (exit 3 on the first failed scan), never a weaker one.
if [ -r "$__CODEX_REQUEST_DIR/lib/gh-retry-helpers.sh" ]; then
  # shellcheck source=lib/gh-retry-helpers.sh
  . "$__CODEX_REQUEST_DIR/lib/gh-retry-helpers.sh"
fi
if ! declare -F gh_failure_is_permanent >/dev/null 2>&1; then
  gh_failure_is_permanent() { return 0; }
fi

# --- argument parsing -------------------------------------------------------

# The exact invocation, kept for the #1550 resume-expiry re-run below.
__CRR_ORIGINAL_ARGS=("$@")

# #489: --trigger-only posts (or confirms) the @codex review trigger and
# returns WITHOUT polling for clearance. coderabbit-wait.sh's rate-limit
# failover uses it so a rate-limited PR advances via Codex without the wait
# helper blocking on Codex's full review. Extract the flag, leave positionals.
# #2166: --allow-moving-head downgrades the moving-head refusal (exit 8) to a
# warning. See refuse_moving_head_unless_allowed below.
# #2534: --failover is --trigger-only plus a failover marker on a posted trigger.
TRIGGER_ONLY=false
FAILOVER=false
AUTHORIZE_TRIGGER_WRITE=false
ALLOW_MOVING_HEAD=false
__POSITIONAL=()
for __arg in "$@"; do
  case "$__arg" in
    --trigger-only) TRIGGER_ONLY=true ;;
    --failover) FAILOVER=true; TRIGGER_ONLY=true ;;
    --authorize-trigger-write) AUTHORIZE_TRIGGER_WRITE=true; TRIGGER_ONLY=true ;;
    --allow-moving-head) ALLOW_MOVING_HEAD=true ;;
    *) __POSITIONAL+=("$__arg") ;;
  esac
done
set -- ${__POSITIONAL[@]+"${__POSITIONAL[@]}"}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 [--trigger-only] [--failover] [--allow-moving-head] <PR_NUMBER> [REPO]" >&2
  echo "  --trigger-only       post/confirm the @codex trigger, then exit 0 (no clearance poll)" >&2
  echo "  --failover           --trigger-only for the CodeRabbit rate-limit failover; marks the trigger it posts" >&2
  echo "  --allow-moving-head  post even when the head is younger than codex.request_min_head_age_seconds" >&2
  echo "                       or CI has not picked it up yet (warns instead of exit 8)" >&2
  echo "  PR_NUMBER       pull request number (integer)" >&2
  echo "  REPO            owner/repo (optional; defaults to current repo)" >&2
  exit 3
fi

PR_NUMBER=$1
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: PR_NUMBER must be an integer; got '$PR_NUMBER'" >&2
  exit 3
fi

# This dependency must be usable before deduplication or any trigger write.
# shellcheck source=lib/codex-request-evidence.sh
if [ ! -r "$__CODEX_REQUEST_DIR/lib/codex-request-evidence.sh" ] \
  || ! . "$__CODEX_REQUEST_DIR/lib/codex-request-evidence.sh" \
  || ! declare -F crqe_select_trigger crqe_count_triggers crqe_ack_present crqe_request_threshold crqe_select_head_review crqe_review_approval_time >/dev/null; then
  echo "[codex-review-request] ERROR: request evidence helper unavailable (see #1276)" >&2
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

# GH_TOKEN write-token resolution is DEFERRED to just after author_identity
# is parsed from review-policy.yml (below). That ordering lets the #737
# keyring fallback resolve `gh auth token --user <author_identity>` when the
# op-preflight cache has lapsed — the author identity must be known first.
# See the "write-token resolution (#737)" block after AUTHOR_IDENTITY.

# --- config readers ---------------------------------------------------------

# Runtime knobs retain the SCRIPT's checkout, not $PWD (Codex P2 on #2175).
# The entry decision below materializes REPO's governing base policy for its
# enabled/request_by_default switches (#2273).
# A cwd-relative path read no file at all when the script ran from a
# subdirectory or by absolute path from elsewhere, and every codex: key then
# took its default -- request_by_default then to true (since #2240 a
# missing file instead requests with a warning), the moving-head knobs to
# their defaults. A hand install with no policy beside
# it keeps the cwd-relative read it always had.
CONFIG="$__CODEX_REQUEST_DIR/../.github/review-policy.yml"
[ -f "$CONFIG" ] || CONFIG=".github/review-policy.yml"

# Extract a scalar field from the codex: block in review-policy.yml.
# Uses the state-machine awk pattern established in #54 (stops at the next
# top-level key, tolerates column-0 comments). Returns empty string if the
# field is not present, which the caller should turn into a default.
codex_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^codex:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block {
      # Match "  field: value" or a value wrapped in double OR single
      # quotes. Strip BOTH quote styles (\047 = single quote) so a
      # single-quoted boolean (valid YAML) survives the == "true"
      # entry-gate checks below. Matches the quote-tolerance of the
      # codex_field parser in scripts/codex-review-check.sh and the
      # workflow parser tests.
      if ($1 == field":") {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
        gsub(/^["\047]/, "", $0)
        gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
        gsub(/[[:space:]]*#.*$/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        print
        exit
      }
    }
  ' "$CONFIG"
}

# Extract a top-level scalar (column-0 key, no enclosing block) from
# review-policy.yml — e.g. author_identity. Same quoting/comment
# tolerance as codex_field.
policy_top_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^[^[:space:]#]/ && $1 == field":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      # Both YAML quote styles (Codex P2 on PR #442 r9) — matching the
      # quote-tolerance of the gh-pr-guard expected-author parser.
      gsub(/^["\x27]/, "", $0)
      gsub(/["\x27][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

# Author identity for the trigger and timeout-determination comment writes
# (#438/#1085): used to decide whether an ambient GH_TOKEN may be bridged
# into gh-as-author.sh.
AUTHOR_IDENTITY=$(policy_top_field author_identity)
AUTHOR_IDENTITY=${AUTHOR_IDENTITY:-nathanjohnpayne}

# --- write-token resolution (#737) ------------------------------------------
# Resolve a GitHub token for this helper's API reads and its author-owned PR
# comment writes (the `@codex review` trigger and exact-head timeout
# determination, both posted through gh-as-author.sh). Two independent
# sources satisfy it, tried in order:
#
#   1. GH_TOKEN already in the environment — exported inline by the caller,
#      or auto-sourced from a FRESH op-preflight cache by
#      preflight_require_token above.
#   2. The gh keyring's stored author account: `gh auth token --user
#      <author_identity>`. This fallback closes the #737 gap. In a
#      long-running session the op-preflight cache TTL (36000s = 10h since
#      #765) can lapse, leaving GH_TOKEN unset even though the keyring still
#      has the author account authenticated. Before #737 the hard guard exited 3
#      WITHOUT ever posting the trigger, so `@codex review` silently no-op'd;
#      callers that pipe `| tail -1` and ignore the exit code then proceeded
#      to merge as if Codex had been asked (observed on gaycruisebingo PRs
#      #78/#79 — 0 triggers posted). The keyring fallback lets the trigger
#      succeed whenever EITHER source is available.
#
# author_identity (parsed from review-policy.yml above) is the account the
# trigger and timeout determination must be attributed to — Codex ignores
# non-author triggers, and Phase 4b accepts only trusted author markers. It is
# the identity post_author_pr_comment writes as via gh-as-author.sh, so a
# keyring token for it also bridges cleanly into either write (#438/#1085).
if [ -z "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  GH_TOKEN=$(gh auth token --user "$AUTHOR_IDENTITY" 2>/dev/null || true)
  if [ -n "$GH_TOKEN" ]; then
    export GH_TOKEN
    echo "[codex-review-request] GH_TOKEN was unset and no fresh op-preflight cache was found — resolved the author token from the gh keyring for '$AUTHOR_IDENTITY' (#737)" >&2
  fi
fi
if [ -z "${GH_TOKEN:-}" ]; then
  # Fail LOUD (#737): a caller that pipes `| tail -1` and ignores the exit
  # code must NOT mistake a non-post for a completed request. Non-zero exit
  # plus an unmissable stderr banner naming the two exhausted sources.
  echo "ERROR: could not resolve a GitHub token to post the '@codex review' trigger." >&2
  echo "       The '@codex review' trigger was NOT posted — do NOT treat Codex as requested (#737)." >&2
  echo "       Tried, in order:" >&2
  echo "         1. an already-exported GH_TOKEN / fresh op-preflight cache" >&2
  echo "            (run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode review)\")" >&2
  echo "         2. the gh keyring author account '$AUTHOR_IDENTITY'" >&2
  echo "            (authenticate once with: gh auth login)" >&2
  exit 3
fi

# review_timeout_seconds: foreground poll budget for a Codex terminal signal
# on HEAD, measured from the trigger it waits on. Default 1800s (#1550),
# remeasured from 243 author-posted triggers on mergepath and nathanpaynedotcom
# between 2026-09-14 and 2026-10-01: trigger→first Codex response p50 370s /
# p90 745s / p95 982s / max 1723s, with 19 responses past the previous 840s
# default and none past 1800s. On 2026-09-30 alone the p90 was 1225s. Each of
# those 19 timed out at 840s, routed to Phase 4b, and then drew a real Codex
# review that could invalidate the Phase 4b result. 1800s = 120 × the 15s
# POLL_INTERVAL, so the final poll lands on the deadline. The earlier 840s
# retune and its 2026-07 sample are in #623.
# It is deliberately NOT sized to the dropped/rate-limited non-response tail
# (#570): that is not a slow verdict and no foreground wait can catch it —
# --trigger-only + event-driven pickup remains its escape path (#489).
TIMEOUT_SECONDS=$(codex_field review_timeout_seconds)
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-1800}
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.review_timeout_seconds must be an integer; got '$TIMEOUT_SECONDS'" >&2
  exit 3
fi

BOT_LOGIN=$(codex_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"chatgpt-codex-connector[bot]"}

# --- blocking-tier surfacing (#577) -----------------------------------------
# Source the shared feedback-policy resolver so each emitted finding can
# carry `blocking: true|false` derived from the SAME resolve_required_tiers
# the codex-p1-gate uses. This is purely additive to the JSON contract — it
# never changes the exit-code behavior below. Absent feedback_policy block
# ⇒ blocking set {p1}, so only P1 findings are marked blocking (today's
# de-facto gate scope). rc 2 = malformed; a benign non-2 tail status (rc 1
# when the last tier isn't required) is ignored, mirroring codex-p1-gate.sh.
#
# The source is GUARDED (same posture as the preflight-helpers source
# above): in some test harnesses this script is copied to a scratch tree
# WITHOUT scripts/lib, so we degrade to the documented absent-block default
# ({p1}) rather than hard-erroring — surfacing is a best-effort convenience,
# not a merge gate. The gate scripts (codex-p1-gate.sh) always run from the
# full checkout and DO source the lib unconditionally.
__CODEX_REQ_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# #1100: resolve_base_policy.sh --materialize-default hands ITS CALLER ownership
# of a temp policy file. The accounting gate below materializes one, and an
# eyes-ack retry re-enters that gate, so an inline rm on the success path alone
# would leak one file per attempt on a long-lived runner (and every `die` path
# would leak unconditionally). review-feedback-accounting.sh:54 solves the same
# problem with one EXIT trap over one variable; this mirrors it.
# run_trigger_ack_gate re-posts the trigger up to MAX_ACK_RETRIES times, and
# every re-post re-enters the accounting gate and materializes ANOTHER policy
# file. A single-variable trap would remove only the last one, so each prior
# retry's file would survive on a long-lived runner. Retiring the previous path
# at the moment the next one is assigned keeps exactly one file live, and the
# trap removes that one.
__CRA_BASE_CFG_TMP=""
__CRA_ENTRY_CFG_TMP=""
__cra_retire_base_cfg() { # <new-path-or-empty>
  if [ -n "$__CRA_BASE_CFG_TMP" ] && [ "$__CRA_BASE_CFG_TMP" != "${1:-}" ]; then
    rm -f "$__CRA_BASE_CFG_TMP"
  fi
  __CRA_BASE_CFG_TMP="${1:-}"
}
trap '__cra_retire_base_cfg ""; [ -z "$__CRA_ENTRY_CFG_TMP" ] || rm -f "$__CRA_ENTRY_CFG_TMP"' EXIT
REQUIRED_TIERS_JSON='["p1"]'
DISCRETIONARY_TIERS_JSON='["p2","p3","nitpick"]'
if [ -r "$__CODEX_REQ_LIBDIR/lib/feedback-policy-helpers.sh" ]; then
  # shellcheck source=lib/feedback-policy-helpers.sh
  . "$__CODEX_REQ_LIBDIR/lib/feedback-policy-helpers.sh"
  set +e
  __REQUIRED_TIERS=$(resolve_required_tiers "$CONFIG")
  __RT_RC=$?
  set -e
  if [ "$__RT_RC" -eq 2 ]; then
    echo "ERROR: malformed feedback_policy block in $CONFIG (resolve_required_tiers exit 2)" >&2
    exit 3
  fi
  # JSON array of required tiers (lowercase p0..p3|nitpick) for jq
  # membership tests. Empty input ⇒ [].
  REQUIRED_TIERS_JSON=$(printf '%s\n' "$__REQUIRED_TIERS" \
    | jq -R . | jq -s 'map(select(. != ""))')
  # Disposition defaults differ from the legacy gate set: P0 is not
  # discretionary merely because an absent policy blocks only P1 (#1673).
  # Keep this advisory decoration from changing the requester's exits.
  __DISCRETIONARY_TIERS=$(resolve_tiers_by_disposition discretionary "$CONFIG" || true)
  DISCRETIONARY_TIERS_JSON=$(printf '%s\n' "$__DISCRETIONARY_TIERS" \
    | jq -R . | jq -s 'map(select(. != ""))')
fi

# --- Phase 4a entry decision (#486) -----------------------------------------
# Two codex: block keys govern whether this run posts an `@codex review`
# trigger at all, BEFORE any of the per-HEAD signal scanning below:
#
#   codex.enabled            — whether Codex participates as a reviewer.
#                              Absent ⇒ true (matches codex-review-check.sh).
#                              When false, Phase 4a is OFF entirely: this
#                              script never triggers, regardless of
#                              request_by_default. The caller routes to
#                              Phase 4b.
#   codex.request_by_default — whether `@codex review` is requested on
#                              EVERY PR, not only the threshold/path-gated
#                              ones. Absent ⇒ false (owner decision
#                              2026-10-15, #2240; it was true under #486).
#                              When false, the trigger is gated on the
#                              caller's Phase 4a entry signal
#                              (MERGEPATH_PHASE_4A_GATED), the pre-#486
#                              threshold-only behavior. Read by
#                              resolve_request_by_default below, which
#                              fails toward REQUESTING on any policy it
#                              cannot read.
#
# request_by_default is ORTHOGONAL to enabled: it only governs WHEN the
# trigger is posted and has no effect when Codex is disabled.
#
# MERGEPATH_PHASE_4A_GATED is how the caller (the authoring agent, or a
# workflow) tells this worker that the PR independently qualifies for
# Phase 4a (lines ≥ external_review_threshold, a file matches
# external_review_paths, or the PR carries needs-external-review). Set it
# to `true`/`1` for a gated PR: that PR is requested whatever
# request_by_default says, because Phase 4 review is mandatory, and no PR
# read is spent on the decision. When the flag is unset/false and
# request_by_default resolves to false, the script derives the gate from the
# PR itself (derive_phase_4a_gate, #2257) before it would skip: consumers'
# per-repo docs call this script without the flag, and a Phase 4 PR must not
# lose its mandatory request because of that. Only a PR the derivation reads
# as under-threshold is skipped (exit 5, NO_TRIGGER_REQUESTED).
CODEX_ENABLED=true

# Resolve codex.request_by_default (#2240). Sets REQUEST_BY_DEFAULT to
# true|false and REQUEST_BY_DEFAULT_SOURCE to explicit|unset|failsafe.
#
#   explicit  the key holds a YAML boolean; its value is used.
#   unset     the policy parses, and the key (or the whole codex: key) is
#             absent: false, the owner-decided default since #2240.
#   failsafe  the policy cannot be trusted to answer, so the trigger IS
#             requested, with a warning naming the cause: the file is
#             missing, no YAML parser is available, the file does not parse
#             or holds more than one document, the root or codex: is not a
#             mapping, codex: is present but empty or null, the key or the
#             codex: block is duplicated in any YAML style, or the value is
#             not a boolean (a quoted 'false' is a string, not a boolean).
#
# The two outcomes are not symmetric: requesting wrongly costs one Codex
# round, while skipping wrongly silently drops a review. So a skip needs a
# real parser's answer, the same rule coderabbit-should-invoke.sh applies
# to its suppressing decisions; codex_field's awk reader cannot tell an
# absent key from a file it failed to read.
#
# Presence is tested with has(), never with `//`: yq's alternative operator
# treats an explicit `false` like null, so `.request_by_default // "x"`
# reports an explicit false as missing. go-yaml resolves a duplicated key
# last-wins without complaint, so duplicates are counted separately, through
# the parser's own key list so that every spelling is seen.
# MERGEPATH_YQ_BIN is a test seam for the parser-unavailable path.
REQUEST_BY_DEFAULT=""
REQUEST_BY_DEFAULT_SOURCE=""
request_by_default_failsafe() {  # <cause>
  REQUEST_BY_DEFAULT="true"
  REQUEST_BY_DEFAULT_SOURCE=failsafe
  echo "[codex-review-request] WARN: cannot read codex.request_by_default: $1 — requesting Codex anyway (an unreadable policy never opts out of review, #2240)" >&2
}
resolve_request_by_default() {
  local yq_bin=${MERGEPATH_YQ_BIN:-yq} docs root_type codex_count codex_type key_count present tag value
  if [ ! -f "$CONFIG" ]; then
    request_by_default_failsafe "policy file not found ($CONFIG)"
    return 0
  fi
  if ! command -v "$yq_bin" >/dev/null 2>&1 \
     && [ "$yq_bin" = "yq" ] \
     && [ -x "$__CODEX_REQUEST_DIR/lib/ensure-yq.sh" ]; then
    bash "$__CODEX_REQUEST_DIR/lib/ensure-yq.sh" --ci-only >/dev/null 2>&1 || true
  fi
  if ! command -v "$yq_bin" >/dev/null 2>&1; then
    request_by_default_failsafe "no YAML parser (yq) is available to verify $CONFIG; install mikefarah/yq v4"
    return 0
  fi
  if ! docs=$("$yq_bin" eval-all -o=json '[.] as $d ireduce ([]; . + $d) | length' "$CONFIG" 2>/dev/null); then
    request_by_default_failsafe "$CONFIG is not valid YAML"
    return 0
  fi
  if [ "$docs" != "1" ]; then
    request_by_default_failsafe "$CONFIG must hold exactly one YAML document (found $docs)"
    return 0
  fi
  root_type=$("$yq_bin" 'type' "$CONFIG" 2>/dev/null) || root_type=""
  if [ "$root_type" != "!!map" ]; then
    request_by_default_failsafe "$CONFIG is not a YAML mapping"
    return 0
  fi
  # Duplicates are counted by the parser, not by scanning lines: yq's `keys`
  # keeps every duplicated key in any style (block, flow, quoted), while the
  # value read resolves them last-wins. A line scan missed the flow and
  # quoted spellings (#2245).
  codex_count=$("$yq_bin" '[keys[] | select(. == "codex")] | length' "$CONFIG" 2>/dev/null) || codex_count="?"
  case "$codex_count" in
    0)
      # The codex: key is absent altogether: unset, the #2240 default.
      REQUEST_BY_DEFAULT="false"
      REQUEST_BY_DEFAULT_SOURCE="unset"
      return 0 ;;
    1) ;;
    *[!0-9]*|"")
      request_by_default_failsafe "the parser could not count codex: keys in $CONFIG"
      return 0 ;;
    *)
      request_by_default_failsafe "$CONFIG has $codex_count codex: blocks"
      return 0 ;;
  esac
  codex_type=$("$yq_bin" '.codex | type' "$CONFIG" 2>/dev/null) || codex_type="?"
  case "$codex_type" in
    "!!map") ;;
    "!!null")
      # Present but empty or null (`codex:`, `codex: null`, `codex: ~`): a
      # block that says nothing is a malformed policy, not an absent one
      # (#2245). Only a missing codex: key means unset.
      request_by_default_failsafe "codex: in $CONFIG is present but empty or null"
      return 0 ;;
    *)
      request_by_default_failsafe "codex: in $CONFIG is not a mapping"
      return 0 ;;
  esac
  key_count=$("$yq_bin" '[.codex | keys[] | select(. == "request_by_default")] | length' "$CONFIG" 2>/dev/null) || key_count="?"
  case "$key_count" in
    0|1) ;;
    *[!0-9]*|"")
      request_by_default_failsafe "the parser could not count codex.request_by_default keys in $CONFIG"
      return 0 ;;
    *)
      request_by_default_failsafe "$CONFIG has $key_count codex.request_by_default keys"
      return 0 ;;
  esac
  present=$("$yq_bin" '.codex | has("request_by_default")' "$CONFIG" 2>/dev/null) || present="?"
  case "$present" in
    false)
      REQUEST_BY_DEFAULT="false"
      REQUEST_BY_DEFAULT_SOURCE="unset"
      return 0 ;;
    true) ;;
    *)
      request_by_default_failsafe "the parser could not test for the key in $CONFIG"
      return 0 ;;
  esac
  tag=$("$yq_bin" '.codex.request_by_default | tag' "$CONFIG" 2>/dev/null) || tag="?"
  value=$("$yq_bin" '.codex.request_by_default' "$CONFIG" 2>/dev/null) || value="?"
  if [ "$tag" = "!!bool" ]; then
    case "$value" in
      true|True|TRUE) REQUEST_BY_DEFAULT="true"; REQUEST_BY_DEFAULT_SOURCE=explicit; return 0 ;;
      false|False|FALSE) REQUEST_BY_DEFAULT="false"; REQUEST_BY_DEFAULT_SOURCE=explicit; return 0 ;;
    esac
  fi
  request_by_default_failsafe "value '$value' (YAML tag $tag) is not a boolean"
}

# Normalize the caller's gate signal to a strict true/false. Accept the
# common truthy spellings; anything else (including unset) is false.
PHASE_4A_GATED=false
PHASE_4A_GATE_REASON=""
case "${MERGEPATH_PHASE_4A_GATED:-}" in
  true|TRUE|True|1|yes|YES) PHASE_4A_GATED=true ;;
esac

# --- Phase 4a gate derivation (#2257) ----------------------------------------
# With request_by_default unset or false, a PR is requested only when it is
# Phase-4a-gated. Callers that follow this repo's AGENTS.md pass
# MERGEPATH_PHASE_4A_GATED=true, but consumers' per-repo docs (never
# propagated) still show the bare call, so a Phase 4 PR there would lose its
# mandatory request (Codex P1 on nathanpaynedotcom#1378). When the caller has
# not set the flag, the gate is derived from the PR itself. It is gated when
# any of these holds, checked in this order and reported by the first that
# fires:
#
#   label      the PR carries needs-external-review (the labeler's verdict
#              under the governing policy, or a human's force-on);
#   size       lines changed >= external_review_threshold (default 300 when
#              the key is absent), counted with the labeler's generated-file
#              exclusion, the EXCLUDE_RE constant read from
#              external_review_fingerprint.sh at the PR's base sha; a
#              listing at GitHub's 3000-file cap is gated outright;
#   paths      a changed file, or a rename's source, matches the
#              external_review_paths patterns that scripts/workflow/
#              parse_policy_list.sh prints, through scripts/workflow/
#              match_protected_paths.sh: the labeler's parser and matcher,
#              both loaded from the PR's base sha.
#
# READER PARITY (Codex P1 x4 on #2258). Every input is read with the reader
# the labeler (pr-review-policy.yml through external_review_fingerprint.sh)
# or the merge clearance gate uses, never with a reader of its own: the label
# from the PR's label list; the size from the paginated file list with
# EXCLUDE_RE; the threshold from the raw top-level line's second token; the
# paths from parse_policy_list.sh; the match from match_protected_paths.sh.
# The policy text, the exclusion constant, the parser and the matcher all
# come from the base revision, never from this checkout, which may be another
# repository or the candidate's own edit. The parser and the matcher are
# code, so the base copies are read as data and only this requester's
# byte-identical own copy runs (#2272, below). No YAML parser reads the
# policy here.
#
# FAIL-SAFE (owner rule): any input that cannot be read counts as gated, and
# the PR is requested with a WARN naming the cause. That includes the PR
# metadata, its label list, the paginated file list, a file list that is
# EMPTY or disagrees with the PR's changed_files count (a short read is not a
# small PR), the governing base policy, a threshold the labeler would not
# read as written, the base copies of the exclusion constant, the parser and
# the matcher (including a base copy that is not byte-identical to this
# requester's own), and a PR whose head, base, default branch or labels changed
# during the reads. A skip therefore needs every signal positively read as
# "not gated" for one snapshot of the PR.
#
# FETCHED CODE NEVER RUNS (#2272). The parser and the matcher are code, and
# the base can be any branch the PR targets, including an unprotected one.
# This script usually runs with the author or reviewer PAT reachable: in its
# environment (GH_TOKEN, OP_PREFLIGHT_*), in its parent's environment, and in
# the op-preflight cache under $HOME. Stripping the child's environment does
# not stop same-user code from reading the other two (Codex P1 on #2277), so
# the base copies are never executed. Each is fetched as DATA and compared
# byte for byte with this requester's own copy beside it, which travels with
# it (requires: in .mergepath-sync.yml). Only that own copy runs, and only
# when the bytes are identical, so labeler parity holds exactly: the code
# that runs IS the base revision's helper. A base copy that differs, or a
# missing own copy, takes the fail-safe and requests: version skew or a
# candidate's edit costs a Codex request, never a skipped one.
#
# The own copy still runs through run_policy_helper, which starts it with an
# empty environment plus PATH (to find bash and awk) and a verified LC_ALL:
# neither helper reads anything else, and an empty environment keeps a
# future helper from silently depending on a credential. Probe UTF-8
# character semantics instead of trusting a locale spelling (#2315): the
# matcher compiles `?` to `[^/]`; under C a
# multibyte character in a file name is several characters, so `?` would
# match LESS than the labeler: the unsafe direction. The EXCLUDE_RE read
# executes nothing (jq decodes the file and sed extracts one line).
run_policy_helper() {  # <script> [args...]; stdin passes through
  local policy_locale
  for policy_locale in C.UTF-8 en_US.UTF-8; do
    # The child must evaluate the sample under its own effective locale.
    # shellcheck disable=SC2016
    if env -i PATH="$PATH" LC_ALL="$policy_locale" bash -c \
      'sample=$(printf "\303\251"); [ "${#sample}" -eq 1 ] && [[ $sample =~ ^[^/]$ ]]' \
      >/dev/null 2>&1; then
      env -i PATH="$PATH" LC_ALL="$policy_locale" bash "$@"
      return $?
    fi
  done
  echo "[codex-review-request] no verified UTF-8 locale for policy helpers" >&2
  return 2
}
# Fetch a base helper as data and confirm it is byte-identical to this
# requester's own copy. Prints nothing; returns 0 when identical, else sets
# BASE_HELPER_CAUSE and returns 1. Args: <repo path> <base sha> <own copy>
BASE_HELPER_CAUSE=""
base_helper_matches_own() {
  local path=$1 sha=$2 own=$3 json fetched rc=0
  BASE_HELPER_CAUSE=""
  fetched=$(mktemp "${TMPDIR:-/tmp}/codex-request-helper.XXXXXX" 2>/dev/null) || fetched=""
  if [ -z "$fetched" ]; then
    BASE_HELPER_CAUSE="could not allocate a scratch file to read $path"
    return 1
  fi
  json=$(gh api "repos/$REPO/contents/$path?ref=$sha" 2>/dev/null) || json=""
  # -j: the decoded bytes exactly, with no newline appended, so the compare
  # below sees the file as committed.
  if ! printf '%s' "$json" | jq -j '.content | gsub("\n"; "") | @base64d' >"$fetched" 2>/dev/null \
     || [ ! -s "$fetched" ]; then
    BASE_HELPER_CAUSE="cannot read $path at $sha"
    rc=1
  elif [ ! -s "$own" ]; then
    BASE_HELPER_CAUSE="this requester has no copy of $path to run (it travels with the requester; fetched base code is never executed, #2272)"
    rc=1
  elif ! cmp -s "$fetched" "$own"; then
    BASE_HELPER_CAUSE="$path at $sha is not byte-identical to this requester's own copy; fetched base code is never executed (#2272)"
    rc=1
  fi
  rm -f "$fetched"
  return "$rc"
}
phase_4a_gate_failsafe() {  # <cause>
  PHASE_4A_GATED=true
  PHASE_4A_GATE_REASON="$1"
  echo "[codex-review-request] WARN: cannot derive the Phase 4 gate: $1 — treating the PR as Phase-4a-gated and requesting Codex (an unreadable input never skips a mandatory review, #2257)" >&2
}
phase_4a_gate_derived() {  # <reason>
  PHASE_4A_GATED=true
  PHASE_4A_GATE_REASON="$1"
  log "Phase 4 gate derived from the PR: $1 — requesting Codex (#2257)"
}
derive_phase_4a_gate() {
  local pr_json has_label changed_files files_json files_tmp files_count head_sha base_ref base_sha default_branch
  local base_cfg fp_json default_json default_sha raw_threshold raw_lines live_default
  local parser parser_rc paths_out
  local threshold exclude_re lines pattern matcher changed matched live_json live_fence rc=0
  local -a patterns=()

  pr_json=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>/dev/null) || {
    phase_4a_gate_failsafe "could not read the PR metadata for $REPO#$PR_NUMBER"
    return 0
  }
  if ! printf '%s' "$pr_json" | jq -e '
      type == "object"
      and (.labels | type) == "array"
      and all(.labels[]; type == "object" and ((.name | type) == "string"))
      and (.changed_files | type) == "number"' >/dev/null 2>&1; then
    phase_4a_gate_failsafe "the PR metadata for $REPO#$PR_NUMBER has no readable labels or changed_files count"
    return 0
  fi
  # The snapshot every later read is bound to: the head the decision is about
  # and the base whose policy governs it.
  head_sha=$(printf '%s' "$pr_json" | jq -r '.head.sha // "" | strings') || head_sha=""
  base_ref=$(printf '%s' "$pr_json" | jq -r '.base.ref // "" | strings') || base_ref=""
  base_sha=$(printf '%s' "$pr_json" | jq -r '.base.sha // "" | strings') || base_sha=""
  default_branch=$(printf '%s' "$pr_json" | jq -r '.base.repo.default_branch // "" | strings') || default_branch=""
  if [ -z "$head_sha" ] || [ -z "$base_ref" ] || [ -z "$base_sha" ] || [ -z "$default_branch" ]; then
    phase_4a_gate_failsafe "the PR metadata for $REPO#$PR_NUMBER has no readable head sha, base ref, base sha or default branch"
    return 0
  fi
  has_label=$(printf '%s' "$pr_json" | jq -r '[.labels[].name] | index("needs-external-review") != null') || has_label=""
  case "$has_label" in
    true) phase_4a_gate_derived "the PR carries the needs-external-review label"; return 0 ;;
    false) ;;
    *) phase_4a_gate_failsafe "could not test the PR labels for needs-external-review"; return 0 ;;
  esac
  changed_files=$(printf '%s' "$pr_json" | jq -r '.changed_files') || changed_files=""

  # Called in this shell, not in $( ), so GH_API_ARRAY_ERROR survives to name
  # the cause; the array goes through a scratch file.
  files_tmp=$(mktemp "${TMPDIR:-/tmp}/codex-request-files.XXXXXX" 2>/dev/null) || files_tmp=""
  if [ -z "$files_tmp" ]; then
    phase_4a_gate_failsafe "could not allocate a scratch file for the PR file list"
    return 0
  fi
  if ! gh_api_array "repos/$REPO/pulls/$PR_NUMBER/files" "PR files" >"$files_tmp"; then
    rm -f "$files_tmp"
    phase_4a_gate_failsafe "${GH_API_ARRAY_ERROR:-could not read the PR file list}"
    return 0
  fi
  files_json=$(cat "$files_tmp") || files_json=""
  rm -f "$files_tmp"
  if ! printf '%s' "$files_json" | jq -e '
      type == "array"
      and all(.[]; type == "object"
        and ((.filename | type) == "string") and (.filename | length) > 0
        and ((.additions | type) == "number") and ((.deletions | type) == "number")
        and ((.previous_filename == null) or ((.previous_filename | type) == "string")))' >/dev/null 2>&1; then
    phase_4a_gate_failsafe "the PR file list is not an array of file entries with filename, additions and deletions"
    return 0
  fi
  # The matcher reads one path per line, so a name containing a newline would
  # reach it as two harmless-looking paths (CodeRabbit on #2258): unreadable.
  if ! printf '%s' "$files_json" | jq -e '
      all(.[]; ((.filename | test("\n")) | not)
        and ((.previous_filename == null) or ((.previous_filename | test("\n")) | not)))' >/dev/null 2>&1; then
    phase_4a_gate_failsafe "a changed file name contains a newline, which the line-based path matcher cannot read"
    return 0
  fi
  files_count=$(printf '%s' "$files_json" | jq 'length') || files_count=""
  if ! [[ "$files_count" =~ ^[0-9]+$ ]] || ! [[ "$changed_files" =~ ^[0-9]+$ ]]; then
    phase_4a_gate_failsafe "could not count the PR files"
    return 0
  fi
  if [ "$files_count" -eq 0 ]; then
    phase_4a_gate_failsafe "the PR file list is empty"
    return 0
  fi
  if [ "$files_count" -ge 3000 ]; then
    phase_4a_gate_derived "the PR file list has $files_count entries, at GitHub's 3000-file cap"
    return 0
  fi
  if [ "$files_count" -ne "$changed_files" ]; then
    phase_4a_gate_failsafe "the PR file list has $files_count entries but the PR reports $changed_files changed files"
    return 0
  fi

  # Pin the default branch's head before the policy read (Codex P2 on #2258):
  # when the base predates review-policy.yml the resolver falls back to the
  # default branch BY NAME, so a commit landing there during the derivation
  # could swap in a stricter policy with every other fence part unchanged.
  # The fence below re-reads this sha.
  default_json=$(gh api "repos/$REPO/branches/$default_branch" 2>/dev/null) || default_json=""
  default_sha=$(printf '%s' "$default_json" | jq -r '.commit.sha // "" | strings' 2>/dev/null) || default_sha=""
  if [ -z "$default_sha" ]; then
    phase_4a_gate_failsafe "could not read the head commit of the default branch $default_branch"
    return 0
  fi

  # Threshold and protected paths come from the policy that GOVERNS the PR:
  # its base, fetched at the base sha of the snapshot above (Codex P1 on
  # #2258). The script's own checkout may be another repository, or the
  # candidate's own edited policy.
  base_cfg=$("$__CODEX_REQUEST_DIR/workflow/resolve_base_policy.sh" --repo "$REPO" \
    --base-ref "$base_ref" --base-sha "$base_sha" --default-branch "$default_branch" \
    --default-config "$CONFIG" --materialize-default 2>/dev/null) || base_cfg=""
  if [ -z "$base_cfg" ] || [ ! -r "$base_cfg" ]; then
    phase_4a_gate_failsafe "could not resolve the governing review policy at $base_ref@$base_sha"
    return 0
  fi
  # Every value below is read the way the labeler reads it, with the
  # labeler's own readers wherever they exist (Codex P1 x4 on #2258):
  #   threshold  the raw top-level line's second token, exactly as
  #              external_review_fingerprint.sh and merge-clearance-gate.sh
  #              read it: grep '^external_review_threshold:' | awk '{print $2}';
  #   paths      scripts/workflow/parse_policy_list.sh, loaded from the base;
  #   exclusion  EXCLUDE_RE from external_review_fingerprint.sh at the base;
  #   matcher    scripts/workflow/match_protected_paths.sh at the base.
  # No YAML parser is consulted. A second reader can disagree with the
  # labeler (anchors and aliases, flow lists, numeric spellings) and skip a
  # PR the labeler gates.
  raw_threshold=$(grep -E '^external_review_threshold:' "$base_cfg" 2>/dev/null) || raw_threshold=""
  parser="$__CODEX_REQUEST_DIR/workflow/parse_policy_list.sh"
  if ! base_helper_matches_own scripts/workflow/parse_policy_list.sh "$base_sha" "$parser"; then
    [ "$base_cfg" = "$CONFIG" ] || rm -f "$base_cfg" 2>/dev/null || true
    phase_4a_gate_failsafe "the policy list parser: $BASE_HELPER_CAUSE"
    return 0
  fi
  paths_out=$(run_policy_helper "$parser" "$base_cfg" external_review_paths 2>/dev/null) || parser_rc=$?
  [ "$base_cfg" = "$CONFIG" ] || rm -f "$base_cfg" 2>/dev/null || true
  if [ "${parser_rc:-0}" -ne 0 ]; then
    phase_4a_gate_failsafe "the policy list parser failed on external_review_paths (rc=$parser_rc)"
    return 0
  fi
  # The labeler's own line split: one pattern per non-empty line.
  while IFS= read -r pattern; do
    [ -n "$pattern" ] && patterns+=("$pattern")
  done <<<"$paths_out"

  # Absent (no line) is the documented default 300, which the labeler also
  # uses. One line whose token is plain digits is used as written. Any other
  # token, or the key on more than one line, is a value the labeler would
  # not read as written (it falls back to 300), so it is unreadable here.
  raw_lines=0
  [ -z "$raw_threshold" ] || raw_lines=$(printf '%s\n' "$raw_threshold" | wc -l | tr -d ' ')
  if [ "$raw_lines" = 0 ]; then
    threshold=300
  elif [ "$raw_lines" = 1 ]; then
    threshold=$(printf '%s\n' "$raw_threshold" | awk '{print $2}')
    if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
      phase_4a_gate_failsafe "external_review_threshold in the governing policy is not a plain digit scalar ('$threshold'); the labeler would not read it as written"
      return 0
    fi
  else
    phase_4a_gate_failsafe "external_review_threshold appears on $raw_lines top-level lines of the governing policy; the labeler would not read one value"
    return 0
  fi
  # The generated-file exclusion is read from the fingerprint helper AT THE
  # BASE, the copy the labeler's classification runs (Codex P1 on #2258), not
  # from this checkout, which may be another repository or the candidate.
  fp_json=$(gh api "repos/$REPO/contents/scripts/workflow/external_review_fingerprint.sh?ref=$base_sha" 2>/dev/null) || fp_json=""
  exclude_re=$(printf '%s' "$fp_json" | jq -r '.content | gsub("\n"; "") | @base64d' 2>/dev/null \
    | sed -n "s/^EXCLUDE_RE='\(.*\)'\$/\1/p" | head -1) || exclude_re=""
  if [ -z "$exclude_re" ]; then
    phase_4a_gate_failsafe "cannot read the generated-file exclusion (EXCLUDE_RE) from scripts/workflow/external_review_fingerprint.sh at $base_sha"
    return 0
  fi
  lines=$(printf '%s' "$files_json" | jq --arg re "$exclude_re" '
    [ .[] | select((.filename | test($re)) | not) | (.additions + .deletions) ] | add // 0' 2>/dev/null) || lines=""
  if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
    phase_4a_gate_failsafe "could not count the changed lines"
    return 0
  fi
  if [ "$lines" -ge "$threshold" ]; then
    phase_4a_gate_derived "$lines lines changed >= external_review_threshold $threshold"
    return 0
  fi

  if [ "${#patterns[@]}" -gt 0 ]; then
    # The matcher is loaded from the base too (Codex P1 on #2258): the
    # labeler runs the base revision's helper tree, and a checkout copy,
    # from another repository or edited by the candidate, could match less.
    matcher="$__CODEX_REQUEST_DIR/workflow/match_protected_paths.sh"
    if ! base_helper_matches_own scripts/workflow/match_protected_paths.sh "$base_sha" "$matcher"; then
      phase_4a_gate_failsafe "the protected-path matcher: $BASE_HELPER_CAUSE"
      return 0
    fi
    # Both sides of a rename (#763): moving a protected file out of a
    # protected path must still match.
    changed=$(printf '%s' "$files_json" | jq -r '.[] | (.filename, (.previous_filename // empty))')
    matched=$(printf '%s\n' "$changed" | run_policy_helper "$matcher" "${patterns[@]}") || rc=$?
    if [ "$rc" -ne 0 ]; then
      phase_4a_gate_failsafe "the protected-path matcher failed (rc=$rc)"
      return 0
    fi
    if [ -n "$matched" ]; then
      phase_4a_gate_derived "protected paths changed: $(printf '%s\n' "$matched" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
      return 0
    fi
  fi

  # Snapshot fence (Codex P1 x2 on #2258): every read above describes one
  # snapshot of the PR: its head, its base (whose policy was read), the
  # repository default branch the resolver can fall back through and that
  # branch's head commit, and its label state. A push, a base move to a stricter policy, or a
  # needs-external-review label landing during the reads would leave this
  # skip describing a PR that no longer exists, and the skip path never
  # reaches the moving-head guard. Re-read the PR immediately before
  # reporting "not gated": a label now present gates it; any other change, or
  # an unreadable re-read, counts as gated.
  live_json=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>/dev/null) || live_json=""
  live_fence=$(printf '%s' "$live_json" | jq -r '
    if type == "object" and (.labels | type) == "array"
       and all(.labels[]; type == "object" and ((.name | type) == "string"))
    then [(.head.sha // "" | strings), (.base.ref // "" | strings), (.base.sha // "" | strings),
          (.base.repo.default_branch // "" | strings),
          ([.labels[].name] | index("needs-external-review") != null | tostring)] | join(" ")
    else "" end' 2>/dev/null) || live_fence=""
  if [ -z "$live_fence" ]; then
    phase_4a_gate_failsafe "could not re-read the PR before skipping"
    return 0
  fi
  if [ "$live_fence" = "$head_sha $base_ref $base_sha $default_branch true" ]; then
    phase_4a_gate_derived "the PR carries the needs-external-review label (added during the derivation)"
    return 0
  fi
  if [ "$live_fence" != "$head_sha $base_ref $base_sha $default_branch false" ]; then
    phase_4a_gate_failsafe "the PR moved during the derivation (head/base/default/label was '$head_sha $base_ref $base_sha $default_branch false', now '$live_fence')"
    return 0
  fi
  live_default=$(gh api "repos/$REPO/branches/$default_branch" 2>/dev/null | jq -r '.commit.sha // "" | strings' 2>/dev/null) || live_default=""
  if [ "$live_default" != "$default_sha" ]; then
    phase_4a_gate_failsafe "the default branch $default_branch moved during the derivation (was ${default_sha}, now ${live_default:-unreadable}); its policy may be the fallback that governs this PR"
    return 0
  fi

  PHASE_4A_GATED=false
  PHASE_4A_GATE_REASON="no needs-external-review label, $lines lines changed < external_review_threshold $threshold, no file matches external_review_paths (head $head_sha)"
  log "Phase 4 gate derived from the PR: not gated ($PHASE_4A_GATE_REASON) — #2257"
}

# Decide whether to request a Codex review on this PR. Returns 0 (request)
# or 1 (skip). Kept as a function so the decision is testable in one place
# and reads as a single boolean expression at the call site.
should_request_codex() {
  # Keep the established readers, but scope their CONFIG to the policy of
  # REPO's base. The script's checkout can belong to another repository.
  local CONFIG="$CONFIG" entry_cfg
  entry_cfg=$("$__CODEX_REQUEST_DIR/workflow/resolve_base_policy.sh" \
    --repo "$REPO" --pr "$PR_NUMBER" --default-config "$CONFIG" \
    --materialize-default 2>/dev/null) || entry_cfg=""
  if [ -z "$entry_cfg" ] || [ ! -r "$entry_cfg" ]; then
    request_by_default_failsafe "could not resolve the governing policy for $REPO#$PR_NUMBER"
    return 0
  fi
  [ "$entry_cfg" = "$CONFIG" ] || __CRA_ENTRY_CFG_TMP="$entry_cfg"
  CONFIG="$entry_cfg"
  CODEX_ENABLED=$(codex_field enabled)
  CODEX_ENABLED=${CODEX_ENABLED:-true}
  # Codex off ⇒ never trigger (orthogonality rule).
  [ "$CODEX_ENABLED" = "true" ] || return 1
  # A caller-flagged Phase-4a-gated PR is always requested: Phase 4 review is
  # mandatory, whatever request_by_default says (#2240). Checked first, so a
  # flagged run never depends on the policy read or the PR reads below.
  [ "$PHASE_4A_GATED" = "true" ] && return 0
  # Otherwise request_by_default decides: true ⇒ trigger on every PR.
  resolve_request_by_default
  [ "$REQUEST_BY_DEFAULT" = "true" ] && return 0
  # false/unset: request only a PR the derivation reads as gated (#2257).
  derive_phase_4a_gate
  [ "$PHASE_4A_GATED" = "true" ]
}

# ack_wait_seconds: the 👀 eyes-ack window (#419). Default 30s aligned to the
# shipped policy value (#647) from the measured ack latency (#623): healthy
# acks land in p50 9s / p99 13s / max 13s (n=14, the full recorded ack
# corpus), so 30s is ~2.3× p99 — it clears every observed healthy ack with
# margin yet fails over fast on a dropped/rate-limited trigger. The measurement
# sizes the WINDOW; the retry COUNT (max_ack_retries) is unchanged, so the full
# failover budget is 30s × (1 + max_ack_retries) = 60s, halved from the prior
# 60s × 2 = 120s. Was 60s folklore.
ACK_WAIT_SECONDS=$(codex_field ack_wait_seconds)
ACK_WAIT_SECONDS=${ACK_WAIT_SECONDS:-30}
if ! [[ "$ACK_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.ack_wait_seconds must be an integer; got '$ACK_WAIT_SECONDS'" >&2
  exit 3
fi

MAX_ACK_RETRIES=$(codex_field max_ack_retries)
MAX_ACK_RETRIES=${MAX_ACK_RETRIES:-1}
if ! [[ "$MAX_ACK_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: codex.max_ack_retries must be an integer; got '$MAX_ACK_RETRIES'" >&2
  exit 3
fi

# --- moving-head guard knobs (#2166) ---------------------------------------
# A Codex request is posted once per batch, on a head that is final for the
# round. Two observable proxies for "final" are enforced immediately before a
# NEW trigger write (never on an acknowledgement retry, a dedup skip, or a
# cleared head):
#
#   codex.request_min_head_age_seconds  the head must be at least this old,
#                                       measured from the push: the latest of
#                                       the committer date, the last
#                                       force-push, and the push dispatch
#                                       (the latest repo-lint run for the head
#                                       on the PR's branch, so
#                                       an ordinary push of an old commit
#                                       still reads as new). Default 300: the
#                                       measured push-to-next-request p50 was
#                                       3 minutes, i.e. requests went out on
#                                       heads the agent was still amending.
#                                       0 disables the age check.
#
#   "CI has picked this head up" -- by default, a run of the `repo-lint`
#   workflow (repo_lint.yml, manifest-canonical, so on every consumer) exists
#   for the head SHA, in any status. Keyed on the WORKFLOW RUN, not on a job's
#   check-run: job names change and shard (`lint-fast` becoming `lint-fast
#   (1)`..`(4)` would refuse every request under an exact-name match), and a
#   run exists the moment GitHub dispatches the push, before any job is
#   created. A queued run counts: the Actions backlog is not the agent's
#   signal. A missing run is a head GitHub has not dispatched workflows for
#   yet. A repo with NO repo-lint workflow at all cannot produce the signal,
#   so it is skipped with a warning rather than refusing forever -- the guard
#   fails toward requesting, the same asymmetry coderabbit-should-invoke.sh
#   applies.
#
#   codex.request_requires_check        OVERRIDE. Absent (the default): the
#                                       repo-lint workflow-run signal above.
#                                       Set to a name: a check-run by exactly
#                                       that name must have been scheduled on
#                                       the head instead. Set to "": the
#                                       signal is disabled.
#
# Both are read from the checkout's policy: this guard protects the agent's
# own cycle time, not a merge decision, so a candidate-controlled value costs
# the candidate only wasted rounds.
#
# The value is validated inside the guard, not here (#2253): a malformed knob
# must not turn the disabled (codex.enabled: false) or skip
# (request_by_default) paths, which post nothing, from exit 5 into exit 3.
REQUEST_MIN_HEAD_AGE_SECONDS=$(codex_field request_min_head_age_seconds)
REQUEST_MIN_HEAD_AGE_SECONDS=${REQUEST_MIN_HEAD_AGE_SECONDS:-300}
# REQUEST_SIGNAL_MODE: workflow (key absent), check (key set to a name) or
# off (key present and empty). Resolve value and presence together as YAML
# inside the write guard, preserving disabled/no-request entry paths.
REQUEST_WORKFLOW_NAME=repo-lint
REQUEST_WORKFLOW_PATH=.github/workflows/repo_lint.yml
REQUEST_REQUIRES_CHECK=""
REQUEST_SIGNAL_MODE=workflow
resolve_request_check_signal() {
  local policy selection
  # Preserve the bootstrap default when there is no policy file.
  [ -f "$CONFIG" ] || return 0
  policy=$(policy_yaml_to_json "$CONFIG") || {
    echo "ERROR: codex.request_requires_check policy could not be parsed" >&2
    exit 3
  }
  selection=$(printf '%s' "$policy" | jq -ce '
    if . == null then {} else . end
    | if type != "object" then error("policy must be a mapping") else . end
    | (.codex // {})
    | if type != "object" then error("codex must be a mapping") else . end
    | if has("request_requires_check") then
        .request_requires_check
        | if . == null or . == "" then {mode:"off",name:""}
          elif type == "string" then {mode:"check",name:.}
          else error("request_requires_check must be a check name or empty") end
      else {mode:"workflow",name:""} end
  ') || {
    echo "ERROR: codex.request_requires_check must name a check or be empty" >&2
    exit 3
  }
  REQUEST_SIGNAL_MODE=$(printf '%s' "$selection" | jq -r .mode)
  REQUEST_REQUIRES_CHECK=$(printf '%s' "$selection" | jq -r .name)
}

POLL_INTERVAL_SECONDS=15
ACK_POLL_INTERVAL_SECONDS=5

# Transient poll-read retry (#1550). A single HTTP 502 during the review wait
# used to end the run with exit 3 while Codex was still working on an
# acknowledged trigger, and the rerun then posted a second trigger. Each
# post-trigger scan now retries a transient read failure (classified by
# gh_failure_is_permanent) this many times, SCAN_RETRY_BACKOFF_SECONDS apart,
# before failing closed with exit 3. Permanent failures are not retried.
SCAN_RETRY_ATTEMPTS=${MERGEPATH_CODEX_SCAN_RETRY_ATTEMPTS:-3}
SCAN_RETRY_BACKOFF_SECONDS=${MERGEPATH_CODEX_SCAN_RETRY_BACKOFF_SECONDS:-$POLL_INTERVAL_SECONDS}
if ! [[ "$SCAN_RETRY_ATTEMPTS" =~ ^[1-9][0-9]{0,2}$ ]]; then
  echo "ERROR: MERGEPATH_CODEX_SCAN_RETRY_ATTEMPTS must be an integer in [1, 999]; got '$SCAN_RETRY_ATTEMPTS'" >&2
  exit 3
fi
if ! [[ "$SCAN_RETRY_BACKOFF_SECONDS" =~ ^[0-9]{1,4}$ ]]; then
  echo "ERROR: MERGEPATH_CODEX_SCAN_RETRY_BACKOFF_SECONDS must be an integer in [0, 9999]; got '$SCAN_RETRY_BACKOFF_SECONDS'" >&2
  exit 3
fi

# --- logging helpers --------------------------------------------------------

log() {
  echo "[codex-review-request] $*" >&2
}

die() {
  local code=$1
  shift
  echo "[codex-review-request] ERROR: $*" >&2
  exit "$code"
}

# Fetch a paginated GitHub REST API endpoint and return the flattened JSON
# array on stdout. `gh api --paginate` emits one JSON value per page
# concatenated into a single stream — `jq`'s default mode runs the filter
# once per input (per page), which miscounts and misfilters on multi-page
# PRs. Slurp with `-s` collects all inputs into an outer array, then `add`
# concatenates the per-page arrays into one flat array. Defaults to `[]`
# on empty input.
#
# RETURNS 3 on failure; it cannot abort its caller (#966, mirroring the
# #831 contract fix already applied to coderabbit-wait.sh). Every call
# site here is a command substitution (`VAR=$(fetch_api_array …)`), so a
# `die`/`exit` inside this function would kill only that subshell — the
# assigning statement resumes with an empty string and status 0, and a
# caller that infers "no results" from emptiness reads a failed API call
# as a confident negative. `return` carries the SAME status a `die` exit
# would have produced; the difference is that this function no longer
# claims a power (aborting the whole script) it does not actually have
# when called from inside another function. A top-level
# `VAR=$(fetch_api_array …)` (outside any function) still trips
# `set -euo pipefail` and exits the script with status 3 — unaffected by
# this change. A call site INSIDE a function body must propagate the
# status explicitly (`|| return 3` / `|| die 3 …`); see scan_codex_state
# below for the call site migrated here. The other in-function site,
# trigger_ack_present, is deliberately NOT migrated in this change: its
# unread-vs-absent distinction is the eyes-ack deadline rule, specified
# and tested as a whole in #987. It keeps the pre-existing behaviour —
# an unreadable read reads as a missing ack — until then.
#
# The two streams are captured SEPARATELY. `gh api` writes diagnostics to
# stderr on calls that SUCCEED — deprecation notices, retry/backoff
# chatter, token-scope warnings — so folding stderr into stdout with
# `2>&1` feeds that prose to the `jq -s` slurp below, which then fails
# and reports a healthy fetch as an error. That is the same dishonesty
# this contract fix is about, pointed the other way: a swallowed failure
# lies about a bad read, a merged stderr stream lies about a good one.
# Only stdout reaches jq; stderr is kept solely for the diagnostic.
#
# That separation, and the algorithm around it, now live in
# scripts/lib/gh-api-array.sh (#1008). This file's copy was the ONLY one of the
# eight that had it, so extracting it is what finally gives the other seven the
# same correction. What stays here is this script's failure ACTION: `return`
# rather than `die`, per the paragraph above. One behaviour changed in the
# move and is recorded in the lib's header — an unallocatable stderr capture
# file now degrades to a less detailed diagnostic instead of failing the read,
# because the read itself is unaffected by it.
fetch_api_array() {
  gh_api_array "$1" "$2" || {
    log "ERROR: $GH_API_ARRAY_ERROR"
    return 3
  }
}

# scan_codex_state's reader (#1550). Same contract as fetch_api_array, except
# a transient fetch failure returns 4 instead of 3, so rescan_codex_state can
# retry it. The classification has to travel as a status: this runs inside
# the caller's command substitution, so GH_API_ARRAY_* never reach it.
# Kept separate from fetch_api_array on purpose: some of that reader's call
# sites let a failure fall through `set -e` as the script's own exit status,
# where a 4 would read as FALLBACK_REQUIRED.
fetch_scan_array() {
  gh_api_array "$1" "$2" && return 0
  log "ERROR: $GH_API_ARRAY_ERROR"
  # An empty diagnostic (stderr capture unavailable) proves nothing about the
  # failure, so it stays permanent: the pre-#1550 behaviour.
  if [ "$GH_API_ARRAY_ERROR_KIND" = fetch ] && [ -n "$GH_API_ARRAY_DETAIL" ] \
     && ! gh_failure_is_permanent "$GH_API_ARRAY_DETAIL"; then
    return 4
  fi
  return 3
}

# --- Phase 4a entry gate (#486) ---------------------------------------------
# Evaluate the request decision after its governing-policy metadata lookup,
# before per-head signal scanning or trigger writes. On "skip", emit a minimal JSON object (same field
# names as the terminal output, all signals null) and exit 5
# (NO_TRIGGER_REQUESTED) so the caller can distinguish "deliberately did not
# request" from a timeout (4) or an API error (3).
if ! should_request_codex; then
  if [ "$CODEX_ENABLED" != "true" ]; then
    log "codex.enabled is false — Phase 4a is off; not requesting a Codex review (route to Phase 4b)"
  else
    if [ "$REQUEST_BY_DEFAULT_SOURCE" = "unset" ]; then
      log "codex.request_by_default is not set (the default is false since #2240) and this PR is not Phase-4a-gated (MERGEPATH_PHASE_4A_GATED!=true) — not requesting a Codex review"
    else
      log "codex.request_by_default is false and this PR is not Phase-4a-gated (MERGEPATH_PHASE_4A_GATED!=true) — not requesting a Codex review"
    fi
    # Codex P1 on #2175: say why, so the skip is never mistaken for "Codex not
    # needed". Since #2257 the gate is derived from the PR before this skip,
    # so this line reports what was read; the flag remains the override for a
    # PR the derivation misreads.
    log "Phase 4 gate derived from the PR: ${PHASE_4A_GATE_REASON:-not gated}. If this PR meets external_review_threshold or touches external_review_paths (a Phase 4 PR), Codex is mandatory: rerun with MERGEPATH_PHASE_4A_GATED=true"
  fi
  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg bot_login "$BOT_LOGIN" '
    {
      pr_number: $pr_number,
      repo: $repo,
      head_sha: null,
      head_committer_date: null,
      bot_login: $bot_login,
      review: null,
      findings: [],
      reaction: null,
      verdict: null,
      blocked_reason: null,
      terminal_determination: null,
      trigger_posted: false,
      trigger_requested: false,
      rounds_waited_seconds: 0
    }
  '
  exit 5
fi

# --- fetch PR metadata ------------------------------------------------------

request_freshness_snapshot() { # <PR metadata JSON>
  local tuple policy freshness base_ref base_sha default_branch
  tuple=$(printf '%s' "$1" | jq -ce '
    [.base.ref, .base.sha, .base.repo.default_branch]
    | select(all(.[]; type == "string" and length > 0))') || return 1
  base_ref=$(printf '%s' "$tuple" | jq -r '.[0]')
  base_sha=$(printf '%s' "$tuple" | jq -r '.[1]')
  default_branch=$(printf '%s' "$tuple" | jq -r '.[2]')
  policy=$(crqe_governing_policy_json "$REPO" "$PR_NUMBER" "$CONFIG" \
    "$__CODEX_REQUEST_DIR/workflow/resolve_base_policy.sh" \
    "$base_ref" "$base_sha" "$default_branch") || return 1
  freshness=$(crqe_policy_reaction_freshness "$policy") || return 1
  jq -nSc --argjson tuple "$tuple" --argjson freshness "$freshness" \
    '{tuple:$tuple,freshness:$freshness}'
}

revalidate_request_freshness() {
  local metadata snapshot
  metadata=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>/dev/null) \
    || die 3 "cannot revalidate governing request freshness metadata; rerun the requester"
  snapshot=$(request_freshness_snapshot "$metadata") \
    || die 3 "cannot revalidate governing request freshness policy; rerun the requester"
  [ "$snapshot" = "$GOVERNING_FRESHNESS_SNAPSHOT" ] \
    || die 3 "governing request freshness base/policy changed; rerun the requester"
}

log "PR $REPO#$PR_NUMBER — fetching HEAD commit metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) || die 3 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(printf '%s\n' "$PR_JSON" | jq -r '.head.sha')
# The PR's head branch scopes the moving-head guard's push-dispatch anchor to
# runs dispatched for THIS branch (Codex P2 on #2175). Empty when unreadable;
# the guard then falls back to every run for the SHA.
HEAD_REF=$(printf '%s\n' "$PR_JSON" | jq -r '.head.ref // empty' 2>/dev/null) || HEAD_REF=""
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 3 "could not determine HEAD sha for PR #$PR_NUMBER"
fi

# Use the committer date for request/provider diagnostics, not the author date.
HEAD_COMMITTER_DATE=$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>&1) \
  || die 3 "failed to fetch commit date for $HEAD_SHA: $HEAD_COMMITTER_DATE"
# Post-write diagnostics use jq's canonical UTC parser. Refuse unsupported
# metadata before a trigger can be written, rather than failing afterward.
jq -ne --arg t "$HEAD_COMMITTER_DATE" '
  $t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
  and (try ($t | fromdateiso8601 | todateiso8601 == $t) catch false)' >/dev/null \
  || die 3 "unsupported commit timestamp; expected a valid YYYY-MM-DDTHH:MM:SSZ value"

# Retain the shared timestamp diagnostics used by request evidence and
# provider-state polling. Clearance below depends on commit anchors; a PR
# reaction cannot suppress a request or end the polling loop.
# #1567: timing is governed by the target base policy, as in Phase 4b. Read
# freshness before any threshold/reuse decision, without validating request
# caps on a no-spend path. Each new write still re-reads its governed budgets.
GOVERNING_FRESHNESS_SNAPSHOT=$(request_freshness_snapshot "$PR_JSON") \
  || die 3 "cannot read the governing review policy/request freshness"
REACTION_FRESHNESS_SECONDS=$(printf '%s' "$GOVERNING_FRESHNESS_SNAPSHOT" | jq -r .freshness)
TIMELINE_JSON=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/timeline" "PR timeline")
EPOCH_NOW=$(date +%s)
REACTION_ANCHOR=$(crqe_request_threshold "$HEAD_COMMITTER_DATE" "$TIMELINE_JSON" \
  "$REACTION_FRESHNESS_SECONDS" "$EPOCH_NOW") \
  || die 3 "could not compute Codex request freshness threshold"
HEAD_PUSHED_AT=$(printf '%s' "$REACTION_ANCHOR" | jq -r .head_pushed_at)
ANCHOR_SOURCE=$(printf '%s' "$REACTION_ANCHOR" | jq -r .anchor_source)
REACTION_FLOOR_ISO=$(printf '%s' "$REACTION_ANCHOR" | jq -r .reaction_floor)
REACTION_THRESHOLD=$(printf '%s' "$REACTION_ANCHOR" | jq -r .reaction_threshold)
REACTION_THRESHOLD_SOURCE=$(printf '%s' "$REACTION_ANCHOR" | jq -r .reaction_threshold_source)

log "HEAD = $HEAD_SHA committed at $HEAD_COMMITTER_DATE"
log "anchor = $HEAD_PUSHED_AT (source: $ANCHOR_SOURCE)"
log "reaction_threshold = $REACTION_THRESHOLD (source: $REACTION_THRESHOLD_SOURCE)"
log "bot_login = $BOT_LOGIN    timeout = ${TIMEOUT_SECONDS}s"
log "ack_wait = ${ACK_WAIT_SECONDS}s    max_ack_retries = $MAX_ACK_RETRIES"

# --- Codex signal scan ------------------------------------------------------

# Scan for (a) a review from the bot on the current HEAD commit, (b) inline
# findings from the bot on the current HEAD, (c) an issue verdict anchored by
# its Reviewed commit field. Returns a JSON object to stdout on
# success. Emits empty object { "review": null, "findings": [], "reaction": null }
# if nothing matches yet.
scan_codex_state() {
  local reviews comments issue_comments review findings reaction verdict blocked approval_time request summary

  # Each read must propagate fetch_api_array's status explicitly (#966):
  # scan_codex_state is invoked from every call site as
  # `VAR=$(scan_codex_state)`, so it runs inside ITS OWN command
  # substitution subshell — a `die` from within fetch_api_array, called
  # from in here, would only kill that inner subshell too, leaving these
  # assignments empty and status 0. `|| return 3` makes the caller's
  # `if ! scan_codex_state; then die …` guard (below and at every call
  # site) actually observe the failure instead of relying on the
  # trailing `jq -n --argjson` emitter to crash on empty input. A transient
  # read failure returns 4 rather than 3 (#1550); see rescan_codex_state.
  reviews=$(fetch_scan_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews") || return $?
  comments=$(fetch_scan_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline comments") || return $?
  issue_comments=$(fetch_scan_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments") || return $?
  issue_comments=$(crqe_resolve_verdict_anchors "$issue_comments" "$REPO" "$BOT_LOGIN") || return 3

  # Latest review from the Codex bot on the current HEAD commit, if any.
  # Codex always uses COMMENTED state regardless of findings. We also
  # capture the review id so the findings filter can scope to THIS
  # review only and not pick up stale findings from an earlier review
  # round on the same HEAD.
  # Provider histories and finding bodies are unbounded; keep them off argv.
  review=$(crqe_select_head_review "$reviews" "$comments" "$BOT_LOGIN" "$HEAD_SHA") || return 3
  approval_time=$(crqe_review_approval_time "$review" "$comments" "$BOT_LOGIN" "$HEAD_SHA") || return 3
  review=$(printf '%s\n' "$review" | jq 'if . == null then null else {id,state,submitted_at,commit_id,body} end') || return 3

  # Get the LATEST Codex review id so findings are scoped to that
  # round only. nathanpayne-codex caught (swipewatch propagation
  # PR #33 round 2) that filtering by SHA alone keeps old P0/P1
  # comments from earlier reviews on the same HEAD forever — same
  # bug class as PR #65 round 1's gate (c) findings filter on
  # codex-review-check.sh.
  latest_review_id=$(printf '%s\n' "$review" | jq -r 'if . == null then "" else .id end')

  # Inline findings from the bot on the current HEAD commit, scoped
  # to the LATEST review round (via pull_request_review_id), with
  # P0-P3 priority extracted from EITHER the ![P{0-3} Badge] badge image OR
  # the **Pn text fallback Codex emits when the badge is absent — mirroring
  # codex_tier_of in scripts/lib/feedback-policy-helpers.sh so a fallback-only
  # finding is classified consistently (CodeRabbit Major on #590). The
  # alternation's leftmost match wins, matching codex_tier_of's first-marker
  # rule. If there's no current review, findings is empty.
  if [ -n "$latest_review_id" ] && [ "$latest_review_id" != "null" ]; then
    findings=$(printf '%s\n' "$comments" | jq \
      --arg bot "$BOT_LOGIN" \
      --argjson review_id "$latest_review_id" \
      --argjson required "$REQUIRED_TIERS_JSON" \
      --argjson discretionary "$DISCRETIONARY_TIERS_JSON" '
      [ .[]
        | select(.user.login == $bot)
        | select(.pull_request_review_id == $review_id)
        | ( (.body | capture("!\\[P(?<b>[0-3]) Badge\\]|\\*\\*P(?<f>[0-3])")? // {}) | (.b // .f) ) as $n
        | { path, line, comment_id: .id, body,
            priority: ( if $n == null then "P?" else "P" + $n end ),
            # blocking (#577): this finding sits in a `required` tier per the
            # resolved feedback_policy set. An unmarked finding ($n == null,
            # "P?") is never blocking. Membership test lowercases the
            # normalized tier (p0..p3) against $required (from
            # resolve_required_tiers) so the surfaced flag matches exactly
            # what the codex-p1-gate enforces at merge time.
            blocking: ( $n != null and ( ("p" + $n) as $t | $required | index($t) != null ) ),
            discretionary: ( $n != null and ( ("p" + $n) as $t | $discretionary | index($t) != null ) )
          }
      ]
    ')
  else
    findings='[]'
  fi

  # #1751: retain the output field for compatibility, without treating a
  # commit-less reaction as a response or clearance signal.
  reaction=null

  # HEAD-anchored Codex issue-comment verdict (#600/#567/#608, mirrored here
  # per #609). Codex can clear a round purely via this "Codex Review: Didn't
  # find any major issues" + "Reviewed commit: <sha>" ISSUE comment, with no
  # review object — codex-review-check.sh (the merge
  # gate) has recognized this since #600, but until #609 this poller did not,
  # so a verdict-only response ran the poll to timeout (exit 4) instead of
  # terminating on it. Select the LATEST HEAD-anchored verdict FIRST (any
  # disposition), THEN check whether that latest one is affirmative — so a
  # newer non-affirmative verdict on the same HEAD supersedes an older clean
  # one and fails closed (same #608 P1 shape as the merge gate). KEEP THIS
  # FILTER IN SYNC with CODEX_VERDICT_JSON in scripts/codex-review-check.sh.
  verdict=$(printf '%s\n' "$issue_comments" | jq -c \
    --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    ($sha | ascii_downcase) as $head
    | [ .[]
        | select(.user.login == $bot)
        | . as $c
        | ( [ $c.body
              | ascii_downcase
              | scan("reviewed commit[^0-9a-z_\\r\\n]{0,6}([^\\r\\n]*)")
              | .[0] | sub("^[`*[:space:]]+"; "") | sub("[`*[:space:]]+$"; "")
            ] ) as $shas
        | ([$c.body | ascii_downcase | scan("reviewed commit")] | length) as $fields
        | (($shas | length) > 0 and ($shas | length) == $fields
           and ($head | test("^[0-9a-f]{40}$"))
           and ($shas | all(. == $head))) as $exact
        | ($c.body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b")) as $affirmative
        # A newer negative verdict with an ambiguous anchor must invalidate
        # older clearance. It never grants clearance or names another head.
        # Only complete, valid anchors exclusively naming other heads can be
        # safely excluded from the latest-signal ordering for this head.
        | select($exact or (($affirmative | not)
            and ($c.body | test("(?im)^\\s*codex review:"))
            and ($fields == 0 or ($shas | unique | length) > 1
                 or ($shas | length) != $fields or ($shas | any(. == $head))
                 or ($shas | any(test("^[0-9a-f]{40}$") | not)))))
        | { created_at: .created_at,
            affirmative: ($exact and $affirmative) }
      ]
    | max_by(.created_at) // null
  ')

  # Account-/connection-level failure marker (#722). Codex answers a trigger
  # with a plain comment — no findings, no `Reviewed commit:` anchor, no
  # reaction — when the account is quota-exhausted ("usage_limit") or the App
  # is not connected ("not_connected"). None of the signal kinds above match
  # it, so without this the poll runs out the full review_timeout_seconds
  # window and exits 4, indistinguishable from a slow review. Select the
  # LATEST such marker (by created_at) so the poll can compare it against the
  # trigger threshold like any other signal.
  #
  # Precedence mirrors audit-codex-latency.sh's normalize phase: a bot
  # comment that is a VERDICT (its header line starts "Codex Review:") is
  # never a marker — exclude it first — so a findings verdict whose body
  # happens to mention e.g. "rate limit" is not misread as a quota block.
  # usage_limit wins over not_connected on a comment matching both.
  if [ "$CODEX_FAILURE_MARKERS_OK" = "true" ]; then
    blocked=$(printf '%s\n' "$issue_comments" | jq -c \
      --arg bot "$BOT_LOGIN" \
      --arg usage_re "$CODEX_USAGE_LIMIT_MARKER_RE" \
      --arg nc_re "$CODEX_NOT_CONNECTED_MARKER_RE" '
      [ .[]
        | select(.user.login == $bot)
        | select(((.body // "") | test("(?im)^\\s*codex review:")) | not)
        | ( if ((.body // "") | test($usage_re; "i")) then "usage_limit"
            elif ((.body // "") | test($nc_re; "i")) then "not_connected"
            else null end ) as $reason
        | select($reason != null)
        | { reason: $reason, created_at: .created_at, comment_id: .id }
      ]
      | max_by([.created_at, .comment_id]) // null
    ')
  else
    blocked='null'
  fi

  request=$(crqe_select_trigger "$issue_comments" "$AUTHOR_IDENTITY" "") || return 3
  summary=$(crqe_select_codex_review_summary "$issue_comments" "$BOT_LOGIN" "$HEAD_SHA") || return 3
  blocked=$(crqe_filter_provider_block "$blocked" "$request" "$summary") || return 3
  # #1362: the request generation this scan saw. The pre-flight scan's copy is
  # the evidence a new request is decided on; null when it cannot be read.
  local generation
  generation=$(crqe_trigger_generation "$issue_comments" "$AUTHOR_IDENTITY" 2>/dev/null) || generation=null

  # #2664: what the Review Summary row says about the latest request, for
  # reporting only. The row names no request, so another request on this
  # head whose window overlaps makes it ambiguous. "On this head" uses the
  # push proof, never the committer date; with no proof every overlapping
  # author request counts, since none can be ruled out (Codex P2 on #2779).
  local run='{"state":"none","observed_at":null,"comment_id":null,"retry_after_seconds":null}'
  if [ "$request" != null ]; then
    run=$(crqe_select_codex_run_state "$issue_comments" "$BOT_LOGIN" "$HEAD_SHA" \
      "$(printf '%s' "$request" | jq -r '.created_at // ""')") || return 3
    run=$(printf '%s' "$issue_comments" | jq -c --argjson run "$run" --argjson req "$request" \
      --arg author "$AUTHOR_IDENTITY" --arg head_at "${HEAD_PUSH_PROOF:-}" --argjson window "${TIMEOUT_SECONDS:-0}" '
      def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
      ($req.created_at | epoch) as $mine
      | [ .[] | select((.user.login // "") == $author)
          | select((.body // "") | test("\\A@codex review\\z"; "i"))
          | select(.id != $req.id)
          | select($head_at == "" or .created_at >= $head_at)
          | (.created_at | epoch) as $t
          | select($t <= $mine + $window and $t + $window >= $mine) ] as $others
      | $run + {overlapping_request: (($others | length) > 0)}') || return 3
  fi

  printf '%s\n' "$review" "$findings" "$reaction" "$verdict" "$blocked" "$request" "$generation" "$run" | jq -s --arg approval_time "$approval_time" '
    if length != 8 then error("incomplete Codex scan components") else
      { review: .[0], findings: .[1], reaction: .[2], verdict: .[3], blocked: .[4], request: .[5], generation: .[6], run: .[7], review_approval_eligible: ($approval_time != "") }
    end
  '
}

# Echo the failure-marker reason (usage_limit|not_connected) carried by a scan
# that should short-circuit the wait, else empty. When a trigger was posted
# this run, retain that confirmed request boundary even when the API scan has
# not observed the new comment yet. Scans already filter against their latest
# exact author request and active current-head summary. A block is not fixed by re-polling
# or re-triggering — only a human upgrading/connecting the account resolves
# it — so treating it as a wait-ending signal is correct (#722).
current_blocked_reason() {
  local scan=$1 block request after
  block=$(printf '%s' "$scan" | jq -c .blocked) || return 3
  request=$(printf '%s' "$scan" | jq -c '.request // null') || return 3
  if [ "$TRIGGER_POSTED" = "true" ] || [ "${CAP_REUSED_TRIGGER:-false}" = true ] \
     || [ "${RESUMED_TRIGGER:-false}" = true ]; then
    after=${TRIGGER_SIGNAL_THRESHOLD:-$TRIGGER_POST_TIME}
    request=${REQUEST_BLOCK_TRIGGER_JSON:-null}
    if [ "$TRIGGER_POSTED" = true ] || [ "$request" = null ]; then
      request=$(jq -nc --arg at "$after" --arg id "${TRIGGER_COMMENT_ID:-}" \
        '{created_at:$at,id:($id | tonumber? // null)}') || return 3
    fi
  fi
  block=$(crqe_filter_provider_block "$block" "$request") || return 3
  printf '%s' "$block" | jq -r 'if . == null then "" else .reason end'
}

# Returns 0 iff the scan produced a commit-anchored signal (review or
# HEAD-anchored issue-comment verdict). Used by the poll loop, which stops
# as soon as Codex has produced any response — even a review with P0/P1
# findings, or a non-affirmative verdict, counts because the caller will
# then process the response and decide what to do (#609: a verdict-only
# response must end the poll instead of running to timeout).
has_signal() {
  local scan=$1
  [ "$(printf '%s\n' "$scan" | jq -r '.review != null or .verdict != null')" = "true" ]
}

# Returns 0 iff the scan produced a signal that should be treated as
# CLEARED (no further @codex review trigger needed). Cleared means one of:
#   - a substantive review on HEAD eligible for the same-agent approval
#     substitute, with zero blocking (required-tier) inline findings
#     (the reviewed-and-clean path; "blocking" reflects the resolved
#     feedback_policy required set, so this is P0/P1 by default), OR
#   - a HEAD-anchored AFFIRMATIVE issue-comment verdict AND zero blocking
#     findings on HEAD (#600/#609) — a NON-affirmative latest verdict does
#     NOT clear (fails closed, mirroring #608 P1 on codex-review-check.sh).
#
# A review with blocking findings does NOT count as cleared — the caller
# may have replied to the findings with a rebuttal and want Codex to
# re-evaluate. Earlier versions of this function used has_signal in
# the pre-flight, which caused the rebuttal-without-commit path to
# stall: re-running the script saw the existing P1-bearing review
# and skipped the trigger, so Codex was never asked to reconsider.
# Codex caught this on swipewatch propagation PR #33 — same shape as
# the manual `@codex review` workaround I had to use on template PR
# #73 during dry-run C.
has_cleared_signal() {
  local scan=$1
  # Latest-signal-wins between commit-anchored reviews and verdicts.
  # An older clean review cannot mask a newer negative verdict; verdicts
  # win timestamp ties. Unanchored reactions have no authority (#1751).
  [ "$(printf '%s\n' "$scan" | jq -r '
    def review_time: if .review == null then "" else .review.submitted_at end;
    def verdict_time: if .verdict == null then "" else .verdict.created_at end;
    # P0 ALWAYS blocks clearance (the absent-policy disposition default is
    # P0/P1), regardless of the resolved gate set — otherwise a consumer with
    # no feedback_policy block (resolve_required_tiers -> {p1}) would emit a
    # P0-only review as blocking:false and prematurely clear it, skipping the
    # re-request (Codex P2 round 2 on #590). On top of the always-blocking P0,
    # anything in the resolved `required` set (the `blocking` flag) also blocks.
    # findings is already HEAD-scoped (scan_codex_state), independent of
    # which signal is latest, so it gates the verdict path too.
    def review_clean: ([.findings[] | select(.priority == "P0" or .blocking == true)] | length) == 0;

    ( reduce ( [["review", review_time], ["verdict", verdict_time]] | .[] ) as $sig
        ({kind: "", time: ""};
         if ($sig[1] != "" and ($sig[1] >= .time)) then {kind: $sig[0], time: $sig[1]} else . end)
    ) as $latest
    | if $latest.kind == "review" then ((.review_approval_eligible == true and review_clean) | tostring)
      elif $latest.kind == "verdict" then
        ((.verdict.affirmative == true and review_clean) | tostring)
      else "false"
      end
  ')" = "true" ]
}

# Returns 0 iff the scan has a terminal Codex signal that is at least
# as recent as TRIGGER_SIGNAL_THRESHOLD (>=, not >). That threshold is
# the first trigger timestamp in this script run, while TRIGGER_POST_TIME
# tracks the latest trigger comment for eyes-ack polling. Keeping them
# separate lets a late response to the original trigger count even if a
# retry comment was posted before the response became visible.
#
# Uses >= because GitHub timestamps are second-precision and a legitimate
# Codex response in the same second as the trigger comment post would
# otherwise be classified as stale forever, forcing a Phase 4b timeout.
has_post_trigger_signal() {
  local scan=$1
  local after=${TRIGGER_SIGNAL_THRESHOLD:-$TRIGGER_POST_TIME}
  [ "$(printf '%s\n' "$scan" | jq -r --arg after "$after" '
    ((.review != null and .review.submitted_at >= $after)
     or (.verdict != null and .verdict.created_at >= $after))
  ')" = "true" ]
}

# #489: HEAD-pinned idempotency for the rate-limit failover. Returns 0 iff a
# VALID `@codex review` trigger already exists for the current HEAD — meaning a
# comment authored by the configured `author_identity` (the same identity
# `post_codex_trigger` writes as, via gh-as-author.sh) whose `created_at` is at
# or after `REACTION_THRESHOLD` (the PR-scoped pushed-at / freshness anchor,
# `max(HEAD_PUSHED_AT, freshness floor)`). Author + anchor scoping (Codex P2 on
# #512) is what makes this sound: a reviewer-authored `@codex review`, or a
# stale author trigger left on a prior head before a force-push of an
# old-committer-date commit, must NOT count as "Codex was requested for THIS
# SHA" — otherwise coderabbit-wait.sh would emit `codex_failover_requested:true`
# with no valid trigger sent. Lets --trigger-only skip a duplicate post when
# coderabbit-wait.sh fires the failover more than once for the same HEAD (e.g.
# a re-invocation). Fail-open: on a missing author identity or any read error it
# returns non-zero so the caller still posts (better to re-request Codex than to
# silently skip the failover). Governing freshness/base uncertainty instead
# fails closed before this lookup can authorize reuse or a new request.
existing_codex_trigger_on_head() {
  [ -n "$AUTHOR_IDENTITY" ] || return 1
  local comments
  comments=$(gh api --paginate "repos/$REPO/issues/$PR_NUMBER/comments" 2>/dev/null \
    | jq -s 'add // []' 2>/dev/null) || return 1
  [ -n "$comments" ] || return 1
  revalidate_request_freshness
  local trigger
  trigger=$(crqe_select_trigger "$comments" "$AUTHOR_IDENTITY" "$REACTION_THRESHOLD") || return 1
  [ "$trigger" != null ]
}

# #798: content-fingerprint idempotency for AUTOMATIC callers, alongside the
# per-HEAD idempotency above. `existing_codex_trigger_on_head` answers "was a
# trigger already posted for this SHA"; this answers "has Codex already
# reviewed this CONTENT", which is the question an `update-branch` head raises.
# `gh pr update-branch` mints a new SHA that changes no file in the PR's own
# diff, and with `required_status_checks.strict: true` every merge forces one
# on every other open PR — so a batch of N PRs drew O(N²) review rounds that
# responded to no code change (#798).
#
# OPT-IN, and deliberately so. It applies only when the caller sets
# MERGEPATH_CODEX_AUTO_TRIGGER=true (or 1) — today that is
# agent-review.yml's auto-merge job, whose CodeRabbit-wait step reaches this
# script through coderabbit-wait.sh's #489 rate-limit failover. An agent's own
# `codex-review-request.sh <PR#> --trigger-only` never sets it and therefore
# ALWAYS posts, which is what keeps the explicit-invocation requirement
# (#631/#648) intact: a fix push must re-arm HEAD-anchored clearance, and only
# a machine-initiated trigger on content nobody changed is suppressible.
#
# Honored only under --trigger-only, the shape every automatic caller uses.
# In full (polling) mode a suppressed trigger would leave the poll loop
# waiting out `review_timeout_seconds` for a review nobody requested, so the
# mode that cannot express "no trigger, no wait" simply does not opt in.
#
# The decision itself lives in scripts/workflow/codex_auto_trigger_gate.sh so
# it is directly testable; this is the call site, not the policy. That gate in
# turn delegates to external_review_carryforward.sh and suppresses only on
# `carried: true`, so a suppressed head is by construction one whose Codex
# clearance already carries forward — never one left with no clearance and no
# caller to re-request it (#798 review). Fail-open on
# every uncertainty — a missing helper (a consumer mid-sync, or the PR that
# introduces it), a nonzero exit, unparseable output, or an explicit
# `trigger:true` all return non-zero here so the trigger is posted.
AUTO_TRIGGER_SKIP_REASON=""
auto_trigger_content_free() {
  case "${MERGEPATH_CODEX_AUTO_TRIGGER:-}" in
    true|True|TRUE|1) ;;
    *) return 1 ;;
  esac

  local gate
  gate="${MERGEPATH_CODEX_AUTO_TRIGGER_GATE_CMD:-$__CODEX_REQUEST_DIR/workflow/codex_auto_trigger_gate.sh}"
  if [ ! -f "$gate" ]; then
    log "auto-trigger gate helper not present at $gate — posting the trigger (fail open)"
    return 1
  fi

  local json rc=0
  # stderr is inherited so the gate's diagnostics stream into this run's log;
  # only stdout is parsed.
  json=$(bash "$gate" \
    --repo "$REPO" \
    --pr "$PR_NUMBER" \
    --head "$HEAD_SHA" \
    --config "$CONFIG" \
    --bot-login "$BOT_LOGIN") || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "auto-trigger gate exited $rc — posting the trigger (fail open)"
    return 1
  fi

  local decision
  decision=$(printf '%s' "$json" | jq -r 'if .trigger == false then "skip" else "post" end' 2>/dev/null) || decision="post"
  [ "$decision" = "skip" ] || return 1

  AUTO_TRIGGER_SKIP_REASON=$(printf '%s' "$json" | jq -r '.reason // "reviewable content is unchanged"' 2>/dev/null || printf 'reviewable content is unchanged')
  return 0
}

reset_review_wait_clock() {
  START_TS=$(date +%s)
  DEADLINE=$((START_TS + TIMEOUT_SECONDS))
  ELAPSED=0
}

run_feedback_accounting_gate() {
  local gate output rc=0 posted accounted
  gate="${MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD:-$__CODEX_REQUEST_DIR/review-feedback-accounting.sh}"
  command -v "$gate" >/dev/null 2>&1 \
    || die 3 "review feedback accounting gate unavailable: $gate"

  # #1100: resolve the governing base policy ONCE, here, and hand the SAME
  # snapshot to accounting via its documented REVIEW_FEEDBACK_ACCOUNTING_CONFIG
  # injection point. Resolving separately on each side opened a window: if the
  # PR base advanced between the two calls, `.missing` was classified under one
  # policy while the relax and collision sets came from another, and a policy
  # that moved a gating login onto coderabbit/code_scanning in the newer
  # revision would relax a finding the older revision classified as gating --
  # with no collision to catch it, because the newer revision is internally
  # consistent. AGENTS.md states relaxation uses the same base policy accounting
  # classified with; one resolution is what makes that literally true.
  #
  # Resolution failure leaves the variable empty: accounting falls back to
  # resolving its own (unchanged pre-#1100 behaviour) and the relax set below is
  # empty, so nothing is skippable. Fail-closed either way.
  __cra_base_cfg=""
  __cra_resolver="$__CODEX_REQUEST_DIR/workflow/resolve_base_policy.sh"
  if [ -x "$__cra_resolver" ]; then
    __cra_base_cfg=$("$__cra_resolver" --repo "$REPO" --pr "$PR_NUMBER" \
      --default-config "$CONFIG" --materialize-default 2>/dev/null) || __cra_base_cfg=""
  fi
  if [ -n "$__cra_base_cfg" ] && [ "$__cra_base_cfg" != "$CONFIG" ]; then
    __cra_retire_base_cfg "$__cra_base_cfg"
  fi
  if [ -n "$__cra_base_cfg" ]; then
    output=$(REVIEW_FEEDBACK_ACCOUNTING_CONFIG="$__cra_base_cfg" "$gate" "$PR_NUMBER" "$REPO") || rc=$?
  else
    output=$("$gate" "$PR_NUMBER" "$REPO") || rc=$?
  fi
  case "$rc" in
    0)
      posted=$(printf '%s' "$output" | jq -r '.posted // "?"' 2>/dev/null || printf '?')
      accounted=$(printf '%s' "$output" | jq -r '.accounted // "?"' 2>/dev/null || printf '?')
      log "review feedback accounting clear ($accounted/$posted accounted)"
      ;;
    1)
      # #1100: scope the refusal to the provider being REQUESTED. The barrier's
      # Codex arm is read-only, so making Codex terminal is the agent's job and
      # this script is its only tool -- but the gate counted EVERY provider, so
      # a CodeRabbit backlog refused the Codex request, and clearing that
      # backlog needs fix commits that produce a new head for CodeRabbit to
      # find more on. Codex could never reach terminal on the head the barrier
      # was evaluating. Observed live on nathanpaynedotcom#798.
      #
      # The relax set is ENUMERATED, and that direction is deliberate: naming
      # who may be skipped is fail-closed, because an unmodelled or renamed
      # reviewer keeps blocking. Naming who must block would be the fail-open
      # shape -- the next unmodelled provider would silently stop gating.
      # Codex's own findings, and any reviewer identity (including a Phase 4b
      # adapter review), still refuse exactly as before.
      # The relax set NARROWS what gates this request, so it must come from the
      # governing BASE policy -- the same one review-feedback-accounting.sh
      # classifies `.missing` with -- not from the candidate checkout. Reading
      # $CONFIG here would let a PR that edits .github/review-policy.yml point
      # coderabbit.bot_login at the Codex bot and mark Codex's own findings
      # skippable. feedback-policy-helpers.sh states this rule itself: its
      # untrusted reader is "for an additional login to WIDEN a scan, never to
      # narrow one", and a narrowing caller "must resolve $CONFIG itself".
      #
      # Parse the shared snapshot successfully before defaulting absent fields
      # (#1359). A failed parse is not absence and must not synthesize a
      # skippable provider. One structured parse serves both identity sets,
      # including flow-style YAML (#1124), just as it does in accounting.
      if [ -n "$__cra_base_cfg" ] && [ -r "$__cra_base_cfg" ] \
         && __cra_policy_json=$(policy_yaml_to_json "$__cra_base_cfg" 2>/dev/null) \
         && printf '%s' "$__cra_policy_json" | jq -e 'type == "object"' >/dev/null 2>&1 \
         && __cra_cr_bot=$(printf '%s' "$__cra_policy_json" | jq -r '.coderabbit.bot_login // empty' 2>/dev/null) \
         && __cra_ghas_bot=$(printf '%s' "$__cra_policy_json" | jq -r '.code_scanning.bot_login // empty' 2>/dev/null) \
         && __cra_codex_bot=$(printf '%s' "$__cra_policy_json" | jq -r '.codex.bot_login // empty' 2>/dev/null) \
         && __cra_author_id=$(printf '%s' "$__cra_policy_json" | jq -r '.author_identity // empty' 2>/dev/null) \
         && __cra_reviewers=$(printf '%s' "$__cra_policy_json" | jq -r '.available_reviewers[]? // empty' 2>/dev/null); then
        __cra_relax=$(printf '%s\n%s\n' \
          "${__cra_cr_bot:-coderabbitai[bot]}" \
          "${__cra_ghas_bot:-github-advanced-security[bot]}" \
          | LC_ALL=C tr '[:upper:]' '[:lower:]' | grep -v '^$' || true)
        # Sourcing the relax set from the BASE policy stops a PR nominating its
        # own skippable providers, but it does not stop a COLLISION.
        # validate_governing_policy (review-feedback-accounting.sh:127-129)
        # checks codex/coderabbit/code_scanning bot_login only as
        # `optional_string`, and available_reviewers only as non-empty strings;
        # nothing requires these identities to be DISTINCT. So a base policy
        # that sets coderabbit.bot_login to the Codex bot -- or to a registered
        # Phase 4b reviewer, or the author identity -- passes validation, gets
        # that login's findings inventoried as gating, and would then have them
        # relaxed by a login-only allowlist.
        #
        # Refuse the WHOLE relax set on any collision rather than subtracting
        # the colliding entry: a policy that gives two providers one login has
        # not named either of them, and the safe reading of an ambiguous
        # skippable set is that nothing is skippable.
        #
        # Empty and absent values share accounting's established defaults;
        # every parse/extraction failure took the empty-relax branch instead.
        __cra_gating=$(printf '%s\n%s\n%s\n' \
          "${__cra_codex_bot:-chatgpt-codex-connector[bot]}" \
          "${__cra_author_id:-nathanjohnpayne}" \
          "$__cra_reviewers" \
          | LC_ALL=C tr '[:upper:]' '[:lower:]' | grep -v '^$' || true)
        if [ -n "$__cra_relax" ] && [ -n "$__cra_gating" ] \
           && printf '%s\n' "$__cra_relax" | grep -xF "$__cra_gating" >/dev/null; then
          log "review feedback accounting: the governing base policy gives a skippable provider the same login as Codex, the author identity, or a registered reviewer; no provider is skippable (#1100)"
          __cra_relax=""
        fi
      else
        __cra_relax=""
        log "review feedback accounting: could not resolve or parse the governing base policy; no provider is skippable (#1100)"
      fi
      __cra_blocking=$(printf '%s' "$output" | jq -r --arg relax "$__cra_relax" '
        ($relax | split("\n") | map(select(length > 0))) as $ok
        | if ((.missing | type) != "array") or ((.missing | length) == 0) then 1
          else [ .missing[] | select(((.reviewer // "") | ascii_downcase) as $r | ($ok | index($r)) == null) ] | length
          end' 2>/dev/null || printf '1')
      if [ "${__cra_blocking:-1}" -gt 0 ]; then
        printf '%s\n' "$output" >&2
        die 6 "review feedback is unaccounted; disposition every finding before requesting another Codex review"
      fi
      log "review feedback accounting: $(printf '%s' "$output" | jq -r '(.missing // []) | length' 2>/dev/null || printf '?') undispositioned finding(s), none from a provider that gates this request (#1100) — proceeding"
      ;;
    *)
      printf '%s\n' "$output" >&2
      die 3 "review feedback accounting gate failed with exit $rc"
      ;;
  esac
}

# #2657: five-request checkpoint. Once a PR already counts
# CODEX_REQUEST_CHECKPOINT_AFTER counted requests (the same crqe_count_triggers
# count the ceiling uses; failover triggers excluded), record ONE author-owned
# marker comment once the next new request has posted, so a restarted session
# sees it.
# It asks the agent to reassess scope and recurring findings, batch the
# remaining fixes and strengthen tests before continuing. It is informational:
# it never blocks, never spends or refunds a request, and a failed write only
# warns. The body must never contain the Codex trigger phrase.
CODEX_REQUEST_CHECKPOINT_AFTER=5
CODEX_REQUEST_CHECKPOINT_MARKER='<!-- mergepath-codex-request-checkpoint:v1'
REQUEST_CHECKPOINT_JSON=null
record_request_checkpoint() { # <request-comments-json> <counted> <ceiling>
  local comments="$1" counted="$2" ceiling="$3" existing body body_file
  [ "$counted" -ge "$CODEX_REQUEST_CHECKPOINT_AFTER" ] || return 0
  # Only a generated marker line opening the comment counts, never a quote
  # of the marker text in an ordinary comment.
  existing=$(printf '%s' "$comments" | jq -r --arg who "$AUTHOR_IDENTITY" \
    '[.[] | select((.user.login // "" | ascii_downcase) == ($who | ascii_downcase))
          | select((.body // "") | test("\\A<!-- mergepath-codex-request-checkpoint:v1 counted=[0-9]+ head=[0-9a-f]{40,64} -->(\\n|\\z)")) | .id] | first // empty' 2>/dev/null) || existing=""
  if [ -n "$existing" ]; then
    REQUEST_CHECKPOINT_JSON=$(jq -nc --argjson n "$counted" --arg id "$existing" \
      '{after:5,counted_requests:$n,recorded:"existing",comment_id:($id|tonumber? // null)}')
    return 0
  fi
  # Every staging failure is nonblocking too: under `set -e` an unguarded
  # write error would end the request before it posts.
  # The comment is posted to whichever repository runs this propagated
  # script, so the hub issue is fully qualified. The body is one simple
  # command's write: a redirect failure on a `{ }` group is not reliably seen.
  body=$(
    printf '%s counted=%s head=%s -->\n' "$CODEX_REQUEST_CHECKPOINT_MARKER" "$counted" "$HEAD_SHA"
    printf '**Codex request checkpoint (nathanjohnpayne/mergepath#2657).** This PR already counts %s Codex requests (request ceiling %s, blocking-review budget %s).\n\n' \
      "$counted" "$ceiling" "${GOVERNING_BLOCKING_REVIEW_BUDGET:-default}"
    printf 'Before the next round: reassess the scope and any recurring findings, batch the remaining fixes into one push, and strengthen the tests or shared fixtures that let those findings through. This note is informational. It blocks nothing and changes no budget.'
  )
  body_file=$(mktemp "${TMPDIR:-/tmp}/codex-request-checkpoint.XXXXXX") || body_file=""
  if [ -z "$body_file" ] || ! printf '%s\n' "$body" 2>/dev/null >"$body_file"; then
    log "WARN: request checkpoint (#2657) body could not be staged; continuing (the checkpoint is informational)"
    REQUEST_CHECKPOINT_JSON=$(jq -nc --argjson n "$counted" '{after:5,counted_requests:$n,recorded:"failed",comment_id:null}')
    [ -z "$body_file" ] || rm -rf "$body_file" 2>/dev/null || :
    return 0
  fi
  # A subshell contains post_author_pr_comment's `die`: the checkpoint must
  # never abort the request it precedes.
  if ( post_author_pr_comment "$(cat "$body_file")" "Codex request checkpoint" body-file ) >/dev/null 2>&1; then
    log "request checkpoint (#2657): $counted counted requests; recorded a checkpoint comment — reassess scope, batch fixes, strengthen tests before continuing"
    REQUEST_CHECKPOINT_JSON=$(jq -nc --argjson n "$counted" '{after:5,counted_requests:$n,recorded:"posted",comment_id:null}')
  else
    log "WARN: request checkpoint (#2657) comment could not be posted; continuing (the checkpoint is informational)"
    REQUEST_CHECKPOINT_JSON=$(jq -nc --argjson n "$counted" '{after:5,counted_requests:$n,recorded:"failed",comment_id:null}')
  fi
  rm -f "$body_file" 2>/dev/null || :
  return 0
}

post_author_pr_comment() { # <body> <purpose> [body-file|inline]
  local body="$1" purpose="$2" mode="${3:-body-file}" AS_AUTHOR bridge_author_pat=""
  local body_file="" output="" rc=0 identity_checker
  local -a body_args
  AS_AUTHOR="$__CODEX_REQUEST_DIR/gh-as-author.sh"
  if [ ! -x "$AS_AUTHOR" ]; then
    echo "ERROR: gh-as-author.sh helper missing or non-executable: $AS_AUTHOR" >&2
    echo "       Refusing to post $purpose without author-token attribution." >&2
    die 3 "gh-as-author.sh helper unavailable"
  fi

  # Inline author-PAT bridging (#438): gh-as-author.sh's resolver
  # intentionally ignores ambient GH_TOKEN — it reads only
  # OP_PREFLIGHT_AUTHOR_PAT or a stored `gh auth token --user`. In a
  # CI/fresh shell with no preflight cache and no keyring, the
  # still-documented `GH_TOKEN=<author PAT> codex-review-request.sh`
  # invocation shape passed every read-side check and then failed the
  # trigger write despite holding a valid author token, forcing an
  # unnecessary Phase 4b fallback. Bridge the ambient token into the
  # wrapper's preferred env var ONLY after verifying it actually
  # resolves to the author identity; any other token (the common
  # reviewer-PAT session shape) is left alone so the wrapper's own
  # resolution proceeds unchanged and fails closed as before.
  if [ -n "${GH_TOKEN:-}" ] && [ -z "${OP_PREFLIGHT_AUTHOR_PAT:-}" ]; then
    identity_checker="$__CODEX_REQUEST_DIR/identity-check.sh"
    if [ -x "$identity_checker" ] \
      && GH_TOKEN="$GH_TOKEN" "$identity_checker" --expect-write-identity "$AUTHOR_IDENTITY" >/dev/null 2>&1; then
      log "ambient GH_TOKEN verifies as author identity $AUTHOR_IDENTITY — bridging it into gh-as-author.sh as OP_PREFLIGHT_AUTHOR_PAT"
      bridge_author_pat="$GH_TOKEN"
    fi
  fi

  # The established trigger contract uses the exact safe literal
  # `--body "@codex review"`; preserve it so wrapper policy/tests and the App's
  # command matching do not change as a side effect of #1085. New machine
  # markers use --body-file, keeping their structured Markdown out of shell
  # arguments and following the repository write rule.
  case "$mode" in
    inline) body_args=(--body "$body") ;;
    body-file)
      body_file=$(mktemp "${TMPDIR:-/tmp}/codex-author-comment.XXXXXX") \
        || die 3 "could not create temporary body file for $purpose"
      printf '%s' "$body" >"$body_file" \
        || die 3 "could not write temporary body file for $purpose"
      body_args=(--body-file "$body_file")
      ;;
    *) die 3 "unknown author-comment body mode: $mode" ;;
  esac

  # Capture stdout+stderr so a failure surfaces the real gh error (404 / 403 /
  # 422) rather than a bare failure. gh's comment URL remains extractable by
  # the caller for the mandatory post-write readback.
  # Pass the configured author identity on BOTH invocation branches:
  # the wrapper's hard default (nathanjohnpayne) would reject a valid
  # custom-author token in repos that override author_identity —
  # bridged-token case (Codex P2 on PR #442 r2) AND warm-preflight /
  # keyring case (Codex P2 on PR #442 r5). review-policy.yml is the
  # source of truth this script already reads, so it wins.
  if [ -n "$bridge_author_pat" ]; then
    output=$(OP_PREFLIGHT_AUTHOR_PAT="$bridge_author_pat" GH_AS_AUTHOR_IDENTITY="$AUTHOR_IDENTITY" "$AS_AUTHOR" -- gh pr comment "$PR_NUMBER" --repo "$REPO" "${body_args[@]}" 2>&1) \
      || rc=$?
  else
    output=$(GH_AS_AUTHOR_IDENTITY="$AUTHOR_IDENTITY" "$AS_AUTHOR" -- gh pr comment "$PR_NUMBER" --repo "$REPO" "${body_args[@]}" 2>&1) \
      || rc=$?
  fi
  [ -z "$body_file" ] || rm -f "$body_file"
  if [ "$rc" -ne 0 ] && [ "$TRIGGER_POSTED" = true ] \
     && [ "$mode" = inline ] && [ "$body" = '@codex review' ] \
     && grep -Fqx '[codex-review-request] ERROR: trigger not authorized: existing-trigger' <<< "$output"; then
    # The real wrapper's canonical authorizer may refuse an ack retry as a
    # duplicate. Preserve this run's confirmed request and its original poll
    # clock, but only while fresh evidence still names that exact request.
    local ack_comments ack_trigger
    revalidate_request_freshness
    ack_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "ack retry duplicate evidence") \
      || die 3 "cannot confirm the refused acknowledgement retry's existing trigger"
    ack_trigger=$(crqe_select_trigger "$ack_comments" "$AUTHOR_IDENTITY" "") \
      || die 3 "cannot select the refused acknowledgement retry's existing trigger"
    if printf '%s' "$ack_trigger" | jq -e --arg id "$TRIGGER_COMMENT_ID" --arg created "$TRIGGER_POST_TIME" \
         '(.id | tostring) == $id and .created_at == $created' >/dev/null 2>&1; then
      ACK_RETRY_REFUSED_BY_EXISTING=true
      log "existing trigger $TRIGGER_COMMENT_ID refused the acknowledgement retry — continuing normal review poll"
      return 1
    fi
  fi
  if [ "$rc" -ne 0 ] && [ "$mode" = inline ] && [ "$body" = '@codex review' ] && [ "$TRIGGER_POSTED" != true ] \
     && grep -Eqx '\[codex-review-request\] ERROR: trigger not authorized: (concurrent-request|existing-trigger|pending-request-unanswered|pending-request-running)' <<< "$output"; then
    die 3 "another guarded Codex request for $REPO#$PR_NUMBER posted first (#1362); this run posted nothing. A polling rerun waits on that request rather than posting another, and hands it to Phase 4b if it times out (#2664): $output"
  fi
  [ "$rc" -eq 0 ] || die 3 "failed to post $purpose: $output"
  AUTHOR_COMMENT_OUTPUT="$output"
}

# The request-attempt cap is an intentional review-loop stop, not an API
# failure and not a Phase 4a timeout. Emit the normal requester observations
# with a machine-readable stop outcome. The caller owns its already-selected
# advisory or required review policy; this write cap does not classify it.
# Malformed policy or unreadable request
# evidence never reaches this function; those remain exit 3 infrastructure
# failures.
emit_cap_exhausted() { # <kind> <request_attempts> <max_request_attempts>
  local kind="$1" request_attempts="$2" max_request_attempts="$3"
  jq -n \
    --arg kind "$kind" \
    --argjson blocking_reviews "${BLOCKING_REVIEW_COUNT:-null}" \
    --argjson max_blocking_reviews "${BLOCKING_REVIEW_LIMIT:-null}" \
    --argjson pr_number "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg head_sha "$HEAD_SHA" \
    --arg head_committer_date "$HEAD_COMMITTER_DATE" \
    --arg bot_login "$BOT_LOGIN" \
    --argjson scan "$INITIAL_SCAN" \
    --argjson request_attempts "$request_attempts" \
    --argjson max_request_attempts "$max_request_attempts" \
    --argjson elapsed "$ELAPSED" '
    {
      pr_number: $pr_number,
      repo: $repo,
      head_sha: $head_sha,
      head_committer_date: $head_committer_date,
      bot_login: $bot_login,
      review: $scan.review,
      findings: $scan.findings,
      reaction: $scan.reaction,
      verdict: $scan.verdict,
      blocked_reason: null,
      terminal_determination: null,
      cap_exhausted: {
        kind: $kind,
        request_attempts: $request_attempts,
        max_request_attempts: $max_request_attempts,
        blocking_reviews: $blocking_reviews,
        max_blocking_reviews: $max_blocking_reviews,
        observed_provider_block: $scan.blocked
      },
      trigger_posted: false,
      trigger_requested: true,
      rounds_waited_seconds: $elapsed
    }
  '
  exit 7
}

governing_request_attempt_cap() {
  # The cap protects the request WRITE, so the policy controlling it must be
  # the PR's governing base policy. Reading only $CONFIG here lets a candidate
  # raise its own budget before asking for another scarce provider review.
  local budget_json base_cap resolver
  GOVERNING_REQUEST_ATTEMPT_CAP=""
  GOVERNING_BLOCKING_REVIEW_BUDGET=""

  resolver="$__CODEX_REQUEST_DIR/workflow/resolve_base_policy.sh"
  [ -x "$resolver" ] \
    || die 3 "governing review-policy resolver unavailable; refusing a new '@codex review' trigger"
  declare -F crqe_governing_budget >/dev/null \
    || die 3 "governing review-policy parser unavailable; refusing a new '@codex review' trigger"
  budget_json=$(crqe_governing_budget "$REPO" "$PR_NUMBER" "$CONFIG" \
    "$AUTHOR_IDENTITY" "$resolver") \
    || die 3 "cannot read the governing review policy/request budget; refusing a new '@codex review' trigger"
  base_cap=$(printf '%s' "$budget_json" | jq -r '.max_request_attempts')

  GOVERNING_REQUEST_ATTEMPT_CAP="$base_cap"
  # Validated only where it is used (a new request): an acknowledgement retry
  # does not re-check the blocking budget, so it must not fail on it either.
  GOVERNING_BLOCKING_REVIEW_BUDGET=$(printf '%s' "$budget_json" | jq -r '.max_blocking_reviews')
  GOVERNING_POLICY_FINGERPRINT=$(printf '%s' "$budget_json" | jq -r '.policy_fingerprint // empty')
}

# The blocking-review budget (#1560 slice 3). Counts, across the whole PR, the
# solicited Codex responses the review ledger (specs/codex_review_ledger.md)
# classifies as blocking. A response counts when it came after at least one
# request (unsolicited == false) and any of:
#   - class "blocking": a finding at p0 or a required tier;
#   - class "unknown_tier": a non-affirmative verdict whose tier is unknown;
#   - conflicting: its own signals disagree (a blocking review beside a clean
#     signal, or verdicts that disagree).
# Unknown and conflicting evidence counts against the budget, never for it.
# The count needs no request attribution, so the ledger's ambiguous windows
# do not affect it. A class outside the ledger's known set (version skew,
# malformed output) is refused rather than read as non-blocking. Sets
# BLOCKING_REVIEW_COUNT; any failure to produce an exact count is exit 3 with
# no trigger posted.
count_blocking_reviews() {
  local ledger_cmd ledger rc=0
  ledger_cmd="${MERGEPATH_CODEX_LEDGER_CMD:-$__CODEX_REQUEST_DIR/codex-review-ledger.sh}"
  command -v "$ledger_cmd" >/dev/null 2>&1 \
    || die 3 "Codex review ledger unavailable: $ledger_cmd; refusing a new '@codex review' trigger"
  [[ "${GOVERNING_POLICY_FINGERPRINT:-}" =~ ^[0-9]+-[0-9]+$ ]] \
    || die 3 "the governing policy snapshot has no fingerprint; refusing a new '@codex review' trigger"
  ledger=$(MERGEPATH_REVIEW_POLICY_PATH="$CONFIG" "$ledger_cmd" --repo "$REPO" \
    --expect-head "$HEAD_SHA" --expect-policy "$GOVERNING_POLICY_FINGERPRINT" "$PR_NUMBER") || rc=$?
  [ "$rc" -eq 0 ] \
    || die 3 "Codex review ledger failed (exit $rc); cannot count blocking reviews; refusing a new '@codex review' trigger"
  # Exactly one ledger document (-s), read under the same policy snapshot as
  # the limit: the ledger refuses a fingerprint other than ours and echoes its
  # own, so author, bot, tiers and budget all come from one base revision. A
  # base that moved between the two resolutions is conflicting evidence, never
  # a value to pick.
  BLOCKING_REVIEW_COUNT=$(printf '%s' "$ledger" | jq -ser \
    --arg head "$HEAD_SHA" --arg author "$AUTHOR_IDENTITY" \
    --argjson limit "$BLOCKING_REVIEW_LIMIT" --arg fp "$GOVERNING_POLICY_FINGERPRINT" '
    if length != 1 then error("documents") else .[0] end
    | if type == "object" and .head_sha == $head and .author == $author
       and .max_blocking_reviews == $limit and .policy_fingerprint == $fp
       and (.responses | type) == "array"
       and all(.responses[]; (.unsolicited | type) == "boolean"
                             and ((.first_at | type) == "string" and (.first_at | length) > 0)
                             and (.class as $c | ["blocking", "discretionary", "no_findings", "clean",
                                                  "unknown_tier", "provider_blocked"] | index($c)) != null
                             and (.conflicting | type) == "boolean")
    then [ .responses[]
           | select((.unsolicited | not)
                    and (.class == "blocking" or .class == "unknown_tier" or .conflicting)) ]
         | length
    else error("ledger") end' 2>/dev/null) \
    || die 3 "Codex review ledger output is malformed, or names another head, author, budget or policy snapshot; refusing a new '@codex review' trigger"
  [[ "$BLOCKING_REVIEW_COUNT" =~ ^[0-9]+$ ]] \
    || die 3 "Codex review ledger produced no single blocking-review count; refusing a new '@codex review' trigger"
}

preserve_final_request_timeout() { # <comments-json> <selected-trigger-json>
  local state live_head
  if [ "$CODEX_FAILURE_MARKERS_OK" != true ] \
     || ! command -v codex_phase4a_timeout_marker_state >/dev/null 2>&1; then
    die 3 "cannot classify the final Codex request: shared terminal-marker helper unavailable"
  fi
  state=$(codex_phase4a_timeout_marker_state "$HEAD_SHA" "$AUTHOR_IDENTITY" "$1")
  case "$(printf '%s' "$state" | jq -r '.state // "malformed"')" in
    current) ;;
    none|stale|superseded) return 0 ;;
    *) die 3 "cannot classify the final Codex request: trusted terminal-marker evidence is malformed" ;;
  esac
  # The marker parser recognizes exact lowercase commands; the request
  # selector also recognizes case variants. A newer selected command must
  # supersede an older timeout even when only the selector recognizes it.
  printf '%s' "$state" | jq -e --argjson trigger "$2" \
    '.trigger_comment_id == $trigger.id' >/dev/null || return 0
  live_head=$(gh_api_scalar --shape sha "Recorded Phase 4a timeout live PR head" \
    "repos/$REPO/pulls/$PR_NUMBER" --jq '.head.sha') \
    || die 3 "cannot reuse Phase 4a timeout: live PR head is unreadable"
  [ "$live_head" = "$HEAD_SHA" ] \
    || die 3 "cannot reuse Phase 4a timeout: PR head moved from $HEAD_SHA to $live_head"
  log "final Codex request already has a validated timeout determination; preserving its fallback without another poll or write"
  jq -n --argjson pr_number "$PR_NUMBER" --arg repo "$REPO" \
    --arg head_sha "$HEAD_SHA" --arg head_committer_date "$HEAD_COMMITTER_DATE" \
    --arg bot_login "$BOT_LOGIN" --argjson scan "$INITIAL_SCAN" --argjson state "$state" '
    {
      pr_number: $pr_number, repo: $repo, head_sha: $head_sha,
      head_committer_date: $head_committer_date, bot_login: $bot_login,
      review: $scan.review, findings: $scan.findings,
      reaction: $scan.reaction, verdict: $scan.verdict, blocked_reason: null,
      terminal_determination: {
        provider: "codex", outcome: "timeout", marker_comment_id: $state.marker_id
      },
      trigger_posted: false, trigger_requested: true, rounds_waited_seconds: 0
    }'
  exit 4
}

# The blocking-review budget (#1560 slice 3). Checked before any new request
# write and before every request-ceiling stop, so it takes precedence when both
# budgets are spent: a PR that has drawn max_blocking_reviews solicited blocking
# reviews stops for the human whatever its request count. The boundary is
# explicit: with a budget of 10, a request is refused once 10 such reviews
# exist. An acknowledgement retry re-asks for a request that already passed
# this check, and reusing the final pending request posts nothing, so neither
# runs it.
check_blocking_budget() { # <request_count> <max_review_rounds>
  [[ "$GOVERNING_BLOCKING_REVIEW_BUDGET" =~ ^[0-9]+$ ]] \
    || die 3 "the governing codex.max_blocking_reviews is invalid; refusing a new '@codex review' trigger"
  BLOCKING_REVIEW_LIMIT="$GOVERNING_BLOCKING_REVIEW_BUDGET"
  count_blocking_reviews
  if [ "$BLOCKING_REVIEW_COUNT" -ge "$BLOCKING_REVIEW_LIMIT" ]; then
    log "Codex blocking-review budget spent for $REPO#$PR_NUMBER ($BLOCKING_REVIEW_COUNT/$BLOCKING_REVIEW_LIMIT solicited blocking reviews); refusing additional '@codex review' requests"
    emit_cap_exhausted blocking-reviews "$1" "$2"
  fi
}

# The moving-head guard (#2166). Runs once per run, immediately before the
# FIRST new trigger write: not on an acknowledgement retry (the head was
# accepted when the first trigger of this run went out), not on a dedup skip
# or a cleared head (those post nothing). It is a cycle-time guard, not a
# merge gate: every merge requirement is enforced elsewhere, so each signal
# fails OPEN on an unreadable input with a distinct log line, and the
# observations are reported rather than silently coerced.
#
# Two signals, each independently refusing:
#   head-age       age of the HEAD pushed-at anchor < request_min_head_age_seconds
#   check-missing  CI has not picked the head up: no repo-lint workflow run
#                  for the head SHA (or, under the request_requires_check
#                  override, no check-run by that exact name)
# Refusal is exit 8 with no write. --allow-moving-head, or an automatic caller
# (MERGEPATH_CODEX_AUTO_TRIGGER, which fires on a provider event rather than
# on a push the agent is still amending), turns the refusal into a warning.
MOVING_HEAD_AGE_SECONDS=null
MOVING_HEAD_CHECK_STATUS=""
MOVING_HEAD_ANCHOR=""
refuse_moving_head_unless_allowed() {
  local reasons="" pushed_epoch now_epoch age runs status allow=false
  resolve_request_check_signal
  # A malformed knob is a configuration error on the write path: refuse
  # before the guard's own reads and before any write (#2253; it used to be
  # checked at load time, which also failed the no-write paths).
  if ! [[ "$REQUEST_MIN_HEAD_AGE_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: codex.request_min_head_age_seconds must be a non-negative integer; got '$REQUEST_MIN_HEAD_AGE_SECONDS'" >&2
    exit 3
  fi
  case "${MERGEPATH_CODEX_AUTO_TRIGGER:-}" in
    true|TRUE|True|1|yes|YES) allow=true ;;
  esac
  [ "$ALLOW_MOVING_HEAD" = true ] && allow=true

  # The CI-pickup read comes first: it also supplies the push-time anchor for
  # the age signal below.
  local dispatched_at="" anchor="$HEAD_PUSHED_AT" anchor_source="$ANCHOR_SOURCE" check_reason=""
  local signal_label="" wf check_dispatch_unavailable=false
  case "$REQUEST_SIGNAL_MODE" in
    workflow)
      signal_label="$REQUEST_WORKFLOW_NAME"
      # Every workflow run for the head SHA, paginated (one head collects a
      # run per triggering event, which can exceed a page), filtered to
      # repo-lint by name or by its canonical path.
      runs=$(gh api --paginate -X GET "repos/$REPO/actions/runs" \
        -f head_sha="$HEAD_SHA" -F per_page=100 2>/dev/null) || runs=""
      # Scoped to the PR's head branch (Codex P2 on #2175): the same SHA can
      # carry runs from another branch it was pushed to earlier, and those
      # neither prove CI picked up THIS push nor date it.
      runs=$(printf '%s' "$runs" | jq -c -s --arg n "$REQUEST_WORKFLOW_NAME" --arg p "$REQUEST_WORKFLOW_PATH" --arg b "$HEAD_REF" '
        if length > 0 and all(.[]; type == "object" and ((.workflow_runs | type) == "array"))
        then [ .[].workflow_runs[]
               | select((.name // "") == $n or ((.path // "") | startswith($p)))
               | select($b == "" or (.head_branch // "") == $b) ]
        else "unreadable" end' 2>/dev/null) || runs='"unreadable"'
      if [ "$runs" = '"unreadable"' ] || [ -z "$runs" ]; then
        status=unreadable
      elif [ "$(printf '%s' "$runs" | jq 'length')" -gt 0 ]; then
        status=$(printf '%s' "$runs" | jq -r 'sort_by(.id) | last | .status // "unknown"')
        # Only PR/push events date this push. Any event proves pickup, but a
        # later manual or scheduled run must not restart a settled head's age
        # guard (#2198). A re-run keeps the original created_at.
        dispatched_at=$(printf '%s' "$runs" | jq -r '
          [.[] | select(.event == "pull_request" or .event == "push")
           | (.created_at // empty)
           | select(type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))] | max // ""')
      else
        # No repo-lint run on this head. Either CI has not picked it up yet,
        # or this repo has no repo-lint workflow and never will: tell the two
        # apart, because the second must not refuse forever.
        wf=$(gh api --paginate -X GET "repos/$REPO/actions/workflows" -F per_page=100 2>/dev/null) || wf=""
        status=$(printf '%s' "$wf" | jq -r -s --arg n "$REQUEST_WORKFLOW_NAME" --arg p "$REQUEST_WORKFLOW_PATH" '
          if length > 0 and all(.[]; type == "object" and ((.workflows | type) == "array"))
          then (if any(.[].workflows[]; (.name // "") == $n or (.path // "") == $p)
                then "missing" else "no-workflow" end)
          else "unreadable" end' 2>/dev/null) || status=unreadable
      fi
      ;;
    check)
      signal_label="$REQUEST_REQUIRES_CHECK"
      # Exact server-side name filter; the client-side select repeats it so a
      # server that ignores the filter cannot pass a differently named run off
      # as this one. Any run counts, whatever its status. -f encodes the name:
      # a configured check name may carry spaces. PAGINATED and slurped
      # (Codex P1 on #2175): per_page caps at 100, and a long-lived head
      # carries more check runs than that.
      runs=$(gh api --paginate -X GET "repos/$REPO/commits/$HEAD_SHA/check-runs" \
        -f check_name="$REQUEST_REQUIRES_CHECK" -F per_page=100 2>/dev/null) || runs=""
      # Check runs are attached to the COMMIT, not the branch (Codex P2 on
      # #2175): a SHA checked before on another branch carries that old run.
      # Scope to the check suites GitHub created for the PR's head branch;
      # with no head ref there is nothing to scope by and every suite counts.
      local suites='null'
      if [ -n "$HEAD_REF" ]; then
        suites=$(gh api --paginate -X GET "repos/$REPO/commits/$HEAD_SHA/check-suites" \
          -F per_page=100 2>/dev/null) || suites=""
        suites=$(printf '%s' "$suites" | jq -c -s --arg b "$HEAD_REF" '
          if length > 0 and all(.[]; type == "object" and ((.check_suites | type) == "array"))
          then {known: [ .[].check_suites[] | select((.head_branch // "") == $b) | .id ],
                created: [ .[].check_suites[] | select((.head_branch // "") == $b)
                           | {id, created_at} ],
                unknown: [ .[].check_suites[]
                           | select((.head_branch | type) != "string" or .head_branch == "") | .id ]}
          else "unreadable" end' 2>/dev/null) || suites='"unreadable"'
        [ -n "$suites" ] || suites='"unreadable"'
      fi
      if [ "$suites" = '"unreadable"' ]; then
        status=unreadable
      else
        runs=$(printf '%s' "$runs" | jq -c -s --arg n "$REQUEST_REQUIRES_CHECK" --argjson ids "$suites" '
          if length > 0 and all(.[]; type == "object" and ((.check_runs | type) == "array"))
          then [ .[].check_runs[] | select((.name // "") == $n) ] as $named
             | [ $named[] | select($ids == null or
                 ((.check_suite.id // null) as $s | ($ids.known | index($s)) != null)) ] as $known
             | if ($known | length) > 0 then $known
               elif $ids != null and any($named[];
                 (.check_suite.id // null) as $s | ($ids.unknown | index($s)) != null)
               then "branch-unavailable"
               else [] end
          else "unreadable" end' 2>/dev/null) || runs='"unreadable"'
        if [ "$runs" = '"unreadable"' ] || [ -z "$runs" ]; then
          status=unreadable
        elif [ "$runs" = '"branch-unavailable"' ]; then
          status=branch-unavailable
        else
          status=$(printf '%s' "$runs" | jq -r 'sort_by(.id) | last | .status // "missing"' 2>/dev/null) || status=unreadable
          [ "$status" != null ] || status=missing
        fi
      fi
      # Latest run, as in the workflow path: an earlier run of the same SHA
      # must not date the current push.
      if [ "$status" != unreadable ] && [ "$status" != missing ] && [ "$status" != branch-unavailable ]; then
        dispatched_at=$(printf '%s' "$runs" | jq -r --argjson suites "$suites" '
          def timestamp: select(type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"));
          [.[] | .check_suite.id as $id
           | [.created_at, .started_at,
              ($suites.created[]? | select(.id == $id) | .created_at)]
           | map(timestamp) | first // empty] | max // ""' 2>/dev/null) || dispatched_at=""
        if [ -z "$dispatched_at" ]; then
          # Queued checks have no start time. Without any dispatch timestamp,
          # an old commit date cannot establish pickup age. Keep the anchor
          # until its age is checked so an independently young head still holds.
          check_dispatch_unavailable=true
        fi
      fi
      ;;
    *) status="" ;;
  esac
  if [ "$REQUEST_SIGNAL_MODE" != off ]; then
    [ -n "$status" ] && [ "$status" != null ] || status=unreadable
    MOVING_HEAD_CHECK_STATUS=$status
    case "$status" in
      unreadable)
        log "moving-head guard: CI-pickup signal ('$signal_label') for $HEAD_SHA unreadable; not enforced" ;;
      branch-unavailable)
        log "moving-head guard: matching '$signal_label' check has unavailable suite branch attribution; CI-pickup signal not enforced" ;;
      no-workflow)
        log "WARNING: moving-head guard: this repository has no '$REQUEST_WORKFLOW_NAME' workflow ($REQUEST_WORKFLOW_PATH), so the CI-pickup signal cannot be observed; not enforced (set codex.request_requires_check to name another check)" ;;
      missing)
        check_reason="check-missing"
        if [ "$REQUEST_SIGNAL_MODE" = workflow ]; then
          log "moving-head guard: no '$REQUEST_WORKFLOW_NAME' workflow run exists for HEAD $HEAD_SHA yet: CI has not picked this head up"
        else
          log "moving-head guard: no check-run named '$REQUEST_REQUIRES_CHECK' has been scheduled on HEAD $HEAD_SHA (codex.request_requires_check)"
        fi ;;
      *)
        log "moving-head guard: '$signal_label' is $status on HEAD"
        # Push-time anchor (Codex P2 on #2175). HEAD_PUSHED_AT is the commit's
        # committer date unless a force-push replaced it, so an ordinary push
        # of a commit created long before reads as an old head the moment it
        # lands. The latest run of the signal for this head on the PR branch
        # was created when GitHub dispatched the current push, which is the
        # push time this signal means. Use whichever is later. Missing check
        # dispatch metadata retains only an independently young age signal.
        if [ -n "$dispatched_at" ] && [[ "$dispatched_at" > "$anchor" ]]; then
          anchor="$dispatched_at"
          anchor_source="latest '$signal_label' dispatch for HEAD on the PR branch (push dispatch)"
        fi ;;
    esac
  fi

  if [ "$REQUEST_MIN_HEAD_AGE_SECONDS" -gt 0 ]; then
    pushed_epoch=$(jq -rn --arg t "$anchor" \
      '$t | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null) || pushed_epoch=""
    now_epoch=$(date +%s)
    if [[ "$pushed_epoch" =~ ^[0-9]+$ ]]; then
      age=$((now_epoch - pushed_epoch))
      [ "$age" -ge 0 ] || age=0
      if [ "$check_dispatch_unavailable" = true ] && [ "$age" -ge "$REQUEST_MIN_HEAD_AGE_SECONDS" ]; then
        anchor=""
        anchor_source="unavailable check dispatch timestamp"
        pushed_epoch=""
      fi
    fi
    if [[ "$pushed_epoch" =~ ^[0-9]+$ ]]; then
      MOVING_HEAD_AGE_SECONDS=$age
      if [ "$age" -lt "$REQUEST_MIN_HEAD_AGE_SECONDS" ]; then
        reasons="head-age"
        log "moving-head guard: HEAD was pushed ${age}s ago (anchor $anchor, source: $anchor_source), under codex.request_min_head_age_seconds=$REQUEST_MIN_HEAD_AGE_SECONDS"
      fi
    else
      log "moving-head guard: HEAD pushed-at anchor '$anchor' is not parseable; head-age signal unavailable, not enforced"
    fi
  fi
  [ -z "$check_reason" ] || reasons="${reasons:+$reasons,}$check_reason"
  MOVING_HEAD_ANCHOR="$anchor"

  [ -n "$reasons" ] || return 0
  if [ "$allow" = true ]; then
    log "WARNING: head does not look final for a review round ($reasons); posting anyway because the caller allowed a moving head"
    return 0
  fi
  log "refusing to post '@codex review' on a moving head ($reasons); a Codex request goes out once per batch, when the head is final: every known finding addressed, local tests green, no further push planned. Rerun once the head has settled, or pass --allow-moving-head (exit 8)"
  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg head_sha "$HEAD_SHA" \
    --arg head_committer_date "$HEAD_COMMITTER_DATE" \
    --arg bot_login "$BOT_LOGIN" \
    --argjson scan "$INITIAL_SCAN" \
    --arg reasons "$reasons" \
    --argjson age "$MOVING_HEAD_AGE_SECONDS" \
    --argjson min_age "$REQUEST_MIN_HEAD_AGE_SECONDS" \
    --arg pushed_at "$MOVING_HEAD_ANCHOR" \
    --arg check_name "$signal_label" \
    --arg check_kind "$REQUEST_SIGNAL_MODE" \
    --arg check_status "$MOVING_HEAD_CHECK_STATUS" '
    {
      pr_number: $pr_number,
      repo: $repo,
      head_sha: $head_sha,
      head_committer_date: $head_committer_date,
      bot_login: $bot_login,
      review: $scan.review,
      findings: $scan.findings,
      reaction: $scan.reaction,
      verdict: $scan.verdict,
      blocked_reason: null,
      terminal_determination: null,
      moving_head: {
        reasons: ($reasons | split(",")),
        head_pushed_at: $pushed_at,
        age_seconds: $age,
        min_age_seconds: $min_age,
        check_kind: (if $check_kind == "off" then null else $check_kind end),
        check_name: (if $check_name == "" then null else $check_name end),
        check_status: (if $check_status == "" then null else $check_status end)
      },
      trigger_posted: false,
      trigger_requested: true,
      rounds_waited_seconds: 0
    }'
  exit 8
}

post_codex_trigger() {
  # Check immediately before every author-attributed trigger write, including
  # an acknowledgement retry. Current-head clearance and idempotency return
  # before this function, preserving their existing behavior. The complete
  # paginated PR timeline is the only budget store; no local counter can make
  # concurrent checkouts or later invocations agree.
  # Parse this only at the new-write boundary. Disabled, cleared, and
  # idempotently-reused paths spend no request attempt and retain their
  # established behavior even if a later budget edit is malformed.
  local max_review_rounds request_comments request_count
  revalidate_request_freshness
  governing_request_attempt_cap
  max_review_rounds="$GOVERNING_REQUEST_ATTEMPT_CAP"
  request_comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "Codex request-attempt evidence") \
    || die 3 "cannot read Codex request-attempt evidence; refusing a new '@codex review' trigger"
  request_count=$(crqe_count_triggers "$request_comments" "$AUTHOR_IDENTITY" "$(failover_head_set "$request_comments")") \
    || die 3 "cannot count Codex request attempts; refusing a new '@codex review' trigger"
  # Below the ceiling, a new request is about to be written: the blocking
  # budget gates it. At the ceiling, the check runs only where a stop is about
  # to be reported (check_blocking_budget), never on the reuse branch, which
  # posts nothing and only polls the existing final request (#1560 canary).
  if [ "$request_count" -lt "$max_review_rounds" ] && [ "$TRIGGER_POSTED" != "true" ]; then
    # The moving-head guard (#2166) runs only here, where a NEW trigger is
    # about to be written, and before any budget it could be counted against.
    # It runs after the request-cap branch below the ceiling only (#2253): at
    # the ceiling every path either polls the existing final request without
    # writing or stops with exit 7, and neither may be turned into an exit 8
    # "rerun later" by a young head. Every path that reaches the write below
    # passes through this branch, because the ceiling branch always returns
    # or exits.
    refuse_moving_head_unless_allowed
    check_blocking_budget "$request_count" "$max_review_rounds"
  fi
  if [ "$request_count" -ge "$max_review_rounds" ]; then
    # The initial request may consume the final slot. Its missing eyes
    # acknowledgement must suppress only the retry: the already-confirmed
    # request still deserves its ordinary bounded review poll. An initial
    # capped request has no such request to poll and remains fail-closed.
    if [ "$TRIGGER_POSTED" = "true" ]; then
      ACK_RETRY_REFUSED_BY_CAP=true
      log "Codex request-attempt cap reached for $REPO#$PR_NUMBER ($request_count/$max_review_rounds); suppressing acknowledgement retry and continuing normal review poll"
      return 1
    fi
    # Trigger-only callers can consume the last slot before a separate waiter
    # starts. Reuse only an unanswered fresh author trigger, and only at the
    # cap; normal re-request behavior after a finding remains unchanged.
    local pending_trigger
    pending_trigger=$(crqe_select_trigger "$request_comments" "$AUTHOR_IDENTITY" "$REACTION_THRESHOLD") \
      || die 3 "cannot select the final Codex request"
    if [ "$TRIGGER_ONLY" != true ] && [ "$pending_trigger" != null ]; then
      CAP_REUSED_TRIGGER=true
      REQUEST_BLOCK_TRIGGER_JSON=$pending_trigger
      TRIGGER_SIGNAL_THRESHOLD=$(printf '%s' "$pending_trigger" | jq -r '.created_at')
      local pending_block_reason
      pending_block_reason=$(current_blocked_reason "$INITIAL_SCAN") || die 3 "cannot order the final-request provider refusal"
      if ! has_post_trigger_signal "$INITIAL_SCAN" \
         && [ -z "$pending_block_reason" ]; then
        preserve_final_request_timeout "$request_comments" "$pending_trigger"
        CAP_REQUEST_COUNT=$request_count
        CAP_REQUEST_LIMIT=$max_review_rounds
        log "Codex request-attempt cap reached for $REPO#$PR_NUMBER ($request_count/$max_review_rounds); polling the existing final request without a new trigger"
        return 0
      fi
      CAP_REUSED_TRIGGER=false
    fi
    # Blocking before the ceiling: when both are spent, the blocking stop wins.
    check_blocking_budget "$request_count" "$max_review_rounds"
    log "Codex request-attempt cap reached for $REPO#$PR_NUMBER ($request_count/$max_review_rounds); refusing additional '@codex review' requests"
    emit_cap_exhausted request-ceiling "$request_count" "$max_review_rounds"
  fi

  # Accounting protects new review requests. An exhausted cap performs no
  # write and reports its distinct stop first; when a slot remains, no new
  # round may hide undispositioned feedback (#1000).
  run_feedback_accounting_gate

  # #2158: wrappers independently re-check the same canonical authorization
  # at the write boundary. This mode never posts, even when a context marker
  # was supplied by a caller other than this script.
  if [ "$AUTHORIZE_TRIGGER_WRITE" = true ]; then
    local expected="${MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD:-}" live
    [[ "$expected" =~ ^[0-9a-f]{40}$ && "$expected" = "$HEAD_SHA" ]] \
      || die 3 "canonical trigger authorization has a missing or stale expected head"
    live=$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .head.sha) \
      || die 3 "cannot fence the authorized trigger head"
    [ "$live" = "$expected" ] || die 3 "trigger head moved during authorization"
    # #1362: this pass runs inside the wrapper's per-PR claim. The canonical
    # requester names the request generation it decided to post against; a
    # request that landed since (a concurrent requester that won the claim,
    # or one typed in the web UI) refuses this one rather than adding a
    # second. An absent or unreadable generation fails closed.
    local observed="${MERGEPATH_CODEX_TRIGGER_OBSERVED_GENERATION:-}" current
    current=$(crqe_trigger_generation "$request_comments" "$AUTHOR_IDENTITY") \
      || die 3 "cannot read the Codex request generation for authorization"
    if ! jq -en --argjson observed "${observed:-null}" --argjson current "$current" \
         '($observed | type) == "array" and $observed == $current' >/dev/null 2>&1; then
      jq -n '{authorized:false,reason:"concurrent-request"}'
      die 3 "trigger not authorized: concurrent-request"
    fi
    jq -n --arg repo "$REPO" --argjson pr "$PR_NUMBER" --arg head "$HEAD_SHA" --arg author "$AUTHOR_IDENTITY" \
      '{authorized:true,repo:$repo,pr_number:$pr,head_sha:$head,author_identity:$author}'
    exit 0
  fi

  # The Codex GitHub App ONLY monitors '@codex review' comments authored
  # by the repo's AUTHOR/human identity (nathanjohnpayne). A trigger
  # posted by a reviewer/bot identity (nathanpayne-claude/-codex/-cursor)
  # is silently ignored: empirically a reviewer-posted trigger sat
  # unanswered to the full 600s timeout while an author-posted one drew a
  # Codex review in ~20s (PR #405). Post it through gh-as-author.sh,
  # which verifies an author token and runs the write with process-local
  # GH_TOKEN. This SUPERSEDES the #284 `identity-check --expect-reviewer`
  # guard, which fail-closed on the WRONG identity for this particular
  # write.
  # A new request names this run's mode for the wrapper's authorization
  # (#2582). An eyes-ack retry names none: the authorization then refuses it
  # as the existing trigger, and this run keeps polling the request it
  # confirmed without spending another (#2631).
  local caller_mode="$REQUEST_MODE"
  [ "$TRIGGER_POSTED" != true ] || caller_mode=""
  # The checkpoint belongs to a new deliberate request, and is recorded only
  # once that request has actually posted: a requester that loses the
  # trigger write records nothing, so concurrent requesters at the threshold
  # cannot each add one (#1362 serializes the write itself). A CodeRabbit
  # failover stands in for a lost review, not a deliberate round, so it
  # never records (and so never uses up) the checkpoint.
  local record_checkpoint=false
  if [ "$TRIGGER_POSTED" != true ] && [ "$FAILOVER" != true ]; then record_checkpoint=true; fi
  # #1362: the wrapper's claimed recount refuses this write if the request
  # generation it was decided against has changed. A new request is decided
  # on the pre-flight scan, so it names that scan's generation: a request
  # another caller posted after it, even one this run's later reads already
  # include, refuses this write. An acknowledgement retry names this read,
  # which holds the run's own confirmed trigger.
  local observed_generation
  if [ "$TRIGGER_POSTED" != true ]; then
    observed_generation=$(printf '%s' "$INITIAL_SCAN" | jq -c '.generation // null' 2>/dev/null) || observed_generation=null
    [ "$observed_generation" != null ] \
      || die 3 "cannot read the Codex request generation the request was decided on; refusing a new '@codex review' trigger"
  else
    observed_generation=$(crqe_trigger_generation "$request_comments" "$AUTHOR_IDENTITY") \
      || die 3 "cannot read the Codex request generation; refusing a new '@codex review' trigger"
  fi
  log "posting '@codex review' trigger comment (as author identity $AUTHOR_IDENTITY; request attempts $request_count/$max_review_rounds)"
  MERGEPATH_CODEX_TRIGGER_WRITE=1 MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD="$HEAD_SHA" \
    MERGEPATH_CODEX_TRIGGER_CALLER_MODE="$caller_mode" \
    MERGEPATH_CODEX_TRIGGER_OBSERVED_GENERATION="$observed_generation" \
    post_author_pr_comment "@codex review" "'@codex review' trigger comment" inline || return 1
  POST_OUTPUT="$AUTHOR_COMMENT_OUTPUT"
  TRIGGER_POSTED=true
  if [ "$record_checkpoint" = true ]; then
    record_request_checkpoint "$request_comments" "$request_count" "$max_review_rounds"
  fi

  # Capture the post time so the poll loop can ignore stale signals
  # that were already on HEAD before the trigger fired. Without this,
  # `has_signal "$INITIAL_SCAN"` would return true on the very first
  # iteration of the poll loop and the script would exit with the
  # stale review/verdict without waiting for Codex's actual response
  # to the new trigger. Codex caught this on swipewatch propagation
  # PR #33 round 2 — same shape as the round-1 has_cleared_signal
  # bug, just on the post-trigger side.
  #
  # Use GitHub's authoritative timestamp from the just-posted comment
  # (extracted from the URL gh returns) rather than local wall-clock.
  # Local wall-clock can be ahead of or behind GitHub by a few seconds
  # due to NTP skew, and the strict `>` comparison would misclassify
  # a real Codex response as pre-trigger. Falls back to local wall-
  # clock minus a 60-second buffer if the comment ID can't be
  # extracted (e.g., gh output format change). Codex caught the
  # wall-clock issue on nathanpaynedotcom propagation PR #180 round 4.
  TRIGGER_COMMENT_ID=$(printf '%s\n' "$POST_OUTPUT" | grep -oE 'issuecomment-[0-9]+' | head -1 | sed 's/issuecomment-//' || true)
  if [ -n "$TRIGGER_COMMENT_ID" ]; then
    # Keep the newest CONFIRMED trigger separately from the current ack target.
    # A retry whose wrapper output unexpectedly omits the id must not erase an
    # earlier concrete trigger, but timeout persistence later re-reads the full
    # timeline and refuses that older id if the unconfirmed retry did land.
    TERMINAL_TRIGGER_COMMENT_ID="$TRIGGER_COMMENT_ID"
    # #799: the wall-clock fallback immediately below was unreachable on a
    # failed read. The error body is non-empty, so `[ -z ]` passed and a JSON
    # blob became TRIGGER_POST_TIME — which is then compared as a STRING
    # against ISO-8601 comment timestamps, and `{"message":…` sorts above
    # every `2026-…`, so every Codex response would read as pre-trigger and
    # the poll would run to timeout. `--shape timestamp` is what makes the
    # fallback fire rather than merely making the blob emptier.
    TRIGGER_POST_TIME=$(gh_api_scalar --shape timestamp "trigger comment $TRIGGER_COMMENT_ID timestamp" \
      "repos/$REPO/issues/comments/$TRIGGER_COMMENT_ID" --jq '.created_at') || TRIGGER_POST_TIME=""
  fi
  if [ -z "$TRIGGER_POST_TIME" ]; then
    # Fallback: local wall-clock minus a 60-second buffer for
    # clock skew tolerance.
    EPOCH_NOW=$(date +%s)
    EPOCH_BUFFER=$((EPOCH_NOW - 60))
    if TRIGGER_POST_TIME=$(date -u -r "$EPOCH_BUFFER" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
      :
    else
      TRIGGER_POST_TIME=$(date -u -d "@$EPOCH_BUFFER" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || die 3 "could not compute fallback TRIGGER_POST_TIME")
    fi
  fi

  # Post-write readback (#737): a genuinely-posted trigger yields an
  # `issuecomment-<id>` reference in gh's output (TRIGGER_COMMENT_ID above).
  # If gh-as-author reported success but produced no identifiable comment, do
  # NOT let the caller treat Codex as requested on the strength of a post we
  # cannot confirm landed — surface it as a LOUD, unmissable warning. (A hard
  # write failure already exited 3 in the branches above; this catches the
  # rarer "success with nothing to show for it" case, e.g. a gh output-format
  # change.)
  if [ -n "$TRIGGER_COMMENT_ID" ]; then
    log "confirmed '@codex review' trigger posted as comment $TRIGGER_COMMENT_ID (post-write readback, #737)"
  else
    echo "[codex-review-request] WARNING: '@codex review' write returned success but yielded no comment id — cannot confirm the trigger landed; verify before treating Codex as requested (#737)" >&2
  fi

  # Terminal Codex signals should be accepted if they respond to any
  # trigger posted in this script run. Retries still update
  # TRIGGER_POST_TIME for eyes-ack polling, but must not advance the
  # terminal-signal threshold past a valid response to an earlier trigger.
  if [ -z "$TRIGGER_SIGNAL_THRESHOLD" ]; then
    TRIGGER_SIGNAL_THRESHOLD="$TRIGGER_POST_TIME"
  fi

  # The review timeout belongs to the latest trigger comment, not to
  # the first missing-ack attempt. Without this reset, an unacknowledged
  # trigger can consume part of the retry's normal review window.
  reset_review_wait_clock
}

trigger_ack_present() {
  local reactions

  [ -n "$TRIGGER_COMMENT_ID" ] || return 1
  reactions=$(fetch_api_array "repos/$REPO/issues/comments/$TRIGGER_COMMENT_ID/reactions" "trigger comment reactions")
  [ "$(crqe_ack_present "$reactions" "$BOT_LOGIN" "$TRIGGER_POST_TIME")" = true ]
}

wait_for_trigger_ack() {
  local ack_start ack_deadline now remaining sleep_for

  if [ -z "$TRIGGER_COMMENT_ID" ]; then
    log "trigger comment id unavailable — skipping eyes-ack check and continuing normal poll"
    return 0
  fi

  ack_start=$(date +%s)
  ack_deadline=$((ack_start + ACK_WAIT_SECONDS))

  while :; do
    if trigger_ack_present; then
      log "Codex eyes acknowledgment received on trigger comment $TRIGGER_COMMENT_ID"
      return 0
    fi

    # If a terminal Codex signal arrives before the eyes reaction is
    # observable via REST, do not re-trigger. The terminal signal wins;
    # eyes is only an acknowledgment, never a clearance signal.
    rescan_codex_state "eyes-ack Codex scan"
    # An account-/connection-level block during the ack window is terminal
    # too (#722): re-posting `@codex review` cannot help a quota-exhausted or
    # not-connected account, so stop the ack gate (no re-trigger) and let the
    # poll loop short-circuit on the marker FINAL_SCAN already carries.
    local ack_block_reason
    ack_block_reason=$(current_blocked_reason "$FINAL_SCAN") || die 3 "cannot order the eyes-ack provider refusal"
    if [ -n "$ack_block_reason" ]; then
      log "Codex reported '$ack_block_reason' during eyes-ack wait — no re-trigger (a human must resolve it); handing to the poll loop to short-circuit (#722)"
      return 0
    fi
    if has_post_trigger_signal "$FINAL_SCAN"; then
      log "Codex terminal signal arrived during eyes-ack wait — no re-trigger needed"
      return 0
    fi

    now=$(date +%s)
    if [ "$now" -ge "$ack_deadline" ] || [ "$now" -ge "$DEADLINE" ]; then
      log "no Codex eyes acknowledgment on trigger comment $TRIGGER_COMMENT_ID within ${ACK_WAIT_SECONDS}s"
      return 1
    fi

    remaining=$((ack_deadline - now))
    sleep_for=$ACK_POLL_INTERVAL_SECONDS
    if [ "$remaining" -lt "$sleep_for" ]; then
      sleep_for=$remaining
    fi
    sleep "$sleep_for"
    ELAPSED=$(( $(date +%s) - START_TS ))
  done
}

run_trigger_ack_gate() {
  local retries_used=0

  [ "$TRIGGER_POSTED" = "true" ] || return 0
  if [ -z "$TRIGGER_COMMENT_ID" ]; then
    log "trigger comment id unavailable — skipping eyes-ack gate and continuing normal poll"
    return 0
  fi

  while :; do
    if wait_for_trigger_ack; then
      return 0
    fi

    if [ "$retries_used" -ge "$MAX_ACK_RETRIES" ]; then
      log "eyes-ack retry cap reached (${retries_used}/${MAX_ACK_RETRIES}) — continuing normal review poll"
      return 0
    fi

    retries_used=$((retries_used + 1))
    log "re-posting '@codex review' because Codex did not acknowledge the trigger (${retries_used}/${MAX_ACK_RETRIES})"
    if ! post_codex_trigger; then
      if [ "$ACK_RETRY_REFUSED_BY_CAP" = "true" ] || [ "$ACK_RETRY_REFUSED_BY_EXISTING" = true ]; then
        return 0
      fi
      die 3 "acknowledgement retry did not post a Codex trigger"
    fi
  done
}

# Persist a normal Phase 4a timeout for the exact head whose confirmed trigger
# exhausted the bounded wait (#1085). Phase 4b runs later, often from another
# checkout and process, so stdout/exit 4 is not a handoff channel. The PR
# timeline is. Account/connection blocks deliberately do NOT use this marker:
# this helper exits 4 with blocked_reason, while the later
# codex-review-check.sh --diagnostic-signal-only probe maps their
# provider-authored comments to its distinct Phase 4b exit-2 waiver.
record_phase4a_timeout_determination() {
  local live_head comments state marker_body post_id fresh_state

  [ "$CODEX_FAILURE_MARKERS_OK" = true ] \
    && command -v codex_phase4a_timeout_marker_body >/dev/null 2>&1 \
    && command -v codex_phase4a_timeout_marker_state >/dev/null 2>&1 \
    || die 3 "cannot persist Phase 4a timeout: shared terminal-marker helper unavailable"
  # #2664: the request is this run's own confirmed trigger, or the same-head
  # request it resumed and waited out to that request's own deadline.
  [ "$TRIGGER_POSTED" = true ] || [ "$RESUMED_TRIGGER" = true ] \
    || die 3 "cannot persist Phase 4a timeout: this run neither posted nor resumed a request"
  codex_phase4a_comment_id_ok "$TERMINAL_TRIGGER_COMMENT_ID" \
    || die 3 "cannot persist Phase 4a timeout: trigger comment id was not confirmed"

  # A timeout determined for H must never become a waiver on H2. Re-read the
  # live PR immediately before the write; the eventual Phase 4b reader repeats
  # the same fence before consuming the marker.
  live_head=$(gh_api_scalar --shape sha "Phase 4a timeout live PR head" \
    "repos/$REPO/pulls/$PR_NUMBER" --jq '.head.sha') \
    || die 3 "cannot persist Phase 4a timeout: live PR head is unreadable"
  [ "$live_head" = "$HEAD_SHA" ] \
    || die 3 "cannot persist Phase 4a timeout: PR head moved from $HEAD_SHA to $live_head"

  comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "Phase 4a timeout comments") \
    || die 3 "cannot persist Phase 4a timeout: issue comments are unreadable"
  state=$(codex_phase4a_timeout_marker_state "$HEAD_SHA" "$AUTHOR_IDENTITY" "$comments")
  case "$(printf '%s' "$state" | jq -r '.state // "malformed"')" in
    current)
      PHASE4A_TERMINAL_COMMENT_ID=$(printf '%s' "$state" | jq -r '.marker_id // empty')
      codex_phase4a_comment_id_ok "$PHASE4A_TERMINAL_COMMENT_ID" \
        || die 3 "existing Phase 4a timeout marker has no valid comment id"
      PHASE4A_TERMINAL_RECORDED=true
      log "Phase 4a timeout already recorded for $HEAD_SHA as comment $PHASE4A_TERMINAL_COMMENT_ID (idempotent)"
      return 0
      ;;
    malformed)
      die 3 "cannot persist Phase 4a timeout: trusted terminal-marker evidence is malformed"
      ;;
    none|stale|superseded) ;;
    *) die 3 "cannot persist Phase 4a timeout: terminal-marker state is unreadable" ;;
  esac

  # The marker is bound to an actual author-owned trigger. This is stronger
  # than trusting a hand-authored assertion that a timeout happened, and keeps
  # "no request" distinct from "requested and timed out".
  command -v codex_phase4a_trigger_comment_is_latest >/dev/null 2>&1 \
    || die 3 "cannot persist Phase 4a timeout: latest-trigger verifier unavailable"
  codex_phase4a_trigger_comment_is_latest "$AUTHOR_IDENTITY" "$TERMINAL_TRIGGER_COMMENT_ID" "$comments" \
    || die 3 "cannot persist Phase 4a timeout: confirmed trigger is absent, malformed, or superseded in the live author-owned timeline"
  marker_body=$(codex_phase4a_timeout_marker_body "$HEAD_SHA" "$TERMINAL_TRIGGER_COMMENT_ID") \
    || die 3 "cannot build Phase 4a timeout marker for head $HEAD_SHA"

  log "recording ordinary Phase 4a timeout for $HEAD_SHA on the PR timeline (#1085)"
  post_author_pr_comment "$marker_body" "Phase 4a timeout determination"
  post_id=$(printf '%s' "$AUTHOR_COMMENT_OUTPUT" | grep -oE 'issuecomment-[0-9]+' | head -1 | sed 's/issuecomment-//' || true)
  codex_phase4a_comment_id_ok "$post_id" \
    || die 3 "Phase 4a timeout marker write returned success but yielded no comment id"

  # Mandatory readback: a zero write status is not proof that the intended
  # author/body landed. Re-read the paginated timeline and run the SAME parser
  # Phase 4b will use, then also require this exact new comment object.
  comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "Phase 4a timeout marker readback") \
    || die 3 "Phase 4a timeout marker posted but readback failed"
  fresh_state=$(codex_phase4a_timeout_marker_state "$HEAD_SHA" "$AUTHOR_IDENTITY" "$comments")
  [ "$(printf '%s' "$fresh_state" | jq -r '.state // "malformed"')" = current ] \
    || die 3 "Phase 4a timeout marker posted but shared-parser readback did not validate it"
  printf '%s' "$comments" | jq -e --argjson id "$post_id" --arg who "$AUTHOR_IDENTITY" --arg body "$marker_body" '
    any(.[]?; (.id == $id) and ((.user.login // "") == $who) and ((.body // "") == $body))
  ' >/dev/null 2>&1 \
    || die 3 "Phase 4a timeout marker posted but exact comment readback did not match"

  PHASE4A_TERMINAL_RECORDED=true
  PHASE4A_TERMINAL_COMMENT_ID="$post_id"
  log "confirmed Phase 4a timeout marker comment $post_id for $HEAD_SHA"
}

# #2553: the heads a failover marker may name, read only when one is present.
# An unreadable read prints [], so every trigger counts. The force-push heads
# come from GraphQL (#2591); if that read fails, only they are left out.
failover_head_set() { # <comments-json>
  local commits timeline forced
  if ! crqe_failover_markers_present "$1" "$AUTHOR_IDENTITY"; then printf '[]'; return 0; fi
  forced=$(crqe_force_push_heads "$REPO" "$PR_NUMBER" 2>/dev/null) || forced='[]'
  if commits=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/commits" "PR commits for failover markers" 2>/dev/null) \
     && timeline=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/timeline" "PR timeline for failover markers" 2>/dev/null) \
     && crqe_pr_head_set "$commits" "$timeline" "$HEAD_SHA" "$forced"; then
    return 0
  fi
  log "failover markers: the PR's head set is unreadable; every trigger counts toward the request ceiling"
  printf '[]'
}

# #2534: record the trigger the CodeRabbit rate-limit failover just posted, so
# the request ceiling does not count it (crqe_failover_trigger_ids). Runs only
# for a trigger this run posted with a confirmed id. The marker is best effort:
# a failed write or readback leaves the trigger counted, which costs a slot
# and never the ceiling, so it is reported, not fatal. Prints the outcome.
record_failover_marker() {
  local body comments
  if [ "$TRIGGER_POSTED" != true ] || [[ ! "$TERMINAL_TRIGGER_COMMENT_ID" =~ ^[1-9][0-9]*$ ]]; then
    printf 'not-posted'
    return 0
  fi
  if ! command -v crqe_failover_marker_body crqe_failover_trigger_ids crqe_pr_head_set >/dev/null 2>&1 \
     || ! body=$(crqe_failover_marker_body "$HEAD_SHA" "$TERMINAL_TRIGGER_COMMENT_ID"); then
    log "failover marker: helper unavailable or invalid input; the trigger counts toward the request ceiling"
    printf 'failed'
    return 0
  fi
  if ! ( MERGEPATH_CODEX_FAILOVER_MARKER_WRITE=1 post_author_pr_comment "$body" "Codex failover marker" ) >/dev/null; then
    log "failover marker: write failed; trigger $TERMINAL_TRIGGER_COMMENT_ID counts toward the request ceiling"
    printf 'failed'
    return 0
  fi
  # Readback through the same parser the ceiling uses.
  if comments=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "Codex failover marker readback" 2>/dev/null) \
     && crqe_failover_trigger_ids "$comments" "$AUTHOR_IDENTITY" "$(failover_head_set "$comments")" 2>/dev/null \
        | jq -e --argjson id "$TERMINAL_TRIGGER_COMMENT_ID" 'index($id) != null' >/dev/null 2>&1; then
    log "failover marker: trigger $TERMINAL_TRIGGER_COMMENT_ID is exempt from the request ceiling"
    printf 'recorded'
  else
    log "failover marker: posted, but readback did not validate it; trigger $TERMINAL_TRIGGER_COMMENT_ID counts toward the request ceiling"
    printf 'failed'
  fi
}

# Run a read, retrying transient failures (#1550), and store its output in
# <out-var> in the caller's shell, so call it directly, never inside $( ).
# Status 4 from the read means a transient failure; anything else non-zero is
# permanent and fails closed at once. A transient failure that outlasts the
# retries fails closed too: an unreadable answer is never treated as an empty
# one.
read_with_transient_retry() { # <what> <out-var> <command> [args...]
  local what=$1 out_var=$2 attempt=1 rc out
  shift 2
  while :; do
    rc=0
    out=$("$@") || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf -v "$out_var" '%s' "$out"
      return 0
    fi
    [ "$rc" -eq 4 ] || die 3 "$what failed"
    if [ "$attempt" -ge "$SCAN_RETRY_ATTEMPTS" ]; then
      die 3 "$what failed: transient GitHub read failure persisted across $attempt attempt(s)"
    fi
    log "$what hit a transient GitHub read failure (attempt $attempt/$SCAN_RETRY_ATTEMPTS); retrying in ${SCAN_RETRY_BACKOFF_SECONDS}s (#1550)"
    sleep "$SCAN_RETRY_BACKOFF_SECONDS"
    attempt=$((attempt + 1))
  done
}

# Re-scan after a trigger (#1550); sets FINAL_SCAN.
rescan_codex_state() { # <what>
  read_with_transient_retry "$1" FINAL_SCAN scan_codex_state
}

# Resume an in-flight request instead of re-posting it (#1550). A rerun after
# a crashed or interrupted poll used to post a second trigger while Codex was
# still working on the first, restarting Codex's clock and spending another
# request attempt.
#
# A trigger comment names no commit (see scripts/lib/codex-request-evidence.sh),
# so its freshness alone cannot prove it asked for a review of THIS head. The
# proof comes from the provider: Codex's Review Summary must report a Code
# Review Running on the current HEAD, updated at or after the pending trigger.
# That shows a review of this head is in flight since the request; it still
# cannot say which request started it, and nothing here needs it to. Without
# that evidence the caller posts a new trigger exactly as before, so an
# unproven case costs a request, never a missed review. Evidence that cannot
# be READ is not evidence of absence: the comments read retries transient
# failures and then fails closed (exit 3), and a malformed selector result or
# trusted timeout marker fails closed too, rather than posting a duplicate
# into a review that may be running.
#
# The resumed wait ends at the pending trigger's own deadline (its created_at
# plus review_timeout_seconds), so resuming never extends a request's wait.
# A resumed request grants no timeout authority: if it expires unanswered, the
# caller posts a new trigger, and only that trigger can mint a timeout marker.
# #2664: a push time for HEAD that the author cannot set, or empty. The
# earliest pull_request or push workflow run for HEAD on the PR branch was
# created just after HEAD reached the branch, so a request after it was
# posted on this head. The earliest is used because a later pull_request run
# can come from another activity (review_requested, labeled, reopened) on the
# unchanged head and would wrongly date it later (Codex P2 on #2779). A
# branch moved back to an earlier commit is a non-fast-forward update, so its
# force-push timeline event dates that push, and the later of the two wins.
# An unreadable list proves nothing.
head_push_proof_at() {
  local forced="" dispatched="" runs
  # Read directly, not through ANCHOR_SOURCE: that picks the force-push only
  # when it is later than the committer date, so a future-dated commit would
  # hide it (#2779 Phase 4b advisory).
  forced=$(crqe_latest_head_transition "${TIMELINE_JSON:-[]}" 2>/dev/null) || forced=""
  runs=$(gh api --paginate -X GET "repos/$REPO/actions/runs" \
    -f head_sha="$HEAD_SHA" -F per_page=100 2>/dev/null) || runs=""
  dispatched=$(printf '%s' "$runs" | jq -r -s --arg b "$HEAD_REF" '
    if length > 0 and all(.[]; type == "object" and ((.workflow_runs | type) == "array"))
    then [ .[].workflow_runs[]
           | select(.event == "pull_request" or .event == "push")
           | select($b == "" or (.head_branch // "") == $b)
           | (.created_at // empty)
           | select(type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) ] | min // ""
    else "" end' 2>/dev/null) || dispatched=""
  if [ -n "$forced" ] && { [ -z "$dispatched" ] || [[ "$forced" > "$dispatched" ]]; }; then
    printf '%s' "$forced"
  else
    printf '%s' "$dispatched"
  fi
}

resume_pending_codex_request() {
  [ -n "$AUTHOR_IDENTITY" ] || return 1
  local comments="" pending created created_epoch summary status observed now deadline
  read_with_transient_retry "resume-check issue comments read" comments \
    fetch_scan_array "repos/$REPO/issues/$PR_NUMBER/comments" "issue comments (resume check)"
  revalidate_request_freshness
  # The latest exact author request, with no freshness anchor. Neither anchor
  # proves head attribution: the reaction-freshness floor may be shorter than
  # the reply deadline, and HEAD_PUSHED_AT falls back to the author-controlled
  # committer date, which a future date would push past every current request.
  # Staleness is bounded by the request's own deadline below, and the
  # exact-head Running summary is what ties the request to this head.
  pending=$(crqe_select_trigger "$comments" "$AUTHOR_IDENTITY" "") \
    || die 3 "cannot select the pending Codex request for the resume check"
  [ -n "$pending" ] && [ "$pending" != null ] || return 1
  created=$(printf '%s' "$pending" | jq -r '.created_at // ""') \
    || die 3 "cannot read the pending Codex request's timestamp"
  created_epoch=$(jq -rn --arg t "$created" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null) \
    || die 3 "cannot parse the pending Codex request's timestamp '$created'"
  [[ "$created_epoch" =~ ^[0-9]+$ ]] || die 3 "cannot parse the pending Codex request's timestamp '$created'"

  # #2664: only a request tied to the current head can hold it, and neither
  # the committer date nor a workflow run proves that tie (#2779 Phase 4b). It
  # holds on a strong tie: it was posted strictly after the PR's latest
  # force-push, and that force-push put HEAD in place
  # (crqe_head_force_push_tie_at). It also holds on the exact-head Running
  # summary since the request (#1550), but only while it is within its own
  # wait. Otherwise a new counted request posts, as before #2664: an
  # unprovable tie costs a slot, never a deadlock or a waiver.
  local tie_at tie_epoch
  RESUME_STRONG_TIE=false
  # Unreadable evidence is not absent evidence: a failed read is retried once
  # and then exits 3, rather than posting beside a request that may be
  # strongly tied and still running (CodeRabbit on #2779).
  if ! tie_at=$(crqe_head_force_push_tie_at "$REPO" "$PR_NUMBER" "$HEAD_SHA" 2>/dev/null); then
    sleep 2
    tie_at=$(crqe_head_force_push_tie_at "$REPO" "$PR_NUMBER" "$HEAD_SHA" 2>/dev/null) \
      || die 3 "cannot read the PR's force-push timeline for the same-head hold"
  fi
  tie_epoch=$(jq -rn --arg t "$tie_at" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null) || tie_epoch=""
  if [[ "$tie_epoch" =~ ^[0-9]+$ ]] && [ "$created_epoch" -gt "$tie_epoch" ]; then
    RESUME_STRONG_TIE=true
  fi
  # The timeout handoff binds only the exact lowercase command
  # (codex_phase4a_trigger_comment_is_latest), so a case-varied request could
  # be held but never handed off. It is not held; a new request posts.
  if ! printf '%s' "$pending" | jq -e '(.body // "") == "@codex review"' >/dev/null 2>&1; then
    log "pending request $(printf '%s' "$pending" | jq -r .id) is not the exact lowercase command the timeout handoff binds — not resuming"
    return 1
  fi
  # At the request ceiling the #813 cap path keeps precedence: it polls the
  # final request without timeout authority and reports the ceiling. This is
  # a no-spend path, so a cap that cannot be read only skips the check
  # (#1567); the write boundary still validates the cap before any post.
  if [ "$AUTHORIZE_TRIGGER_WRITE" != true ]; then
    local cap_limit cap_count
    cap_limit=$( { governing_request_attempt_cap && printf '%s' "$GOVERNING_REQUEST_ATTEMPT_CAP"; } 2>/dev/null ) || cap_limit=""
    cap_count=$(crqe_count_triggers "$comments" "$AUTHOR_IDENTITY" "$(failover_head_set "$comments")" 2>/dev/null) || cap_count=""
    if [[ "$cap_limit" =~ ^[0-9]+$ ]] && [[ "$cap_count" =~ ^[0-9]+$ ]] && [ "$cap_count" -ge "$cap_limit" ]; then
      return 1
    fi
  fi

  # Answered or provider-blocked since the pending trigger: a new round needs
  # a new request, so do not resume.
  TRIGGER_SIGNAL_THRESHOLD=$created
  RESUMED_TRIGGER=true
  REQUEST_BLOCK_TRIGGER_JSON=$pending
  local resume_block_reason
  resume_block_reason=$(current_blocked_reason "$INITIAL_SCAN") || die 3 "cannot order the pending-request provider refusal"
  if has_post_trigger_signal "$INITIAL_SCAN" \
     || [ -n "$resume_block_reason" ]; then
    TRIGGER_SIGNAL_THRESHOLD=""
    RESUMED_TRIGGER=false
    return 1
  fi
  RESUMED_TRIGGER=false
  TRIGGER_SIGNAL_THRESHOLD=""

  # A request that already minted a Phase 4a timeout determination (for
  # example at a shorter review_timeout_seconds) is settled: Phase 4b may have
  # consumed that waiver. Resuming it would reopen a closed attempt, so it is
  # not resumable. Malformed trusted marker evidence fails closed, as it does
  # in preserve_final_request_timeout. Only a missing marker helper (a partial
  # install) skips resuming, which is the pre-#1550 behaviour.
  # A `current` marker settles only the request it is bound to: the marker
  # parser recognizes exact lowercase commands while the request selector also
  # recognizes case variants, so a newer selected command can postdate a marker
  # the parser still calls current. Compare the bound trigger id, exactly as
  # preserve_final_request_timeout does.
  local marker_json marker_state
  if [ "$CODEX_FAILURE_MARKERS_OK" != true ] \
     || ! command -v codex_phase4a_timeout_marker_state >/dev/null 2>&1; then
    log "terminal-marker helper unavailable — not resuming (#1550)"
    return 1
  fi
  marker_json=$(codex_phase4a_timeout_marker_state "$HEAD_SHA" "$AUTHOR_IDENTITY" "$comments" 2>/dev/null) \
    || marker_json='{}'
  marker_state=$(printf '%s' "$marker_json" | jq -r '.state // "malformed"' 2>/dev/null) || marker_state=malformed
  case "$marker_state" in
    none|stale|superseded) ;;
    current)
      if printf '%s' "$marker_json" | jq -e --argjson trigger "$pending" \
           '.trigger_comment_id == $trigger.id' >/dev/null 2>&1; then
        # #2664: its timeout is recorded and handed to Phase 4b, so it is not
        # in flight. A later run on this head is a new round: it posts a new
        # counted request, which supersedes that determination (#1085).
        log "pending request $(printf '%s' "$pending" | jq -r .id) has a current Phase 4a timeout marker — not resuming"
        return 1
      fi
      ;;
    *) die 3 "cannot classify the pending Codex request for resume: trusted terminal-marker evidence is malformed" ;;
  esac

  summary=$(crqe_select_codex_review_summary "$comments" "$BOT_LOGIN" "$HEAD_SHA") \
    || die 3 "cannot read the Codex Review Summary for the resume check"
  status=$(printf '%s' "$summary" | jq -r 'if . == null then "" else .status end') \
    || die 3 "cannot read the Codex Review Summary for the resume check"
  observed=$(printf '%s' "$summary" | jq -r 'if . == null then "" else .observed_at end') \
    || die 3 "cannot read the Codex Review Summary for the resume check"
  # #2664: a Running summary no longer gates the resume. An unanswered
  # request on this head is uncertain whatever the row says (the row names
  # no request), and posting another would treat it as never sent. It only
  # chooses the reason the wrapper's authorization reports.
  RESUME_PENDING_RUNNING=false
  if [ "$status" = running ] && [ -n "$observed" ] && ! [[ "$observed" < "$created" ]]; then
    RESUME_PENDING_RUNNING=true
  fi
  now=$(date +%s)
  deadline=$((created_epoch + TIMEOUT_SECONDS))
  if [ "$RESUME_STRONG_TIE" != true ]; then
    if [ "$RESUME_PENDING_RUNNING" != true ]; then
      log "pending request $(printf '%s' "$pending" | jq -r .id) has no strong tie to the current head and no Running summary — not resuming; a new counted request posts"
      return 1
    fi
    if [ "$now" -ge "$deadline" ]; then
      log "pending request $(printf '%s' "$pending" | jq -r .id) is tied only by a Running summary and is past its wait — not resuming; a new counted request posts"
      return 1
    fi
  fi
  RESUME_PENDING_STATE=pending
  if [ "$now" -ge "$deadline" ]; then
    # Past its own wait: the wait below ends at once, and the request's
    # timeout determination is recorded as for any expired request.
    RESUME_PENDING_STATE=expired
    deadline=$now
  fi

  RESUMED_TRIGGER=true
  RESUMED_EVER=true
  RESUMED_TRIGGER_ID=$(printf '%s' "$pending" | jq -r .id)
  # The timeout writer binds its determination to this request.
  TERMINAL_TRIGGER_COMMENT_ID=$RESUMED_TRIGGER_ID
  REQUEST_BLOCK_TRIGGER_JSON=$pending
  TRIGGER_SIGNAL_THRESHOLD=$created
  START_TS=$created_epoch
  DEADLINE=$deadline
  ELAPSED=$((now - created_epoch))
  [ "$ELAPSED" -ge 0 ] || ELAPSED=0
  return 0
}

# --- pre-flight: is Codex already working on HEAD? --------------------------

# #2664: read once per run, before any scan; scans run in subshells.
HEAD_PUSH_PROOF=$(head_push_proof_at)

log "checking for existing Codex signal on HEAD"
if ! INITIAL_SCAN=$(scan_codex_state); then
  die 3 "initial Codex scan failed"
fi

reset_review_wait_clock
TRIGGER_POSTED=false
TRIGGER_COMMENT_ID=""
TERMINAL_TRIGGER_COMMENT_ID=""
TRIGGER_POST_TIME=""
TRIGGER_SIGNAL_THRESHOLD=""
ACK_RETRY_REFUSED_BY_CAP=false
ACK_RETRY_REFUSED_BY_EXISTING=false
CAP_REUSED_TRIGGER=false
CAP_REQUEST_COUNT=0
CAP_REQUEST_LIMIT=0
GOVERNING_POLICY_FINGERPRINT=""
BLOCKING_REVIEW_COUNT=""
BLOCKING_REVIEW_LIMIT=""
RESUMED_TRIGGER=false
# A run re-executed after a resumed request expired (#1550) reports that the
# invocation resumed first, although this process posts normally.
RESUMED_EVER=false
RESUME_PENDING_RUNNING=false
RESUME_STRONG_TIE=false
RESUME_PENDING_STATE=""
# #2664 reporting of the waited-on request's run (see codex_run_tick).
CODEX_RUN_DIAGNOSTIC_JSON=null
CODEX_RUN_WINDOW_JSON=null
CODEX_RUN_FINAL_STATE=""
CODEX_RUN_OVERLAP=false
RESUMED_TRIGGER_ID=""
REQUEST_BLOCK_TRIGGER_JSON=null

# The no-write decisions below belong to a request mode. A requester applies
# its own. The wrapper's authorization pass runs as --trigger-only, so it
# applies the mode the canonical requester names in
# MERGEPATH_CODEX_TRIGGER_CALLER_MODE (#2582). Polling mode posts a new request
# while an earlier trigger is on HEAD by design (a pending request with no
# provider evidence, the replacement for a resumed request that expired), so
# authorizing that write must not refuse it as a #489 duplicate. Without the
# variable, the stricter trigger-only decisions apply; the eyes-ack retry
# relies on that refusal to keep polling without spending a request.
REQUEST_MODE=poll
[ "$TRIGGER_ONLY" != true ] || REQUEST_MODE="trigger-only"
if [ "$AUTHORIZE_TRIGGER_WRITE" = true ]; then
  case "${MERGEPATH_CODEX_TRIGGER_CALLER_MODE:-trigger-only}" in
    poll|trigger-only) REQUEST_MODE=${MERGEPATH_CODEX_TRIGGER_CALLER_MODE:-trigger-only} ;;
    *) die 3 "canonical trigger authorization names an unknown caller mode" ;;
  esac
fi

NO_WRITE_REASON=""
if has_cleared_signal "$INITIAL_SCAN"; then
  NO_WRITE_REASON="already-cleared"
  log "Codex has already cleared on HEAD (no-blocking-tier review or affirmative verdict comment) — skipping trigger comment"
elif [ "$REQUEST_MODE" = trigger-only ] && existing_codex_trigger_on_head; then
  NO_WRITE_REASON="existing-trigger"
  log "trigger-only: @codex review already requested on HEAD — skipping duplicate trigger (idempotent, #489)"
elif [ "$REQUEST_MODE" = trigger-only ] && auto_trigger_content_free; then
  NO_WRITE_REASON="content-free-auto-trigger"
  log "auto-trigger: $AUTO_TRIGGER_SKIP_REASON — skipping the automatic @codex review (#798)"
elif [ "$REQUEST_MODE" = poll ] && resume_pending_codex_request; then
  if [ "$AUTHORIZE_TRIGGER_WRITE" = true ]; then
    if [ "$RESUME_PENDING_RUNNING" = true ]; then
      NO_WRITE_REASON="pending-request-running"
      log "pending request $RESUMED_TRIGGER_ID: Codex reports a review of HEAD Running since it was posted — a new trigger is not authorized (#1550)"
    else
      NO_WRITE_REASON="pending-request-unanswered"
      log "pending request $RESUMED_TRIGGER_ID on this head is unanswered ($RESUME_PENDING_STATE) — a new trigger is not authorized (#2664)"
    fi
  else
    case "$RESUME_PENDING_STATE" in
      pending) log "resuming pending request $RESUMED_TRIGGER_ID on this head (unanswered; Codex Running: $RESUME_PENDING_RUNNING); no new trigger (#1550, #2664), ${ELAPSED}s of ${TIMEOUT_SECONDS}s already elapsed" ;;
      expired) log "pending request $RESUMED_TRIGGER_ID on this head is unanswered past its ${TIMEOUT_SECONDS}s wait — handing it off, not posting a fresh request (#2664)" ;;
    esac
  fi
else
  post_codex_trigger
fi

# The wrapper's fresh scan must honor the same no-write decisions as the
# outer requester. Authorization never spends a request or posts a comment.
if [ "$AUTHORIZE_TRIGGER_WRITE" = true ]; then
  jq -n --arg reason "${NO_WRITE_REASON:-no-request-authorized}" \
    '{authorized:false,reason:$reason}'
  die 3 "trigger not authorized: ${NO_WRITE_REASON:-no-request-authorized}"
fi

# #489 trigger-only: return immediately after posting (or confirming) the
# trigger — BEFORE run_trigger_ack_gate, which would otherwise re-post
# @codex up to max_ack_retries (the eyes-ack retry) and break the
# one-trigger-per-run contract the rate-limit failover relies on. No clearance
# poll; Codex's actual review/clearance is picked up later by the normal Phase
# 4a flow and the merge-clearance gate. trigger_posted is false when the
# idempotency check skipped a duplicate, or when Codex had already cleared.
if [ "$TRIGGER_ONLY" = "true" ]; then
  failover_marker=null
  [ "$FAILOVER" != true ] || failover_marker=$(record_failover_marker | jq -Rc .)
  # Preserve a block already known before this trigger. Posting or deduping
  # a request does not make an unavailable provider usable (#2139).
  trigger_only_blocked_reason=""
  if ! has_cleared_signal "$INITIAL_SCAN"; then
    trigger_only_blocked_reason=$(printf '%s' "$INITIAL_SCAN" | jq -r \
      --arg after "$REACTION_THRESHOLD" --arg floor "$REACTION_FLOOR_ISO" --argjson now "$EPOCH_NOW" '
      # A future author-controlled committer date cannot hide a recent block.
      (if ($after | fromdateiso8601) > $now then $floor else $after end) as $block_after
      | if .blocked != null and (.blocked.created_at // "") >= $block_after
      then .blocked.reason else "" end')
  fi
  jq -n \
    --argjson pr_number "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg head_sha "$HEAD_SHA" \
    --arg head_committer_date "$HEAD_COMMITTER_DATE" \
    --arg bot_login "$BOT_LOGIN" \
    --argjson trigger_posted "$TRIGGER_POSTED" \
    --argjson failover_marker "$failover_marker" \
    --argjson request_checkpoint "$REQUEST_CHECKPOINT_JSON" \
    --arg blocked_reason "$trigger_only_blocked_reason" '
    {
      pr_number: $pr_number,
      repo: $repo,
      head_sha: $head_sha,
      head_committer_date: $head_committer_date,
      bot_login: $bot_login,
      review: null,
      findings: [],
      reaction: null,
      verdict: null,
      blocked_reason: (if $blocked_reason == "" then null else $blocked_reason end),
      terminal_determination: null,
      trigger_posted: $trigger_posted,
      trigger_requested: true,
      trigger_only: true,
      failover_marker: $failover_marker,
      request_checkpoint: $request_checkpoint,
      rounds_waited_seconds: 0
    }'
  exit 0
fi

if [ "$TRIGGER_POSTED" = "true" ]; then
  # We just posted a trigger. The INITIAL_SCAN data is now stale by
  # definition — Codex will respond with something new. Skip the
  # initial has_signal check; force the loop to actually poll.
  FINAL_SCAN='{"review":null,"findings":[],"reaction":null,"verdict":null,"blocked":null}'
  run_trigger_ack_gate
else
  FINAL_SCAN=$INITIAL_SCAN
fi

# #2664: report what Codex's Review Summary row says about the waited-on
# request, with no automatic retry. Codex publishes nothing that ties a
# terminal state to one request: the row names no request and can be updated
# by any run on this head, and the eyes reaction shows only while a run is
# live. So a "failed" row can belong to another run, and no retry is posted on
# it. At 300 s the state is recorded as a diagnostic; at the end of the wait
# it is reported, and an unanswered request takes the ordinary timeout
# handoff to Phase 4b, which clears nothing and cancels nothing. A window the
# provider states is reported as a not-before time; a restated window moves
# it when its deadline is later, whatever its duration.
CODEX_RUN_DIAGNOSTIC_SECONDS=300
codex_run_state_now() { # the waited-on request's reported state
  local scan_request watched state
  watched=${TERMINAL_TRIGGER_COMMENT_ID:-${RESUMED_TRIGGER_ID:-}}
  scan_request=$(printf '%s' "$FINAL_SCAN" | jq -r '.request.id // empty' 2>/dev/null) || scan_request=""
  state=$(printf '%s' "$FINAL_SCAN" | jq -r '.run.state // "none"' 2>/dev/null) || state=unknown
  if [ -z "$watched" ] || [ "$scan_request" != "$watched" ]; then state=none; fi
  if [ "$(printf '%s' "$FINAL_SCAN" | jq -r '.run.overlapping_request // false' 2>/dev/null)" = true ]; then
    case "$state" in failed|canceled|completed|running) state=ambiguous ;; esac
  fi
  case "$state" in running) state=active ;; none) state=unknown ;; esac
  printf '%s' "$state"
}

codex_run_tick() {
  [ "$TRIGGER_POSTED" = true ] || [ "$RESUMED_TRIGGER" = true ] || return 0
  local state window observed not_before
  state=$(codex_run_state_now)
  # Set here, not in codex_run_state_now, which runs in a subshell. Once seen,
  # an overlap stays reported.
  if [ "$(printf '%s' "$FINAL_SCAN" | jq -r '.run.overlapping_request // false' 2>/dev/null)" = true ]; then
    CODEX_RUN_OVERLAP=true
  fi
  if [ "$CODEX_RUN_DIAGNOSTIC_JSON" = null ] && [ "$ELAPSED" -ge "$CODEX_RUN_DIAGNOSTIC_SECONDS" ]; then
    CODEX_RUN_DIAGNOSTIC_JSON=$(jq -nc --argjson at "$ELAPSED" --arg state "$state" '{after_seconds: $at, run_state: $state}')
    log "diagnostic (#2664): no Codex result after ${ELAPSED}s; the Review Summary reads '$state' for this request — reported only, no request is posted"
  fi
  window=$(printf '%s' "$FINAL_SCAN" | jq -r '.run.retry_after_seconds // empty' 2>/dev/null) || window=""
  observed=$(printf '%s' "$FINAL_SCAN" | jq -r '.run.observed_at // empty' 2>/dev/null) || observed=""
  if [[ "$window" =~ ^[0-9]+$ ]] && [ -n "$observed" ]; then
    not_before=$(jq -rn --arg t "$observed" --argjson w "$window" '($t | sub("\\.[0-9]+"; "") | fromdateiso8601) + $w | todateiso8601' 2>/dev/null) || not_before=""
    if [ -n "$not_before" ] && { [ "$CODEX_RUN_WINDOW_JSON" = null ] \
         || [[ "$not_before" > "$(printf '%s' "$CODEX_RUN_WINDOW_JSON" | jq -r .not_before)" ]]; }; then
      CODEX_RUN_WINDOW_JSON=$(jq -nc --argjson w "$window" --arg nb "$not_before" '{seconds: $w, not_before: $nb}')
      log "Codex states a retry window of ${window}s; not before $not_before (#2664, reported only)"
    fi
  fi
}

codex_run_json() {
  local watched=${TERMINAL_TRIGGER_COMMENT_ID:-${RESUMED_TRIGGER_ID:-}}
  jq -nc --arg id "$watched" --argjson diagnostic "$CODEX_RUN_DIAGNOSTIC_JSON" --arg final "$CODEX_RUN_FINAL_STATE" \
    --arg handoff "${CODEX_RUN_HANDOFF:-}" \
    --argjson overlap "$CODEX_RUN_OVERLAP" --argjson window "$CODEX_RUN_WINDOW_JSON" '
    { request_comment_id: (if $id == "" then null else ($id | tonumber? // null) end),
      diagnostic: $diagnostic,
      final_state: (if $final == "" then null else $final end),
      overlapping_request: $overlap,
      handoff: (if $handoff == "" then null else $handoff end),
      provider_window: $window }'
}

# --- poll loop --------------------------------------------------------------

run_review_poll() {
while :; do
  # If we just triggered a fresh review, or resumed one (#1550), only break on
  # a signal at or after that trigger. Otherwise (no trigger sent), any
  # existing signal is fine — that's the cleared-on-arrival path.
  if [ "$TRIGGER_POSTED" = "true" ] || [ "$CAP_REUSED_TRIGGER" = true ] \
     || [ "$RESUMED_TRIGGER" = true ]; then
    if has_post_trigger_signal "$FINAL_SCAN"; then
      log "Codex signal received after ${ELAPSED}s (post-trigger)"
      break
    fi
  elif has_signal "$FINAL_SCAN"; then
    log "Codex signal received after ${ELAPSED}s"
    break
  fi

  # Short-circuit on an account-/connection-level failure marker (#722).
  # A usage_limit or not_connected comment is terminal: no further polling
  # or re-triggering can produce a review until a human acts (upgrade / add
  # credits / connect the App), so break immediately instead of burning the
  # rest of the timeout. The exit-code logic below still exits 4
  # (FALLBACK_REQUIRED) because no real Codex signal arrived — but now with
  # blocked_reason in the JSON so the caller (and the Phase 4b handoff) can
  # name the real cause instead of a generic timeout.
  BLOCKED_REASON_NOW=$(current_blocked_reason "$FINAL_SCAN") || die 3 "cannot order the polled provider refusal"
  if [ -n "$BLOCKED_REASON_NOW" ]; then
    log "Codex reported '$BLOCKED_REASON_NOW' after ${ELAPSED}s — short-circuiting the wait; re-polling/re-triggering cannot clear it. The result preserves the invocation's existing routing authority (#722)"
    break
  fi

  # #2664: the 300 s diagnostic and the provider's stated window (reporting).
  codex_run_tick

  NOW=$(date +%s)
  if [ "$NOW" -ge "$DEADLINE" ]; then
    # Final scan at the deadline (#465): a Codex signal that arrived between
    # the last poll and now must not be emitted as a stale timeout. Refresh
    # FINAL_SCAN so BOTH the JSON emission and the exit-code decision below
    # reflect current state — if a signal landed, has_*_signal sees it and
    # the script exits 0 instead of 4 (FALLBACK_REQUIRED) on stale data.
    rescan_codex_state "final timeout-path scan"
    log "deadline reached after ${ELAPSED}s — emitted scan is the final one; exit code decided below"
    break
  fi

  log "polling... (${ELAPSED}s / ${TIMEOUT_SECONDS}s)"
  sleep "$POLL_INTERVAL_SECONDS"
  ELAPSED=$(( $(date +%s) - START_TS ))

  rescan_codex_state "poll scan"
done
}

run_review_poll

# #2664: a resumed request that expires unanswered is not replaced by a fresh
# request (the earlier #1550 re-run did that). Its timeout determination is
# recorded below like any expired request on this head, and Phase 4b takes
# over. A timeout grants no clearance and cancels nothing.

# A reused trigger grants no new timeout/fallback authority. If its bounded
# wait returns no response, report the cap with the final observations. Only
# this invocation's own confirmed trigger may mint a timeout determination.
if [ "$CAP_REUSED_TRIGGER" = true ] && ! has_post_trigger_signal "$FINAL_SCAN"; then
  INITIAL_SCAN=$FINAL_SCAN
  # The reuse branch skipped the blocking check; take it now, before the
  # ceiling stop is reported, so a spent blocking budget still names the stop.
  check_blocking_budget "$CAP_REQUEST_COUNT" "$CAP_REQUEST_LIMIT"
  emit_cap_exhausted request-ceiling "$CAP_REQUEST_COUNT" "$CAP_REQUEST_LIMIT"
fi

# --- emit final JSON --------------------------------------------------------

# Surface the account-/connection-level block (#722) on the final scan, using
# the same post-trigger anchoring as the poll short-circuit so a stale marker
# from a prior HEAD does not leak into this run's report. Empty ⇒ null.
BLOCKED_REASON=$(current_blocked_reason "$FINAL_SCAN") || die 3 "cannot order the final provider refusal"

# A plain timeout is a terminal Phase 4a determination, not ordinary pending.
# Persist it before emitting exit 4 so a later Phase 4b process can consume it.
# Provider-authored account/connection blocks keep blocked_reason here and must
# not create this marker; the later codex-review-check.sh
# --diagnostic-signal-only probe maps them to its Phase 4b exit-2 waiver.
PHASE4A_TERMINAL_RECORDED=false
PHASE4A_TERMINAL_COMMENT_ID=""
if [ "$TRIGGER_POSTED" = true ] || [ "$RESUMED_TRIGGER" = true ]; then
  if has_post_trigger_signal "$FINAL_SCAN"; then
    CODEX_RUN_FINAL_STATE=answered
  else
    codex_run_tick
    CODEX_RUN_FINAL_STATE=$(codex_run_state_now)
    log "request ${TERMINAL_TRIGGER_COMMENT_ID:-?} unanswered at the end of its ${TIMEOUT_SECONDS}s wait; the Review Summary reads '$CODEX_RUN_FINAL_STATE' — reported, not retried or cancelled (#2664)"
  fi
fi
# #2664: a timeout determination is minted only from a strong head tie:
# this run's own request, or a held request posted after the PR's latest
# force-push, when that force-push put HEAD in place
# (crqe_head_force_push_tie_at), strictly later. The hold's weaker tie (a
# Running summary) only keeps a rerun from posting beside the request while
# it is within its wait. It cannot tie an older head's request to this head
# well enough to hand this head to Phase 4b (#2779 Phase 4b P1s). Without a
# strong tie the run exits 4 with no marker and reports the request as
# unattributed, and a rerun posts a new counted request.
CODEX_RUN_HANDOFF=""
if { [ "$TRIGGER_POSTED" = true ] || [ "$RESUMED_TRIGGER" = true ]; } && [ -z "$BLOCKED_REASON" ] \
   && ! has_post_trigger_signal "$FINAL_SCAN"; then
  strong_tie=$TRIGGER_POSTED
  if [ "$strong_tie" != true ] && [ "$RESUMED_TRIGGER" = true ] && [ "$RESUME_STRONG_TIE" = true ]; then
    strong_tie=true
    log "held request ${TERMINAL_TRIGGER_COMMENT_ID:-?} was posted after the force-push that put HEAD in place — recording its timeout"
  fi
  if [ "$strong_tie" = true ]; then
    record_phase4a_timeout_determination
    CODEX_RUN_HANDOFF=timeout-recorded
  else
    CODEX_RUN_HANDOFF=unattributed
    log "held request ${TERMINAL_TRIGGER_COMMENT_ID:-?} is unanswered and tied only by a Running summary: unattributed; a rerun posts a new counted request. No timeout determination is recorded (#2664)"
  fi
fi

jq -n \
  --argjson pr_number "$PR_NUMBER" \
  --arg repo "$REPO" \
  --arg head_sha "$HEAD_SHA" \
  --arg head_committer_date "$HEAD_COMMITTER_DATE" \
  --arg bot_login "$BOT_LOGIN" \
  --argjson scan "$FINAL_SCAN" \
  --argjson trigger_posted "$TRIGGER_POSTED" \
  --argjson request_resumed "$RESUMED_EVER" \
  --arg blocked_reason "$BLOCKED_REASON" \
  --argjson terminal_recorded "$PHASE4A_TERMINAL_RECORDED" \
  --arg terminal_comment_id "$PHASE4A_TERMINAL_COMMENT_ID" \
  --argjson request_checkpoint "$REQUEST_CHECKPOINT_JSON" \
  --argjson codex_run "$(codex_run_json)" \
  --argjson elapsed "$ELAPSED" '
  {
    pr_number: $pr_number,
    repo: $repo,
    head_sha: $head_sha,
    head_committer_date: $head_committer_date,
    bot_login: $bot_login,
    review: $scan.review,
    findings: $scan.findings,
    reaction: $scan.reaction,
    verdict: $scan.verdict,
    blocked_reason: (if $blocked_reason == "" then null else $blocked_reason end),
    terminal_determination: (if $terminal_recorded then {
      provider: "codex",
      outcome: "timeout",
      marker_comment_id: ($terminal_comment_id | tonumber)
    } else null end),
    trigger_posted: $trigger_posted,
    request_resumed: $request_resumed,
    trigger_requested: true,
    request_checkpoint: $request_checkpoint,
    codex_run: $codex_run,
    rounds_waited_seconds: $elapsed
  }
'

# Exit 0 if a signal arrived; exit 4 (FALLBACK_REQUIRED) if we timed
# out. When TRIGGER_POSTED=true, "a signal arrived" means a signal
# at or after the first trigger in this run — existing pre-trigger
# signals do not count, otherwise the script would exit 0 with stale
# findings the moment we time out polling for the new review.
#
# A resumed request (#1550) is anchored the same way: only a response at or
# after the resumed trigger counts. Otherwise a resumed poll that breaks on a
# provider block would fall to has_signal and exit 0 on an older review the
# resumed request was asking Codex to reconsider.
if [ "$TRIGGER_POSTED" = "true" ] || [ "$RESUMED_TRIGGER" = "true" ]; then
  if has_post_trigger_signal "$FINAL_SCAN"; then
    exit 0
  else
    exit 4
  fi
elif has_signal "$FINAL_SCAN"; then
  exit 0
else
  exit 4
fi
