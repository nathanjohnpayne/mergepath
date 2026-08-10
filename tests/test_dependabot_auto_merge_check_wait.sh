#!/usr/bin/env bash
# tests/test_dependabot_auto_merge_check_wait.sh
#
# Behavioral regression coverage for the Dependabot current-HEAD check wait
# in .github/workflows/dependabot-auto-merge.yml. The PATH-shimmed gh stub
# requires a paginated, GET, form-encoded check-name lookup and models the
# three decisions the embedded shell makes: success, never-seen timeout, and
# seen-but-pending timeout. This complements the structural checks in
# scripts/ci/check_workflow_parsers, which cannot prove the request shape or
# timeout classification.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/dependabot-auto-merge.yml"

[ -r "$WORKFLOW" ] || { echo "missing workflow: $WORKFLOW" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dependabot-current-head-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SHIM_DIR="$WORK/bin"
FUNCTIONS="$WORK/functions.sh"
SHIM_LOG="$WORK/gh.log"
mkdir -p "$SHIM_DIR"

extract_function() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ "^[[:space:]]*" name "\\(\\)[[:space:]]*\\{" {
      capture = 1
    }
    capture {
      sub(/^          /, "")
      print
    }
    capture && /^[[:space:]]*}[[:space:]]*$/ {
      exit
    }
  ' "$WORKFLOW"
}

{
  extract_function latest_check_run
  printf '\n'
  extract_function require_current_head_check_success
} >"$FUNCTIONS"

if grep -Fq 'latest_check_run()' "$FUNCTIONS" && \
   grep -Fq 'require_current_head_check_success()' "$FUNCTIONS"; then
  pass "extracted the live workflow functions"
else
  fail "could not extract current-head check functions from workflow"
fi

cat >"$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$SHIM_LOG"

require_arg() {
  local expected="$1"
  shift
  local arg
  for arg in "$@"; do
    [ "$arg" = "$expected" ] && return 0
  done
  echo "gh shim: missing expected argument: $expected" >&2
  exit 91
}

case "${1:-}" in
  pr)
    [ "${2:-}" = view ] || { echo "gh shim: unexpected pr command" >&2; exit 92; }
    printf '%s\n' "${FAKE_HEAD:-test-head}"
    ;;
  api)
    shift
    require_arg --paginate "$@"
    require_arg -X "$@"
    require_arg GET "$@"
    require_arg "repos/${GITHUB_REPOSITORY}/commits/${FAKE_HEAD:-test-head}/check-runs" "$@"
    require_arg "check_name=${FAKE_CHECK_NAME:-Label Gate}" "$@"
    require_arg per_page=100 "$@"
    case "${FAKE_MODE:-success}" in
      success)
        cat <<'JSON'
{"check_runs":[{"name":"Label Gate","status":"completed","conclusion":"success","started_at":"2026-08-04T00:01:00Z"},{"name":"Other","status":"completed","conclusion":"failure","started_at":"2026-08-04T00:02:00Z"}]}
{"check_runs":[{"name":"Label Gate","status":"completed","conclusion":"failure","started_at":"2026-08-04T00:00:00Z"}]}
JSON
        ;;
      absent)
        printf '%s\n' '{"check_runs":[]}'
        ;;
      pending)
        printf '%s\n' '{"check_runs":[{"name":"Label Gate","status":"in_progress","conclusion":null,"started_at":"2026-08-04T00:00:00Z"}]}'
        ;;
      *)
        echo "gh shim: unknown FAKE_MODE=${FAKE_MODE:-}" >&2
        exit 93
        ;;
    esac
    ;;
  *)
    echo "gh shim: unexpected command: ${1:-}" >&2
    exit 94
    ;;
esac
SHIM
chmod +x "$SHIM_DIR/gh"

run_functions() {
  local mode="$1"
  local action="$2"
  PATH="$SHIM_DIR:$PATH" \
    SHIM_LOG="$SHIM_LOG" \
    FAKE_MODE="$mode" \
    FAKE_HEAD=test-head \
    FAKE_CHECK_NAME='Label Gate' \
    GITHUB_REPOSITORY=owner/repo \
    PR_URL=https://example.test/owner/repo/pull/1 \
    REQUIRED_HEAD_CHECK_NAME='Label Gate' \
    TEST_CHECK_WAIT_SECONDS=0 \
    TEST_CHECK_POLL_SECONDS=0 \
    bash -c '
      set -euo pipefail
      source "$1"
      case "$2" in
        latest) latest_check_run "Label Gate" test-head ;;
        gate) require_current_head_check_success ;;
      esac
    ' bash "$FUNCTIONS" "$action"
}

: >"$SHIM_LOG"
if latest_output="$(run_functions success latest)"; then
  if [ "$(printf '%s' "$latest_output" | jq -c '{name,status,conclusion}')" = '{"name":"Label Gate","status":"completed","conclusion":"success"}' ]; then
    pass "paginated filtered lookup selects the latest exact-name run"
  else
    fail "latest lookup returned the wrong run: $latest_output"
  fi
else
  fail "paginated filtered lookup failed"
fi

if grep -Fq -- '--paginate -X GET repos/owner/repo/commits/test-head/check-runs -f check_name=Label Gate -F per_page=100' "$SHIM_LOG"; then
  pass "lookup uses paginated GET with a form-encoded spaced check name"
else
  fail "lookup did not use the required paginated, form-encoded request shape"
fi

if success_output="$(run_functions success gate 2>&1)"; then
  if [[ "$success_output" == *"Required check run 'Label Gate' is successful on current HEAD test-head."* ]]; then
    pass "successful latest run clears the current-head wait"
  else
    fail "success path emitted an unexpected result: $success_output"
  fi
else
  fail "successful latest run did not clear the current-head wait"
fi

set +e
absent_output="$(run_functions absent gate 2>&1)"
absent_rc=$?
set -e
if [ "$absent_rc" -ne 0 ] && \
   [[ "$absent_output" == *"never appeared on current HEAD test-head"* ]] && \
   [[ "$absent_output" == *"Compare against: gh api -X GET repos/owner/repo/commits/test-head/check-runs --paginate"* ]]; then
  pass "absent check takes the never-seen timeout path"
else
  fail "absent timeout was misclassified (rc=$absent_rc): $absent_output"
fi

set +e
pending_output="$(run_functions pending gate 2>&1)"
pending_rc=$?
set -e
if [ "$pending_rc" -ne 0 ] && \
   [[ "$pending_output" == *"did not complete successfully within 0s on current HEAD test-head"* ]] && \
   [[ "$pending_output" != *"never appeared"* ]]; then
  pass "seen pending check takes the completion timeout path"
else
  fail "pending timeout was misclassified (rc=$pending_rc): $pending_output"
fi

echo "test_dependabot_auto_merge_check_wait: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
