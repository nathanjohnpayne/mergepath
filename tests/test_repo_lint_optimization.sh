#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOPE="$ROOT/scripts/ci/repo-lint-scope.sh"
DEPENDENCIES="$ROOT/scripts/ci/repo-lint-dependencies.json"
REPO_LINT="$ROOT/.github/workflows/repo_lint.yml"
MD_WRAP="$ROOT/.github/workflows/md-prose-wrap.yml"
OWL="$ROOT/.github/workflows/owl-rules-check.yml"
AGENT_REVIEW="$ROOT/.github/workflows/agent-review.yml"
AUTO_CLEAR="$ROOT/.github/workflows/auto-clear-blocking-labels.yml"
TOKEN_WRAPPER="$ROOT/scripts/ci/check_no_token_in_output"
DOC_WRAPPER="$ROOT/scripts/ci/check_doc_ownership"
CONSUMER_VERDICT="$ROOT/scripts/ci/repo-lint-consumer-verdict.sh"
MODE_HELPER="$ROOT/scripts/lib/ci-check-modes.sh"
SELECTION_HELPER="$ROOT/scripts/lib/repo-lint-check-selection.sh"
CONSUMER_HARNESS="$ROOT/tests/test_repo_lint_consumer_safety.sh"
RESIDUE_HARNESS="$ROOT/tests/test_consumer_residue_safety.sh"

PASS=0
FAIL=0

pass() {
  echo "PASS: $*"
  PASS=$((PASS + 1))
}

fail() {
  echo "FAIL: $*" >&2
  FAIL=$((FAIL + 1))
}

classify() {
  local event="$1"
  shift
  printf '%s\n' "$@" | bash "$SCOPE" --event "$event"
}

scope_value() {
  local key="$1" event="$2"
  shift 2
  classify "$event" "$@" | sed -n "s/^${key}=//p"
}

if [ ! -f "$SCOPE" ]; then
  fail "repo-lint scope classifier exists"
else
  if [ "$(scope_value deep pull_request docs/README.md plans/example.md)" = "false" ]; then
    pass "ordinary documentation changes stay on the fast required lane"
  else
    fail "ordinary documentation changes should not request deep CI"
  fi

  for path in \
    .github/workflows/repo_lint.yml \
    scripts/ci/check_example \
    tests/test_example.sh \
    specs/example.md \
    rules/repo_rules.md \
    docs/agents/operating-rules.md \
    docs/architecture/0002-branch-protection-enforcement-posture.md \
    .mergepath-sync.yml \
    .repo-template.yml \
    REVIEW_POLICY.md \
    ai_agent_tooling_standard.md; do
    if [ "$(scope_value deep pull_request "$path")" = "true" ]; then
      pass "$path requests deep CI"
    else
      fail "$path must request deep CI"
    fi
  done

  if [ "$(scope_value full pull_request rules/repo_rules.md)" = "true" ] \
     && [ "$(scope_value checks pull_request rules/repo_rules.md)" = '[]' ]; then
    pass "rules/repo_rules.md fails closed to the full deep surface"
  else
    fail "rules/repo_rules.md must not bypass the full self-approval policy checker"
  fi

  if [ "$(scope_value full push docs/README.md)" = "true" ] \
     && [ "$(scope_value full schedule docs/README.md)" = "true" ] \
     && [ "$(scope_value full workflow_dispatch docs/README.md)" = "true" ]; then
    pass "main pushes, schedules, and manual runs execute the full regression surface"
  else
    fail "non-PR events must fail closed to deep CI"
  fi

  if [ "$(printf '' | bash "$SCOPE" --event pull_request | sed -n 's/^deep=//p')" = "false" ]; then
    pass "an empty PR diff does not invent deep work"
  else
    fail "an empty PR diff should stay fast"
  fi

  if [ ! -f "$DEPENDENCIES" ] || ! jq -e '.version == 1 and (.wrappers | type == "object") and (.full_triggers | type == "array")' "$DEPENDENCIES" >/dev/null 2>&1; then
    fail "repo-lint exposes a versioned machine-readable wrapper dependency graph"
  else
    pass "repo-lint exposes a versioned machine-readable wrapper dependency graph"
  fi

  selected=$(scope_value checks pull_request scripts/ci/check_no_token_in_output)
  if jq -e 'index("check_no_token_in_output") != null and length == 1' <<<"$selected" >/dev/null 2>&1 \
     && [ "$(scope_value full pull_request scripts/ci/check_no_token_in_output)" = "false" ]; then
    pass "a direct wrapper change selects only that wrapper's expensive checks"
  else
    fail "a direct wrapper change must produce a partial affected-wrapper selection (got $selected)"
  fi

  selected=$(scope_value checks pull_request scripts/ci/token_output_gate.py)
  if jq -e 'index("check_no_token_in_output") != null' <<<"$selected" >/dev/null 2>&1; then
    pass "a declared dependency change selects its owning wrapper"
  else
    fail "declared dependencies must select their owning wrappers (got $selected)"
  fi

  selected=$(scope_value checks pull_request scripts/lib/ci-check-modes.sh)
  if jq -e '
      length == 5
      and (index("check_doc_ownership") != null)
      and (index("check_coderabbit_wait") != null)
      and (index("check_merge_clearance_gate") != null)
      and (index("check_phase_4b_automation") != null)
      and (index("check_phase_4b_accounting") != null)
    ' <<<"$selected" >/dev/null 2>&1; then
    pass "the shared mode selector selects every wrapper that sources it"
  else
    fail "ci-check-modes.sh must select every sourcing wrapper (got $selected)"
  fi

  selected=$(scope_value checks pull_request scripts/phase-4b-review.sh)
  if jq -e '
      index("check_phase_4b_automation") != null
      and index("check_phase_4b_accounting") != null
    ' <<<"$selected" >/dev/null 2>&1; then
    pass "Phase 4b orchestrator changes select automation and accounting regressions"
  else
    fail "phase-4b-review.sh must select both Phase 4b wrappers (got $selected)"
  fi

  if [ "$(scope_value full pull_request scripts/ci/repo-lint-scope.sh)" = "true" ] \
     && [ "$(scope_value checks pull_request scripts/ci/repo-lint-scope.sh)" = '[]' ]; then
    pass "classifier and graph changes fail closed to the full deep surface"
  else
    fail "scope infrastructure changes must select the full deep surface"
  fi

  jq_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-jq.XXXXXX")
  jq_real=$(command -v jq)
  cat > "$jq_stub_dir/jq" <<'STUB'
