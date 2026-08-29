#!/usr/bin/env bash
# tests/test_ci_scripts_wired.sh
#
# Unit tests for scripts/ci/check_ci_scripts_wired — the structural
# guard added in #269 that fails closed when an executable
# scripts/ci/check_* file is missing from .github/workflows/repo_lint.yml.
#
# Each case sets up a scratch directory with a synthetic
# scripts/ci/ tree + a minimal .github/workflows/repo_lint.yml and
# invokes the real check script with REPO_ROOT pointing at the
# scratch dir (the script computes REPO_ROOT relative to its own
# location, so we copy the script into the scratch dir for each
# case).
#
# Bash 3.2 portable. Follows the test_gh_pr_guard.sh scaffolding
# pattern.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/ci/check_ci_scripts_wired"

[[ -x "$CHECK" ]] || { echo "missing or non-executable $CHECK" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ci-scripts-wired-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a scratch fake-repo and copy the real check script into the
# matching scripts/ci/ location so REPO_ROOT resolves correctly.
# Args:
#   $1 — case name (subdir under WORKDIR)
# Returns the scratch repo root via stdout.
make_scratch_repo() {
  local case_name="$1"
  local repo="$WORKDIR/$case_name"
  mkdir -p "$repo/scripts/ci" "$repo/.github/workflows"
  cp "$CHECK" "$repo/scripts/ci/check_ci_scripts_wired"
  chmod +x "$repo/scripts/ci/check_ci_scripts_wired"
  printf '%s' "$repo"
}

# Write an executable check_* stub at scripts/ci/<name>.
mk_check() {
  local repo="$1"
  local name="$2"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/scripts/ci/$name"
  chmod +x "$repo/scripts/ci/$name"
}

# Write a non-executable check_* file at scripts/ci/<name>.
mk_check_nonexec() {
  local repo="$1"
  local name="$2"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/scripts/ci/$name"
  chmod -x "$repo/scripts/ci/$name"
}

# Write a workflow file from a heredoc-passed body.
mk_workflow() {
  local repo="$1"
  local body="$2"
  printf '%s\n' "$body" >"$repo/.github/workflows/repo_lint.yml"
}

# Write the consumer-local annex (#601) from a heredoc-passed body.
mk_annex() {
  local repo="$1"
  local body="$2"
  printf '%s\n' "$body" >"$repo/.github/workflows/repo_lint_local.yml"
}

run_check() {
  local repo="$1"
  ( cd "$repo" && bash "$repo/scripts/ci/check_ci_scripts_wired" )
}

# ---------------------------------------------------------------------------
# Case 1: all wired → pass.
# Two checks on disk, both have explicit `run:` lines in the workflow.
# Note: check_ci_scripts_wired itself is always on disk in the scratch
# repo, so the workflow must also wire it.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case1_all_wired)"
mk_check "$repo" check_foo
mk_check "$repo" check_bar
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
      - name: check_bar
        run: ./scripts/ci/check_bar
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "all wired: exit 0"
else
  fail "all wired: exit $rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 2: one missing → fail with the specific missing name in output.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case2_one_missing)"
mk_check "$repo" check_foo
mk_check "$repo" check_bar
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  fail "one missing: expected nonzero exit, got 0; output: $out"
elif ! echo "$out" | grep -q "check_bar"; then
  fail "one missing: diagnostic does not name check_bar; output: $out"
else
  pass "one missing: fails closed and names check_bar"
fi

# ---------------------------------------------------------------------------
# Case 3: duplicate workflow entry → pass (not an error).
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case3_duplicate)"
mk_check "$repo" check_foo
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
      - name: check_foo_again
        run: ./scripts/ci/check_foo
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "duplicate entry: pass (inefficient but not a correctness failure)"
else
  fail "duplicate entry: expected exit 0, got $rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 4: comment-only mention of a script → NOT counted as wired.
