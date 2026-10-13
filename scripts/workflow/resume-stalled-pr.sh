#!/usr/bin/env bash
# scripts/workflow/resume-stalled-pr.sh — pick up the oldest stalled pull
# request and hand its next round to the calling agent session
# (nathanjohnpayne/mergepath#2165).
#
# This is the entry point a scheduled routine (or a human) runs to continue
# review rounds outside working hours. It runs the read-only finder
# (scripts/workflow/stalled-prs.sh), selects the stalled PR whose newest
# event is oldest, and prints a WORK ORDER: the PR, its head, why it is
# stalled, the next action, and the exact commands the review policy
# prescribes for that action. The calling session then executes the round
# per AGENTS.md § Workflow Summary.
#
# The only action this script will perform itself is the mechanical,
# idempotent, wrapper-verified one — posting `@codex review` through
# scripts/codex-review-request.sh --trigger-only — and only under --execute.
# Pushing a fix needs code; merging needs the accounting and thread gates and
# the author identity; both stay with the agent session. This script never
# merges.
#
# Usage:
#   scripts/workflow/resume-stalled-pr.sh [--repo owner/repo] [--threshold-minutes N]
#                                         [--pr N] [--execute] [--json]
#                                         [--input FILE] [--now ISO8601]
#
#   --repo               Repository to inspect (default: current repo).
#   --threshold-minutes  Passed to the finder (default 60).
#   --pr N               Resume this PR instead of the oldest stalled one. It
#                        must still classify as stalled.
#   --execute            Perform the `request codex` action when that is the
#                        next action. Posts through the author wrapper, so it
#                        needs the author credential the wrapper resolves
#                        (OP_PREFLIGHT_AUTHOR_PAT from preflight, or the gh
#                        keyring). Without --execute every action is printed,
#                        none is performed.
#   --json               Print the selected PR's finder record as JSON after
#                        the work order (machine-readable handoff).
#   --input FILE         Replay a finder snapshot instead of fetching one
#                        (regression suite; no network).
#   --now ISO8601        Passed to the finder (fixture runs).
#
# Exit codes:
#   0  a stalled PR was selected and its work order printed (and, under
#      --execute, the request step ran and exited 0)
#   1  nothing is stalled — nothing to resume
#   2  usage error
#   3  the finder could not read the repository, or the --execute step hit an
#      infrastructure error
#   4  --execute: the Codex request was REFUSED BY POLICY, not by an outage —
#      the requester exited 6 (feedback unaccounted) or 7 (request budget
#      exhausted). The routing outcome is printed as a `next:` line and in the
#      `--json` record (`execute.requester_exit`, `execute.cap_kind`,
#      `execute.next_action`): `disposition findings` (6), `phase 4b`
#      (7 request-ceiling: run scripts/phase-4b-review.sh from a trusted main
#      checkout) or `human tiebreaker` (7 blocking-reviews: escalate per
#      REVIEW_POLICY.md § Disagreements). A routine must act on that line, not
#      retry the request: the requester will keep refusing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FINDER="$ROOT/scripts/workflow/stalled-prs.sh"
REQUESTER="$ROOT/scripts/codex-review-request.sh"

REPO=""
THRESHOLD_MINUTES=60
PICK_PR=""
EXECUTE=0
JSON_OUT=0
INPUT_FILE=""
NOW=""

usage() {
  echo "usage: resume-stalled-pr.sh [--repo owner/repo] [--threshold-minutes N] [--pr N] [--execute] [--json] [--input FILE] [--now ISO8601]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --threshold-minutes) [ "$#" -ge 2 ] || usage; THRESHOLD_MINUTES="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; PICK_PR="$2"; shift 2 ;;
    --execute) EXECUTE=1; shift ;;
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
# Fork and contributor-owned PRs never classify as stalled (the finder routes
# them to waiting-on-human), so the head branch is always on origin here.
echo "  git -C \$HOME/GitHub/${q_slug} fetch origin ${q_ref}"
echo "  git -C \$HOME/GitHub/${q_slug} worktree add ${q_wt} ${q_ref}"
echo

