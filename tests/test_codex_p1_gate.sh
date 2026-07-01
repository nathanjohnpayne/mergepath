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
# Cases covered (per nathanjohnpayne/mergepath#235, generalized in #577):
#   1. Gate disabled (codex.p1_gate.enabled=false) → exit 0, no API calls.
#   2. No P1 comments on the PR → exit 0, "Codex blocking-tier unresolved: 0".
#   3. P1 present and resolved (review-thread isResolved=true) → exit 0.
#   4. P1 present and unresolved → exit 1, count > 0, paths listed.
#   5. P1 only on a stale SHA (not HEAD) → exit 0, doesn't gate.
#   6. P1 from a NON-bot author → exit 0 (must be bot to count).
#   7. Mix: 2 P1s on HEAD, one resolved + one unresolved → exit 1, count = 1.
#   8. Malformed PR_NUMBER → exit 2.
#   9. Missing GH_TOKEN → exit 2.
#   10. >100 review threads → PAGINATED (#592): two threads pages, blocking P1
#       on page 2, collected + classified unresolved → exit 1 (was exit 2 in
#       v1; pagination now handles the extreme PR precisely).
#   11. enabled knob absent from config → default false → exit 0.
#   12. PR_NUMBER + REPO supplied via env (no positional args) →
#       same behavior as positional. Covers the scheduled-sweep /
#       workflow_dispatch invocation shape added in #257.
#
# Generalized tier-gate cases (#577 — feedback_policy block PRESENT):
#   14. feedback_policy block ABSENT → P1-only: an unresolved P0 does NOT
#       block (P0 ∉ {p1}), an unresolved P1 DOES. (Backward-compat default.)
#   15. feedback_policy by-priority with p0+p1 required → an unresolved P0
#       on HEAD blocks (exit 1, count=1).
#   16. feedback_policy by-priority with p0+p1 required → an unresolved P2
#       does NOT block (P2 ∉ {p0,p1}); exit 0.
#   17. feedback_policy mode: address-all → an unresolved P3 blocks (every
#       tier required); exit 1.
#   18. Malformed feedback_policy (bad tier value) with gate enabled →
#       exit 2 (resolve_required_tiers fails closed).
#
# Pagination cases (#592 — reviewThreads + nested comments cursor loop):
#   19. >100 review threads, blocking P1 RESOLVED on page 2 → collected across
#       both pages, honored as resolved → exit 0. (Proves page-2 threads are
#       actually fetched, not just that a page-2 finding blocks.)
#   20. A thread with >100 comments where the blocking comment id is on
#       comments page 2 → nested comments paginated, id found, thread
#       unresolved → exit 1. (Without nested pagination the id would be
#       missing and — while still fail-closed — the precise path is proven.)
#   21. Nested comments page-2 GraphQL error → fail closed, exit 2.
#   22. Top-level reviewThreads page-2 GraphQL error → fail closed, exit 2.
#   23. hasNextPage=true but endCursor=null → fail closed, exit 2.
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

  # For graphql, capture the query body + the cursor value so the stub can
  # serve the right pagination page (#592). The gate sends the top-level
  # reviewThreads query and a per-thread `node(id:...)` comments query; each
  # can page via -f cursor=<value>.
  q=""
  cursor="__none__"
  node_id="__none__"
  prev=""
  for a in "$@"; do
    case "$prev" in
      query=*) : ;;  # handled below via the value directly
    esac
    case "$a" in
      query=*) q="${a#query=}" ;;
      cursor=*) cursor="${a#cursor=}" ;;
      id=*)     node_id="${a#id=}" ;;
    esac
    prev="$a"
  done

  case "$endpoint" in
    graphql)
      # Per-thread nested comments pagination (node(id:...) query). Served
      # from $FIXTURE_TCOMMENTS_<node_id>_<cursor> if present.
      if printf '%s' "$q" | grep -q 'PullRequestReviewThread'; then
        f="FIXTURE_TCOMMENTS_${node_id}_${cursor}"
        cat "${!f:-/dev/null}"
        exit 0
      fi
      # Top-level reviewThreads pagination. First page = cursor "null"
      # ($FIXTURE_THREADS or $FIXTURE_THREADS_null); subsequent pages served
      # from $FIXTURE_THREADS_<cursor>.
      if [ "$cursor" = "null" ] || [ "$cursor" = "__none__" ]; then
        if [ -n "${FIXTURE_THREADS_null:-}" ]; then
          cat "$FIXTURE_THREADS_null"
        else
          cat "${FIXTURE_THREADS:-/dev/null}"
        fi
      else
        f="FIXTURE_THREADS_${cursor}"
        cat "${!f:-/dev/null}"
      fi
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
# Helper (#577): scratch dir with the gate ENABLED plus a feedback_policy
# block appended verbatim. $1 is the multi-line block text (already
# `feedback_policy:`-rooted) or empty for "no feedback_policy block".
# Lets the tier-gate cases below drive resolve_required_tiers off a real
# on-disk config the way the script reads it.
# ---------------------------------------------------------------------------
make_scratch_with_policy() {
  local policy_block=$1
  local dir
  dir=$(mktemp -d "$WORKDIR/scratch.XXXXXX")
  mkdir -p "$dir/.github"
  {
    cat <<EOF
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  p1_gate:
    enabled: true
EOF
    if [ -n "$policy_block" ]; then
      printf '%s\n' "$policy_block"
    fi
  } >"$dir/.github/review-policy.yml"
  echo "$dir"
}

