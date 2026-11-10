#!/usr/bin/env bash
# Is a fork or Dependabot PR's trusted feedback-archive relay still pending?
#
# Usage: codex-p1-relay-pending.sh <owner/repo> <pr>
#
# A fork or Dependabot PR event runs the Codex P1 Gate with a read-only
# token, so it cannot persist its archive records or publish the required
# check. It uploads a handoff instead, and the trusted
# codex-feedback-archive-relay.yml workflow_run relay persists the records
# and posts a terminal `mergepath-feedback-archive-relay` marker on the PR.
# Until every such source run has a verified terminal marker, the archive
# the gate reads is incomplete, and no other evaluation may clear the PR.
#
# This is the required-check publisher's copy of the bounded relay-source
# scan in codex-p1-gate.yml's scheduled-sweep job (#2689). It reads the same
# inputs and decides the same way: the PR's fork flag and author, every
# codex-p1-gate.yml run titled `Codex P1 Gate relay-v1 PR #<pr>` since the PR
# was created, for each event that can produce a handoff, bound to the PR by
# feedback-archive-relay-source.sh, then the PR's comments through
# verified-relay-markers.py. The sweep keeps its inline copy until #2224
# removes it. Unlike the sweep, this script never re-runs a stalled relay:
# that needs `actions: write`, which the publisher does not hold, and it
# never clears anything either way.
#
# Exit 0: no relay holds this PR (a same-repository PR whose author is not
#         Dependabot, or every bound source run has a verified terminal
#         marker).
# Exit 1: a bound source run still awaits its relay; withhold clearance.
# Exit 2: the PR, the scan or the marker verification could not be read or
#         exceeded its bound; withhold clearance (fail closed).
# Diagnostics, including each failed gh call's own stderr, go to stderr.

set -euo pipefail

