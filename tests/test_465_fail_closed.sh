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
refute_grep "D2: candidate-controlled agent-review cannot invoke the privileged continuation" \
  "$W/agent-review.yml" 'scripts/workflow/approval-merge-continuation.sh'
assert_grep "D2: candidate-controlled agent-review reports read-only readiness" \
  "$W/agent-review.yml" 'Report stable read-only readiness'
assert_grep "D2: candidate-controlled readiness names the trusted continuation boundary" \
  "$W/agent-review.yml" 'The trusted Agent Review Pipeline workflow_run continuation will re-evaluate every mutable gate.'
refute_grep "D2: shared continuation does not recreate a head-only durable arm" \
  scripts/workflow/approval-merge-continuation.sh '--squash --auto'
assert_grep "D2: shared continuation fails closed when durable-arm cleanup cannot be verified" \
  scripts/workflow/approval-merge-continuation.sh 'could not retract and verify a post-independence auto-merge request'

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
  _wfs_co=$(grep -c 'uses:.*actions/checkout' "$W/weekly-feedback-sweep.yml" || true)
  _wfs_pc=$(grep -c 'persist-credentials: false' "$W/weekly-feedback-sweep.yml" || true)
  if [ "$_wfs_co" -gt 0 ] && [ "$_wfs_pc" -eq "$_wfs_co" ]; then
    pass "D7: weekly-feedback-sweep hardens ALL $_wfs_co checkout(s) (#548 / Codex #550)"
  else
    fail "D7: weekly-feedback-sweep checkouts (#548): $_wfs_pc persist-credentials vs $_wfs_co checkouts (expected equal)"
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
  _ar_co=$(grep -c 'uses:.*actions/checkout' "$W/agent-review.yml" || true)
  _ar=$(grep -c 'persist-credentials: false' "$W/agent-review.yml" || true)
  if [ "$_ar_co" -gt 0 ] && [ "$_ar" -eq "$_ar_co" ]; then
    pass "D7: agent-review hardens all $_ar_co checkout(s) (#550)"
  else
    fail "D7: agent-review checkouts (#550): $_ar persist-credentials vs $_ar_co checkouts (expected equal)"
  fi
else echo "SKIP: D7 agent-review (absent)"; SKIP=$((SKIP + 1)); fi
if [ -f "$W/auto-clear-blocking-labels.yml" ]; then
  _ac_co=$(grep -c 'uses:.*actions/checkout' "$W/auto-clear-blocking-labels.yml" || true)
  _ac=$(grep -c 'persist-credentials: false' "$W/auto-clear-blocking-labels.yml" || true)
  if [ "$_ac_co" -gt 0 ] && [ "$_ac" -eq "$_ac_co" ]; then
    pass "D7: auto-clear hardens all $_ac_co checkout(s) (#550)"
  else
    fail "D7: auto-clear checkouts (#550): $_ac persist-credentials vs $_ac_co checkouts (expected equal)"
  fi
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

# Defect 9 (#557): load-config must ALSO run on approved pull_request_review
# events. The auto-merge-on-approval require_approval gate reads
# needs.load-config.outputs.reviewers on the direct-approval path; if
# load-config is skipped on review events that list is empty, the gate defaults
# REVIEWERS_JSON to [] and rejects every approver as unregistered, so
# approval-triggered auto-merge never arms (regressing #544 / #495). Job-scoped
# (extract the load-config block) so it cannot false-match the auto-merge gate's
# own pull_request_review branch.
#
# #689: match only non-comment lines. The job's own explanatory comment
# (right above the `if:`) also says "pull_request_review", so a plain
# substring grep over the whole block would keep passing on that prose
# alone even if the real `if:` condition were reverted — defeating the
# guard. Stripping full-line comments first anchors the match on the
# live condition.
grep_nocomment_q() {  # <text> <fixed-string>
  printf '%s\n' "$1" | grep -v '^[[:space:]]*#' | grep -qF -- "$2"
}

if [ -f "$W/agent-review.yml" ]; then
  _lc_block=$(awk '/^  load-config:/{f=1;print;next} /^  [A-Za-z._-]+:/{f=0} f{print}' "$W/agent-review.yml")
  if grep_nocomment_q "$_lc_block" 'pull_request_review'; then
    pass "D9: load-config runs on pull_request_review so the arming gate sees reviewers (#557)"
  else
    fail "D9: load-config must gate on pull_request_review (#557) — direct-approval arming regressed"
  fi