# Build a single-finding comments fixture for a given tier marker body.
# $1 = HEAD sha, $2 = comment body. id is fixed at 1001.
make_single_comment_fixture() {
  local sha=$1 body=$2
  make_comments_fixture "$(jq -n --arg sha "$sha" --arg body "$body" '
    [{
      id: 1001,
      user: { login: "chatgpt-codex-connector[bot]" },
      body: $body,
      path: "src/foo.ts",
      line: 42,
      commit_id: $sha,
      original_commit_id: $sha
    }]
  ')"
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
# Helper: make a reviewThreads GraphQL response fixture (one page).
#
# The gate paginates reviewThreads (#592): each thread node carries an `id`
# and its comments connection carries its own pageInfo{hasNextPage,endCursor}.
#
# Args:
#   $1 = jq expression (evaluated under `jq -n`) producing an array of
#        {isResolved, comment_ids} objects, optionally with:
#          id                    thread node id (defaults to "T<index>")
#          comments_has_next     nested comments overflow flag (default false)
#          comments_end_cursor   nested comments endCursor (default null)
#        Uses jq-literal object syntax (unquoted keys ok), NOT JSON. Example:
#          '[{isResolved: true, comment_ids: [1001]}]'
#   $2 = totalCount (optional, retained for back-compat — the paginating gate
#        ignores totalCount, but kept so existing call sites don't break)
#   $3 = hasNextPage (optional, defaults to false) — top-level threads page
#   $4 = endCursor   (optional, defaults to null)  — top-level threads page
# ---------------------------------------------------------------------------
make_threads_fixture() {
  local nodes_expr=$1
  local total=${2:-}
  local has_next=${3:-false}
  local end_cursor=${4:-null}
  local file="$WORKDIR/threads.$$.$RANDOM.json"
  # Resolve the input expression to JSON via `jq -n`, then transform into the
  # GraphQL response shape, defaulting each node's id and comments pageInfo.
  local resolved_nodes
  resolved_nodes=$(jq -n "$nodes_expr | [ to_entries[] | .key as \$idx | .value | {
    id: (.id // \"T\(\$idx)\"),
    isResolved: .isResolved,
    comments: {
      pageInfo: {
        hasNextPage: (.comments_has_next // false),
        endCursor: (.comments_end_cursor // null)
      },
      nodes: ([.comment_ids[] | {databaseId: .}])
    }
  }]")
  if [ -z "$total" ]; then
    total=$(echo "$resolved_nodes" | jq 'length')
  fi
  jq -n \
    --argjson nodes "$resolved_nodes" \
    --argjson total "$total" \
    --arg has_next "$has_next" \
    --arg end_cursor "$end_cursor" '
    {
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              totalCount: $total,
              pageInfo: {
                hasNextPage: ($has_next == "true"),
                endCursor: (if $end_cursor == "null" then null else $end_cursor end)
              },
              nodes: $nodes
            }
          }
        }
      }
    }
  ' > "$file"
  echo "$file"
}