#!/usr/bin/env bash
count=$(cat "$JQ_STUB_COUNT")
count=$((count + 1))
echo "$count" > "$JQ_STUB_COUNT"
if [ "$count" -eq 2 ]; then exit 7; fi
exec "$JQ_REAL" "$@"
STUB
  chmod +x "$jq_stub_dir/jq"
  echo 0 > "$jq_stub_dir/count"
  parse_failure=$(printf '%s\n' docs/README.md | PATH="$jq_stub_dir:$PATH" JQ_REAL="$jq_real" JQ_STUB_COUNT="$jq_stub_dir/count" bash "$SCOPE" --event pull_request 2>/dev/null)
  rm -rf "$jq_stub_dir"
  if grep -Fxq 'deep=true' <<<"$parse_failure" \
     && grep -Fxq 'full=true' <<<"$parse_failure" \
     && grep -Fxq 'checks=[]' <<<"$parse_failure"; then
    pass "dependency graph parse failures fail closed to the full deep surface"
  else
    fail "a later jq failure must not continue with incomplete wrapper patterns (got $parse_failure)"
  fi

  malformed_root=$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-malformed.XXXXXX")
  mkdir -p "$malformed_root/scripts/ci"
  cp "$SCOPE" "$malformed_root/scripts/ci/repo-lint-scope.sh"
  cat > "$malformed_root/scripts/ci/repo-lint-dependencies.json" <<'JSON'
{"version":1,"full_triggers":[".github/**",null],"wrappers":{"check_example":["scripts/example.sh",7]}}
JSON
  malformed_members=$(printf '%s\n' docs/README.md | bash "$malformed_root/scripts/ci/repo-lint-scope.sh" --event pull_request 2>/dev/null)
  rm -rf "$malformed_root"
  if grep -Fxq 'deep=true' <<<"$malformed_members" \
     && grep -Fxq 'full=true' <<<"$malformed_members" \
     && grep -Fxq 'checks=[]' <<<"$malformed_members"; then
    pass "non-string dependency graph members fail closed to the full deep surface"
  else
    fail "dependency graph arrays must contain only strings (got $malformed_members)"
  fi

  invalid_name_root=$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-invalid-name.XXXXXX")
  mkdir -p "$invalid_name_root/scripts/ci"
  cp "$SCOPE" "$invalid_name_root/scripts/ci/repo-lint-scope.sh"
  cat > "$invalid_name_root/scripts/ci/repo-lint-dependencies.json" <<'JSON'
{"version":1,"full_triggers":[".github/**"],"wrappers":{"lint_wrapper":["scripts/example.sh"]}}
JSON
  invalid_name=$(printf '%s\n' scripts/example.sh | bash "$invalid_name_root/scripts/ci/repo-lint-scope.sh" --event pull_request 2>/dev/null)
  rm -rf "$invalid_name_root"
  if grep -Fxq 'deep=true' <<<"$invalid_name" \
     && grep -Fxq 'full=true' <<<"$invalid_name" \
     && grep -Fxq 'checks=[]' <<<"$invalid_name"; then
    pass "invalid wrapper names fail closed before reaching the shared selector"
  else
    fail "dependency graph wrapper keys must match the selector contract (got $invalid_name)"
  fi
