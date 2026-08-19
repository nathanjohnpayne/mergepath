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
#   47. markerless full-review summary on the PR-comment surface with a fresh
#       exact-head CodeRabbit review object gates; 47b without that object and
#       47c when it predates the object, it remains out of scope.
#   47d. a head-pinned review run whose body matches no acceptor holds the run.
#   47e. stale marker-led and current markerless summaries are both evaluated.
#   47f. the production shape: a terminal head-pinned review OBJECT carrying the
#       markerless summary clears the hold even when the marker-led walkthrough
#       still names an older head (47f2: its findings are classified, not just
#       counted as a candidate).
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
      if grep -q 'PullRequestReviewThread' <<<"$q"; then
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
    # #995: an unset fixture emits `[]`, not an EMPTY body. `gh api` on a list
    # endpoint always prints JSON on success — a zero-byte 200 is a transport
    # fault, and since the #967 ordering fix `fetch_api_array` refuses it as an
    # unreadable read rather than reading it as "no results". Modelling "no
    # fixture" as an empty body made these stubs assert a shape gh never
    # produces, which is the harness being wrong, not the guard.
    repos/*/pulls/*/comments)
      if [ -n "${FIXTURE_COMMENTS:-}" ]; then cat "$FIXTURE_COMMENTS"; else printf '[]\n'; fi
      exit 0
      ;;
    repos/*/pulls/*/reviews)
      if [ -n "${FIXTURE_REVIEWS:-}" ]; then cat "$FIXTURE_REVIEWS"; else printf '[]\n'; fi
      exit 0
      ;;
    repos/*/issues/*/comments)
      # #832: the PR-level summary surface. FIXTURE_ISSUE_COMMENTS_FAIL
      # simulates an unreadable endpoint so the fail-closed path is testable.
      if [ -n "${FIXTURE_ISSUE_COMMENTS_FAIL:-}" ]; then
        echo "gh: HTTP 502 Bad Gateway (issues/comments)" >&2
        exit 1
      fi
      # #1008: `gh api` writes diagnostics to stderr on calls that SUCCEED —
      # deprecation notices, retry/backoff chatter, token-scope warnings.
      # This knob reproduces that so test 28b can assert the read still
      # succeeds. It could not, while this gate's own copy of fetch_api_array
      # captured with `2>&1` and fed the prose to the jq slurp.
      if [ -n "${FIXTURE_ISSUE_COMMENTS_STDERR_NOISE:-}" ]; then
        echo "gh: warning: this endpoint is deprecated and will be removed" >&2
      fi
      # #995: an UNSET fixture emits `[]`, not a zero-byte body. `gh api`
      # never returns an empty 200 for a list endpoint, and since the raw
      # stream is now judged before the flatten (#967/#1006) a zero-byte body
      # is a refusal — so the old `/dev/null` default asserted a shape the
      # platform cannot produce.
      if [ -n "${FIXTURE_ISSUE_COMMENTS:-}" ]; then cat "$FIXTURE_ISSUE_COMMENTS"; else printf '[]\n'; fi
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

# awk shim: transparent, EXCEPT when CR_GATE_TEST_FAIL_SUMMARY_AWK_AFTER=<n> is
# set, in which case the first n runs of `summary_unfenced_numbered`'s program
# — identified by that program's own distinctive emit, `NR, line` — succeed and
# every later one exits nonzero. Mirrors CODERABBIT_TEST_FAIL_ISSUES_AFTER in
# tests/test_coderabbit_wait_statuscontext_ratelimit.sh.
#
# Scoped to that one program, and counted, on purpose. The reader is shared:
# the summary CLASSIFIER (summary_stanza_opener_lines) runs it before the
# summary GRADER does, and a stub that failed every run would drop the summary
# as "not a report" long before the graded pipeline ran — the assertion would
# pass with the fix reverted, proving nothing. The counter lets the classifier
# through and fails only the grading run, which is the call site under test.
# (The classifier's own swallowed-read path is a separate, pre-existing
# fail-open; it is #942, not this case.) The real interpreter is resolved once,
# now, before PATH is shadowed.
REAL_AWK=$(command -v awk)
cat >"$STUB_DIR/awk" <<STUB
#!/bin/bash
if [ -n "\${CR_GATE_TEST_FAIL_SUMMARY_AWK_AFTER:-}" ]; then
  for __a in "\$@"; do
    case "\$__a" in
      *"NR, line"*)
        __c_file="\${CR_GATE_TEST_AWK_COUNTER:-/dev/null}"
        __c=\$(cat "\$__c_file" 2>/dev/null || echo 0)
        __c=\$((__c + 1))
        echo "\$__c" >"\$__c_file" 2>/dev/null || true
        if [ "\$__c" -gt "\$CR_GATE_TEST_FAIL_SUMMARY_AWK_AFTER" ]; then
          exit 9
        fi
        ;;
    esac
  done
fi
if [ -n "\${CR_GATE_TEST_FAIL_AWK_PROGRAM:-}" ]; then
  for __a in "\$@"; do
    case "\$__a" in
      *"\$CR_GATE_TEST_FAIL_AWK_PROGRAM"*)
        echo "awk: fixture failure on the program matching '\$CR_GATE_TEST_FAIL_AWK_PROGRAM'" >&2
        exit 9
        ;;
    esac
  done
fi
exec "$REAL_AWK" "\$@"
STUB
chmod +x "$STUB_DIR/awk"

# The counter knob above is scoped, by design, to summary_unfenced_numbered's
# program alone — matched on that program's own distinctive emit, `NR, line`.
# That scoping is what makes tests 51 and 52 non-vacuous, and it is also what
# makes them STRUCTURALLY incapable of failing the file's three OTHER awk
# programs: the stanza-opener scan, the pre-merge PAIR scan, and the pre-merge
# STRIP. `CR_GATE_TEST_FAIL_AWK_PROGRAM=<substring>` fails one named program
# outright, so a reader that test 52's shim can never reach still gets covered.
#
# `CR_GATE_TEST_GREP_ERROR_ON=<substring>` is the same idea for grep, and it
# tests a status grep can return that awk cannot usefully be made to: rc 2, its
# own ERROR, as distinct from rc 1, no-match. `|| true` absorbs both
# identically, so a grep that died on an invalid multibyte sequence or a bad
# locale — a production cause #942's own body names — read as "this body says
# no". The shim writes to stderr and exits 2, exactly as grep does.
REAL_GREP=$(command -v grep)
cat >"$STUB_DIR/grep" <<STUB
#!/bin/bash
if [ -n "\${CR_GATE_TEST_GREP_ERROR_ON:-}" ]; then
  case "\$*" in
    *"\$CR_GATE_TEST_GREP_ERROR_ON"*)
      echo "grep: invalid byte sequence (fixture failure on '\$CR_GATE_TEST_GREP_ERROR_ON')" >&2
      exit 2
      ;;
  esac
fi
exec "$REAL_GREP" "\$@"
STUB
chmod +x "$STUB_DIR/grep"

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
HEAD_SHA="abc123def456abc123def456abc123def456abcd"
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
# A stale head that is a FULL 40-hex object id. `summary_names_head` extracts
# with `between [0-9a-f]{40} and [0-9a-f]{40}`, so an abbreviated stale sha never
# parses and the summary falls out of scope through the SHORT-SHA path — which
# test 45 already owns — instead of the stale-head or range-POSITION path the
# test using it names (CodeRabbit Major on #886). Anything asserting "a
# different head" or "the head is the range START" has to use this.
STALE_SHA='deadbeef1234deadbeef1234deadbeef1234dead'

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

# Review-object fixture for CodeRabbit's markerless full-review format. Its
# exact `commit_id` is the scope anchor that an ordinary summary body lacks.
# The BODY is load-bearing, not decoration: only a review RUN anchors a summary,
# and a non-empty body is what separates one from the body-less object CodeRabbit
# creates for a conversational thread reply (mergepath#900). A fixture without it
# would be a reply carrier, and every case built on this helper would silently
# stop anchoring.
make_reviews_fixture() {
  local sha=$1 state=${2:-COMMENTED} submitted_at=${3:-2026-08-04T00:00:10Z}
  local body=${4:-**Actionable comments posted: 0**}
  local file="$WORKDIR/reviews.$$.$RANDOM.json"
  jq -n --arg sha "$sha" --arg state "$state" --arg submitted_at "$submitted_at" \
    --arg body "$body" '
    [{
      id: 8001,
      user: { login: "coderabbitai[bot]" },
      commit_id: $sha,
      state: $state,
      submitted_at: $submitted_at,
      body: $body
    }]
  ' > "$file"
  echo "$file"
}