# ---------------------------------------------------------------------------
# Helper: make a per-thread comments-page fixture for the node(id:...) query
# the gate issues when a thread's comments connection overflows 100 (#592).
#
# Args:
#   $1 = jq expression producing an array of comment databaseIds. Example:
#          '[2001, 2002]'
#   $2 = hasNextPage (optional, defaults to false)
#   $3 = endCursor   (optional, defaults to null)
# ---------------------------------------------------------------------------
make_thread_comments_fixture() {
  local ids_expr=$1
  local has_next=${2:-false}
  local end_cursor=${3:-null}
  local file="$WORKDIR/tcomments.$$.$RANDOM.json"
  jq -n \
    --argjson ids "$(jq -n "$ids_expr")" \
    --arg has_next "$has_next" \
    --arg end_cursor "$end_cursor" '
    {
      data: {
        node: {
          comments: {
            pageInfo: {
              hasNextPage: ($has_next == "true"),
              endCursor: (if $end_cursor == "null" then null else $end_cursor end)
            },
            nodes: ([$ids[] | {databaseId: .}])
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0" \
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0" \
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
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
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 1" \
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
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
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 1" \
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
# Test 10 (#592): >100 review threads — the finding is on PAGE 2 and
# UNRESOLVED. v1 hard-errored (exit 2) on hasNextPage; the paginating gate now
# fetches page 2, finds the unresolved P1 there, and blocks (exit 1). Page 1
# holds an unrelated resolved thread; page 2 (cursor CUR1) holds comment 1001.
# ---------------------------------------------------------------------------
echo
echo "--- Test 10 (#592): >100 review threads → page 2 finding paginated, unresolved → exit 1"
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
# Page 1: unrelated resolved thread (comment 9001), hasNextPage=true, cursor CUR1.
FIXTURE_THREADS_null=$(make_threads_fixture \
  '[{isResolved: true, comment_ids: [9001]}]' "" true CUR1)
# Page 2: the unresolved P1 thread (comment 1001).
FIXTURE_THREADS_CUR1=$(make_threads_fixture \
  '[{isResolved: false, comment_ids: [1001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS_null="$FIXTURE_THREADS_null" \
  FIXTURE_THREADS_CUR1="$FIXTURE_THREADS_CUR1" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "src/foo.ts:42"; then
  pass ">100 threads → page 2 paginated, unresolved P1 → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' + path (page-2 pagination); got rc=$RC"
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
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

# ===========================================================================
# Generalized tier-gate cases (#577). These drive resolve_required_tiers off
# a feedback_policy block written into the scratch config and confirm the
# gate enforces the resolved tier SET (not hard-coded P1).
# ===========================================================================
HEAD_SHA="abc123def456"
P0_BODY="![P0 Badge](url) Critical: drop the privilege escalation."
P2_BODY="![P2 Badge](url) Minor: tidy this branch."
P3_BODY="![P3 Badge](url) Trivial: rename the local."

# ---------------------------------------------------------------------------
# Test 14: feedback_policy ABSENT → P1-only. An unresolved P0 must NOT block
#          (P0 ∉ {p1}); the gate is byte-compatible with its original scope.
#          (Tests 3/4/7 already cover that an unresolved P1 DOES block.)
# ---------------------------------------------------------------------------
echo
echo "--- Test 14 (#577): feedback_policy absent → P0 does NOT block (P1-only)"
SCRATCH=$(make_scratch_with_policy "")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$P0_BODY")
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
  pass "absent feedback_policy → unresolved P0 out of scope (P1-only) → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' (P0 ∉ {p1}); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 15: feedback_policy by-priority, p0+p1 required → unresolved P0 blocks.
# ---------------------------------------------------------------------------
echo
echo "--- Test 15 (#577): by-priority p0+p1 required → unresolved P0 blocks"
SCRATCH=$(make_scratch_with_policy "$(cat <<'EOF'
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: discretionary
    nitpick: discretionary
EOF
)")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$P0_BODY")
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
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P0\] src/foo.ts:42"; then
  pass "p0 required → unresolved P0 → exit 1, listed as [P0]"
else
  fail "expected rc=1 with 'unresolved: 1' + [P0] path; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 16: feedback_policy by-priority, p0+p1 required → unresolved P2 clears.
# ---------------------------------------------------------------------------
echo
echo "--- Test 16 (#577): by-priority p0+p1 required → unresolved P2 does NOT block"
SCRATCH=$(make_scratch_with_policy "$(cat <<'EOF'
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: discretionary
    nitpick: discretionary
EOF
)")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$P2_BODY")
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
  pass "p2 discretionary → unresolved P2 out of scope → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' (P2 ∉ {p0,p1}); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 17: feedback_policy mode: address-all → unresolved P3 blocks (every
#          tier required).
# ---------------------------------------------------------------------------
echo
echo "--- Test 17 (#577): mode address-all → unresolved P3 blocks"
SCRATCH=$(make_scratch_with_policy "$(cat <<'EOF'
feedback_policy:
  mode: address-all
EOF
)")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$P3_BODY")
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
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P3\] src/foo.ts:42"; then
  pass "address-all → unresolved P3 → exit 1, listed as [P3]"
else
  fail "expected rc=1 with 'unresolved: 1' + [P3] path; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 18: malformed feedback_policy (bad tier value) + gate enabled → exit 2.
#          resolve_required_tiers returns 2; the gate treats it as a config
#          error, the same posture as a bad p1_gate.enabled value.
# ---------------------------------------------------------------------------
echo
echo "--- Test 18 (#577): malformed feedback_policy tier value → exit 2"
SCRATCH=$(make_scratch_with_policy "$(cat <<'EOF'
feedback_policy:
  mode: by-priority
  priorities:
    p0: banana
    p1: required
EOF
)")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$P0_BODY")
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
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "malformed feedback_policy"; then
  pass "malformed feedback_policy tier → exit 2 (fail closed)"
