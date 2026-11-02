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
#   1. Legacy P1 scan disabled → accounting runs, then exit 0 with no legacy
#      API calls.
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
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true

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
  jq_filter=""
  cursor="__none__"
  node_id="__none__"
  prev=""
  for a in "$@"; do
    case "$prev" in
      query=*) : ;;  # handled below via the value directly
      --jq) jq_filter="$a" ;;
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
      if grep -q 'PullRequestReviewThread' <<<"$q"; then
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
      [ -n "${GH_SUCCESS_STDERR:-}" ] && printf '%s\n' "$GH_SUCCESS_STDERR" >&2
      if [ -n "$jq_filter" ]; then
        jq -r "$jq_filter" "${FIXTURE_PR:-/dev/null}"
      else
        cat "${FIXTURE_PR:-/dev/null}"
      fi
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
      GH_SUCCESS_STDERR="${GH_SUCCESS_STDERR:-}" \
      "$SCRIPT" "$@"
  )
}

# The feedback-accounting gate is independently testable from the legacy
# current-HEAD thread scan. A missing disposition must block before any of the
# latter's GitHub reads begin.
FEEDBACK_GATE_STUB="$WORKDIR/feedback-accounting-block.sh"
cat >"$FEEDBACK_GATE_STUB" <<'EOF'
#!/bin/sh
printf '%s\n' '{"status":"unaccounted","posted":1,"accounted":0}'
exit 1
EOF
chmod +x "$FEEDBACK_GATE_STUB"

# ---------------------------------------------------------------------------
# Test 1: Legacy P1 scan disabled — accounting clears, no legacy API calls.
# ---------------------------------------------------------------------------
echo
echo "--- Test 1: gate disabled (enabled=false)"
SCRATCH=$(make_scratch_with_config false)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT" \
    && ! grep -q "^gh" "$WORKDIR/gh-calls.log"; then
  pass "legacy P1 scan disabled exits 0 after accounting with no legacy API calls"
else
  fail "expected rc=0 + 'unresolved: 0' + no gh calls; got rc=$RC, output:"
  echo "$OUT" | sed 's/^/      /' >&2
  echo "    gh calls:" >&2
  sed 's/^/      /' "$WORKDIR/gh-calls.log" >&2
fi

