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
    echo "unexpected merge write with a head-only precondition" >&2
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

cat > "$TMP/root/scripts/workflow/merge-queue-arm-policy.sh" <<'STUB'
#!/usr/bin/env bash
printf 'queue-policy:%s queue-source:%s\n' "${GH_TOKEN:-unset}" \
  "${MERGEPATH_MERGE_QUEUE_SOURCE_TOKEN:-unset}" \
  >> "${STUB_DIR:?}/queue-policy.log"
exit "${STUB_QUEUE_POLICY_RC:-4}"
STUB
chmod +x "$TMP/root/scripts/workflow/merge-queue-arm-policy.sh"

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

if ! grep -Fq -- '--disable-auto' "$SUBJECT" "$ROOT/.github/workflows/agent-review.yml" \
   && ! grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge' "$SUBJECT" "$ROOT/.github/workflows/agent-review.yml"; then
  pass "non-Dependabot approval cleanup contains no native merge or disable mutation"
else
  fail "non-Dependabot approval cleanup reintroduced a native merge or disable mutation"
fi

BASE='{"state":"OPEN","isDraft":false,"headRefOid":"abc123","baseRefName":"main","baseRefOid":"base123","url":"https://example.test/pr/7","body":"Authoring-Agent: codex","labels":[],"author":{"login":"outside-contributor"},"autoMergeRequest":null}'
SHARED_BASE=$(jq -c '.author.login = "nathanjohnpayne"' <<<"$BASE")
DEPENDABOT_BASE=$(jq -c '
  .author.login = "dependabot[bot]" |
  .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}
' <<<"$BASE")
# `gh pr view --json author` — the subject's only author source — renders bot
# logins as `app/<slug>`, so this is the spelling the boundary sees in CI.
DEPENDABOT_APP_BASE=$(jq -c '
  .author.login = "app/dependabot" |
  .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}
' <<<"$BASE")
ARMED_SHARED_BASE=$(jq -c '
  .autoMergeRequest = {
    "enabledAt":"2026-01-09T00:00:00Z",
    "enabledBy":{"login":"nathanjohnpayne"}
  }
' <<<"$SHARED_BASE")

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
  : > "$TMP/queue-policy.log"
  printf 'author_identity: %s\n' "${STUB_EXPECTED_AUTHOR:-nathanjohnpayne}" > "$TMP/root/policy.yml"
  printf 'author_identity: %s\n' "${STUB_TRUSTED_AUTHOR:-${STUB_EXPECTED_AUTHOR:-nathanjohnpayne}}" > "$TMP/root/.github/review-policy.yml"
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" MERGEPATH_REPO_ROOT="$TMP/root" \
    GH_TOKEN="${TEST_AMBIENT_GH_TOKEN:-${STUB_SUBJECT_TOKEN:-author-token}}" \
    ACCOUNTING_GH_TOKEN="${TEST_ACCOUNTING_GH_TOKEN:-}" \
    MERGEPATH_AUTHOR_TOKEN="${STUB_AUTHOR_TOKEN-author-token}" \
    MERGEPATH_PROTECTIVE_TOKEN="${STUB_PROTECTIVE_TOKEN-workflow-token}" \
    MERGEPATH_QUEUE_POLICY_TOKEN="${STUB_QUEUE_POLICY_TOKEN-queue-policy-token}" \
    MERGEPATH_QUEUE_SOURCE_TOKEN="${STUB_QUEUE_SOURCE_TOKEN-queue-source-token}" \
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
    STUB_QUEUE_POLICY_RC="${STUB_QUEUE_POLICY_RC:-4}" \
    bash "$TMP/subject.sh" "${subject_args[@]}" >"$TMP/subject.out" 2>&1
}