else
  fail "expected rc=2 with 'malformed feedback_policy'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# Pagination cases (#592). The gate paginates the reviewThreads connection AND
# each thread's nested comments connection with a cursor loop, failing closed
# on any GraphQL error / malformed page / exceeded safety cap.
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 19 (#592): >100 threads, blocking P1 RESOLVED on page 2. Proves page-2
# threads are actually fetched AND their resolution honored — the P1 must clear
# (exit 0), which it can only do if the gate read page 2's isResolved=true.
# Page 1: unrelated unresolved thread on a NON-blocking (P3) comment.
# ---------------------------------------------------------------------------
echo
echo "--- Test 19 (#592): P1 resolved on threads page 2 → collected + honored → exit 0"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "![P1 Badge](url) Finding.")
# Page 1: a thread whose only comment (7777) is NOT a Codex blocking comment,
# left unresolved — it must not affect the verdict.
FIXTURE_THREADS_null=$(make_threads_fixture \
  '[{isResolved: false, comment_ids: [7777]}]' "" true CUR1)
# Page 2: the P1 thread (comment 1001), RESOLVED.
FIXTURE_THREADS_CUR1=$(make_threads_fixture \
  '[{isResolved: true, comment_ids: [1001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS_null="$FIXTURE_THREADS_null" \
  FIXTURE_THREADS_CUR1="$FIXTURE_THREADS_CUR1" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
  pass "P1 resolved on threads page 2 → collected + honored → exit 0"
else
  fail "expected rc=0 (page-2 resolution honored); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 20 (#592): a thread with >100 comments where the blocking comment id is
# on comments PAGE 2. The gate must paginate the nested comments connection,
# find id 1001, and (thread unresolved) block. The first comments page holds an
# unrelated id (8001); page 2 (cursor CCUR1) holds 1001.
# ---------------------------------------------------------------------------
echo
echo "--- Test 20 (#592): blocking comment on nested comments page 2 → caught → exit 1"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "![P1 Badge](url) Finding.")
# One thread (T0), unresolved, whose comments connection overflows: page 1
# carries id 8001 + hasNextPage=true + endCursor CCUR1.
FIXTURE_THREADS_null=$(make_threads_fixture \
  '[{id: "TX", isResolved: false, comment_ids: [8001], comments_has_next: true, comments_end_cursor: "CCUR1"}]')
