#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/workflow/approval-merge-continuation.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/approval-continuation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/root/.github" "$TMP/root/scripts/lib" "$TMP/root/scripts/workflow"
cp "$SUBJECT" "$TMP/subject.sh"
cp "$ROOT/scripts/lib/blocking-labels.sh" "$TMP/root/scripts/lib/blocking-labels.sh"
cp "$ROOT/scripts/lib/review-policy-scalar.sh" "$TMP/root/scripts/lib/review-policy-scalar.sh"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "api" ] && [ "$2" = "user" ]; then
  if [ "${STUB_LOGIN_RC:-0}" -ne 0 ]; then
    echo "stub identity lookup failed" >&2
    exit "$STUB_LOGIN_RC"
  fi
  echo "${STUB_LOGIN:-nathanjohnpayne}"
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo" ]; then
  printf 'repo-view\n' >> "$STUB_DIR/events.log"
  if [ "${STUB_DEFAULT_BRANCH_RC:-0}" -ne 0 ]; then
    echo "stub default-branch lookup failed" >&2
    exit "$STUB_DEFAULT_BRANCH_RC"
  fi
  echo "${STUB_DEFAULT_BRANCH:-main}"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  count=$(cat "$STUB_DIR/read-count")
  count=$((count + 1))
  echo "$count" > "$STUB_DIR/read-count"
  printf 'pr-view-%s\n' "$count" >> "$STUB_DIR/events.log"
  if [ "$count" -eq 1 ]; then
    if [ "${STUB_INITIAL_RC:-0}" -ne 0 ]; then
      echo "stub initial PR read failed" >&2
      exit "$STUB_INITIAL_RC"
    fi
    printf '%s\n' "$STUB_INITIAL"
  elif [ "$count" -eq 2 ]; then
    printf '%s\n' "${STUB_SECOND:-$STUB_INITIAL}"
  elif [ "$count" -eq 3 ]; then
    printf '%s\n' "${STUB_THIRD:-${STUB_FINAL:-$STUB_INITIAL}}"
  elif [ "$count" -eq 4 ]; then
    printf '%s\n' "${STUB_FOURTH:-${STUB_FINAL:-$STUB_INITIAL}}"
  else
    printf '%s\n' "${STUB_FINAL:-$STUB_INITIAL}"
  fi
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  if [[ " $* " == *" --match-head-commit "* ]]; then
    echo "unexpected ineffective --match-head-commit on disable-auto" >&2
    exit 91
  fi
  printf 'merge\n' >> "$STUB_DIR/events.log"
  printf '%s\n' "$*" >> "$STUB_DIR/merge.log"
  printf '%s\n' "${GH_TOKEN:-}" >> "$STUB_DIR/merge-token.log"
  exit "${STUB_MERGE_RC:-0}"
fi
echo "unexpected gh call: $*" >&2
exit 90
STUB
chmod +x "$TMP/bin/gh"

for script in codex-review-check.sh merge-clearance-gate.sh review-feedback-accounting.sh resolve-pr-threads.sh required-head-checks.sh; do
  cat > "$TMP/root/scripts/$script" <<'STUB'
#!/usr/bin/env bash
name="${0##*/}"
case "$name" in
  codex-review-check.sh)
    printf 'head_pin=%s args=[%s]\n' "${CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD:-unset}" "$*" >> "${STUB_DIR:?}/readiness.log"
    exit "${STUB_READINESS_RC:-0}"
    ;;
  merge-clearance-gate.sh) exit "${STUB_GATE_RC:-0}" ;;
  review-feedback-accounting.sh)
    printf '%s\n' "${GH_TOKEN:-unset}" >> "${STUB_DIR:?}/accounting-token.log"
    exit "${STUB_ACCOUNTING_RC:-0}"
    ;;
  resolve-pr-threads.sh) exit "${STUB_THREADS_RC:-0}" ;;
  required-head-checks.sh)
    printf '%s\n' "$*" >> "${STUB_DIR:?}/required-checks.log"
    exit "${STUB_REQUIRED_CHECKS_RC:-0}"
    ;;
esac
STUB
  chmod +x "$TMP/root/scripts/$script"
done

cat > "$TMP/root/scripts/workflow/approval-independence-check.sh" <<'STUB'
#!/usr/bin/env bash
printf 'independence\n' >> "${STUB_DIR:?}/events.log"
printf 'read_count=%s args=[%s]\n' "$(cat "${STUB_DIR:?}/read-count")" "$*" >> "$STUB_DIR/independence.log"
printf '{"sharedAuthor":%s,"requiresExternalReview":%s}\n' \
  "${STUB_SHARED_AUTHOR:-false}" "${STUB_REQUIRES_EXTERNAL:-false}"
if [ -n "${STUB_INDEPENDENCE_STDERR:-}" ]; then
  printf '%s\n' "$STUB_INDEPENDENCE_STDERR" >&2
fi
exit "${STUB_INDEPENDENCE_RC:-0}"
STUB
chmod +x "$TMP/root/scripts/workflow/approval-independence-check.sh"

cat > "$TMP/root/scripts/workflow/resolve_base_policy.sh" <<'STUB'
#!/usr/bin/env bash
printf 'policy\n' >> "${STUB_DIR:?}/events.log"
printf '%s\n' "$*" >> "$STUB_DIR/policy.log"
if [ "${STUB_POLICY_RC:-0}" -ne 0 ]; then
  echo "stub policy resolution failed" >&2
  exit "$STUB_POLICY_RC"
fi
printf '%s\n' "$MERGEPATH_REPO_ROOT/policy.yml"
STUB
chmod +x "$TMP/root/scripts/workflow/resolve_base_policy.sh"

# Execute the shipping workflow step itself rather than only grepping its
# shape. The extraction is bounded by the next job separator and dedents the
# literal run block exactly as Actions will hand it to bash.
WORKFLOW_RETRACTION="$TMP/workflow-retraction.sh"
awk '
  /- name: Retract durable auto-merge/ {in_step=1}
  in_step && /^        run: \|/ {in_run=1; next}
  in_run && /^  # ─/ {exit}
  in_run && /^          / {sub(/^          /, ""); print; next}
  in_run && /^[[:space:]]*$/ {print; next}
  in_run {exit}
