#!/usr/bin/env bash
# scripts/dispatch-thread-resolution-lane.sh — run the thread-resolution CI
# lane for a PR and wait for that run to finish (#1057 item G).
#
# A session whose proxy refuses GraphQL cannot resolve review threads, so it
# hands resolution to .github/workflows/thread-resolution-lane.yml. A
# dispatch returns before its run exists, and the most recent run with a
# matching name may be an older one, so this does the whole step and does
# not leave it to a recipe (CodeRabbit and Codex on #1555):
#
#   1. dispatch a repository_dispatch event (the lane's only trigger, which
#      GitHub runs from the default branch's copy alone) carrying the PR and
#      a fresh nonce, through scripts/gh-as-author.sh, which binds and
#      verifies the provisioned author PAT (Contents: write)
#   2. poll, within a bound, for the run whose title carries that nonce:
#      only the run this call created can match
#   3. poll that run's REST status until it completes, within
#      --watch-timeout, and require the `success` conclusion
#
# Everything after the dispatch is a REST read (actions/workflows/.../runs,
# actions/runs/<id>), not `gh run list` / `gh run watch`: `gh run watch`
# does not support fine-grained PATs (Codex P1 on #1555). Reads prefer the
# reviewer PAT, which is classic (docs/agents/cloud-environments.md).
#
# Reply on every thread before running this: the lane sees only
# GitHub-visible evidence, never a session's local feedback ledger.
#
# Usage:
#   scripts/dispatch-thread-resolution-lane.sh <PR#> [--repo OWNER/REPO]
#     [--appear-timeout SECONDS] [--watch-timeout SECONDS] [--no-wait]
#
#   --appear-timeout  how long to wait for the run to be listed (default 180)
#   --watch-timeout   how long to wait for it to complete (default 1200)
#   --no-wait         print the run id once it is listed, and do not watch it
#
# Exit codes:
#   0  the lane run completed successfully (or, with --no-wait, was found)
#   1  bad invocation
#   4  the dispatch was refused
#   6  no run carrying this dispatch's nonce appeared within the bound
#   8  the lane run finished unsuccessfully (its log says why)
#   9  the lane run did not complete within --watch-timeout
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="thread-resolution-lane.yml"
EVENT_TYPE="thread-resolution-lane"

PR=""
REPO=""
APPEAR_TIMEOUT=180
WATCH_TIMEOUT=1200
POLL_INTERVAL="${DISPATCH_LANE_POLL_INTERVAL:-5}"
WAIT=true

die() { echo "dispatch-thread-resolution-lane: $2" >&2; exit "$1"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--appear-timeout|--watch-timeout)
      [ "$#" -ge 2 ] || die 1 "$1 requires a value"
      case "$1" in
        --repo) REPO="$2" ;;
        --appear-timeout) APPEAR_TIMEOUT="$2" ;;
        --watch-timeout) WATCH_TIMEOUT="$2" ;;
      esac
      shift 2
      ;;
    --no-wait) WAIT=false; shift ;;
    -h|--help) sed -n '2,/^# Bash 3.2 portable/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
    -*) die 1 "unknown option: $1" ;;
    *)
      [ -z "$PR" ] || die 1 "unexpected argument: $1"
      PR="$1"; shift
      ;;
  esac
done

printf '%s' "$PR" | grep -Eq '^[0-9]+$' || die 1 "PR number required (got '${PR}')"
printf '%s' "$APPEAR_TIMEOUT" | grep -Eq '^[0-9]+$' || die 1 "--appear-timeout must be a number of seconds"
printf '%s' "$WATCH_TIMEOUT" | grep -Eq '^[0-9]+$' || die 1 "--watch-timeout must be a number of seconds"
command -v gh >/dev/null 2>&1 || die 1 "gh is required"

if [ -z "$REPO" ]; then
  REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -nE 's#^(https://[^/]*github\.com/|git@github(-[A-Za-z0-9]+)?(\.com)?:|ssh://git@github(-[A-Za-z0-9]+)?(\.com)?/)([^/]+/[^/]+)$#\6#p' \
    | sed -E 's/\.git$//')"
  [ -n "$REPO" ] || die 1 "could not derive OWNER/REPO from origin; pass --repo"
fi

