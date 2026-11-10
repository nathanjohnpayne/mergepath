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
#   --verify --sha X --branch-requirements FILE
#                     also require every rule in FILE, a `known` result of
#                     scripts/lib/branch-requirements.sh's br_required_checks
#                     that the CALLER resolved (#2722). Each rule is judged on
#                     X by the same workflow-grouped check-run reduction, plus
#                     the legacy commit-status surface for a rule any producer
#                     can satisfy. Anything but a `known` result is exit 3,
#                     never "nothing required".
#
# Exit codes: 0 ok / 1 not satisfied / 2 usage / 3 infra (fail closed).

set -euo pipefail

CONFIG_PATH=".github/required-head-checks"
DEFAULT_NAME="lint"

usage() { echo "usage: required-head-checks.sh --repo <owner/repo> (--list | --verify --sha <sha> [--branch-requirements <file>])" >&2; exit 2; }
infra()  { echo "required-head-checks: ERROR — $*" >&2; exit 3; }

REPO=""; MODE=""; SHA=""; BRANCH_REQUIREMENTS_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)   REPO="${2:-}"; shift 2 ;;
    --sha)    SHA="${2:-}";  shift 2 ;;
    --list)   MODE="list";   shift ;;
    --verify) MODE="verify"; shift ;;
    --branch-requirements) BRANCH_REQUIREMENTS_FILE="${2:-}"; [ -n "$BRANCH_REQUIREMENTS_FILE" ] || usage; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$REPO" ] && [ -n "$MODE" ] || usage
[ "$MODE" != "verify" ] || [ -n "$SHA" ] || usage
[ -z "$BRANCH_REQUIREMENTS_FILE" ] || [ "$MODE" = "verify" ] || usage

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
# The branch rules, when given, are validated before any read: a file that is
# not a `known` br_required_checks result says nothing about what the branch
# requires, so it is an indeterminate input, not an empty requirement list.
# One compact {context, app_id} object per line.
requirement_lines=""
if [ -n "$BRANCH_REQUIREMENTS_FILE" ]; then
  [ -r "$BRANCH_REQUIREMENTS_FILE" ] || infra "branch requirements file '$BRANCH_REQUIREMENTS_FILE' is unreadable"
  requirement_lines=$(jq -c '
    if type == "object" and .state == "known" and (.requirements | type) == "array"
       and all(.requirements[]; type == "object"
               and (.context | type) == "string" and (.context | length) > 0
               and (.app_id == null or ((.app_id | type) == "string" and (.app_id | length) > 0)))
    then .requirements[] | {context, app_id}
    else error("not a known br_required_checks result") end' "$BRANCH_REQUIREMENTS_FILE" 2>/dev/null) \
    || infra "branch requirements in '$BRANCH_REQUIREMENTS_FILE' are not a known br_required_checks result; refusing to read them as nothing required"
fi

RUNS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/head-check-runs.sh"
[ -r "$RUNS_LIB" ] || infra "missing shared check-run reducer"
# shellcheck source=lib/head-check-runs.sh
. "$RUNS_LIB"
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
suite_json=$(printf '%s\n' "$suite_map" | jq -s '.') || infra "could not parse workflow runs for $SHA"

rc=0
# Each name's check runs, fetched once per verification and reused by a branch
# rule naming the same context (#2722), keyed by name.
fetched='{}'
while IFS= read -r name; do
  [ -n "$name" ] || continue
  # Filtered per NAME rather than refetching every run on the SHA. This runs
  # inside a poll loop of up to 20 minutes, and a busy
  # commit carries ~1100 check runs -- refetching all of them ~80 times per
  # PR is how a verifier walks into a secondary rate limit, which this
  # script correctly treats as indeterminate and fails closed on. The
  # cheaper query keeps the gate from breaking the merge it protects.
  runs=$(gh api --method GET "repos/$REPO/commits/$SHA/check-runs" \
    -f check_name="$name" --paginate \
    --jq '.check_runs[] | {name, status, conclusion, suite: .check_suite.id, started_at, app: .app.id}' 2>/dev/null) \
    || infra "could not read check runs named '$name' for $SHA"
  runs_json=$(printf '%s\n' "$runs" | jq -s '.') || infra "could not parse check runs named '$name'"
  fetched=$(jq -c --arg n "$name" --argjson r "$runs_json" '. + {($n): $r}' <<<"$fetched") \
    || infra "could not record check runs named '$name'"
  summary=$(head_check_runs_reduce "$name" <(printf '%s\n' "$runs_json") <(printf '%s\n' "$suite_json")) \
    || infra "could not reduce check runs named '$name'"
  verdict=$(jq -r '.state' <<<"$summary")
  case "$verdict" in
    green) echo "required-head-checks: OK   $name" ;;
    *)     echo "required-head-checks: WAIT $name ($verdict)"; rc=1 ;;
  esac
