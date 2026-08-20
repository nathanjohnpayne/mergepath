#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOPE="$ROOT/scripts/ci/repo-lint-scope.sh"
REPO_LINT="$ROOT/.github/workflows/repo_lint.yml"
MD_WRAP="$ROOT/.github/workflows/md-prose-wrap.yml"
OWL="$ROOT/.github/workflows/owl-rules-check.yml"
AGENT_REVIEW="$ROOT/.github/workflows/agent-review.yml"
TOKEN_WRAPPER="$ROOT/scripts/ci/check_no_token_in_output"
DOC_WRAPPER="$ROOT/scripts/ci/check_doc_ownership"
CONSUMER_VERDICT="$ROOT/scripts/ci/repo-lint-consumer-verdict.sh"
MODE_HELPER="$ROOT/scripts/lib/ci-check-modes.sh"

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

if [ ! -f "$SCOPE" ]; then
  fail "repo-lint scope classifier exists"
else
  if [ "$(classify pull_request docs/README.md plans/example.md)" = "deep=false" ]; then
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
    if [ "$(classify pull_request "$path")" = "deep=true" ]; then
      pass "$path requests deep CI"
    else
      fail "$path must request deep CI"
    fi
  done

  if [ "$(classify push docs/README.md)" = "deep=true" ] \
     && [ "$(classify schedule docs/README.md)" = "deep=true" ] \
     && [ "$(classify workflow_dispatch docs/README.md)" = "deep=true" ]; then
    pass "main pushes, schedules, and manual runs execute the full regression surface"
  else
    fail "non-PR events must fail closed to deep CI"
  fi

  if [ "$(printf '' | bash "$SCOPE" --event pull_request)" = "deep=false" ]; then
    pass "an empty PR diff does not invent deep work"
  else
    fail "an empty PR diff should stay fast"
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

  if yq -e '.jobs.scope.outputs.deep == "${{ steps.classify.outputs.deep }}" and (.jobs.scope.steps[] | select(.id == "classify") | .run | contains("repo-lint-scope.sh"))' "$REPO_LINT" >/dev/null; then
    pass "repo-lint publishes one parsed deep-CI scope decision"
  else
    fail "repo-lint must classify and publish the deep-CI scope once"
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
    name="$name" yq -e '([.jobs.lint_fast.steps[] | select(.name == strenv(name)) | .run | contains("--check")] | any) and ([.jobs.deep_safety.steps[] | select(.name == (strenv(name) + " --self-test")) | .run | contains("--self-test")] | any)' "$REPO_LINT" >/dev/null || governance_modes_ok=0
  done
  if [ "$governance_modes_ok" -eq 1 ]; then
    pass "governance wrappers keep live structure fast and move regression suites to deep CI"
  else
    fail "CodeRabbit, merge-clearance, and Phase 4b wrappers must split live and self-test modes"
  fi

  agent_review_wait=$(yq -r '.jobs."auto-merge-on-approval".steps[] | select(.name == "Require current-head check success") | .run' "$AGENT_REVIEW")
  if ! grep -Fq 'annex_absent="true"' <<<"$agent_review_wait" \
     && grep -Fq 'while :; do' <<<"$agent_review_wait"; then
    pass "agent-review retains the required-check wait before its final blocking-label recheck"
  else
    fail "agent-review must not arm native auto-merge before late blocking labels can be rechecked"
  fi

  if grep -Fq 'repo_lint_local.yml annex present' <<<"$agent_review_wait" \
     && grep -Fq 'while :; do' <<<"$agent_review_wait"; then
    pass "agent-review retains explicit polling for the optional non-required annex"
  else
    fail "agent-review must continue to enforce a present repo_lint_local.yml annex"
  fi
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