# The workflow references check_foo only inside a comment line; the
# check must still flag it as missing.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case4_comment_only)"
mk_check "$repo" check_foo
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      # The next step covers ./scripts/ci/check_foo behavior — note
      # this is a COMMENT, not a real wiring.
      - name: something_else
        run: echo unrelated
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  fail "comment-only mention: expected fail, comment should not count as wired; output: $out"
elif ! echo "$out" | grep -q "check_foo"; then
  fail "comment-only mention: diagnostic does not name check_foo; output: $out"
else
  pass "comment-only mention: NOT counted as wired"
fi

# ---------------------------------------------------------------------------
# Case 5 (#269 r5 — nathanpayne-codex Phase 4b finding): non-executable
# check files are STILL required to be wired or exempted. The earlier
# r3-r4 spec carved them out as "WIP skip", but the repo_lint.yml
# workflow runs `chmod +x scripts/ci/*` BEFORE this guard, so on CI
# every check_* is executable regardless of pre-chmod perms. Aligning
# the guard with production reality is more honest than enforcing a
# contract the workflow order silently breaks.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case5_nonexec)"
mk_check "$repo" check_foo
mk_check_nonexec "$repo" check_not_ready_yet
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "check_not_ready_yet"; then
  pass "non-executable check file: still required to be wired (r5 — workflow chmods regardless of pre-state)"
else
  fail "non-executable check file: expected exit 1 with 'check_not_ready_yet' in diagnostic, got rc=$rc; output: $out"
fi

# Same fixture, now wired → PASS regardless of executable bit.
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
      - name: check_not_ready_yet
        run: ./scripts/ci/check_not_ready_yet
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "non-executable check file: wired → passes regardless of perm bit"
else
  fail "non-executable wired-and-on-disk: expected exit 0, got $rc; output: $out"
fi

# Same fixture, exempted via WIRED-EXEMPT → PASS.
mk_workflow "$repo" "name: t
jobs:
  lint:
    # WIRED-EXEMPT: check_not_ready_yet — intentionally pending
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "non-executable check file: WIRED-EXEMPT honored as escape hatch"
else
  fail "non-executable + WIRED-EXEMPT: expected exit 0, got $rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 6 (#601): consumer-local annex — a check wired ONLY in
# .github/workflows/repo_lint_local.yml counts as wired. This is the
# consumer path: repo_lint.yml is manifest-canonical, so a consumer's
# own check_* is wired in the never-propagated annex instead.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case6_annex_wired)"
mk_check "$repo" check_foo
mk_check "$repo" check_consumer_local
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
mk_annex "$repo" "name: t-local
on:
  pull_request:
jobs:
  lint-local:
    steps:
      - name: check_consumer_local
        run: ./scripts/ci/check_consumer_local
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "annex-only wiring: check wired only in repo_lint_local.yml counts as wired"
else
  fail "annex-only wiring: expected exit 0, got $rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 7 (#601): annex present but the check is wired in NEITHER file →
# still fails closed and names the check. The annex must not blanket-
# satisfy the guard just by existing.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case7_annex_unwired)"
mk_check "$repo" check_foo
mk_check "$repo" check_nowhere
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
mk_annex "$repo" "name: t-local
on:
  pull_request:
jobs:
  lint-local:
    steps:
      - name: something_else
        run: echo unrelated
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "check_nowhere"; then
  pass "annex present, unwired in both: fails closed and names check_nowhere"
else
  fail "annex present, unwired in both: expected nonzero exit naming check_nowhere, got rc=$rc; output: $out"
fi

# Comment-only mention in the ANNEX must not count as wired either
# (same trap as Case 4, annex edition).
mk_annex "$repo" "name: t-local
on:
  pull_request:
# the annex talks about ./scripts/ci/check_nowhere in a comment only
jobs:
  lint-local:
    steps:
      - name: something_else
        run: echo unrelated
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "check_nowhere"; then
  pass "annex comment-only mention: NOT counted as wired"