fi

if ! command -v yq >/dev/null 2>&1; then
  fail "mikefarah/yq is available for parsed workflow assertions"
else
  workflows=("$REPO_LINT")
  if [ -f "$MD_WRAP" ]; then
    workflows+=("$MD_WRAP")
  fi
  if [ -f "$OWL" ]; then
    workflows+=("$OWL")
  fi
  for workflow in "${workflows[@]}"; do
    label="${workflow##*/}"
    if yq -e '(.on | has("pull_request")) and (.on.push.branches | length == 1) and (.on.push.branches[0] == "main")' "$workflow" >/dev/null; then
      pass "$label runs PR heads once and limits push validation to main"
    else
      fail "$label must use pull_request plus push.branches=[main]"
    fi
    if yq -e '.concurrency.group == "${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}" and .concurrency.cancel-in-progress == "${{ github.event_name == '\''pull_request'\'' }}"' "$workflow" >/dev/null; then
      pass "$label cancels superseded PR heads without cancelling main"
    else
      fail "$label must declare PR-scoped concurrency cancellation"
    fi
  done

  if yq -e '.on.schedule[0].cron == "17 7 * * *" and .on.workflow_dispatch == null' "$REPO_LINT" >/dev/null; then
    pass "repo-lint retains a scheduled and manual full-regression backstop"
  else
    fail "repo-lint must expose the daily deep-CI schedule and manual trigger"
  fi

  if yq -e '.jobs.scope.outputs.deep == "${{ steps.classify.outputs.deep }}" and .jobs.scope.outputs.full == "${{ steps.classify.outputs.full }}" and .jobs.scope.outputs.checks == "${{ steps.classify.outputs.checks }}" and (.jobs.scope.steps[] | select(.id == "classify") | .run | contains("repo-lint-scope.sh"))' "$REPO_LINT" >/dev/null; then
    pass "repo-lint publishes one parsed affected-wrapper scope decision"
  else
    fail "repo-lint must classify and publish deep/full/check scope once"
  fi

  if yq -e '.jobs.deep_safety.needs == "scope" and .jobs.deep_safety.if == "needs.scope.outputs.deep == '\''true'\''" and (.jobs.deep_safety.strategy.matrix.safety | contains(["consumer", "residue"]))' "$REPO_LINT" >/dev/null; then
    pass "one matrix declaration runs the two exhaustive safety nets in parallel only for deep CI"
  else
    fail "consumer and residue safety must be isolated matrix legs selected only by deep CI"
  fi

  aggregator_run=$(yq -r '.jobs.lint.steps[] | select(.name == "publish aggregate lint result") | .run' "$REPO_LINT")
  if yq -e '.jobs.lint.name == "lint" and .jobs.lint.if == "always()" and (.jobs.lint.needs | contains(["scope", "lint_fast", "deep_safety"]))' "$REPO_LINT" >/dev/null \
     && printf '%s' "$aggregator_run" | grep -Fq 'FAST_RESULT' \
     && printf '%s' "$aggregator_run" | grep -Fq 'DEEP_RESULT' \
     && printf '%s' "$aggregator_run" | grep -Fq 'SCOPE_RESULT' \
     && printf '%s' "$aggregator_run" | grep -Fq 'exit 1'; then
    pass "a stable lint aggregator preserves the required status context"
  else
    fail "repo-lint must retain one always-running lint aggregator over every lane"
  fi

  if yq -e '(.jobs.lint_fast.steps[] | select(.name == "check_no_token_in_output") | .run | contains("--scan")) and (.jobs.lint_fast.steps[] | select(.name == "check_doc_ownership") | .run | contains("--check"))' "$REPO_LINT" >/dev/null; then
    pass "the fast lane runs live token and ownership assertions without their self-tests"
  else
    fail "the fast lane must use token --scan and doc-ownership --check modes"
  fi

  if yq -e '(.jobs.deep_safety.steps[] | select(.name == "check_no_token_in_output --self-test") | .run | contains("--self-test")) and (.jobs.deep_safety.steps[] | select(.name == "check_doc_ownership --self-test") | .run | contains("--self-test"))' "$REPO_LINT" >/dev/null; then
    pass "deep CI retains the full token and ownership regression suites"
  else
    fail "deep CI must run token and doc-ownership self-tests"
  fi

  governance_modes_ok=1
  for name in check_coderabbit_wait check_merge_clearance_gate check_phase_4b_automation check_phase_4b_accounting; do
    name="$name" yq -e '([.jobs.lint_fast.steps[] | select(.name == strenv(name)) | .run | contains("--check")] | any) and ([.jobs.deep_safety.steps[] | select(.name == (strenv(name) + " --self-test")) | select((.if | contains("needs.scope.outputs.full")) and (.if | contains("needs.scope.outputs.checks"))) | .run | contains("--self-test")] | any)' "$REPO_LINT" >/dev/null || governance_modes_ok=0
  done
  if [ "$governance_modes_ok" -eq 1 ]; then
    pass "governance wrappers keep live structure fast and move regression suites to deep CI"
  else
    fail "CodeRabbit, merge-clearance, and Phase 4b wrappers must split live and self-test modes"
  fi

  agent_review_probe=$(yq -r '.jobs."auto-merge-on-approval".steps[] | select(.name == "Probe current-head check readiness once") | .run' "$AGENT_REVIEW")
  if ! grep -Fq 'for readiness_probe in 1; do' <<<"$agent_review_probe" \
     && grep -Fq 'ready=false' <<<"$agent_review_probe" \
     && ! grep -Fq 'sleep ' <<<"$agent_review_probe"; then
    pass "agent-review probes check readiness once without reserving a runner"
  else
    fail "agent-review must record pending readiness and exit without polling"
  fi

  agent_auto_merge=$(yq -r '.jobs."auto-merge-on-approval"' "$AGENT_REVIEW")
  if ! grep -Fq 'coderabbit-wait.sh' <<<"$agent_auto_merge" \
     && ! grep -Fq 'Wait for CodeRabbit review' <<<"$agent_auto_merge"; then
    pass "registered approval does not wait for advisory CodeRabbit arrival"
  else
    fail "CodeRabbit must not be an additional runner-held requirement after approval"
  fi

  wait_step_index=$(yq -r '.jobs."auto-merge-on-approval".steps | to_entries[] | select(.value.name == "Probe current-head check readiness once") | .key' "$AGENT_REVIEW")
  merge_step_index=$(yq -r '.jobs."auto-merge-on-approval".steps | to_entries[] | select(.value.name == "Report stable readiness") | .key' "$AGENT_REVIEW")
  merge_step=$(yq -r '.jobs."auto-merge-on-approval".steps[] | select(.name == "Report stable readiness") | .run' "$AGENT_REVIEW")
  merge_protect_line=$(grep -nF -- '--retract-unsafe-only "$PR_NUMBER" "$REPO"' <<<"$merge_step" | head -1 | cut -d: -f1 || true)
  merge_continue_line=$(grep -nF 'GH_TOKEN="$AUTHOR_TOKEN" MERGEPATH_PROTECTIVE_TOKEN="$WORKFLOW_TOKEN"' <<<"$merge_step" | head -1 | cut -d: -f1 || true)
  if [[ "$wait_step_index" =~ ^[0-9]+$ ]] \
     && [[ "$merge_step_index" =~ ^[0-9]+$ ]] \
     && [ "$merge_step_index" -gt "$wait_step_index" ] \
     && grep -Fq 'if [ ! -f scripts/workflow/approval-merge-continuation.sh ]; then' <<<"$merge_step" \
     && grep -Fq 'APPROVAL_PROTECTIVE_RETRACTION_V2' <<<"$merge_step" \
     && grep -Fq 'GH_TOKEN="$WORKFLOW_TOKEN" bash scripts/workflow/approval-merge-continuation.sh' <<<"$merge_step" \
     && grep -Fq 'MERGEPATH_PROTECTIVE_TOKEN="$WORKFLOW_TOKEN"' <<<"$merge_step" \
     && grep -Fq 'if [ "$protective_rc" -eq 0 ]; then' <<<"$merge_step" \
     && [ -n "$merge_protect_line" ] && [ -n "$merge_continue_line" ] \
     && [ "$merge_protect_line" -lt "$merge_continue_line" ] \
     && grep -Fq 'approval-merge-continuation.sh "$PR_NUMBER" "$REPO"' <<<"$merge_step"; then
    pass "the immediate-green path protects with the workflow token before author-token continuation"
  else
    fail "the immediate-green path must guard helper skew and preserve the ordered two-token continuation"
  fi

  if grep -Fq 'repo_lint_local.yml annex present' <<<"$agent_review_probe" \
     && grep -Fq 'workflowPath // "") == "repo_lint_local.yml"' <<<"$agent_review_probe"; then
    pass "the one-shot probe still observes the optional non-required annex"
  else
    fail "the one-shot probe must continue to enforce a present repo_lint_local.yml annex"
  fi

  if yq -e '(.on.workflow_run.workflows | contains(["repo-lint", "repo-lint-local", ".github/workflows/repo_lint_local.yml"])) and ([.jobs."evaluate-and-clear".steps[] | select(.name == "Continue approved PRs after completed checks") | select(.if | contains("workflow_run")) | .run | contains("approval-merge-continuation.sh")] | any)' "$AUTO_CLEAR" >/dev/null; then
    pass "completed canonical or annex CI re-enters the trusted approval continuation"
  else
    fail "auto-clear must re-enter approval continuation on completed CI workflows"
  fi

  if yq -e '([.jobs."scheduled-sweep".steps[] | select(.name == "Find open approved PRs for the continuation backstop") | .run | contains("review:approved")] | any) and ([.jobs."scheduled-sweep".steps[] | select(.name == "Continue approved PRs after custom-workflow completions") | .run | contains("approval-merge-continuation.sh")] | any)' "$AUTO_CLEAR" >/dev/null; then
    pass "the existing sweep backstops custom annex workflow names"
  else
    fail "custom annex names need a scheduled approval-continuation backstop"
  fi
