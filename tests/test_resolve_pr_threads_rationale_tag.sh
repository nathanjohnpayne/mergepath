#!/usr/bin/env bash
# tests/test_resolve_pr_threads_rationale_tag.sh
#
# Tests the mergepath#305 `[mergepath-resolve: <class>] <rationale>`
# tag-emission flow in scripts/resolve-pr-threads.sh
# --auto-resolve-bots.
#
# Strategy: stub `gh` via PATH-prepend so the script's mutation calls
# (addPullRequestReviewThreadReply for the tag, resolveReviewThread
# for the resolve) are captured into a side log file we can inspect.
# Each case shapes the GraphQL response so derive_tag_class lands on
# the expected class, then asserts the captured argv contains the
# matching `[mergepath-resolve: <class>]` tag body.
#
# Tag format MUST match exactly what the v1 rollup classifier's
# regex in scripts/lib/daily-feedback-rollup-helpers.sh expects:
#   \[mergepath-resolve:[[:space:]]*[a-z-]+[[:space:]]*\]
#
# Cases (matching the spec's class taxonomy):
#   1. addressed-elsewhere  fix-commit by agent author after createdAt
#                           touching the comment's anchored file
#   2. canonical-coverage   path matches a canonical entry in
#                           .mergepath-sync.yml
#   3. nitpick-noted        Nitpick severity, no stronger signal
#   4. deferred-to-followup default fallback
#   5. --rationale override emits deferred-to-followup with custom text
#   6. --no-tag-reply suppresses tag emission while still resolving
#   7. rebuttal-recorded    ≥30-char agent-authored reply on thread

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/resolve-pr-threads.sh"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }

pass=0
fail=0

# tag_before_resolve <argv-log> → 0 if reply call appears before resolve
# call in the cumulative argv log, 1 otherwise. The script's contract
# is "post tag reply BEFORE resolveReviewThread"; without this check,
# tests would pass even if the helper accidentally inverted the order
# (CodeRabbit Major r2 on #308). Uses grep -n line numbers because the
# argv log preserves call sequence by append-only writes.
tag_before_resolve() {
  local log="$1"
  local reply_line resolve_line
  reply_line=$(grep -n 'addPullRequestReviewThreadReply' "$log" 2>/dev/null | head -1 | cut -d: -f1)
  resolve_line=$(grep -n 'resolveReviewThread' "$log" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -z "$reply_line" ] || [ -z "$resolve_line" ]; then
    return 1
  fi
  [ "$reply_line" -lt "$resolve_line" ]
}

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# Build a fixture .mergepath-sync.yml the script will read for the
# canonical-coverage classification. We point the script at this
# fixture by faking REPO_ROOT_FOR_MANIFEST via a symlink-style
# wrapper. The simplest path: copy the real script into the
# fixture tree and run it from there, so its
# `$(dirname BASH_SOURCE)/..` resolution picks up our manifest.
FIXTURE_ROOT="$SCRATCH/repo"
mkdir -p "$FIXTURE_ROOT/scripts/lib" "$FIXTURE_ROOT/scripts/ci" "$FIXTURE_ROOT/tests"
cp "$SCRIPT" "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh"
# The script auto-sources scripts/lib/preflight-helpers.sh if present;
# ship a no-op stub so the source line doesn't fail in the fixture.
cat > "$FIXTURE_ROOT/scripts/lib/preflight-helpers.sh" <<'STUB'
auto_source_preflight() { :; }
STUB
# Also ship a stub identity-check.sh that always passes (we test
# tag emission, not identity verification — that has its own suite).
cat > "$FIXTURE_ROOT/scripts/identity-check.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FIXTURE_ROOT/scripts/identity-check.sh"

# Fixture manifest — only the entries the test asserts against.
cat > "$FIXTURE_ROOT/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - name: test-consumer
    repo: test/consumer
    visibility: public
paths:
  - path: scripts/resolve-pr-threads.sh
    type: canonical
    consumers: all
  - path: scripts/ci/
    type: kit
    consumers: all
YAML

