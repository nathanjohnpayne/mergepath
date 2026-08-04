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
# PR-level SUMMARY surface (#832 — `issues/{pr}/comments`, no review thread):
#   18. blocking finding carried ONLY by the head-pinned summary → exit 1.
#   19. summary-only 🧹 Nitpick under a discretionary policy → exit 0;
#       19b flips nitpick to required and the same summary gates.
#   20. summary whose commits-range END is a stale sha → out of scope, exit 0;
#       20b the head as the range START (force-push shape) → exit 0.
#   21. head-pinned summary carrying a rate-limit stanza → not a completed
#       report → exit 0.
#   22. ⚠️ present only inside the pre-merge check table → stripped → exit 0.
#   23. summary-shaped comment authored by a human → ignored → exit 0.
#   24a. the printed ack token carries the head AND a finding-set fingerprint;
#   24. collaborator ack naming THIS head → exit 0.
#   25. ack naming a different sha → still gates → exit 1.
#   26. ack from a non-collaborator → still gates → exit 1.
#   27. ack from a `[bot]` account → still gates → exit 1.
#   28. unreadable `issues/{pr}/comments` → FAIL CLOSED → exit 2.
#   29. inline + summary findings both counted; 29b resolving the inline
#       thread leaves exactly the summary one (inline behavior unchanged).
#
# Ack scoping (#886 — an ack clears the findings it acknowledged, nothing else):
#   30. ack for finding set {A} vs a same-head re-review that rewrote the
#       summary to {A, B} → still gates; 30b acking the NEW token clears it.
#   31. a collaborator quoting the gate's own failure output → not an ack;
#       31b the invariant behind it — the token is never printed at column 0.
#   32. a valid token mentioned mid-line ("lgtm <token>") → not an ack.
#   33. an ack posted BEFORE the summary it would clear → still gates.
#
# Codex round 1 on #886 (two false clears the ack fix above left open):
#   34. a same-head re-review swapping finding A for B under a byte-identical
#       `⚠️ Potential issue` header → A's ack must not clear B; 34b acking the
#       token printed for B still clears it (no deadlock).
#   35. a summary that QUOTES a stanza marker inside a fence is still a
#       completed report — PR-controlled text must not suppress it; 35b a
#       GENUINE column-0 stanza still does suppress it (the narrowing did not
#       fail open); 35c benign stanzas with `end of` closers still classify.
#
# Codex round 2 on #886:
#   36. a CodeRabbit chat reply QUOTING the summarize marker does not displace
#       the real summary (selection is `startswith`, not `contains`).
#   37. tightening the resolved required-tier set invalidates an earlier ack
#       (the fingerprint is salted with that set).
#   38. a bare ack token with no rationale under it is not an ack.
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
    repos/*/issues/*/comments)
      # #832: the PR-level summary surface. FIXTURE_ISSUE_COMMENTS_FAIL
      # simulates an unreadable endpoint so the fail-closed path is testable.
      if [ -n "${FIXTURE_ISSUE_COMMENTS_FAIL:-}" ]; then
        echo "gh: HTTP 502 Bad Gateway (issues/comments)" >&2
        exit 1
      fi
      cat "${FIXTURE_ISSUE_COMMENTS:-/dev/null}"
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

# ===========================================================================
# PR-level SUMMARY surface (#832). CodeRabbit can carry a blocking finding
# solely in its PR-level summary comment (`issues/{pr}/comments`), which has no
# inline anchor and therefore no review thread. Before #832 this required gate
# read only `pulls/{pr}/comments`, so such a finding never gated.
#
# Every case below drives the gate through the SAME shared coderabbit_tier_of
# the inline path uses — there is no second classifier to test.
# ===========================================================================

SUMMARY_MARKER_LINE='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->'
RATE_LIMIT_STANZA='<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->'
PREV_SHA='0000111122223333444455556666777788889999'

# Compose a CodeRabbit PR-level summary body.
#   $1 = sha to name as the commits-range END (the head the summary reports on)
#   $2 = findings text spliced into the walkthrough
#   $3 = extra stanza marker (optional — makes the body non-benign)
#
# The summarize marker leads the body and the extra stanza follows it, which is
# how CodeRabbit actually writes one: on a rate-limited PR the first two lines
# are the summarize marker and then the rate-limit marker (verified against a
# live mergepath body). The fixture used to PREPEND the extra stanza, which no
# real body does, and the gate's `contains` selection could not tell the
# difference. Once selection moved to `startswith` (Codex P1 round 2 on #886)
# the unrealistic ordering stopped being selected at all — so this ordering is
# load-bearing for tests 21 and 35b, not cosmetic.
make_summary_body() {
  local head=$1 findings=$2 extra=${3:-}
  {
    printf '%s\n' "$SUMMARY_MARKER_LINE"
    if [ -n "$extra" ]; then
      printf '%s\n\n' "$extra"
    else
      printf '\n'
    fi
    printf '%s\n\n' '## Walkthrough'
    printf '%s\n\n' 'Refactors the widget loader and its retry path.'
    printf '%s\n\n' "$findings"
    printf '%s\n' '<details>'
    printf '%s\n\n' '<summary>📥 Commits</summary>'
    printf 'Reviewing files that changed from the base of the PR and between %s and %s\n' \
      "$PREV_SHA" "$head"
    printf '%s\n' '</details>'
  }
}

SUMMARY_BLOCKING_FINDING='_⚠️ Potential issue_ | _🟠 Major_: the retry loop never terminates on a 5xx.'
SUMMARY_NITPICK_FINDING='_🧹 Nitpick_: rename the temp variable to something less generic.'

