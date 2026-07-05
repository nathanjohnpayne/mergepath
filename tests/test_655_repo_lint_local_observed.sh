#!/usr/bin/env bash
# tests/test_655_repo_lint_local_observed.sh
#
# Structural regression guard for #655: a consumer's optional, never-
# propagated repo_lint_local.yml annex (#601) produces a `repo-lint-local`
# check run that branch protection does not require. Before this fix,
# neither the native auto-merge path (agent-review.yml's "Require current-
# head check success" step, hardcoded to the single `lint` check) nor the
# needs-external-review label-clearing re-evaluation trigger
# (auto-clear-blocking-labels.yml's workflow_run list) observed it, so a
# consumer could auto-merge or auto-clear with local checks red. (The
# third, deepest site — codex-review-check.sh gate (a), the script BOTH of
# these ultimately rely on for "is CI green" — has its own execution-level
# test in test_codex_review_check_required_checks.sh.)
#
# The workflow files here cannot be unit-executed without a full Actions
# runner (same posture as test_465_fail_closed.sh), so this suite asserts
# each invariant is present in source, plus a bash-syntax check on every
# agent-review.yml `run:` block (auto-clear-blocking-labels.yml already has
# its own equivalent syntax check in scripts/ci/check_auto_clear_workflow).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

SKIP=0
# Propagation-safe: a consumer that does not carry a given workflow simply
# has nothing to regress, so skip (not fail) when the file is absent.
assert_grep() {  # <label> <file> <fixed-string>
  if [ ! -f "$2" ]; then echo "SKIP: $1 ($2 absent)"; SKIP=$((SKIP + 1)); return; fi
  if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing in $2: $3)"; fi
}

W=.github/workflows

# agent-review.yml: the required-check wait probes the PR HEAD commit for
# the annex file via the Contents API (not the job's own checkout) and
# conditionally requires the repo-lint-local check run alongside lint.
assert_grep "agent-review: probes for the repo_lint_local.yml annex at the PR HEAD commit (#655)" \
  "$W/agent-review.yml" 'repos/$REPO/contents/.github/workflows/repo_lint_local.yml?ref=$sha'
assert_grep "agent-review: conditionally adds repo-lint-local to the required-check set (#655)" \
  "$W/agent-review.yml" 'name: "repo-lint-local", workflow: ""'
assert_grep "agent-review: the wait loop iterates over the required_checks_json array, not one hardcoded name" \
  "$W/agent-review.yml" 'for ((i = 0; i < check_count; i++)); do'

# Codex P1 (#655 round 1): an indeterminate annex-probe read (token scope,
# rate limit, transient error) must fail closed (assume present), not be
# treated the same as a confirmed 404 absence.
assert_grep "agent-review: distinguishes a confirmed 404 (annex genuinely absent) from other errors" \
  "$W/agent-review.yml" "grep -q 'HTTP 404' \"\$annex_probe_err\""
assert_grep "agent-review: fails closed (requires the conventional check name) on a non-404 annex-probe error" \
  "$W/agent-review.yml" 'Could not determine whether repo_lint_local.yml exists'

# Codex P2 (#655 round 1): the annex contract does not mandate the job (and
# therefore check-run) name be literally repo-lint-local, so the probe
# derives the actual job name(s) from the annex YAML instead of assuming
# the filename convention, falling back to the convention only when nothing
# could be parsed.
assert_grep "agent-review: derives the annex job name(s) from its YAML rather than assuming the filename" \
  "$W/agent-review.yml" 'doc["jobs"].each do |id, job|'

# Codex P2 (#655 round 2): success/skipped/neutral are all non-blocking
# conclusions for a required check (matching codex-review-check.sh's own
# BAD_CHECKS acceptance set) -- a conditional annex job GitHub completes as
# skipped must not time out or abort native auto-merge. Values are the
# GraphQL statusCheckRollup enum casing (#655 round 4 data-source switch).
assert_grep "agent-review: accepts SKIPPED and NEUTRAL annex-job conclusions, not just SUCCESS" \
  "$W/agent-review.yml" '[ "$conclusion" != "SUCCESS" ] && [ "$conclusion" != "SKIPPED" ] && [ "$conclusion" != "NEUTRAL" ]'

# Codex P2 (#655 round 3): a matrix-strategy annex job expands into check-run
# names this static YAML read cannot reproduce -- skip it during derivation
# (permanently waiting on a name that will never report is worse than not
# observing that job at all) instead of guessing the unexpanded name.
assert_grep "agent-review: skips matrix-strategy annex jobs during derivation instead of guessing their expanded name(s)" \
  "$W/agent-review.yml" 'job["strategy"].is_a?(Hash) && job["strategy"]["matrix"]'

