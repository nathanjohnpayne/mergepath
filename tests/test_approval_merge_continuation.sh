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
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$STUB_INITIAL"
  else
    printf '%s\n' "${STUB_FINAL:-$STUB_INITIAL}"
  fi
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
  printf '%s\n' "$*" >> "$STUB_DIR/merge.log"
  exit "${STUB_MERGE_RC:-0}"
fi
echo "unexpected gh call: $*" >&2
exit 90
STUB
chmod +x "$TMP/bin/gh"

for script in merge-clearance-gate.sh review-feedback-accounting.sh resolve-pr-threads.sh; do
  cat > "$TMP/root/scripts/$script" <<'STUB'
#!/usr/bin/env bash
name="${0##*/}"
case "$name" in
  merge-clearance-gate.sh) exit "${STUB_GATE_RC:-0}" ;;
  review-feedback-accounting.sh) exit "${STUB_ACCOUNTING_RC:-0}" ;;
  resolve-pr-threads.sh) exit "${STUB_THREADS_RC:-0}" ;;
esac
STUB
  chmod +x "$TMP/root/scripts/$script"
done

cat > "$TMP/root/scripts/workflow/resolve_base_policy.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$MERGEPATH_REPO_ROOT/policy.yml"
STUB
chmod +x "$TMP/root/scripts/workflow/resolve_base_policy.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

BASE='{"state":"OPEN","isDraft":false,"headRefOid":"abc123","url":"https://example.test/pr/7","labels":[]}'

run_case() {
  : > "$TMP/read-count"
  echo 0 > "$TMP/read-count"
  : > "$TMP/merge.log"
  printf 'author_identity: %s\n' "${STUB_EXPECTED_AUTHOR:-nathanjohnpayne}" > "$TMP/root/policy.yml"
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" MERGEPATH_REPO_ROOT="$TMP/root" \
    STUB_INITIAL="${STUB_INITIAL:-$BASE}" STUB_FINAL="${STUB_FINAL:-${STUB_INITIAL:-$BASE}}" \
    STUB_GATE_RC="${STUB_GATE_RC:-0}" STUB_ACCOUNTING_RC="${STUB_ACCOUNTING_RC:-0}" \
    STUB_THREADS_RC="${STUB_THREADS_RC:-0}" STUB_LOGIN="${STUB_LOGIN:-nathanjohnpayne}" \
    STUB_LOGIN_RC="${STUB_LOGIN_RC:-0}" STUB_MERGE_RC="${STUB_MERGE_RC:-0}" \
    bash "$TMP/subject.sh" 7 owner/repo >"$TMP/subject.out" 2>&1
}

assert_not_ready() {
  local label="$1"
  set +e
  run_case
  rc=$?
  set -e
  if [ "$rc" -eq 4 ] && [ ! -s "$TMP/merge.log" ]; then pass "$label"; else fail "$label (rc=$rc)"; fi
}

STUB_GATE_RC=1 assert_not_ready "pending threshold-aware gate defers without arming"
STUB_GATE_RC=0 STUB_INITIAL='{"state":"OPEN","isDraft":false,"headRefOid":"abc123","url":"https://example.test/pr/7","labels":[{"name":"human-hold"}]}' assert_not_ready "blocking label defers before gate work"
STUB_INITIAL='{"state":"OPEN","isDraft":false,"headRefOid":"abc123","url":"https://example.test/pr/7","labels":[{"name":"documentation"}]}' STUB_FINAL="$BASE"
if run_case && [ -s "$TMP/merge.log" ]; then
  pass "non-blocking labels remain merge-eligible"
else
  fail "shared blocking-label policy must not reject unrelated labels"
fi
STUB_INITIAL="$BASE" STUB_ACCOUNTING_RC=1 assert_not_ready "unaccounted feedback defers without arming"
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
STUB_ACCOUNTING_RC=0
STUB_ACCOUNTING_RC=0 STUB_THREADS_RC=3 assert_not_ready "unresolved conversations defer without arming"
STUB_THREADS_RC=0 STUB_FINAL='{"state":"OPEN","isDraft":false,"headRefOid":"def456","url":"https://example.test/pr/7","labels":[]}' assert_not_ready "head drift during evaluation defers without arming"

STUB_FINAL="$BASE"
if run_case && grep -Fq 'pr merge https://example.test/pr/7 --repo owner/repo --squash --auto --match-head-commit abc123' "$TMP/merge.log"; then
  pass "under-threshold clearance arms auto-merge against the exact re-read head"
else
  fail "under-threshold clearance must arm exact-head auto-merge (log: $(cat "$TMP/merge.log" 2>/dev/null || true); output: $(cat "$TMP/subject.out" 2>/dev/null || true))"
fi

STUB_EXPECTED_AUTHOR=consumer-author STUB_LOGIN=consumer-author
if run_case && [ -s "$TMP/merge.log" ]; then
  pass "governing base policy supplies the authorized merge identity"
else
  fail "continuation must accept the author identity from the governing base policy"
fi
unset STUB_EXPECTED_AUTHOR STUB_LOGIN

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
STUB_MERGE_RC=0

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
STUB_LOGIN_RC=0

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
