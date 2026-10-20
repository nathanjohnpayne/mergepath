#!/usr/bin/env bash
# scripts/workflow/resume-stalled-pr.sh — pick up the oldest stalled pull
# request and hand its next round to the calling agent session
# (nathanjohnpayne/mergepath#2165).
#
# This is the entry point a scheduled routine (or a human) runs to continue
# review rounds outside working hours. It runs the read-only finder
# (scripts/workflow/stalled-prs.sh), selects the stalled PR whose newest
# event is oldest, and prints a WORK ORDER: the PR, its head, why it is
# stalled, the next action, a non-destructive checkout, and the exact
# commands the review policy prescribes for that action. The calling agent
# session then performs the round — every write included (a fix push, the
# Codex request, thread resolution, the merge) — per AGENTS.md § Workflow
# Summary, through the repository's identity-verified wrappers.
#
# Read-only. This script performs no GitHub write of any kind: it never
# requests a review, comments, labels, pushes or merges. Keeping every write
# in the session keeps each one behind the session's own fresh reads and the
# wrappers' identity checks, instead of behind a snapshot taken minutes
# earlier.
#
# Usage:
#   scripts/workflow/resume-stalled-pr.sh [--repo owner/repo] [--threshold-minutes N]
#                                         [--pr N] [--json]
#                                         [--input FILE] [--now ISO8601]
#
#   --repo               Repository to inspect (default: current repo).
#   --threshold-minutes  Passed to the finder (default 60).
#   --pr N               Resume this PR instead of the oldest stalled one. It
#                        must still classify as stalled.
#   --json               Print the selected PR's finder record as JSON after
#                        the work order (machine-readable handoff).
#   --input FILE         Replay a finder snapshot instead of fetching one
#                        (regression suite; no network).
#   --now ISO8601        Passed to the finder (fixture runs).
#
# Exit codes:
#   0  a stalled PR was selected and its work order printed
#   1  nothing is stalled — nothing to resume
#   2  usage error
#   3  the finder could not read the repository

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FINDER="$ROOT/scripts/workflow/stalled-prs.sh"

REPO=""
THRESHOLD_MINUTES=60
PICK_PR=""
JSON_OUT=0
INPUT_FILE=""
NOW=""

usage() {
  echo "usage: resume-stalled-pr.sh [--repo owner/repo] [--threshold-minutes N] [--pr N] [--json] [--input FILE] [--now ISO8601]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --threshold-minutes) [ "$#" -ge 2 ] || usage; THRESHOLD_MINUTES="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; PICK_PR="$2"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    --input) [ "$#" -ge 2 ] || usage; INPUT_FILE="$2"; shift 2 ;;
    --now) [ "$#" -ge 2 ] || usage; NOW="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

case "$PICK_PR" in ''|*[!0-9]*) [ -z "$PICK_PR" ] || usage ;; esac
[ -x "$FINDER" ] || { echo "resume-stalled-pr: finder missing or not executable: $FINDER" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "resume-stalled-pr: jq is required" >&2; exit 3; }

finder_args=(--json --threshold-minutes "$THRESHOLD_MINUTES")
[ -z "$REPO" ] || finder_args+=(--repo "$REPO")
[ -z "$INPUT_FILE" ] || finder_args+=(--input "$INPUT_FILE")
[ -z "$NOW" ] || finder_args+=(--now "$NOW")

# The finder exits 1 when something is stalled — that is the signal this
# script exists to consume, not a failure. 3 (unreadable) is fatal here too.
set +e
REPORT=$("$FINDER" "${finder_args[@]}")
finder_rc=$?
set -e
case "$finder_rc" in
  0|1) ;;
  *) echo "resume-stalled-pr: finder exited $finder_rc; nothing selected" >&2; exit 3 ;;
esac

REPO=$(printf '%s' "$REPORT" | jq -r '.repo')

if [ -n "$PICK_PR" ]; then
  SELECTED=$(printf '%s' "$REPORT" | jq -c --argjson n "$PICK_PR" '[.prs[] | select(.number == $n and .class == "stalled")][0] // null')
else
  # The report is already sorted stalled-first, oldest newest-event first.
  SELECTED=$(printf '%s' "$REPORT" | jq -c '[.prs[] | select(.class == "stalled")][0] // null')
fi

if [ "$SELECTED" = "null" ]; then
  if [ -n "$PICK_PR" ]; then
    echo "resume-stalled-pr: $REPO#$PICK_PR is not stalled (or not open); nothing to resume" >&2
  else
    echo "resume-stalled-pr: no stalled PR in $REPO (threshold ${THRESHOLD_MINUTES}m); nothing to resume" >&2
  fi
  exit 1
fi

