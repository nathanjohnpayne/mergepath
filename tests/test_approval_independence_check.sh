#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/workflow/approval-independence-check.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/approval-independence.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$SUBJECT" ]; then
  echo "FAIL: approval independence helper is missing or not executable: $SUBJECT" >&2
  exit 1
fi

mkdir -p "$TMP/bin" "$TMP/root/scripts/lib" "$TMP/root/scripts/workflow"
cp "$SUBJECT" "$TMP/root/scripts/workflow/approval-independence-check.sh"
cp "$ROOT/scripts/self-approval-detector.cjs" "$TMP/root/scripts/self-approval-detector.cjs"
cp "$ROOT/scripts/lib/gh-api-array.sh" "$TMP/root/scripts/lib/gh-api-array.sh"
cp "$ROOT/scripts/lib/reviewers-helpers.sh" "$TMP/root/scripts/lib/reviewers-helpers.sh"
cp "$ROOT/scripts/lib/review-policy-scalar.sh" "$TMP/root/scripts/lib/review-policy-scalar.sh"
cp "$ROOT/scripts/lib/blocking-labels.sh" "$TMP/root/scripts/lib/blocking-labels.sh"
cat >> "$TMP/root/scripts/self-approval-detector.cjs" <<'STUB'
if (process.env.STUB_DETECTOR_STDERR) {
  process.stderr.write(`${process.env.STUB_DETECTOR_STDERR}\n`);
}
if (process.env.STUB_DETECTOR_THROW) {
  throw new Error(process.env.STUB_DETECTOR_THROW);
}
STUB

cat > "$TMP/root/scripts/merge-clearance-gate.sh" <<'STUB'
#!/usr/bin/env bash
printf 'head=%s base_ref=%s base_sha=%s args=[%s]\n' \
  "${MERGE_CLEARANCE_EXPECTED_HEAD_SHA:-}" \
  "${MERGE_CLEARANCE_EXPECTED_BASE_REF:-}" \
  "${MERGE_CLEARANCE_EXPECTED_BASE_SHA:-}" "$*" >> "${STUB_PHASE_LOG:?}"
printf 'materialize=%s\n' "${MERGE_CLEARANCE_MATERIALIZE_DEFAULT_POLICY:-}" >> "${STUB_PHASE_LOG:?}"
if [ "${STUB_PHASE4_RC:-0}" -ne 0 ]; then
  echo "phase 4 query failed" >&2
  exit "$STUB_PHASE4_RC"
fi
printf '%s\n' "${STUB_PHASE4:-true}"
STUB
chmod +x "$TMP/root/scripts/merge-clearance-gate.sh"

cat > "$TMP/root/scripts/workflow/resolve_base_policy.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_POLICY_LOG:?}"
if [ "${STUB_POLICY_RC:-0}" -ne 0 ]; then
  echo "policy resolution failed" >&2
  exit "$STUB_POLICY_RC"
fi
materialized=$(mktemp "${TMPDIR:-/tmp}/stub-base-policy.XXXXXX")
cp "${STUB_POLICY_PATH:?}" "$materialized"
printf '%s\n' "$materialized"
STUB
chmod +x "$TMP/root/scripts/workflow/resolve_base_policy.sh"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" != "api" ]; then
  echo "unexpected gh call: $*" >&2
  exit 90
fi
if [ "${2:-}" = "--paginate" ]; then
  count=$(cat "$STUB_DIR/review-count")
  count=$((count + 1))
  echo "$count" > "$STUB_DIR/review-count"
  printf 'reviews-%s\n' "$count" >> "$STUB_DIR/events.log"
  if [ "${STUB_REVIEWS_RC:-0}" -ne 0 ]; then
    echo "review fetch failed" >&2
    exit "$STUB_REVIEWS_RC"
  fi
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "${STUB_REVIEWS_PAGE_1:-[]}" "${STUB_REVIEWS_PAGE_2:-[]}"
  else
    printf '%s\n' "${STUB_REVIEWS_AFTER_PAGE_1:-[]}" "${STUB_REVIEWS_AFTER_PAGE_2:-[]}"
  fi
  exit 0