' "$ROOT/.github/workflows/agent-review.yml" > "$WORKFLOW_RETRACTION"
[ -s "$WORKFLOW_RETRACTION" ] || {
  echo "FAIL: could not extract durable workflow retraction step" >&2
  exit 1
}
chmod +x "$WORKFLOW_RETRACTION"

# Execute the literal workflow block from a checkout that deliberately carries
# an old/poison continuation helper. The first-rollout test must fail if the
# self-contained retraction ever starts depending on the new helper again.
mkdir -p "$TMP/old-trusted-checkout/scripts/workflow"
cat > "$TMP/old-trusted-checkout/scripts/workflow/approval-merge-continuation.sh" <<'STUB'
#!/usr/bin/env bash
echo "poison old helper invoked" >&2
exit 99
STUB
chmod +x "$TMP/old-trusted-checkout/scripts/workflow/approval-merge-continuation.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

BASE='{"state":"OPEN","isDraft":false,"headRefOid":"abc123","baseRefName":"main","baseRefOid":"base123","url":"https://example.test/pr/7","body":"Authoring-Agent: codex","labels":[],"author":{"login":"outside-contributor"},"autoMergeRequest":null}'
SHARED_BASE=$(jq -c '.author.login = "nathanjohnpayne"' <<<"$BASE")
DEPENDABOT_BASE=$(jq -c '
  .author.login = "dependabot[bot]" |
  .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}
' <<<"$BASE")

run_case() {
  local -a subject_args=(7 owner/repo)
  local stub_initial stub_second stub_third stub_fourth stub_final
  if [ -n "${STUB_SUBJECT_MODE:-}" ]; then
    subject_args=(--disarm-shared-author-only 7 owner/repo)
  fi
  stub_initial="${STUB_INITIAL:-$BASE}"
  stub_final="${STUB_FINAL:-$stub_initial}"
  stub_second="${STUB_SECOND:-$stub_initial}"
  stub_third="${STUB_THIRD:-$stub_final}"
  stub_fourth="${STUB_FOURTH:-$stub_final}"
  : > "$TMP/read-count"
  echo 0 > "$TMP/read-count"
  : > "$TMP/merge.log"
  : > "$TMP/merge-token.log"
  : > "$TMP/readiness.log"
  : > "$TMP/required-checks.log"
  : > "$TMP/independence.log"
  : > "$TMP/policy.log"
  : > "$TMP/events.log"
  : > "$TMP/accounting-token.log"
  printf 'author_identity: %s\n' "${STUB_EXPECTED_AUTHOR:-nathanjohnpayne}" > "$TMP/root/policy.yml"
  printf 'author_identity: %s\n' "${STUB_TRUSTED_AUTHOR:-${STUB_EXPECTED_AUTHOR:-nathanjohnpayne}}" > "$TMP/root/.github/review-policy.yml"
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" MERGEPATH_REPO_ROOT="$TMP/root" \
    GH_TOKEN="${TEST_AMBIENT_GH_TOKEN:-${STUB_SUBJECT_TOKEN:-author-token}}" \
    ACCOUNTING_GH_TOKEN="${TEST_ACCOUNTING_GH_TOKEN:-}" \
    MERGEPATH_PROTECTIVE_TOKEN="${STUB_PROTECTIVE_TOKEN-workflow-token}" \
    MERGEPATH_PROTECTIVE_RETRACTION_DONE="${STUB_PROTECTIVE_DONE:-1}" \
    STUB_INITIAL="$stub_initial" STUB_SECOND="$stub_second" \
    STUB_THIRD="$stub_third" STUB_FOURTH="$stub_fourth" STUB_FINAL="$stub_final" \
    STUB_INITIAL_RC="${STUB_INITIAL_RC:-0}" \
    STUB_READINESS_RC="${STUB_READINESS_RC:-0}" STUB_GATE_RC="${STUB_GATE_RC:-0}" \
    STUB_ACCOUNTING_RC="${STUB_ACCOUNTING_RC:-0}" \
    STUB_THREADS_RC="${STUB_THREADS_RC:-0}" STUB_LOGIN="${STUB_LOGIN:-nathanjohnpayne}" \
    STUB_REQUIRED_CHECKS_RC="${STUB_REQUIRED_CHECKS_RC:-0}" \
    STUB_INDEPENDENCE_RC="${STUB_INDEPENDENCE_RC:-0}" \
    STUB_INDEPENDENCE_STDERR="${STUB_INDEPENDENCE_STDERR:-}" \
    STUB_SHARED_AUTHOR="${STUB_SHARED_AUTHOR:-false}" \
    STUB_REQUIRES_EXTERNAL="${STUB_REQUIRES_EXTERNAL:-false}" \
    STUB_POLICY_RC="${STUB_POLICY_RC:-0}" \
    STUB_DEFAULT_BRANCH="${STUB_DEFAULT_BRANCH:-main}" \
    STUB_DEFAULT_BRANCH_RC="${STUB_DEFAULT_BRANCH_RC:-0}" \
    STUB_LOGIN_RC="${STUB_LOGIN_RC:-0}" STUB_MERGE_RC="${STUB_MERGE_RC:-0}" \
    bash "$TMP/subject.sh" "${subject_args[@]}" >"$TMP/subject.out" 2>&1
}

run_workflow_retraction_case() {
  local stub_initial stub_final
  stub_initial="${STUB_INITIAL:-$BASE}"
  stub_final="${STUB_FINAL:-$stub_initial}"
  echo 0 > "$TMP/read-count"
  : > "$TMP/merge.log"
  : > "$TMP/events.log"
  : > "$TMP/workflow-output"
  (
    cd "$TMP/old-trusted-checkout"
    PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" \
      STUB_INITIAL="$stub_initial" STUB_FINAL="$stub_final" \
      STUB_SECOND="$stub_final" \
      STUB_MERGE_RC="${STUB_MERGE_RC:-0}" \
      AUTHOR_IDENTITY="${STUB_WORKFLOW_AUTHOR_IDENTITY-}" \
      SNAPSHOT_CURRENT="${STUB_WORKFLOW_SNAPSHOT_CURRENT:-true}" \
      EVENT_HEAD="${STUB_WORKFLOW_EVENT_HEAD:-abc123}" \
      EVENT_BASE_REF="${STUB_WORKFLOW_EVENT_BASE_REF:-main}" \
      EVENT_BASE_SHA="${STUB_WORKFLOW_EVENT_BASE_SHA:-base123}" \
      GITHUB_OUTPUT="$TMP/workflow-output" \
      PR_NUMBER=7 REPO=owner/repo \
      bash "$WORKFLOW_RETRACTION" >"$TMP/workflow.out" 2>&1
  )
}

