#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/workflow/approval-merge-continuation.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/approval-continuation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/root/scripts/lib" "$TMP/root/scripts/workflow"
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
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  count=$(cat "$STUB_DIR/read-count")
  count=$((count + 1))
  echo "$count" > "$STUB_DIR/read-count"
  printf 'pr-view-%s\n' "$count" >> "$STUB_DIR/events.log"
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$STUB_INITIAL"
  else
    printf '%s\n' "${STUB_FINAL:-$STUB_INITIAL}"
  fi
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  printf 'merge\n' >> "$STUB_DIR/events.log"
  printf '%s\n' "$*" >> "$STUB_DIR/merge.log"
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
  review-feedback-accounting.sh) exit "${STUB_ACCOUNTING_RC:-0}" ;;
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
exit "${STUB_INDEPENDENCE_RC:-0}"
STUB
chmod +x "$TMP/root/scripts/workflow/approval-independence-check.sh"

cat > "$TMP/root/scripts/workflow/resolve_base_policy.sh" <<'STUB'
#!/usr/bin/env bash
printf 'policy\n' >> "${STUB_DIR:?}/events.log"
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
  /- name: Retract shared-author auto-merge/ {in_step=1}
  in_step && /^        run: \|/ {in_run=1; next}
  in_run && /^  # ─/ {exit}
  in_run && /^          / {sub(/^          /, ""); print; next}
  in_run && /^[[:space:]]*$/ {print; next}
  in_run {exit}
' "$ROOT/.github/workflows/agent-review.yml" > "$WORKFLOW_RETRACTION"
[ -s "$WORKFLOW_RETRACTION" ] || {
  echo "FAIL: could not extract shared-author workflow retraction step" >&2
  exit 1
}
chmod +x "$WORKFLOW_RETRACTION"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

BASE='{"state":"OPEN","isDraft":false,"headRefOid":"abc123","baseRefName":"main","baseRefOid":"base123","url":"https://example.test/pr/7","labels":[],"author":{"login":"outside-contributor"},"autoMergeRequest":null}'
SHARED_BASE=$(jq -c '.author.login = "nathanjohnpayne"' <<<"$BASE")

run_case() {
  local -a subject_args=(7 owner/repo)
  local stub_initial stub_final
  if [ -n "${STUB_SUBJECT_MODE:-}" ]; then
    subject_args=(--disarm-shared-author-only 7 owner/repo)
  fi
  stub_initial="${STUB_INITIAL:-$BASE}"
  stub_final="${STUB_FINAL:-$stub_initial}"
  : > "$TMP/read-count"
  echo 0 > "$TMP/read-count"
  : > "$TMP/merge.log"
  : > "$TMP/readiness.log"
  : > "$TMP/required-checks.log"
  : > "$TMP/independence.log"
  : > "$TMP/events.log"
  printf 'author_identity: %s\n' "${STUB_EXPECTED_AUTHOR:-nathanjohnpayne}" > "$TMP/root/policy.yml"
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" MERGEPATH_REPO_ROOT="$TMP/root" \
    STUB_INITIAL="$stub_initial" STUB_FINAL="$stub_final" \
    STUB_READINESS_RC="${STUB_READINESS_RC:-0}" STUB_GATE_RC="${STUB_GATE_RC:-0}" \
    STUB_ACCOUNTING_RC="${STUB_ACCOUNTING_RC:-0}" \
    STUB_THREADS_RC="${STUB_THREADS_RC:-0}" STUB_LOGIN="${STUB_LOGIN:-nathanjohnpayne}" \
    STUB_REQUIRED_CHECKS_RC="${STUB_REQUIRED_CHECKS_RC:-0}" \
    STUB_INDEPENDENCE_RC="${STUB_INDEPENDENCE_RC:-0}" \
    STUB_SHARED_AUTHOR="${STUB_SHARED_AUTHOR:-false}" \
    STUB_REQUIRES_EXTERNAL="${STUB_REQUIRES_EXTERNAL:-false}" \
    STUB_POLICY_RC="${STUB_POLICY_RC:-0}" \
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
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" \
    STUB_INITIAL="$stub_initial" STUB_FINAL="$stub_final" \
    STUB_MERGE_RC="${STUB_MERGE_RC:-0}" \
    AUTHOR_IDENTITY="${STUB_WORKFLOW_AUTHOR_IDENTITY-}" \
    PR_NUMBER=7 REPO=owner/repo \
    bash "$WORKFLOW_RETRACTION" >"$TMP/workflow.out" 2>&1
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
  unset STUB_INITIAL STUB_FINAL STUB_READINESS_RC STUB_GATE_RC
  unset STUB_ACCOUNTING_RC STUB_THREADS_RC STUB_LOGIN STUB_LOGIN_RC
  unset STUB_MERGE_RC STUB_EXPECTED_AUTHOR STUB_REQUIRED_CHECKS_RC
  unset STUB_INDEPENDENCE_RC STUB_SHARED_AUTHOR STUB_REQUIRES_EXTERNAL
  unset STUB_SUBJECT_MODE STUB_POLICY_RC STUB_WORKFLOW_AUTHOR_IDENTITY
}

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
STUB_FINAL="$BASE"
if run_case && [ -s "$TMP/merge.log" ]; then
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