else echo "SKIP: D9 agent-review (absent)"; SKIP=$((SKIP + 1)); fi

# D9 self-test (#689): prove the comment-stripping actually changes the
# outcome, so this guard cannot quietly regress back to a bare substring
# match without a visible test failure. A block whose COMMENT mentions
# pull_request_review but whose `if:` does not must NOT match; a block
# whose `if:` genuinely carries the condition must still match.
_d9_bad_block=$(cat <<'FIXTURE'
  load-config:
    # Historical note: this job used to run only on pull_request_review
    # events before an earlier refactor; kept here for context.
    if: >
      (github.event_name == 'pull_request' &&
       github.event.action == 'opened')
    runs-on: ubuntu-latest
FIXTURE
)
_d9_good_block=$(cat <<'FIXTURE'
  load-config:
    # #557: ALSO run on approved pull_request_review events.
    if: >
      (github.event_name == 'pull_request' &&
       github.event.action == 'opened') ||
      (github.event_name == 'pull_request_review' &&
       github.event.review.state == 'approved')
    runs-on: ubuntu-latest
FIXTURE
)
if grep_nocomment_q "$_d9_bad_block" 'pull_request_review'; then
  fail "D9 self-test: guard must not false-pass on a comment-only mention (#689)"
else
  pass "D9 self-test: guard ignores a comment-only mention of pull_request_review (#689)"
fi
if grep_nocomment_q "$_d9_good_block" 'pull_request_review'; then
  pass "D9 self-test: guard still matches a real if: condition (#689)"
else
  fail "D9 self-test: guard must match a real if: condition on pull_request_review (#689)"
fi

# Defect 10 (#827): auto-clear's attribution comment must be gated on THIS run
# having performed the removal, never on a bare "the label is absent" read.
# Absence is not attributable — the workflow carries no concurrency group, so
# concurrent runs all observe it, and the scheduled sweep observes it on stale
# `gh pr list --label` search-index hits too. Gating on absence produced 15
# attribution comments for 5 real removals on #797.
#
# The removal is therefore a REST DELETE (404 when the label is not on the
# issue) rather than `gh pr edit --remove-label`, which is backed by the
# idempotent GraphQL removeLabelsFromLabelable mutation and exits 0 even when
# the label was never present — carrying no signal to gate on.
assert_grep "D10: auto-clear removes via REST DELETE so the HTTP status attributes the removal (#827)" \
  "$W/auto-clear-blocking-labels.yml" '-X DELETE -i --silent'
assert_grep "D10: auto-clear branches the attribution comment on the DELETE status (#827)" \
  "$W/auto-clear-blocking-labels.yml" 'case "$del_status" in'
refute_grep "D10: auto-clear no longer removes via the unattributable gh pr edit path (#827)" \
  "$W/auto-clear-blocking-labels.yml" 'gh pr edit "$PR" --repo "$REPO" --remove-label needs-external-review'
assert_grep "D10: the scheduled sweep re-verifies the label against live state, not the search index (#827)" \
  "$W/auto-clear-blocking-labels.yml" 'stale search-index hit'

# Defect 12: first-delivery window guards (#1221).
#
# A job that runs the PR's copy of a workflow against a DEFAULT-BRANCH checkout
# cannot assume a manifest-delivered helper is present: on the wave that first
# delivers it, the gate fail-closes on a file that wave is itself delivering,
# and the file cannot reach the default branch until the gate passes. Hit live
# on swipewatch#114 (cleared only by a break-glass admin merge) and twice
# before that on the PR-body validator (#1132).
#
# The discriminator must read the DEFAULT BRANCH's own copy of the WORKFLOW,
# not `.mergepath-sync.yml`: the manifest is deliberately hub-only and 404s on
# every consumer, so a manifest test is permanently permissive downstream --
# i.e. it would let deleting the helper silently disable the guarded work on
# exactly the repos the guard is supposed to protect.
g1221_guard_reads_workflow() {  # <label> <workflow-file> <own-basename>
  if [ ! -f "$2" ]; then echo "SKIP: $1 ($2 absent)"; SKIP=$((SKIP + 1)); return; fi
  # The guard must compare against its OWN workflow, which is a file every
  # consumer has -- unlike `.mergepath-sync.yml`, which 404s downstream and
  # would leave the guard permanently permissive there. Scoped to the guards
  # this change owns: codex-p1-gate.yml still carries two PRE-EXISTING
  # manifest-discriminating fences of the same shape, tracked separately in
  # #1230, and this assertion deliberately does not fail on those.
  if grep -Fq ".github/workflows/$3" "$2"; then
    pass "$1"
  else
    fail "$1 (no default-branch workflow self-comparison, or a manifest test remains, in $2)"
  fi
}
g1221_guard_reads_workflow \
  "D12: the codex-p1-gate archive guard discriminates on the workflow, not the hub-only manifest (#1221)" \
  "$W/codex-p1-gate.yml" "codex-p1-gate.yml"
