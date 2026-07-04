#!/usr/bin/env bash
# tests/test_coderabbit_severity_gate.sh
#
# Unit tests for scripts/coderabbit-severity-gate.sh — the CodeRabbit
# twin of scripts/codex-p1-gate.sh (nathanjohnpayne/mergepath#577).
#
# Strategy: PATH-shim `gh` so the script's REST + GraphQL calls return
# canned payloads from fixture files. Same shape as the PATH-shimmed gh in
# tests/test_codex_p1_gate.sh.
#
# Cases covered:
#   1. Gate disabled (coderabbit.severity_gate.enabled=false) → exit 0,
#      no API calls.
#   1b. Gate disabled + no env (no PR_NUMBER/REPO/GH_TOKEN) → exit 0 clean
#       pass (off-state short-circuit precedes the PR-context requirements).
#   1c. Gate enabled + no env → exit 2 (env required once enabled).
#   2. Gate enabled, no CodeRabbit findings at all → exit 0.
#   3. ⚠️ Potential issue (Major → p1) present and resolved → exit 0.
#   4. ⚠️ Potential issue (Major → p1) present and unresolved → exit 1.
#   5. Finding only on a stale SHA (not HEAD) → exit 0, doesn't gate.
#   6. Finding from a NON-bot author → exit 0 (must be bot to count).
#   7. enabled knob absent → default false → exit 0.
#   8. Malformed PR_NUMBER → exit 2.
#   9. >100 review threads → PAGINATED (#592): finding on threads page 2,
#      collected + classified unresolved → exit 1 (was exit 2 in v1).
#   9b. >100 comments in one thread → nested comments PAGINATED (#592): the
#      blocking comment id sits on comments page 2, is fetched, thread
#      unresolved → exit 1 (was exit 2 in v1). Closes the #590 gap PRECISELY.
#   10. PR_NUMBER + REPO via env (no positional args) → same behavior.
#
# Tier-aware cases (the gate enforces the resolved tier SET):
#   11. by-priority p0+p1 required → unresolved 🧹 Nitpick (nitpick tier)
#       does NOT block (nitpick ∉ {p0,p1}) → exit 0.
#   12. by-priority + nitpick required → unresolved 🧹 Nitpick blocks → exit 1.
#   13. by-priority p0+p1 required → unresolved ⚠️ Potential issue (p1;
#       CodeRabbit tops at p1) blocks → exit 1, listed [P1].
#   14. by-priority p0+p1 required → unresolved Refactor suggestion (p2)
#       does NOT block → exit 0.
#
# nitpick-under-chill no-op warning (advisory; never changes the verdict):
#   15. nitpick required + .coderabbit.yml reviews.profile: chill → WARNING.
#   16. nitpick required + reviews.profile: assertive → no warning.
#   17. nitpick discretionary (default) + chill → no warning (claim not made).
#
# Pagination cases (#592 — reviewThreads + nested comments cursor loop):
#   18. finding RESOLVED on threads page 2 → collected + honored → exit 0.
#   19. blocking id on nested comments page 2, thread resolved → exit 0.
#   20. nested comments page-2 GraphQL error → fail closed exit 2.
#   21. reviewThreads page-2 GraphQL error → fail closed exit 2.
#   22. hasNextPage=true but endCursor=null → fail closed exit 2.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/coderabbit-severity-gate.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (coderabbit-severity-gate.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coderabbit-severity-gate-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# PATH-shim `gh` — identical routing to tests/test_codex_p1_gate.sh.
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

  # For graphql, capture the query body + cursor + node id so the stub can
  # serve the right pagination page (#592). Same routing as
  # tests/test_codex_p1_gate.sh.
  q=""
  cursor="__none__"
  node_id="__none__"
  for a in "$@"; do
    case "$a" in
      query=*) q="${a#query=}" ;;
      cursor=*) cursor="${a#cursor=}" ;;
      id=*)     node_id="${a#id=}" ;;
    esac
  done

  case "$endpoint" in
    graphql)
      if printf '%s' "$q" | grep -q 'PullRequestReviewThread'; then
        f="FIXTURE_TCOMMENTS_${node_id}_${cursor}"
        cat "${!f:-/dev/null}"
        exit 0
      fi
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
    # coderabbit: block present but no severity_gate sub-block at all.
    cat >"$dir/.github/review-policy.yml" <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