assert_not_ready() {
  local label="$1"
  set +e
  run_case
  rc=$?
  set -e
  if [ "$rc" -eq 4 ] && [ ! -s "$TMP/merge.log" ]; then pass "$label"; else fail "$label (rc=$rc)"; fi
}

reset_fixtures() {
  unset STUB_INITIAL STUB_FINAL STUB_INITIAL_RC STUB_READINESS_RC STUB_GATE_RC
  unset STUB_ACCOUNTING_RC STUB_THREADS_RC STUB_LOGIN STUB_LOGIN_RC
  unset STUB_MERGE_RC STUB_EXPECTED_AUTHOR STUB_REQUIRED_CHECKS_RC
  unset STUB_INDEPENDENCE_RC STUB_SHARED_AUTHOR STUB_REQUIRES_EXTERNAL
  unset STUB_INDEPENDENCE_STDERR
  unset STUB_SUBJECT_MODE STUB_POLICY_RC STUB_WORKFLOW_AUTHOR_IDENTITY
  unset STUB_SECOND STUB_THIRD STUB_FOURTH STUB_DEFAULT_BRANCH STUB_DEFAULT_BRANCH_RC
  unset STUB_WORKFLOW_SNAPSHOT_CURRENT STUB_WORKFLOW_EVENT_HEAD
  unset STUB_WORKFLOW_EVENT_BASE_REF STUB_WORKFLOW_EVENT_BASE_SHA STUB_TRUSTED_AUTHOR
  unset STUB_SUBJECT_TOKEN STUB_PROTECTIVE_TOKEN
  unset STUB_PROTECTIVE_DONE
  unset TEST_AMBIENT_GH_TOKEN TEST_ACCOUNTING_GH_TOKEN
}

reset_fixtures
STUB_PROTECTIVE_TOKEN=""
set +e
run_case
missing_protective_token_rc=$?
set -e
if [ "$missing_protective_token_rc" -eq 3 ] \
   && [ "$(cat "$TMP/read-count")" -eq 0 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'requires a separate workflow token for exit cleanup' "$TMP/subject.out"; then
  pass "normal continuation rejects a missing protective token before live work"
else
  fail "normal continuation ran without guaranteed workflow-token cleanup (rc=$missing_protective_token_rc)"
fi

reset_fixtures
STUB_PROTECTIVE_DONE=0
set +e
run_case
missing_protective_pass_rc=$?
set -e
if [ "$missing_protective_pass_rc" -eq 3 ] \
   && [ "$(cat "$TMP/read-count")" -eq 0 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'requires a successful workflow-token protective retraction first' "$TMP/subject.out"; then
  pass "normal continuation rejects a missing protective pass before live work"
else
  fail "normal continuation ran without its prerequisite protective pass (rc=$missing_protective_pass_rc)"
fi

# #1094 / Codex round 4: approval continuation is the non-Dependabot lane.
# Its scheduled and workflow-run callers enumerate every approved PR, so the
# helper itself must preserve Dependabot's dedicated durable auto-merge request
# even when a caller forgets to pre-filter the author class.
reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL="$DEPENDABOT_BASE"
STUB_FINAL="$DEPENDABOT_BASE"
if run_case \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'Dependabot PR is owned by the dedicated auto-merge lane' "$TMP/subject.out"; then
  pass "protective-only continuation preserves Dependabot's dedicated durable arm"
else
  fail "protective-only continuation disabled or reclassified Dependabot auto-merge"
fi

reset_fixtures
STUB_INITIAL="$DEPENDABOT_BASE"
STUB_FINAL="$DEPENDABOT_BASE"
if run_case \
   && [ ! -s "$TMP/merge.log" ] \
   && [ ! -s "$TMP/readiness.log" ] \
   && grep -Fq 'Dependabot PR is owned by the dedicated auto-merge lane' "$TMP/subject.out"; then
  pass "normal approval continuation defers Dependabot to its dedicated lane"
else
  fail "normal approval continuation interfered with Dependabot's dedicated lane"
fi

reset_fixtures
STUB_INITIAL_RC=1
STUB_SECOND="$DEPENDABOT_BASE"
set +e
run_case
dependabot_failed_read_rc=$?
set -e
if [ "$dependabot_failed_read_rc" -eq 3 ] \
   && [ "$(cat "$TMP/read-count")" -eq 2 ] \
   && [ ! -s "$TMP/merge.log" ]; then
  pass "failed initial read cannot make exit cleanup disable a later Dependabot snapshot"
else
  fail "exit cleanup disabled Dependabot after an initial read failure (rc=$dependabot_failed_read_rc)"
fi

reset_fixtures
STUB_INITIAL='{}'
STUB_SECOND="$DEPENDABOT_BASE"
set +e
run_case
dependabot_malformed_read_rc=$?
set -e
if [ "$dependabot_malformed_read_rc" -eq 3 ] \
   && [ "$(cat "$TMP/read-count")" -eq 2 ] \
   && [ ! -s "$TMP/merge.log" ]; then
  pass "malformed initial metadata cannot make exit cleanup disable Dependabot"
else
  fail "exit cleanup disabled Dependabot after malformed initial metadata (rc=$dependabot_malformed_read_rc)"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '
  .author.login = "dependabot[bot]-lookalike" |
  .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}
' <<<"$BASE")
STUB_SECOND="$STUB_INITIAL"
STUB_THIRD=$(jq -c '.autoMergeRequest = null' <<<"$STUB_INITIAL")
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'durable or unclassified auto-merge retraction verified' "$TMP/subject.out"; then
  pass "Dependabot lookalike logins remain inside protective retraction"
else
  fail "Dependabot exemption matched more than the exact native bot login"
fi

reset_fixtures
STUB_READINESS_RC=1
assert_not_ready "missing registered approval or incomplete current-head CI/annex defers without arming"

# #1070: every continuation re-entry must enforce the CONFIGURED required
# head-check list, not just the branch-protection-derived readiness above.
# The premise of that list is that the extra check is NOT branch-protected,
# so without this a repo-lint completion could arm auto-merge before the
# configured check appears or completes.
reset_fixtures
STUB_REQUIRED_CHECKS_RC=1
assert_not_ready "a configured required head check that is not green defers without arming"

reset_fixtures
STUB_REQUIRED_CHECKS_RC=3
set +e
run_case
rhc_rc=$?
set -e
if [ "$rhc_rc" -eq 3 ] && [ ! -s "$TMP/merge.log" ]; then
  pass "an indeterminate required-head-check read is an infra error, not a pass"
else
  fail "indeterminate required-head-check read must exit 3 without arming (rc=$rhc_rc)"
fi

reset_fixtures
if run_case && grep -q -- "--verify --sha abc123" "$TMP/required-checks.log"; then
  pass "the configured list is verified against the pinned head sha"
else
  fail "continuation must verify the configured list against the evaluated head (log: $(cat "$TMP/required-checks.log" 2>/dev/null))"
fi

reset_fixtures
STUB_GATE_RC=1
assert_not_ready "pending threshold-aware external gate defers without arming"

reset_fixtures
STUB_INITIAL=$(jq -c '.labels = [{"name":"human-hold"}]' <<<"$BASE")
assert_not_ready "blocking label defers before gate work"

reset_fixtures
STUB_INITIAL=$(jq -c '.labels = [{"name":"documentation"}]' <<<"$BASE")
STUB_FINAL="$STUB_INITIAL"
if run_case \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'durable auto-merge remains disabled pending the #1058 merge-group boundary' "$TMP/subject.out"; then
  pass "non-blocking labels remain merge-eligible"
else
  fail "shared blocking-label policy must not reject unrelated labels"
fi

reset_fixtures
STUB_ACCOUNTING_RC=1
assert_not_ready "unaccounted feedback defers without arming"

reset_fixtures
STUB_ACCOUNTING_RC=2
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ] && [ ! -s "$TMP/merge.log" ]; then
  pass "feedback-accounting infrastructure failure surfaces as an error"