fi

if [ ! -f "$SELECTION_HELPER" ]; then
  fail "shared affected-wrapper selector exists"
else
  if REPO_LINT_FULL=false REPO_LINT_CHECKS_JSON='["check_doc_ownership"]' \
       bash -c '. "$1"; repo_lint_check_is_selected check_doc_ownership && ! repo_lint_check_is_selected check_no_token_in_output' _ "$SELECTION_HELPER"; then
    pass "shared selector admits only wrappers named by a partial selection"
  else
    fail "shared selector must filter a partial wrapper selection"
  fi
  if REPO_LINT_FULL=true REPO_LINT_CHECKS_JSON='[]' \
       bash -c '. "$1"; repo_lint_check_is_selected check_anything' _ "$SELECTION_HELPER"; then
    pass "shared selector admits every wrapper for a full selection"
  else
    fail "shared selector must admit every wrapper for a full selection"
  fi
  if REPO_LINT_FULL=false REPO_LINT_CHECKS_JSON='not-json' \
       bash -c '. "$1"' _ "$SELECTION_HELPER" >/dev/null 2>&1; then
    fail "shared selector must fail closed on malformed selection JSON"
  else
    pass "shared selector rejects malformed selection JSON"
  fi
fi

for harness in "$CONSUMER_HARNESS" "$RESIDUE_HARNESS"; do
  if [ ! -f "$harness" ] && [ "$harness" = "$CONSUMER_HARNESS" ]; then
    # The production consumer fixture deliberately omits this hub-only replay
    # harness; the explicit assertion below verifies that omission.
    continue
  fi
  if grep -Fq 'repo-lint-check-selection.sh' "$harness" \
     && grep -Fq 'repo_lint_check_is_selected' "$harness"; then
    pass "${harness##*/} applies the shared affected-wrapper selection"
  else
    fail "${harness##*/} must filter expensive probes through the shared selector"
  fi