else
  fail "annex comment-only mention: expected nonzero exit naming check_nowhere, got rc=$rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 7b (#624 Codex P2, fails pre-fix): annex SHAPE gate. An annex that
# Actions never runs cannot satisfy the wiring contract — a shapeless annex
# (no on: block) used to mark its checks wired anyway. Now: hard FAIL
# naming the trigger contract.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case7b_annex_no_trigger)"
mk_check "$repo" check_foo
mk_check "$repo" check_consumer_local
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
mk_annex "$repo" "name: t-local
jobs:
  lint-local:
    steps:
      - name: check_consumer_local
        run: ./scripts/ci/check_consumer_local
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "no push/pull_request trigger"; then
  pass "annex without any on: trigger is rejected — cannot satisfy wiring (#624)"
else
  fail "shapeless annex accepted (rc=$rc); output: $out"
fi

# Case 7c (#624): a manual-only (workflow_dispatch) annex is likewise not a
# wiring vehicle — it never runs on pushes or PRs.
repo="$(make_scratch_repo case7c_annex_dispatch_only)"
mk_check "$repo" check_foo
mk_check "$repo" check_consumer_local
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
mk_annex "$repo" "name: t-local
on:
  workflow_dispatch:
jobs:
  lint-local:
    steps:
      - name: check_consumer_local
        run: ./scripts/ci/check_consumer_local
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "no push/pull_request trigger"; then
  pass "workflow_dispatch-only annex is rejected — not a wiring vehicle (#624)"
else
  fail "dispatch-only annex accepted (rc=$rc); output: $out"
fi

# Case 7d (#624): push-trigger annex is a valid wiring vehicle (positive
# control for the shape gate; case 6 covers pull_request).
repo="$(make_scratch_repo case7d_annex_push)"
mk_check "$repo" check_foo
mk_check "$repo" check_consumer_local
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
mk_annex "$repo" "name: t-local
on:
  push:
jobs:
  lint-local:
    steps:
      - name: check_consumer_local
        run: ./scripts/ci/check_consumer_local
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "push-trigger annex satisfies wiring (shape-gate positive control) (#624)"
else
  fail "push-trigger annex rejected (rc=$rc); output: $out"
fi

# ---------------------------------------------------------------------------
# Case 8 (#601): WIRED-EXEMPT honored from the annex — a consumer can
# exempt a consumer-local check without touching the canonical file.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case8_annex_exempt)"
mk_check "$repo" check_foo
mk_check "$repo" check_local_pending
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
mk_annex "$repo" "name: t-local
on:
  pull_request:
# WIRED-EXEMPT: check_local_pending — consumer-local, intentionally pending
jobs: {}
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  pass "annex WIRED-EXEMPT: exemption honored from repo_lint_local.yml"
else
  fail "annex WIRED-EXEMPT: expected exit 0, got $rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 9 (#601): annex ABSENT → behavior identical to the single-file
# scan (regression guard for the pre-#601 contract). Identical fixture
# to Case 2 (one missing check), no annex on disk: same failure, same
# diagnostic.
# ---------------------------------------------------------------------------
repo="$(make_scratch_repo case9_no_annex_baseline)"
mk_check "$repo" check_foo
mk_check "$repo" check_bar
mk_workflow "$repo" "name: t
jobs:
  lint:
    steps:
      - name: check_ci_scripts_wired
        run: ./scripts/ci/check_ci_scripts_wired
      - name: check_foo
        run: ./scripts/ci/check_foo
"
set +e
out=$(run_check "$repo" 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "check_bar" && [[ ! -f "$repo/.github/workflows/repo_lint_local.yml" ]]; then
  pass "annex absent: single-file behavior preserved (fails closed, names check_bar)"
else
  fail "annex absent: expected nonzero exit naming check_bar with no annex on disk, got rc=$rc; output: $out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "test_ci_scripts_wired: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
