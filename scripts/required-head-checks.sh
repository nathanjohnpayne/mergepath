#!/usr/bin/env bash
# Resolve and verify the per-repo required head-check list (#1070).
#
# The VALUE is per-consumer: nathanpaynedotcom gates auto-merge on its own
# `build-and-test` (Codex P1 on #635 -- branch protection does not require
# that context, so this wait is the only thing enforcing it), and no other
# repo has that workflow. Naming it canonically would make the other eight
# consumers wait forever on a check that never runs.
#
# The MECHANISM is fleet-wide and lives here so the workflows that use it stay
# byte-identical across the fleet and the propagation lane keeps verifying
# them verbatim -- and so all three call sites (agent-review.yml,
# dependabot-auto-merge.yml, approval-merge-continuation.sh) share ONE
# implementation rather than three drifting copies.
#
#   --list            print the resolved names, one per line
#   --verify --sha X  exit 0 only if every configured name is green on X
#
# Exit codes: 0 ok / 1 not satisfied / 2 usage / 3 infra (fail closed).

set -euo pipefail

CONFIG_PATH=".github/required-head-checks"
DEFAULT_NAME="lint"

usage() { echo "usage: required-head-checks.sh --repo <owner/repo> (--list | --verify --sha <sha>)" >&2; exit 2; }
infra()  { echo "required-head-checks: ERROR — $*" >&2; exit 3; }

REPO=""; MODE=""; SHA=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)   REPO="${2:-}"; shift 2 ;;
    --sha)    SHA="${2:-}";  shift 2 ;;
    --list)   MODE="list";   shift ;;
    --verify) MODE="verify"; shift ;;
    *) usage ;;
  esac
done
[ -n "$REPO" ] && [ -n "$MODE" ] || usage
[ "$MODE" != "verify" ] || [ -n "$SHA" ] || usage

# ── Resolve ───────────────────────────────────────────────────────────
# Read from the DEFAULT BRANCH, never the PR head or the workspace: on
# `pull_request` the head is contributor-controlled, so a gate that read its
# own requirements from the ref it is gating could be weakened by that ref.
default_branch=$(gh api "repos/$REPO" --jq .default_branch 2>/dev/null) \
  || infra "could not resolve the default branch for $REPO"
[ -n "$default_branch" ] || infra "empty default branch for $REPO"

err_file=$(mktemp "${TMPDIR:-/tmp}/required-head-checks.XXXXXX")
trap 'rm -f "$err_file"' EXIT
set +e
encoded=$(gh api "repos/$REPO/contents/$CONFIG_PATH?ref=$default_branch" --jq .content 2>"$err_file")
read_rc=$?
set -e
err_text=$(cat "$err_file" 2>/dev/null || true)

names=""
if [ "$read_rc" -eq 0 ]; then
  raw=$(printf '%s' "$encoded" | tr -d '\n' | base64 -d 2>/dev/null) \
    || infra "$CONFIG_PATH on $default_branch is not valid base64"
  # Newline-delimited. GitHub check-run names CONTAIN SPACES ("Merge
  # clearance gate", "Label Gate"), so word-splitting would shatter them into
  # names that do not exist and the gate would wait forever.
  names=$(printf '%s\n' "$raw" | sed 's/#.*//' | sed 's/[[:space:]]*$//;s/^[[:space:]]*//' | grep -v '^$' || true)
  if [ -z "$names" ]; then
    # Present but yielding nothing is a misconfiguration, not "no config".
    # Defaulting here would let an emptied file silently drop a configured
    # gate -- the #635 regression this exists to prevent. Delete the file to
    # fall back.
    infra "$CONFIG_PATH exists on $default_branch but yields no check names; delete it to use the default"
  fi
elif printf '%s' "$err_text" | grep -q '404'; then
  # Confirmed absence -> fleet default. `lint` IS correct for every repo
  # without its own build workflow.
  names="$DEFAULT_NAME"
