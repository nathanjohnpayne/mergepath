#!/usr/bin/env bash
# Supersede a stale failed `auto-clear-blocking-labels` check-run once a later
# clean pass confirms `needs-external-review` is absent (#2193).
#
# Usage: heal-auto-clear-infra-check.sh <owner/repo> <run-url> <event|sweep> <space-separated-pr-numbers>
#
# ─────────────────────────────────────────────────────────────────────
# Why this exists
# ─────────────────────────────────────────────────────────────────────
#
# When either auto-clear job hits an infrastructure error on a PR (an
# exhausted installation token, a failed label read, a gate rc=3), its
# "Surface infra failure as per-PR check-runs" step posts a FAILED synthetic
# `auto-clear-blocking-labels` check-run on that PR's head. Before #2193 the
# only path that ever posted a SUCCESS for that name was the same surfacing
# step's #499 arm, which runs only when a later pass ALSO hit an
# infrastructure error. A later pass that evaluated the PR cleanly and removed
# the label (or found it already gone) posted nothing, so the failure stayed
# the newest run with that name on the head indefinitely. The check is not
# required, but it drives `mergeStateStatus` to UNSTABLE and
# scripts/hooks/gh-pr-guard.sh refuses `gh pr merge` while any name's newest
# run is not green. Observed on #2171, #2173 (head e186acc2) and #2175: every
# required context green, the label gone, and the merge refused.
#
# A synthetic success posted by the same app under the same name on the same
# head is what retires a synthetic failure (the job-native runs of this
# workflow carry different names, so they never could).
#
# ─────────────────────────────────────────────────────────────────────
# Contract
# ─────────────────────────────────────────────────────────────────────
#
# The caller passes only PRs that the pass just evaluated WITHOUT an
# infrastructure error and found (or left) with `needs-external-review`
# absent. For each one this script:
#
#   1. reads the PR's live head SHA and label state in one call, and stops
#      when the label is present (the success title claims absence);
#   2. reads every `auto-clear-blocking-labels` check-run on that head and
#      stops unless the NEWEST one (by completion time, then id) is a
#      `failure`. No run, or a newest run that is already green, posts
#      nothing, so ordinary passes add no check-run volume;
#   3. re-reads the head SHA and label state immediately before the POST and
#      stops when the head moved or the label came back;
#   4. POSTs one `success` check-run with the same name on that head. A
#      failed POST is retried under with_gh_retry (#2205), and every attempt
#      repeats step 3 first, so a retry never writes further from its fence
#      than the first attempt did. A permanent failure (a 4xx other than a
#      rate limit) is not retried. A retry after a POST that was accepted but
#      reported as failed posts a second success, which is harmless: the
#      newest run is green either way.
#
# Every read or write failure is a warning, never a job failure: the heal is
# best effort. When is a failed heal retried, exactly (#2205)?
#
#   * Within this run: the POST, up to GH_RETRY_ATTEMPTS times (default 3,
#     30 s apart), re-fenced each time. The two reads before it are retried
#     the same way, without a fence (they write nothing).
#   * Afterwards: by the next pass that hands this script the PR. The
#     routine one is required-check-publisher.yml: every full-coverage pass
#     (the */30 chained sweep pass, an operator dispatch) that posts a green
#     `Merge clearance gate` verdict on a label-absent head reads the newest
#     run of this check there and, when it is a failure, nominates the PR to
#     auto-clear through repository_dispatch, whose evaluate-and-clear job
#     hands it here. A pull_request_target event other than `synchronize`,
#     and a scheduled-sweep visit while the search index still lists the
#     label, do the same. Nothing else retries it: a `synchronize` or a
#     workflow_run completion never nominates a label-absent PR.
#
# A failed infra check-run that a concurrent run posts after this POST (it
# read the label before the removal) becomes the newest run again and is
# healed the same way. Nothing here removes, adds or reads any label other
# than `needs-external-review`, and nothing here changes a gate verdict.
#
# The check-run POST needs the workflow's GITHUB_TOKEN (`checks: write`):
# check-runs can only be created by a GitHub App, never by a PAT.

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: heal-auto-clear-infra-check.sh <owner/repo> <run-url> <event|sweep> <space-separated-pr-numbers>" >&2
  exit 2
fi

REPO="$1"
RUN_URL="$2"
CONTEXT="$3"
PR_NUMBERS="$4"
CHECK_NAME='auto-clear-blocking-labels'

case "$CONTEXT" in
  event) TITLE_SUFFIX='' ;;
  sweep) TITLE_SUFFIX=' (scheduled sweep)' ;;
  *)
    echo "heal-auto-clear-infra-check.sh: context must be event or sweep (got: $CONTEXT)" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/gh-retry-helpers.sh
source "$ROOT/scripts/lib/gh-retry-helpers.sh"

# live_head_and_label <pr> -> "<head-sha><TAB><true|false>"
live_head_and_label() {
  with_gh_retry gh api "repos/$REPO/pulls/$1" \
    --jq '[.head.sha, (any(.labels[]?; .name == "needs-external-review") | tostring)] | @tsv'
}

