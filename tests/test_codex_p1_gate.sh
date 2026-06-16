#!/usr/bin/env bash
# tests/test_codex_p1_gate.sh
#
# Unit tests for scripts/codex-p1-gate.sh.
#
# Strategy: PATH-shim `gh` so the script's REST + GraphQL calls
# return canned payloads from fixture files. The wrapper writes a
# per-call log so we can assert on which endpoints were hit, and
# returns the fixture matching the endpoint. Same shape as the
# PATH-shimmed gh in tests/test_gh_as_reviewer.sh.
#
# Cases covered (per nathanjohnpayne/mergepath#235):
#   1. Gate disabled (codex.p1_gate.enabled=false) → exit 0, no API calls.
#   2. No P1 comments on the PR → exit 0, "Codex P1 unresolved: 0".
#   3. P1 present and resolved (review-thread isResolved=true) → exit 0.
#   4. P1 present and unresolved → exit 1, count > 0, paths listed.
#   5. P1 only on a stale SHA (not HEAD) → exit 0, doesn't gate.
#   6. P1 from a NON-bot author → exit 0 (must be bot to count).
#   7. Mix: 2 P1s on HEAD, one resolved + one unresolved → exit 1, count = 1.
#   8. Malformed PR_NUMBER → exit 2.
#   9. Missing GH_TOKEN → exit 2.
#   10. >100 review threads → exit 2 (pagination not supported in v1).
#   11. enabled knob absent from config → default false → exit 0.
#   12. PR_NUMBER + REPO supplied via env (no positional args) →
#       same behavior as positional. Covers the scheduled-sweep /
#       workflow_dispatch invocation shape added in #257.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-p1-gate.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (codex-p1-gate.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-p1-gate-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Build a PATH-shim `gh` that:
#   - Logs each call to $GH_CALLS_LOG.
#   - Routes `gh api repos/.../pulls/N` to $FIXTURE_PR
#   - Routes `gh api --paginate repos/.../pulls/N/comments` to $FIXTURE_COMMENTS
#   - Routes `gh api graphql ...` to $FIXTURE_THREADS
#   - Returns rc 0 unless GH_API_RC is set.
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