done

if sed -n '/Stale-ratchet sweep/,/Same ratchet/p' "$RESIDUE_HARNESS" \
     | grep -Fq 'repo_lint_check_is_selected "$n"'; then
  pass "partial residue selection audits only the selected wrappers' exception records"
else
  fail "partial residue selection must not report unselected legacy exceptions as stale"
fi

if yq -e '.jobs.deep_safety.env.REPO_LINT_FULL == "${{ needs.scope.outputs.full }}" and .jobs.deep_safety.env.REPO_LINT_CHECKS_JSON == "${{ needs.scope.outputs.checks }}"' "$REPO_LINT" >/dev/null; then
  pass "deep-safety passes the classifier selection to both harness legs"
else
  fail "deep-safety must consume the classifier full/check outputs"
fi

if [ -f "$MODE_HELPER" ]; then
  mode_result=$(bash -c '. "$1"; ci_check_select_mode --check; echo "$CI_CHECK_RUN_SELF_TEST"' _ "$MODE_HELPER")
  self_result=$(bash -c '. "$1"; ci_check_select_mode --self-test; echo "$CI_CHECK_RUN_SELF_TEST"' _ "$MODE_HELPER")
  consumer_result=$(MERGEPATH_CONSUMER_SAFETY=1 bash -c '. "$1"; ci_check_select_mode; echo "$CI_CHECK_RUN_SELF_TEST"' _ "$MODE_HELPER")
  if [ "$mode_result" = "0" ] && [ "$self_result" = "1" ] && [ "$consumer_result" = "0" ]; then
    pass "the shared wrapper mode selector distinguishes live, self-test, and consumer-smoke calls"
  else
    fail "unexpected wrapper modes: check=$mode_result self=$self_result consumer=$consumer_result"
  fi