else
  fail "feedback-accounting infrastructure failure must exit 3 (rc=$rc)"
fi

reset_fixtures
STUB_THREADS_RC=3
assert_not_ready "unresolved conversations defer without arming"

reset_fixtures
STUB_FINAL=$(jq -c '.headRefOid = "def456"' <<<"$BASE")
assert_not_ready "head drift during evaluation defers without arming"

reset_fixtures
STUB_FINAL=$(jq -c '.baseRefName = "release" | .baseRefOid = "base456"' <<<"$BASE")
assert_not_ready "same-head base retarget during evaluation defers without arming"

reset_fixtures
STUB_FINAL=$(jq -c '.baseRefOid = "base456"' <<<"$BASE")
assert_not_ready "same-head base advance during evaluation defers without arming"

reset_fixtures
STUB_THIRD=$(jq -c 'del(.labels)' <<<"$BASE")
STUB_FINAL="$BASE"
set +e
run_case
malformed_final_rc=$?
set -e
if [ "$malformed_final_rc" -eq 3 ] && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'final PR readback is malformed' "$TMP/subject.out"; then
  pass "malformed final readiness metadata fails closed before independence"
else
  fail "malformed final readiness metadata escaped validation (rc=$malformed_final_rc)"
fi

# #1094: the final continuation must not trust the approval event's immutable
# body snapshot. Revalidate live approval independence after the authoritative
# PR re-read, and distinguish a definitive ineligible approval from an
# indeterminate API/config result.
reset_fixtures
STUB_INDEPENDENCE_RC=1
assert_not_ready "a live same-agent approval after a PR-body edit defers without arming"

reset_fixtures
STUB_INDEPENDENCE_STDERR="benign independence diagnostic"
if run_case \
   && grep -Fq 'durable auto-merge remains disabled pending the #1058 merge-group boundary' "$TMP/subject.out"; then
  pass "benign approval-independence stderr cannot corrupt successful JSON"
else
  fail "approval-independence stderr contaminated successful JSON"
fi

reset_fixtures
STUB_INDEPENDENCE_RC=1
STUB_INDEPENDENCE_STDERR="independence failure diagnostic sentinel"
set +e
run_case
independence_diagnostic_rc=$?
set -e
if [ "$independence_diagnostic_rc" -eq 4 ] \
   && grep -Fq 'independence failure diagnostic sentinel' "$TMP/subject.out"; then
  pass "approval-independence failures preserve their stderr diagnostic"
else
  fail "approval-independence failure stderr was lost (rc=$independence_diagnostic_rc)"
fi

reset_fixtures
STUB_INDEPENDENCE_RC=3
set +e
run_case
independence_rc=$?
set -e
if [ "$independence_rc" -eq 3 ] && [ ! -s "$TMP/merge.log" ]; then
  pass "an indeterminate live approval-independence read fails closed"
else
  fail "indeterminate approval independence must exit 3 without arming (rc=$independence_rc)"
fi

reset_fixtures
STUB_FINAL="$BASE"
if run_case \
   && grep -Fq 'head_pin=1 args=[--approval-readiness-only 7 owner/repo]' "$TMP/readiness.log" \
   && grep -Fq 'read_count=3 args=[--repo owner/repo --pr 7 --head abc123 --base-ref main --base-sha base123 --merge-login nathanjohnpayne]' "$TMP/independence.log" \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'durable auto-merge remains disabled pending the #1058 merge-group boundary' "$TMP/subject.out" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 pr-view-3 independence pr-view-4 pr-view-5 " ]; then
  pass "final metadata and pinned live independence end in stable unarmed readiness"
else
  fail "continuation safety order drifted (events: $(tr '\n' ' ' < "$TMP/events.log"); readiness: $(cat "$TMP/readiness.log" 2>/dev/null || true); independence: $(cat "$TMP/independence.log" 2>/dev/null || true); merge: $(cat "$TMP/merge.log" 2>/dev/null || true); output: $(cat "$TMP/subject.out" 2>/dev/null || true))"
fi

reset_fixtures
STUB_FOURTH=$(jq -c '.body = 7' <<<"$BASE")
STUB_FINAL="$BASE"
set +e
run_case
malformed_post_independence_rc=$?
set -e
if [ "$malformed_post_independence_rc" -eq 3 ] && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'post-independence PR readback is malformed' "$TMP/subject.out"; then
  pass "malformed post-independence metadata fails closed and stays unarmed"