make_issue_comments_fixture() {
  local content=$1
  local file="$WORKDIR/issuecomments.$$.$RANDOM.json"
  echo "$content" > "$file"
  echo "$file"
}

# One CodeRabbit summary comment (id 7001), optionally followed by an ack
# comment (id 7002).
#   $1 = summary body
#   $2 = summary author login (default: the bot)
#   $3 = ack body (optional)
#   $4 = ack author login
#   $5 = ack author_association
make_summary_issue_comments() {
  local body=$1 login=${2:-coderabbitai[bot]}
  local ack_body=${3:-} ack_login=${4:-} ack_assoc=${5:-}
  make_issue_comments_fixture "$(jq -n \
    --arg body "$body" --arg login "$login" \
    --arg ab "$ack_body" --arg al "$ack_login" --arg aa "$ack_assoc" '
    [ { id: 7001, user: { login: $login }, author_association: "NONE", body: $body } ]
    + (if $ab == "" then []
       else [ { id: 7002, user: { login: $al }, author_association: $aa, body: $ab } ]
       end)
  ')"
}

# ---------------------------------------------------------------------------
# Test 18 (#832): a blocking-tier finding carried ONLY by the head-pinned
# PR-level summary — zero inline comments — gates. This is the bug the issue
# filed: before the fix the gate exited 0 here.
# ---------------------------------------------------------------------------
echo
echo "--- Test 18 (#832): summary-only blocking finding → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_THREADS=$(make_threads_fixture '[]')
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING")")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P1\] (PR-level summary comment)" \
    && echo "$OUT" | grep -q "mergepath-summary-ack: $HEAD_SHA" \
    && ! echo "$OUT" | grep -q "Resolve each inline thread"; then
  # The negative conjunct is the CodeRabbit finding on #886: with no inline
  # finding there is no thread to resolve, and printing an instruction the
  # reader cannot act on is worse than printing nothing. Test 29 covers the
  # other direction — with an inline finding present, it must still print.
  pass "summary-only blocking finding → exit 1, listed + ack token, no inline instruction"
else
  fail "expected rc=1 with 'unresolved: 1' + summary path + ack token + no inline instruction; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 19 (#832): a summary-only NON-blocking finding (🧹 Nitpick, discretionary
# under the default policy) does NOT gate. The blocking set is the resolved
# tier set, not "any marker" — the same rule the inline path follows.
# ---------------------------------------------------------------------------
echo
echo "--- Test 19 (#832): summary-only nitpick (discretionary) → exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_THREADS=$(make_threads_fixture '[]')
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_NITPICK_FINDING")")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "summary-only nitpick under a discretionary policy → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Control for test 19: flip nitpick to required and the SAME summary gates —
# proving the non-gating above is the tier decision, not a dead summary path.
echo "--- Test 19b (control): same summary + nitpick required → exit 1"
SCRATCH=$(make_scratch_with_policy "$NITPICK_REQUIRED_POLICY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "\[NITPICK\] (PR-level summary comment)"; then
  pass "control: nitpick required → the same summary finding gates → exit 1"
else
  fail "control: expected rc=1 + [NITPICK] summary listing; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 20 (#832): the summary reports on a DIFFERENT head — its commits-range
# end is a stale sha. Head-pinned selection drops it. Note what is NOT used to
# decide this: no timestamp, no freshness floor. The comment is the newest thing
# on the PR and still out of scope, because scope is the sha CodeRabbit wrote.
# ---------------------------------------------------------------------------
echo
echo "--- Test 20 (#832): summary names a stale head → out of scope, exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_THREADS=$(make_threads_fixture '[]')
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "deadbeef1234" "$SUMMARY_BLOCKING_FINDING")")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && echo "$OUT" | grep -q "does not name $HEAD_SHA"; then
  pass "summary pinned to another head → out of scope, exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' + a head-pin log line; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Test 20b: the head appears in the summary, but as the range START (the
# PREVIOUSLY-reviewed head — the shape a force-push back to an old head
# produces). Position matters: a token-anywhere match would gate here.
echo "--- Test 20b (#832): head is the range START, not the END → exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
STALE_START_SUMMARY="$(printf '%s\n\n%s\n\n%s\n' \
  "$SUMMARY_MARKER_LINE" "$SUMMARY_BLOCKING_FINDING" \
  "Reviewing files that changed from the base of the PR and between $HEAD_SHA and deadbeef1234")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$STALE_START_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "head as range START (not END) → out of scope, exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' (range END is the anchor); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 21 (#832): the summary names this head AND carries a blocking marker,
# but also carries a non-benign outcome stanza (rate limited). The commits
# range describes whatever run last touched the comment, including runs that
# produced no review — so this is not a completed report and its walkthrough
# text is the PREVIOUS round's. Allow-list of benign stanzas, not a deny-list.
# ---------------------------------------------------------------------------
echo
echo "--- Test 21 (#832): head-pinned summary with a rate-limit stanza → not a report, exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING" "$RATE_LIMIT_STANZA")")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && echo "$OUT" | grep -qi "non-benign outcome stanza"; then
  pass "non-benign stanza → not a completed report, exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' + a non-benign-stanza log line; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 22 (#832): the ONLY ⚠️ in the summary is a pre-merge check-table warning
# row (a docstring-coverage grade, not a code finding). It must be stripped
# before classification, or every PR with a low docstring score gates.
# ---------------------------------------------------------------------------
echo
echo "--- Test 22 (#832): ⚠️ only inside the pre-merge check table → exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
PRE_MERGE_ONLY="$(printf '%s\n%s\n%s\n' \
  '<!-- pre_merge_checks_walkthrough_start -->' \
  '| Docstring coverage | ⚠️ Warning | 12.00% is below the 80.00% threshold |' \
  '<!-- pre_merge_checks_walkthrough_end -->')"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$PRE_MERGE_ONLY")")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "pre-merge check-table ⚠️ stripped → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' (check-table row is not a finding); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 23 (#832): a summary comment carrying the marker but authored by a