# gh api [--paginate] <endpoint> [...]
# gh api graphql -F ... -f query=...
if [ "$1" = "api" ]; then
  shift
  # Skip --paginate flag if present (we return the whole array in one go).
  if [ "${1:-}" = "--paginate" ]; then shift; fi

  endpoint="${1:-}"

  case "$endpoint" in
    graphql)
      cat "${FIXTURE_THREADS:-/dev/null}"
      exit 0
      ;;
    repos/*/pulls/*/comments)
      cat "${FIXTURE_COMMENTS:-/dev/null}"
      exit 0
      ;;
    repos/*/pulls/*)
      cat "${FIXTURE_PR:-/dev/null}"
      exit 0
      ;;
  esac
fi

# Default: empty success
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# ---------------------------------------------------------------------------
# Helper: scratch repo dir with a .github/review-policy.yml that enables
# (or disables) the gate. The script reads CONFIG=".github/review-policy.yml"
# from cwd, so we cd into the scratch dir to control config.
# ---------------------------------------------------------------------------
make_scratch_with_config() {
  local enabled=$1   # "true" or "false" or "absent"
  local dir
  dir=$(mktemp -d "$WORKDIR/scratch.XXXXXX")
  mkdir -p "$dir/.github"
  if [ "$enabled" = "absent" ]; then
    # No codex.p1_gate block at all
    cat >"$dir/.github/review-policy.yml" <<EOF
codex:
  bot_login: "chatgpt-codex-connector[bot]"
EOF
  else
    cat >"$dir/.github/review-policy.yml" <<EOF
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  p1_gate:
    enabled: $enabled
EOF
  fi
  echo "$dir"
}

# ---------------------------------------------------------------------------
# Helper: make a PR-metadata fixture with a configurable HEAD sha.
# ---------------------------------------------------------------------------
make_pr_fixture() {
  local sha=$1
  local file="$WORKDIR/pr.$$.$RANDOM.json"
  cat >"$file" <<EOF
{
  "number": 99,
  "head": { "sha": "$sha" },
  "user": { "login": "nathanjohnpayne" }
}
EOF
  echo "$file"
}

# ---------------------------------------------------------------------------
# Helper: make a comments-array fixture from a jq-buildable JSON literal.
# ---------------------------------------------------------------------------
make_comments_fixture() {
  local content=$1
  local file="$WORKDIR/comments.$$.$RANDOM.json"
  echo "$content" > "$file"
  echo "$file"
}

# ---------------------------------------------------------------------------
# Helper: make a reviewThreads GraphQL response fixture.
#
# Args:
#   $1 = jq expression (evaluated under `jq -n`) producing an array of
#        {isResolved, comment_ids} objects. Uses jq-literal object
#        syntax (unquoted keys ok), NOT JSON. Example:
#          '[{isResolved: true, comment_ids: [1001]}]'
#   $2 = totalCount (optional, defaults to nodes length)
#   $3 = hasNextPage (optional, defaults to false)
# ---------------------------------------------------------------------------
make_threads_fixture() {
  local nodes_expr=$1
  local total=${2:-}
  local has_next=${3:-false}
  local file="$WORKDIR/threads.$$.$RANDOM.json"
  # Resolve the input expression to JSON via `jq -n`, then transform
  # into the GraphQL response shape.
  local resolved_nodes
  resolved_nodes=$(jq -n "$nodes_expr | [.[] | {
    isResolved: .isResolved,
    comments: { nodes: ([.comment_ids[] | {databaseId: .}]) }
  }]")
  if [ -z "$total" ]; then
    total=$(echo "$resolved_nodes" | jq 'length')
  fi
  jq -n \
    --argjson nodes "$resolved_nodes" \
    --argjson total "$total" \
    --arg has_next "$has_next" '
    {
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              totalCount: $total,
              pageInfo: { hasNextPage: ($has_next == "true") },
              nodes: $nodes
            }
          }
        }
      }
    }
  ' > "$file"
  echo "$file"
}

# Re-export the path with the gh stub prepended.
run_gate() {
  local scratch=$1
  shift
  (
    cd "$scratch"
    PATH="$STUB_DIR:$PATH" \
      GH_TOKEN="dummy-token" \
      GH_CALLS_LOG="$WORKDIR/gh-calls.log" \
      "$SCRIPT" "$@"
  )
}

# ---------------------------------------------------------------------------
# Test 1: Gate disabled — exit 0, no API calls.
# ---------------------------------------------------------------------------
echo
echo "--- Test 1: gate disabled (enabled=false)"
SCRATCH=$(make_scratch_with_config false)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 0" \
    && ! grep -q "^gh" "$WORKDIR/gh-calls.log"; then
  pass "gate disabled exits 0 with no API calls"
else
  fail "expected rc=0 + 'unresolved: 0' + no gh calls; got rc=$RC, output:"
  echo "$OUT" | sed 's/^/      /' >&2
  echo "    gh calls:" >&2
  sed 's/^/      /' "$WORKDIR/gh-calls.log" >&2
fi

# ---------------------------------------------------------------------------
# Test 1b (#447): gate disabled + NO env (no PR_NUMBER, REPO, or GH_TOKEN).
# The enabled=false short-circuit must run BEFORE the PR-context
# requirements, so a disabled consumer no-ops on a bare/ad-hoc invocation
# instead of erroring on missing env (the documented step-1 contract).
# ---------------------------------------------------------------------------
echo
echo "--- Test 1b (#447): gate disabled + no PR/REPO/GH_TOKEN env"
SCRATCH=$(make_scratch_with_config false)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$( cd "$SCRATCH" && PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/gh-calls.log" \
  env -u GH_TOKEN -u PR_NUMBER -u REPO "$SCRIPT" 2>&1 )
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 0" \
    && ! grep -q "^gh" "$WORKDIR/gh-calls.log"; then
  pass "#447: disabled gate + no env → exit 0 clean pass (no PR_NUMBER/GH_TOKEN error, no gh calls)"
else
  fail "#447: expected rc=0 + 'unresolved: 0' + no gh calls; got rc=$RC, output:"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Control: gate ENABLED + no env → still errors (env required once enabled).
echo "--- Test 1c (#447 control): gate enabled + no PR_NUMBER → exit 2"
SCRATCH=$(make_scratch_with_config true)
set +e
OUT=$( cd "$SCRATCH" && PATH="$STUB_DIR:$PATH" \
  env -u GH_TOKEN -u PR_NUMBER -u REPO "$SCRIPT" 2>&1 )
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -q "PR_NUMBER required"; then
  pass "#447 control: enabled gate + no env → exit 2 (env still required when enabled)"
else
  fail "#447 control: expected rc=2 + 'PR_NUMBER required'; got rc=$RC, output:"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 2: Gate enabled, no P1 comments at all — exit 0.
# ---------------------------------------------------------------------------
echo
echo "--- Test 2: gate enabled, no P1 comments"
SCRATCH=$(make_scratch_with_config true)
HEAD_SHA="abc123def456"
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_THREADS=$(make_threads_fixture '[]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 0"; then
  pass "no P1s → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 3: P1 present and resolved → exit 0.
# ---------------------------------------------------------------------------
echo
echo "--- Test 3: P1 present and resolved"
SCRATCH=$(make_scratch_with_config true)
HEAD_SHA="abc123def456"
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{
    id: 1001,
    user: { login: "chatgpt-codex-connector[bot]" },
    body: "![P1 Badge](url) Stop retrying endlessly.",
    path: "src/foo.ts",
    line: 42,
    commit_id: $sha,
    original_commit_id: $sha
  }]
')")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: true, comment_ids: [1001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 0"; then
  pass "P1 + resolved → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 4: P1 present and unresolved → exit 1.
# ---------------------------------------------------------------------------
echo
echo "--- Test 4: P1 present and unresolved"
SCRATCH=$(make_scratch_with_config true)
HEAD_SHA="abc123def456"
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{
    id: 1001,
    user: { login: "chatgpt-codex-connector[bot]" },
    body: "![P1 Badge](url) Stop retrying endlessly.",
    path: "src/foo.ts",
    line: 42,
    commit_id: $sha,
    original_commit_id: $sha
  }]
')")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [1001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 1" \
    && echo "$OUT" | grep -q "src/foo.ts:42"; then
  pass "P1 + unresolved → exit 1 with path listed"
else
  fail "expected rc=1 with 'unresolved: 1' + path; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 5: P1 only on a stale SHA → exit 0 (not on HEAD; out of scope).
# ---------------------------------------------------------------------------
echo
echo "--- Test 5: P1 only on a stale SHA"
SCRATCH=$(make_scratch_with_config true)
HEAD_SHA="newhead12345"
OLD_SHA="oldsha98765"
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg sha "$OLD_SHA" '
  [{
    id: 1001,
    user: { login: "chatgpt-codex-connector[bot]" },
    body: "![P1 Badge](url) Old finding.",
    path: "src/foo.ts",
    line: 42,
    commit_id: $sha,
    original_commit_id: $sha
  }]
')")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [1001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 0"; then
  pass "P1 on stale SHA → out of scope, exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 6: P1-bodied comment from non-bot author → ignored, exit 0.
#         Catches the same false-positive that bit
#         scripts/codex-review-check.sh at line 685 (the human quoting a
#         P1 badge in a reply).
# ---------------------------------------------------------------------------
echo
echo "--- Test 6: P1-bodied comment from human → ignored"
SCRATCH=$(make_scratch_with_config true)
HEAD_SHA="abc123def456"
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{
    id: 1001,
    user: { login: "nathanjohnpayne" },
    body: "Quoting the codex review: ![P1 Badge](url) — not a real finding",
    path: "src/foo.ts",
    line: 42,
    commit_id: $sha,
    original_commit_id: $sha
  }]
')")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [1001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 0"; then
  pass "P1 body from human → ignored, exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 7: Mix — 2 P1s on HEAD, one resolved + one unresolved → exit 1, count=1.
# ---------------------------------------------------------------------------
echo
echo "--- Test 7: mix of resolved + unresolved P1s"
SCRATCH=$(make_scratch_with_config true)
HEAD_SHA="abc123def456"
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [
    {
      id: 1001,
      user: { login: "chatgpt-codex-connector[bot]" },
      body: "![P1 Badge](url) First finding.",
      path: "src/foo.ts",
      line: 42,
      commit_id: $sha,
      original_commit_id: $sha
    },
    {
      id: 1002,
      user: { login: "chatgpt-codex-connector[bot]" },
      body: "**P1: Second finding (text-only fallback).",
      path: "src/bar.ts",
      line: 99,
      commit_id: $sha,
      original_commit_id: $sha
    }
  ]
')")
FIXTURE_THREADS=$(make_threads_fixture '[
  {isResolved: true, comment_ids: [1001]},
  {isResolved: false, comment_ids: [1002]}
]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 1" \
    && echo "$OUT" | grep -q "src/bar.ts:99" \
    && ! echo "$OUT" | grep -qE "Unresolved.*foo\.ts:42"; then
  pass "mix → exit 1, count=1, only bar.ts listed"
else
  fail "expected rc=1, count=1, bar.ts listed, foo.ts NOT listed; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 8: Malformed PR_NUMBER → exit 2.
# ---------------------------------------------------------------------------
echo
echo "--- Test 8: malformed PR_NUMBER"
SCRATCH=$(make_scratch_with_config true)
set +e
OUT=$(run_gate "$SCRATCH" "not-a-number" owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "PR_NUMBER must be an integer"; then
  pass "malformed PR_NUMBER → exit 2"
else
  fail "expected rc=2 with PR_NUMBER error; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 9: Missing GH_TOKEN → exit 2 (only when gate is enabled; the
#         enabled=false short-circuit happens BEFORE the token check
#         by design — a disabled gate shouldn't require credentials).
# ---------------------------------------------------------------------------
echo
echo "--- Test 9: missing GH_TOKEN with gate enabled"
SCRATCH=$(make_scratch_with_config true)
set +e
OUT=$(
  cd "$SCRATCH" && \
    PATH="$STUB_DIR:$PATH" \
    GH_CALLS_LOG="$WORKDIR/gh-calls.log" \
    "$SCRIPT" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -q "GH_TOKEN is required"; then
  pass "missing GH_TOKEN → exit 2"
else
  fail "expected rc=2 with GH_TOKEN error; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 10: >100 review threads (hasNextPage=true) → exit 2.
# ---------------------------------------------------------------------------
echo
echo "--- Test 10: >100 review threads (pagination)"
SCRATCH=$(make_scratch_with_config true)
HEAD_SHA="abc123def456"
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{
    id: 1001,
    user: { login: "chatgpt-codex-connector[bot]" },
    body: "![P1 Badge](url) Finding.",
    path: "src/foo.ts",
    line: 42,
    commit_id: $sha,
    original_commit_id: $sha
  }]
')")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [1001]}]' 101 true)
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -q ">100 review threads"; then
  pass ">100 threads → exit 2"
else
  fail "expected rc=2 with pagination error; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11: enabled knob absent from config → default false → exit 0.
# ---------------------------------------------------------------------------
echo
echo "--- Test 11: codex.p1_gate block absent → defaults to disabled"
SCRATCH=$(make_scratch_with_config absent)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 0"; then
  pass "missing p1_gate block → defaults to disabled → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 12: PR_NUMBER + REPO via env (no positional args). Covers the
#          scheduled-sweep / workflow_dispatch invocation shape.
# ---------------------------------------------------------------------------
echo
echo "--- Test 12: PR_NUMBER + REPO via env"
SCRATCH=$(make_scratch_with_config true)
HEAD_SHA="abc123def456"
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_THREADS=$(make_threads_fixture '[]')
set +e
OUT=$(
  cd "$SCRATCH" && \
    PATH="$STUB_DIR:$PATH" \
    GH_TOKEN="dummy-token" \
    GH_CALLS_LOG="$WORKDIR/gh-calls.log" \
    PR_NUMBER=99 \
    REPO=owner/repo \
    FIXTURE_PR="$FIXTURE_PR" \
    FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
    FIXTURE_THREADS="$FIXTURE_THREADS" \
    "$SCRIPT" 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex P1 unresolved: 0"; then
  pass "env-only PR_NUMBER + REPO → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 13: Missing PR_NUMBER entirely (no positional, no env) → exit 2.
# ---------------------------------------------------------------------------
echo
echo "--- Test 13: missing PR_NUMBER (positional + env both unset)"
SCRATCH=$(make_scratch_with_config true)
set +e
OUT=$(
  cd "$SCRATCH" && \
    PATH="$STUB_DIR:$PATH" \
    GH_TOKEN="dummy-token" \
    "$SCRIPT" 2>&1
)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "PR_NUMBER required"; then
  pass "missing PR_NUMBER → exit 2"
else
  fail "expected rc=2 with 'PR_NUMBER required'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
echo
echo "============================================"
echo "test_codex_p1_gate.sh: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