else
  fail "malformed post-independence metadata escaped validation (rc=$malformed_post_independence_rc)"
fi

reset_fixtures
STUB_INITIAL="$BASE"
STUB_SECOND="$BASE"
STUB_THIRD="$BASE"
STUB_FOURTH=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:06Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && [ "$(cat "$TMP/merge-token.log")" = "workflow-token" ] \
   && grep -Fq 'post-independence auto-merge retraction verified' "$TMP/subject.out" \
   && grep -Fq 'durable auto-merge remains disabled pending the #1058 merge-group boundary' "$TMP/subject.out"; then
  pass "stable readiness scrubs an arm that appears after independence"
else
  fail "stable readiness preserved a late durable arm or used the author token"
fi

# The post-independence snapshot can be clear while an overlapping rollout
# arms auto-merge immediately afterward. The EXIT pass is the last independent
# observation and must turn ambiguous cleanup into a fail-closed error.
reset_fixtures
STUB_FOURTH="$BASE"
STUB_FINAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:07Z"}' <<<"$BASE")
set +e
run_case
post_snapshot_arm_rc=$?
set -e
if [ "$post_snapshot_arm_rc" -eq 3 ] \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && [ "$(cat "$TMP/merge-token.log")" = "workflow-token" ] \
   && grep -Fq 'could not retract the latest arm before exit' "$TMP/subject.out"; then
  pass "EXIT cleanup catches an arm created after the post-independence snapshot"
else
  fail "EXIT cleanup stranded or silently accepted a post-snapshot arm (rc=$post_snapshot_arm_rc)"
fi

# The head-only merge precondition cannot bind a same-head base transition.
# Observe it after the independence helper returns and stay unarmed; a trailing
# workflow-token pass protects against an overlapping legacy arm.
for post_independence_drift in state draft head base-advance retarget author labels body; do
  reset_fixtures
  STUB_INITIAL="$BASE"
  STUB_SECOND="$BASE"
  STUB_THIRD="$BASE"
  case "$post_independence_drift" in
    state)
      drifted=$(jq -c '.state = "CLOSED"' <<<"$BASE")
      ;;
    draft)
      drifted=$(jq -c '.isDraft = true' <<<"$BASE")
      ;;
    head)
      drifted=$(jq -c '.headRefOid = "def456"' <<<"$BASE")
      ;;
    base-advance)
      drifted=$(jq -c '.baseRefOid = "base456"' <<<"$BASE")
      ;;
    retarget)
      drifted=$(jq -c '.baseRefName = "release" | .baseRefOid = "base999"' <<<"$BASE")
      ;;
    author)
      drifted=$(jq -c '.author.login = "changed-contributor"' <<<"$BASE")
      ;;
    labels)
      drifted=$(jq -c '.labels = [{"name":"human-hold"}]' <<<"$BASE")
      ;;
    body)
      drifted=$(jq -c '.body = "Authoring-Agent: cursor"' <<<"$BASE")
      ;;
  esac
  STUB_FOURTH="$drifted"
  STUB_FINAL="$drifted"
  set +e
  run_case
  post_independence_rc=$?
  set -e
  if [ "$post_independence_rc" -eq 4 ] \
     && [ ! -s "$TMP/merge.log" ] \
     && grep -Fq 'mutable PR metadata changed after approval-independence evaluation' "$TMP/subject.out"; then
    pass "post-independence $post_independence_drift defers without a durable arm"
  else
    fail "post-independence $post_independence_drift escaped the base-policy boundary (rc=$post_independence_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
  fi
done

reset_fixtures
STUB_INITIAL="$SHARED_BASE"
set +e
run_case
shared_phase4_rc=$?
set -e
if [ "$shared_phase4_rc" -eq 4 ] && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'shared-author PR requires a one-shot author merge' "$TMP/subject.out"; then
  pass "shared-author approval cannot leave mutable-state auto-merge armed"
else
  fail "shared-author path must stop before gh pr merge (rc=$shared_phase4_rc)"
fi

reset_fixtures
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
set +e
run_case
armed_shared_phase4_rc=$?
set -e
if [ "$armed_shared_phase4_rc" -eq 4 ] \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 merge pr-view-3 pr-view-4 " ] \
   && [ ! -s "$TMP/readiness.log" ]; then
  pass "shared-author re-entry retracts a pre-existing arm before readiness work"
else
  fail "pre-existing shared-author auto-merge arm was not retracted first (rc=$armed_shared_phase4_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

reset_fixtures
STUB_INITIAL="$SHARED_BASE"
set +e
run_case
shared_under_threshold_rc=$?
set -e
if [ "$shared_under_threshold_rc" -eq 4 ] && [ ! -s "$TMP/merge.log" ]; then
  pass "under-threshold shared-author approval remains valid but uses a one-shot merge"
else
  fail "under-threshold shared-author PR left a durable auto-merge path (rc=$shared_under_threshold_rc)"
fi

reset_fixtures
STUB_SHARED_AUTHOR=false
STUB_REQUIRES_EXTERNAL=true
if run_case \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'durable auto-merge remains disabled pending the #1058 merge-group boundary' "$TMP/subject.out"; then
  pass "native non-shared Phase 4 readiness also stays unarmed without a base CAS"
else
  fail "native non-shared Phase 4 readiness created a head-only durable arm"
fi

# An invalidated shared-author run must retract an old arm before any early
# readiness exit. This is the same-head under-threshold -> Phase 4 transition
# that an approval-triggered auto-merge job otherwise skips as ineligible.
for early_failure in draft readiness independence; do
  reset_fixtures
  STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
  STUB_FINAL="$SHARED_BASE"
  case "$early_failure" in
    draft) STUB_INITIAL=$(jq -c '.isDraft = true' <<<"$STUB_INITIAL") ;;
    readiness) STUB_READINESS_RC=1 ;;
    independence) STUB_INDEPENDENCE_RC=1 ;;
  esac
  set +e
  run_case
  early_failure_rc=$?
  set -e
  if [ "$early_failure_rc" -eq 4 ] \
     && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
     && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 merge pr-view-3 pr-view-4 " ]; then
    pass "shared-author $early_failure invalidation retracts the existing arm before exiting"
  else
    fail "shared-author $early_failure invalidation did not retract first (rc=$early_failure_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
  fi