# Codex P2 (#655 round 4): a 403 (token lacks Contents: read) is usually
# persistent, unlike other indeterminate errors -- forcing the synthetic
# fallback here would permanently block native auto-merge on every future
# PR, not just annex-having ones. Do not fail closed on a confirmed 403.
assert_grep "agent-review: does not fail closed on a confirmed 403 (likely a persistent token-scope gap, not transient)" \
  "$W/agent-review.yml" "grep -q 'HTTP 403' \"\$annex_probe_err\""

# Codex P2 (#655 round 4): "could not parse the YAML at all" (ruby exits
# before its `puts` line -- empty output) is a different failure mode from
# "parsed fine but every job was matrix-strategy and skipped" (ruby emits
# the literal empty array "[]") -- only the former falls back to the
# conventional name; the latter must not, since that name will never exist
# for a matrix-only annex and would permanently block auto-merge.
assert_grep "agent-review: distinguishes genuine YAML-parse failure from a valid parse where every job was matrix-skipped" \
  "$W/agent-review.yml" 'every job is matrix-strategy (skipped)'

# Codex P2 (#655 round 4): the annex contract does not require unique job
# names, so matching must disambiguate by workflow (not name alone) via the
# same statusCheckRollup data source codex-review-check.sh's gate (a) uses
# (switched from the check-runs REST endpoint, which has no workflow-name
# field), picking the latest run per (name, workflow) pair.
assert_grep "agent-review: disambiguates required checks by (name, workflow) via statusCheckRollup" \
  "$W/agent-review.yml" 'select($workflow == "" or (.workflowName // "") == $workflow)'
assert_grep "agent-review: picks the latest run per check (duplicate push+synchronize triggers can both report)" \
  "$W/agent-review.yml" 'sort_by(.startedAt // .completedAt // "")'

# auto-clear-blocking-labels.yml: the workflow_run trigger list observes the
# annex's completion too (verified against a live consumer's repo_lint_local.yml
# workflow name, per #655).
assert_grep "auto-clear: workflow_run trigger list includes repo-lint-local (#655)" \
  "$W/auto-clear-blocking-labels.yml" '- "repo-lint-local"'

# ── Bash syntax check on every agent-review.yml `run:` block. Catches
#    heredoc/subshell/loop errors the grep assertions above cannot (mirrors
#    check_auto_clear_workflow's equivalent check for its own file — no
#    such check previously existed for agent-review.yml).
echo
echo "agent-review.yml bash syntax test"

if [ -f "$W/agent-review.yml" ]; then
  block_dir=$(mktemp -d)
  awk -v outdir="$block_dir" '
    /^[[:space:]]+run:[[:space:]]+\|[[:space:]]*$/ {
      if (in_run) { close(outfile) }
      n++; outfile = outdir "/block-" n ".sh"
      match($0, /^[[:space:]]+/); base_indent = RLENGTH
      in_run = 1; next
    }
    in_run && NF == 0 { print > outfile; next }
    in_run {
      match($0, /^[[:space:]]*/); cur_indent = RLENGTH
      if (cur_indent <= base_indent) {
        close(outfile); in_run = 0; next
      }
      sub("^[[:space:]]{" (base_indent + 2) "}", "")
      print > outfile
    }
    END { if (in_run) close(outfile) }
  ' "$W/agent-review.yml"

  extracted_count=$(ls -1 "$block_dir" 2>/dev/null | wc -l | tr -d ' ')
  syntax_errors=0
  for f in "$block_dir"/block-*.sh; do
    [ -f "$f" ] || continue
    if ! err=$(bash -n "$f" 2>&1); then
      fail "bash syntax error in $(basename "$f") (agent-review.yml)"
      echo "$err" | sed 's/^/    /' >&2
      syntax_errors=$((syntax_errors + 1))
    fi
  done
  rm -rf "$block_dir"

  if [ "$syntax_errors" -eq 0 ] && [ "$extracted_count" -gt 0 ]; then
    pass "all $extracted_count agent-review.yml run blocks have valid bash syntax"
  elif [ "$extracted_count" = "0" ]; then
    fail "extracted 0 run blocks from agent-review.yml (extraction logic broken?)"
  fi
else
  echo "SKIP: agent-review.yml bash syntax test (file absent)"; SKIP=$((SKIP + 1))
fi

echo ""
echo "test_655_repo_lint_local_observed: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