fi
count=$(cat "$STUB_DIR/pr-count")
count=$((count + 1))
echo "$count" > "$STUB_DIR/pr-count"
printf 'pr-%s\n' "$count" >> "$STUB_DIR/events.log"
if [ "${STUB_PR_RC:-0}" -ne 0 ]; then
  echo "PR fetch failed" >&2
  exit "$STUB_PR_RC"
fi
if [ "$count" -eq 1 ]; then
  printf '%s\n' "$STUB_PR"
else
  printf '%s\n' "$STUB_PR_AFTER"
fi
STUB
chmod +x "$TMP/bin/gh"

cat > "$TMP/root/policy.yml" <<'POLICY'
author_identity: nathanjohnpayne
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
  - nathanpayne-cursor
POLICY

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() {
  echo "FAIL: $*${TMP:+ — $(tr '\n' ' ' < "$TMP/err" 2>/dev/null || true)}" >&2
  FAIL=$((FAIL + 1))
}

BASE_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"base":{"ref":"main","sha":"base123","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: claude","labels":[]}'
BASE_REVIEW='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'

reset_fixtures() {
  unset STUB_DETECTOR_STDERR STUB_DETECTOR_THROW
  STUB_PR="$BASE_PR"
  STUB_PR_AFTER="$BASE_PR"
  STUB_REVIEWS_PAGE_1="$BASE_REVIEW"
  STUB_REVIEWS_PAGE_2='[]'
  STUB_REVIEWS_AFTER_PAGE_1="$BASE_REVIEW"
  STUB_REVIEWS_AFTER_PAGE_2='[]'
  STUB_PHASE4=true
  STUB_PHASE4_RC=0
  STUB_PR_RC=0
  STUB_REVIEWS_RC=0
  STUB_POLICY_RC=0
  STUB_POLICY_PATH="$TMP/root/policy.yml"
  MERGE_LOGIN=nathanjohnpayne
}

run_case() {
  echo 0 > "$TMP/review-count"
  echo 0 > "$TMP/pr-count"
  : > "$TMP/events.log"
  : > "$TMP/phase.log"
  : > "$TMP/policy.log"
  PATH="$TMP/bin:$PATH" MERGEPATH_REPO_ROOT="$TMP/root" STUB_DIR="$TMP" \
    STUB_PR="$STUB_PR" STUB_PR_AFTER="$STUB_PR_AFTER" \
    STUB_REVIEWS_PAGE_1="$STUB_REVIEWS_PAGE_1" STUB_REVIEWS_PAGE_2="$STUB_REVIEWS_PAGE_2" \
    STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_AFTER_PAGE_1" \
    STUB_REVIEWS_AFTER_PAGE_2="$STUB_REVIEWS_AFTER_PAGE_2" \
    STUB_PHASE4="$STUB_PHASE4" STUB_PHASE4_RC="$STUB_PHASE4_RC" \
    STUB_PR_RC="$STUB_PR_RC" STUB_REVIEWS_RC="$STUB_REVIEWS_RC" \
    STUB_POLICY_RC="$STUB_POLICY_RC" STUB_POLICY_PATH="$STUB_POLICY_PATH" \
    STUB_PHASE_LOG="$TMP/phase.log" STUB_POLICY_LOG="$TMP/policy.log" \
    STUB_DETECTOR_STDERR="${STUB_DETECTOR_STDERR:-}" \
    STUB_DETECTOR_THROW="${STUB_DETECTOR_THROW:-}" \
    bash "$TMP/root/scripts/workflow/approval-independence-check.sh" \
      --repo owner/repo --pr 7 --head abc123 \
      --base-ref main --base-sha base123 --merge-login "$MERGE_LOGIN" \
      >"$TMP/out" 2>"$TMP/err"
}

