#!/usr/bin/env bash
# tests/test_resolve_pr_threads_staleness_pagination.sh
#
# Regression tests for the #573-item-2 staleness-floor pagination in
# scripts/resolve-pr-threads.sh.
#
# The bug: the thread-enumeration query fetches each thread's comments
# with `comments(last: 50)` — the newest 50. On a thread with more than
# 50 comments where the latest bot/reviewer RE-RAISE is followed by 50+
# agent replies, the window omits the re-raise, so
# latest_nonagent_created() falls back to an OLDER timestamp and
# --resolve-actioned treats a STALE fix/rebuttal as current action —
# resolving LIVE feedback and defeating the #564 fail-closed guarantee.
#
# The fix: threads whose allComments connection reports truncation
# (pageInfo.hasPreviousPage / totalCount > nodes) get a full
# cursor-paginated re-fetch (complete_thread_comments →
# fetch_all_thread_comments) before any staleness-sensitive
# classification. A re-fetch failure FAILS CLOSED: the thread is skipped
# (left unresolved), never resolved on incomplete data.
#
# Strategy mirrors tests/test_resolve_pr_threads_rationale_tag.sh: stub
# `gh` via PATH-prepend, capture argv to a side log, shape multi-page
# GraphQL fixtures, and assert on the mutations (or their absence).
# Fully offline; bash 3.2 portable.
#
# Cases:
#   1. Buried re-raise: the latest bot re-raise sits OUTSIDE the last-50
#      window (50 agent acks after it); a fix commit that predates the
#      re-raise must NOT resolve the thread (skip, exit 3).
#   2. Multi-page floor: a 160-comment thread whose true latest bot
#      comment sits on PAGE 2 of the full re-fetch; a fix commit that
#      post-dates it MUST resolve (pagination finds the correct floor
#      and addressed-elsewhere still classifies) — exit 0.
#   3. Pagination failure under --resolve-actioned: the re-fetch errors →
#      thread skipped (fail closed), no mutations, exit 3.
#   4. Pagination failure under --auto-resolve-bots: the resolve itself
#      still proceeds (blunt-mode contract, gated on the HEAD anchor),
#      but the tag falls back to the fail-safe deferred-to-followup
#      class instead of guessing from the truncated window.
#   5. Non-truncated thread: no re-fetch is issued at all (no extra API
#      cost; pre-#573 shape preserved).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/resolve-pr-threads.sh"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }

pass=0
fail=0

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# Fixture repo tree (same pattern as the rationale-tag test): copy the
# script so its $(dirname BASH_SOURCE)/.. manifest resolution lands on
# our fixture manifest, and ship no-op preflight/identity stubs.
FIXTURE_ROOT="$SCRATCH/repo"
mkdir -p "$FIXTURE_ROOT/scripts/lib"
cp "$SCRIPT" "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh"
cat > "$FIXTURE_ROOT/scripts/lib/preflight-helpers.sh" <<'STUB'
auto_source_preflight() { :; }
STUB
cat > "$FIXTURE_ROOT/scripts/identity-check.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FIXTURE_ROOT/scripts/identity-check.sh"
cat > "$FIXTURE_ROOT/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - name: test-consumer
    repo: test/consumer
    visibility: public
paths:
  - path: scripts/ci/
    type: kit
    consumers: all
YAML