EOF
  else
    cat >"$dir/.github/review-policy.yml" <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
  severity_gate:
    enabled: $enabled
EOF
  fi
  echo "$dir"
}

# Scratch dir with the gate ENABLED plus a feedback_policy block appended
# verbatim. $1 = the multi-line block text (already `feedback_policy:`-rooted)
# or empty for "no feedback_policy block".
make_scratch_with_policy() {
  local policy_block=$1
  local dir
  dir=$(mktemp -d "$WORKDIR/scratch.XXXXXX")
  mkdir -p "$dir/.github"
  {
    cat <<EOF
coderabbit:
  bot_login: "coderabbitai[bot]"
  severity_gate:
    enabled: true
EOF
    if [ -n "$policy_block" ]; then
      printf '%s\n' "$policy_block"
    fi
  } >"$dir/.github/review-policy.yml"
  echo "$dir"
}

# ---------------------------------------------------------------------------
# Fixture builders — mirror tests/test_codex_p1_gate.sh.
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

make_comments_fixture() {
  local content=$1
  local file="$WORKDIR/comments.$$.$RANDOM.json"
  echo "$content" > "$file"
  echo "$file"
}

# Single CodeRabbit finding fixture for a given body + author login.
# $1 = HEAD sha, $2 = body, $3 = author login (defaults to the bot).
make_single_comment_fixture() {
  local sha=$1 body=$2 login=${3:-coderabbitai[bot]}
  make_comments_fixture "$(jq -n \
    --arg sha "$sha" --arg body "$body" --arg login "$login" '
    [{
      id: 2001,
      user: { login: $login },
      body: $body,
      path: "src/foo.ts",
      line: 42,
      commit_id: $sha,
      original_commit_id: $sha
    }]
  ')"
}