case "$next_action" in
  "push fix")
    echo "Round to run (AGENTS.md § Workflow Summary steps 3, 5f, 6, 7/8):"
    echo "  1. Read every unanswered finding on the head and fix or rebut each one:"
    printf '%s' "$SELECTED" | jq -r '.unanswered_findings[] | "       - " + .actor + "  " + .url'
    echo "  2. Push the fix commits (author identity; commits sign via local git config)."
    echo "  3. Record each disposition: scripts/codex-record-feedback.sh $number ... / scripts/coderabbit-record-feedback.sh $number ..."
    echo "  4. Resolve the actioned threads: scripts/resolve-pr-threads.sh $number --resolve-actioned"
    echo "  5. Re-request the review on the new head:"
    echo "       MERGEPATH_PHASE_4A_GATED=true scripts/codex-review-request.sh --trigger-only $number $REPO"
    ;;
  "request codex")
    echo "Round to run:"
    echo "  MERGEPATH_PHASE_4A_GATED=true scripts/codex-review-request.sh --trigger-only $number $REPO"
    echo "  (idempotent on an existing head trigger; exit 6 means review feedback is unaccounted — disposition it first)"
    ;;
  merge)
    echo "Pre-merge sequence (AGENTS.md § Workflow Summary steps 6, 8 and 10) — every gate clean, then merge as the author:"
    echo "  scripts/review-feedback-accounting.sh $number         # posted == accounted"
    echo "  scripts/resolve-pr-threads.sh $number --list          # zero unresolved threads required"
    echo "  scripts/phase-4b-classifier.sh $number               # exit 1 = post the Phase 4b handoff first (above-threshold PRs)"
    echo "  scripts/codex-review-check.sh $number $REPO            # Phase 4 gate on $head_sha"
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

if [ "$EXECUTE" = "1" ]; then
  if [ "$next_action" != "request codex" ]; then
    echo
    echo "resume-stalled-pr: --execute performs only 'request codex'; '$next_action' is left to the session." >&2
    exit 0
  fi
  if [ -n "$INPUT_FILE" ]; then
    echo
    echo "resume-stalled-pr: --execute is refused on a replayed --input snapshot (no live head to request on)." >&2
    exit 2
  fi
  [ -x "$REQUESTER" ] || { echo "resume-stalled-pr: requester missing or not executable: $REQUESTER" >&2; exit 3; }
  echo
  echo "resume-stalled-pr: posting the Codex request through the author wrapper (trigger-only, idempotent)"
  req_out=$(mktemp "${TMPDIR:-/tmp}/resume-stalled-pr-req.XXXXXX") || { echo "resume-stalled-pr: mktemp failed" >&2; exit 3; }
  trap 'rm -f "$req_out"' EXIT
  set +e
  MERGEPATH_PHASE_4A_GATED=true "$REQUESTER" --trigger-only "$number" "$REPO" > "$req_out"
  rc=$?
  set -e
  cat "$req_out"
  # The requester's policy refusals are routing outcomes, preserved as such:
  # collapsing them into an infrastructure failure would leave a scheduled
  # caller retrying a request the policy has already said to stop making.
  cap_kind=$(jq -r '.cap_exhausted.kind // ""' "$req_out" 2>/dev/null || true)
  case "$rc" in
    0) exit_next="" ;;
    6) exit_next="disposition findings" ;;
    7)
      case "$cap_kind" in
        request-ceiling) exit_next="phase 4b" ;;
        blocking-reviews) exit_next="human tiebreaker" ;;
        *) exit_next="human tiebreaker" ;;  # unknown kind: the conservative route
      esac ;;
    *) echo "resume-stalled-pr: codex-review-request.sh exited $rc (infrastructure); nothing was decided" >&2; exit 3 ;;
  esac
  if [ -n "$exit_next" ]; then
    case "$exit_next" in
      "disposition findings") how="disposition every earlier finding (scripts/review-feedback-accounting.sh $number), then rerun" ;;
      "phase 4b") how="the request ceiling is spent: run scripts/phase-4b-review.sh $number --repo $REPO from a trusted main checkout" ;;
      *) how="the blocking-review budget is spent: stop, post the escalation comment carrying [mergepath-handoff] per REVIEW_POLICY.md § Disagreements and Tiebreaking, and alert the human" ;;
    esac
    echo
    echo "next: $exit_next — $how"
    if [ "$JSON_OUT" = "1" ]; then
      jq -n --argjson rc "$rc" --arg kind "$cap_kind" --arg next "$exit_next" --arg how "$how" \
        '{execute: {requester_exit: $rc, cap_kind: (if $kind == "" then null else $kind end), next_action: $next, detail: $how}}'
    fi
    exit 4
  fi
fi