else
  fail "shared wrapper mode selector exists"
fi

if [ ! -f "$ROOT/tests/test_repo_lint_consumer_safety.sh" ]; then
  pass "consumer checkout omits the hub-only consumer replay harness"
elif grep -Fq 'MERGEPATH_CONSUMER_SAFETY=1' "$ROOT/tests/test_repo_lint_consumer_safety.sh"; then
  pass "the production consumer replay selects wrapper smoke modes"
else
  fail "the production consumer replay must set MERGEPATH_CONSUMER_SAFETY=1"
fi

if [ -f "$TOKEN_WRAPPER" ]; then
  TOKEN_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-token-wrapper.XXXXXX")"
  trap 'rm -rf "$TOKEN_FIXTURE"' EXIT
  mkdir -p "$TOKEN_FIXTURE/scripts/ci"
  cp "$TOKEN_WRAPPER" "$TOKEN_FIXTURE/scripts/ci/check_no_token_in_output"
  cat > "$TOKEN_FIXTURE/scripts/ci/token_output_gate.py" <<'PY'
import sys
print(" ".join(sys.argv[1:]))
PY
  token_args=$(MERGEPATH_CONSUMER_SAFETY=1 bash "$TOKEN_FIXTURE/scripts/ci/check_no_token_in_output")
  if [ "$token_args" = "--scan" ]; then
    pass "consumer-safety invokes the live token scan without replaying the execution oracle"
  else
    fail "consumer-safety token wrapper should dispatch --scan, got '$token_args'"
  fi
fi

if [ -f "$DOC_WRAPPER" ]; then
  if grep -Fq 'ci_check_select_mode "$@"' "$DOC_WRAPPER" \
     && ! grep -Fq 'case "${1:-}" in' "$DOC_WRAPPER"; then
    pass "doc ownership delegates mode selection to the shared helper"
  else
    fail "doc ownership must not duplicate the shared mode selector"
  fi

  DOC_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-doc-wrapper.XXXXXX")"
  doc_result=$(MERGEPATH_CONSUMER_SAFETY=1 MERGEPATH_REPO_ROOT="$DOC_FIXTURE" bash "$DOC_WRAPPER")
  rm -rf "$DOC_FIXTURE"
  case "$doc_result" in
    "check_doc_ownership: SKIP ("*)
      pass "consumer-safety selects the live doc-ownership assertion without its regression suite"
      ;;
    *)
      fail "consumer-safety doc wrapper should run the live check, got '$doc_result'"
      ;;
  esac
else
  fail "doc ownership wrapper exists"
fi

if [ ! -f "$CONSUMER_VERDICT" ]; then
  fail "consumer-safety verdict classifier exists"
else
  nested=$(printf '%s\n' 'suite: SKIP: optional fixture' 'check_example: PASS' | bash "$CONSUMER_VERDICT" check_example)
  canonical=$(printf '%s\n' 'noise' 'check_example: SKIP (consumer checkout)' | bash "$CONSUMER_VERDICT" check_example)
  if [ "$nested" = "exit 0" ] && [ "$canonical" = "SKIP" ]; then
    pass "consumer-safety distinguishes a canonical wrapper skip from nested skip chatter"
  else
    fail "consumer-safety verdicts should be exit 0/SKIP, got '$nested'/'$canonical'"
  fi
fi

echo
echo "test_repo_lint_optimization: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
