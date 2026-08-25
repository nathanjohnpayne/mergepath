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

cat > "$TMP/root/scripts/merge-clearance-gate.sh" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_PHASE4_RC:-0}" -ne 0 ]; then
  echo "phase 4 query failed" >&2
  exit "$STUB_PHASE4_RC"
fi
printf '%s\n' "${STUB_PHASE4:-true}"
STUB
chmod +x "$TMP/root/scripts/merge-clearance-gate.sh"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_GH_LOG:-/dev/null}"
if [ "$1" != "api" ]; then
  echo "unexpected gh call: $*" >&2
  exit 90
fi
if [ "${2:-}" = "--paginate" ]; then
  if [ "${STUB_REVIEWS_RC:-0}" -ne 0 ]; then
    echo "review fetch failed" >&2
    exit "$STUB_REVIEWS_RC"
  fi
  printf '%s\n' "${STUB_REVIEWS_PAGE_1:-[]}" "${STUB_REVIEWS_PAGE_2:-[]}"
  exit 0
fi
if [ "${STUB_PR_RC:-0}" -ne 0 ]; then
  echo "PR fetch failed" >&2
  exit "$STUB_PR_RC"
fi
printf '%s\n' "$STUB_PR"
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
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

BASE_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: claude","labels":[]}'
BASE_REVIEW='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'

reset_fixtures() {
  STUB_PR="$BASE_PR"
  STUB_REVIEWS_PAGE_1="$BASE_REVIEW"
  STUB_REVIEWS_PAGE_2='[]'
  STUB_PHASE4=true
  STUB_PHASE4_RC=0
  STUB_PR_RC=0
  STUB_REVIEWS_RC=0
  POLICY="$TMP/root/policy.yml"
}

run_case() {
  : > "$TMP/gh.log"
  PATH="$TMP/bin:$PATH" MERGEPATH_REPO_ROOT="$TMP/root" \
    STUB_PR="$STUB_PR" STUB_REVIEWS_PAGE_1="$STUB_REVIEWS_PAGE_1" \
    STUB_REVIEWS_PAGE_2="$STUB_REVIEWS_PAGE_2" STUB_PHASE4="$STUB_PHASE4" \
    STUB_PHASE4_RC="$STUB_PHASE4_RC" STUB_PR_RC="$STUB_PR_RC" \
    STUB_REVIEWS_RC="$STUB_REVIEWS_RC" \
    STUB_GH_LOG="$TMP/gh.log" \
    bash "$TMP/root/scripts/workflow/approval-independence-check.sh" \
      --repo owner/repo --pr 7 --head abc123 --policy "$POLICY" \
      >"$TMP/out" 2>"$TMP/err"
}

reset_fixtures
if run_case && jq -e '.eligibleApproval == true and .approvals[0].reviewer == "nathanpayne-codex"' "$TMP/out" >/dev/null; then
  pass "a different-agent current-head Phase 4 approval remains eligible"
else
  fail "different-agent current-head approval should be eligible: $(cat "$TMP/err" 2>/dev/null)"
fi
if sed -n '1p' "$TMP/gh.log" | grep -q 'reviews' \
   && sed -n '2p' "$TMP/gh.log" | grep -q 'pulls/7$'; then
  pass "the mutable PR body is the final remote read after review pagination"
else
  fail "live PR metadata must be fetched after the complete review history: $(tr '\n' ';' < "$TMP/gh.log")"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":21,"user":{"login":"nathanpayne-claude"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:01Z"}]'
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[]}'
if run_case && jq -e '.eligibleApproval == true and (.approvals | length) == 2' "$TMP/out" >/dev/null; then
  pass "an independent current-head approval survives beside a same-agent approval"
else
  fail "mixed current-head approvals should pass when one remains independent"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":18,"user":{"login":"nathanpayne-claude"},"state":"APPROVED","commit_id":"old","submitted_at":"2026-01-06T00:00:00Z"},{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[]}'
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '.approvals | length == 1 and .[0].reviewer == "nathanpayne-codex"' "$TMP/out" >/dev/null; then
  pass "a stale independent approval cannot mask a current-head same-agent approval"
else
  fail "only current-head approvals may participate in final independence (rc=$rc)"
fi

reset_fixtures
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[]}'
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 1 ] && jq -e '.eligibleApproval == false and .approvals[0].decision.reason == "same-agent-phase-4-approval"' "$TMP/out" >/dev/null; then
  pass "a live body edit to the approving agent revokes the carried approval"
