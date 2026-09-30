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

# Extract one step's `run: |` body from a workflow (dedented by its own
# indentation) so the vectors below execute the shipped shell.
extract_step_run() {  # <workflow> <step name>
  awk -v name="$2" '
    index($0, "- name: " name) && !found { found=1; next }
    found && !in_run && /^[[:space:]]*- name: / { exit }
    found && /^[[:space:]]*run: \|[[:space:]]*$/ { in_run=1; indent=-1; next }
    in_run {
      if ($0 ~ /[^[:space:]]/) {
        match($0, /^[[:space:]]*/)
        if (indent < 0) indent=RLENGTH
        else if (RLENGTH < indent) exit
      }
      print (length($0) >= indent ? substr($0, indent + 1) : "")
    }
  ' "$1"
}

# D13: workflow_dispatch inputs reach the rollup shell only through env and
# are validated, never spliced into the script text next to the reviewer PAT.
refute_grep "D13: rollup does not interpolate dispatch inputs into run:" \
  "$W/daily-feedback-rollup.yml" '"${{ github.event.inputs.'
assert_grep "D13: rollup passes the since input through env" \
  "$W/daily-feedback-rollup.yml" 'INPUT_SINCE: ${{ github.event.inputs.since }}'
if [ -f "$W/daily-feedback-rollup.yml" ]; then
  D13="$(mktemp -d "${TMPDIR:-/tmp}/test465-d13.XXXXXX")"
  mkdir -p "$D13/scripts"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/args"\n' "$D13" >"$D13/scripts/daily-feedback-rollup.sh"
  extract_step_run "$W/daily-feedback-rollup.yml" "Run rollup" >"$D13/step.sh"
  run_rollup_step() {  # <since> <until> <dry_run>
    rm -f "$D13/args" "$D13/pwned"
    ( cd "$D13" && GH_TOKEN=fixture-token REPO=o/r INPUT_SINCE="$1" INPUT_UNTIL="$2" \
        INPUT_DRY_RUN="$3" bash step.sh >/dev/null 2>&1 )
  }
  if run_rollup_step 2026-09-01 2026-09-02 true \
     && [ "$(tr '\n' ' ' <"$D13/args")" = "--since 2026-09-01 --until 2026-09-02 --dry-run " ]; then
    pass "D13 runtime: valid dates and dry_run reach the rollup as arguments"
  else
    fail "D13 runtime: valid inputs did not reach the rollup ($(cat "$D13/args" 2>/dev/null))"
  fi
  if ! run_rollup_step "2026-09-01\"; touch $D13/pwned; \"" "" "" \
     && [ ! -e "$D13/pwned" ] && [ ! -e "$D13/args" ]; then
    pass "D13 runtime: a shell-bearing since input is rejected before anything runs"
  else
    fail "D13 runtime: malformed since input was not rejected"
  fi
  if ! run_rollup_step "" "" "yes" && [ ! -e "$D13/args" ]; then
    pass "D13 runtime: a non-boolean dry_run input is rejected"
  else
    fail "D13 runtime: non-boolean dry_run input was not rejected"
  fi
  if run_rollup_step "" "" "" && [ -e "$D13/args" ] && [ -z "$(tr -d '\n' <"$D13/args")" ]; then
    pass "D13 runtime: scheduled run (no inputs) calls the rollup with no arguments"
  else
    fail "D13 runtime: empty inputs did not produce a bare rollup call"
  fi
  rm -rf "$D13"
fi

# D14: the CodeRabbit severity sweep's open-PR listing survives a transient
# API failure (bounded retry) and still fails after three.
if [ -f "$W/coderabbit-severity-gate.yml" ]; then
  D14="$(mktemp -d "${TMPDIR:-/tmp}/test465-d14.XXXXXX")"
  mkdir -p "$D14/bin"
  cat >"$D14/bin/gh" <<'SHIM'