reset_fixtures
if run_case && jq -e '
  .stable == true and
  .sharedAuthor == true and
  .requiresExternalReview == true and
  .after.eligibleApproval == true and
  .after.approvals[0].reviewer == "nathanpayne-codex"
' "$TMP/out" >/dev/null; then
  pass "a stable different-agent current-head Phase 4 approval remains eligible"
else
  fail "different-agent current-head approval should be eligible: $(cat "$TMP/err" 2>/dev/null)"
fi

if [ "$(tr '\n' ' ' < "$TMP/events.log")" = "reviews-1 pr-1 reviews-2 pr-2 " ] \
   && grep -Fq 'head=abc123 base_ref=main base_sha=base123' "$TMP/phase.log" \
   && grep -Fq 'materialize=true' "$TMP/phase.log" \
   && grep -Fq -- '--base-ref main --base-sha base123 --default-branch main --materialize-default' "$TMP/policy.log"; then
  pass "double snapshots, pinned requiredness, and exact-base policy resolution use the safety order"
else
  fail "live read/policy order drifted: events=$(tr '\n' ' ' < "$TMP/events.log") phase=$(cat "$TMP/phase.log") policy=$(cat "$TMP/policy.log")"
fi

reset_fixtures
STUB_DETECTOR_STDERR="benign detector diagnostic"
if run_case && jq -e '.stable == true and .after.eligibleApproval == true' "$TMP/out" >/dev/null; then
  pass "benign detector stderr cannot corrupt the machine-readable result"
else
  fail "detector stderr contaminated successful JSON output"
fi

reset_fixtures
STUB_DETECTOR_THROW="detector failure diagnostic sentinel"
set +e; run_case; detector_failure_rc=$?; set -e
if [ "$detector_failure_rc" -eq 3 ] \
   && grep -Fq 'detector failure diagnostic sentinel' "$TMP/err"; then
  pass "detector failures preserve their stderr diagnostic"
else
  fail "detector failure stderr was lost (rc=$detector_failure_rc)"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":21,"user":{"login":"nathanpayne-claude"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:01Z"}]'
STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_PAGE_1"
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"base":{"ref":"main","sha":"base123","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[]}'
STUB_PR_AFTER="$STUB_PR"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ] && jq -e '.after.independentApproval == true and (.after.blockingApprovals | length) == 1' "$TMP/out" >/dev/null; then
  pass "a same-agent approval must be dismissed even when an independent approval coexists"
else
  fail "mixed approvals must not leave a native same-agent fallback (rc=$rc)"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":18,"user":{"login":"nathanpayne-claude"},"state":"APPROVED","commit_id":"old","submitted_at":"2026-01-06T00:00:00Z"},{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'
STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_PAGE_1"
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"base":{"ref":"main","sha":"base123","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[]}'
STUB_PR_AFTER="$STUB_PR"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ]; then pass "a stale independent approval cannot mask a current-head same-agent approval"; else fail "stale independent approval masked same-agent approval (rc=$rc)"; fi

reset_fixtures
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"base":{"ref":"main","sha":"base123","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[]}'
STUB_PR_AFTER="$STUB_PR"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ]; then pass "a live body edit to the approving agent revokes the carried approval"; else fail "same-agent live body passed (rc=$rc)"; fi

reset_fixtures
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"base":{"ref":"main","sha":"base123","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[]}'
STUB_PR_AFTER="$STUB_PR"
STUB_PHASE4=false
if run_case; then pass "the same registered agent remains eligible under threshold"; else fail "under-threshold same-agent approval should remain eligible"; fi

reset_fixtures
STUB_PR_AFTER='{"state":"open","draft":false,"head":{"sha":"abc123"},"base":{"ref":"main","sha":"base123","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: claude","labels":[{"name":"human-hold"}]}'
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ]; then pass "a blocking label appearing during evaluation prevents the write"; else fail "late human-hold passed (rc=$rc)"; fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"old","submitted_at":"2026-01-07T00:00:00Z"}]'
STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_PAGE_1"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ]; then pass "an older-head approval cannot satisfy final independence"; else fail "stale-head approval passed (rc=$rc)"; fi