number=$(printf '%s' "$SELECTED" | jq -r '.number')
head_sha=$(printf '%s' "$SELECTED" | jq -r '.head_sha')
head_ref=$(printf '%s' "$SELECTED" | jq -r '.head_ref')
# The title is PR-controlled display text: strip control characters (newlines
# included) so it cannot add lines to the work order a session consumes.
title=$(printf '%s' "$SELECTED" | jq -r '.title | gsub("[\\x00-\\x1f\\x7f]"; " ")')
url=$(printf '%s' "$SELECTED" | jq -r '.url')
reason=$(printf '%s' "$SELECTED" | jq -r '.reason')
next_action=$(printf '%s' "$SELECTED" | jq -r '.next_action')
detail=$(printf '%s' "$SELECTED" | jq -r '.next_action_detail')
merge_gate_check=$(printf '%s' "$SELECTED" | jq -r '.merge_gate_check // "absent"')
newest_line=$(printf '%s' "$SELECTED" | jq -r '.newest | .kind + " by " + .actor + " at " + .at + " (" + ((.age_seconds / 60) | floor | tostring) + "m ago)"')
repo_slug=${REPO#*/}

# The printed Codex request mirrors the policy exactly, so the session can run
# it as shown. Phase 4a scope is the repository's own triage verdict:
# agent-review.yml labels a PR `needs-external-review` exactly when it meets
# the external review threshold or a protected path; only such a PR is flagged
# Phase-4a-gated, and any other PR is left to the requester's own entry
# decision (codex.request_by_default). A head nobody asked about gets a
# trigger-only request (idempotent). A request that already outlived the
# threshold unanswered would make trigger-only a no-op (it dedups on the
# existing trigger), so that case prints the requester's polling mode, which
# re-posts the unanswered request and waits up to codex.review_timeout_seconds.
if printf '%s' "$SELECTED" | jq -e '.labels | index("needs-external-review")' >/dev/null; then
  gated=true
else
  gated=""
fi
if [ "$reason" = "request-unanswered" ]; then
  req_flag=""
  mode_note="polling mode: re-posts the unanswered request and waits for the answer"
else
  req_flag="--trigger-only"
  mode_note="trigger-only, idempotent"
fi
request_cmd="${gated:+MERGEPATH_PHASE_4A_GATED=true }scripts/codex-review-request.sh${req_flag:+ $req_flag} $number $REPO"
# Every PR-controlled value that lands in a printed command is shell-escaped:
# a branch may legally be named `topic;rm -rf ~`, and the work order is
# advertised as copy-paste-ready.
q_ref=$(printf '%q' "$head_ref")
q_slug=$(printf '%q' "$repo_slug")
q_wt="\$HOME/GitHub/.${q_slug}-worktrees/pr-${number}"

echo "## Stalled PR work order"
echo
echo "PR:          $REPO#$number — $title"
echo "URL:         $url"
echo "Head:        $head_sha ($head_ref)"
echo "Stalled:     $reason — newest event: $newest_line"
echo "Next action: $next_action — $detail"
echo
echo "Checkout (hidden per-repo worktree folder, docs/agents/worktree-placement.md):"
# Non-destructive: a DETACHED worktree at the recorded head SHA. No local
# branch is created, moved or reset, so unpublished commits on a local branch
# of the same name are never orphaned; fixes go back with a plain (non-force)
# push to the PR branch, which fails safely if the remote moved. Fork and
# contributor-owned PRs never classify as stalled (the finder routes them to
# waiting-on-human), so the head branch is always on origin here. Run the
# policy commands below from that worktree: the delegates read the governing
# policy of the repository they run in.
echo "  git -C \$HOME/GitHub/${q_slug} fetch origin ${q_ref}"
echo "  git -C \$HOME/GitHub/${q_slug} worktree add --detach ${q_wt} ${head_sha}"
echo "  cd ${q_wt}"
echo "  # push fixes with: git push origin HEAD:refs/heads/${q_ref}   (non-force; refuses if the remote moved)"
echo

case "$next_action" in
  "push fix")
    echo "Round to run (REVIEW_POLICY.md §§ Workflow and Feedback Disposition Policy):"
    echo "  1. Read every unanswered finding on the head and fix or rebut each one:"
    printf '%s' "$SELECTED" | jq -r '.unanswered_findings[] | "       - " + .actor + "  " + .url'
    echo "  2. Push the fix commits (author identity; commits sign via local git config)."
    echo "  3. Record each disposition: scripts/codex-record-feedback.sh $number $REPO ... / scripts/coderabbit-record-feedback.sh $number --repo $REPO ..."
    echo "  4. Resolve the actioned threads: scripts/resolve-pr-threads.sh $number --repo $REPO --resolve-actioned"
    echo "  5. Re-request the review on the new head:"
    echo "       ${gated:+MERGEPATH_PHASE_4A_GATED=true }scripts/codex-review-request.sh --trigger-only $number $REPO"
    ;;
  "request codex")
    echo "Round to run (the session posts this; it goes through the author wrapper):"
    echo "  $request_cmd"
    echo "  ($mode_note)"
    echo "  Requester exits that are routing outcomes, not failures — act on them, do not retry:"
    if [ "$gated" = "true" ]; then
      echo "    5  Codex is disabled here (codex.enabled false) and this PR is in Phase 4a scope: run Phase 4b"
    else
      echo "    5  no Codex request by policy (codex.request_by_default false): take the under-threshold approval-and-merge path"
    fi
    echo "    6  earlier review feedback is unaccounted: scripts/review-feedback-accounting.sh $number $REPO, disposition, rerun"
    echo "    7  request budget spent: cap_exhausted.kind request-ceiling = run Phase 4b; blocking-reviews = human tiebreaker"
    [ -n "$req_flag" ] || echo "    4  (polling mode) no answer within the review timeout: run Phase 4b"
    echo "  Phase 4b: scripts/phase-4b-review.sh $number --repo $REPO, from a trusted main checkout"
    ;;
  merge)
    echo "Pre-merge sequence (REVIEW_POLICY.md §§ Workflow and Pre-Merge Review Conversation Gate) — every gate clean, then merge as the author:"
    echo "  scripts/coderabbit-should-invoke.sh $number --repo $REPO         # selector: 0 invoke, 1 skip; other exits stop"
    echo "  If selected, run the current-head wait before continuing:"
    echo "    scripts/coderabbit-wait.sh $number $REPO"
    echo "    Wait exit 0: continue; 2: address findings, record feedback and resolve threads, then restart this sequence."
    echo "    Wait exit 4: advisory timeout; record status_probe if present, then continue."
    echo "    Wait exit 5: proceed only with codex_failover_requested:true and current-head Codex/Phase 4 clearance; otherwise stop and alert the human."
    echo "    Wait exit 6: repair the paused/non-base-branch/draft cause, then rerun; any other exit stops."
    echo "  Under-threshold exit-5 failover only: await current-head Codex clearance, then verify it before approving:"
    echo "    CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=0 scripts/codex-review-check.sh --require-codex-on-head $number $REPO"
    echo "  With GH_AS_REVIEWER_IDENTITY set to your registered reviewer identity, post a NEW approval AFTER that clearance:"
    echo "    scripts/gh-as-reviewer.sh -- gh pr review $number --repo $REPO --approve --body 'CodeRabbit rate-limited; cleared by Codex on $head_sha.'"
    echo "  Any earlier approval cannot carry the failover; verify the later exact-head approval before merging:"
    echo "    CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 scripts/codex-review-check.sh --require-codex-on-head $number $REPO"
    echo "  Above-threshold exit-5 failover continues through Phase 4 instead; do not add a same-agent approval."
    echo "  scripts/review-feedback-accounting.sh $number $REPO              # posted == accounted"
    echo "  scripts/resolve-pr-threads.sh $number --repo $REPO --list        # zero unresolved threads required"
    echo "  scripts/required-head-checks.sh --repo $REPO --verify --sha $head_sha   # configured build checks green on the head"
    echo "  scripts/phase-4b-classifier.sh $number --repo $REPO             # exit 1 = post the Phase 4b handoff first (above-threshold PRs)"
    echo "  scripts/codex-review-check.sh $number $REPO                     # Phase 4 gate on $head_sha"
    echo "  Merge clearance gate check on head: $merge_gate_check"
    echo "  scripts/gh-as-author.sh -- gh pr merge $number --repo $REPO --squash --delete-branch --match-head-commit $head_sha"
    echo "  (this script never merges; the author identity does, only after every gate above is clean)"
    ;;
  investigate)
    echo "The gate did not decide the next step: $detail"
    echo "  scripts/codex-review-check.sh $number $REPO           # read the one-line reason on stderr"
    echo "  scripts/required-head-checks.sh --repo $REPO --verify --sha $head_sha"
    ;;
  *)
    echo "Next action '$next_action' is not one this script automates; read the finder output above."
    ;;
esac

echo
echo "Session rule (docs/agents/shared-operating-rules.md § End of session): do not end the session with this PR on an"
echo "unanswered verdict or CI-green, approved and unmerged — finish the round, or post a comment carrying"
echo "[mergepath-handoff] that names the next action."

if [ "$JSON_OUT" = "1" ]; then
  echo
  printf '%s' "$SELECTED" | jq '.'
fi