# Nested comments page 2 for node TX at cursor CCUR1: the blocking id 1001.
FIXTURE_TCOMMENTS_TX_CCUR1=$(make_thread_comments_fixture '[1001]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS_null="$FIXTURE_THREADS_null" \
  FIXTURE_TCOMMENTS_TX_CCUR1="$FIXTURE_TCOMMENTS_TX_CCUR1" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "src/foo.ts:42"; then
  pass "blocking comment id on nested page 2 → caught, unresolved → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' + path (nested pagination); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 20b (#592): same nested-overflow thread, but the blocking id's thread is
# RESOLVED. The gate collects id 1001 from nested page 2 and honors the resolved
# state → exit 0. Proves nested pagination is not only "find the id" but that
# the resolved verdict rides through it.
# ---------------------------------------------------------------------------
echo
echo "--- Test 20b (#592): blocking id on nested page 2, thread resolved → exit 0"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "![P1 Badge](url) Finding.")
FIXTURE_THREADS_null=$(make_threads_fixture \
  '[{id: "TX", isResolved: true, comment_ids: [8001], comments_has_next: true, comments_end_cursor: "CCUR1"}]')
FIXTURE_TCOMMENTS_TX_CCUR1=$(make_thread_comments_fixture '[1001]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS_null="$FIXTURE_THREADS_null" \
  FIXTURE_TCOMMENTS_TX_CCUR1="$FIXTURE_TCOMMENTS_TX_CCUR1" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "Codex blocking-tier unresolved: 0"; then
  pass "blocking id on nested page 2, thread resolved → exit 0"
else
  fail "expected rc=0 (nested-page resolution honored); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 21 (#592): nested comments page-2 GraphQL error → fail closed (exit 2).
# The thread overflows comments; the page-2 node(id:...) fixture is ABSENT, so
# the stub returns empty and the gate's `jq -e .data.node.comments.nodes`
# guard trips → die 2. (Empty stdout is the stub's proxy for a gh failure /
# malformed page here.)
# ---------------------------------------------------------------------------
echo
echo "--- Test 21 (#592): nested comments page-2 error → fail closed exit 2"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "![P1 Badge](url) Finding.")
FIXTURE_THREADS_null=$(make_threads_fixture \
  '[{id: "TX", isResolved: false, comment_ids: [8001], comments_has_next: true, comments_end_cursor: "CCUR1"}]')
# NB: no FIXTURE_TCOMMENTS_TX_CCUR1 exported → stub emits nothing → malformed.
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS_null="$FIXTURE_THREADS_null" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "malformed thread comments"; then
  pass "nested comments page-2 error → fail closed exit 2"
else
  fail "expected rc=2 with 'malformed thread comments'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 22 (#592): top-level reviewThreads page-2 GraphQL error → fail closed
# (exit 2). Page 1 declares hasNextPage=true + endCursor CUR1, but the page-2
# fixture (FIXTURE_THREADS_CUR1) is ABSENT → stub emits nothing → the malformed
# reviewThreads guard trips.
# ---------------------------------------------------------------------------
echo
echo "--- Test 22 (#592): reviewThreads page-2 error → fail closed exit 2"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "![P1 Badge](url) Finding.")
FIXTURE_THREADS_null=$(make_threads_fixture \
  '[{isResolved: false, comment_ids: [9001]}]' "" true CUR1)
# NB: no FIXTURE_THREADS_CUR1 exported → page-2 fetch returns empty → malformed.
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS_null="$FIXTURE_THREADS_null" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "malformed reviewThreads"; then
  pass "reviewThreads page-2 error → fail closed exit 2"
else
  fail "expected rc=2 with 'malformed reviewThreads'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 23 (#592): hasNextPage=true but endCursor=null → fail closed (exit 2).
# A cursor-stall shape: the gate must not loop forever or silently stop; it
# fails closed on the missing cursor.
# ---------------------------------------------------------------------------
echo
echo "--- Test 23 (#592): hasNextPage=true + null endCursor → fail closed exit 2"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "![P1 Badge](url) Finding.")
FIXTURE_THREADS_null=$(make_threads_fixture \
  '[{isResolved: false, comment_ids: [1001]}]' "" true null)
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS_null="$FIXTURE_THREADS_null" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "hasNextPage but no endCursor"; then
  pass "hasNextPage=true + null endCursor → fail closed exit 2"
else
  fail "expected rc=2 with 'hasNextPage but no endCursor'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
echo
echo "============================================"
echo "test_codex_p1_gate.sh: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