g1221_guard_reads_workflow \
  "D12: the Self-Review validator guard discriminates on the workflow, not the hub-only manifest (#1221)" \
  "$W/pr-review-policy.yml" "pr-review-policy.yml"
# Codex P1 on #1229: the validator guard must test the CALL, flag included --
# the other half of #1132 was a validator that existed but predated the flag
# its caller passed, which dies on `usage:` exactly as a missing file does.
if [ ! -f "$W/pr-review-policy.yml" ]; then
  echo "SKIP: D12 validator call-shape guard (#1221) ($W/pr-review-policy.yml absent)"; SKIP=$((SKIP + 1))
elif grep -Fq -- "grep -Fq -- 'scripts/validate-pr-body.sh --self-review-only'" "$W/pr-review-policy.yml"; then
  pass "D12: the validator guard tests the call INCLUDING its flag, so interface skew reads as first delivery (#1221)"
else
  fail "D12: the validator guard tests presence only -- a validator predating --self-review-only still deadlocks (#1221)"
fi

# Behavioural: EXTRACT the archive guard's decision loop from the workflow and
# run it, so a revert is executed rather than merely text-matched. Deliberately
# form-agnostic about everything except the loop's own boundaries.
if [ ! -f "$W/codex-p1-gate.yml" ]; then
  echo "SKIP: D12 archive guard behaviour (#1221) ($W/codex-p1-gate.yml absent)"; SKIP=$((SKIP + 1))
else
  G1221_LOOP="$(awk '/^ *ghas_libs_ok=1$/ { grab = 1 } grab { sub(/^ +/, ""); print } /^ *done$/ { if (grab) exit }' "$W/codex-p1-gate.yml")"
  if [ -z "$G1221_LOOP" ]; then
    fail "D12: could not extract the archive first-delivery loop from $W/codex-p1-gate.yml (#1221)"
  else
    G1221_DIR="$(mktemp -d "${TMPDIR:-/tmp}/d12-1221.XXXXXX")"
    mkdir -p "$G1221_DIR/scripts/lib" "$G1221_DIR/.github/workflows"
    g1221_run() {  # <state> -> prints "rc=<n> <stdout+stderr>"
      ( cd "$G1221_DIR" && set -euo pipefail && eval "$G1221_LOOP" && echo "ghas_libs_ok=$ghas_libs_ok" ) 2>&1
    }
    # State 1: helper present -> proceed, libs usable.
    : > "$G1221_DIR/scripts/lib/feedback-policy-helpers.sh"
    : > "$G1221_DIR/scripts/lib/gh-api-scalar.sh"
    : > "$G1221_DIR/scripts/lib/ghas-alert-severity.sh"
    printf 'irrelevant\n' > "$G1221_DIR/.github/workflows/codex-p1-gate.yml"
    if g1221_run | grep -q 'ghas_libs_ok=1'; then
      pass "D12: helpers present -> archive enrichment proceeds (#1221)"
    else
      fail "D12: helpers present but the guard did not proceed (#1221)"
    fi
    # State 2: helper absent AND the default-branch workflow does not
    # reference it -> first delivery -> degrade, do not fail.
    rm -f "$G1221_DIR/scripts/lib/ghas-alert-severity.sh"
    G1221_OUT="$(g1221_run || true)"
    if printf '%s' "$G1221_OUT" | grep -q 'ghas_libs_ok=0' \
       && printf '%s' "$G1221_OUT" | grep -q '::warning::'; then
      pass "D12: helper absent and unreferenced by the default-branch workflow -> first-delivery window, degrades with a warning (#1221)"
    else
      fail "D12: first-delivery window did not degrade (#1221): $G1221_OUT"
    fi
    # State 3: helper absent BUT the default-branch workflow references it ->
    # breakage, must fail closed. This is the half that stops the guard
    # becoming a way to disable the archive by deleting a file.
    printf 'a line mentioning scripts/lib/ghas-alert-severity.sh\n' \
      > "$G1221_DIR/.github/workflows/codex-p1-gate.yml"
    G1221_OUT="$(g1221_run || true)"
    if printf '%s' "$G1221_OUT" | grep -q '::error::' \
       && ! printf '%s' "$G1221_OUT" | grep -q 'ghas_libs_ok='; then
      pass "D12: helper absent but referenced by the default-branch workflow -> fails closed, not a bootstrap window (#1221)"
    else
      fail "D12: a missing-but-expected helper did not fail closed (#1221): $G1221_OUT"
    fi
    rm -rf "$G1221_DIR"
  fi