REPO="${1:-}"
PR="${2:-}"
if ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || ! [[ "$PR" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: codex-p1-relay-pending.sh <owner/repo> <pr>" >&2
  exit 2
fi
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MAX_RELAY_SOURCE_RUNS=1000

if ! pr_json=$(gh api "repos/$REPO/pulls/$PR"); then
  echo "Could not read PR #$PR to decide whether its archive relay is required." >&2
  exit 2
fi
if ! is_fork=$(jq -r '.head.repo.fork // false' <<<"$pr_json") \
    || ! pr_actor=$(jq -r '.user.login // ""' <<<"$pr_json") \
    || ! pr_created_at=$(jq -r '.created_at // ""' <<<"$pr_json"); then
  echo "Could not parse PR #$PR to decide whether its archive relay is required." >&2
  exit 2
fi
requires_relay="$is_fork"
if [ "$pr_actor" = 'dependabot[bot]' ]; then
  requires_relay=true
fi
if [ "$requires_relay" != true ]; then
  echo "PR #$PR is a same-repository, non-Dependabot PR; no archive relay applies."
  exit 0
fi

relay_scan_error=false
source_runs='[]'
relay_source_cache=$(mktemp -d "${TMPDIR:-/tmp}/relay-source-cache.XXXXXX")
trap 'rm -rf "$relay_source_cache"' EXIT

# Scheduled runs and other PRs share the gate workflow. Query only event
# kinds that can produce this PR's relay handoff, then apply the fail-closed
# bound after filtering to its exact run title. GitHub caps any filtered
# workflow-run query at 1,000 results, so recursively split a saturated time
# window before accepting it as complete. Unrelated traffic never consumes
# the final matching-run bound.
scan_source_window() {
  local source_event="$1" window_start="$2" window_end="$3"
  local start_iso end_iso source_page source_page_json source_total
  local midpoint matching_source_runs page_runs source_count source_run binding bind_rc bound_run
  [ "$relay_scan_error" != true ] || return 0
  start_iso=$(jq -nr --argjson t "$window_start" '$t | todate')
  end_iso=$(jq -nr --argjson t "$window_end" '$t | todate')
  if ! source_page_json=$(gh api --method GET \
    "repos/$REPO/actions/workflows/codex-p1-gate.yml/runs" \
    -f per_page=100 -f page=1 -f event="$source_event" \
    -f created="$start_iso..$end_iso"); then
    relay_scan_error=true
    return 0
  fi
  source_total=$(jq -r '.total_count // 0' <<<"$source_page_json")
  if [ "$source_total" -ge "$MAX_RELAY_SOURCE_RUNS" ]; then
    if [ "$window_start" -ge "$window_end" ]; then
      echo "Read-only relay source scan saturated the GitHub API ceiling within one second for PR #$PR" >&2
      relay_scan_error=true
      return 0
    fi
    midpoint=$((window_start + (window_end - window_start) / 2))
    scan_source_window "$source_event" "$window_start" "$midpoint"
    scan_source_window "$source_event" "$((midpoint + 1))" "$window_end"
    return 0
  fi

  source_page=1
  while :; do
    if [ "$source_page" -gt 1 ]; then
      if ! source_page_json=$(gh api --method GET \
        "repos/$REPO/actions/workflows/codex-p1-gate.yml/runs" \
        -f per_page=100 -f page="$source_page" -f event="$source_event" \
        -f created="$start_iso..$end_iso"); then
        relay_scan_error=true
        return 0
      fi
    fi
    page_runs='[]'
    if ! matching_source_runs=$(jq -cs \
      --arg title "Codex P1 Gate relay-v1 PR #$PR" '
        if length != 1 then
          error("expected one workflow-runs response")
        else .[0] end |
        if (.workflow_runs | type) != "array" then
          error("workflow_runs is not an array")
        else
          .workflow_runs[] | select(.display_title == $title)
        end
      ' <<<"$source_page_json"); then
      echo "Workflow-runs API response is missing a valid workflow_runs array for PR #$PR" >&2
      relay_scan_error=true
      return 0
    fi
    while IFS= read -r source_run; do
      [ -n "$source_run" ] || continue
      set +e
      binding=$(printf '%s' "$source_run" \
        | MERGEPATH_RELAY_SOURCE_CACHE_DIR="$relay_source_cache" \
          "$SCRIPT_DIR/feedback-archive-relay-source.sh" "$REPO" "$PR")
      bind_rc=$?
      set -e
      if [ "$bind_rc" -eq 0 ]; then
        if [ "$(jq -r '.requires_relay' <<<"$binding")" = true ]; then
          bound_run=$(jq -c '.source_run_id' <<<"$binding")
          page_runs=$(printf '%s\n%s\n' "$page_runs" "$bound_run" \
            | jq -cs '.[0] + [.[1]]')
        fi
      elif [ "$bind_rc" -ne 4 ]; then
        echo "Could not resolve the trusted source binding for a matching run on PR #$PR" >&2
        relay_scan_error=true
        return 0
      fi
      # rc 4 is an unbound title lookalike. It has no authority to hold this
      # PR, so leave it out of the inventory.
    done <<<"$matching_source_runs"
    source_runs=$(printf '%s\n%s\n' "$source_runs" "$page_runs" \
      | jq -cs '.[0] + .[1]')
    source_count=$(jq 'length' <<<"$source_runs")
    if [ "$source_count" -ge "$MAX_RELAY_SOURCE_RUNS" ]; then
      echo "Read-only relay matching source run scan exceeded the fail-closed bound of $MAX_RELAY_SOURCE_RUNS for PR #$PR" >&2
      relay_scan_error=true
      return 0
    fi
    [ $((source_page * 100)) -ge "$source_total" ] && break
    source_page=$((source_page + 1))
  done
}

if ! scan_start_epoch=$(jq -nr --arg t "$pr_created_at" '$t | fromdateiso8601') \
    || ! scan_end_epoch=$(date -u +%s); then
  relay_scan_error=true
else
  for source_event in pull_request pull_request_review pull_request_review_comment issue_comment; do
    scan_source_window "$source_event" "$scan_start_epoch" "$scan_end_epoch"
    [ "$relay_scan_error" != true ] || break
  done
fi
if [ "$relay_scan_error" != true ]; then
  if ! relay_comments=$(gh api --paginate \
      "repos/$REPO/issues/$PR/comments" | jq -s 'add // []'); then
    relay_scan_error=true
  # A failed verifier (exit 2) leaves no JSON to reduce, so stop here rather
  # than feed jq an empty --argjson (#2907).
  elif ! relay_comments=$(printf '%s' "$relay_comments" \
      | python3 "$SCRIPT_DIR/verified-relay-markers.py" --repo "$REPO" --pr "$PR"); then
    relay_scan_error=true
  fi
fi
if [ "$relay_scan_error" = true ]; then
  echo "Trusted read-only feedback-archive source run scan failed closed."
  exit 2
fi

terminal_runs=$(printf '%s' "$relay_comments" | jq -c '[
  .[] | select(.user.login == "github-actions[bot]") | .body // ""
  | try capture("^<!-- mergepath-feedback-archive-relay:v1 run=(?<run>[0-9]+) status=(?<status>complete|failed) -->$").run
    catch empty
  | tonumber
]')
pending_runs=$(jq -c --argjson terminal "$terminal_runs" \
  '[.[] | select(. as $run | ($terminal | index($run)) == null)] | unique' \
  <<<"$source_runs")
if [ "$pending_runs" != '[]' ]; then
  echo "Trusted read-only feedback-archive relay is still pending for source run(s) $(jq -r 'map(tostring) | join(", ")' <<<"$pending_runs"); refusing clearance."
  exit 1
fi
echo "Every bound read-only source run on PR #$PR has a verified terminal relay marker."
exit 0