# Reads use a provisioned PAT when there is one (a Codex task has no keyring
# and no ambient token), the classic reviewer PAT first; the dispatch itself
# goes through the author wrapper.
READ_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-${OP_PREFLIGHT_AUTHOR_PAT:-${GH_TOKEN:-}}}"
read_gh() {
  if [ -n "$READ_TOKEN" ]; then GH_TOKEN="$READ_TOKEN" gh "$@"; else gh "$@"; fi
}

# The lane titles each run "Thread resolution lane: PR #<pr> [<nonce>]", so
# a nonce no earlier dispatch used identifies this dispatch's run exactly.
NONCE="$(date +%s)-$$-${RANDOM}${RANDOM}"
TITLE="Thread resolution lane: PR #$PR [$NONCE]"

AS_AUTHOR="$ROOT/scripts/gh-as-author.sh"
[ -x "$AS_AUTHOR" ] || die 4 "author wrapper missing ($AS_AUTHOR)"
dispatch_rc=0
"$AS_AUTHOR" -- gh api -X POST "repos/$REPO/dispatches" \
  -f "event_type=$EVENT_TYPE" -F "client_payload[pr]=$PR" -f "client_payload[nonce]=$NONCE" >/dev/null || dispatch_rc=$?
# The wrapper's token exits (scripts/gh-as-author.sh: 3 lookup failed, 2
# verification failed, 70 trace marker) mean nothing was sent. Any other
# nonzero, 1 included, is what gh itself returned for the request, which is
# GitHub refusing the dispatch.
case "$dispatch_rc" in
  0) ;;
  3) die 4 "no author token was found, so nothing was dispatched to $REPO; provision the author PAT (docs/agents/cloud-environments.md, Credentials)" ;;
  2) die 4 "the author token did not verify as a user-held credential for the author, so nothing was dispatched to $REPO" ;;
  70) die 4 "the author wrapper refused before dispatching to $REPO (exit 70; its message is above)" ;;
  *) die 4 "the repository_dispatch to $REPO was refused; the author PAT needs Contents: write (fine-grained) or repo (classic)" ;;
esac
echo "dispatch-thread-resolution-lane: dispatched $EVENT_TYPE for $REPO#$PR (nonce $NONCE)" >&2

# Both waits are wall-clock deadlines (bash's SECONDS), so time spent in
# requests counts, not only the sleeps (CodeRabbit on #1555); a sleep never
# runs past the deadline.
nap() { # <deadline>
  local left=$(( $1 - SECONDS ))
  [ "$left" -gt "$POLL_INTERVAL" ] && left="$POLL_INTERVAL"
  [ "$left" -gt 0 ] && sleep "$left"
  return 0
}

run_id=""
deadline=$(( SECONDS + APPEAR_TIMEOUT ))
while :; do
  run_id="$(read_gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?event=repository_dispatch&per_page=100" \
    --jq "[.workflow_runs[] | select(.display_title == \"$TITLE\")][0].id // empty" 2>/dev/null || true)"
  printf '%s' "$run_id" | grep -Eq '^[0-9]+$' && break
  run_id=""
  [ "$SECONDS" -lt "$deadline" ] || die 6 "no lane run titled '$TITLE' appeared within ${APPEAR_TIMEOUT}s; check the Actions tab of $REPO"
  nap "$deadline"
done
echo "dispatch-thread-resolution-lane: run $run_id: https://github.com/$REPO/actions/runs/$run_id" >&2

if ! $WAIT; then
  printf '%s\n' "$run_id"
  exit 0
fi
deadline=$(( SECONDS + WATCH_TIMEOUT ))
while :; do
  state="$(read_gh api "repos/$REPO/actions/runs/$run_id" --jq '"\(.status) \(.conclusion // "")"' 2>/dev/null || true)"
  case "$state" in
    "completed success") break ;;
    completed\ *) die 8 "lane run $run_id finished with conclusion '${state#completed }'; read its log before retrying" ;;
  esac
  [ "$SECONDS" -lt "$deadline" ] || die 9 "lane run $run_id did not complete within ${WATCH_TIMEOUT}s (last status: ${state:-unreadable})"
  nap "$deadline"
done
echo "dispatch-thread-resolution-lane: lane run $run_id completed; check the PR for any thread it left open (its summary lists them)" >&2
exit 0