done

# A shared-author run must also perform the last-moment protective pass. This
# covers an older first-rollout invocation that arms after this invocation's
# pre-evaluation readback but before the shared-author stop.
reset_fixtures
STUB_INITIAL="$SHARED_BASE"
STUB_SECOND="$SHARED_BASE"
STUB_THIRD=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:02Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
set +e
run_case
shared_late_arm_rc=$?
set -e
if [ "$shared_late_arm_rc" -eq 4 ] \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 pr-view-3 merge pr-view-4 " ]; then
  pass "a shared-author stop retracts an arm created after pre-evaluation"
else
  fail "shared-author final cleanup stranded a late arm (rc=$shared_late_arm_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

# An overlapping continuation can create an arm while this invocation is
# inside an expensive readiness gate. Every normal-mode not-ready exit performs
# one final live protective pass, so a base-policy transition cannot inherit
# that arm without reclassification.
reset_fixtures
STUB_READINESS_RC=1
STUB_INITIAL="$BASE"
STUB_SECOND="$BASE"
STUB_THIRD=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:02Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
set +e
run_case
late_arm_not_ready_rc=$?
set -e
if [ "$late_arm_not_ready_rc" -eq 4 ] \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 pr-view-3 merge pr-view-4 " ]; then
  pass "a late arm is retracted before an early normal-mode not-ready exit"
else
  fail "normal-mode not-ready cleanup stranded a late arm (rc=$late_arm_not_ready_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

# Infrastructure failures use the same trailing workflow-token pass. The
# author token remains untrusted for protective writes, and no unexpected gate
# rc may strand an arm created by an older overlapping continuation.
for infra_gate in readiness clearance accounting threads required-checks independence; do
  reset_fixtures
  STUB_INITIAL="$BASE"
  STUB_SECOND="$BASE"
  STUB_FINAL="$BASE"
  late_arm=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:04Z"}' <<<"$BASE")
  case "$infra_gate" in
    readiness) STUB_READINESS_RC=2; STUB_THIRD="$late_arm" ;;
    clearance) STUB_GATE_RC=2; STUB_THIRD="$late_arm" ;;
    accounting) STUB_ACCOUNTING_RC=2; STUB_THIRD="$late_arm" ;;
    threads) STUB_THREADS_RC=2; STUB_THIRD="$late_arm" ;;
    required-checks) STUB_REQUIRED_CHECKS_RC=2; STUB_THIRD="$late_arm" ;;
    independence)
      STUB_INDEPENDENCE_RC=2
      STUB_THIRD="$BASE"
      STUB_FOURTH="$late_arm"
      ;;
  esac
  set +e
  run_case
  late_arm_infra_rc=$?
  set -e
  if [ "$late_arm_infra_rc" -eq 3 ] \
     && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
     && [ "$(cat "$TMP/merge-token.log")" = "workflow-token" ]; then
    pass "$infra_gate infrastructure exit retracts a late arm with the workflow token"
  else
    fail "$infra_gate infrastructure cleanup stranded a late arm or used the wrong token (rc=$late_arm_infra_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
  fi
done

# The final live snapshot is itself the authority when it reveals base drift.
# Retract its arm directly before deferring; a second free-floating read could
# otherwise miss the exact tuple that was just found unsafe.
reset_fixtures
STUB_INITIAL="$BASE"
STUB_SECOND="$BASE"
STUB_THIRD=$(jq -c '.baseRefOid = "base456" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:03Z"}' <<<"$BASE")
STUB_FINAL=$(jq -c '.baseRefOid = "base456" | .autoMergeRequest = null' <<<"$BASE")
set +e
run_case
final_drift_arm_rc=$?
set -e
if [ "$final_drift_arm_rc" -eq 4 ] \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'final-snapshot-drift auto-merge retraction verified' "$TMP/subject.out" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 pr-view-3 merge pr-view-4 pr-view-5 " ]; then
  pass "a final base-drift snapshot is disarmed before the continuation defers"
else
  fail "final base drift left its exact armed tuple standing (rc=$final_drift_arm_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

reset_fixtures
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_POLICY_RC=9
STUB_FINAL=$(jq -c '.autoMergeRequest = null' <<<"$SHARED_BASE")
set +e
run_case
armed_policy_failure_rc=$?
set -e
if [ "$armed_policy_failure_rc" -eq 3 ] \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && [ "$(cat "$TMP/merge-token.log")" = "workflow-token" ] \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 merge pr-view-3 " ]; then
  pass "unreadable governing policy exits through workflow-token protective cleanup"
else
  fail "unreadable governing policy did not use bounded protective cleanup (rc=$armed_policy_failure_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
STUB_POLICY_RC=9
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'durable or unclassified auto-merge retraction verified' "$TMP/subject.out"; then
  pass "workflow-token protection retracts an armed PR when governing policy is unreadable"
else
  fail "workflow-token protection stranded an unclassified arm"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL="$SHARED_BASE"
STUB_SECOND=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:01Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 merge pr-view-3 " ]; then
  pass "protective mode retracts a shared-author arm that appears during policy materialization"
else
  fail "protective mode trusted the stale initially-unarmed bit"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'durable or unclassified auto-merge retraction verified' "$TMP/subject.out"; then
  pass "the approval guard can invoke the bounded protective retraction mode"
else
  fail "protective retraction mode did not verify the disarm"
fi

for failed_readback in still_armed moved_head moved_base; do
  reset_fixtures
  STUB_SUBJECT_MODE=disarm
  STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
  case "$failed_readback" in
    still_armed) STUB_FINAL="$STUB_INITIAL" ;;
    moved_head) STUB_FINAL=$(jq -c '.headRefOid = "def456"' <<<"$SHARED_BASE") ;;
    moved_base) STUB_FINAL=$(jq -c '.baseRefOid = "base456"' <<<"$SHARED_BASE") ;;
  esac
  set +e
  run_case
  failed_readback_rc=$?
  set -e
  if [ "$failed_readback_rc" -eq 3 ] \
     && grep -Fq -- '--disable-auto' "$TMP/merge.log"; then
    pass "a $failed_readback disarm readback fails closed after the retraction write"
  else
    fail "a $failed_readback disarm readback was accepted (rc=$failed_readback_rc)"
  fi