reset_fixtures
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"base":{"ref":"main","sha":"base123","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[]}'
STUB_PR_AFTER="$STUB_PR"
STUB_REVIEWS_PAGE_1='[{"id":19,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"old","submitted_at":"2026-01-06T00:00:00Z"},{"id":20,"user":{"login":"nathanpayne-claude"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'
STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_PAGE_1"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ] && jq -e '(.after.blockingApprovals | map(.id) | index(19)) != null and .after.independentApproval == true' "$TMP/out" >/dev/null; then
  pass "a standing old-head same-agent approval blocks beside a current-head independent approval"
else
  fail "old-head same-agent approval remained as a native fallback (rc=$rc)"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'
STUB_REVIEWS_PAGE_2='[{"id":21,"user":{"login":"nathanpayne-codex"},"state":"CHANGES_REQUESTED","commit_id":"abc123","submitted_at":"2026-01-08T00:00:00Z"}]'
STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_PAGE_1"
STUB_REVIEWS_AFTER_PAGE_2="$STUB_REVIEWS_PAGE_2"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ]; then pass "a later paginated changes-requested review supersedes approval"; else fail "later changes-requested state passed (rc=$rc)"; fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":21,"user":{"login":"nathanpayne-codex"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-01-08T00:00:00Z"}]'
STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_PAGE_1"
if run_case; then pass "a later COMMENTED review does not erase an opinionated approval"; else fail "COMMENTED noise erased approval"; fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":21,"user":{"login":"nathanpayne-codex"},"state":"CHANGES_REQUESTED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'
STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_PAGE_1"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ]; then pass "equal review timestamps resolve by larger numeric id"; else fail "equal-time lower-id approval survived (rc=$rc)"; fi

reset_fixtures
STUB_REVIEWS_AFTER_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"DISMISSED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ] && grep -q 'opinionated review state changed' "$TMP/err"; then pass "an approval dismissed between paginated snapshots defers"; else fail "mid-read dismissal was consumed (rc=$rc)"; fi

reset_fixtures
STUB_REVIEWS_AFTER_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":21,"user":{"login":"nathanpayne-claude"},"state":"CHANGES_REQUESTED","commit_id":"abc123","submitted_at":"2026-01-08T00:00:00Z"}]'
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ] && grep -q 'opinionated review state changed' "$TMP/err"; then
  pass "a second reviewer's new changes-requested opinion between snapshots defers"
else
  fail "cross-reviewer opinion change was not detected (rc=$rc)"
fi

reset_fixtures
STUB_REVIEWS_AFTER_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":21,"user":{"login":"nathanpayne-claude"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-01-08T00:00:00Z"}]'
if run_case; then
  pass "a second reviewer's COMMENTED noise between snapshots does not revoke approval"
else
  fail "COMMENTED noise changed the opinionated snapshot"
fi

reset_fixtures
STUB_PR_AFTER='{"state":"open","draft":false,"head":{"sha":"abc123"},"base":{"ref":"release","sha":"base456","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: claude","labels":[]}'
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ] && grep -q 'base ref changed' "$TMP/err"; then pass "same-head base retarget defers"; else fail "base retarget mixed policies (rc=$rc)"; fi

reset_fixtures
STUB_PR_AFTER='{"state":"open","draft":false,"head":{"sha":"abc123"},"base":{"ref":"main","sha":"base456","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: claude","labels":[]}'
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ] && grep -q 'base sha changed' "$TMP/err"; then pass "same-head base advance defers"; else fail "base advance mixed policies (rc=$rc)"; fi