# One CodeRabbit summary comment (id 7001), optionally followed by an ack
# comment (id 7002).
#   $1 = summary body
#   $2 = summary author login (default: the bot)
#   $3 = ack body (optional)
#   $4 = ack author login
#   $5 = ack author_association
#   $6 = summary created_at (default: 2026-08-04T00:00:00Z)
#   $7 = summary updated_at (default: created_at)
make_summary_issue_comments() {
  local body=$1 login=${2:-coderabbitai[bot]}
  local ack_body=${3:-} ack_login=${4:-} ack_assoc=${5:-}
  local created_at=${6:-2026-08-04T00:00:00Z}
  local updated_at=${7:-$created_at}
  make_issue_comments_fixture "$(jq -n \
    --arg body "$body" --arg login "$login" --arg created_at "$created_at" --arg updated_at "$updated_at" \
    --arg ab "$ack_body" --arg al "$ack_login" --arg aa "$ack_assoc" '
    [ { id: 7001, user: { login: $login }, author_association: "NONE", body: $body,
        created_at: $created_at, updated_at: $updated_at } ]
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
  "$(make_summary_body "$STALE_SHA" "$SUMMARY_BLOCKING_FINDING")")
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
  "Reviewing files that changed from the base of the PR and between $HEAD_SHA and $STALE_SHA")"
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
if grep -q "^\[mergepath-summary-ack: $HEAD_SHA [0-9a-f]\{12\}\]$" <<<"$ACK_TOKEN"; then
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
# Test 28b (#1008): the OTHER direction — a read that SUCCEEDS while `gh api`
# writes benign chatter to stderr is a good read, and must be graded, not
# reported as unreadable.
#
# This gate's own copy of fetch_api_array captured with `gh api … 2>&1`, so
# every deprecation notice / retry line landed in the JSON handed to
# `jq -s`, the slurp failed, and `die 2` reported a healthy fetch as an
# infra failure. Only codex-review-request.sh's copy had the separated-stream
# form (#966); routing all eight through scripts/lib/gh-api-array.sh is what
# gives this gate that correction.
#
# Asserted on the summary-only blocking fixture from test 18 rather than on a
# clean one: an EMPTY result would also exit 0, so "did not fail closed" is
# not enough — the payload has to arrive intact enough to still be CLASSIFIED,
# which only a correctly-parsed read can do.
# ---------------------------------------------------------------------------
echo
echo "--- Test 28b (#1008): benign gh stderr on a SUCCESSFUL read → still parsed and graded"
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
  FIXTURE_ISSUE_COMMENTS_STDERR_NOISE=1 \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && ! echo "$OUT" | grep -qi "failed to flatten PR-level issue comments"; then
  pass "#1008: benign gh stderr on a successful read does not become a flatten failure"
else
  fail "expected rc=1 with 'unresolved: 1' and no flatten error; got rc=$RC"
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
if grep -q "mergepath-summary-ack" <<<"$ACK_PROBE_OUT" \
    && ! grep -q "^\[mergepath-summary-ack:" <<<"$ACK_PROBE_OUT"; then
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
QUOTED_RANGE_SUMMARY="$(make_summary_body "$STALE_SHA" "$SUMMARY_BLOCKING_FINDING

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
# Test 45 (#886, Phase 4b P2): a shortened commits-range end cannot identify a
# unique Git object. A PR author can create a later current head with the same
# prefix, so the required gate must fail closed until CodeRabbit supplies the
# full current SHA.
# ---------------------------------------------------------------------------
echo
echo "--- Test 45 (#886): an ABBREVIATED commits-range end is out of scope → exit 0"
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
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "does not name $HEAD_SHA as its commits-range end"; then
  pass "an abbreviated range end cannot identify this head → out of scope, exit 0"
else
  fail "expected rc=0 with the out-of-scope log line; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 45b (#886): a shortened range end for another SHA is likewise out of
# scope. This keeps the short-form rejection independent of whether the prefix
# happens to resemble the current head.
# ---------------------------------------------------------------------------
echo
echo "--- Test 45b (#886): a DIFFERENT abbreviated sha is out of scope → exit 0"
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
  pass "a different abbreviated sha stays out of scope → exit 0"
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
# Test 47 (#886, Codex P1): CodeRabbit's markerless full-review body has no
# auto-generated summary marker or commits-range line. Its exact-head review
# object is therefore the only legitimate scope anchor. The P1 finding must
# gate when both surfaces agree, but a look-alike body alone must not.
# ---------------------------------------------------------------------------
echo
echo "--- Test 47 (#886): markerless full-review summary + head review object → exit 1"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_THREADS=$(make_threads_fixture '[]')
MARKERLESS_FULL_REVIEW="**Actionable comments posted: 1**

$SUMMARY_BLOCKING_FINDING"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$MARKERLESS_FULL_REVIEW" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:00Z" "2026-08-04T00:00:20Z")
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "markerless full-review summary"; then
  pass "markerless full-review finding is gated when a CodeRabbit review object anchors HEAD"
