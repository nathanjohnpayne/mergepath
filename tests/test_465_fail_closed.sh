#!/usr/bin/env bash
# Structural regression guards for the #465 fail-open / early-clear fixes.
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

echo ""
echo "test_465_fail_closed: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
