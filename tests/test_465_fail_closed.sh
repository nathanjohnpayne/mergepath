#!/usr/bin/env bash
# Structural regression guards for the #465 fail-open / early-clear fixes,
# plus the #530 non-idempotent comment-POST and #548 checkout-hardening
# invariants (cross-workflow, source-level assertions; propagation-safe via
# the assert_grep/refute_grep SKIP-if-absent contract).
#
# The six defects span four YAML workflows and two shell scripts; the
# workflow ones cannot be unit-executed without a full Actions runner, so
# this suite asserts each fail-closed invariant is present in source. The
# scripts' overall behavior stays covered by the existing execution suites
# (test_merge_clearance_gate.sh, test_codex_review_check_resolution.sh,
# test_codex_review_request_ack.sh).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

SKIP=0
# Propagation-safe: a consumer that does not carry a given workflow/script
# simply has nothing to regress, so skip (not fail) when the file is absent.
assert_grep() {  # <label> <file> <fixed-string>
  if [ ! -f "$2" ]; then echo "SKIP: $1 ($2 absent)"; SKIP=$((SKIP + 1)); return; fi
  # `--` so a pattern starting with `-`/`--` is not mis-read as a grep flag.
  if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing in $2: $3)"; fi
}
refute_grep() {  # <label> <file> <fixed-string-that-must-be-absent>
  if [ ! -f "$2" ]; then echo "SKIP: $1 ($2 absent)"; SKIP=$((SKIP + 1)); return; fi
  if grep -qF -- "$3" "$2"; then fail "$1 (still present in $2: $3)"; else pass "$1"; fi
}

W=.github/workflows

# Defect 1: head_sha is sourced from the list query (so a check_run can
# always be posted); a missing SHA flags infra error rather than skipping,
# and the fragile per-PR head_sha resolve is gone (#465 + r2).
assert_grep "D1: merge-clearance sources head_sha from the list query" \
  "$W/merge-clearance-gate.yml" '--json number,headRefOid'
assert_grep "D1: merge-clearance head-SHA failure flags infra error" \
  "$W/merge-clearance-gate.yml" 'cannot refresh its Merge clearance gate'
refute_grep "D1: merge-clearance no longer does a fragile per-PR head_sha resolve" \
  "$W/merge-clearance-gate.yml" 'head_sha=$(gh api "repos/$REPO/pulls/'
refute_grep "D1: merge-clearance no longer silently skips on unresolved head SHA" \
  "$W/merge-clearance-gate.yml" 'Could not resolve head SHA for PR #$PR; skipping'

# Defect 2: no unconditional immediate-merge fallback when --auto is unavailable.
refute_grep "D2: agent-review dropped the '|| gh pr merge --squash' immediate fallback" \
  "$W/agent-review.yml" '--auto "$PR_URL" || gh pr merge --squash "$PR_URL"'
assert_grep "D2: agent-review fails closed when auto-merge cannot be enabled" \
  "$W/agent-review.yml" 'refusing to merge unconditionally'

# Defect 3: label removal verifies end-state instead of retrying the non-idempotent write.
assert_grep "D3: auto-clear verifies label end-state (still_present)" \
  "$W/auto-clear-blocking-labels.yml" 'still_present'
refute_grep "D3: auto-clear no longer retries the --remove-label write" \
  "$W/auto-clear-blocking-labels.yml" 'with_gh_retry gh pr edit "$PR" --repo "$REPO" --remove-label needs-external-review'
# #530: the attribution-comment POST is non-idempotent (a retry after a
# timeout-after-accept duplicates the comment), so it must NOT be retried;
# the idempotent (name,head_sha) check-run POSTs stay wrapped.
refute_grep "D3: auto-clear no longer retries the non-idempotent comment POST (#530)" \
  "$W/auto-clear-blocking-labels.yml" 'with_gh_retry gh pr comment "$PR" --repo "$REPO" --body "$comment_body"'
assert_grep "D3: auto-clear keeps check-run POSTs retried (idempotent name,head_sha) (#530)" \
  "$W/auto-clear-blocking-labels.yml" 'with_gh_retry gh api "repos/$REPO/check-runs"'

# Defect 4: codex-review-request re-scans at the deadline before emitting.
assert_grep "D4: codex-review-request final scan at deadline" \
  scripts/codex-review-request.sh 'Final scan at the deadline'
refute_grep "D4: codex-review-request no longer breaks on timeout without a final scan" \
  scripts/codex-review-request.sh 'TIMEOUT after ${ELAPSED}s — no Codex review or reaction on HEAD'

# Defect 5: daily-feedback-rollup pins checkout to the trusted default branch.
assert_grep "D5: daily-feedback-rollup pins checkout ref" \
  "$W/daily-feedback-rollup.yml" 'ref: ${{ github.event.repository.default_branch }}'

# Defect 6: gate (a) distinguishes unreadable (403/5xx, fail closed) from 404 (none required).
assert_grep "D6: codex-review-check distinguishes protection readability" \
  scripts/codex-review-check.sh 'protection_readable'
assert_grep "D6: codex-review-check tells 404 apart via HTTP status" \
  scripts/codex-review-check.sh 'HTTP 404'
refute_grep "D6: codex-review-check dropped the unconditional skip-all-checks fail-open" \
  scripts/codex-review-check.sh 'Skipping required-check filter — all checks treated as passing this gate.'