# newest_conclusion <head-sha> -> the conclusion of the newest
# auto-clear-blocking-labels check-run on that head, or `none`. Paginated so a
# head that collected many failed runs during a long outage is read in full.
newest_conclusion() {
  local runs
  runs=$(with_gh_retry gh api --paginate \
    "repos/$REPO/commits/$1/check-runs?check_name=$CHECK_NAME&filter=all&per_page=100" \
    --jq '.check_runs[] | select(.name == "auto-clear-blocking-labels")
          | [(.completed_at // .started_at // ""), (.id | tostring), (.conclusion // .status // "unknown")]
          | @tsv') || return 1
  if [ -z "$runs" ]; then
    printf 'none\n'
    return 0
  fi
  printf '%s\n' "$runs" | sort -t "$(printf '\t')" -k1,1 -k2,2n | tail -n 1 | cut -f3
}

# fenced_heal_post <pr> <head-sha>: ONE attempt of the fence and the write,
# shaped for with_gh_retry. It re-reads the PR (unretried here: the caller's
# retry repeats the whole unit) and prints `moved <sha>` or `labeled <state>`
# with status 0 when the fence says not to write, so a fence stop is never
# retried. Otherwise it POSTs once and prints `posted`. A failed read or POST
# returns gh's status with gh's stderr, which with_gh_retry classifies as
# transient or permanent.
fenced_heal_post() {
  local pr="$1" head="$2" recheck recheck_head recheck_label rc=0
  recheck=$(gh api "repos/$REPO/pulls/$pr" \
    --jq '[.head.sha, (any(.labels[]?; .name == "needs-external-review") | tostring)] | @tsv') || return $?
  recheck_head=$(printf '%s\n' "$recheck" | cut -f1)
  recheck_label=$(printf '%s\n' "$recheck" | cut -f2)
  if [ "$recheck_head" != "$head" ]; then
    printf 'moved %s\n' "${recheck_head:-unreadable}"
    return 0
  fi
  if [ "$recheck_label" != "false" ]; then
    printf 'labeled %s\n' "$recheck_label"
    return 0
  fi
  gh api "repos/$REPO/check-runs" \
    -X POST \
    -f name="$CHECK_NAME" \
    -f "head_sha=$head" \
    -f status='completed' \
    -f conclusion='success' \
    -F "output[title]=Auto-clear confirmed needs-external-review absent$TITLE_SUFFIX" \
    -F "output[summary]=PR #$pr: this pass evaluated the PR without an infrastructure error and confirmed needs-external-review is absent on head $head, superseding an earlier failed $CHECK_NAME check-run. See workflow run logs: $RUN_URL" \
    >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'posted\n'
}

for PR in $PR_NUMBERS; do
  case "$PR" in
    ''|*[!0-9]*)
      echo "::warning::Ignoring malformed PR number '$PR' in the auto-clear heal list."
      continue
      ;;
  esac
  echo "::group::Checking PR #$PR for a stale auto-clear infra-failure check-run"
  if ! live=$(live_head_and_label "$PR"); then
    echo "::warning::Could not read the live head and labels of PR #$PR; a later clean pass will retry the heal."
    echo "::endgroup::"
    continue
  fi
  head_sha=$(printf '%s\n' "$live" | cut -f1)
  has_label=$(printf '%s\n' "$live" | cut -f2)
  if ! [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::warning::PR #$PR returned an unusable head SHA '$head_sha'; skipping the heal."
    echo "::endgroup::"
    continue
  fi
  if [ "$has_label" != "false" ]; then
    echo "needs-external-review is present on PR #$PR (state: $has_label); nothing to heal."
    echo "::endgroup::"
    continue
  fi
  if ! newest=$(newest_conclusion "$head_sha"); then
    echo "::warning::Could not read the $CHECK_NAME check-runs on PR #$PR head $head_sha; a later clean pass will retry the heal."
    echo "::endgroup::"
    continue
  fi
  if [ "$newest" != "failure" ]; then
    echo "Newest $CHECK_NAME check-run on PR #$PR head $head_sha is '$newest'; nothing to heal."
    echo "::endgroup::"
    continue
  fi
  # Fence and POST as one retried unit (#2205): every attempt re-reads the
  # PR first. A push since the first read means the stale failure is on a head
  # the PR no longer carries, and the new head has not been evaluated by this
  # pass; a label that came back means absence can no longer be claimed.
  if ! outcome=$(with_gh_retry fenced_heal_post "$PR" "$head_sha"); then
    echo "::warning::Failed to post the healing $CHECK_NAME check-run for PR #$PR after retries; the next publisher full pass that finds it failed on this head nominates the PR again (#2205)."
    echo "::endgroup::"
    continue
  fi
  case "$outcome" in
    posted)
      echo "Posted a success $CHECK_NAME check-run on PR #$PR head $head_sha, superseding the stale failure."
      ;;
    moved*)
      echo "PR #$PR head moved from $head_sha to ${outcome#moved } before the heal; skipping."
      ;;
    labeled*)
      echo "needs-external-review reappeared on PR #$PR before the heal (state: ${outcome#labeled }); skipping."
      ;;
    *)
      echo "::warning::Unexpected heal outcome '$outcome' for PR #$PR."
      ;;
  esac
  echo "::endgroup::"
done