# Common gh stub. Routes by ($1, $2) and the rest of argv:
#   `gh api graphql -f query=...` → branch on query body for resolveReviewThread / addPullRequestReviewThreadReply / reviewThreads
#   `gh api repos/.../pulls/N` → HEAD oid
#   `gh api repos/.../pulls/N/files?...` → PR file list
#   `gh api repos/.../pulls/N/commits?...` → PR commits
#   `gh repo view --json nameWithOwner` → fixture repo slug
make_gh_stub() {
  local stub_path="$1"
  local threads_json="$2"
  local files_json="$3"
  local commits_json="$4"
  cat > "$stub_path" <<GH_STUB
#!/usr/bin/env bash
echo "ARGV: \$*" >> "\$GH_ARGV_LOG"
# Capture the body of any -F (typed) field so we can grep for the
# mergepath-resolve tag in the addPullRequestReviewThreadReply body
# field. Iterate a COPY of argv via an indexed array — shifting the
# real \$@ here would empty it before the case statement below can
# dispatch on \$1/\$2.
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
        # Pull out the query body from argv (already logged above);
        # branch on substring matches.
        if grep -q "addPullRequestReviewThreadReply" "\$GH_ARGV_LOG.lastcall"; then
          # Tag-reply mutation — return a minimal success response.
          echo '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"C_kwT1"}}}}'
        elif grep -q "resolveReviewThread" "\$GH_ARGV_LOG.lastcall"; then
          echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
        else
          # reviewThreads pagination query.
          cat <<'JSON_THREADS'
${threads_json}
JSON_THREADS
        fi
        ;;
      "repos/"*"/pulls/"*"/files"*)
        # The script calls this with --jq '[.[].filename]' which
        # transforms the API response to a flat list of paths. Our
        # stub doesn't actually parse --jq, so we return the
        # already-transformed shape (a JSON array of path strings).
        cat <<'JSON_FILES'
${files_json}
JSON_FILES
        ;;
      "repos/"*"/pulls/"*"/commits"*)
        # Same shape note as /files: stub returns the already-jq-
        # transformed shape (array of {sha,login,date} objects)
        # because the script reads --jq output, not raw API JSON.
        cat <<'JSON_COMMITS'
${commits_json}
JSON_COMMITS
        ;;
      "repos/"*"/pulls/"*)
        # HEAD oid fetch — the script calls this with --jq .head.sha
        # and captures stdout; the stub doesn't actually parse --jq,
        # so we return the bare sha directly. Same pattern the
        # existing tests in scripts/ci/check_resolve_pr_threads use.
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

# The stub uses .lastcall to remember the most-recent call's argv
# (so it can branch on which graphql mutation was sent). A second
# pre-hook stub wraps the main one to populate it.
make_gh_wrapper() {
  local wrapper_path="$1"
  local real_stub="$2"
  cat > "$wrapper_path" <<WRAP_STUB
#!/usr/bin/env bash
# Capture this call's argv into .lastcall before dispatching to the
# real stub, so the real stub can branch on which mutation was sent.
printf '%s\n' "\$*" > "\$GH_ARGV_LOG.lastcall"
exec "$real_stub" "\$@"
WRAP_STUB
  chmod +x "$wrapper_path"
}

# ─────────────────────────────────────────────────────────────────────
# Test 1: helper detects fix-commit → emits addressed-elsewhere
# ─────────────────────────────────────────────────────────────────────
echo "Test 1: addressed-elsewhere class (fix-commit detection)"

# Thread: comment created 2026-01-01, anchored at scripts/foo.sh.
# PR files include scripts/foo.sh. PR commits include one by
# nathanpayne-claude on 2026-01-02 (after createdAt).
THREADS_T1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_1","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"scripts/foo.sh","body":"Some finding","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Some finding","databaseId":1001}]}
  }
]}}}}}'
FILES_T1='["scripts/foo.sh","scripts/bar.sh"]'
COMMITS_T1='[{"sha":"abc1234567","login":"nathanpayne-claude","date":"2026-01-02T00:00:00Z"}]'

GH_ARGV_LOG="$SCRATCH/t1.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T1" "$FILES_T1" "$COMMITS_T1"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG" && grep -q 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: tag body contains [mergepath-resolve: addressed-elsewhere]"
else
  fail=$((fail + 1))
  echo "  FAIL: addressed-elsewhere tag not emitted (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# Regression: synth_rationale's PR_COMMITS_CACHE must be populated
# in the parent shell so the addressed-elsewhere rationale cites
# the SPECIFIC matched commit SHA instead of falling back to the
# generic "addressed by a follow-up commit on this PR" text. If
# fetch_pr_tag_data only runs inside derive_tag_class's command-
# substitution subshell, synth_rationale (also subshelled) sees an
# empty PR_COMMITS_CACHE → emits `[: : integer expression expected`
# on its commit_count loop guard → silently degrades to the generic
# rationale. nathanpayne-codex Phase 4b r4 on #308 reproduced this
# with a page-2 files fixture; gate added at the call site by
# warming the cache in the parent shell before the subshells.
if [ "$rc" -eq 0 ] \
   && ! grep -q 'integer expression expected' <<<"$out" \
   && grep -q 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\] addressed by commit abc1234' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: addressed-elsewhere rationale cites matched commit (no subshell-cache regression)"