# make_gh_stub <stub-path> <threads-file> <files-json> <commits-json>
#              <commit-files-map>
# Routes graphql calls on the recorded lastcall body:
#   addPullRequestReviewThreadReply → tag-reply success
#   resolveReviewThread             → resolve success
#   nodes(ids:                      → #564 readback (all requested = true)
#   node(id:                        → #573 thread-comments re-fetch; pages
#                                     served from $COMMENTS_PAGE1_FILE /
#                                     $COMMENTS_PAGE2_FILE (page 2 when the
#                                     cursor S2CURSOR2 is in argv); fails
#                                     when GH_STUB_FAIL_THREAD_COMMENTS=1
#   (else)                          → thread-enumeration fixture
make_gh_stub() {
  local stub_path="$1"
  local threads_file="$2"
  local files_json="$3"
  local commits_json="$4"
  local commit_files_map="${5:-{}}"
  cat > "$stub_path" <<GH_STUB
#!/usr/bin/env bash
echo "ARGV: \$*" >> "\$GH_ARGV_LOG"
__ARGS=("\$@")
__i=0
while [ "\$__i" -lt "\${#__ARGS[@]}" ]; do
  case "\${__ARGS[\$__i]}" in
    -F|--field)
      __next_i=\$((__i + 1))
      echo "FIELD: \${__ARGS[\$__next_i]}" >> "\$GH_ARGV_LOG"
      __i=\$((__i + 2)) ;;
    -f|--raw-field)
      __next_i=\$((__i + 1))
      echo "RAWFIELD: \${__ARGS[\$__next_i]}" >> "\$GH_ARGV_LOG"
      __i=\$((__i + 2)) ;;
    *) __i=\$((__i + 1)) ;;
  esac
done

case "\$1" in
  api)
    case "\$2" in
      graphql)
        if grep -q "addPullRequestReviewThreadReply" "\$GH_ARGV_LOG.lastcall"; then
          echo '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"C_kwT1"}}}}'
        elif grep -q "resolveReviewThread" "\$GH_ARGV_LOG.lastcall"; then
          echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
        elif grep -q "nodes(ids:" "\$GH_ARGV_LOG.lastcall"; then
          # #564 readback — confirm every requested id as resolved.
          __req=\$(grep -oE 'nodes\(ids: \[[^]]*\]' "\$GH_ARGV_LOG.lastcall" | head -1 | sed -E 's/^nodes\(ids: //')
          [ -z "\$__req" ] && __req='[]'
          printf '%s' "\$__req" | jq -c '{data:{nodes: map({id: ., isResolved: true})}}'
        elif grep -q "node(id:" "\$GH_ARGV_LOG.lastcall"; then
          # #573 thread-comments re-fetch.
          if [ -n "\${GH_STUB_FAIL_THREAD_COMMENTS:-}" ]; then
            echo "simulated thread-comments GraphQL failure" >&2
            exit 1
          fi
          if grep -q "cursor=S2CURSOR2" "\$GH_ARGV_LOG.lastcall"; then
            cat "\$COMMENTS_PAGE2_FILE"
          else
            cat "\$COMMENTS_PAGE1_FILE"
          fi
        else
          cat "$threads_file"
        fi
        ;;
      "repos/"*"/pulls/"*"/files"*)
        cat <<'JSON_FILES'
${files_json}
JSON_FILES
        ;;
      "repos/"*"/pulls/"*"/commits"*)
        cat <<'JSON_COMMITS'
${commits_json}
JSON_COMMITS
        ;;
      "repos/"*"/commits/"*)
        __sha="\${2##*/}"
        printf '%s' '${commit_files_map}' | jq -c --arg s "\$__sha" '.[\$s] // []'
        ;;
      "repos/"*"/pulls/"*)
        echo "HEADCURRENT"
        ;;
      *)
        echo "{}" ;;
    esac
    ;;
  repo)
    printf '{"nameWithOwner":"test/repo"}\n'
    ;;
  *)
    exit 0
    ;;
esac
exit 0
GH_STUB
  chmod +x "$stub_path"
}

make_gh_wrapper() {
  local wrapper_path="$1"
  local real_stub="$2"
  cat > "$wrapper_path" <<WRAP_STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "\$GH_ARGV_LOG.lastcall"
exec "$real_stub" "\$@"
WRAP_STUB
  chmod +x "$wrapper_path"
}

