#!/usr/bin/env bash
# Unit tests for scripts/hooks/gh-pr-guard.sh under the #411
# wrapper-mandatory token contract.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/hooks/gh-pr-guard.sh"

[[ -x "$HOOK" ]] || { echo "missing or non-executable $HOOK" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-guard-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "config get")
    echo "${STUB_ACTIVE_USER:-nathanpayne-claude}"
    exit 0
    ;;
  "pr view")
    json_fields=""
    for ((i=1; i<=$#; i++)); do
      if [ "${!i}" = "--json" ]; then
        next=$((i+1))
        json_fields="${!next}"
        break
      fi
    done
    case "$json_fields" in
      *body*)
        printf '%s\n' "${STUB_PR_BODY:-}"
        printf '"additions": %s\n' "${STUB_PR_ADDITIONS:-0}"
        printf '"deletions": %s\n' "${STUB_PR_DELETIONS:-0}"
        printf '"head": "%s"\n' "${STUB_PR_HEAD:-feature/some-branch}"
        printf '"author": "%s"\n' "${STUB_PR_AUTHOR:-nathanjohnpayne}"
        exit 0
        ;;
      *)
        echo "${STUB_MERGE_STATE:-CLEAN}"
        if [ -n "${STUB_LABELS:-}" ]; then
          echo "$STUB_LABELS" | tr ';' '\n'
        fi
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

run_hook() {
  local cmd="$1"
  local merge_state="${2:-CLEAN}"
  local labels="${3:-}"
  local expected_reviewer="${4:-nathanpayne-claude}"
  local pr_body="${5:-}"
  local additions="${6:-0}"
  local deletions="${7:-0}"
  local pr_head="${8:-feature/some-branch}"
  local pr_author="${9:-nathanjohnpayne}"
  local payload
  payload=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
  PATH="$STUB_DIR:$PATH" \
  STUB_MERGE_STATE="$merge_state" \
  STUB_LABELS="$labels" \
  STUB_PR_BODY="$pr_body" \
  STUB_PR_ADDITIONS="$additions" \
  STUB_PR_DELETIONS="$deletions" \
  STUB_PR_HEAD="$pr_head" \
  STUB_PR_AUTHOR="$pr_author" \
  GH_PR_GUARD_EXPECTED_REVIEWER="$expected_reviewer" \
    bash "$HOOK" <<<"$payload"
}

assert_rc_contains() {
  local label="$1" expected_rc="$2" needle="$3"; shift 3
  local out rc
  set +e
  out=$(run_hook "$@" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne "$expected_rc" ]; then
    fail "$label: rc=$rc expected $expected_rc; output: $out"
  elif [ -n "$needle" ] && ! echo "$out" | grep -qi "$needle"; then
    fail "$label: missing '$needle'; output: $out"
  else
    pass "$label"
  fi
}

assert_rc_contains "direct pr create blocked" 2 "token-verifying wrapper" \
  'gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "inline-token pr create blocked" 2 "not hook-verifiable" \
  'GH_TOKEN=author-token gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "wrapper substring spoof still blocked" 2 "token-verifying wrapper" \
  'echo scripts/gh-as-author.sh && gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "wrapper state does not cross separator" 2 "token-verifying wrapper" \
  'scripts/gh-as-author.sh -- echo ok ; gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "non-canonical author wrapper path blocked" 2 "non-canonical" \
  '/tmp/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "bare reviewer wrapper command blocked" 2 "non-canonical" \
  'gh-as-reviewer.sh -- gh pr review 123 --comment --body "review"'

assert_rc_contains "wrapper non-guarded then bare guarded compound blocked" 2 "#348" \
  'scripts/gh-as-author.sh -- gh pr view 123 && gh pr merge 123 --squash'

assert_rc_contains "author wrapper pr create valid body allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "author wrapper pr create missing body blocked" 2 "Self-Review" \
  'scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude"'

assert_rc_contains "reviewer wrapper pr create blocked" 2 "author token" \
  'scripts/gh-as-reviewer.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "author wrapper pr merge clean allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "direct pr merge blocked" 2 "token-verifying wrapper" \
  'gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "author wrapper pr merge blocked state" 2 "mergeStateStatus is BLOCKED" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "BLOCKED" ""

assert_rc_contains "author wrapper pr merge human-hold blocks" 2 "human-hold" \
  'CODEX_CLEARED=1 BREAK_GLASS_ADMIN=1 BREAK_GLASS_MERGE_STATE=1 scripts/gh-as-author.sh -- gh pr merge 123 --admin --squash' "DIRTY" "human-hold"

assert_rc_contains "direct pr comment blocked" 2 "token-verifying wrapper" \
  'gh pr comment 123 --body "ping"'

assert_rc_contains "reviewer wrapper pr comment allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "reviewer wrapper identity mismatch blocked" 2 "not expected reviewer" \
  'GH_AS_REVIEWER_IDENTITY=nathanpayne-codex scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "author wrapper normal pr comment blocked" 2 "reviewer token" \
  'scripts/gh-as-author.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "author wrapper codex trigger allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr comment 123 --body "@codex review"'

assert_rc_contains "author wrapper codex trigger echo spoof blocked" 2 "reviewer token" \
  'echo "@codex review" && scripts/gh-as-author.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "reviewer wrapper pr review comment allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --comment --body "review"'

assert_rc_contains "direct issue comment blocked" 2 "token-verifying wrapper" \
  'gh issue comment 7 --body "thanks"'

assert_rc_contains "reviewer wrapper issue comment allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh issue comment 7 --body "thanks"'

assert_rc_contains "author wrapper issue comment blocked" 2 "reviewer token" \
  'scripts/gh-as-author.sh -- gh issue comment 7 --body "thanks"'

assert_rc_contains "direct pr edit blocked" 2 "token-verifying wrapper" \
  'gh pr edit 123 --title "new"'

assert_rc_contains "author wrapper pr edit allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr edit 123 --title "new"'

assert_rc_contains "reviewer wrapper pr edit blocked" 2 "author token" \
  'scripts/gh-as-reviewer.sh -- gh pr edit 123 --title "new"'

assert_rc_contains "self-approve over-threshold blocked from wrapper identity" 2 "self-approve detected" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "lgtm"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "5000" "0"

assert_rc_contains "cross-agent approve allowed" 0 "" \
  'GH_AS_REVIEWER_IDENTITY=nathanpayne-codex scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "lgtm"' "CLEAN" "" "nathanpayne-codex" "Authoring-Agent: claude" "5000" "0"

ORIG_DIR="$(pwd)"
mkdir -p "$WORKDIR/repo-with-policy/.github"
cat >"$WORKDIR/repo-with-policy/.github/review-policy.yml" <<'YML'
external_review_threshold: 500
YML
cd "$WORKDIR/repo-with-policy"
assert_rc_contains "same-agent under-threshold approve allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "small"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "10" "5"
cd "$ORIG_DIR"

assert_rc_contains "compound direct guarded write blocked" 2 "#348" \
  'gh issue close 7 && gh pr merge --admin 123'

echo ""
echo "test_gh_pr_guard: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
