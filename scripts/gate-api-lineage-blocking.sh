#!/usr/bin/env bash
# scripts/gate-api-lineage-blocking.sh — does the Checks-API lineage of a
# required context block this head right now? (#2247)
#
# Usage:
#   scripts/gate-api-lineage-blocking.sh <REPO> <HEAD_SHA> <CHECK_NAME> <RUN_ID>
#
# Read-only. Exit 0 ONLY when all of these hold, read from one paginated
# `GET /commits/<HEAD_SHA>/check-runs?check_name=<CHECK_NAME>&filter=latest`:
#
#   1. The calling workflow run's own job-native run of CHECK_NAME is listed
#      (matched by RUN_ID in its details_url), so its check suite is known.
#   2. At least one Checks-API run of CHECK_NAME is listed: app
#      `github-actions`, empty external_id (Actions stamps a UUID on every
#      job-native run and a Checks-API POST leaves it empty; the same
#      discriminator as gate (a) in scripts/codex-review-check.sh, #1215).
#   3. EVERY listed Checks-API run blocks: not completed, or completed with a
#      conclusion other than success / neutral / skipped.
#   4. No listed Checks-API run shares a check suite with the caller's own
#      job-native run.
#
# Anything else (a failed read, a malformed answer, any condition unmet)
# exits 1 with the reason on stdout. Usage errors exit 2.
#
# Why each condition is there. The event-driven job of
# merge-clearance-gate.yml concludes its job-native run non-failing while
# clearance is merely pending, and relies on the Checks-API lineage to keep
# the required context blocking (#2247). GitHub reads both lineages of one
# required context, and a red Checks-API run blocks on its own while every
# job-native run is green (measured on #828 and #835, written up in #841).
# That is the property this script confirms is present on the head at the
# moment the job decides:
#
#   - filter=latest is GitHub's own choice of the current run per check
#     suite; the #835 stale Checks-API failure left that listing at the same
#     moment branch protection released the merge, so it is the selection the
#     merge decision uses. All Checks-API POSTs for one head coalesce into one
#     shared suite, so normally exactly one Checks-API run is listed.
#   - Requiring every listed Checks-API run to block, not just one, holds
#     under either reading of how GitHub combines runs: newest per lineage, or
#     newest per suite.
#   - The shared suite is whichever suite was created first on the head. If
#     that were this workflow run's own suite, its job-native run and the
#     Checks-API runs would compete for "latest" in one suite, and a
#     non-failing job-native completion could mask the Checks-API block. The
#     caller then keeps its job-native run failing. Condition 1 is what makes
#     condition 4 checkable: when the shared suite is the caller's own, the
#     listing shows only one of the two, and either way a condition fails.
#
# A pass is a statement about this instant. A later Checks-API write can
# still change the lineage; every writer there publishes green only from its
# own evaluation of a cleared head, and the publisher withholds a verdict
# whenever a newer hold was opened after its pass began.

set -euo pipefail

if [ $# -ne 4 ]; then
  echo "Usage: $0 <REPO> <HEAD_SHA> <CHECK_NAME> <RUN_ID>" >&2
  exit 2
fi
REPO=$1
HEAD_SHA=$2
CHECK_NAME=$3
RUN_ID=$4

case "$REPO" in
  */*) ;;
  *) echo "Usage: REPO must be owner/repo; got '$REPO'" >&2; exit 2 ;;
esac
if ! [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Usage: HEAD_SHA must be a 40-character hex SHA; got '$HEAD_SHA'" >&2
  exit 2
fi
if [ -z "$CHECK_NAME" ]; then
  echo "Usage: CHECK_NAME must be non-empty" >&2
  exit 2
fi
case "$RUN_ID" in
  ''|*[!0-9]*) echo "Usage: RUN_ID must be a positive integer; got '$RUN_ID'" >&2; exit 2 ;;
esac

for tool in gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "not established: required tool '$tool' not found on PATH"
    exit 1
  fi
done

if ! runs=$(gh api --paginate -X GET "repos/$REPO/commits/$HEAD_SHA/check-runs" \
    -f check_name="$CHECK_NAME" -f filter=latest -f per_page=100 \
    --jq '.check_runs[] | {id, status, conclusion,
            ext: (.external_id // ""),
            suite: (.check_suite.id // null),
            app: (.app.slug // ""),
            url: (.details_url // "")}' 2>/dev/null); then
  echo "not established: could not read the '$CHECK_NAME' check runs on $HEAD_SHA"
  exit 1
fi

# The verdict program lives in a quoted heredoc rather than inline in the
# command substitution: bash 3.2 mis-parses parentheses inside a
# single-quoted argument of $( ).
VERDICT_JQ=$(cat <<'JQ'
  def blocks:
    (.status != "completed")
    or ((.conclusion // "") as $c | ["success", "neutral", "skipped"] | index($c) | not);
  ([ .[] | select(.app == "github-actions") ]) as $mine
  | ([ $mine[] | select(.ext != "")
       | select(.url | contains("/actions/runs/" + $run + "/job/")) ]) as $own
  | ([ $mine[] | select(.ext == "") ]) as $api
  | ([ $own[] | .suite ]) as $own_suites
  | if ($own | length) == 0 then
      "not established: this run's own job-native run is not in the latest listing"
    elif ($own_suites | map(select(. == null)) | length) > 0 then
      "not established: this run's own job-native run carries no check suite id"
    elif ($api | length) == 0 then
      "not established: no Checks-API run of this context on the head"
    elif ([ $api[] | select(.suite == null or (.suite as $s | $own_suites | index($s))) ] | length) > 0 then
      "not established: a Checks-API run shares this run's check suite, so a job-native completion could mask it"
    elif ([ $api[] | select(blocks | not) ] | length) > 0 then
      "not established: the current Checks-API run is not blocking (" + ([ $api[] | select(blocks | not) | "\(.id) \(.status)/\(.conclusion // "-")" ] | join(", ")) + ")"
    else
      "established: Checks-API run(s) " + ([ $api[] | "\(.id) \(.status)/\(.conclusion // "-") in suite \(.suite)" ] | join(", ")) + " block; this run's job-native suite is " + ($own_suites | map(tostring) | join(", "))
    end
JQ
)

verdict=$(printf '%s\n' "$runs" | jq -rs --arg run "$RUN_ID" "$VERDICT_JQ" 2>/dev/null) || {
  echo "not established: could not parse the '$CHECK_NAME' check runs on $HEAD_SHA"
  exit 1
}

echo "$verdict"
case "$verdict" in
  "established: "*) exit 0 ;;
  *) exit 1 ;;
esac