# build_thread_fixture <thread-id> <path> <full-comments-json> <out-file>
# Builds the ENUMERATION fixture: the thread's allComments carries only
# the newest-50 window of the full comment list, plus the truncation
# signals (totalCount + pageInfo.hasPreviousPage) the projection reads.
build_thread_fixture() {
  local thread_id="$1"
  local anchor_path="$2"
  local full_json="$3"
  local out_file="$4"
  jq -nc --argjson full "$full_json" \
     --arg id "$thread_id" --arg p "$anchor_path" '
    ($full | length) as $n |
    {data:{repository:{pullRequest:{reviewThreads:{
      totalCount: 1,
      pageInfo: {hasNextPage: false, endCursor: null},
      nodes: [{
        id: $id, isResolved: false, isOutdated: false,
        commentsFirst: {nodes: [{
          author: $full[0].author, path: $p,
          body: $full[0].body, createdAt: $full[0].createdAt
        }]},
        commentsLast: {nodes: [{commit: {oid: "HEADCURRENT"}}]},
        allComments: {
          totalCount: $n,
          pageInfo: {hasPreviousPage: ($n > 50)},
          nodes: (if $n > 50 then $full[-50:] else $full end)
        }
      }]
    }}}}}' > "$out_file"
}

# ─────────────────────────────────────────────────────────────────────
# Test 1 (#573 item 2): a re-raise buried under 50 agent replies must
# not be resolved over by a STALE fix commit. Full thread (60 comments):
#   idx 0      bot finding            @ 2026-01-01 (T0)
#   idx 1-8    agent acks (<30 chars) @ 2026-01-02
#   idx 9      bot RE-RAISE           @ 2026-01-03 (T2)
#   idx 10-59  agent acks (<30 chars) @ 2026-01-03+ (fill the window)
# Agent fix commit @ 2026-01-02 (T1: after T0, BEFORE T2) touching the
# anchored file. Pre-fix, the last-50 window held only agent acks, so
# the floor fell back to T0 and the T1 commit classified
# addressed-elsewhere → the live re-raise was resolved. Post-fix, the
# paginated re-fetch restores the T2 floor → not actioned → skip.
# ─────────────────────────────────────────────────────────────────────
echo "Test 1: buried re-raise — stale fix commit must not resolve (#573)"

