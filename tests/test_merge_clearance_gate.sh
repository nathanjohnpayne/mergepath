#!/usr/bin/env bash
# tests/test_merge_clearance_gate.sh
#
# Unit tests for scripts/merge-clearance-gate.sh — the HEAD-pinned
# merge-clearance gate (nathanjohnpayne/mergepath#427 + #428).
#
# Strategy: PATH-shim `gh` so the script's REST calls return canned
# fixtures, and stub the codex-review-check.sh delegate via
# MERGE_CLEARANCE_CODEX_CHECK_BIN so the external-review dispatch +
# exit-code mapping can be exercised without re-deriving that script's
# behavior. Same shape as tests/test_codex_p1_gate.sh.
#
# Cases:
#   Dependabot path
#     1.  reviewer_gate disabled → exit 0, no API calls.
#     2.  enabled + latest-state APPROVED on HEAD by a reviewer → exit 0.
#     3.  enabled + APPROVED only on a STALE sha (not HEAD) → exit 1.
#         [#427 repro: matchline#245 — approval dismissed/absent on HEAD]
#     4.  enabled + APPROVED then later CHANGES_REQUESTED on HEAD → exit 1.
#     5.  enabled + APPROVED on HEAD by a non-reviewer login → exit 1.
#   External-review path
#     6.  external_review_gate disabled → exit 0.
#     7.  enabled + delegate returns 0 → exit 0.
#     8.  enabled + delegate returns 1 → exit 1.
#         [#428 repro: nathanpaynedotcom#405 — not cleared on merge HEAD]
#     9.  enabled + delegate returns 3 (infra) → exit 2.
#   Dispatch / misc
#     10. Dependabot precedence: dependabot author + needs-external-review
#         label → judged by the Dependabot rule (not the external path).
#     11. neither Dependabot nor external-review → exit 0 (not applicable).
#     12. malformed PR_NUMBER → exit 2.
#     13. missing GH_TOKEN → exit 2.
#     14. env-only PR_NUMBER + REPO → same behavior as positional.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/merge-clearance-gate.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (merge-clearance-gate.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/merge-clearance-gate-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# PATH-shim gh: log calls, route pulls/N/reviews and pulls/N to fixtures.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"

cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${GH_CALLS_LOG:-/dev/null}"
{
  printf 'gh'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "$1" = "api" ]; then
  shift
  if [ "${1:-}" = "--paginate" ]; then shift; fi
  endpoint="${1:-}"
  case "$endpoint" in
    repos/*/pulls/*/reviews)
      cat "${FIXTURE_REVIEWS:-/dev/null}"
      exit 0
      ;;
    repos/*/pulls/*/files)
      cat "${FIXTURE_FILES:-/dev/null}"
      exit 0
      ;;
    repos/*/issues/*/comments)
      cat "${FIXTURE_COMMENTS:-/dev/null}"
      exit 0
      ;;
    repos/*/pulls/*)
      cat "${FIXTURE_PR:-/dev/null}"
      exit 0
      ;;
    *)
      # Fail (don't silently succeed) on an unhandled endpoint so a future
      # gate change that calls a new endpoint surfaces as a test failure
      # rather than a false green (CodeRabbit ⚠️ on PR #429).
      echo "STUB gh: unhandled api endpoint: $endpoint" >&2
      exit 1
      ;;
  esac
fi
# Any non-`gh api` invocation is unexpected for this gate.
echo "STUB gh: unhandled invocation: $*" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

# A stub codex-review-check.sh that exits with $CODEX_STUB_RC (inherited
# from the gate's environment). Default 0.
cat >"$STUB_DIR/codex-check-stub" <<'STUB'
#!/usr/bin/env bash
exit "${CODEX_STUB_RC:-0}"
STUB
chmod +x "$STUB_DIR/codex-check-stub"

# ---------------------------------------------------------------------------
# Scratch repo dir with a review-policy.yml controlling both knobs +
# the available_reviewers list.
# ---------------------------------------------------------------------------
make_scratch() {
  local dependabot_enabled=$1 external_enabled=$2
  local dir
  dir=$(mktemp -d "$WORKDIR/scratch.XXXXXX")
  mkdir -p "$dir/.github"
  cat >"$dir/.github/review-policy.yml" <<EOF
external_review_threshold: 300
external_review_paths:
  - ".github/**"
  - "src/auth/**"

available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor
  - nathanpayne-codex

codex:
  bot_login: "chatgpt-codex-connector[bot]"
  external_review_gate:
    enabled: $external_enabled

dependabot:
  reviewer_gate:
    enabled: $dependabot_enabled
EOF
  echo "$dir"
}

make_files_fixture() {  # <json_array_literal>   e.g. '[{"filename":"x","additions":5,"deletions":0}]'
  local content=$1
  local file="$WORKDIR/files.$$.$RANDOM.json"
  echo "$content" >"$file"
  echo "$file"
}

make_comments_fixture() {  # <json_array_literal>  issue comments
  local content=$1
  local file="$WORKDIR/comments.$$.$RANDOM.json"
  echo "$content" >"$file"
  echo "$file"
}

make_pr_fixture() {  # <sha> <author> <labels_json_array>
  local sha=$1 author=$2 labels=${3:-'[]'}
  local file="$WORKDIR/pr.$$.$RANDOM.json"
  jq -n --arg sha "$sha" --arg author "$author" --argjson labels "$labels" '
    { number: 99, head: { sha: $sha }, user: { login: $author }, labels: $labels }
  ' >"$file"
  echo "$file"
}

make_reviews_fixture() {  # <json_array_literal>
  local content=$1
  local file="$WORKDIR/reviews.$$.$RANDOM.json"
  echo "$content" >"$file"
  echo "$file"
}

run_gate() {  # <scratch> [args...]   (env: FIXTURE_PR, FIXTURE_REVIEWS, CODEX_STUB_RC, MERGE_CLEARANCE_CODEX_CHECK_BIN)
  local scratch=$1; shift
  (
    cd "$scratch"
    PATH="$STUB_DIR:$PATH" \
      GH_TOKEN="dummy-token" \
      GH_CALLS_LOG="$WORKDIR/gh-calls.log" \
      "$SCRIPT" "$@"
  )
}

HEAD_SHA="head000aaa"
OLD_SHA="old111bbb"
DEPENDABOT='dependabot[bot]'
EXT_LABEL='[{"name":"needs-external-review"}]'

# ---------------------------------------------------------------------------
# Test 1: Dependabot, reviewer_gate disabled → exit 0, no reviews API call.
# ---------------------------------------------------------------------------
echo; echo "--- Test 1: Dependabot, gate disabled"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS" \
    && ! grep -q "reviews" "$WORKDIR/gh-calls.log"; then
  pass "Dependabot + gate disabled → exit 0, no reviews fetch"
else
  fail "expected rc=0 + no reviews fetch; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 2: Dependabot, enabled, latest-state APPROVED on HEAD → exit 0.
# ---------------------------------------------------------------------------
echo; echo "--- Test 2: Dependabot, APPROVED on HEAD"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{ user:{login:"nathanpayne-claude"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" }]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS" && echo "$OUT" | grep -q "nathanpayne-claude"; then
  pass "Dependabot + APPROVED on HEAD → exit 0"
else
  fail "expected rc=0 PASS with approver; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 3 (#427 repro): APPROVED only on a STALE sha (not HEAD) → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 3: Dependabot, APPROVED only on stale sha (#427)"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg old "$OLD_SHA" '
  [{ user:{login:"nathanpayne-claude"}, state:"APPROVED", commit_id:$old, submitted_at:"2026-06-01T09:00:00Z" }]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "Dependabot + stale-sha approval → exit 1 (HEAD-pinned)"
else
  fail "expected rc=1 BLOCKED; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 4: APPROVED then later CHANGES_REQUESTED on HEAD → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 4: Dependabot, latest-state CHANGES_REQUESTED on HEAD"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [
    { user:{login:"nathanpayne-claude"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" },
    { user:{login:"nathanpayne-claude"}, state:"CHANGES_REQUESTED", commit_id:$sha, submitted_at:"2026-06-01T11:00:00Z" }
  ]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "Dependabot + stale APPROVED behind CHANGES_REQUESTED → exit 1"
else
  fail "expected rc=1 BLOCKED; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 5: APPROVED on HEAD by a login NOT in available_reviewers → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 5: Dependabot, APPROVED by non-reviewer login"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{ user:{login:"some-random-collaborator"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" }]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "Dependabot + non-reviewer approval → exit 1"
else
  fail "expected rc=1 BLOCKED; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 6: External-review, gate disabled → exit 0.
# ---------------------------------------------------------------------------
echo; echo "--- Test 6: external-review, gate disabled"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS"; then
  pass "external-review + gate disabled → exit 0"
else
  fail "expected rc=0 PASS; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 7: External-review, enabled, delegate returns 0 → exit 0.
# ---------------------------------------------------------------------------
echo; echo "--- Test 7: external-review, delegate clears"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=0 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS"; then
  pass "external-review + delegate rc=0 → exit 0"
else
  fail "expected rc=0 PASS; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 8 (#428 repro): delegate returns 1 (not cleared on HEAD) → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 8: external-review, delegate blocks (#428)"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "external-review + delegate rc=1 → exit 1"
else
  fail "expected rc=1 BLOCKED; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 9: delegate returns 3 (infra) → mapped to exit 2.
# ---------------------------------------------------------------------------
echo; echo "--- Test 9: external-review, delegate infra error"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=3 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "rc=3"; then
  pass "external-review + delegate rc=3 → exit 2 (infra)"
else
  fail "expected rc=2; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 10: Dependabot precedence — dependabot author + needs-external-review
#          → judged by the Dependabot rule (no APPROVED on HEAD → exit 1),
#          NOT routed to the external delegate.
# ---------------------------------------------------------------------------
echo; echo "--- Test 10: Dependabot precedence over external label"
SCRATCH=$(make_scratch true true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT" "$EXT_LABEL")
FIXTURE_REVIEWS=$(make_reviews_fixture '[]')
set +e
# If it wrongly took the external path, the delegate stub (rc=0) would
# clear it. Point the delegate at a stub that would PASS so a precedence
# bug surfaces as a wrong exit 0.
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=0 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED" && echo "$OUT" | grep -qi "Dependabot"; then
  pass "Dependabot + external label → judged by Dependabot rule → exit 1"
else
  fail "expected rc=1 via Dependabot rule; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11: neither Dependabot nor external-review → exit 0 (not applicable).
# ---------------------------------------------------------------------------
echo; echo "--- Test 11: normal under-threshold PR → not applicable"
SCRATCH=$(make_scratch true true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"README.md","additions":3,"deletions":1}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -qi "not applicable"; then
  pass "normal PR → exit 0 (not applicable)"
else
  fail "expected rc=0 not-applicable; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11b (#429 Codex P1): NO needs-external-review label, but the PR is
# intrinsically OVER THRESHOLD. The gate must DERIVE applicability (not
# trust the label) and delegate — so a delegate that blocks → exit 1. This
# is the stale-label race regression net: a label-only check would have
# fallen through to "not applicable" green here.
# ---------------------------------------------------------------------------
echo; echo "--- Test 11b: no label + over-threshold → derives applicability (#429)"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/big.ts","additions":250,"deletions":120}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED" && echo "$OUT" | grep -qi "lines changed"; then
  pass "no label + over-threshold → external arm derived → delegate blocks → exit 1"
else
  fail "expected rc=1 BLOCKED via derived threshold; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11c: NO label, UNDER threshold, but touches a protected path
# (.github/**) → external arm applies via paths → delegate blocks → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 11c: no label + protected path → derives applicability"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":4,"deletions":0}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED" && echo "$OUT" | grep -qi "protected paths"; then
  pass "no label + protected path → external arm derived → delegate blocks → exit 1"
else
  fail "expected rc=1 BLOCKED via protected paths; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11d: external gate DISABLED + over-threshold no-label → exit 0
# (knob off short-circuits the whole arm; never reaches the delegate).
# ---------------------------------------------------------------------------
echo; echo "--- Test 11d: external gate disabled + over-threshold → not applicable"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/big.ts","additions":250,"deletions":120}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -qi "not applicable"; then
  pass "external gate disabled → over-threshold no-label still exit 0"
else
  fail "expected rc=0 not-applicable; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 12: malformed PR_NUMBER → exit 2.
# ---------------------------------------------------------------------------
echo; echo "--- Test 12: malformed PR_NUMBER"
SCRATCH=$(make_scratch true true)
set +e
OUT=$(run_gate "$SCRATCH" "not-a-number" owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "PR_NUMBER must be an integer"; then
  pass "malformed PR_NUMBER → exit 2"
else
  fail "expected rc=2; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 13: missing GH_TOKEN → exit 2.
# ---------------------------------------------------------------------------
echo; echo "--- Test 13: missing GH_TOKEN"
SCRATCH=$(make_scratch true true)
set +e
OUT=$(cd "$SCRATCH" && PATH="$STUB_DIR:$PATH" "$SCRIPT" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -q "GH_TOKEN is required"; then
  pass "missing GH_TOKEN → exit 2"
else
  fail "expected rc=2; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 14: env-only PR_NUMBER + REPO → same behavior as positional.
# ---------------------------------------------------------------------------
echo; echo "--- Test 14: env-only PR_NUMBER + REPO"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{ user:{login:"nathanpayne-codex"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" }]
')")
set +e
OUT=$(
  cd "$SCRATCH" && \
    PATH="$STUB_DIR:$PATH" \
    GH_TOKEN="dummy-token" \
    PR_NUMBER=99 REPO=owner/repo \
    FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    "$SCRIPT" 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS"; then
  pass "env-only PR_NUMBER + REPO → exit 0"
else
  fail "expected rc=0 PASS; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 15 (CodeRabbit ⚠️ #429): external_review_threshold ABSENT from config
# → defaults to 300 without crashing under set -euo pipefail. A small PR
# stays "not applicable" (exit 0); the grep|awk no-match must not abort.
# ---------------------------------------------------------------------------
echo; echo "--- Test 15: threshold key absent → default 300, no crash"
SCRATCH=$(mktemp -d "$WORKDIR/scratch.XXXXXX"); mkdir -p "$SCRATCH/.github"
cat >"$SCRATCH/.github/review-policy.yml" <<EOF
external_review_paths:
  - ".github/**"
available_reviewers:
  - nathanpayne-claude
codex:
  external_review_gate:
    enabled: true
dependabot:
  reviewer_gate:
    enabled: false
EOF
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"README.md","additions":10,"deletions":2}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -qi "not applicable"; then
  pass "threshold absent → default 300 applied, small PR not applicable (no crash)"
else
  fail "expected rc=0 not-applicable; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 16 (CodeRabbit ⚠️ Major #429): protected-paths matcher UNAVAILABLE →
# the gate must FAIL CLOSED (require external review), not skip to
# threshold-only. Point the helper dir at an empty location; an
# under-threshold PR must then still delegate (→ delegate blocks → exit 1).
# ---------------------------------------------------------------------------
echo; echo "--- Test 16: missing protected-paths helpers → fail closed"
SCRATCH=$(make_scratch false true)
EMPTY_WF=$(mktemp -d "$WORKDIR/emptywf.XXXXXX")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"README.md","additions":5,"deletions":1}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_WORKFLOW_DIR="$EMPTY_WF" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED" && echo "$OUT" | grep -qi "failing closed"; then
  pass "missing matcher → fail closed → external arm applies → delegate blocks → exit 1"
else
  fail "expected rc=1 BLOCKED via fail-closed; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 17 (#429): verified propagation PR — over-threshold, NO
# needs-external-review label, with a github-actions[bot] lane marker scoped
# to the CURRENT head → EXEMPT (not applicable), must NOT delegate.
# ---------------------------------------------------------------------------
echo; echo "--- Test 17: verified propagation lane (head-pinned) → exempt"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":400,"deletions":50}]')
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg h "$HEAD_SHA" '
  [{user:{login:"github-actions[bot]"}, body:("<!-- mergepath-propagation-lane verified-head=" + $h + " -->\nverified faithful mirror ✅")}]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -qi "not applicable"; then
  pass "verified propagation lane (current-head marker) → exempt (exit 0, no delegate)"
else
  fail "expected rc=0 not-applicable (exempt); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 17b (#429 Codex round-3 P1 / nathanpayne-codex CHANGES_REQUESTED): a
# STALE lane marker — bot-authored but scoped to an OLD head — must NOT exempt
# a diverged current head. This is the head-pinning regression: an unscoped
# "was-ever-a-mirror" marker would have false-exempted here. Over-threshold +
# stale marker → still requires external → delegate blocks.
# ---------------------------------------------------------------------------
echo; echo "--- Test 17b: STALE bot marker (old head) + diverged head → NOT exempt"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":400,"deletions":50}]')
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg old "$OLD_SHA" '
  [{user:{login:"github-actions[bot]"}, body:("<!-- mergepath-propagation-lane verified-head=" + $old + " -->\nverified faithful mirror ✅")}]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "stale marker (old head) → NOT exempt → delegate blocks → exit 1 (head-pinned)"
else
  fail "expected rc=1 BLOCKED (stale marker ignored); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 18: SPOOFED lane marker — current-head marker but authored by a NON-bot
# login → must NOT exempt (a PR author can't forge github-actions[bot]).
# Over-threshold + spoofed marker → still requires external → delegate blocks.
# ---------------------------------------------------------------------------
echo; echo "--- Test 18: spoofed (non-bot) lane marker → NOT exempt"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/big.ts","additions":250,"deletions":120}]')
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg h "$HEAD_SHA" '
  [{user:{login:"nathanjohnpayne"}, body:("<!-- mergepath-propagation-lane verified-head=" + $h + " --> nice try")}]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "spoofed non-bot marker → NOT exempt → delegate blocks → exit 1"
else
  fail "expected rc=1 BLOCKED (spoof ignored); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
echo
echo "============================================"
echo "test_merge_clearance_gate.sh: $PASS passed, $FAIL failed"
echo "============================================"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