done <<EOF
$names
EOF

# ── Branch rules (#2722) ──────────────────────────────────────────────
# Each rule is one requirement GitHub evaluates on its own (see the contract
# in scripts/lib/branch-requirements.sh): a rule pinned to an app counts only
# that app's check runs; a rule any producer satisfies counts every check run
# of the name AND the legacy commit statuses of the name, because GitHub
# accepts either surface and, when a head carries both, holds the merge until
# both are green (#1193). A rule with no result on either surface is absent.
# Check runs reduce exactly as the configured names above do, so success,
# neutral and skipped count as green, and an in-flight run is pending.
if [ -n "$requirement_lines" ]; then
  statuses_json='[]'
  if printf '%s\n' "$requirement_lines" | jq -e -s 'any(.[]; .app_id == null)' >/dev/null; then
    statuses=$(gh api "repos/$REPO/commits/$SHA/statuses?per_page=100" --paginate \
      --jq '.[] | {context, state, id}' 2>/dev/null) \
      || infra "could not read commit statuses for $SHA"
    statuses_json=$(printf '%s\n' "$statuses" | jq -s '.') || infra "could not parse commit statuses for $SHA"
  fi
  while IFS= read -r requirement; do
    [ -n "$requirement" ] || continue
    ctx=$(jq -r '.context' <<<"$requirement")
    app=$(jq -r '.app_id // ""' <<<"$requirement")
    if ! all_runs=$(jq -ce --arg n "$ctx" '.[$n]' <<<"$fetched"); then
      runs=$(gh api --method GET "repos/$REPO/commits/$SHA/check-runs" \
        -f check_name="$ctx" --paginate \
        --jq '.check_runs[] | {name, status, conclusion, suite: .check_suite.id, started_at, app: .app.id}' 2>/dev/null) \
        || infra "could not read check runs named '$ctx' for $SHA"
      all_runs=$(printf '%s\n' "$runs" | jq -s '.') || infra "could not parse check runs named '$ctx'"
      fetched=$(jq -c --arg n "$ctx" --argjson r "$all_runs" '. + {($n): $r}' <<<"$fetched") \
        || infra "could not record check runs named '$ctx'"
    fi
    runs_json=$(jq -c --arg app "$app" \
      'if $app == "" then . else map(select((.app // "" | tostring) == $app)) end' <<<"$all_runs") \
      || infra "could not filter check runs named '$ctx'"
    check_state=$(head_check_runs_reduce "$ctx" <(printf '%s\n' "$runs_json") <(printf '%s\n' "$suite_json") | jq -r '.state') \
      || infra "could not reduce check runs named '$ctx'"
    status_state=absent
    if [ -z "$app" ]; then
      status_state=$(jq -r --arg n "$ctx" '
        [.[] | select(.context == $n)]
        | if length == 0 then "absent"
          else (max_by(.id) | .state
                | if . == "success" then "green" elif . == "pending" then "pending" else "failed" end)
          end' <<<"$statuses_json") || infra "could not reduce commit statuses named '$ctx'"
    fi
    if [ "$check_state" = absent ] && [ "$status_state" = absent ]; then
      verdict=absent
    elif [ "$check_state" = pending ] || [ "$status_state" = pending ]; then
      verdict=pending
    elif { [ "$check_state" = green ] || [ "$check_state" = absent ]; } && \
         { [ "$status_state" = green ] || [ "$status_state" = absent ]; }; then
      verdict=green
    else
      verdict=failed
    fi
    label="$ctx (required by the branch rules${app:+, app $app})"
    case "$verdict" in
      green) echo "required-head-checks: OK   $label" ;;
      *)     echo "required-head-checks: WAIT $label ($verdict)"; rc=1 ;;
    esac
  done <<EOF
$requirement_lines
EOF
fi
exit "$rc"