done

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'durable or unclassified auto-merge retraction verified' "$TMP/subject.out" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 merge pr-view-3 " ] \
   && grep -Fq -- '--base-ref main --base-sha base123 --default-branch main --materialize-default' "$TMP/policy.log" \
   && ! grep -Fq -- '--pr' "$TMP/policy.log"; then
  pass "protective mode retracts a native non-shared durable arm"
else
  fail "protective mode preserved a native non-shared durable arm"
fi

# #1094 adversarial race: policy was pinned to the first main/base123 tuple,
# but the PR retargeted after that materialization. The old implementation
# preserved this external-author arm as "proven non-shared" even though its
# policy and live base no longer described the same state. The latest armed
# tuple must instead be treated as unclassified and retracted with its own head
# CAS, then verified against that same base tuple.
reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_SECOND=$(jq -c '
  .headRefOid = "def456" |
  .baseRefName = "release/1.x" |
  .baseRefOid = "base456" |
  .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:01Z"}
' <<<"$BASE")
STUB_FINAL=$(jq -c '.autoMergeRequest = null' <<<"$STUB_SECOND")
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'changed during policy classification; treating the latest armed state as unclassified' "$TMP/subject.out" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 merge pr-view-3 " ]; then
  pass "base/head drift during non-shared preservation retracts the latest arm as unclassified"
else
  fail "policy/PR drift preserved or retracted the wrong armed snapshot (events=$(tr '\n' ' ' < "$TMP/events.log"); merge=$(cat "$TMP/merge.log" 2>/dev/null); output=$(cat "$TMP/subject.out" 2>/dev/null))"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_DEFAULT_BRANCH_RC=7
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'governing policy is unclassified' "$TMP/subject.out"; then
  pass "an unreadable default branch retracts an armed PR instead of guessing its policy identity"
else
  fail "default-branch lookup failure preserved an unclassified arm"
fi

reset_fixtures
STUB_LOGIN=outside-contributor
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
set +e
run_case
misconfigured_contributor_token_rc=$?
set -e
if [ "$misconfigured_contributor_token_rc" -eq 3 ] \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && [ "$(cat "$TMP/merge-token.log")" = "workflow-token" ] \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 merge pr-view-3 " ] \
   && grep -Fq 'expected nathanjohnpayne' "$TMP/subject.out"; then
  pass "a misconfigured author token cannot block workflow-token exit cleanup"
else
  fail "misconfigured author-token exit stranded an arm or used the wrong token (rc=$misconfigured_contributor_token_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

reset_fixtures
STUB_POLICY_RC=9
set +e
run_case
nonshared_policy_failure_rc=$?
set -e
if [ "$nonshared_policy_failure_rc" -eq 3 ] \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 repo-view policy pr-view-2 " ] \
   && [ ! -s "$TMP/merge.log" ]; then
  pass "native non-shared readiness fails closed and stays unarmed on an unreadable governing policy"
else
  fail "native non-shared path bypassed its policy authorization (rc=$nonshared_policy_failure_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

# Run the inline workflow implementation through the rollout states that a
# structural grep cannot prove: optional-token repos, an old trusted helper,
# non-shared arms, shared arms, and a failed retraction readback.
reset_fixtures
if run_workflow_retraction_case && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'readiness continuation remains disabled' "$TMP/workflow.out" \
   && grep -Fxq 'auto_arm_allowed=false' "$TMP/workflow-output"; then
  pass "workflow retraction leaves an unarmed no-token repository green"
else
  fail "workflow retraction made an unarmed no-token repository fail"
fi

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=nathanjohnpayne
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
if run_workflow_retraction_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'Durable or unclassified auto-merge retraction verified' "$TMP/workflow.out" \
   && grep -Fxq 'auto_arm_allowed=true' "$TMP/workflow-output"; then
  pass "workflow-token retraction removes a native non-shared arm without an author token"
else
  fail "workflow-token retraction preserved a native non-shared arm"
fi

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=nathanjohnpayne
STUB_WORKFLOW_SNAPSHOT_CURRENT=false
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
if run_workflow_retraction_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'event head/base is stale or unclassified' "$TMP/workflow.out" \
   && ! grep -Fxq 'auto_arm_allowed=true' "$TMP/workflow-output"; then
  pass "a stale event snapshot retracts an armed PR as unclassified instead of trusting its old base identity"
else
  fail "stale event identity was trusted to preserve an unclassified live arm"
fi

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=nathanjohnpayne
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
if run_workflow_retraction_case \
   && grep -Fq 'pr merge https://example.test/pr/7 --repo owner/repo --disable-auto' "$TMP/merge.log" \
   && grep -Fq 'Durable or unclassified auto-merge retraction verified' "$TMP/workflow.out" \
   && ! grep -Fxq 'auto_arm_allowed=true' "$TMP/workflow-output"; then
  pass "workflow retraction is self-contained for the first consumer rollout"
else
  fail "workflow retraction could not disable and verify a shared-author arm"
fi

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=release-author
WORKFLOW_RELEASE_SHARED=$(jq -c '.author.login = "release-author" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_INITIAL="$WORKFLOW_RELEASE_SHARED"
STUB_FINAL=$(jq -c '.autoMergeRequest = null' <<<"$WORKFLOW_RELEASE_SHARED")
if run_workflow_retraction_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'Durable or unclassified auto-merge retraction verified' "$TMP/workflow.out"; then
  pass "workflow retraction consumes the exact governing identity even when it diverges from the default checkout"
else
  fail "workflow retraction preserved an arm under a stale default-checkout identity"
fi

reset_fixtures
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
set +e
run_workflow_retraction_case
workflow_missing_identity_rc=$?
set -e
if [ "$workflow_missing_identity_rc" -eq 0 ] \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'retracting the existing unclassified auto-merge request fail closed' "$TMP/workflow.out" \
   && ! grep -Fxq 'auto_arm_allowed=true' "$TMP/workflow-output"; then
  pass "workflow retraction removes an existing arm even when policy identity is unavailable"
else
  fail "workflow retraction stranded an unclassified existing arm (rc=$workflow_missing_identity_rc)"
fi

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=nathanjohnpayne
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$STUB_INITIAL"
set +e
run_workflow_retraction_case
workflow_still_armed_rc=$?
set -e
if [ "$workflow_still_armed_rc" -eq 1 ] \
   && grep -Fq 'retraction did not persist' "$TMP/workflow.out"; then
  pass "workflow retraction rejects a still-armed readback"
else
  fail "workflow retraction accepted a still-armed readback (rc=$workflow_still_armed_rc)"
fi

for invalid_field in author auto_merge_absent auto_merge_scalar; do
  reset_fixtures
  case "$invalid_field" in
    author) STUB_INITIAL=$(jq -c 'del(.author)' <<<"$BASE") ;;
    auto_merge_absent) STUB_INITIAL=$(jq -c 'del(.autoMergeRequest)' <<<"$BASE") ;;
    auto_merge_scalar) STUB_INITIAL=$(jq -c '.autoMergeRequest = true' <<<"$BASE") ;;
  esac
  set +e
  run_case
  invalid_shape_rc=$?
  set -e
  if [ "$invalid_shape_rc" -eq 3 ] && [ ! -s "$TMP/merge.log" ]; then
    pass "$invalid_field PR metadata fails closed before any merge write"
  else
    fail "$invalid_field PR metadata passed or wrote (rc=$invalid_shape_rc)"
  fi