run_workflow_retraction_case() {
  local stub_initial stub_final
  stub_initial="${STUB_INITIAL:-$BASE}"
  stub_final="${STUB_FINAL:-$stub_initial}"
  echo 0 > "$TMP/read-count"
  : > "$TMP/merge.log"
  : > "$TMP/events.log"
  : > "$TMP/queue-policy.log"
  : > "$TMP/workflow-output"
  (
    cd "$TMP/old-trusted-checkout"
    PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" \
      STUB_INITIAL="$stub_initial" STUB_FINAL="$stub_final" \
      STUB_SECOND="$stub_final" \
      STUB_MERGE_RC="${STUB_MERGE_RC:-0}" \
      STUB_QUEUE_POLICY_RC="${STUB_QUEUE_POLICY_RC:-4}" \
      AUTHOR_IDENTITY="${STUB_WORKFLOW_AUTHOR_IDENTITY-}" \
      SNAPSHOT_CURRENT="${STUB_WORKFLOW_SNAPSHOT_CURRENT:-true}" \
      EVENT_HEAD="${STUB_WORKFLOW_EVENT_HEAD:-abc123}" \
      EVENT_BASE_REF="${STUB_WORKFLOW_EVENT_BASE_REF:-main}" \
      EVENT_BASE_SHA="${STUB_WORKFLOW_EVENT_BASE_SHA:-base123}" \
      GH_TOKEN="${STUB_WORKFLOW_GH_TOKEN:-workflow-token}" \
      QUEUE_POLICY_TOKEN="${STUB_WORKFLOW_QUEUE_POLICY_TOKEN-queue-policy-token}" \
      QUEUE_SOURCE_TOKEN="${STUB_WORKFLOW_QUEUE_SOURCE_TOKEN-queue-source-token}" \
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
  unset STUB_SUBJECT_TOKEN STUB_AUTHOR_TOKEN STUB_PROTECTIVE_TOKEN
  unset STUB_QUEUE_POLICY_TOKEN STUB_QUEUE_POLICY_RC
  unset STUB_QUEUE_SOURCE_TOKEN
  unset STUB_WORKFLOW_QUEUE_POLICY_TOKEN STUB_WORKFLOW_GH_TOKEN
  unset STUB_WORKFLOW_QUEUE_SOURCE_TOKEN
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

# The fixtures above spell the bot `dependabot[bot]`, which is the REST /
# Actions-context rendering. Every author read in the subject comes from
# `gh pr view --json author`, and gh renders bot logins as `app/<slug>`, so
# `app/dependabot` is the spelling the boundary ACTUALLY receives in CI. The
# suite stubbing only the REST form is why the boundary could silently stop
# matching without a single test going red. The #1058 cleanup path is now
# read-only, but this account boundary still has to select the dedicated
# Dependabot lane before ordinary arm classification.
reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL="$DEPENDABOT_APP_BASE"
STUB_FINAL="$DEPENDABOT_APP_BASE"
if run_case \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'Dependabot PR is owned by the dedicated auto-merge lane' "$TMP/subject.out"; then
  pass "protective-only continuation preserves Dependabot's durable arm under the gh app/ login"
else
  fail "protective-only continuation disabled Dependabot auto-merge under the gh app/ login"
fi

reset_fixtures
STUB_INITIAL="$DEPENDABOT_APP_BASE"
STUB_FINAL="$DEPENDABOT_APP_BASE"
if run_case \
   && [ ! -s "$TMP/merge.log" ] \
   && [ ! -s "$TMP/readiness.log" ] \
   && grep -Fq 'Dependabot PR is owned by the dedicated auto-merge lane' "$TMP/subject.out"; then
  pass "normal approval continuation defers the gh app/ Dependabot login to its dedicated lane"
else
  fail "normal approval continuation interfered with Dependabot under the gh app/ login"
fi

# Closest false positive to the widened match: the exemption must accept the
# two exact native logins and nothing that merely starts with one. A prefix
# test — or an unquoted `case` pattern, where `dependabot[bot]` is a
# character class — would hand an outside contributor a way to park an
# unretractable arm behind a lookalike login.
reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '
  .author.login = "app/dependabot-lookalike" |
  .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}
' <<<"$BASE")
STUB_SECOND="$STUB_INITIAL"
STUB_THIRD=$(jq -c '.autoMergeRequest = null' <<<"$STUB_INITIAL")
set +e
run_case
dependabot_app_lookalike_rc=$?
set -e
if [ "$dependabot_app_lookalike_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "gh app/ Dependabot lookalikes fail closed in ordinary arm classification"
else
  fail "Dependabot exemption matched more than the two exact native bot logins"
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
set +e
run_case
dependabot_lookalike_rc=$?
set -e
if [ "$dependabot_lookalike_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "Dependabot lookalike logins fail closed as ordinary armed PRs"
else
  fail "Dependabot exemption matched more than the exact native bot login"
fi

# #1058: the established cleanup lane may preserve an owner arm only
# after the read-only queue-policy helper proves the complete live boundary.
# The proof uses distinct target-policy and source-read tokens. A protected
# arm returns not-ready rather than pretending that retraction occurred.
reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_SUBJECT_TOKEN=workflow-token
STUB_QUEUE_POLICY_TOKEN=queue-policy-token
STUB_QUEUE_POLICY_RC=0
STUB_INITIAL="$ARMED_SHARED_BASE"
STUB_SECOND="$ARMED_SHARED_BASE"
set +e
run_case
protected_arm_rc=$?
set -e
if [ "$protected_arm_rc" -eq 4 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'protective classification made no mutation' "$TMP/subject.out"; then
  pass "protective continuation reports a proven queue-governed arm as retained"
else
  fail "protective continuation misreported a proven queue-governed arm"
fi

# Normal continuation must make the same retained-arm decision before any
# readiness gate. In particular, it must not locally rewrite the snapshot to
# look unarmed and later publish the ordinary unarmed-readiness claim.
reset_fixtures
STUB_QUEUE_POLICY_TOKEN=queue-policy-token
STUB_QUEUE_POLICY_RC=0
STUB_INITIAL=$(jq -c '.autoMergeRequest = {
  "enabledAt":"2026-01-09T00:00:00Z",
  "enabledBy":{"login":"nathanjohnpayne"}
}' <<<"$BASE")
STUB_SECOND="$STUB_INITIAL"
STUB_FINAL="$STUB_INITIAL"
set +e
run_case
normal_retained_arm_rc=$?
set -e
if [ "$normal_retained_arm_rc" -eq 4 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && [ ! -s "$TMP/readiness.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'queue-governed arm remains active; direct readiness continuation is not authorized' "$TMP/subject.out" \
   && ! grep -Fq 'durable auto-merge remains disabled pending the #1058 merge-group boundary' "$TMP/subject.out"; then
  pass "normal continuation stops on a proven retained arm without claiming unarmed readiness"
else
  fail "normal continuation locally reclassified or advanced a proven retained arm (rc=$normal_retained_arm_rc; output=$(tr '\n' ' ' < "$TMP/subject.out"))"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_SUBJECT_TOKEN=workflow-token
STUB_QUEUE_POLICY_TOKEN=queue-policy-token
STUB_QUEUE_POLICY_RC=4
STUB_INITIAL="$ARMED_SHARED_BASE"
STUB_SECOND="$ARMED_SHARED_BASE"
STUB_THIRD="$SHARED_BASE"
STUB_FINAL="$SHARED_BASE"
set +e
run_case
queue_disabled_result=$?
set -e
if [ "$queue_disabled_result" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && [ ! -s "$TMP/merge-token.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "queue proof rc=4 refuses an unconditioned disable mutation"
else
  fail "queue proof rc=4 wrote or silently accepted an unproven arm"
fi

for queue_reject_rc in 3 5; do
  reset_fixtures
  STUB_SUBJECT_MODE=disarm
  STUB_SUBJECT_TOKEN=workflow-token
  STUB_QUEUE_POLICY_TOKEN=queue-policy-token
  STUB_QUEUE_POLICY_RC="$queue_reject_rc"
  STUB_INITIAL="$ARMED_SHARED_BASE"
  STUB_SECOND="$ARMED_SHARED_BASE"
  set +e
  run_case
  queue_reject_result=$?
  set -e
  if [ "$queue_reject_result" -ne 0 ] \
     && [ ! -s "$TMP/merge.log" ] \
     && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
     && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
    pass "queue proof rc=$queue_reject_rc refuses ambiguous active-rollout mutation"
  else
    fail "queue proof rc=$queue_reject_rc disabled or silently preserved an ambiguous arm"
  fi
done

# A trusted checkout without the new proof helper must also block. Falling
# back to native disable would recreate the read/newer-arm/disable race.
chmod -x "$TMP/root/scripts/workflow/merge-queue-arm-policy.sh"
reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL="$ARMED_SHARED_BASE"
STUB_SECOND="$ARMED_SHARED_BASE"
set +e
run_case
missing_queue_helper_rc=$?
set -e
chmod +x "$TMP/root/scripts/workflow/merge-queue-arm-policy.sh"
if [ "$missing_queue_helper_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && [ ! -s "$TMP/queue-policy.log" ] \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "missing queue proof helper leaves an armed PR untouched and blocks"
else
  fail "missing queue proof helper allowed an unconditioned arm mutation"
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
set +e
run_case
late_post_independence_arm_rc=$?
set -e
if [ "$late_post_independence_arm_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && [ ! -s "$TMP/merge-token.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'refusing to mutate post-independence arm' "$TMP/subject.out"; then
  pass "stable readiness blocks without mutating an arm that appears after independence"
else
  fail "stable readiness mutated or accepted a late durable arm"
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
   && [ ! -s "$TMP/merge.log" ] \
   && [ ! -s "$TMP/merge-token.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'refusing to mutate continuation exit arm' "$TMP/subject.out" \
   && grep -Fq 'could not retract the latest arm before exit' "$TMP/subject.out"; then
  pass "EXIT cleanup detects a newer arm and blocks without mutating it"
else
  fail "EXIT cleanup mutated or silently accepted a post-snapshot arm (rc=$post_snapshot_arm_rc)"
fi

# A newly active arm may be valid inside the queue boundary. It must remain
# untouched, but that means the ordinary one-shot readiness claim is no longer
# true. The EXIT observation therefore replaces success with not-ready rather
# than printing a stale merge-ready result and returning zero.
reset_fixtures
STUB_FOURTH="$BASE"
STUB_FINAL=$(jq -c \
  '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:08Z"}' \
  <<<"$BASE")
STUB_QUEUE_POLICY_RC=0
set +e
run_case
post_snapshot_proven_arm_rc=$?
set -e
if [ "$post_snapshot_proven_arm_rc" -eq 4 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && [ ! -s "$TMP/merge-token.log" ] \
   && grep -Fxq \
     'queue-policy:queue-policy-token queue-source:queue-source-token' \
     "$TMP/queue-policy.log" \
   && grep -Fq 'continuation exit arm is protected by the #1058 merge-queue boundary' \
     "$TMP/subject.out" \
   && grep -Fq 'queue-governed arm became active at continuation exit' \
     "$TMP/subject.out" \
   && ! grep -Fq 'merge-ready at' "$TMP/subject.out"; then
  pass "EXIT cleanup preserves a proven queue arm and revokes ordinary readiness"
else
  fail "EXIT cleanup reported stale readiness for a proven post-snapshot arm (rc=$post_snapshot_proven_arm_rc; output=$(tr '\n' ' ' < "$TMP/subject.out"))"
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
if [ "$armed_shared_phase4_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate pre-evaluation arm' "$TMP/subject.out" \
   && [ ! -s "$TMP/readiness.log" ]; then
  pass "shared-author re-entry blocks on a pre-existing unproven arm without mutation"
else
  fail "pre-existing shared-author arm was mutated or allowed into readiness work (rc=$armed_shared_phase4_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
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

# An invalidated shared-author run with an old arm must block before any early
# readiness predicate. Native disable cannot distinguish that old request from
# a newer owner action on the same tuple.
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
  if [ "$early_failure_rc" -eq 3 ] \
     && [ ! -s "$TMP/merge.log" ] \
     && [ ! -s "$TMP/readiness.log" ] \
     && grep -Fq 'refusing to mutate pre-evaluation arm' "$TMP/subject.out"; then
    pass "shared-author $early_failure invalidation blocks on the existing arm without mutation"
  else
    fail "shared-author $early_failure invalidation mutated or bypassed the existing arm (rc=$early_failure_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
  fi
done

# A shared-author run must also perform the last-moment protective read. This
# covers a newer owner arm appearing after pre-evaluation and before the stop.
reset_fixtures
STUB_INITIAL="$SHARED_BASE"
STUB_SECOND="$SHARED_BASE"
STUB_THIRD=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:02Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
set +e
run_case
shared_late_arm_rc=$?
set -e
if [ "$shared_late_arm_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'refusing to mutate continuation exit arm' "$TMP/subject.out"; then
  pass "a shared-author stop detects a newer arm and refuses to mutate it"
else
  fail "shared-author final cleanup mutated or accepted a late arm (rc=$shared_late_arm_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

# A newer owner action can create an arm while this invocation is inside an
# expensive readiness gate. The final read must turn that into a non-mutating
# failure, never an unconditional disable.
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
if [ "$late_arm_not_ready_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'refusing to mutate continuation exit arm' "$TMP/subject.out"; then
  pass "a late arm blocks an early normal-mode exit without mutation"
else
  fail "normal-mode not-ready cleanup mutated or accepted a late arm (rc=$late_arm_not_ready_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

# Infrastructure failures use the same trailing read-only pass. No unexpected
# gate result may authorize mutation of an arm created by a newer action.
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
     && [ ! -s "$TMP/merge.log" ] \
     && [ ! -s "$TMP/merge-token.log" ] \
     && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log"; then
    pass "$infra_gate infrastructure exit detects a late arm without mutation"
  else
    fail "$infra_gate infrastructure cleanup mutated or accepted a late arm (rc=$late_arm_infra_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
  fi
done

# A final live snapshot that reveals base drift and an arm must block without
# mutation. There is no action-level precondition with which to disable it.
reset_fixtures
STUB_INITIAL="$BASE"
STUB_SECOND="$BASE"
STUB_THIRD=$(jq -c '.baseRefOid = "base456" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:03Z"}' <<<"$BASE")
STUB_FINAL=$(jq -c '.baseRefOid = "base456" | .autoMergeRequest = null' <<<"$BASE")
set +e
run_case
final_drift_arm_rc=$?
set -e
if [ "$final_drift_arm_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'refusing to mutate final-snapshot-drift arm' "$TMP/subject.out"; then
  pass "a final base-drift arm blocks without an unconditional disable"
else
  fail "final base drift mutated or accepted its armed tuple (rc=$final_drift_arm_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
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
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'refusing to mutate continuation exit arm' "$TMP/subject.out"; then
  pass "unreadable governing policy leaves an armed PR untouched and fails closed"
else
  fail "unreadable governing policy mutated or accepted an arm (rc=$armed_policy_failure_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
STUB_POLICY_RC=9
set +e
run_case
unreadable_policy_arm_rc=$?
set -e
if [ "$unreadable_policy_arm_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "workflow-token protection blocks an unclassified arm without mutation"
else
  fail "workflow-token protection mutated or accepted an unclassified arm"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL="$SHARED_BASE"
STUB_SECOND=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:01Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
set +e
run_case
arm_during_policy_rc=$?
set -e
if [ "$arm_during_policy_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "protective mode blocks an arm that appears during policy materialization"
else
  fail "protective mode mutated or trusted the stale initially-unarmed bit"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
set +e
run_case
protective_arm_rc=$?
set -e
if [ "$protective_arm_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "the approval guard blocks an unproven arm in protective mode"
else
  fail "protective mode mutated or accepted an unproven arm"
fi

for armed_snapshot in still_armed moved_head moved_base; do
  reset_fixtures
  STUB_SUBJECT_MODE=disarm
  STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
  case "$armed_snapshot" in
    still_armed) STUB_SECOND="$STUB_INITIAL" ;;
    moved_head) STUB_SECOND=$(jq -c '.headRefOid = "def456" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:01Z"}' <<<"$SHARED_BASE") ;;
    moved_base) STUB_SECOND=$(jq -c '.baseRefOid = "base456" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:01Z"}' <<<"$SHARED_BASE") ;;
  esac
  set +e
  run_case
  armed_snapshot_rc=$?
  set -e
  if [ "$armed_snapshot_rc" -eq 3 ] \
     && [ ! -s "$TMP/merge.log" ] \
     && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
    pass "a $armed_snapshot protective snapshot fails closed without a write"
  else
    fail "a $armed_snapshot protective snapshot was mutated or accepted (rc=$armed_snapshot_rc)"
  fi
done

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
set +e
run_case
nonshared_arm_rc=$?
set -e
if [ "$nonshared_arm_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out" \
   && grep -Fq -- '--base-ref main --base-sha base123 --default-branch main --materialize-default' "$TMP/policy.log" \
   && ! grep -Fq -- '--pr' "$TMP/policy.log"; then
  pass "protective mode blocks a native non-shared durable arm without mutation"
else
  fail "protective mode mutated or accepted a native non-shared durable arm"
fi

# #1094 adversarial race: policy was pinned to the first main/base123 tuple,
# but the PR retargeted after that materialization. The old implementation
# preserved this external-author arm as "proven non-shared" even though its
# policy and live base no longer described the same state. The latest armed
# tuple must instead be treated as unclassified and left untouched for explicit
# disposition; native disable has no head or action CAS.
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
set +e
run_case
policy_drift_arm_rc=$?
set -e
if [ "$policy_drift_arm_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'changed during policy classification; treating the latest armed state as unclassified' "$TMP/subject.out" \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "base/head drift leaves the latest unclassified arm untouched and blocks"
else
  fail "policy/PR drift mutated or accepted an armed snapshot (events=$(tr '\n' ' ' < "$TMP/events.log"); merge=$(cat "$TMP/merge.log" 2>/dev/null); output=$(cat "$TMP/subject.out" 2>/dev/null))"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_DEFAULT_BRANCH_RC=7
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
set +e
run_case
unreadable_default_arm_rc=$?
set -e
if [ "$unreadable_default_arm_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'governing policy is unclassified' "$TMP/subject.out" \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "an unreadable default branch leaves an armed PR untouched and blocks"
else
  fail "default-branch lookup failure mutated or accepted an unclassified arm"
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
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fxq 'queue-policy:queue-policy-token queue-source:queue-source-token' "$TMP/queue-policy.log" \
   && grep -Fq 'expected nathanjohnpayne' "$TMP/subject.out" \
   && grep -Fq 'refusing to mutate continuation exit arm' "$TMP/subject.out"; then
  pass "a misconfigured author token cannot authorize mutation during exit cleanup"
else
  fail "misconfigured author-token exit mutated or accepted an arm (rc=$misconfigured_contributor_token_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
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
# structural grep cannot prove: optional-token repos, a missing queue-policy
# helper, non-shared/shared arms, and every helper outcome.
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
set +e
run_workflow_retraction_case
workflow_nonshared_arm_rc=$?
set -e
if [ "$workflow_nonshared_arm_rc" -eq 1 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'Native non-shared PR has a head-only durable arm' "$TMP/workflow.out" \
   && grep -Fq 'Refusing to mutate or classify a durable arm' "$TMP/workflow.out" \
   && grep -Fxq 'auto_arm_allowed=true' "$TMP/workflow-output"; then
  pass "missing queue helper blocks a native non-shared arm without mutation"
else
  fail "missing queue helper mutated or accepted a native non-shared arm"
fi

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=nathanjohnpayne
STUB_WORKFLOW_SNAPSHOT_CURRENT=false
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_FINAL="$BASE"
set +e
run_workflow_retraction_case
workflow_stale_snapshot_rc=$?
set -e
if [ "$workflow_stale_snapshot_rc" -eq 1 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'event head/base is stale or unclassified' "$TMP/workflow.out" \
   && grep -Fq 'Refusing to mutate or classify a durable arm' "$TMP/workflow.out" \
   && ! grep -Fxq 'auto_arm_allowed=true' "$TMP/workflow-output"; then
  pass "a stale event snapshot leaves its unclassified arm untouched and blocks"
else
  fail "stale event identity authorized mutation or acceptance of an unclassified arm"
fi

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=nathanjohnpayne
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
set +e
run_workflow_retraction_case
workflow_missing_helper_shared_rc=$?
set -e
if [ "$workflow_missing_helper_shared_rc" -eq 1 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'Refusing to mutate or classify a durable arm' "$TMP/workflow.out" \
   && ! grep -Fxq 'auto_arm_allowed=true' "$TMP/workflow-output"; then
  pass "first-rollout checkout without the queue helper blocks a shared-author arm"
else
  fail "missing queue helper mutated or accepted a shared-author arm"
fi

cat > "$TMP/old-trusted-checkout/scripts/workflow/merge-queue-arm-policy.sh" <<'STUB'
#!/usr/bin/env bash
printf 'candidate workflow invoked privileged queue policy\n' \
  >> "${STUB_DIR:?}/queue-policy.log"
exit 0
STUB
chmod +x "$TMP/old-trusted-checkout/scripts/workflow/merge-queue-arm-policy.sh"
reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=nathanjohnpayne
STUB_WORKFLOW_QUEUE_POLICY_TOKEN=author-token
STUB_WORKFLOW_QUEUE_SOURCE_TOKEN=source-token
STUB_INITIAL="$ARMED_SHARED_BASE"
STUB_FINAL="$ARMED_SHARED_BASE"
set +e
run_workflow_retraction_case
workflow_candidate_arm_rc=$?
set -e
if [ "$workflow_candidate_arm_rc" -eq 1 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && [ ! -s "$TMP/queue-policy.log" ] \
   && grep -Fq 'Refusing to mutate or classify a durable arm' "$TMP/workflow.out"; then
  pass "candidate-controlled workflow cannot invoke the privileged queue classifier even when ambient test tokens exist"
else
  fail "candidate-controlled workflow invoked or bypassed the privileged queue boundary"
fi
rm -f "$TMP/old-trusted-checkout/scripts/workflow/merge-queue-arm-policy.sh"

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=release-author
WORKFLOW_RELEASE_SHARED=$(jq -c '.author.login = "release-author" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_INITIAL="$WORKFLOW_RELEASE_SHARED"
STUB_FINAL=$(jq -c '.autoMergeRequest = null' <<<"$WORKFLOW_RELEASE_SHARED")
set +e
run_workflow_retraction_case
workflow_release_arm_rc=$?
set -e
if [ "$workflow_release_arm_rc" -eq 1 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'Refusing to mutate or classify a durable arm' "$TMP/workflow.out"; then
  pass "inline cleanup blocks a governing-identity arm without mutation"
else
  fail "inline cleanup mutated or accepted an arm under a divergent identity"
fi

reset_fixtures
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
set +e
run_workflow_retraction_case
workflow_missing_identity_rc=$?
set -e
if [ "$workflow_missing_identity_rc" -eq 1 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'blocking on the existing unclassified auto-merge request fail closed' "$TMP/workflow.out" \
   && grep -Fq 'Refusing to mutate or classify a durable arm' "$TMP/workflow.out" \
   && ! grep -Fxq 'auto_arm_allowed=true' "$TMP/workflow-output"; then
  pass "inline cleanup blocks an unclassified arm without mutation"
else
  fail "inline cleanup mutated or accepted an unclassified arm (rc=$workflow_missing_identity_rc)"
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
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'Refusing to mutate or classify a durable arm' "$TMP/workflow.out"; then
  pass "inline cleanup rejects an unproven still-armed state without mutation"
else
  fail "inline cleanup mutated or accepted a still-armed state (rc=$workflow_still_armed_rc)"
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
if [ "$divergent_base_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate pre-evaluation arm' "$TMP/subject.out"; then
  pass "non-default governing identity cannot authorize mutation of its armed PR"
else
  fail "divergent default policy enabled mutation or acceptance of an armed PR (rc=$divergent_base_rc)"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_TRUSTED_AUTHOR=nathanjohnpayne
STUB_EXPECTED_AUTHOR=release-author
RELEASE_SHARED=$(jq -c '.author.login = "release-author" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_INITIAL="$RELEASE_SHARED"
STUB_FINAL=$(jq -c '.autoMergeRequest = null' <<<"$RELEASE_SHARED")
set +e
run_case
divergent_protective_shared_rc=$?
set -e
if [ "$divergent_protective_shared_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "protective mode blocks a governing-base shared-author arm without mutation"
else
  fail "protective mode mutated or accepted the governing-base shared-author arm"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_TRUSTED_AUTHOR=nathanjohnpayne
STUB_EXPECTED_AUTHOR=release-author
DEFAULT_SHARED=$(jq -c '.author.login = "nathanjohnpayne" | .autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
STUB_INITIAL="$DEFAULT_SHARED"
STUB_FINAL=$(jq -c '.autoMergeRequest = null' <<<"$DEFAULT_SHARED")
set +e
run_case
divergent_protective_nonshared_rc=$?
set -e
if [ "$divergent_protective_nonshared_rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate durable or unclassified arm' "$TMP/subject.out"; then
  pass "protective mode blocks a governing-base non-shared arm without mutation"
else
  fail "protective mode mutated or accepted a governing-base non-shared arm"
fi

reset_fixtures
STUB_MERGE_RC=1
STUB_FOURTH=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:05Z"}' <<<"$BASE")
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ] \
   && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'refusing to mutate post-independence arm' "$TMP/subject.out"; then
  pass "post-independence armed state fails closed without a mutation attempt"
else
  fail "post-independence armed state must exit 3 without mutation (rc=$rc)"
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