reset_fixtures
STUB_PR_AFTER='{"state":"open","draft":false,"head":{"sha":"def456"},"base":{"ref":"main","sha":"base123","repo":{"default_branch":"main"}},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: claude","labels":[]}'
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ]; then pass "head drift during the live recheck defers"; else fail "head drift passed (rc=$rc)"; fi

reset_fixtures
STUB_PHASE4_RC=2
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "indeterminate Phase 4 applicability fails closed"; else fail "Phase 4 error did not fail closed (rc=$rc)"; fi

reset_fixtures
STUB_REVIEWS_RC=7
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "an unreadable paginated review history fails closed"; else fail "review API error passed (rc=$rc)"; fi

reset_fixtures
STUB_REVIEWS_PAGE_1='{}'
STUB_REVIEWS_AFTER_PAGE_1='{}'
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "a non-array paginated response fails closed"; else fail "malformed pagination passed (rc=$rc)"; fi

reset_fixtures
STUB_REVIEWS_AFTER_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":21,"user":{"login":"nathanpayne-claude"},"state":"CHANGES_REQUESTED","commit_id":"abc123"}]'
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "a malformed opinionated review object fails closed"; else fail "malformed review object passed (rc=$rc)"; fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"z"}]'
STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_PAGE_1"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "a non-canonical review timestamp fails closed"; else fail "non-canonical timestamp passed (rc=$rc)"; fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":20,"user":{"login":"nathanpayne-codex"},"state":"CHANGES_REQUESTED","commit_id":"abc123","submitted_at":"2026-01-08T00:00:00Z"}]'
STUB_REVIEWS_AFTER_PAGE_1="$STUB_REVIEWS_PAGE_1"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "duplicate review ids fail closed before state reduction"; else fail "duplicate review ids passed (rc=$rc)"; fi

reset_fixtures
STUB_PR_RC=8
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "an unreadable PR response fails closed"; else fail "PR API error passed (rc=$rc)"; fi

for malformed_labels in absent null object; do
  reset_fixtures
  case "$malformed_labels" in
    absent) STUB_PR=$(jq -c 'del(.labels)' <<<"$BASE_PR") ;;
    null) STUB_PR=$(jq -c '.labels = null' <<<"$BASE_PR") ;;
    object) STUB_PR=$(jq -c '.labels = {}' <<<"$BASE_PR") ;;
  esac
  STUB_PR_AFTER="$STUB_PR"
  set +e; run_case; rc=$?; set -e
  if [ "$rc" -eq 3 ]; then pass "$malformed_labels labels metadata fails closed"; else fail "$malformed_labels labels metadata passed (rc=$rc)"; fi
done

reset_fixtures
STUB_POLICY_PATH="$TMP/root/empty-policy.yml"
printf 'author_identity: nathanjohnpayne\navailable_reviewers: []\n' > "$STUB_POLICY_PATH"
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "an unavailable reviewer allow-list fails closed"; else fail "empty reviewer list passed (rc=$rc)"; fi

reset_fixtures
MERGE_LOGIN=wrong
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "the merge identity is revalidated against the pinned base policy"; else fail "wrong final merge identity passed (rc=$rc)"; fi

reset_fixtures
STUB_POLICY_RC=9
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 3 ]; then pass "an unreadable pinned base policy fails closed"; else fail "policy resolver failure passed (rc=$rc)"; fi

reset_fixtures
STUB_PR_AFTER=$(jq -c '.body = "Authoring-Agent: codex"' <<<"$BASE_PR")
set +e; run_case; rc=$?; set -e
if [ "$rc" -eq 1 ] && grep -q 'metadata changed' "$TMP/err"; then pass "a body edit between the two PR snapshots defers"; else fail "mid-read body edit passed (rc=$rc)"; fi

echo "test_approval_independence_check: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