# HUMAN is not CodeRabbit's summary — quoting the bot must not gate.
# ---------------------------------------------------------------------------
echo
echo "--- Test 23 (#832): summary-shaped comment from a human → ignored, exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING")" "nathanjohnpayne")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "human-authored summary-shaped comment → ignored, exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' (must be bot-authored); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# The acknowledgement channel — the resolution path a summary-only finding
# has instead of "Resolve conversation" (#832 acceptance criterion 3).
# ===========================================================================
GATING_SUMMARY_BODY="$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING")"

# The token is pinned to the finding SET as well as the head, so the tests
# derive it the way a collaborator does — by reading it out of the gate's own
# failure output — rather than recomputing the fingerprint independently. That
# also makes the printed token's usability part of the assertion: if the gate
# ever printed a token its own matcher rejects, the ack channel would be a
# permanent deadlock and test 24 would fail.
# `|| true`: under `set -e` a no-match grep inside a command substitution kills
# the whole suite mid-run, which reports a regression as a truncated log rather
# than as the assertion that failed. An empty token fails its assertion loudly.
extract_ack_token() {
  printf '%s\n' "$1" | grep -o '\[mergepath-summary-ack: [^]]*\]' | head -1 || true
}

SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY")
set +e
ACK_PROBE_OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
set -e
ACK_TOKEN=$(extract_ack_token "$ACK_PROBE_OUT")
ACK_FINGERPRINT=$(printf '%s' "$ACK_TOKEN" | awk '{print $3}' | tr -d ']')

echo
echo "--- Test 24a (#886): the gate prints a head + finding-set pinned token"
if printf '%s' "$ACK_TOKEN" | grep -q "^\[mergepath-summary-ack: $HEAD_SHA [0-9a-f]\{12\}\]$"; then
  pass "printed ack token carries the head AND a finding-set fingerprint"
else
  fail "expected '[mergepath-summary-ack: $HEAD_SHA <12 hex>]'; got '$ACK_TOKEN'"
  echo "$ACK_PROBE_OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 24 (#832): a collaborator ack naming THIS head clears the finding. The
# token leads the comment; the rationale sits underneath it (#886).
# ---------------------------------------------------------------------------
echo
echo "--- Test 24 (#832): collaborator ack for this head → exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY" \
  "coderabbitai[bot]" \
  "$ACK_TOKEN

Rebutted: the retry loop is bounded by the caller." \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && echo "$OUT" | grep -qi "acknowledged for $HEAD_SHA"; then
  pass "collaborator ack pinned to this head → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' + an ack log line; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 25 (#832): an ack naming a DIFFERENT sha does not clear this head. This
# is what makes the ack per-head rather than per-PR: a push invalidates it.
# ---------------------------------------------------------------------------
echo
echo "--- Test 25 (#832): ack naming another sha → still gates, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY" \
  "coderabbitai[bot]" \
  "[mergepath-summary-ack: deadbeef1234 $ACK_FINGERPRINT]

Rebutted on the previous head." \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "ack for a different sha → still gates, exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' (ack is head-pinned); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 26 (#832): an ack from a non-collaborator does not clear the gate.
# `author_association` is GitHub-computed, so a drive-by commenter on a public
# PR cannot self-serve a required check.
# ---------------------------------------------------------------------------
echo
echo "--- Test 26 (#832): ack from a non-collaborator → still gates, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY" \
  "coderabbitai[bot]" \
  "$ACK_TOKEN

lgtm" \
  "some-drive-by" "NONE")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "ack from a non-collaborator → still gates, exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' (association must be OWNER/MEMBER/COLLABORATOR); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 27 (#832): an ack from a `[bot]` account with a collaborator
# association does not clear the gate either — a workflow must not be able to
# auto-ack its own PR past a required check.
# ---------------------------------------------------------------------------
echo
echo "--- Test 27 (#832): ack from a bot account → still gates, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY" \
  "coderabbitai[bot]" \
  "$ACK_TOKEN

auto-ack" \
  "github-actions[bot]" "COLLABORATOR")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "ack from a [bot] account → still gates, exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' (bot accounts cannot ack); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 28 (#832): the issues endpoint is unreadable → FAIL CLOSED (exit 2).
# A required gate must never read an API failure as "no findings". Asserted on
# a PR whose inline surface is clean, so the only thing that can produce a
# nonzero exit is the failed read itself.
# ---------------------------------------------------------------------------
echo
echo "--- Test 28 (#832): unreadable issues endpoint → fail closed, exit 2"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS_FAIL=1 \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "failed to fetch PR-level issue comments"; then
  pass "unreadable issues endpoint → exit 2 (fail closed)"
else
  fail "expected rc=2 + a fetch-failure message; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 29 (#832): the inline path is unchanged when a summary is also present.