FULL_S1=$(jq -nc '
  [{author:{login:"coderabbitai"},body:"Original finding on scripts/foo.sh — buffer handling is wrong.",databaseId:1000,createdAt:"2026-01-01T00:00:00Z"}]
  + [range(1;9) | {author:{login:"nathanpayne-claude"},body:("ack " + tostring),databaseId:(1000+.),createdAt:"2026-01-02T01:00:00Z"}]
  + [{author:{login:"coderabbitai"},body:"Re-raise: the fix did not address this — still broken.",databaseId:1100,createdAt:"2026-01-03T00:00:00Z"}]
  + [range(10;60) | {author:{login:"nathanpayne-claude"},body:("ack " + tostring),databaseId:(1100+.),createdAt:"2026-01-03T02:00:00Z"}]
')
build_thread_fixture "PRT_S1" "scripts/foo.sh" "$FULL_S1" "$SCRATCH/threads_s1.json"
jq -nc --argjson full "$FULL_S1" \
  '{data:{node:{comments:{totalCount:60,pageInfo:{hasNextPage:false,endCursor:null},nodes:$full}}}}' \
  > "$SCRATCH/comments_s1_page1.json"
FILES_S1='["scripts/foo.sh"]'
COMMITS_S1='[{"sha":"fix1111111","login":"nathanpayne-claude","date":"2026-01-02T00:00:00Z"}]'
CFILES_S1='{"fix1111111":["scripts/foo.sh"]}'

GH_ARGV_LOG="$SCRATCH/t1.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$SCRATCH/threads_s1.json" "$FILES_S1" "$COMMITS_S1" "$CFILES_S1"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  COMMENTS_PAGE1_FILE="$SCRATCH/comments_s1_page1.json" \
  COMMENTS_PAGE2_FILE="$SCRATCH/comments_s1_page1.json" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (not demonstrably actioned:' <<<"$out" \
   && grep -q 'node(id:' "$GH_ARGV_LOG" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: buried re-raise restored via pagination — stale fix not actioned, thread left unresolved, exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: stale fix resolved over a buried re-raise (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 2 (#573 item 2): multi-page re-fetch finds the true floor on
# PAGE 2, and a genuinely-actioned thread still resolves. Full thread
# (160 comments → two re-fetch pages of 100 + 60):
#   idx 0        bot finding    @ 2026-01-01 (T0)
#   idx 1-104    agent acks     @ 2026-01-02
#   idx 105      bot RE-RAISE   @ 2026-01-05 (T2 — on re-fetch page 2,
#                               and outside the last-50 window [110:160))
#   idx 106-159  agent acks     @ 2026-01-05
# Agent fix commit @ 2026-01-06 (T3 > T2) touching the anchored file →
# addressed-elsewhere → resolved + readback-confirmed, exit 0.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 2: page-2 floor — genuinely-actioned thread resolves (#573)"

FULL_S2=$(jq -nc '
  [{author:{login:"coderabbitai"},body:"Original finding on docs/big-thread.md — section is misleading.",databaseId:2000,createdAt:"2026-01-01T00:00:00Z"}]
  + [range(1;105) | {author:{login:"nathanpayne-claude"},body:("ack " + tostring),databaseId:(2000+.),createdAt:"2026-01-02T00:00:00Z"}]
  + [{author:{login:"coderabbitai"},body:"Re-raise: previous fix incomplete — please redo.",databaseId:2200,createdAt:"2026-01-05T00:00:00Z"}]
  + [range(106;160) | {author:{login:"nathanpayne-claude"},body:("ack " + tostring),databaseId:(2200+.),createdAt:"2026-01-05T12:00:00Z"}]
')
build_thread_fixture "PRT_S2" "docs/big-thread.md" "$FULL_S2" "$SCRATCH/threads_s2.json"
jq -nc --argjson full "$FULL_S2" \
  '{data:{node:{comments:{totalCount:160,pageInfo:{hasNextPage:true,endCursor:"S2CURSOR2"},nodes:$full[0:100]}}}}' \
  > "$SCRATCH/comments_s2_page1.json"
jq -nc --argjson full "$FULL_S2" \
  '{data:{node:{comments:{totalCount:160,pageInfo:{hasNextPage:false,endCursor:null},nodes:$full[100:160]}}}}' \
  > "$SCRATCH/comments_s2_page2.json"
FILES_S2='["docs/big-thread.md"]'
COMMITS_S2='[{"sha":"fix2222222","login":"nathanpayne-claude","date":"2026-01-06T00:00:00Z"}]'
CFILES_S2='{"fix2222222":["docs/big-thread.md"]}'

GH_ARGV_LOG="$SCRATCH/t2.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$SCRATCH/threads_s2.json" "$FILES_S2" "$COMMITS_S2" "$CFILES_S2"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  COMMENTS_PAGE1_FILE="$SCRATCH/comments_s2_page1.json" \
  COMMENTS_PAGE2_FILE="$SCRATCH/comments_s2_page2.json" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 0 ] \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\] addressed by commit fix2222' "$GH_ARGV_LOG" \
   && grep -q 'cursor=S2CURSOR2' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: two-page re-fetch walked (cursor=S2CURSOR2), floor on page 2 honored, thread resolved + confirmed"
else
  fail=$((fail + 1))
  echo "  FAIL: multi-page re-fetch did not resolve the actioned thread (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 3 (#573 item 2): pagination FAILURE fails closed under
# --resolve-actioned. Same truncated thread as Test 1, but the stub
# errors on the node(id:) re-fetch → the thread must be SKIPPED (no
# tag reply, no resolve mutation), exit 3.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 3: re-fetch failure → thread skipped, fail closed (#573)"

GH_ARGV_LOG="$SCRATCH/t3.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$SCRATCH/threads_s1.json" "$FILES_S1" "$COMMITS_S1" "$CFILES_S1"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  GH_STUB_FAIL_THREAD_COMMENTS=1 \
  COMMENTS_PAGE1_FILE="$SCRATCH/comments_s1_page1.json" \
  COMMENTS_PAGE2_FILE="$SCRATCH/comments_s1_page1.json" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (comment list incomplete' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: pagination error → thread skipped with no mutations, exit 3 (fail closed)"
else
  fail=$((fail + 1))
  echo "  FAIL: pagination error did not fail closed (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 4 (#573 item 2): pagination failure under --auto-resolve-bots.
# The blunt mode still resolves (its contract is HEAD-anchor-gated, not
# classification-gated), but the tag must fall back to the fail-safe
# deferred-to-followup class — never an "actioned" class guessed from a
# truncated window that may hide a live re-raise.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 4: re-fetch failure under --auto-resolve-bots → fail-safe deferred tag (#573)"

GH_ARGV_LOG="$SCRATCH/t4.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$SCRATCH/threads_s1.json" "$FILES_S1" "$COMMITS_S1" "$CFILES_S1"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  GH_STUB_FAIL_THREAD_COMMENTS=1 \
  COMMENTS_PAGE1_FILE="$SCRATCH/comments_s1_page1.json" \
  COMMENTS_PAGE2_FILE="$SCRATCH/comments_s1_page1.json" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 0 ] \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: deferred-to-followup\]' "$GH_ARGV_LOG" \
   && ! grep -q 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\]' "$GH_ARGV_LOG" \
   && grep -q 'WARN: comment pagination incomplete' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: blunt mode still resolves but tags the fail-safe deferred-to-followup class + WARN"
else
  fail=$((fail + 1))
  echo "  FAIL: truncated-window class was trusted under --auto-resolve-bots (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 5 (#573 item 2): a NON-truncated thread must not trigger the
# re-fetch at all — the last-50 window already covers the whole thread,
# so adding per-thread node(id:) calls would be pure API cost. The
# thread is a plain actioned (rebuttal-recorded) case and must resolve
# exactly as before the #573 change.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 5: non-truncated thread — no re-fetch issued, pre-#573 behavior intact"

THREADS_S5="$SCRATCH/threads_s5.json"
cat > "$THREADS_S5" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_S5","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/small.md","body":"Small-thread finding","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"totalCount":2,"pageInfo":{"hasPreviousPage":false},"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Small-thread finding","databaseId":5001,"createdAt":"2026-01-01T00:00:00Z"},
     {"author":{"login":"nathanpayne-claude"},"body":"Disagree — this is intentional; see #200 for the full context.","databaseId":5002,"createdAt":"2026-01-02T00:00:00Z"}
   ]}
  }
]}}}}}
JSON
FILES_S5='[]'
COMMITS_S5='[]'

GH_ARGV_LOG="$SCRATCH/t5.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_S5" "$FILES_S5" "$COMMITS_S5"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  COMMENTS_PAGE1_FILE="$SCRATCH/comments_s1_page1.json" \
  COMMENTS_PAGE2_FILE="$SCRATCH/comments_s1_page1.json" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 0 ] \
   && ! grep -q 'node(id:' "$GH_ARGV_LOG" \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: rebuttal-recorded\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: complete window → no node(id:) re-fetch; rebuttal-recorded thread resolved as before"
else
  fail=$((fail + 1))
  echo "  FAIL: non-truncated thread behavior changed (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "test_resolve_pr_threads_staleness_pagination: PASS ($pass tests)"
  exit 0
else
  echo "test_resolve_pr_threads_staleness_pagination: FAIL ($fail of $((pass + fail)) tests)" >&2
  exit 1
fi