# reviewThreads GraphQL response fixture (one page) — same contract as
# tests/test_codex_p1_gate.sh. The paginating gate (#592) needs each node's
# `id` + comments pageInfo{hasNextPage,endCursor}, and the top-level page's
# endCursor.
#
# Args:
#   $1 = jq nodes expr — array of {isResolved, comment_ids} objects, optionally
#        with: id, comments_has_next, comments_end_cursor.
#   $2 = totalCount (retained for back-compat; ignored by the paginating gate).
#   $3 = top-level hasNextPage (default false).
#   $4 = GLOBAL nested-comments-hasNextPage override (default "": leave per-node
#        default). Back-compat with the #590 tests that flipped every node's
#        comments overflow via this positional. Per-node comments_has_next in
#        $1 takes precedence when set.
#   $5 = top-level endCursor (default null).
make_threads_fixture() {
  local nodes_expr=$1
  local total=${2:-}
  local has_next=${3:-false}
  local global_cnext=${4:-}
  local end_cursor=${5:-null}
  local file="$WORKDIR/threads.$$.$RANDOM.json"
  local resolved_nodes
  resolved_nodes=$(jq -n --arg gcnext "$global_cnext" "$nodes_expr | [ to_entries[] | .key as \$idx | .value | {
    id: (.id // \"T\(\$idx)\"),
    isResolved: .isResolved,
    comments: {
      pageInfo: {
        hasNextPage: (
          if .comments_has_next != null then .comments_has_next
          elif \$gcnext == \"true\" then true
          else false end
        ),
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

# Per-thread comments-page fixture for the node(id:...) query the gate issues
# when a thread's comments connection overflows 100 (#592). Same shape as
# tests/test_codex_p1_gate.sh's make_thread_comments_fixture.
#   $1 = jq expr → array of comment databaseIds.
#   $2 = hasNextPage (default false).
#   $3 = endCursor   (default null).
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

# CodeRabbit finding bodies (heuristic markers coderabbit_tier_of reads).
HEAD_SHA="abc123def456"
MAJOR_BODY="**⚠️ Potential issue** | **Major**

This pointer can be null."
CRITICAL_BODY="**⚠️ Potential issue** | **Critical**

Security: this leaks the credential."
NITPICK_BODY="**🧹 Nitpick (assertive)**

Consider renaming this local."
REFACTOR_BODY="**🛠️ Refactor suggestion**

Extract this into a helper."

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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! grep -q "^gh" "$WORKDIR/gh-calls.log"; then
  pass "gate disabled exits 0 with no API calls"
else
  fail "expected rc=0 + 'unresolved: 0' + no gh calls; got rc=$RC, output:"
  echo "$OUT" | sed 's/^/      /' >&2
  echo "    gh calls:" >&2
  sed 's/^/      /' "$WORKDIR/gh-calls.log" >&2
fi

# ---------------------------------------------------------------------------
# Test 1a2: gate disabled via a SINGLE-QUOTED value (enabled: 'false', #651).
# The parser must strip single quotes like it strips double quotes, or the
# later `case` rejects the value and the disabled gate never no-ops.
# ---------------------------------------------------------------------------
echo
echo "--- Test 1a2: gate disabled (enabled: 'false' — single-quoted, #651)"
SCRATCH=$(make_scratch_with_config "'false'")
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! grep -q "^gh" "$WORKDIR/gh-calls.log"; then
  pass "single-quoted enabled: 'false' parses as disabled (exits 0)"
else
  fail "single-quoted enabled: 'false' should disable the gate; got rc=$RC, output:"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 1b: gate disabled + NO env. The off-state short-circuit must run
# BEFORE the PR-context requirements.
# ---------------------------------------------------------------------------
echo
echo "--- Test 1b: gate disabled + no PR/REPO/GH_TOKEN env"
SCRATCH=$(make_scratch_with_config false)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$( cd "$SCRATCH" && PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/gh-calls.log" \
  env -u GH_TOKEN -u PR_NUMBER -u REPO "$SCRIPT" 2>&1 )
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! grep -q "^gh" "$WORKDIR/gh-calls.log"; then
  pass "disabled gate + no env → exit 0 clean pass (no PR_NUMBER/GH_TOKEN error, no gh calls)"
else
  fail "expected rc=0 + 'unresolved: 0' + no gh calls; got rc=$RC, output:"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Control: gate ENABLED + no env → still errors (env required once enabled).
echo "--- Test 1c (control): gate enabled + no PR_NUMBER → exit 2"
SCRATCH=$(make_scratch_with_config true)
set +e
OUT=$( cd "$SCRATCH" && PATH="$STUB_DIR:$PATH" \
  env -u GH_TOKEN -u PR_NUMBER -u REPO "$SCRIPT" 2>&1 )
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -q "PR_NUMBER required"; then
  pass "control: enabled gate + no env → exit 2 (env still required when enabled)"
else
  fail "control: expected rc=2 + 'PR_NUMBER required'; got rc=$RC, output:"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 2: Gate enabled, no findings at all — exit 0.
# ---------------------------------------------------------------------------
echo
echo "--- Test 2: gate enabled, no CodeRabbit findings"
SCRATCH=$(make_scratch_with_config true)
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "no findings → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 3: ⚠️ Major finding (p1, default-required) present and resolved → exit 0.
# ---------------------------------------------------------------------------
echo
echo "--- Test 3: ⚠️ Major finding present and resolved"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$MAJOR_BODY")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: true, comment_ids: [2001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "⚠️ Major + resolved → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 4: ⚠️ Major finding (p1) present and unresolved → exit 1.
# ---------------------------------------------------------------------------
echo
echo "--- Test 4: ⚠️ Major finding present and unresolved"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$MAJOR_BODY")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [2001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P1\] src/foo.ts:42"; then
  pass "⚠️ Major + unresolved → exit 1 with path listed"
else
  fail "expected rc=1 with 'unresolved: 1' + [P1] path; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 5: finding only on a stale SHA → exit 0 (not on HEAD; out of scope).
# ---------------------------------------------------------------------------
echo
echo "--- Test 5: finding only on a stale SHA"
SCRATCH=$(make_scratch_with_config true)
OLD_SHA="oldsha98765"
FIXTURE_PR=$(make_pr_fixture "newhead12345")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$OLD_SHA" "$MAJOR_BODY")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [2001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "finding on stale SHA → out of scope, exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 6: ⚠️-bodied comment from non-bot author → ignored, exit 0.
# ---------------------------------------------------------------------------
echo
echo "--- Test 6: ⚠️-bodied comment from human → ignored"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$MAJOR_BODY" "nathanjohnpayne")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [2001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "⚠️ body from human → ignored, exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 7: enabled knob absent → default false → exit 0.
# ---------------------------------------------------------------------------
echo
echo "--- Test 7: severity_gate block absent → defaults to disabled"
SCRATCH=$(make_scratch_with_config absent)
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "missing severity_gate block → defaults to disabled → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
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
# Test 9 (#592): >100 review threads — the ⚠️ Major finding is on threads
# PAGE 2 and UNRESOLVED. v1 hard-errored (exit 2) on hasNextPage; the
# paginating gate fetches page 2 and blocks (exit 1). Page 1 holds an unrelated
# resolved thread (comment 9001); page 2 (cursor CUR1) holds comment 2001.
# ---------------------------------------------------------------------------
echo
echo "--- Test 9 (#592): >100 review threads → page 2 finding paginated, unresolved → exit 1"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$MAJOR_BODY")
FIXTURE_THREADS_null=$(make_threads_fixture \
  '[{isResolved: true, comment_ids: [9001]}]' "" true "" CUR1)
FIXTURE_THREADS_CUR1=$(make_threads_fixture \
  '[{isResolved: false, comment_ids: [2001]}]')
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
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "src/foo.ts:42"; then
  pass ">100 threads → page 2 paginated, unresolved → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' + path (page-2 pagination); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 9b (#592): a thread with >100 comments — the blocking comment id sits on
# comments PAGE 2. v1 hard-errored (exit 2) on the nested overflow (the #590
# gap nathanpayne-codex flagged as P1); the paginating gate fetches nested page
# 2, finds id 2001, and (thread unresolved) blocks (exit 1). Comments page 1
# carries an unrelated id (5555) + hasNextPage=true + endCursor CCUR1.
# ---------------------------------------------------------------------------
echo
echo "--- Test 9b (#592): blocking comment on nested comments page 2 → caught → exit 1"
SCRATCH=$(make_scratch_with_config true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$MAJOR_BODY")
FIXTURE_THREADS_null=$(make_threads_fixture \
  '[{id: "TX", isResolved: false, comment_ids: [5555], comments_has_next: true, comments_end_cursor: "CCUR1"}]')
FIXTURE_TCOMMENTS_TX_CCUR1=$(make_thread_comments_fixture '[2001]')
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
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "src/foo.ts:42"; then
  pass ">100 comments → nested page 2 paginated, id caught, unresolved → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' + path (nested pagination); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 10: PR_NUMBER + REPO via env (no positional args).
# ---------------------------------------------------------------------------
echo
echo "--- Test 10: PR_NUMBER + REPO via env"
SCRATCH=$(make_scratch_with_config true)
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "env-only PR_NUMBER + REPO → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# Tier-aware cases — the gate enforces the resolved tier SET.
# ===========================================================================
DEFAULT_POLICY="$(cat <<'EOF'
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: discretionary
    nitpick: discretionary
EOF
)"

# ---------------------------------------------------------------------------
# Test 11: by-priority p0+p1 required → unresolved 🧹 Nitpick (nitpick tier)
#          does NOT block (nitpick ∉ {p0,p1}) → exit 0.
# ---------------------------------------------------------------------------
echo
echo "--- Test 11: nitpick discretionary → unresolved 🧹 Nitpick does NOT block"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$NITPICK_BODY")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [2001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "nitpick discretionary → unresolved 🧹 Nitpick out of scope → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' (nitpick ∉ {p0,p1}); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 12: by-priority + nitpick required → unresolved 🧹 Nitpick blocks → exit 1.
# ---------------------------------------------------------------------------
echo
echo "--- Test 12: nitpick required → unresolved 🧹 Nitpick blocks"
SCRATCH=$(make_scratch_with_policy "$(cat <<'EOF'
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: discretionary
    nitpick: required
EOF
)")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$NITPICK_BODY")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [2001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[NITPICK\] src/foo.ts:42"; then
  pass "nitpick required → unresolved 🧹 Nitpick → exit 1, listed as [NITPICK]"
else
  fail "expected rc=1 with 'unresolved: 1' + [NITPICK] path; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 13: by-priority p0+p1 required → unresolved ⚠️ Potential issue (p1)
# blocks. CodeRabbit tops out at p1: coderabbit_tier_of maps its ⚠️ Potential
# issue marker to p1 regardless of a "Critical"/"Security" WORD in the body
# (the badge-only classifier ignores bare prose — see #581 Phase 4b). p1 is in
# the default required set, so the finding blocks, listed as [P1].
# ---------------------------------------------------------------------------
echo
echo "--- Test 13: p1 required → unresolved ⚠️ Potential issue blocks"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$CRITICAL_BODY")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [2001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P1\] src/foo.ts:42"; then
  pass "p1 required → unresolved ⚠️ Potential issue → exit 1, listed as [P1]"
else
  fail "expected rc=1 with 'unresolved: 1' + [P1] path; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 14: by-priority p0+p1 required → unresolved Refactor suggestion (p2)
#          does NOT block → exit 0.
# ---------------------------------------------------------------------------
echo
echo "--- Test 14: p2 discretionary → unresolved Refactor suggestion does NOT block"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_single_comment_fixture "$HEAD_SHA" "$REFACTOR_BODY")
FIXTURE_THREADS=$(make_threads_fixture '[{isResolved: false, comment_ids: [2001]}]')
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "p2 discretionary → unresolved Refactor suggestion out of scope → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' (p2 ∉ {p0,p1}); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# nitpick-under-chill no-op warning (#577). Advisory only — it never changes
# the gate result; it just flags that `nitpick: required` is a silent no-op
# when .coderabbit.yml runs the (nitpick-suppressing) chill profile.
# ===========================================================================
NITPICK_REQUIRED_POLICY="$(cat <<'EOF'
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: discretionary
    p3: discretionary
    nitpick: required
EOF
)"

# Write a .coderabbit.yml with a given reviews.profile into a scratch dir.
write_coderabbit_yml() {
  local dir=$1 profile=$2
  cat >"$dir/.coderabbit.yml" <<EOF
reviews:
  profile: $profile
EOF
}

# ---------------------------------------------------------------------------
# Test 15: nitpick required + reviews.profile: chill → no-op WARNING emitted.
#          The finding here is a p1 Major (so the gate still exits 0/clean on
#          a resolved thread) — we assert only on the warning, independent of
#          the gate verdict.
# ---------------------------------------------------------------------------
echo
echo "--- Test 15: nitpick required + profile chill → no-op warning"
SCRATCH=$(make_scratch_with_policy "$NITPICK_REQUIRED_POLICY")
write_coderabbit_yml "$SCRATCH" "chill"
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -qi "nitpick.*required.*chill\|chill profile suppresses"; then
  pass "nitpick required + chill → warning emitted (gate still exits 0)"
else
  fail "expected rc=0 + a nitpick/chill no-op warning; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 16: nitpick required + reviews.profile: assertive → NO warning.
# ---------------------------------------------------------------------------
echo
echo "--- Test 16: nitpick required + profile assertive → no warning"
SCRATCH=$(make_scratch_with_policy "$NITPICK_REQUIRED_POLICY")
write_coderabbit_yml "$SCRATCH" "assertive"
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
if [ "$RC" = 0 ] && ! echo "$OUT" | grep -qi "chill profile suppresses"; then
  pass "nitpick required + assertive → no no-op warning"
else
  fail "expected rc=0 with NO nitpick/chill warning; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 17: nitpick discretionary (default) + chill → NO warning (the claim
#          is only made when nitpick is required).
# ---------------------------------------------------------------------------
echo
echo "--- Test 17: nitpick discretionary + profile chill → no warning"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
write_coderabbit_yml "$SCRATCH" "chill"
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
if [ "$RC" = 0 ] && ! echo "$OUT" | grep -qi "chill profile suppresses"; then
  pass "nitpick discretionary + chill → no warning (claim not made)"
else
  fail "expected rc=0 with NO nitpick/chill warning; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
echo
echo "============================================"
echo "test_coderabbit_severity_gate.sh: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