# An inline blocking finding on an UNRESOLVED thread plus a summary-only
# blocking finding count as TWO, and resolving the inline thread leaves exactly
# the summary one. Guards against the summary read displacing (or being
# displaced by) the inline read.
# ---------------------------------------------------------------------------
echo
echo "--- Test 29 (#832): inline + summary findings both counted"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_COMMENTS_INLINE=$(make_single_comment_fixture "$HEAD_SHA" "$MAJOR_BODY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS_INLINE" \
  FIXTURE_THREADS="$(make_threads_fixture '[{isResolved: false, comment_ids: [2001]}]')" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 2" \
    && echo "$OUT" | grep -q "\[P1\] src/foo.ts:42" \
    && echo "$OUT" | grep -q "\[P1\] (PR-level summary comment)"; then
  pass "inline unresolved + summary-only → 2 findings, both listed"
else
  fail "expected rc=1 with 'unresolved: 2' + both listings; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo "--- Test 29b (#832): inline thread RESOLVED leaves only the summary finding"
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS_INLINE" \
  FIXTURE_THREADS="$(make_threads_fixture '[{isResolved: true, comment_ids: [2001]}]')" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P1\] (PR-level summary comment)" \
    && ! echo "$OUT" | grep -q "src/foo.ts:42"; then
  pass "resolved inline thread drops out; the summary finding remains → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' + summary listing only; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# Ack scoping (#886). Two ways a head-pinned substring ack cleared findings it
# never acknowledged. Both are demonstrated against the SAME gating summary the
# tests above use, so a regression shows up as a false CLEAR, not a false block.
# ===========================================================================

# A second blocking finding, as a same-head re-review would add it. The summary
# comment keeps id 7001: `@coderabbitai review` / `resume` / the rate-limit
# `try again` retry rewrite the summary for the UNCHANGED head, so neither the
# head sha nor the comment id moves — only the content does.
SUMMARY_SECOND_FINDING='_⚠️ Potential issue_ | _🟠 Major_: the credential is logged in the failure branch.'
REREVIEWED_SUMMARY_BODY="$(make_summary_body "$HEAD_SHA" \
  "$SUMMARY_BLOCKING_FINDING
$SUMMARY_SECOND_FINDING")"

# ---------------------------------------------------------------------------
# Test 30 (#886): an ack written against finding set {A} does NOT clear a
# summary that has since been rewritten, on the same head, to {A, B}. Before
# the fix the ack cleared every summary finding on the head unconditionally —
# including one published after it — and the gate exited 0 here.
# ---------------------------------------------------------------------------
echo
echo "--- Test 30 (#886): ack for set {A} vs re-review adding B → still gates, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$REREVIEWED_SUMMARY_BODY" \
  "coderabbitai[bot]" \
  "$ACK_TOKEN

Rebutted: the retry loop is bounded by the caller." \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 2" \
    && echo "$OUT" | grep -q "credential is logged"; then
  pass "stale-finding-set ack does not clear a rewritten summary → exit 1"
else
  fail "expected rc=1 with 'unresolved: 2' + the new finding listed; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 30b (#886): the escape hatch still exists — acking the token the gate
# prints for the NEW finding set clears it. Without this, finding-pinning would
# have traded a false clear for a permanent deadlock (`enforce_admins: true`
# leaves no break-glass), which is the reason the ack channel exists at all.
# ---------------------------------------------------------------------------
echo
echo "--- Test 30b (#886): ack for the NEW finding set → exit 0"
NEW_ACK_TOKEN=$(extract_ack_token "$OUT")
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$REREVIEWED_SUMMARY_BODY" \
  "coderabbitai[bot]" \
  "$NEW_ACK_TOKEN

Both rebutted." \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && [ "$NEW_ACK_TOKEN" != "$ACK_TOKEN" ]; then
  pass "ack regenerated for the new finding set clears it → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' and a token distinct from the {A} one; got rc=$RC token='$NEW_ACK_TOKEN'"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 31 (#886): a collaborator who pastes the gate's own failure output into
# a PR comment while triaging the red check does not thereby clear it. The gate
# prints the token verbatim, so a substring match made routine triage behaviour
# into a silent bypass of a required check.
# ---------------------------------------------------------------------------
echo
echo "--- Test 31 (#886): collaborator quoting the gate's failure output → still gates, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY" \
  "coderabbitai[bot]" \
  "The severity gate is red on this PR — what is it asking for?

$ACK_PROBE_OUT

Can someone take a look?" \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "quoted failure output does not ack → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' (a quote is not an ack); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 31b (#886): the invariant test 31 rests on — the gate never renders the
# token at column 0. That is what makes "a verbatim paste of ANY contiguous
# region of this output cannot ack" true rather than merely likely: unindent
# the token in the report and a paste starting at that line would ack.
# ---------------------------------------------------------------------------
echo
echo "--- Test 31b (#886): the printed token is never at column 0"
if printf '%s\n' "$ACK_PROBE_OUT" | grep -q "mergepath-summary-ack" \
    && ! printf '%s\n' "$ACK_PROBE_OUT" | grep -q "^\[mergepath-summary-ack:"; then
  pass "gate output renders the ack token indented, never leading a line"
else
  fail "the gate must print the ack token, and must never print it at column 0"
  echo "$ACK_PROBE_OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 32 (#886): a valid token that does not LEAD the comment is not an ack.
# The one-line "lgtm [token]" shape is what a substring matcher accepted; it is
# also the shape any incidental mention takes.
# ---------------------------------------------------------------------------
echo
echo "--- Test 32 (#886): token mentioned mid-line → not an ack, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY" \
  "coderabbitai[bot]" \
  "lgtm $ACK_TOKEN" \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "token not leading the comment → not an ack, exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' (the token must lead the comment); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 33 (#886): an ack that PRECEDES the summary it would clear (lower
# comment id) is still rejected once the finding set differs — the demonstrated
# shape, where the ack was written before the finding even existed.
# ---------------------------------------------------------------------------
echo
echo "--- Test 33 (#886): ack posted BEFORE the summary it would clear → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_issue_comments_fixture "$(jq -n \
  --arg body "$REREVIEWED_SUMMARY_BODY" --arg tok "$ACK_TOKEN" '
  [ { id: 6999, user: { login: "nathanjohnpayne" }, author_association: "OWNER",
      body: ($tok + "\n\nPre-emptively acked.") },
    { id: 7001, user: { login: "coderabbitai[bot]" }, author_association: "NONE",
      body: $body } ]
')")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 2"; then
  pass "ack predating the finding set it would clear → exit 1"
else
  fail "expected rc=1 with 'unresolved: 2'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# Codex P1 round 1 on #886. Two holes the round-2 ack fix left open, each a
# false CLEAR of this required gate. Both fixtures deliberately use CodeRabbit's
# REAL body shapes rather than the single-line convenience shapes above — that
# difference is the whole finding in the first case.
# ===========================================================================

# CodeRabbit writes a summary finding as a marker line ON ITS OWN, with the
# finding text on the lines BELOW it (see the split header/body fixtures in
# tests/test_coderabbit_wait_status_probe.sh). Only the marker line classifies,
# so fingerprinting the classified lines alone hashed a constant: A and B below
# share a byte-identical first line and differ only underneath it.
SUMMARY_SPLIT_FINDING_A='_⚠️ Potential issue_

**Unbounded retry loop**

The retry loop never terminates on a 5xx response.'
SUMMARY_SPLIT_FINDING_B='_⚠️ Potential issue_

**Credential written to the log**

The failure branch logs the bearer token in full.'

SPLIT_SUMMARY_A="$(make_summary_body "$HEAD_SHA" "$SUMMARY_SPLIT_FINDING_A")"
SPLIT_SUMMARY_B="$(make_summary_body "$HEAD_SHA" "$SUMMARY_SPLIT_FINDING_B")"

# The token a collaborator would have copied while finding A was on screen.
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$SPLIT_SUMMARY_A")
set +e
SPLIT_PROBE_OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
set -e
SPLIT_ACK_TOKEN_A=$(extract_ack_token "$SPLIT_PROBE_OUT")

# ---------------------------------------------------------------------------
# Test 34 (#886, Codex P1): a same-head re-review that REPLACES finding A with
# a different finding B, keeping the `_⚠️ Potential issue_` header byte-
# identical, must invalidate A's ack. Pre-fix the fingerprint covered only the
# header line, so both summaries produced the same token and A's ack cleared B
# — an undispositioned blocking finding passing a required gate.
# ---------------------------------------------------------------------------
echo
echo "--- Test 34 (#886): ack for finding A vs same-header finding B → still gates, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$SPLIT_SUMMARY_B" \
  "coderabbitai[bot]" \
  "$SPLIT_ACK_TOKEN_A

Rebutted: the retry loop is bounded by the caller." \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
SPLIT_ACK_TOKEN_B=$(extract_ack_token "$OUT")
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && [ -n "$SPLIT_ACK_TOKEN_A" ] && [ "$SPLIT_ACK_TOKEN_A" != "$SPLIT_ACK_TOKEN_B" ]; then
  pass "same-header finding swap changes the token; A's ack does not clear B → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' and A/B tokens differing; got rc=$RC A='$SPLIT_ACK_TOKEN_A' B='$SPLIT_ACK_TOKEN_B'"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 34b (#886, Codex P1): the escape hatch survives the tightening — acking
# the token printed for B clears B. Finding-pinning must not trade a false
# clear for a permanent deadlock, since `enforce_admins: true` leaves no
# break-glass.
# ---------------------------------------------------------------------------
echo
echo "--- Test 34b (#886): ack regenerated for finding B → exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$SPLIT_SUMMARY_B" \
  "coderabbitai[bot]" \
  "$SPLIT_ACK_TOKEN_B

Deferred to a follow-up issue." \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "ack regenerated for the replacement finding clears it → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 35 (#886, Codex P1): PR-CONTROLLED text must not decide whether a
# summary is a completed report. CodeRabbit quotes changed code, and this very
# PR's fixtures contain the rate-limit stanza as source text. Pre-fix the
# whole-body substring count read that echo as a non-benign outcome stanza,
# discarded an otherwise-complete current-head summary, and exited 0 with a
# real blocking finding in it.
# ---------------------------------------------------------------------------
echo
echo "--- Test 35 (#886): echoed rate-limit stanza inside a fence → still a report, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
ECHOED_STANZA_SUMMARY="$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING

The diff adds this fixture line:

\`\`\`
<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->
\`\`\`
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$ECHOED_STANZA_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "author-controlled echo of a stanza marker does not suppress the summary → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 35b (#886, Codex P1): the narrowing above must not fail open. A GENUINE
# rate-limit stanza — CodeRabbit's own, at column 0 and outside any fence — is
# still a non-benign outcome, so the body is not a completed report and its
# text does not gate.
# ---------------------------------------------------------------------------
echo
echo "--- Test 35b (#886): genuine column-0 rate-limit stanza → not a report, exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING" \
     '<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->')")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && echo "$OUT" | grep -q "non-benign outcome stanza"; then
  pass "a real rate-limit stanza still suppresses the summary → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' and the non-benign log line; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 35c (#886, Codex P1): `end of auto-generated comment:` CLOSERS are not
# openers. Real bodies carry both forms (mergepath#874's summary has three
# openers and two closers), and a benign body that closes its stanzas must
# still read as a completed report. A guard on the counting shape rather than a
# pre-fix failure.
# ---------------------------------------------------------------------------
echo
echo "--- Test 35c (#886): closed benign stanzas still read as a report → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
CLOSED_STANZA_SUMMARY="$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING

<!-- This is an auto-generated comment: release notes by coderabbit.ai -->

Release notes body.

<!-- end of auto-generated comment: release notes by coderabbit.ai -->
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$CLOSED_STANZA_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "benign stanzas with closers still classify as a report → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# Codex P1/P2 round 2 on #886.
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 36 (#886, Codex P1): a CodeRabbit CHAT REPLY that QUOTES the summarize
# marker must not displace the real summary. The reply always has the higher
# comment id, so a `contains` selection picked it, found no structural stanza
# in it, rejected it as "not a completed report", and never looked at the real
# current-head summary — clearing the gate with a blocking finding in it. Live
# shape: fixture 7917/7918 in tests/test_coderabbit_wait_status_probe.sh
# (#794). The waiter has always used `startswith` here; the gate had not.
# ---------------------------------------------------------------------------
echo
echo "--- Test 36 (#886): marker-quoting chat reply does not displace the summary → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_issue_comments_fixture "$(jq -n \
  --arg body "$GATING_SUMMARY_BODY" --arg m "$SUMMARY_MARKER_LINE" '
  [ { id: 7001, user: { login: "coderabbitai[bot]" }, author_association: "NONE",
      body: $body },
    { id: 7002, user: { login: "coderabbitai[bot]" }, author_association: "NONE",
      body: ("🧩 Analysis chain\n\n" + $m + "\n\nQuoted from the summary above while answering a question.") } ]
')")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "a newer marker-quoting reply does not shadow the real summary → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 37 (#886, Codex P1): the ack is bound to the ACTIVE blocking tier set,
# not only to the head and the body. The tier set comes from the trusted
# default-branch policy and can tighten while a PR is open, so an ack written
# when only P1 was blocking must not silently clear a P2 that a later policy
# made blocking — the body, and therefore an unsalted fingerprint, is identical
# across the two policies.
# ---------------------------------------------------------------------------
P2_REQUIRED_POLICY="$(cat <<'EOF'
feedback_policy:
  mode: by-priority
  priorities:
    p0: required
    p1: required
    p2: required
    p3: discretionary
    nitpick: discretionary
EOF
)"
SUMMARY_P2_FINDING='_🛠️ Refactor suggestion_ | _🟡 Minor_: fold the duplicated parse into one helper.'
MIXED_TIER_SUMMARY="$(make_summary_body "$HEAD_SHA" \
  "$SUMMARY_BLOCKING_FINDING
$SUMMARY_P2_FINDING")"

# The token as printed under the {p0,p1} policy, where only the P1 blocks.
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$MIXED_TIER_SUMMARY")
set +e
MIXED_PROBE_OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
set -e
MIXED_ACK_P1_ONLY=$(extract_ack_token "$MIXED_PROBE_OUT")

echo
echo "--- Test 37 (#886): ack predating a policy tightening does not clear the newly-blocking tier"
SCRATCH=$(make_scratch_with_policy "$P2_REQUIRED_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$MIXED_TIER_SUMMARY" \
  "coderabbitai[bot]" \
  "$MIXED_ACK_P1_ONLY

Rebutted under the policy in force when this was written." \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
MIXED_ACK_P2_TOO=$(extract_ack_token "$OUT")
if [ "$RC" = 1 ] && [ -n "$MIXED_ACK_P1_ONLY" ] \
    && [ "$MIXED_ACK_P1_ONLY" != "$MIXED_ACK_P2_TOO" ]; then
  pass "tightening the required tiers invalidates the earlier ack → exit 1"
else
  fail "expected rc=1 and differing tokens; got rc=$RC p1only='$MIXED_ACK_P1_ONLY' p2too='$MIXED_ACK_P2_TOO'"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 38 (#886, Codex P2): the token alone is not an acknowledgement. The spec
# and REVIEW_POLICY both say the rationale goes on the lines below it, so
# accepting a bare token let a required check go green with no recorded
# disposition — the documented contract and the enforced one disagreeing. The
# test is mechanical (at least one non-blank line follows), deliberately not a
# judgement about what counts as substantive.
# ---------------------------------------------------------------------------
echo
echo "--- Test 38 (#886): bare ack token with no rationale → still gates, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY" \
  "coderabbitai[bot]" \
  "$ACK_TOKEN

   " \
  "nathanjohnpayne" "OWNER")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "token with only blank lines under it is not an ack → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# Codex round 4 on #886.
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 39 (#886, Codex P1): the pre-merge-table strip must not be steerable by
# PR-controlled text. It DELETES body text, so a start delimiter quoted by
# CodeRabbit ABOVE the genuine table made the suppressor span from the quote to
# the real table's end — silently removing every blocking finding in between
# and clearing a required gate. Same structural + fence-aware rule as the
# stanza parser, and this is the more dangerous of the two.
# ---------------------------------------------------------------------------
echo
echo "--- Test 39 (#886): quoted pre-merge start delimiter does not swallow a finding → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
QUOTED_DELIM_BODY="$(make_summary_body "$HEAD_SHA" "The diff adds this delimiter as a fixture:

\`\`\`
<!-- pre_merge_checks_walkthrough_start -->
\`\`\`

$SUMMARY_BLOCKING_FINDING

<!-- pre_merge_checks_walkthrough_start -->
| Docstring coverage | ⚠️ Warning | 12.00% is below the 80.00% threshold |
<!-- pre_merge_checks_walkthrough_end -->
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$QUOTED_DELIM_BODY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "a quoted start delimiter does not extend the strip over a real finding → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' (the finding must survive the strip); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 39b (#886, Codex P1): the narrowing must not stop the strip doing its
# job — a genuine table between genuine structural delimiters is still removed,
# so a docstring-coverage ⚠️ row still does not gate. Test 22 covers the plain
# case; this one pins it with a fenced quote of the delimiter also present.
# ---------------------------------------------------------------------------
echo
echo "--- Test 39b (#886): genuine table still stripped alongside a quoted delimiter → exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
QUOTED_PLUS_REAL_TABLE="$(make_summary_body "$HEAD_SHA" "Fixture text quoting the delimiter:

\`\`\`
<!-- pre_merge_checks_walkthrough_start -->
\`\`\`

<!-- pre_merge_checks_walkthrough_start -->
| Docstring coverage | ⚠️ Warning | 12.00% is below the 80.00% threshold |
<!-- pre_merge_checks_walkthrough_end -->
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$QUOTED_PLUS_REAL_TABLE")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "the real pre-merge table is still stripped → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 40 (#886, Codex P2): with every blocking inline thread RESOLVED and only
# a summary finding left, the report must not tell the reader to resolve inline
# threads. `BLOCKING_COUNT` counts pre-resolution candidates, so it is nonzero
# here; the guard has to key on what is actually being reported.
# ---------------------------------------------------------------------------
echo
echo "--- Test 40 (#886): resolved inline + unresolved summary → no inline instruction"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_COMMENTS_R40=$(make_single_comment_fixture "$HEAD_SHA" "$MAJOR_BODY")
FIXTURE_THREADS_R40=$(make_threads_fixture '[{isResolved: true, comment_ids: [2001]}]')
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS_R40" \
  FIXTURE_THREADS="$FIXTURE_THREADS_R40" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "(PR-level summary comment)" \
    && ! echo "$OUT" | grep -q "Resolve each inline thread"; then
  pass "resolved inline candidate does not resurrect the inline instruction → exit 1"
else
  fail "expected rc=1, the summary finding listed, and no inline instruction; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# Codex round 5 on #886. The three structural scans share one CommonMark fence
# reader; these cases drive it through the fence forms the first hand-rolled
# copies did not recognise, and pin the commits-range scan to unfenced text.
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 41 (#886, Codex P1): a TILDE fence. The earlier fence checks matched only
# a bare three-backtick line, so `~~~` quoted content was read as CodeRabbit's
# own markup — walking straight past the round-1 stanza fix. A quoted column-0
# rate-limit stanza inside a tilde fence must not suppress the summary.
# ---------------------------------------------------------------------------
echo
echo "--- Test 41 (#886): stanza quoted inside a ~~~ fence → still a report, exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
TILDE_FENCE_SUMMARY="$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING

The diff adds this fixture line:

~~~
<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->
~~~
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$TILDE_FENCE_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "a tilde-fenced stanza quote does not suppress the summary → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 41b (#886, Codex P1): a LONGER backtick fence containing a three-backtick
# line. CommonMark closes a fence only on the same character at >= the opening
# run length, so the inner ``` is content, not a closer. A naive toggle would
# reopen the scan mid-block and read the quoted delimiter as real — here that
# would let a quoted pre-merge start delimiter delete a genuine finding.
# ---------------------------------------------------------------------------
echo
echo "--- Test 41b (#886): inner \`\`\` does not close a \`\`\`\`\` fence → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
LONG_FENCE_SUMMARY="$(make_summary_body "$HEAD_SHA" "Quoted fixture, nested fences:

\`\`\`\`\`
\`\`\`
<!-- pre_merge_checks_walkthrough_start -->
\`\`\`
\`\`\`\`\`

$SUMMARY_BLOCKING_FINDING

<!-- pre_merge_checks_walkthrough_start -->
| Docstring coverage | ⚠️ Warning | 12.00% is below the 80.00% threshold |
<!-- pre_merge_checks_walkthrough_end -->
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$LONG_FENCE_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "a longer fence is not closed by a shorter inner one → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 42 (#886, Codex P1): the commits-range scan reads UNFENCED text only. A
# quoted `between X and <head>` string let a stale summary pass as this head's
# report, and both error directions are unsafe on this predicate — so the fix
# is precision, not a fail-direction argument. Here the ONLY occurrence of the
# head is a fenced quote, and the genuine range names a different head, so the
# summary is out of scope and its finding must not gate.
# ---------------------------------------------------------------------------
echo
echo "--- Test 42 (#886): a fenced commits-range quote does not bring a stale summary into scope"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
QUOTED_RANGE_SUMMARY="$(make_summary_body "deadbeefdeadbeef" "$SUMMARY_BLOCKING_FINDING

The diff quotes an older range:

\`\`\`
Reviewing files that changed from the base of the PR and between $PREV_SHA and $HEAD_SHA
\`\`\`
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$QUOTED_RANGE_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && echo "$OUT" | grep -q "does not name $HEAD_SHA as its commits-range end"; then
  pass "a fenced range quote is not CodeRabbit's commits row → out of scope, exit 0"
else
  fail "expected rc=0 with the out-of-scope log line; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 42b (#886): the genuine, unfenced commits row is still found — the
# narrowing above must not push a real report out of scope, which would be a
# false clear of its own.
# ---------------------------------------------------------------------------
echo
echo "--- Test 42b (#886): the genuine unfenced commits row is still in scope → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$GATING_SUMMARY_BODY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "the real commits row still brings the summary into scope → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 43 (#886, Codex P2): with no summary finding, the ack fingerprint is
# never printed or consulted, so an absent hasher must not fail the gate.
# Simulated by running with a PATH that has neither sha256sum nor shasum.
# ---------------------------------------------------------------------------
echo
echo "--- Test 43 (#886): no summary finding + no hasher on PATH → clean exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
NOHASH_BIN="$WORKDIR/nohash.$$"
mkdir -p "$NOHASH_BIN"
for tool in bash sh env awk sed grep jq gh cat cut tr head printf sort wc mkdir rm dirname basename; do
  tp=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$tp" ] && ln -sf "$tp" "$NOHASH_BIN/$tool"
done
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_NITPICK_FINDING")")
set +e
OUT=$(
  PATH="$NOHASH_BIN" \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! echo "$OUT" | grep -q "neither sha256sum nor shasum"; then
  pass "an unused hashing dependency does not redden a clean gate → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0' and no hasher error; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 44 (#886, Codex P1 round 6): a backtick fence opener may not carry a
# backtick in its info string (CommonMark; tilde fences have no such rule).
# Accepting one let an ordinary prose line read as an opener, putting the
# reader into a fence that never legitimately closes — hiding everything after
# it, INCLUDING the genuine commits range, which takes the summary out of scope
# and clears the gate. Note the direction: this one suppresses by opening a
# fence, the mirror image of the round-5 cases which suppressed by closing one.
# ---------------------------------------------------------------------------
echo
echo "--- Test 44 (#886): a backtick line with backticks in its info string is not a fence → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
BAD_OPENER_SUMMARY="$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING

\`\`\`sh with \`inline\` ticks
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$BAD_OPENER_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "an invalid backtick opener does not hide the commits range → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1' (the summary must stay in scope); got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 44b (#886): the restriction is backtick-only. A TILDE opener may carry
# anything in its info string, so a `~~~` fence with backticks after it is
# still a fence and still hides its contents.
# ---------------------------------------------------------------------------
echo
echo "--- Test 44b (#886): a tilde opener may carry backticks in its info string"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
TILDE_INFO_SUMMARY="$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING

~~~sh with \`inline\` ticks
<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->
~~~
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$TILDE_INFO_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "a tilde fence with a backticked info string still fences its contents → exit 1"
else
  fail "expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ===========================================================================
# Phase 4b automated review on #886 (reviewer nathanpayne-codex).
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 45 (#886, Phase 4b P1): the commits-range extraction accepts a 7-to-40
# character range end, so the comparison must be a PREFIX match against the
# 40-character API head. Requiring equality made the tolerated abbreviation
# unmatchable — the two halves of the function contradicted each other, and if
# CodeRabbit ever abbreviates, every summary silently falls out of scope and
# its findings go ungated. (Every real body sampled in this repo writes the
# full 40; the inconsistency is the defect, not the observed data.)
# ---------------------------------------------------------------------------
echo
echo "--- Test 45 (#886): an ABBREVIATED commits-range end still names this head → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
SHORT_HEAD=$(printf '%s' "$HEAD_SHA" | cut -c1-10)
ABBREV_RANGE_SUMMARY="$(make_summary_body "$SHORT_HEAD" "$SUMMARY_BLOCKING_FINDING")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$ABBREV_RANGE_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "an abbreviated range end prefix-matches the full head → in scope, exit 1"
else
  fail "expected rc=1 with 'unresolved: 1'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 45b (#886): prefix matching must not become "any prefix of anything". A
# range end that is NOT a prefix of this head still puts the summary out of
# scope — test 20 covers the plain stale case; this pins that the loosening did
# not swallow it.
# ---------------------------------------------------------------------------
echo
echo "--- Test 45b (#886): an abbreviation of a DIFFERENT sha is still out of scope → exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "fedcba9876" "$SUMMARY_BLOCKING_FINDING")")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "does not name $HEAD_SHA as its commits-range end"; then
  pass "an abbreviation of another sha stays out of scope → exit 0"
else
  fail "expected rc=0 with the out-of-scope log line; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 46 (#886, Phase 4b P2): the finding loop classifies UNFENCED lines only.
# The structural scans already ignored fenced quotes; the classifier did not,
# so a PR whose diff contains a classifier marker as SOURCE TEXT could
# manufacture a blocking summary finding against itself when CodeRabbit quoted
# it back — this repo's own fixtures contain such strings. Closes #893.
# ---------------------------------------------------------------------------
echo
echo "--- Test 46 (#886): a quoted finding marker inside a fence is not a finding → exit 0"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
QUOTED_MARKER_SUMMARY="$(make_summary_body "$HEAD_SHA" "No actionable comments.

The diff adds this fixture line:

\`\`\`
_⚠️ Potential issue_ | _🟠 Major_: the retry loop never terminates on a 5xx.
\`\`\`
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$QUOTED_MARKER_SUMMARY")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "a fenced quote of a finding marker does not manufacture a finding → exit 0"
else
  fail "expected rc=0 with 'unresolved: 0'; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 46b (#886): the narrowing must not lose a genuine finding — an unfenced
# marker still gates, and its reported line number still points at the real
# line in the summary rather than at a position in the filtered stream.
# ---------------------------------------------------------------------------
echo
echo "--- Test 46b (#886): an unfenced marker below a fence still gates, with a true line number"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FENCE_THEN_FINDING="$(make_summary_body "$HEAD_SHA" "Quoted fixture:

\`\`\`
some quoted source line
another quoted source line
\`\`\`

$SUMMARY_BLOCKING_FINDING
")"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$FENCE_THEN_FINDING")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
# The finding sits on line 14 of the composed body. The filtered stream drops
# the fence delimiters and their contents, which would put it at 10. Asserting
# the NUMBER, not just the count, is what pins that original line numbers
# survive the filter — a count-only assertion passes either way.
REPORTED_LINE=$(echo "$OUT" | sed -n 's/.*(PR-level summary comment):\([0-9]*\).*/\1/p' | head -1)
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && [ "${REPORTED_LINE:-0}" -eq 14 ]; then
  pass "an unfenced finding below a fence gates, reported at its true line $REPORTED_LINE"
else
  fail "expected rc=1, 'unresolved: 1' and reported line 14; got rc=$RC line='$REPORTED_LINE'"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
echo
echo "============================================"
echo "test_coderabbit_severity_gate.sh: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