else
  fail=$((fail + 1))
  echo "  FAIL: addressed-elsewhere rationale degraded — subshell-cache regression?" >&2
  echo "    expected rationale: 'addressed by commit abc1234 (touching ...)'" >&2
  echo "    script output (looking for 'integer expression expected'):" >&2
  echo "$out" | grep -E '(integer expression|abc1234|follow-up commit)' | sed 's/^/      /' >&2 || true
  echo "    captured tag-reply field:" >&2
  grep 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\]' "$GH_ARGV_LOG" | sed 's/^/      /' >&2 || true
fi

# ─────────────────────────────────────────────────────────────────────
# Test 2: canonical-coverage when path matches manifest
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 2: canonical-coverage class (path in .mergepath-sync.yml)"

# scripts/resolve-pr-threads.sh IS in the fixture manifest as canonical.
THREADS_T2='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_2","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"scripts/resolve-pr-threads.sh","body":"Some finding","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Some finding","databaseId":2001}]}
  }
]}}}}}'
FILES_T2='["scripts/resolve-pr-threads.sh"]'
COMMITS_T2='[]'

GH_ARGV_LOG="$SCRATCH/t2.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T2" "$FILES_T2" "$COMMITS_T2"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG" && grep -q 'FIELD: body=\[mergepath-resolve: canonical-coverage\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: tag body contains [mergepath-resolve: canonical-coverage]"
else
  fail=$((fail + 1))
  echo "  FAIL: canonical-coverage tag not emitted (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 3: nitpick-noted on Nitpick severity, no fix, no canonical path
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 3: nitpick-noted class (Nitpick severity, no other signals)"

# Path NOT in manifest. Body carries CodeRabbit Nitpick badge.
# No commits (empty PR_COMMITS_CACHE).
THREADS_T3='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_3","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/random.md","body":"_🧹 Nitpick (assertive)_ minor wording issue","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"_🧹 Nitpick (assertive)_ minor wording issue","databaseId":3001}]}
  }
]}}}}}'
FILES_T3='[]'
COMMITS_T3='[]'

GH_ARGV_LOG="$SCRATCH/t3.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T3" "$FILES_T3" "$COMMITS_T3"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG" && grep -q 'FIELD: body=\[mergepath-resolve: nitpick-noted\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: tag body contains [mergepath-resolve: nitpick-noted]"
else
  fail=$((fail + 1))
  echo "  FAIL: nitpick-noted tag not emitted (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 4: deferred-to-followup default fallback
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 4: deferred-to-followup class (default fallback)"

# Path NOT in manifest. Body has no severity markers. No commits.
# No agent reply. → falls through to deferred-to-followup.
THREADS_T4='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_4","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/random.md","body":"Some opaque finding without a badge","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Some opaque finding without a badge","databaseId":4001}]}
  }
]}}}}}'
FILES_T4='[]'
COMMITS_T4='[]'

GH_ARGV_LOG="$SCRATCH/t4.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T4" "$FILES_T4" "$COMMITS_T4"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG" && grep -q 'FIELD: body=\[mergepath-resolve: deferred-to-followup\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: tag body contains [mergepath-resolve: deferred-to-followup]"
else
  fail=$((fail + 1))
  echo "  FAIL: deferred-to-followup tag not emitted (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 5: --rationale override emits deferred-to-followup with the
#         custom rationale text appended verbatim.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 5: --rationale override (deferred-to-followup + custom text)"

# Same thread as Test 2 (canonical path) — would normally classify
# as canonical-coverage; the override must beat the auto-class.
# FILES_T5 mirrors FILES_T2 ("scripts/resolve-pr-threads.sh") so the
# would-be auto-class actually evaluates to canonical-coverage and
# the test genuinely exercises --rationale's precedence over the
# ladder. With an empty FILES_T5 the auto-class would fall through
# to deferred-to-followup anyway, making the override untestable.
THREADS_T5="$THREADS_T2"
FILES_T5='["scripts/resolve-pr-threads.sh"]'
COMMITS_T5='[]'

GH_ARGV_LOG="$SCRATCH/t5.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T5" "$FILES_T5" "$COMMITS_T5"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

CUSTOM_RATIONALE="P2 noted; deferred to mergepath canonical follow-up #280"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots \
    --rationale "$CUSTOM_RATIONALE" 2>&1
)
rc=$?
set -e

# Both the class and the custom rationale must appear in the SAME
# tag-reply field. The stub log writes one `FIELD:` line per -F arg
# (the body is one such line: `FIELD: body=[mergepath-resolve: deferred-to-followup] P2 noted; ...`).
if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG" && grep -qF "FIELD: body=[mergepath-resolve: deferred-to-followup] $CUSTOM_RATIONALE" "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: override emitted deferred-to-followup tag with custom rationale text"
else
  fail=$((fail + 1))
  echo "  FAIL: rationale override not emitted as expected (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 6: --no-tag-reply suppresses the addPullRequestReviewThreadReply