# #1094: the final continuation must not trust the approval event's immutable
# body snapshot. Revalidate live approval independence after the authoritative
# PR re-read, and distinguish a definitive ineligible approval from an
# indeterminate API/config result.
reset_fixtures
STUB_INDEPENDENCE_RC=1
assert_not_ready "a live same-agent approval after a PR-body edit defers without arming"

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
   && grep -Fq 'read_count=2 args=[--repo owner/repo --pr 7 --head abc123 --base-ref main --base-sha base123 --merge-login nathanjohnpayne]' "$TMP/independence.log" \
   && grep -Fq 'pr merge https://example.test/pr/7 --repo owner/repo --squash --auto --match-head-commit abc123' "$TMP/merge.log" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 policy pr-view-2 independence merge " ]; then
  pass "final metadata, pinned live independence, and exact-head auto-merge run in that order"
else
  fail "continuation safety order drifted (events: $(tr '\n' ' ' < "$TMP/events.log"); readiness: $(cat "$TMP/readiness.log" 2>/dev/null || true); independence: $(cat "$TMP/independence.log" 2>/dev/null || true); merge: $(cat "$TMP/merge.log" 2>/dev/null || true); output: $(cat "$TMP/subject.out" 2>/dev/null || true))"
fi

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
   && grep -Fq -- '--disable-auto --match-head-commit abc123' "$TMP/merge.log" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 merge pr-view-2 " ] \
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
if run_case && [ -s "$TMP/merge.log" ]; then
  pass "native non-shared Phase 4 authors retain GitHub's author-independent auto-merge path"
else
  fail "native non-shared Phase 4 approval was over-blocked"
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
     && grep -Fq -- '--disable-auto --match-head-commit abc123' "$TMP/merge.log" \
     && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 merge pr-view-2 " ]; then
    pass "shared-author $early_failure invalidation retracts the existing arm before exiting"
  else
    fail "shared-author $early_failure invalidation did not retract first (rc=$early_failure_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
  fi
done

reset_fixtures
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
STUB_POLICY_RC=9
set +e
run_case
armed_policy_failure_rc=$?
set -e
if [ "$armed_policy_failure_rc" -eq 4 ] \
   && grep -Fq -- '--disable-auto --match-head-commit abc123' "$TMP/merge.log" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 merge pr-view-2 " ]; then
  pass "shared-author retraction precedes an unreadable governing policy"
else
  fail "policy failure stranded a shared-author arm (rc=$armed_policy_failure_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

reset_fixtures
STUB_SUBJECT_MODE=disarm
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
if run_case \
   && grep -Fq -- '--disable-auto --match-head-commit abc123' "$TMP/merge.log" \
   && grep -Fq 'shared-author auto-merge is disarmed' "$TMP/subject.out"; then
  pass "the approval guard can invoke the shared-author-only retraction mode"
else
  fail "shared-author-only retraction mode did not verify the disarm"
fi