# Defect 7 (#548): every dispatchable-privileged checkout pins the trusted
# default branch (blocks a manually-dispatched branch from running tampered
# repo code under a privileged PAT), and checkouts with no authenticated-git
# path drop the persisted checkout token (defense-in-depth).
assert_grep "D7: weekly-feedback-sweep pins checkout ref (#548 Major)" \
  "$W/weekly-feedback-sweep.yml" 'ref: ${{ github.event.repository.default_branch }}'
assert_grep "D7: weekly-feedback-sweep drops the persisted checkout token (#548)" \
  "$W/weekly-feedback-sweep.yml" 'persist-credentials: false'
# Both checkouts (main sweep + the notify-on-failure job) must drop the token,
# so the #548 invariant holds for the WHOLE file (Codex #550 P2 caught that the
# failure-notify checkout was initially missed). Propagation-safe: skip if absent.
if [ -f "$W/weekly-feedback-sweep.yml" ]; then
  _wfs_pc=$(grep -c 'persist-credentials: false' "$W/weekly-feedback-sweep.yml")
  if [ "$_wfs_pc" -ge 2 ]; then
    pass "D7: weekly-feedback-sweep hardens BOTH checkouts (#548 / Codex #550)"
  else
    fail "D7: weekly-feedback-sweep both checkouts (#548): $_wfs_pc persist-credentials, expected >= 2"
  fi
else
  echo "SKIP: D7 weekly-feedback-sweep both checkouts (absent)"; SKIP=$((SKIP + 1))
fi
assert_grep "D7: weekly-drift-audit pins checkout ref (#548)" \
  "$W/weekly-drift-audit.yml" 'ref: ${{ github.event.repository.default_branch }}'
assert_grep "D7: weekly-drift-audit drops the persisted checkout token (#548)" \
  "$W/weekly-drift-audit.yml" 'persist-credentials: false'
assert_grep "D7: pr-audit pins checkout ref (#548)" \
  "$W/pr-audit.yml" 'ref: ${{ github.event.repository.default_branch }}'
assert_grep "D7: onepassword-headless-proof pins checkout ref (#548)" \
  "$W/onepassword-headless-proof.yml" 'ref: ${{ github.event.repository.default_branch }}'
assert_grep "D7: pr-review-policy drops the persisted checkout token (#548)" \
  "$W/pr-review-policy.yml" 'persist-credentials: false'
# NB: repo_lint.yml is NOT a propagated path (it is consumer-local — each repo
# runs its own lint), so this PROPAGATED suite must not assert its contents:
# consumers have repo_lint.yml present-but-unsynced, which fails (not skips) the
# grep. The canonical repo_lint persist-credentials (#548) stays in the file; it
# just is not a fleet-wide invariant. Caught by the swipewatch sync canary #78.
assert_grep "D7: pr-audit drops the persisted checkout token (#548)" \
  "$W/pr-audit.yml" 'persist-credentials: false'
assert_grep "D7: daily-feedback-rollup drops the persisted checkout token (#548 / Codex #550)" \
  "$W/daily-feedback-rollup.yml" 'persist-credentials: false'
# Completeness sweep (Codex #550): every cross-repo-PAT workflow drops the
# persisted token on ALL its checkouts (gh-with-explicit-token only, no authed
# git). Count-based so a regression of any one checkout is caught.
if [ -f "$W/agent-review.yml" ]; then
  _ar=$(grep -c 'persist-credentials: false' "$W/agent-review.yml")
  if [ "$_ar" -ge 4 ]; then pass "D7: agent-review hardens all 4 checkouts (#550)"; else fail "D7: agent-review checkouts (#550): $_ar persist-credentials, expected >= 4"; fi
else echo "SKIP: D7 agent-review (absent)"; SKIP=$((SKIP + 1)); fi
if [ -f "$W/auto-clear-blocking-labels.yml" ]; then
  _ac=$(grep -c 'persist-credentials: false' "$W/auto-clear-blocking-labels.yml")
  if [ "$_ac" -ge 2 ]; then pass "D7: auto-clear hardens both checkouts (#550)"; else fail "D7: auto-clear checkouts (#550): $_ac persist-credentials, expected >= 2"; fi
else echo "SKIP: D7 auto-clear (absent)"; SKIP=$((SKIP + 1)); fi

# Defect 8 (#550 Codex P1): secret-bearing dispatchable workflows guard the JOB
# on the default branch, so a non-default workflow_dispatch — which runs the
# chosen ref's workflow DEFINITION, beyond the checkout pin's reach — cannot
# leak the secret via a step added ahead of the pinned checkout.
assert_grep "D8: onepassword-headless-proof guards dispatch to the default branch (#550)" \
  "$W/onepassword-headless-proof.yml" 'if: github.ref_name == github.event.repository.default_branch'
assert_grep "D8: weekly-feedback-sweep guards dispatch to the default branch (#550)" \
  "$W/weekly-feedback-sweep.yml" 'if: github.ref_name == github.event.repository.default_branch'
assert_grep "D8: weekly-drift-audit guards dispatch to the default branch (#550)" \
  "$W/weekly-drift-audit.yml" 'if: github.ref_name == github.event.repository.default_branch'
assert_grep "D8: pr-audit guards dispatch to the default branch (#550)" \
  "$W/pr-audit.yml" 'if: github.ref_name == github.event.repository.default_branch'
assert_grep "D8: daily-feedback-rollup guards dispatch to the default branch (#550 Codex)" \
  "$W/daily-feedback-rollup.yml" 'if: github.ref_name == github.event.repository.default_branch'

echo ""
echo "test_465_fail_closed: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
