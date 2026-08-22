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
runs=$(gh api "repos/$REPO/commits/$SHA/check-runs" --paginate \
  --jq '.check_runs[] | {name, status, conclusion, suite: .check_suite.id, started: .started_at}' 2>/dev/null) \
  || infra "could not read check runs for $SHA"

rc=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  # Group by check SUITE and require EVERY suite that produced this name to
  # have a successful LATEST run. Collapsing same-name runs and taking
  # whichever started last lets a later success from an unrelated workflow
  # mask the intended workflow's pending or failing run.
  verdict=$(printf '%s\n' "$runs" | jq -rs --arg n "$name" '
    [ .[] | select(.name == $n) ]
    | if length == 0 then "absent"
      else
        group_by(.suite)
        | map(sort_by(.started) | last)
        | if any(.status != "completed") then "pending"
          elif all(.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped") then "green"
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