done

reset_fixtures
STUB_EXPECTED_AUTHOR=consumer-author
STUB_LOGIN=consumer-author
if run_case \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'durable auto-merge remains disabled pending the #1058 merge-group boundary' "$TMP/subject.out"; then
  pass "governing base policy supplies the authorized merge identity"
else
  fail "continuation must accept the author identity from the governing base policy"
fi

reset_fixtures
STUB_TRUSTED_AUTHOR=nathanjohnpayne
STUB_EXPECTED_AUTHOR=release-author
STUB_LOGIN=release-author
RELEASE_SHARED=$(jq -c '.author.login = "release-author" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_INITIAL="$RELEASE_SHARED"
STUB_FINAL=$(jq -c '.autoMergeRequest = null' <<<"$RELEASE_SHARED")
set +e
run_case
divergent_base_rc=$?
set -e
if [ "$divergent_base_rc" -eq 4 ] \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'shared-author PR requires a one-shot author merge' "$TMP/subject.out"; then
  pass "non-default governing identity overrides the divergent default policy for retraction"
else
  fail "divergent default policy masked the governing shared author (rc=$divergent_base_rc)"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_TRUSTED_AUTHOR=nathanjohnpayne
STUB_EXPECTED_AUTHOR=release-author
RELEASE_SHARED=$(jq -c '.author.login = "release-author" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_INITIAL="$RELEASE_SHARED"
STUB_FINAL=$(jq -c '.autoMergeRequest = null' <<<"$RELEASE_SHARED")
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'durable or unclassified auto-merge retraction verified' "$TMP/subject.out"; then
  pass "protective mode uses the divergent governing base identity to retract its shared author"
else
  fail "protective mode trusted the divergent default identity instead of the governing base"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_TRUSTED_AUTHOR=nathanjohnpayne
STUB_EXPECTED_AUTHOR=release-author
DEFAULT_SHARED=$(jq -c '.author.login = "nathanjohnpayne" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_INITIAL="$DEFAULT_SHARED"
STUB_FINAL=$(jq -c '.autoMergeRequest = null' <<<"$DEFAULT_SHARED")
if run_case \
   && grep -Fq -- '--disable-auto' "$TMP/merge.log" \
   && grep -Fq 'durable or unclassified auto-merge retraction verified' "$TMP/subject.out"; then
  pass "protective mode retracts a governing-base non-shared durable arm despite the divergent default identity"
else
  fail "protective mode preserved a governing-base non-shared durable arm"
fi

reset_fixtures
STUB_MERGE_RC=1
STUB_FOURTH=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:05Z"}' <<<"$BASE")
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ] && [ -s "$TMP/merge.log" ]; then
  pass "failed post-independence protective retraction surfaces as an infrastructure error"
else
  fail "failed post-independence protective retraction must exit 3 (rc=$rc)"
fi

reset_fixtures
STUB_LOGIN_RC=7
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ] && grep -Fq 'stub identity lookup failed' "$TMP/subject.out"; then
  pass "merge-token identity API failure preserves its diagnostic"
else
  fail "identity API failure must exit 3 with its diagnostic (rc=$rc)"
fi

reset_fixtures
STUB_LOGIN=wrong
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ] && [ ! -s "$TMP/merge.log" ]; then
  pass "non-author token fails closed before merge"
else
  fail "non-author token must fail closed (rc=$rc)"
fi

# #1101 (CodeRabbit on PR #1106): every caller of this script runs it under
# GH_TOKEN=AUTHOR_MERGE_TOKEN, an external PAT this repo's workflow
# `permissions:` blocks cannot grant Code Scanning alerts access to.
# review-feedback-accounting.sh must run under the caller-supplied
# ACCOUNTING_GH_TOKEN instead when one is set, so a workflow can route just
# that read-only call through GITHUB_TOKEN (whose scope its `permissions:`
# block DOES control) without touching the ambient author-attributed token
# used for the merge itself.
reset_fixtures
TEST_AMBIENT_GH_TOKEN="author-merge-token"
TEST_ACCOUNTING_GH_TOKEN="github-actions-token"
if run_case && [ "$(cat "$TMP/accounting-token.log" 2>/dev/null)" = "github-actions-token" ]; then
  pass "review-feedback-accounting.sh runs under ACCOUNTING_GH_TOKEN when the caller supplies one"
else
  fail "expected accounting to run under ACCOUNTING_GH_TOKEN (got: $(cat "$TMP/accounting-token.log" 2>/dev/null || echo '<missing>'))"
fi

reset_fixtures
TEST_AMBIENT_GH_TOKEN="author-merge-token"
if run_case && [ "$(cat "$TMP/accounting-token.log" 2>/dev/null)" = "author-merge-token" ]; then
  pass "review-feedback-accounting.sh falls back to the ambient GH_TOKEN when ACCOUNTING_GH_TOKEN is unset"
else
  fail "expected accounting to fall back to the ambient GH_TOKEN (got: $(cat "$TMP/accounting-token.log" 2>/dev/null || echo '<missing>'))"
fi

echo "test_approval_merge_continuation: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