#!/usr/bin/env bash
n=$(( $(cat "$D14_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" >"$D14_COUNT"
if [ "$n" -le "$D14_FAILS" ]; then echo "HTTP 502" >&2; exit 1; fi
printf '%s\n' 11 12
SHIM
  printf '#!/usr/bin/env bash\nexit 0\n' >"$D14/bin/sleep"
  chmod +x "$D14/bin/gh" "$D14/bin/sleep"
  extract_step_run "$W/coderabbit-severity-gate.yml" "Find open PRs" >"$D14/step.sh"
  run_find_step() {  # <fails>
    rm -f "$D14/count"; : >"$D14/out"
    ( PATH="$D14/bin:$PATH" D14_COUNT="$D14/count" D14_FAILS="$1" EVENT_NAME=schedule \
        REPO=o/r GITHUB_OUTPUT="$D14/out" bash "$D14/step.sh" >/dev/null 2>&1 )
  }
  if run_find_step 2 && [ "$(cat "$D14/count")" = 3 ] && grep -qx 12 "$D14/out"; then
    pass "D14 runtime: open-PR listing retries two transient failures"
  else
    fail "D14 runtime: open-PR listing did not recover from two transient failures"
  fi
  if ! run_find_step 3 && [ "$(cat "$D14/count")" = 3 ]; then
    pass "D14 runtime: open-PR listing fails after three attempts"
  else
    fail "D14 runtime: open-PR listing must fail after exactly three attempts"
  fi
  rm -rf "$D14"
fi

# #1150: scoped sync-all branch keys retain the propagation lane while the
# source checkout remains pinned to the SHA component. The suffix grammar is
# exact so arbitrary text cannot widen branch recognition.
assert_grep "D11: propagation lane accepts an exact sync-all scope digest (#1150)" \
  "$W/pr-review-policy.yml" 'if [[ "$SYNC_KEY" =~ ^sync-all-([0-9a-f]{7,40})-[0-9a-f]{12}$ ]]; then'
assert_grep "D11: propagation lane preserves legacy mixed-case sync-all SHA parsing (#1150)" \
  "$W/pr-review-policy.yml" 'elif [[ "$SYNC_KEY" =~ ^sync-all-([0-9a-fA-F]{7,40})$ ]]; then'
assert_grep "D11: propagation lane extracts only the source SHA (#1150)" \
  "$W/pr-review-policy.yml" 'SYNC_SHA="${BASH_REMATCH[1]}"'

# Execute the workflow's parser itself so these case-boundary vectors cannot
# pass by merely duplicating the intended regex in this test.
sync_key_parser="$(awk '
  /^            if \[\[ "\$SYNC_KEY" =~ \^sync-all-/ { capture=1 }
  capture {
    is_end=($0 == "            fi")
    sub(/^            /, "")
    print
    if (is_end) exit
  }
' "$W/pr-review-policy.yml")"
parse_sync_key() {
  local SYNC_KEY="$1" SYNC_SHA=""
  eval "$sync_key_parser"
  printf '%s\n' "$SYNC_SHA"
}
scoped_lower="$(parse_sync_key 'sync-all-abcdef1-0123456789ab')"
scoped_upper="$(parse_sync_key 'sync-all-ABCDEF1-0123456789ab')"
legacy_upper="$(parse_sync_key 'sync-all-ABCDEF1')"
[ "$scoped_lower" = "abcdef1" ] \
  && pass "D11 runtime: lowercase scoped sync-all key extracts its source SHA" \
  || fail "D11 runtime: lowercase scoped sync-all key was rejected"
if [[ "$scoped_upper" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  fail "D11 runtime: uppercase scoped sync-all key widened the new grammar"
else
  pass "D11 runtime: uppercase scoped sync-all key is rejected"
fi
[ "$legacy_upper" = "ABCDEF1" ] \
  && pass "D11 runtime: legacy uppercase sync-all SHA remains accepted" \
  || fail "D11 runtime: legacy uppercase sync-all SHA compatibility changed"

# Source-commit provenance: the branch-name SHA may name ANY commit in the
# public mergepath repo, so the lane resolves it to ONE full commit and
# requires it to be on mergepath's default branch before checking it out.
assert_grep "D12: propagation lane resolves the branch-key SHA to a single full commit" \
  "$W/pr-review-policy.yml" 'SYNC_FULL_SHA=$(git -C "$MP_DIR" rev-parse --verify --quiet "${SYNC_SHA}^{commit}" 2>/dev/null)'
assert_grep "D12: propagation lane requires the source commit on mergepath's default-branch first-parent history" \
  "$W/pr-review-policy.yml" 'grep -Fxq "$SYNC_FULL_SHA" <<<"$MP_FIRST_PARENT"'
refute_grep "D12: propagation lane does not accept generic (second-parent) ancestry" \
  "$W/pr-review-policy.yml" 'merge-base --is-ancestor "$SYNC_FULL_SHA"'
assert_grep "D12: propagation lane hands the full SHA to the base verifier" \
  "$W/pr-review-policy.yml" 'bash "$VERIFIER" "$MP_DIR" "$PWD" "$BASE_SHA" "$HEAD_SHA" "$SYNC_FULL_SHA"'
refute_grep "D12: propagation lane no longer checks out the raw branch-key SHA" \
  "$W/pr-review-policy.yml" 'checkout --quiet "$SYNC_SHA"'

# Execute the workflow's own resolve/ancestry/checkout condition against a
# local fixture "mergepath" (git is wrapped only to redirect the public clone
# URL to the fixture), so the vectors below exercise the real shell.
if [ -f "$W/pr-review-policy.yml" ]; then
  D12="$(mktemp -d "${TMPDIR:-/tmp}/test465-d12.XXXXXX")"
  d12_git() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
  d12_git init -q "$D12/upstream"
  d12_git -C "$D12/upstream" commit -q --allow-empty -m "on main"
  D12_MAIN=$(git -C "$D12/upstream" rev-parse HEAD)
  d12_git -C "$D12/upstream" checkout -q -b unmerged
  d12_git -C "$D12/upstream" commit -q --allow-empty -m "not on main"
  D12_SIDE=$(git -C "$D12/upstream" rev-parse HEAD)
  d12_git -C "$D12/upstream" checkout -q main
  # A PR branch merged with a TRUE merge: its intermediate commit is an
  # ancestor of main but never a main state.
  d12_git -C "$D12/upstream" checkout -q -b merged-pr
  d12_git -C "$D12/upstream" commit -q --allow-empty -m "intermediate merged-PR commit"
  D12_SECOND=$(git -C "$D12/upstream" rev-parse HEAD)
  d12_git -C "$D12/upstream" checkout -q main
  d12_git -C "$D12/upstream" commit -q --allow-empty -m "main moves on"
  d12_git -C "$D12/upstream" merge -q --no-ff -m "true merge" merged-pr
  mkdir -p "$D12/bin"
  REAL_GIT=$(command -v git)
  cat >"$D12/bin/git" <<SHIM
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  if [ "\$a" = "https://github.com/nathanjohnpayne/mergepath" ]; then a="$D12/upstream"; fi
  args+=("\$a")
done
exec "$REAL_GIT" "\${args[@]}"
SHIM
  chmod +x "$D12/bin/git"
  lane_condition="$(awk '
    /^              SYNC_FULL_SHA=""$/ { capture=1 }
    capture {
      line=$0; sub(/^              /, "", line); print line
      if ($0 ~ /; then$/) exit
    }
  ' "$W/pr-review-policy.yml")"
  run_lane_condition() {  # <sync_sha>
    ( SYNC_SHA="$1"; MP_DIR=$(mktemp -d "$D12/mp.XXXXXX"); rmdir "$MP_DIR"
      PATH="$D12/bin:$PATH"
      eval "$lane_condition
        echo \"checked-out \$SYNC_FULL_SHA\"
      else
        echo rejected
      fi" )
  }
  out_main=$(run_lane_condition "${D12_MAIN:0:7}")
  out_side=$(run_lane_condition "${D12_SIDE:0:7}")
  out_bogus=$(run_lane_condition "0000000")
  out_second=$(run_lane_condition "${D12_SECOND:0:7}")
  [ "$out_main" = "checked-out $D12_MAIN" ] \
    && pass "D12 runtime: a default-branch short SHA resolves to its full commit and checks out" \
    || fail "D12 runtime: default-branch short SHA expected checkout of $D12_MAIN, got: $out_main"
  [ "$out_side" = "rejected" ] \
    && pass "D12 runtime: a commit only on an unmerged branch is rejected" \
    || fail "D12 runtime: unmerged-branch commit must be rejected, got: $out_side"
  [ "$out_second" = "rejected" ] \
    && pass "D12 runtime: a second-parent-only (merged PR branch) commit is rejected" \
    || fail "D12 runtime: second-parent-only commit must be rejected, got: $out_second"
  [ "$out_bogus" = "rejected" ] \
    && pass "D12 runtime: an unresolvable SHA is rejected" \
    || fail "D12 runtime: unresolvable SHA must be rejected, got: $out_bogus"
  rm -rf "$D12"
fi

echo ""
echo "test_465_fail_closed: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