# ---------------------------------------------------------------------------
# Test 1b (#1000): accounting is default-on even when the legacy P1 scan is
# disabled, so a bare invocation cannot claim a clean result without PR
# context.
# ---------------------------------------------------------------------------
echo
echo "--- Test 1b (#1000): legacy P1 scan disabled + no PR context"
SCRATCH=$(make_scratch_with_config false)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$( cd "$SCRATCH" && PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/gh-calls.log" \
  env -u GH_TOKEN -u PR_NUMBER -u REPO "$SCRIPT" 2>&1 )
RC=$?
set -e
if [ "$RC" = 2 ] && grep -q "PR_NUMBER required" <<<"$OUT" \
    && ! grep -q "^gh" "$WORKDIR/gh-calls.log"; then
  pass "#1000: default-on accounting requires PR context even when the legacy scan is disabled"
else
  fail "#1000: expected rc=2 + PR_NUMBER error + no gh calls; got rc=$RC, output:"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo
echo "--- Test 1d (#1000): undispositioned feedback blocks even when legacy P1 is disabled"
SCRATCH=$(make_scratch_with_config false)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$FEEDBACK_GATE_STUB" \
  run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && grep -q 'review feedback is unaccounted' <<<"$OUT" \
    && ! grep -q '^gh' "$WORKDIR/gh-calls.log"; then
  pass "#1000: feedback accounting miss blocks every consumer before legacy P1 reads"
else
  fail "#1000 feedback-accounting integration (rc=$RC, out=$OUT)"
fi

echo
echo "--- Test 1e (#1000): expected-head mutation fails closed before publication"
SCRATCH=$(make_scratch_with_config false)
FIXTURE_PR=$(make_pr_fixture "bbbb2222")
set +e
OUT=$(CODEX_P1_EXPECTED_HEAD_SHA="aaaa1111" FIXTURE_PR="$FIXTURE_PR" \
  run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && grep -q 'PR head drifted during gate evaluation' <<<"$OUT"; then
  pass "#1000: a synchronize during issue-comment evaluation fails closed"
else
  fail "#1000 expected-head drift guard (rc=$RC, out=$OUT)"
fi

echo
echo "--- Test 1f (#1008): drift read keeps successful stderr out of the SHA payload"
SCRATCH=$(make_scratch_with_config false)
FIXTURE_PR=$(make_pr_fixture "cafe1234")
set +e
OUT=$(CODEX_P1_EXPECTED_HEAD_SHA="cafe1234" FIXTURE_PR="$FIXTURE_PR" \
  GH_SUCCESS_STDERR="benign gh retry notice" \
  run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && grep -q 'Codex blocking-tier unresolved: 0' <<<"$OUT"; then
  pass "#1008: successful drift read ignores gh stderr chatter"
else
  fail "#1008 drift-read stream isolation (rc=$RC, out=$OUT)"
fi

# Control: enabled legacy scan + no env errors for the same reason.
echo "--- Test 1c (#447 control): gate enabled + no PR_NUMBER → exit 2"
SCRATCH=$(make_scratch_with_config true)
set +e
OUT=$( cd "$SCRATCH" && PATH="$STUB_DIR:$PATH" \
  env -u GH_TOKEN -u PR_NUMBER -u REPO "$SCRIPT" 2>&1 )
RC=$?
set -e
if [ "$RC" = 2 ] && grep -q "PR_NUMBER required" <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
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
if [ "$RC" = 1 ] && grep -q "Codex blocking-tier unresolved: 1" <<<"$OUT" \
    && grep -q "src/foo.ts:42" <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
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
if [ "$RC" = 1 ] && grep -q "Codex blocking-tier unresolved: 1" <<<"$OUT" \
    && grep -q "src/bar.ts:99" <<<"$OUT" \
    && ! grep -qE "Unresolved.*foo\.ts:42" <<<"$OUT"; then
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
if [ "$RC" = 2 ] && grep -qi "PR_NUMBER must be an integer" <<<"$OUT"; then
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
if [ "$RC" = 2 ] && grep -q "GH_TOKEN is required" <<<"$OUT"; then
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
if [ "$RC" = 1 ] && grep -q "Codex blocking-tier unresolved: 1" <<<"$OUT" \
    && grep -q "src/foo.ts:42" <<<"$OUT"; then
  pass ">100 threads → page 2 paginated, unresolved P1 → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' + path (page-2 pagination); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11: enabled knob absent → accounting still runs, legacy scan skips.
# ---------------------------------------------------------------------------
echo
echo "--- Test 11: codex.p1_gate block absent → defaults to disabled"
SCRATCH=$(make_scratch_with_config absent)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
  pass "missing p1_gate block → accounting clears, legacy scan defaults disabled"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Tests 11a–11c (#817): both scalar readers in this script strip single AND
# double quotes, matching scripts/codex-review-check.sh codex_field. They used
# to strip double quotes only, which broke in two opposite directions:
#
#   11a  `enabled: 'true'` reached the true|false validator as the 6-character
#        string with its quotes intact and exited 2 — a required gate
#        deadlocked by a benign YAML quoting choice.
#   11b  a single-quoted `bot_login` matched zero comments, so a real
#        unresolved P1 from the bot went uncounted and the gate passed. That
#        is the soundness direction: a vacuous pass, not a stall.
#   11c  `enabled: 'false'` must still resolve to the off-state clean pass
#        rather than the validator error, so the fix is symmetric.
#
# Written against raw config text so the quoting under test is literal.
# ---------------------------------------------------------------------------
make_scratch_raw_config() {  # <verbatim review-policy.yml body>
  local body=$1 dir
  dir=$(mktemp -d "$WORKDIR/scratch.XXXXXX")
  mkdir -p "$dir/.github"
  printf '%s\n' "$body" >"$dir/.github/review-policy.yml"
  echo "$dir"
}

echo
echo "--- Test 11a (#817): single-quoted p1_gate.enabled → parsed, not exit 2"
SCRATCH=$(make_scratch_raw_config "codex:
  bot_login: \"chatgpt-codex-connector[bot]\"
  p1_gate:
    enabled: 'true'")
HEAD_SHA="abc123def456"
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "![P1 Badge](url) Stop retrying endlessly.")
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
if [ "$RC" = 1 ] && grep -q "Codex blocking-tier unresolved: 1" <<<"$OUT"; then
  pass "#817: enabled: 'true' enables the gate (was exit 2)"
else
  fail "#817: expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo
echo "--- Test 11b (#817): single-quoted bot_login still matches the bot"
SCRATCH=$(make_scratch_raw_config "codex:
  bot_login: 'chatgpt-codex-connector[bot]'
  p1_gate:
    enabled: true")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "![P1 Badge](url) Stop retrying endlessly.")
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
if [ "$RC" = 1 ] && grep -q "Codex blocking-tier unresolved: 1" <<<"$OUT"; then
  pass "#817: single-quoted bot_login counts the bot's finding (was a vacuous pass)"
else
  fail "#817: expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo
echo "--- Test 11c (#817): single-quoted enabled: 'false' → accounting then legacy-scan skip"
SCRATCH=$(make_scratch_raw_config "codex:
  bot_login: \"chatgpt-codex-connector[bot]\"
  p1_gate:
    enabled: 'false'")
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT" \
    && ! grep -q "^gh" "$WORKDIR/gh-calls.log"; then
  pass "#817: enabled: 'false' → accounting pass then no legacy API calls"
else
  fail "#817: expected rc=0 + 'unresolved: 0' + no gh calls; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi


# ---------------------------------------------------------------------------
# Tests 11d–11h (#2913): both codex.* reads come from the parsed policy. The
# earlier line-oriented awk readers matched only an unquoted, block-style
# `field:` key, so a quoted key or a flow mapping read as unset: the legacy
# scan stayed off and a custom bot_login was missed. LEGACY_P1_GATE_AWK is the
# old p1_gate reader, kept as the mutation baseline for these spellings.
# ---------------------------------------------------------------------------
LEGACY_P1_GATE_AWK='
  /^codex:/ { in_codex=1; in_p1_gate=0; next }
  in_codex && /^[^[:space:]#]/ { in_codex=0; in_p1_gate=0 }
  in_codex && /^[[:space:]]+p1_gate:/ { in_p1_gate=1; next }
  in_p1_gate && /^[[:space:]]{0,3}[^[:space:]#]/ { in_p1_gate=0 }
  in_p1_gate && $1 == field":" {
    sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
    gsub(/^["\047]/, "", $0)
    gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
    gsub(/[[:space:]]*#.*$/, "", $0)
    sub(/[[:space:]]+$/, "", $0)
    print
    exit
  }
'
custom_bot_comment_fixture() {  # <sha> -- one unresolved P1 by custom-codex[bot]
  make_comments_fixture "$(jq -n --arg sha "$1" '
    [{ id: 1001, user: { login: "custom-codex[bot]" },
       body: "![P1 Badge](url) Stop retrying endlessly.",
       path: "src/foo.ts", line: 42, commit_id: $sha, original_commit_id: $sha }]')"
}

HEAD_SHA="abc123def456"
for spec in \
  "11d quoted keys|codex:"$'\n'"  \"bot_login\": \"custom-codex[bot]\""$'\n'"  \"p1_gate\":"$'\n'"    \"enabled\": true" \
  "11e flow mapping|codex: {bot_login: \"custom-codex[bot]\", p1_gate: {enabled: true}}" \
  "11f nested flow mapping|codex:"$'\n'"  bot_login: custom-codex[bot]"$'\n'"  p1_gate: {\"enabled\": true}"; do
  label=${spec%%|*} body=${spec#*|}
  echo
  echo "--- Test $label (#2913): the legacy scan is enabled and the custom bot is counted"
  SCRATCH=$(make_scratch_raw_config "$body")
  FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
  FIXTURE_COMMENTS=$(custom_bot_comment_fixture "$HEAD_SHA")
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
  if [ "$RC" = 1 ] && grep -q "Codex blocking-tier unresolved: 1" <<<"$OUT"; then
    pass "#2913 $label: p1_gate.enabled and bot_login are read; the custom bot's P1 blocks"
  else
    fail "#2913 $label: expected rc=1 with 'unresolved: 1'; got rc=$RC"
    echo "$OUT" | sed 's/^/      /' >&2
  fi
  legacy=$(awk -v field=enabled "$LEGACY_P1_GATE_AWK" "$SCRATCH/.github/review-policy.yml")
  if [ "$legacy" != "true" ]; then
    pass "#2913 mutation $label: the legacy p1_gate reader misreads enabled ('$legacy'), so the case detects a regression"
  else
    fail "#2913 mutation $label: the legacy p1_gate reader already reads enabled; the case proves nothing"
  fi
done

# A policy that cannot be parsed, or a p1_gate that is not a mapping, is a
# config error (exit 2) before any GitHub read, not the disabled default.
for spec in \
  "11g unparseable policy|codex:"$'\n'"  p1_gate:"$'\n'"    enabled: [unclosed|could not be parsed" \
  "11h non-mapping p1_gate|codex: {p1_gate: true}|codex.p1_gate must be a mapping"; do
  label=${spec%%|*} rest=${spec#*|}
  body=${rest%|*} want=${rest##*|}
  echo
  echo "--- Test $label (#2913): exit 2 before any read"
  SCRATCH=$(make_scratch_raw_config "$body")
  : > "$WORKDIR/gh-calls.log"
  set +e
  OUT=$(run_gate "$SCRATCH" 99 owner/repo 2>&1)
  RC=$?
  set -e
  if [ "$RC" = 2 ] && grep -qF "$want" <<<"$OUT" && ! grep -q "^gh" "$WORKDIR/gh-calls.log"; then
    pass "#2913 $label: exit 2 naming the cause, no GitHub reads"
  else
    fail "#2913 $label: expected rc=2 naming '$want' and no gh calls; got rc=$RC"
    echo "$OUT" | sed 's/^/      /' >&2
  fi
done

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
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
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
if [ "$RC" = 2 ] && grep -qi "PR_NUMBER required" <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
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
if [ "$RC" = 1 ] && grep -q "Codex blocking-tier unresolved: 1" <<<"$OUT" \
    && grep -q "\[P0\] src/foo.ts:42" <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
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
if [ "$RC" = 1 ] && grep -q "Codex blocking-tier unresolved: 1" <<<"$OUT" \
    && grep -q "\[P3\] src/foo.ts:42" <<<"$OUT"; then
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
if [ "$RC" = 2 ] && grep -qi "malformed feedback_policy" <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
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
if [ "$RC" = 1 ] && grep -q "Codex blocking-tier unresolved: 1" <<<"$OUT" \
    && grep -q "src/foo.ts:42" <<<"$OUT"; then
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
if [ "$RC" = 0 ] && grep -q "Codex blocking-tier unresolved: 0" <<<"$OUT"; then
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
if [ "$RC" = 2 ] && grep -qi "malformed thread comments" <<<"$OUT"; then
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
if [ "$RC" = 2 ] && grep -qi "malformed reviewThreads" <<<"$OUT"; then
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
if [ "$RC" = 2 ] && grep -qi "hasNextPage but no endCursor" <<<"$OUT"; then
  pass "hasNextPage=true + null endCursor → fail closed exit 2"
else
  fail "expected rc=2 with 'hasNextPage but no endCursor'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 24 (#2618): the explicit pending verdict. With MERGEPATH_GATE_VERDICT_FILE
# set, an accounting failure whose undispositioned findings are ALL
# non-blocking does not stop the gate: it still runs the head-drift fence and
# the legacy blocking-tier scan, and writes exactly `pending` only when both
# found nothing. Every blocking, unknown, malformed or error state leaves the
# file absent; without the variable the output is byte-identical to before.
# ---------------------------------------------------------------------------
echo
echo "--- Test 24 (#2618): pending verdict for non-blocking findings awaiting disposition"
ACCOUNTING_STUB="$WORKDIR/feedback-accounting-json.sh"
cat >"$ACCOUNTING_STUB" <<'EOF'
#!/bin/sh
cat "$ACCOUNTING_JSON"
exit "${ACCOUNTING_RC:-1}"
EOF
chmod +x "$ACCOUNTING_STUB"
# accounting_answer <missing JSON array> [feedback_policy JSON] -> file path
accounting_answer() {
  local file="$WORKDIR/accounting.$$.$RANDOM.json"
  jq -nc --argjson missing "$1" --argjson policy "${2:-{\}}" '{
    status: "unaccounted", repo: "owner/repo", pr_number: 99,
    feedback_policy: $policy, posted: ($missing | length), accounted: 0,
    missing_count: ($missing | length), findings: $missing, missing: $missing
  }' >"$file"
  echo "$file"
}
P2_INLINE='[{"kind":"inline","reviewer":"chatgpt-codex-connector[bot]","tier":"p2","finding_id":7,"path":"a.sh","line":3,"accounted":false}]'
MINOR_CR='[{"kind":"inline","reviewer":"coderabbitai[bot]","tier":"p2","finding_id":8,"path":"b.sh","line":4,"accounted":false},{"kind":"issue-comment","reviewer":"coderabbitai[bot]","tier":"nitpick","comment_id":9,"accounted":false}]'
P1_AND_P2='[{"kind":"inline","reviewer":"chatgpt-codex-connector[bot]","tier":"p2","finding_id":7,"accounted":false},{"kind":"review-body","reviewer":"chatgpt-codex-connector[bot]","tier":"p1","review_id":10,"accounted":false}]'
MERGEPATH_POLICY='{"mode":"by-priority","priorities":{"p0":"required","p1":"required","p2":"discretionary","p3":"discretionary","nitpick":"discretionary"}}'
CLEAR_THREADS=$(make_threads_fixture '[{isResolved: true, comment_ids: [1001]}]')
OPEN_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [1001]}]')
P1_ON_HEAD=$(make_single_comment_fixture "$HEAD_SHA" "![P1 Badge](url) Real blocker.")
NO_COMMENTS=$(make_comments_fixture '[]')
PR_ON_HEAD=$(make_pr_fixture "$HEAD_SHA")

# pending_case <label> <expect: pending|none> <expected rc> <answer file>
#   [scratch-kind] [comments fixture] [threads fixture] [extra VAR=value ...]
# Runs the gate twice: once with the verdict file (the event job's ask) and
# once without it, and asserts the verdict-free run kept today's exact output.
pending_case() {
  local label=$1 expect=$2 want_rc=$3 answer=$4 scratch_kind=${5:-enabled}
  local comments=${6:-$NO_COMMENTS} threads=${7:-$CLEAR_THREADS}
  shift 7 2>/dev/null || shift $#
  local scratch vfile out rc out_plain rc_plain content
  case "$scratch_kind" in
    disabled) scratch=$(make_scratch_with_config false) ;;
    p2-required) scratch=$(make_scratch_with_policy "$(printf 'feedback_policy:\n  mode: by-priority\n  priorities:\n    p1: required\n    p2: required\n')") ;;
    *) scratch=$(make_scratch_with_config true) ;;
  esac
  vfile="$WORKDIR/verdict.$RANDOM"
  rm -f "$vfile"
  set +e
  out=$(
    export ACCOUNTING_JSON="$answer" MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$ACCOUNTING_STUB" \
      FIXTURE_PR="$PR_ON_HEAD" FIXTURE_COMMENTS="$comments" FIXTURE_THREADS="$threads" \
      CODEX_P1_EXPECTED_HEAD_SHA="$HEAD_SHA" MERGEPATH_GATE_VERDICT_FILE="$vfile"
    for kv in "$@"; do export "${kv?}"; done
    run_gate "$scratch" 99 owner/repo 2>/dev/null
  )
  rc=$?
  out_plain=$(
    export ACCOUNTING_JSON="$answer" MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$ACCOUNTING_STUB" \
      FIXTURE_PR="$PR_ON_HEAD" FIXTURE_COMMENTS="$comments" FIXTURE_THREADS="$threads" \
      CODEX_P1_EXPECTED_HEAD_SHA="$HEAD_SHA"
    for kv in "$@"; do export "${kv?}"; done
    run_gate "$scratch" 99 owner/repo 2>/dev/null
  )
  rc_plain=$?
  set -e
  content=$(cat "$vfile" 2>/dev/null || echo "<absent>")
  # Verdict-free: stdout is the accounting answer alone (today's stop at the
  # accounting failure), or nothing on an accounting error.
  if [ "$out_plain" != "$(cat "$answer")" ] && [ "$rc_plain" != 2 ]; then
    fail "#2618: $label changed the verdict-free stdout (rc=$rc_plain out=$out_plain)"
    return 0
  fi
  if [ "$expect" = pending ]; then
    if [ "$rc" = 1 ] && [ "$content" = pending ] && [ "$rc_plain" = 1 ] \
        && grep -q '"status":"unaccounted"' <<<"$out"; then
      pass "#2618: $label → rc 1, verdict file reads pending, accounting answer still reported"
    else
      fail "#2618: $label expected pending (rc=$rc file=$content plain_rc=$rc_plain out=$out)"
    fi
  else
    if [ "$rc" = "$want_rc" ] && [ "$content" = "<absent>" ] && [ "$rc_plain" != 0 ]; then
      pass "#2618: $label → rc $want_rc, no pending verdict"
    else
      fail "#2618: $label expected rc $want_rc and no verdict (rc=$rc file=$content plain_rc=$rc_plain out=$out)"
    fi
  fi
}

# (a) only non-blocking findings await disposition.
pending_case "Codex P2 awaiting disposition, no blocking-tier thread" pending 1 \
  "$(accounting_answer "$P2_INLINE" "$MERGEPATH_POLICY")"
pending_case "CodeRabbit Minor + nitpick awaiting disposition" pending 1 \
  "$(accounting_answer "$MINOR_CR" "$MERGEPATH_POLICY")"
pending_case "absent governing policy, P2 awaiting disposition" pending 1 \
  "$(accounting_answer "$P2_INLINE")"
pending_case "legacy scan disabled, P2 awaiting disposition" pending 1 \
  "$(accounting_answer "$P2_INLINE" "$MERGEPATH_POLICY")" disabled
pending_case "resolved P1 thread on HEAD, P2 awaiting disposition" pending 1 \
  "$(accounting_answer "$P2_INLINE" "$MERGEPATH_POLICY")" enabled "$P1_ON_HEAD" "$CLEAR_THREADS"

# (c) a real blocker anywhere keeps the failure.
pending_case "P1 awaiting disposition beside a P2" none 1 \
  "$(accounting_answer "$P1_AND_P2" "$MERGEPATH_POLICY")"
pending_case "P0 awaiting disposition" none 1 \
  "$(accounting_answer '[{"kind":"inline","tier":"p0","accounted":false}]' "$MERGEPATH_POLICY")"
pending_case "P2 awaiting disposition + UNRESOLVED P1 thread on HEAD" none 1 \
  "$(accounting_answer "$P2_INLINE" "$MERGEPATH_POLICY")" enabled "$P1_ON_HEAD" "$OPEN_THREADS"
pending_case "governing policy requires p2" none 1 \
  "$(accounting_answer "$P2_INLINE" '{"mode":"by-priority","priorities":{"p2":"required"}}')"
pending_case "governing policy is address-all" none 1 \
  "$(accounting_answer "$P2_INLINE" '{"mode":"address-all"}')"
pending_case "trusted gate config makes p2 blocking-tier" none 1 \
  "$(accounting_answer "$P2_INLINE" "$MERGEPATH_POLICY")" p2-required

# (d) unknown tiers, malformed answers and every error stay failing.
pending_case "unknown tier" none 1 \
  "$(accounting_answer '[{"kind":"inline","tier":"p9","accounted":false}]' "$MERGEPATH_POLICY")"
pending_case "missing tier" none 1 \
  "$(accounting_answer '[{"kind":"inline","accounted":false}]' "$MERGEPATH_POLICY")"
pending_case "null tier" none 1 \
  "$(accounting_answer '[{"kind":"inline","tier":null,"accounted":false}]' "$MERGEPATH_POLICY")"
pending_case "unknown finding kind" none 1 \
  "$(accounting_answer '[{"kind":"telepathy","tier":"p2","accounted":false}]' "$MERGEPATH_POLICY")"
pending_case "unknown policy mode" none 1 \
  "$(accounting_answer "$P2_INLINE" '{"mode":"vibes"}')"
BAD_COUNT="$WORKDIR/accounting-bad-count.json"
jq -c '.missing_count = 0' "$(accounting_answer "$P2_INLINE")" >"$BAD_COUNT"
pending_case "missing_count disagrees with the list" none 1 "$BAD_COUNT"
EMPTY_MISSING="$WORKDIR/accounting-empty.json"
accounting_answer '[]' >/dev/null
jq -n '{status:"unaccounted",missing:[],missing_count:0}' >"$EMPTY_MISSING"
pending_case "unaccounted with an empty missing list" none 1 "$EMPTY_MISSING"
NOT_JSON="$WORKDIR/accounting-not-json.txt"
printf 'not json at all\n' >"$NOT_JSON"
pending_case "accounting answer is not JSON" none 1 "$NOT_JSON"
pending_case "accounting read/API error (rc 2)" none 2 \
  "$(accounting_answer "$P2_INLINE" "$MERGEPATH_POLICY")" enabled "$NO_COMMENTS" "$CLEAR_THREADS" ACCOUNTING_RC=2
pending_case "reviewThreads API error after a non-blocking accounting failure" none 2 \
  "$(accounting_answer "$P2_INLINE" "$MERGEPATH_POLICY")" enabled "$P1_ON_HEAD" /dev/null
pending_case "PR head drifted after a non-blocking accounting failure" none 2 \
  "$(accounting_answer "$P2_INLINE" "$MERGEPATH_POLICY")" enabled "$NO_COMMENTS" "$CLEAR_THREADS" \
  CODEX_P1_EXPECTED_HEAD_SHA=feedface

# Without the variable the gate is exactly what it was: it stops at the
# accounting failure, before any legacy read, with the same stdout.
SCRATCH=$(make_scratch_with_config true)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(ACCOUNTING_JSON="$(accounting_answer "$P2_INLINE" "$MERGEPATH_POLICY")" \
  MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$ACCOUNTING_STUB" \
  FIXTURE_PR="$PR_ON_HEAD" run_gate "$SCRATCH" 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 1 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] \
    && grep -q '"status":"unaccounted"' <<<"$OUT" && ! grep -q '^gh' "$WORKDIR/gh-calls.log"; then
  pass "#2618: without MERGEPATH_GATE_VERDICT_FILE a non-blocking miss stops before legacy reads, stdout unchanged"
else
  fail "#2618: verdict-free behaviour changed (rc=$RC, out=$OUT)"
fi

# ---------------------------------------------------------------------------
echo
echo "============================================"
echo "test_codex_p1_gate.sh: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