else
  # 403 / rate limit / 5xx / network: INDETERMINATE. Falling back here would
  # silently drop the extra gate on exactly the repo that configured one.
  infra "could not read $CONFIG_PATH on $default_branch (indeterminate, not a 404): ${err_text:-unknown API error}"
fi

if [ "$MODE" = "list" ]; then
  printf '%s\n' "$names"
  exit 0
fi

# ── Verify ────────────────────────────────────────────────────────────
# Grouped by STABLE WORKFLOW IDENTITY, not by check suite. Two groupings are
# wrong in opposite directions:
#
#   * collapsing all same-name runs and taking the latest lets a later
#     success from an UNRELATED workflow mask a pending or failing run of the
#     intended one;
#   * grouping by check SUITE splits repeated dispatches of the SAME workflow
#     into separate groups, so requiring every group green would let one stale
#     failed re-run block the PR forever. Measured: "Merge clearance gate"
#     appears in three suites from ONE workflow (databaseId 291775158) on a
#     single commit.
#
# So: group by workflow, reduce each to its LATEST run for that name, and
# require every distinct workflow to be green.
#
# REST + --paginate rather than GraphQL: a busy commit exceeds a single
# GraphQL page, and a first:100 query with a fail-closed truncation guard
# blocks every merge on exactly the repos that run the most CI. Workflow
# identity comes from joining the Actions runs API on check_suite_id; a check
# run with no matching workflow run (an external app such as CodeRabbit)
# falls back to its suite id, which is its stable identity.
# Workflow identity is not in the check-runs payload, so it comes from the
# Actions runs API keyed on check_suite_id. Fetched ONCE per verification,
# not per name.
suite_map=$(gh api "repos/$REPO/actions/runs?head_sha=$SHA&per_page=100" --paginate \
  --jq '.workflow_runs[] | {suite: .check_suite_id, wf: .workflow_id}' 2>/dev/null) \
  || infra "could not read workflow runs for $SHA"

rc=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  # Filtered per NAME rather than refetching every run on the SHA. This runs
  # inside a poll loop of up to 20 minutes at 15s intervals, and a busy
  # commit carries ~1100 check runs -- refetching all of them ~80 times per
  # PR is how a verifier walks into a secondary rate limit, which this
  # script correctly treats as indeterminate and fails closed on. The
  # cheaper query keeps the gate from breaking the merge it protects.
  runs=$(gh api --method GET "repos/$REPO/commits/$SHA/check-runs" \
    -f check_name="$name" --paginate \
    --jq '.check_runs[] | {name, status, conclusion, suite: .check_suite.id, started: .started_at}' 2>/dev/null) \
    || infra "could not read check runs named '$name' for $SHA"

  verdict=$(jq -n -r --arg n "$name" \
    --slurpfile r <(printf '%s\n' "$runs") \
    --slurpfile m <(printf '%s\n' "$suite_map") '
    ($m | map({key: (.suite|tostring), value: (.wf|tostring)}) | from_entries) as $bysuite
    | [ $r[] | select(.name == $n)
        | . + {wf: ($bysuite[(.suite|tostring)] // ("suite:" + (.suite|tostring)))} ]
    | if length == 0 then "absent"
      else
        group_by(.wf)
        # Any non-completed run in a group means that workflow is still
        # working, regardless of ordering. Reducing to the latest FIRST
        # would miss a queued re-run whose started_at is null and therefore
        # does not sort last -- reporting green while a re-run is pending.
        | map(if any(.status != "completed") then "pending"
              else (sort_by(.started) | last
                    | if (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped")
                      then "green" else "failed" end)
              end)
        | if any(. == "pending") then "pending"
          elif all(. == "green") then "green"
          else "failed" end
      end')
  case "$verdict" in
    green) echo "required-head-checks: OK   $name" ;;
    *)     echo "required-head-checks: WAIT $name ($verdict)"; rc=1 ;;
  esac
done <<EOF
$names
EOF
exit "$rc"