fi

# Codex P1 on #1229, second half: the RENDERER is manifest-delivered too, and
# #1124 widened its arity from `$# -ne 5` to `5..6`. A default branch predating
# that rejects a six-argument call, so a degrade that still passes six
# arguments fails the archive step and the wave stays deadlocked -- having
# announced that it degraded. Extract that decision and run it.
if [ ! -f "$W/codex-p1-gate.yml" ]; then
  echo "SKIP: D12 renderer arity decision (#1221) ($W/codex-p1-gate.yml absent)"; SKIP=$((SKIP + 1))
else
  G1221_REND="$(awk '/\$g1221_render_ok" = 1 \] &&/ { exit } /^ *g1221_render_ok=1$/ { grab = 1 } grab { sub(/^ +/, ""); print }' "$W/codex-p1-gate.yml")"
  if [ -z "$G1221_REND" ]; then
    fail "D12: could not extract the renderer arity decision from $W/codex-p1-gate.yml (#1221)"
  else
    G1221_RDIR="$(mktemp -d "${TMPDIR:-/tmp}/d12-rend.XXXXXX")"
    mkdir -p "$G1221_RDIR/scripts" "$G1221_RDIR/.github/workflows"
    g1221_rend_run() {
      ( cd "$G1221_RDIR" && set -euo pipefail && eval "$G1221_REND" \
        && echo "ok=$g1221_render_ok legacy=$g1221_render_legacy" ) 2>&1
    }
    printf '#!/bin/sh\n' > "$G1221_RDIR/scripts/render-feedback-archive.sh"
    chmod +x "$G1221_RDIR/scripts/render-feedback-archive.sh"
    # Current fleet: the default-branch workflow passes the tier argument.
    printf 'a line with "$ghas_tier" in it\n' > "$G1221_RDIR/.github/workflows/codex-p1-gate.yml"
    if g1221_rend_run | grep -q 'ok=1 legacy=0'; then
      pass "D12: default-branch workflow passes the tier argument -> six-argument renderer (#1221)"
    else
      fail "D12: renderer decision did not select the six-argument form (#1221)"
    fi
    # Pre-#1124 default branch: no tier argument -> its renderer takes five.
    printf 'a line referencing scripts/render-feedback-archive.sh only\n' > "$G1221_RDIR/.github/workflows/codex-p1-gate.yml"
    if g1221_rend_run | grep -q 'ok=1 legacy=1'; then
      pass "D12: default-branch workflow omits the tier argument -> five-argument renderer, not a six-argument call it would reject (#1221)"
    else
      fail "D12: renderer decision did not fall back to the five-argument form (#1221)"
    fi
    # Renderer absent and unreferenced -> first delivery, skip archiving.
    rm -f "$G1221_RDIR/scripts/render-feedback-archive.sh"
    printf 'unrelated\n' > "$G1221_RDIR/.github/workflows/codex-p1-gate.yml"
    if g1221_rend_run | grep -q 'ok=0'; then
      pass "D12: renderer absent and unreferenced -> first-delivery window, archive skipped rather than failing (#1221)"
    else
      fail "D12: renderer absence did not degrade (#1221)"
    fi
    # Renderer absent but REFERENCED -> breakage, fail closed.
    printf 'scripts/render-feedback-archive.sh is referenced here\n' > "$G1221_RDIR/.github/workflows/codex-p1-gate.yml"
    G1221_ROUT="$(g1221_rend_run || true)"
    if printf '%s' "$G1221_ROUT" | grep -q '::error::' && ! printf '%s' "$G1221_ROUT" | grep -q 'ok='; then
      pass "D12: renderer absent but referenced by the default-branch workflow -> fails closed (#1221)"
    else
      fail "D12: a missing-but-expected renderer did not fail closed (#1221): $G1221_ROUT"
    fi
    rm -rf "$G1221_RDIR"
  fi
fi

echo ""
echo "test_465_fail_closed: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