#         mutation entirely (resolve still runs).
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 6: --no-tag-reply suppresses tag emission"

GH_ARGV_LOG="$SCRATCH/t6.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T4" "$FILES_T4" "$COMMITS_T4"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots --no-tag-reply 2>&1
)
rc=$?
set -e

# Tightened assertions (CodeRabbit Major r2 on #308):
#   - rc == 0 — script exited cleanly
#   - addPullRequestReviewThreadReply mutation NEVER ran — proves
#     reply path is fully short-circuited (the prior body-text check
#     was weaker: a reply with a non-tag body would have slipped past)
#   - resolveReviewThread mutation DID run — proves "suppress tag,
#     still resolve" contract
if [ "$rc" -eq 0 ] \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG" \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: --no-tag-reply skipped reply mutation and still resolved thread"
else
  fail=$((fail + 1))
  echo "  FAIL: --no-tag-reply behavior incorrect (rc=$rc, missing suppression or resolve)" >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 7: rebuttal-recorded — ≥30-char agent-authored reply on the
#         thread bumps the class above nitpick / deferred-to-followup
#         when no addressed-elsewhere/canonical signal applies.
#         (CodeRabbit Major on #308 — the ladder's rebuttal step had
#         no fixture coverage before.)
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 7: rebuttal-recorded class (≥30-char agent reply on thread)"

# Path NOT in manifest, no commits, but allComments has an
# agent-authored reply ≥30 chars. The reply MUST be authored by an
# agent identity (nathanpayne-claude / -codex / -cursor) — the
# bot-author of the original comment is skipped (index 0).
THREADS_T7='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_7","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/notes.md","body":"Some non-canonical finding","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Some non-canonical finding","databaseId":7001},
     {"author":{"login":"nathanpayne-claude"},"body":"Disagree — this is intentional for the propagation path; see #200 for context.","databaseId":7002}
   ]}
  }
]}}}}}'
FILES_T7='[]'
COMMITS_T7='[]'

GH_ARGV_LOG="$SCRATCH/t7.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T7" "$FILES_T7" "$COMMITS_T7"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG" && grep -q 'FIELD: body=\[mergepath-resolve: rebuttal-recorded\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: tag body contains [mergepath-resolve: rebuttal-recorded]"
else
  fail=$((fail + 1))
  echo "  FAIL: rebuttal-recorded tag not emitted (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 8 (#467): templated-render class survives a SCALAR `consumers:
# all` templated entry. The pre-fix fetch_manifest_templated_dests did
# `.consumers // [] | map(...)`, which on the scalar `all` tried to map
# over a string — a yq error that (under `|| true`) blanked the WHOLE
# templated-dest cache, so NO templated dest classified as
# templated-render. Here a thread anchored on a templated `dest:` whose
# entry is `consumers: all` must classify as templated-render.
#
# This test REWRITES the shared fixture manifest, so it must run LAST
# (all earlier tests have already executed against the original
# manifest). It adds a second consumer whose repo is `test/repo` so the
# `consumers: all` set resolves to include the --repo under test.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 8: templated-render class on a scalar consumers: all templated dest"

cat > "$FIXTURE_ROOT/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - name: test-consumer
    repo: test/consumer
    visibility: public
  - name: this-repo
    repo: test/repo
    visibility: public
paths:
  - path: scripts/resolve-pr-threads.sh
    type: canonical
    consumers: all
  - path: scripts/ci/
    type: kit
    consumers: all
  - path: examples/foo.tpl
    type: templated
    dest: rendered/foo.cfg
    consumers: all
YAML

# Thread anchored on the templated DEST (not a .path entry, so step-1
# canonical-coverage does not fire — only step-1b templated-render).
THREADS_T8='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_8","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"rendered/foo.cfg","body":"A finding on the rendered output","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"A finding on the rendered output","databaseId":8001}]}
  }
]}}}}}'
FILES_T8='["rendered/foo.cfg"]'
COMMITS_T8='[]'

GH_ARGV_LOG="$SCRATCH/t8.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T8" "$FILES_T8" "$COMMITS_T8"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG" && grep -q 'FIELD: body=\[mergepath-resolve: templated-render\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: tag body contains [mergepath-resolve: templated-render] (scalar consumers: all resolved)"
else
  fail=$((fail + 1))
  echo "  FAIL: templated-render not emitted for scalar consumers: all dest (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "test_resolve_pr_threads_rationale_tag: PASS ($pass tests)"
  exit 0
else
  echo "test_resolve_pr_threads_rationale_tag: FAIL ($fail of $((pass + fail)) tests)" >&2
  exit 1
fi