else
  fail "expected rc=1 with a markerless exact-head review-object anchor; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo "--- Test 47b (#886): markerless body without a head review object → exit 0"
FIXTURE_REVIEWS=$(make_reviews_fixture "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "has no timestamped completed CodeRabbit review object"; then
  pass "markerless body without a current-head review object remains out of scope"
else
  fail "expected rc=0 with markerless summary rejected without head review; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# A current-head review object must correlate to the publication that carries
# the markerless body. Without the fresh_at floor, an older clean-looking
# markerless summary can borrow a later review object and transiently clear
# the gate until the asynchronous issue_comment sweep catches up.
echo "--- Test 47c (#886): markerless body predating head review object → exit 0"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$MARKERLESS_FULL_REVIEW" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:00Z" "2026-08-04T00:00:05Z")
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "predates completed CodeRabbit review object"; then
  pass "markerless body that predates its exact-head review object remains out of scope"
else
  fail "expected rc=0 with markerless summary rejected as stale; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# What the hold is FOR, once the summary is read out of the run object's own
# body: a head-pinned CodeRabbit review RUN exists and NO acceptor recognises a
# summary in it — a serialization this gate cannot classify. Holding is the
# correct answer to that, because a gate that cannot read the review must not
# certify it. This is now the ONLY route to rc 3: a run carrying a recognised
# serialization becomes a candidate the moment the run exists, so the hold can
# no longer fire merely because the walkthrough comment has not caught up (the
# steady-state deadlock measured on this PR, covered by test 47f).
echo "--- Test 47d (#886): a head run whose body matches no acceptor → exit 3"
FIXTURE_ISSUE_COMMENTS=$(make_issue_comments_fixture '[]')
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z" \
  "### Review complete

See the inline comments.")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
# The run id is asserted too: the hold's remaining case is an UNRECOGNISED body,
# so the operator has to be told which object was not recognised or the message
# is unactionable.
if [ "$RC" = 3 ] && echo "$OUT" | grep -q "awaiting its PR-level summary" \
    && echo "$OUT" | grep -q "review run object(s): 8001"; then
  pass "a run whose serialization no acceptor recognises holds the run, naming the object"
else
  fail "expected rc=3 naming the unrecognised run object; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# The PUBLISHER is the job, not the event. Scoping REQUIRE_REVIEW_SUMMARY to
# `pull_request_review` left the SAME job — the one that owns the native check
# for this head — running the arrival-independent scan on its other triggers, so
# a pull_request_review_comment (CodeRabbit's own inline comments fire one each)
# or a pull_request [edited] landing inside the publication gap published a
# success over the review run's rc 3 red, under the same check name and on the
# same head. Structural, because the guarded code runs in Actions: assert the
# event-driven job opts in unconditionally and carries no event-name condition
# on the flag (Codex P1 on #886).
echo "--- Test 47d0 (#886): the event-driven publisher honors the hold on every event it serves"
EVENT_JOB=$(awk '
  /^  coderabbit-severity-gate:/ { in_job = 1 }
  in_job && /^  scheduled-sweep:/ { exit }
  in_job { print }
' "$ROOT/.github/workflows/coderabbit-severity-gate.yml")
# `|| true`: grep -c exits 1 on a count of ZERO, which is exactly the regression
# this asserts against, and a failing command substitution aborts the suite under
# `set -e` — so the regression would surface as a crash that also stops every
# later test, instead of as this test failing (CodeRabbit, #886).
EVENT_FLAG=$(printf '%s\n' "$EVENT_JOB" | grep -c '^ *REQUIRE_REVIEW_SUMMARY:' || true)
if [ "$EVENT_FLAG" -eq 1 ] \
    && grep -Fq 'REQUIRE_REVIEW_SUMMARY: "true"' <<<"$EVENT_JOB" \
    && ! grep '^ *REQUIRE_REVIEW_SUMMARY:' <<<"$EVENT_JOB" | grep -q 'github.event_name'; then
  pass "the event-driven job sets the hold flag once, unconditionally"
else
  fail "expected exactly one unconditional REQUIRE_REVIEW_SUMMARY: \"true\" in the event-driven job (found $EVENT_FLAG setting(s))"
  printf '%s\n' "$EVENT_JOB" | grep -n 'REQUIRE_REVIEW_SUMMARY' | sed 's/^/      /' >&2
fi

# The unconditional flag is only safe because the flag does not decide a hold —
# the ANCHOR does. On a push there is no CodeRabbit review on the new head, so a
# run with the flag set must PASS rather than hold; if it held, every
# synchronize event would pin the required check red until CodeRabbit got round
# to the PR, which is review-ARRIVAL enforcement this gate deliberately does not
# do. This is the invariant that let the event allow-list collapse to "true".
echo "--- Test 47d0b (#886): flag set with no review on HEAD does not hold → exit 0"
FIXTURE_ISSUE_COMMENTS=$(make_issue_comments_fixture '[]')
FIXTURE_REVIEWS=$(make_issue_comments_fixture '[]')
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && ! echo "$OUT" | grep -q "awaiting its PR-level summary"; then
  pass "the hold needs an anchor: no current-head review means no hold, flag or not"
else
  fail "expected rc=0 with the flag set and no current-head review; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# rc 3 is not a finding count, and the two publishers of this check have to
# answer it differently: the event-driven job cannot decline to publish (it owns
# the native check for the head), while the sweep must decline rather than post
# a verdict read off the previous publication. Both halves are asserted against
# the workflow, since a gate exit code with no consumer changes nothing.
echo "--- Test 47d1 (#886): both publishers act on the rc 3 hold"
SWEEP_JOB=$(awk '
  /^  scheduled-sweep:/ { in_job = 1 }
  in_job { print }
' "$ROOT/.github/workflows/coderabbit-severity-gate.yml")
if grep -Fq 'REQUIRE_REVIEW_SUMMARY: "true"' <<<"$SWEEP_JOB" \
    && grep -Fq 'if [ "$rc" -eq 3 ]; then' "$ROOT/.github/workflows/coderabbit-severity-gate.yml" \
    && grep -Fq "skipping this publication so the review run's verdict stands" "$ROOT/.github/workflows/coderabbit-severity-gate.yml" \
    && grep -Fq "holding this run non-green until it does" "$ROOT/.github/workflows/coderabbit-severity-gate.yml"; then
  pass "the sweep opts into the hold and skips publication; the event-driven job goes non-green"
else
  fail "expected the sweep to set REQUIRE_REVIEW_SUMMARY and skip on rc 3, and the event job to fail on it"
fi

# A CodeRabbit conversational REPLY creates a head-pinned COMMENTED review
# object with an EMPTY body and starts no run, so no summary ever follows it
# (mergepath#900). Letting one set the correlation floor pushed that floor past
# the genuine summary and held the run forever — re-armed by every thread reply.
echo "--- Test 47d1b (#886): a body-less reply object does not set the correlation floor"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" 'No required finding here.')" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:20Z" "2026-08-04T00:00:20Z")
FIXTURE_REVIEWS=$(make_issue_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [ { id: 8001, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:10Z", body: "**Actionable comments posted: 0**" },
    { id: 8002, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:30Z", body: "" } ]
')")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && ! echo "$OUT" | grep -q "awaiting its PR-level summary"; then
  pass "a reply-carrier review object cannot push the floor past the genuine summary"
else
  fail "expected rc=0 with the summary still correlated to the real run; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# A marker-led summary's commits-range end still names the head after CodeRabbit
# re-reviews the SAME head, so the SHA-only scope test alone keeps the PREVIOUS
# publication in scope. On the review-triggered path that stale candidate must be
# dropped and the verdict must come from the CURRENT run's own summary instead.
#
# Non-vacuous by construction: the stale marker-led summary carries a BLOCKING
# finding while the current run reports none, so the two answers differ. A
# regressed correlation filter classifies the stale summary and shows up as rc 1;
# only dropping it yields rc 0. (Before the review-object sourcing this case
# could only be expressed as the hold, because there was no current summary for
# the verdict to come from.)
echo "--- Test 47d2 (#886): review event + marker summary predating the review → dropped, exit 0"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING")" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:00Z" "2026-08-04T00:00:00Z")
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && echo "$OUT" | grep -q "predate the completed CodeRabbit review object" \
    && echo "$OUT" | grep -q "markerless full-review summary in review object 8001"; then
  pass "a marker-led summary from the previous publication is dropped for the current run's own"
else
  fail "expected rc=0 with the uncorrelated marker summary dropped; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# The correlation floor must not be a blanket hold: once the summary for THIS
# review publishes, the same review-triggered run classifies it and goes green.
echo "--- Test 47d3 (#886): review event + summary published after the review → exit 0"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" 'No required finding here.')" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:20Z" "2026-08-04T00:00:20Z")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! echo "$OUT" | grep -q "awaiting its PR-level summary"; then
  pass "a marker-led summary correlated to the triggering review still clears the run"
else
  fail "expected rc=0 once the correlated summary publishes; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# The correlation filter reads each candidate's own fresh_at, so the markerless
# candidate has to carry the value its selection floor already checked. Dropping
# it made the filter discard a candidate it had just admitted — a false HOLD
# reachable only when REQUIRE_REVIEW_SUMMARY and the markerless format meet.
echo "--- Test 47d3b (#886): review event + correlated markerless summary → exit 1 on its finding"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$MARKERLESS_FULL_REVIEW" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:00Z" "2026-08-04T00:00:20Z")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P1\] (PR-level summary comment)" \
    && ! echo "$OUT" | grep -q "awaiting its PR-level summary" \
    && ! echo "$OUT" | grep -q "predate the completed CodeRabbit review object"; then
  pass "a correlated markerless summary is classified, not discarded, on the review-triggered path"
else
  fail "expected rc=1 from the markerless finding rather than the publication hold; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Dismissing a CodeRabbit review is one of this gate's own triggers. If the
# dismissed object stopped anchoring, the dismissal itself would clear a
# summary-only blocking finding on exit 0 — a second, undocumented way off a
# surface whose only exit is meant to be the collaborator ack.
echo "--- Test 47d1c (#886): a DISMISSED review still anchors its markerless summary → exit 1"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments "$MARKERLESS_FULL_REVIEW" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:00Z" "2026-08-04T00:00:20Z")
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" DISMISSED "2026-08-04T00:00:10Z")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P1\] (PR-level summary comment)"; then
  pass "dismissing the review does not drop the anchor or clear the summary finding"
else
  fail "expected rc=1 with the dismissed review still anchoring the summary; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# The sweep's compare-and-swap has to sample every surface the verdict is
# computed from, and there are FOUR. The PR-comment surface carries the summary;
# the review-object surface decides the publication hold the sweep opted into;
# and the gate's ORIGINAL input — unresolved blocking INLINE findings — is read
# from pulls/{pr}/comments plus GraphQL reviewThreads. A thread resolved, or a
# finding posted/edited/deleted, between the gate's read and the check_run POST
# leaves a comments+reviews-only fingerprint byte-identical, so the guard
# republishes a stale success over a now-unresolved blocking finding.
echo "--- Test 47d1d (#886): the sweep snapshot guard samples every verdict surface"
# Extract to the closing brace AT THE FUNCTION'S OWN INDENT. A `/^ *}/` range
# end stops at the first `}` of the embedded GraphQL document instead and
# truncates the body, which silently under-counts the fail-closed reads below.
FP_FN=$(awk '
  /^            cr_surface_fp\(\) \{$/ { in_fn = 1 }
  in_fn { print }
  in_fn && /^            \}$/ { exit }
' "$ROOT/.github/workflows/coderabbit-severity-gate.yml")
# `|| true` for the same `set -e` reason as the EVENT_FLAG count above: a
# fingerprint function stripped of its fail-closed reads counts ZERO, and the
# bare form would abort the suite rather than fail this assertion.
FP_FAILCLOSED=$(printf '%s\n' "$FP_FN" | grep -c '|| return 1' || true)
if grep -Fq 'repos/$REPO/issues/$1/comments' <<<"$FP_FN" \
    && grep -Fq 'repos/$REPO/pulls/$1/reviews' <<<"$FP_FN" \
    && grep -Fq 'repos/$REPO/pulls/$1/comments' <<<"$FP_FN" \
    && grep -Fq 'reviewThreads(first: 100, after: $endCursor)' <<<"$FP_FN" \
    && grep -Fq 'nodes { id isResolved }' <<<"$FP_FN" \
    && grep -Fq "printf '%s\\035%s\\035%s\\035%s'" <<<"$FP_FN" \
    && [ "$FP_FAILCLOSED" -eq 4 ]; then
  pass "cr_surface_fp fingerprints comments, reviews, inline findings and thread state, failing closed on each read"
else
  fail "expected cr_surface_fp to sample all four surfaces and fail closed on each read (fail-closed lines: $FP_FAILCLOSED)"
fi

# A raw C0 control byte anywhere in the workflow makes the YAML document
# unloadable — Ruby Psych rejects the file with "control characters are not
# allowed" — and GitHub then refuses to register the workflow at all. For a
# REQUIRED check that is worse than a failing run: the check silently stops
# existing. Two of this file's delimiters ARE control bytes, written as the jq
# and printf escapes so the source stays printable; a prose mention of one that
# pastes the byte itself is the same document-level break (Codex P1 on #886).
echo "--- Test 47d1e (#886): the workflow source carries no raw control bytes"
# Delete TAB, LF, printable ASCII and every high byte (UTF-8 continuation), so
# what survives is exactly the C0 bytes YAML forbids, plus DEL.
CTRL_BYTES=$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' \
  < "$ROOT/.github/workflows/coderabbit-severity-gate.yml" | LC_ALL=C wc -c | tr -d '[:space:]')
if [ "$CTRL_BYTES" -eq 0 ]; then
  pass "no raw C0 control byte in the workflow source"
else
  fail "workflow source contains $CTRL_BYTES raw control byte(s); GitHub cannot load the document"
  LC_ALL=C grep -n '[^[:print:][:space:]]' "$ROOT/.github/workflows/coderabbit-severity-gate.yml" \
    | head -5 | sed 's/^/      /' >&2
fi

# The correlation floor is scoped to the review-triggered path. On the
# arrival-independent sweep an uncorrelated candidate must stay IN scope:
# dropping it there yields zero candidates, which passes, and a real blocking
# summary finding would go unenforced.
echo "--- Test 47d4 (#886): sweep path keeps an uncorrelated marker summary in scope → exit 1"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING")" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:00Z" "2026-08-04T00:00:00Z")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && ! echo "$OUT" | grep -q "predate the completed CodeRabbit review object"; then
  pass "the sweep path still enforces an uncorrelated marker-led summary finding"
else
  fail "expected rc=1 with the sweep path unaffected by the correlation floor; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Marker-led summaries and markerless full-review summaries are separate
# CodeRabbit serializations, not fallbacks for one another. A stale marker-led
# comment must not hide a fresh markerless body that carries the only P1.
echo "--- Test 47e (#886): stale marker-led + current markerless summary → exit 1"
STALE_MARKER_SUMMARY=$(make_summary_body "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "No required finding here.")
FIXTURE_ISSUE_COMMENTS=$(make_issue_comments_fixture "$(jq -n \
  --arg marker "$STALE_MARKER_SUMMARY" --arg markerless "$MARKERLESS_FULL_REVIEW" '
  [
    { id: 7001, user: { login: "coderabbitai[bot]" }, author_association: "NONE", body: $marker,
      created_at: "2026-08-04T00:00:00Z", updated_at: "2026-08-04T00:00:00Z" },
    { id: 7002, user: { login: "coderabbitai[bot]" }, author_association: "NONE", body: $markerless,
      created_at: "2026-08-04T00:00:00Z", updated_at: "2026-08-04T00:00:20Z" }
  ]
')")
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z")
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "comment id 7002" \
    && echo "$OUT" | grep -q "markerless full-review summary"; then
  pass "a stale marker-led summary cannot shadow a current markerless finding"
else
  fail "expected rc=1 with current markerless finding despite stale marker-led summary; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 47f (#886): the MEASURED production shape, and the deadlock it produced.
#
# On a real PR with CodeRabbit TERMINAL for the head — review object present,
# commit StatusContext `CodeRabbit = success` — the gate still exited 3, because
# the marker-led walkthrough comment is updated in place and was still naming an
# OLDER head, and the markerless predicate was applied to the PR-comment surface
# where CodeRabbit never writes it (0 occurrences across ten real PRs, against 17
# in review-object bodies). Steady state was therefore zero candidates: the event
# job published red forever and the sweep, the only publisher that could retire
# it, answered rc 3 by declining. Under `enforce_admins: true` there is no
# break-glass, so merging deadlocked the repo.
#
# The fixture is that state exactly: terminal head-pinned review OBJECT carrying
# the markerless summary, walkthrough naming a stale head, hold flag set.
# ---------------------------------------------------------------------------
echo
echo "--- Test 47f (#886): terminal review object + stale walkthrough → no hold, exit 0"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$STALE_SHA" 'No required finding here.')" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:00Z" "2026-08-04T00:00:00Z")
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z" \
  "**Actionable comments posted: 0**

No blocking findings on this head.")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && ! echo "$OUT" | grep -q "awaiting its PR-level summary" \
    && echo "$OUT" | grep -q "markerless full-review summary in review object 8001" \
    && echo "$OUT" | grep -q "head-pinned by its commit_id to $HEAD_SHA"; then
  pass "a terminal review object clears the hold even when the walkthrough names an older head"
else
  fail "expected rc=0 with no hold on a terminal CodeRabbit; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Not merely COUNTED as a candidate — CLASSIFIED. Clearing the hold by admitting
# a body the gate then never reads would trade a deadlock for a false clear, so
# the same fixture with a P1 in the review-object body must gate on it.
echo "--- Test 47f2 (#886): the review object's own body is classified → exit 1"
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z" \
  "**Actionable comments posted: 1**

$SUMMARY_BLOCKING_FINDING")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P1\] (PR-level summary comment)" \
    && ! echo "$OUT" | grep -q "awaiting its PR-level summary"; then
  pass "a blocking finding in the review object's own body gates rather than clearing"
else
  fail "expected rc=1 from the review-object body's own finding; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# The scope anchor is the object's GitHub-owned commit_id, not its timestamp: a
# review object on ANOTHER head contributes nothing, however recent it is. Pairs
# with 47d0b — without an anchor there is no hold either, because this gate does
# not enforce review ARRIVAL (that would pin every push red until CodeRabbit got
# round to the PR).
echo "--- Test 47f3 (#886): a review object on another head is not this head's summary → exit 0"
FIXTURE_REVIEWS=$(make_reviews_fixture "$PREV_SHA" COMMENTED "2026-08-04T00:09:59Z" \
  "**Actionable comments posted: 1**

$SUMMARY_BLOCKING_FINDING")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! echo "$OUT" | grep -q "awaiting its PR-level summary" \
    && ! echo "$OUT" | grep -q "markerless full-review summary in review object"; then
  pass "a review object pinned to another head neither gates nor holds"
else
  fail "expected rc=0 with an off-head review object ignored; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 47g (#886): CodeRabbit's OTHER terminal serialization — no
# `Actionable comments posted` header at all.
#
# Measured across `pulls/{pr}/reviews` for 20 mergepath PRs: of 22 non-empty
# coderabbitai[bot] review bodies, 2 open with a blank line and then
# `<details><summary>🧹 Nitpick comments (N)</summary>` and carry no header line
# anywhere (mergepath#880 review 4848342765 on 9601e872, mergepath#849 review
# 4833684457 on 1b8195da). Both are complete terminal reports, and on #880's head
# 4848342765 was the ONLY CodeRabbit review object. With the header as the sole
# acceptor the candidate set was empty on a terminal review — rc 3, which the
# event arm publishes as a native FAILURE and the sweep declines to retire, on a
# body that never changes and with no break-glass under `enforce_admins: true`.
#
# The escape the object itself carries: its own `📥 Commits` range names the head,
# corroborating the GitHub-owned `commit_id` it is already pinned by.
# ---------------------------------------------------------------------------

# Compose the header-less terminal report, in the shape measured on #880.
#   $1 = sha to name as the commits-range END
#   $2 = findings text
#   $3 = extra stanza marker (optional — makes the body a non-report)
# The leading blank lines and the trailing `... by CodeRabbit for review status`
# comment are both real: the latter is NOT a stanza opener (no `: <kind> by
# coderabbit.ai`), which is why a run body legitimately carries zero stanzas.
make_headerless_review_body() {
  local head=$1 findings=$2 extra=${3:-}
  {
    printf '\n\n'
    if [ -n "$extra" ]; then
      printf '%s\n\n' "$extra"
    fi
    printf '%s\n' '<details>'
    printf '%s\n\n' '<summary>🧹 Nitpick comments (1)</summary><blockquote>'
    printf '%s\n\n' "$findings"
    printf '%s\n\n' '</blockquote></details>'
    printf '%s\n' '<details>'
    printf '%s\n\n' '<summary>📥 Commits</summary>'
    printf 'Reviewing files that changed from the base of the PR and between %s and %s.\n' \
      "$PREV_SHA" "$head"
    printf '%s\n\n' '</details>'
    printf '%s\n' '<!-- This is an auto-generated comment by CodeRabbit for review status -->'
  }
}

echo
echo "--- Test 47g (#886): header-less terminal review body naming HEAD → no hold, exit 0"
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$STALE_SHA" 'No required finding here.')" \
  "coderabbitai[bot]" "" "" "" "2026-08-04T00:00:00Z" "2026-08-04T00:00:00Z")
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z" \
  "$(make_headerless_review_body "$HEAD_SHA" "$SUMMARY_NITPICK_FINDING")")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && ! echo "$OUT" | grep -q "awaiting its PR-level summary" \
    && echo "$OUT" | grep -q "markerless full-review summary in review object 8001" \
    && echo "$OUT" | grep -q "recognised by: own-commits-range"; then
  pass "a header-less terminal report is recognised by the commits range in its own body"
else
  fail "expected rc=0 with the header-less report accepted; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Non-vacuous: admitting a body the gate then never reads would trade the
# deadlock for a false clear, so the SAME serialization carrying a Major must
# gate on it. Only the classification tells 47g and 47g2 apart.
echo "--- Test 47g2 (#886): a header-less body's own finding is classified → exit 1"
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z" \
  "$(make_headerless_review_body "$HEAD_SHA" "$SUMMARY_BLOCKING_FINDING")")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P1\] (PR-level summary comment)" \
    && ! echo "$OUT" | grep -q "awaiting its PR-level summary"; then
  pass "a blocking finding in a header-less review body gates rather than clearing"
else
  fail "expected rc=1 from the header-less body's own finding; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# The acceptor is the ANCHOR, not the shape. A header-less body whose commits
# range names an OLDER head is not this head's report, and admitting it on
# `commit_id` alone would let any unrecognised serialization certify the head.
echo "--- Test 47g3 (#886): header-less body naming an older head is not accepted → exit 3"
FIXTURE_ISSUE_COMMENTS=$(make_issue_comments_fixture '[]')
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z" \
  "$(make_headerless_review_body "$STALE_SHA" "$SUMMARY_NITPICK_FINDING")")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 3 ] && echo "$OUT" | grep -q "review run object(s): 8001"; then
  pass "a header-less body naming another head does not certify this one"
else
  fail "expected rc=3 on a header-less body naming a stale head; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ...and a body whose own markup says the publication produced NO review is not a
# report however precisely it names the head. The guard is the narrow one — at
# least one non-benign stanza — not the marker format's all-benign test, which a
# genuine run body (zero stanzas) would fail.
echo "--- Test 47g4 (#886): a rate-limited header-less body naming HEAD is not a report → exit 3"
FIXTURE_REVIEWS=$(make_reviews_fixture "$HEAD_SHA" COMMENTED "2026-08-04T00:00:10Z" \
  "$(make_headerless_review_body "$HEAD_SHA" "$SUMMARY_NITPICK_FINDING" "$RATE_LIMIT_STANZA")")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 3 ] && echo "$OUT" | grep -q "review run object(s): 8001"; then
  pass "a non-benign stanza keeps a head-naming body out of scope"
else
  fail "expected rc=3 on a rate-limited header-less body; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 47h (#886): the correlation floor comes from runs that CARRY a recognised
# summary, never from any non-empty run.
#
# HEAD_REVIEW_AT is max(submitted_at) over every non-empty head-pinned run,
# unrecognised ones included, and the REQUIRE_REVIEW_SUMMARY correlation filter
# drops candidates below it. A later unrecognised run therefore discarded the
# recognised summary — including the review-object-body candidate, whose fresh_at
# IS its own run's submitted_at — so a head where a readable summary demonstrably
# existed reported neither its finding nor a success. Same unretirable red as
# 47g, reached from the opposite direction. Same-head double runs are production
# shapes (#886 commit 5d04dfc9 → reviews 4860672174 + 4860719383).
#
# Non-vacuous: the recognised run carries a Major, so a poisoned floor is rc 3
# and an honest one is rc 1. The two answers cannot be confused.
# ---------------------------------------------------------------------------
echo
echo "--- Test 47h (#886): a later unrecognised run does not discard the recognised summary → exit 1"
FIXTURE_ISSUE_COMMENTS=$(make_issue_comments_fixture '[]')
FIXTURE_REVIEWS=$(make_issue_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" \
  --arg blocking "**Actionable comments posted: 1**

$SUMMARY_BLOCKING_FINDING" '
  [ { id: 8001, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:10Z", body: $blocking },
    { id: 8002, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:30Z", body: "### Review complete\n\nSee the inline comments." } ]
')")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 1" \
    && echo "$OUT" | grep -q "\[P1\] (PR-level summary comment)" \
    && ! echo "$OUT" | grep -q "awaiting its PR-level summary"; then
  pass "an unrecognised later run cannot poison the floor and hide a recognised Major"
else
  fail "expected rc=1 reporting the recognised run's Major; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# Supersession still works, and is what the floor is FOR: when the later run's
# body IS recognised, it replaces the earlier publication rather than being
# ignored. Same two runs as 47h with 8002 carrying a real terminal report, so the
# Major is dropped as superseded and the verdict comes from the current run.
echo "--- Test 47h2 (#886): a later RECOGNISED run supersedes the earlier summary → exit 0"
FIXTURE_REVIEWS=$(make_issue_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" \
  --arg blocking "**Actionable comments posted: 1**

$SUMMARY_BLOCKING_FINDING" \
  --arg current "$(make_headerless_review_body "$HEAD_SHA" "$SUMMARY_NITPICK_FINDING")" '
  [ { id: 8001, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:10Z", body: $blocking },
    { id: 8002, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:30Z", body: $current } ]
')")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && echo "$OUT" | grep -q "markerless full-review summary in review object 8002" \
    && ! echo "$OUT" | grep -q "awaiting its PR-level summary"; then
  pass "the newest recognised run's own summary is the verdict on a same-head re-review"
else
  fail "expected rc=0 from the superseding run's summary; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 47h3 (#886, Codex P1 round 15): the mirror image of 47h. Taking the floor
# from recognised runs alone stops a later unrecognised run from HIDING a
# finding, and by itself it also stops that run from being noticed at all: when
# the earlier recognised summary is CLEAN, the gate published success while
# CodeRabbit's newest serialization on this head sat unread — which is the
# summary-only blocking finding this gate exists to catch, cleared by a required
# check.
#
# The hold applies to a would-be PASS only, which is why 47h above still reports
# its Major on rc 1 rather than disappearing into this hold. Same two runs as
# 47h, with 8001's body carrying a nitpick instead of a Major: 47h and 47h3 have
# byte-identical run 8002 and differ only in whether the READ verdict is clean,
# so nothing but the pass/fail distinction can produce their different answers.
# ---------------------------------------------------------------------------
echo
echo "--- Test 47h3 (#886): a newer unrecognised run withholds an otherwise-clean pass → exit 3"
FIXTURE_ISSUE_COMMENTS=$(make_issue_comments_fixture '[]')
FIXTURE_REVIEWS=$(make_issue_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" \
  --arg clean "**Actionable comments posted: 0**

$SUMMARY_NITPICK_FINDING" '
  [ { id: 8001, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:10Z", body: $clean },
    { id: 8002, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:30Z", body: "### Review complete\n\nSee the inline comments." } ]
')")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 3 ] && echo "$OUT" | grep -q "unrecognised head-pinned review run object(s): 8002" \
    && ! echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "a clean earlier publication cannot certify a head whose newest run is unread"
else
  fail "expected rc=3 naming the unread newer run 8002; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# The hold is scoped to REQUIRE_REVIEW_SUMMARY, like the correlation filter it
# rides beside: an ad-hoc or third-party caller has no publication to withhold
# and asked for the arrival-independent answer. Same fixture, flag unset.
echo "--- Test 47h4 (#886): the unread-run hold does not fire for an ad-hoc caller → exit 0"
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! echo "$OUT" | grep -q "unrecognised head-pinned review run object"; then
  pass "the default-false path keeps its arrival-independent answer"
else
  fail "expected rc=0 with no hold when REQUIRE_REVIEW_SUMMARY is unset; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# An unread run the gate cannot ORDER is still an unread run (CodeRabbit Major on
# #886). `>` on the timestamp alone left two fail-open gaps in 47h3's predicate:
# a run whose `submitted_at` is absent compares below every real timestamp, and a
# run sharing a second with the recognised summary compares equal. Both read as
# "not newer" and let the older clean summary certify the head. Dropping an
# unusable timestamp is the safe direction for a CANDIDATE and the unsafe one for
# a RUN, which is why the two predicates deliberately differ.
echo "--- Test 47h5 (#886): an unread run with no submitted_at counts as newer → exit 3"
FIXTURE_REVIEWS=$(make_issue_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" \
  --arg clean "**Actionable comments posted: 0**

$SUMMARY_NITPICK_FINDING" '
  [ { id: 8001, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:10Z", body: $clean },
    { id: 8002, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: null, body: "### Review complete\n\nSee the inline comments." } ]
')")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 3 ] && echo "$OUT" | grep -q "unrecognised head-pinned review run object(s): 8002"; then
  pass "a run the gate cannot place in the order is not certified around"
else
  fail "expected rc=3 naming the untimestamped run 8002; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

echo "--- Test 47h6 (#886): an unread run sharing the summary's timestamp counts as newer → exit 3"
FIXTURE_REVIEWS=$(make_issue_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" \
  --arg clean "**Actionable comments posted: 0**

$SUMMARY_NITPICK_FINDING" '
  [ { id: 8001, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:10Z", body: $clean },
    { id: 8002, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:10Z", body: "### Review complete\n\nSee the inline comments." } ]
')")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 3 ] && echo "$OUT" | grep -q "unrecognised head-pinned review run object(s): 8002"; then
  pass "the (submitted_at, id) total order breaks a shared-second tie"
else
  fail "expected rc=3 naming the same-second run 8002; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# The tie-break is by ID and not "any equal timestamp holds": an unrecognised run
# that shares the second but sorts BELOW the recognised summary is part of the
# publication already read, not a later one, and must not withhold the pass.
echo "--- Test 47h7 (#886): an unread run BELOW the summary in the total order does not hold → exit 0"
FIXTURE_REVIEWS=$(make_issue_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" \
  --arg clean "**Actionable comments posted: 0**

$SUMMARY_NITPICK_FINDING" '
  [ { id: 8000, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:10Z", body: "### Review complete\n\nSee the inline comments." },
    { id: 8001, user: { login: "coderabbitai[bot]" }, commit_id: $sha, state: "COMMENTED",
      submitted_at: "2026-08-04T00:00:10Z", body: $clean } ]
')")
set +e
OUT=$(
  REQUIRE_REVIEW_SUMMARY=true \
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! echo "$OUT" | grep -q "unrecognised head-pinned review run object"; then
  pass "an earlier same-second run belongs to the publication already read"
else
  fail "expected rc=0 with no hold on the lower-id same-second run; got rc=$RC"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 48 (#886, Codex P2): the scheduled workflow's stale-snapshot guard
# must preserve read status separately. Serializing failed reads as a random
# fingerprint only probabilistically skips a publish; a read failure has no
# trustworthy snapshot and must unconditionally continue to the next sweep.
# This is intentionally structural because the guarded code runs in Actions,
# while this suite's `gh` shim exercises the gate script itself.
# ---------------------------------------------------------------------------
echo
echo "--- Test 48 (#886): workflow skips publication when either comment fingerprint read fails"
WORKFLOW="$ROOT/.github/workflows/coderabbit-severity-gate.yml"
if ! grep -Fq '__unreadable__' "$WORKFLOW" \
    && grep -Fq 'pre_fp_rc=$?' "$WORKFLOW" \
    && grep -Fq 'post_fp_rc=$?' "$WORKFLOW" \
    && grep -Fq '{ [ "$pre_fp_rc" -ne 0 ] || [ "$post_fp_rc" -ne 0 ]; }; then' "$WORKFLOW" \
    && awk '
      /\{ \[ "\$pre_fp_rc" -ne 0 \] \|\| \[ "\$post_fp_rc" -ne 0 \]; \}; then/ { guarding=1; next }
      guarding && /continue/ { found=1; exit }
      guarding && /^            fi/ { exit }
      END { exit(found ? 0 : 1) }
    ' "$WORKFLOW"; then
  pass "unreadable fingerprint snapshots skip publication without a random sentinel"
else
  fail "workflow must retain fingerprint read status and continue on either read failure"
fi

# ---------------------------------------------------------------------------
# Test 48b (#886, Codex P1): the gate's fail-closed rc 2 must reach the
# check_run even when the snapshot guard cannot compare. The two failures are
# CORRELATED, not independent — cr_surface_fp and the gate read the same
# issues/{pr}/comments endpoint — so an unreadable endpoint trips the guard and
# exits the gate 2 in the same breath, and a guard ordered first swallowed the
# fail-closed verdict, leaving a possibly-stale SUCCESS on the head. Structural,
# because the ordering lives in Actions.
# ---------------------------------------------------------------------------
echo
echo "--- Test 48b (#886): a fail-closed rc 2 outranks both snapshot guards"
SWEEP_STEP=$(awk '
  /^      - name: Re-evaluate gate per PR and post check_run$/ { in_step = 1 }
  in_step { print }
' "$WORKFLOW")
# `|| true` on every extraction: grep exits 1 on no match, and under `set -e` a
# failing command substitution aborts the whole suite — which turns a real
# regression into a vanished test rather than a reported failure.
GUARDS_CONDITIONED=$(printf '%s\n' "$SWEEP_STEP" \
  | grep -c '^ *if \[ "\$gate_infra_error" -eq 0 \]' || true)
# The classifier must be computed BEFORE the first guard it conditions, and rc 3
# must stay OUTSIDE the infra-error set so the hold keeps declining to publish.
CLASSIFIER_LINE=$(printf '%s\n' "$SWEEP_STEP" | grep -n '^ *gate_infra_error=0$' | head -1 | cut -d: -f1 || true)
FIRST_GUARD_LINE=$(printf '%s\n' "$SWEEP_STEP" | grep -n '^ *if \[ "\$gate_infra_error" -eq 0 \]' | head -1 | cut -d: -f1 || true)
if [ "$GUARDS_CONDITIONED" -eq 2 ] \
    && [ -n "$CLASSIFIER_LINE" ] && [ -n "$FIRST_GUARD_LINE" ] \
    && [ "$CLASSIFIER_LINE" -lt "$FIRST_GUARD_LINE" ] \
    && grep -Fq '0|1|3) ;;' <<<"$SWEEP_STEP" \
    && grep -Fq '*) gate_infra_error=1 ;;' <<<"$SWEEP_STEP"; then
  pass "both snapshot guards defer to the gate's fail-closed exit, and rc 3 still holds"
else
  fail "expected rc 2 to bypass both snapshot guards (guards conditioned: $GUARDS_CONDITIONED, classifier line: ${CLASSIFIER_LINE:-none}, first guard line: ${FIRST_GUARD_LINE:-none})"
fi

# ---------------------------------------------------------------------------
# Test 49 (#947): regression for the #520 SIGPIPE race. `grep -q` exits on
# the FIRST match; when the match sits near the top of a payload large
# enough to fill the pipe buffer, a `printf ... | grep -q` producer can
# still be writing when grep closes its end, taking SIGPIPE/EPIPE — and
# under this file's `set -euo pipefail`, that turns a MATCHING assertion
# into a spurious failure. The herestring form (`grep -q PAT <<<"$VAR"`)
# has no second process to signal, so it cannot race. Build a payload well
# past the pipe buffer (64 KiB, matching the ~20 KB SWEEP_JOB shape from the
# original flake) with the needle on line 1, and run both forms enough
# times that the piped form would be expected to fail at least once if the
# race were still live.
# ---------------------------------------------------------------------------
echo
echo "--- Test 49 (#947): the herestring idiom survives a large early-match payload the piped form races on"
NEEDLE='SIGPIPE_RACE_NEEDLE'
RACE_PAYLOAD=$(
  printf '%s\n' "$NEEDLE"
  # A plain Bash loop instead of `yes | head -n 2000`: the pipeline form
  # requires `|| true` to survive the expected SIGPIPE when `head` stops
  # reading, but that same guard would also mask a genuine failure in
  # payload construction, silently shrinking the payload below the size
  # this regression test needs.
  padding_line=0
  while [ "$padding_line" -lt 2000 ]; do
    printf '%s\n' 'padding padding padding padding padding padding padding padding'
    padding_line=$((padding_line + 1))
  done
)
RACE_ITERS=200
RACE_PIPED_FAILURES=0
i=0
while [ "$i" -lt "$RACE_ITERS" ]; do
  # Deliberately the OLD racy idiom, run in a subshell with `set +e` so one
  # SIGPIPE-induced failure doesn't abort this test loop under `set -e`.
  if ! (set +e; printf '%s\n' "$RACE_PAYLOAD" | grep -q "$NEEDLE"); then
    RACE_PIPED_FAILURES=$((RACE_PIPED_FAILURES + 1))
  fi
  # The fixed herestring idiom must never fail — this is the assertion.
  if ! grep -q "$NEEDLE" <<<"$RACE_PAYLOAD"; then
    fail "herestring grep -q missed a needle present in the payload (iteration $i)"
  fi
  i=$((i + 1))
done
if [ "$RACE_PIPED_FAILURES" -gt 0 ]; then
  pass "confirmed the racy piped idiom can drop matches under pipefail ($RACE_PIPED_FAILURES/$RACE_ITERS runs) while the herestring form stayed correct every time — this is why #947 converts the file's assertions to herestrings rather than reinventing the #520 remedy"
else
  # The race is timing-dependent (#520, #947) and is not guaranteed to
  # reproduce on every host/kernel/iteration count. Absence of a piped
  # failure here does not mean the herestring conversion was unnecessary —
  # it means this run got lucky, same as the local runs noted in #947.
  pass "herestring grep -q stayed correct across $RACE_ITERS large-payload iterations (the racy piped form did not happen to fault this run; see #520/#947 for why it still must not be used)"
fi

# ---------------------------------------------------------------------------
# Test 51 (#936): the summary READ is never allowed to fail into "zero
# findings".
#
# This gate's PR-level summary path grades a DOCUMENT: it feeds the summary
# through `summary_unfenced_numbered` and classifies the surviving lines. The
# reader ran INSIDE the loop's here-document, and a here-document discards its
# command substitution's exit status — so a dead reader produced an empty
# stream, the loop found nothing, and the REQUIRED gate reported zero blocking
# summary findings from a summary it had never read.
# ---------------------------------------------------------------------------
SUMMARY_MAJOR_FINDING='_🔒 Security & Privacy_ | _🟠 Major_ | _⚡ Quick win_

**Reject the diagnostic bypass in merge-gate callers.**

The caller accepts a bypass flag that skips the gate.'

echo
echo "--- Test 51 (#936): a FAILED summary read is never 'zero findings'"
# `done <<EOF\n\$(reader)\nEOF` discards the command substitution's status, so
# an awk that died on a pathological body produced an empty stream, the loop
# found nothing, and this REQUIRED gate printed `unresolved: 0` and exited 0 —
# a failed READ reading as a clean REPORT (CodeRabbit 🟠 Major on #936). The
# body here carries a genuine blocking finding — a 🟠 Major badge, p1 on the
# shared ladder — so a gate that still says zero is reporting on a summary it
# never read.
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_THREADS=$(make_threads_fixture '[]')
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_MAJOR_FINDING")")
AWK_COUNTER="$WORKDIR/awk-calls-51"
: >"$AWK_COUNTER"
# Count the reader's runs on THIS fixture with nothing failing, so the
# threshold below is derived rather than guessed: every run but the last is the
# classifier's, and the last is the summary read under test.
CR_GATE_TEST_FAIL_SUMMARY_AWK_AFTER=9999 \
CR_GATE_TEST_AWK_COUNTER="$AWK_COUNTER" \
  FIXTURE_PR="$FIXTURE_PR" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  run_gate "$SCRATCH" 99 owner/repo >/dev/null 2>&1 || true
TOTAL_AWK=$(cat "$AWK_COUNTER" 2>/dev/null || echo 0)
: >"$AWK_COUNTER"
set +e
OUT=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  CR_GATE_TEST_FAIL_SUMMARY_AWK_AFTER=$((TOTAL_AWK - 1)) \
  CR_GATE_TEST_AWK_COUNTER="$AWK_COUNTER" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC=$?
set -e
# The summary must have survived classification — otherwise the failure under
# test never ran and a green here would be vacuous.
if [ "$TOTAL_AWK" -gt 1 ] && [ "$RC" != 0 ] \
    && ! echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! echo "$OUT" | grep -q "carries a non-benign outcome stanza"; then
  pass "#936: a failed summary read fails closed rather than reporting zero blocking findings"
else
  fail "#936: expected a nonzero exit with no 'unresolved: 0' claim and a classified summary; got rc=$RC (reader runs=$TOTAL_AWK)"
  echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 52 (#942): EVERY call site of the shared summary reader, not just the
# one #936 fixed.
#
# Test 51 above pins the LAST reader run — the grading pipeline. `summary_
# unfenced_numbered` has three other callers, and each one captures it in a
# command substitution that drops the status: `summary_stanza_opener_lines`
# (via summary_stanzas_all_benign / summary_has_non_benign_stanza), the
# commits-range extraction in `summary_names_head`, and the `pair=` extraction
# in `summary_strip_pre_merge_block`. A dead reader at the FIRST of those is
# strictly worse than at the site #936 fixed, because it fires earlier: the
# summary never becomes a candidate, so the graded pipeline's guard is never
# reached and the gate prints `unresolved: 0`.
#
# The assertion is deliberately INDEX-FREE rather than one case per named
# call site. Which run index belongs to which caller is an implementation
# detail that moves whenever the scoping order changes, and a test pinned to
# an index silently stops covering the site it was written for. Failing the
# reader at EVERY index in turn asserts the property the issue actually
# states — "a failed read at ANY of its call sites yields a nonzero gate exit"
# — and keeps covering a fourth caller nobody has written yet.
# ---------------------------------------------------------------------------
echo
echo "--- Test 52 (#942): a FAILED summary read fails closed at EVERY reader call site"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_THREADS=$(make_threads_fixture '[]')
FIXTURE_ISSUE_COMMENTS=$(make_summary_issue_comments \
  "$(make_summary_body "$HEAD_SHA" "$SUMMARY_MAJOR_FINDING")")
AWK_COUNTER="$WORKDIR/awk-calls-52"
: >"$AWK_COUNTER"
# Same derivation as test 51: count the reader's runs on this fixture with
# nothing failing, so the indices below are measured rather than guessed.
CR_GATE_TEST_FAIL_SUMMARY_AWK_AFTER=9999 \
CR_GATE_TEST_AWK_COUNTER="$AWK_COUNTER" \
  FIXTURE_PR="$FIXTURE_PR" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
  run_gate "$SCRATCH" 99 owner/repo >/dev/null 2>&1 || true
TOTAL_AWK_52=$(cat "$AWK_COUNTER" 2>/dev/null || echo 0)
if [ "$TOTAL_AWK_52" -lt 2 ]; then
  fail "#942: expected the shared summary reader to run more than once on this fixture; counted $TOTAL_AWK_52 (the multi-site coverage below would be vacuous)"
fi
SITE_FAILURES_52=''
SITE_STANZA_MISDIAGNOSIS_52=''
IDX_52=0
while [ "$IDX_52" -lt "$TOTAL_AWK_52" ]; do
  : >"$AWK_COUNTER"
  set +e
  OUT=$(
    FIXTURE_PR="$FIXTURE_PR" \
    FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
    FIXTURE_THREADS="$FIXTURE_THREADS" \
    FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS" \
    CR_GATE_TEST_FAIL_SUMMARY_AWK_AFTER="$IDX_52" \
    CR_GATE_TEST_AWK_COUNTER="$AWK_COUNTER" \
      run_gate "$SCRATCH" 99 owner/repo 2>&1
  )
  RC=$?
  set -e
  if [ "$RC" = 0 ] || echo "$OUT" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
    SITE_FAILURES_52="$SITE_FAILURES_52 run$((IDX_52 + 1))(rc=$RC)"
  fi
  # Acceptance criterion 2: the classifier must not report an UNREADABLE
  # summary as one that "carries a non-benign outcome stanza". That message
  # names a specific, wrong diagnosis — an operator reading it goes looking
  # for a rate limit rather than for a broken read.
  if echo "$OUT" | grep -q "carries a non-benign outcome stanza"; then
    SITE_STANZA_MISDIAGNOSIS_52="$SITE_STANZA_MISDIAGNOSIS_52 run$((IDX_52 + 1))"
  fi
  IDX_52=$((IDX_52 + 1))
done
if [ -z "$SITE_FAILURES_52" ]; then
  pass "#942: a failed summary read fails closed at all $TOTAL_AWK_52 reader call sites, never 'unresolved: 0'"
else
  fail "#942: a failed summary read still reported zero blocking findings at:$SITE_FAILURES_52 (of $TOTAL_AWK_52 reader runs)"
fi
if [ -z "$SITE_STANZA_MISDIAGNOSIS_52" ]; then
  pass "#942: an unreadable summary is never misreported as carrying a non-benign outcome stanza"
else
  fail "#942: an unreadable summary was misdiagnosed as a non-benign outcome stanza at:$SITE_STANZA_MISDIAGNOSIS_52"
fi

# ---------------------------------------------------------------------------
# Test 53 (#942): the readers test 52 CANNOT reach.
#
# Test 52 fails the shared reader `summary_unfenced_numbered` at every one of
# its call sites, and its shim keys on that program's own emit, `NR, line`.
# That scoping is what makes it non-vacuous — and it is also a coverage
# boundary: the file's three OTHER awk programs and all five of its greps never
# run that string, so no index of test 52 can fail any of them. Each case below
# fails ONE such reader, and each carries a CONTROL run on the same fixture with
# nothing injected, so a green is measured against the verdict the gate reaches
# when the reader works rather than assumed.
#
# The greps are failed with rc 2 — grep's own ERROR — not rc 1. `|| true` is
# rc-blind and absorbs both identically, which is the whole defect: rc 2 is
# reachable on an invalid multibyte sequence or a bad locale, one of the exact
# production causes #942's body names for the awk death, and it makes grep
# print NOTHING, so the load-bearing `-gt 0` / `-n` guards read a manufactured
# empty result as an answer about the body.
# ---------------------------------------------------------------------------
echo
echo "--- Test 53 (#942): the pre-merge STRIP and the summary greps fail closed too"
SCRATCH=$(make_scratch_with_policy "$DEFAULT_POLICY")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA")
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_THREADS=$(make_threads_fixture '[]')
# A genuine 🟠 Major finding AND a genuine pre-merge check table, so the strip
# has a pair to act on and the graded body still carries something blocking.
STRIP_FIXTURE_BODY="$(make_summary_body "$HEAD_SHA" "$SUMMARY_MAJOR_FINDING

<!-- pre_merge_checks_walkthrough_start -->
| Docstring coverage | ⚠️ Warning | 12.00% is below the 80.00% threshold |
<!-- pre_merge_checks_walkthrough_end -->")"
FIXTURE_ISSUE_COMMENTS_53=$(make_summary_issue_comments "$STRIP_FIXTURE_BODY")

# The control: no injection at all. This fixture must actually GATE, or every
# case below would be asserting nonzero against a gate that was already red.
set +e
OUT_53_CONTROL=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS_53" \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC_53_CONTROL=$?
set -e
if [ "$RC_53_CONTROL" != 0 ] \
    && echo "$OUT_53_CONTROL" | grep -q "CodeRabbit blocking-tier unresolved: 1"; then
  pass "#942 control: the strip fixture gates on its 🟠 Major with every reader working"
else
  fail "#942 control: expected a nonzero exit reporting 1 unresolved blocking finding; got rc=$RC_53_CONTROL (the cases below would be vacuous)"
  echo "$OUT_53_CONTROL" | sed 's/^/      /' >&2
fi

# 53a — the pre-merge STRIP awk. Its output IS summary_strip_pre_merge_block's
# return value, so a dead awk yields an empty SUMMARY_SCAN and the caller's
# `[ -n "$SUMMARY_SCAN" ]` skips the whole grading block. errexit cannot rescue
# it: the call site is `SUMMARY_SCAN=$(…) || die 2`, and errexit is suppressed
# inside a command substitution on the left of an `||` list.
set +e
OUT_53A=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS_53" \
  CR_GATE_TEST_FAIL_AWK_PROGRAM='NR < sl' \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC_53A=$?
set -e
if [ "$RC_53A" != 0 ] \
    && ! echo "$OUT_53A" | grep -q "CodeRabbit blocking-tier unresolved: 0"; then
  pass "#942: a failed pre-merge-block STRIP fails closed, never 'unresolved: 0'"
else
  fail "#942: a failed pre-merge-block strip cleared the gate; got rc=$RC_53A"
  echo "$OUT_53A" | sed 's/^/      /' >&2
fi

# 53b — the commits-range grep in summary_names_head. On rc 2 `ranges` is
# empty, which `|| true` handed to `[ -n "$ranges" ] || return 1` as "this body
# names no commits range" — so the gate logged the specific claim "does not
# name <HEAD_SHA> as its commits-range end" about a body it never searched.
set +e
OUT_53B=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS_53" \
  CR_GATE_TEST_GREP_ERROR_ON='between [0-9a-f]{40}' \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC_53B=$?
set -e
if [ "$RC_53B" != 0 ] \
    && ! echo "$OUT_53B" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! echo "$OUT_53B" | grep -q "does not name $HEAD_SHA as its commits-range end"; then
  pass "#942: a grep ERROR on the commits-range scan fails closed, and is not reported as a stale summary"
else
  fail "#942: a grep error on the commits-range scan cleared the gate or was misdiagnosed as a stale summary; got rc=$RC_53B"
  echo "$OUT_53B" | sed 's/^/      /' >&2
fi

# 53c — the benign allow-list grep, shared by summary_stanzas_all_benign and
# summary_has_non_benign_stanza. On rc 2 the counts came back empty,
# `${total:-0}` manufactured the zero-stanza state the `-gt 0` guard watches
# for, and the caller logged "carries a non-benign outcome stanza" — the exact
# wrong diagnosis acceptance criterion 2 forbids, now reached through the grep
# rather than through the awk the PR hardened.
set +e
OUT_53C=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS_53" \
  CR_GATE_TEST_GREP_ERROR_ON='auto-generated comment: (summarize' \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC_53C=$?
set -e
if [ "$RC_53C" != 0 ] \
    && ! echo "$OUT_53C" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! echo "$OUT_53C" | grep -q "carries a non-benign outcome stanza"; then
  pass "#942: a grep ERROR on the benign stanza allow-list fails closed, and is not misdiagnosed as a non-benign stanza"
else
  fail "#942: a grep error on the benign stanza allow-list cleared the gate or was misdiagnosed as a non-benign stanza; got rc=$RC_53C"
  echo "$OUT_53C" | sed 's/^/      /' >&2
fi

# 53d — the stanza-opener COUNT grep on the line above it. Same manufactured
# zero-stanza state, reached one grep earlier, and the pattern (`.`) is not the
# allow-list one, so 53c cannot cover it.
set +e
OUT_53D=$(
  FIXTURE_PR="$FIXTURE_PR" \
  FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  FIXTURE_THREADS="$FIXTURE_THREADS" \
  FIXTURE_ISSUE_COMMENTS="$FIXTURE_ISSUE_COMMENTS_53" \
  CR_GATE_TEST_GREP_ERROR_ON='-c .' \
    run_gate "$SCRATCH" 99 owner/repo 2>&1
)
RC_53D=$?
set -e
if [ "$RC_53D" != 0 ] \
    && ! echo "$OUT_53D" | grep -q "CodeRabbit blocking-tier unresolved: 0" \
    && ! echo "$OUT_53D" | grep -q "carries a non-benign outcome stanza"; then
  pass "#942: a grep ERROR on the stanza-opener count fails closed, and is not misdiagnosed as a non-benign stanza"
else
  fail "#942: a grep error on the stanza-opener count cleared the gate or was misdiagnosed as a non-benign stanza; got rc=$RC_53D"
  echo "$OUT_53D" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
echo
echo "============================================"
echo "test_coderabbit_severity_gate.sh: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