for failed_readback in still_armed moved_head; do
  reset_fixtures
  STUB_SUBJECT_MODE=disarm
  STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
  case "$failed_readback" in
    still_armed) STUB_FINAL="$STUB_INITIAL" ;;
    moved_head) STUB_FINAL=$(jq -c '.headRefOid = "def456"' <<<"$SHARED_BASE") ;;
  esac
  set +e
  run_case
  failed_readback_rc=$?
  set -e
  if [ "$failed_readback_rc" -eq 3 ] \
     && grep -Fq -- '--disable-auto --match-head-commit abc123' "$TMP/merge.log"; then
    pass "a $failed_readback disarm readback fails closed after the retraction write"
  else
    fail "a $failed_readback disarm readback was accepted (rc=$failed_readback_rc)"
  fi
done

reset_fixtures
STUB_SUBJECT_MODE=disarm
if run_case && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'native non-shared PR requires no auto-merge invalidation' "$TMP/subject.out" \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 " ]; then
  pass "shared-author-only retraction is a no-op for a native non-shared PR"
else
  fail "shared-author-only retraction affected a native non-shared PR"
fi

reset_fixtures
STUB_POLICY_RC=9
set +e
run_case
nonshared_policy_failure_rc=$?
set -e
if [ "$nonshared_policy_failure_rc" -eq 3 ] \
   && [ "$(tr '\n' ' ' < "$TMP/events.log")" = "pr-view-1 policy " ] \
   && [ ! -s "$TMP/merge.log" ]; then
  pass "native non-shared arming still fails closed on an unreadable governing policy"
else
  fail "native non-shared path bypassed its policy authorization (rc=$nonshared_policy_failure_rc; events=$(tr '\n' ' ' < "$TMP/events.log"))"
fi

# Run the inline workflow implementation through the rollout states that a
# structural grep cannot prove: optional-token repos, an old trusted helper,
# non-shared arms, shared arms, and a failed retraction readback.
reset_fixtures
if run_workflow_retraction_case && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'no auto-merge request to retract' "$TMP/workflow.out"; then
  pass "workflow retraction leaves an unarmed no-token repository green"
else
  fail "workflow retraction made an unarmed no-token repository fail"
fi

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=nathanjohnpayne
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$BASE")
if run_workflow_retraction_case && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'Native non-shared PR requires no auto-merge invalidation' "$TMP/workflow.out"; then
  pass "workflow retraction leaves a native non-shared arm untouched"
else
  fail "workflow retraction disrupted a native non-shared arm"
fi

reset_fixtures
STUB_WORKFLOW_AUTHOR_IDENTITY=nathanjohnpayne
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
STUB_FINAL="$SHARED_BASE"
if run_workflow_retraction_case \
   && grep -Fq 'pr merge https://example.test/pr/7 --repo owner/repo --disable-auto' "$TMP/merge.log" \
   && grep -Fq 'Shared-author auto-merge retraction verified' "$TMP/workflow.out"; then
  pass "workflow retraction is self-contained for the first consumer rollout"
else
  fail "workflow retraction could not disable and verify a shared-author arm"
fi

reset_fixtures
STUB_INITIAL=$(jq -c '.autoMergeRequest = {"enabledAt":"2026-01-09T00:00:00Z"}' <<<"$SHARED_BASE")
set +e
run_workflow_retraction_case
workflow_missing_identity_rc=$?
set -e
if [ "$workflow_missing_identity_rc" -eq 1 ] && [ ! -s "$TMP/merge.log" ] \
   && grep -Fq 'author_identity is unavailable' "$TMP/workflow.out"; then
  pass "workflow retraction fails closed only when an existing arm cannot be classified"
else
  fail "workflow retraction accepted an unclassified existing arm (rc=$workflow_missing_identity_rc)"
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
if run_case && [ -s "$TMP/merge.log" ]; then
  pass "governing base policy supplies the authorized merge identity"
else
  fail "continuation must accept the author identity from the governing base policy"
fi

reset_fixtures
STUB_MERGE_RC=1
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ] && [ -s "$TMP/merge.log" ]; then
  pass "failed exact-head merge arming surfaces as an infrastructure error"
else
  fail "failed exact-head merge arming must exit 3 (rc=$rc)"
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

echo "test_approval_merge_continuation: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