else
  fail "same-agent live body must defer with a classified decision (rc=$rc)"
fi

reset_fixtures
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[]}'
STUB_PHASE4=false
if run_case; then
  pass "the same registered agent remains eligible under threshold"
else
  fail "under-threshold same-agent approval should remain policy-compliant"
fi

reset_fixtures
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: codex","labels":[{"name":"needs-external-review"}]}'
STUB_PHASE4=false
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "a newly added external-review label forces Phase 4 after the query"
else
  fail "live force-on label must not be lost to query/read ordering (rc=$rc)"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":19,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"old","submitted_at":"2026-01-06T00:00:00Z"}]'
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "an approval on an older head cannot satisfy final independence"
else
  fail "stale-head approval must defer (rc=$rc)"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'
STUB_REVIEWS_PAGE_2='[{"id":21,"user":{"login":"nathanpayne-codex"},"state":"CHANGES_REQUESTED","commit_id":"abc123","submitted_at":"2026-01-08T00:00:00Z"}]'
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "a later paginated changes-requested review supersedes approval"
else
  fail "latest opinionated state across pages must win (rc=$rc)"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":21,"user":{"login":"nathanpayne-codex"},"state":"COMMENTED","commit_id":"abc123","submitted_at":"2026-01-08T00:00:00Z"}]'
if run_case; then
  pass "a later COMMENTED review does not erase the latest opinionated approval"
else
  fail "informational comments must not supersede approval"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='[{"id":20,"user":{"login":"nathanpayne-codex"},"state":"APPROVED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"},{"id":21,"user":{"login":"nathanpayne-codex"},"state":"CHANGES_REQUESTED","commit_id":"abc123","submitted_at":"2026-01-07T00:00:00Z"}]'
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "equal review timestamps resolve by the larger numeric review id"
else
  fail "equal-time latest-state tie must not preserve the lower-id approval (rc=$rc)"
fi

reset_fixtures
STUB_PR='{"state":"open","draft":false,"head":{"sha":"abc123"},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: claude","labels":[{"name":"human-hold"}]}'
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'blocking labels appeared.*human-hold' "$TMP/err"; then
  pass "a blocking label that appears during evaluation prevents the write"
else
  fail "late human-hold must defer final approval consumption (rc=$rc)"
fi

reset_fixtures
STUB_PR='{"state":"open","draft":false,"head":{"sha":"def456"},"user":{"login":"nathanjohnpayne"},"body":"Authoring-Agent: claude","labels":[]}'
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'head changed' "$TMP/err"; then
  pass "head drift during the live recheck defers"
else
  fail "head drift must defer without becoming infrastructure (rc=$rc)"
fi

reset_fixtures
STUB_PHASE4_RC=2
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ]; then
  pass "indeterminate Phase 4 applicability fails closed as infrastructure"
else
  fail "Phase 4 query failure must exit 3 (rc=$rc)"
fi

reset_fixtures
STUB_REVIEWS_RC=7
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ] && grep -q 'failed to fetch reviews' "$TMP/err"; then
  pass "an unreadable paginated review history fails closed"
else
  fail "review API failure must exit 3 with its diagnostic (rc=$rc)"
fi

reset_fixtures
STUB_REVIEWS_PAGE_1='{}'
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ] && grep -Eq 'failed to fetch reviews|not a stream of JSON arrays' "$TMP/err"; then
  pass "a successful but non-array paginated response fails closed"
else
  fail "malformed review pagination shape must be infrastructure (rc=$rc)"
fi

reset_fixtures
STUB_PR_RC=8
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ] && grep -q 'could not fetch live PR metadata' "$TMP/err"; then
  pass "an unreadable final PR body fails closed"
else
  fail "PR metadata failure must exit 3 (rc=$rc)"
fi

reset_fixtures
POLICY="$TMP/root/empty-policy.yml"
printf 'author_identity: nathanjohnpayne\navailable_reviewers: []\n' > "$POLICY"
set +e
run_case
rc=$?
set -e
if [ "$rc" -eq 3 ]; then
  pass "an unavailable reviewer allow-list fails closed"
else
  fail "empty reviewer allow-list must be infrastructure, not no-approval (rc=$rc)"
fi

echo "test_approval_independence_check: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
