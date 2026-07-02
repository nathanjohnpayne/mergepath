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
#   2. canonical routing → deferred-to-followup: a NON-ACTIONED thread
#                           on a manifest path is an explicit deferral
#                           and must resurface in the daily rollup,
#                           which SKIPS routing classes (#616 finding
#                           3509930338); the routing context is logged
#                           as an INFO line, the recorded class is
#                           deferred-to-followup
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
  # #565: per-commit file map (sha -> [filenames]) for the
  # addressed-elsewhere commit_touches_file check. Defaults to empty so the
  # many call sites that never reach a per-commit fetch need not pass it.
  local commit_files_map="${5:-{}}"
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
        elif grep -q "nodes(ids:" "\$GH_ARGV_LOG.lastcall"; then
          # #564 post-resolve readback. The script re-reads each resolved
          # thread via the top-level nodes(ids:) lookup. Return ONLY the ids
          # the readback query actually requested (parsed from the recorded
          # argv) so a wrong nodes(ids:) list built by the script is caught
          # — CodeRabbit on #565 — each resolved unless
          # GH_STUB_READBACK_UNRESOLVED names it (which exercises the
          # fail-closed readback path).
          __req=\$(grep -oE 'nodes\(ids: \[[^]]*\]' "\$GH_ARGV_LOG.lastcall" | head -1 | sed -E 's/^nodes\(ids: //')
          [ -z "\$__req" ] && __req='[]'
          cat <<'JSON_READBACK' | jq -c --argjson req "\$__req" --arg kf "\${GH_STUB_READBACK_UNRESOLVED:-}" '{data:{nodes:[.data.repository.pullRequest.reviewThreads.nodes[] | select(.id as \$i | \$req | index(\$i)) | {id, isResolved: (if .id == \$kf then false else true end)}]}}'
${threads_json}
JSON_READBACK
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
      "repos/"*"/commits/"*)
        # #565 per-commit files: extract the sha (last path segment) and
        # return its file list from the provided sha->[filenames] map (or []
        # if absent). The script calls this with --jq '[.files[].filename]',
        # so (like the /files and /commits stubs) return the already-
        # transformed array of filenames directly.
        __sha="\${2##*/}"
        printf '%s' '${commit_files_map}' | jq -c --arg s "\$__sha" '.[\$s] // []'
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
# #565: the fix commit abc1234567 must be shown to TOUCH scripts/foo.sh for
# addressed-elsewhere to hold (per-commit file verification).
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T1" "$FILES_T1" "$COMMITS_T1" '{"abc1234567":["scripts/foo.sh"]}'
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
# Test 2: a NON-ACTIONED thread on a canonical manifest path is recorded
# as deferred-to-followup, NOT canonical-coverage (#616 finding
# 3509930338). --auto-resolve-bots is THE explicit-deferral tool and the
# daily rollup SKIPS routing classes — tagging the routing class here
# would bury the deliberate deferral so it never resurfaces. The ladder
# still derives canonical-coverage (locking the manifest classification,
# which the INFO line surfaces); the disposition of record is deferred.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 2: canonical-path non-actioned deferral records deferred-to-followup (#616)"

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

if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG" \
   && grep -q 'INFO: routing class canonical-coverage recorded as deferred-to-followup' <<<"$out" \
   && grep -q 'FIELD: body=\[mergepath-resolve: deferred-to-followup\]' "$GH_ARGV_LOG" \
   && ! grep -q 'FIELD: body=\[mergepath-resolve: canonical-coverage\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: canonical routing logged (INFO) but the recorded tag is deferred-to-followup"
else
  fail=$((fail + 1))
  echo "  FAIL: non-actioned canonical-path thread not recorded as deferred-to-followup (rc=$rc)" >&2
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
# Post-#616 (finding 3509930338) the CLASSIFICATION is asserted via the
# INFO line ("routing class templated-render recorded as
# deferred-to-followup") and the recorded tag is deferred-to-followup:
# a non-actioned templated-dest thread auto-resolved here is an explicit
# deferral, and routing classes are rollup-skip classes. A blanked
# templated-dest cache (the #467 regression this test locks) would skip
# the INFO line entirely and fall straight to deferred-to-followup.
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

if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG" \
   && grep -q 'INFO: routing class templated-render recorded as deferred-to-followup' <<<"$out" \
   && grep -q 'FIELD: body=\[mergepath-resolve: deferred-to-followup\]' "$GH_ARGV_LOG" \
   && ! grep -q 'FIELD: body=\[mergepath-resolve: templated-render\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: templated-render classified (scalar consumers: all resolved), recorded as deferred-to-followup"
else
  fail=$((fail + 1))
  echo "  FAIL: templated-render not classified for scalar consumers: all dest, or wrong recorded tag (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 8b (#521): the same scalar `consumers: all` templated dest must
# ALSO classify as templated-render on the NO-YQ fallback path. We force
# that path by running with a PATH that excludes yq (and keeps only the
# stub gh + minimal coreutils). The awk fallback now emits a dedicated
# `__AWK_CONSUMERS_ALL__` sentinel that path_matches_templated_dest treats
# as match-any — before this fix the awk path emitted the cautious
# no-scope sentinel for EVERY templated entry, so a `consumers: all` dest
# never classified as templated-render without yq.
# Reuses the Test 8 fixture manifest (still on disk) + the same threads.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 8b: templated-render on consumers: all dest via NO-YQ awk fallback (#521)"

# Sanity: confirm the fixture manifest still carries the consumers: all
# templated entry (Test 8 wrote it; we depend on it here).
if ! grep -q 'consumers: all' "$FIXTURE_ROOT/.mergepath-sync.yml"; then
  fail=$((fail + 1))
  echo "  FAIL: Test 8b precondition — fixture manifest missing consumers: all entry" >&2
fi

GH_ARGV_LOG_B="$SCRATCH/t8b.log"; : > "$GH_ARGV_LOG_B"
# Stub gh in its own dir. Force the no-yq fallback via the script's test
# hook (RESOLVE_PR_THREADS_FORCE_NO_YQ=1) rather than curating yq out of
# PATH: CI installs yq into /usr/bin, so a fixed-PATH exclusion is not
# portable (it false-failed the setup on the runner). The hook exercises
# the exact grep/awk branch regardless of where yq is installed.
T8B_BIN="$SCRATCH/t8b-bin"; mkdir -p "$T8B_BIN"
make_gh_stub "$T8B_BIN/gh-real" "$THREADS_T8" "$FILES_T8" "$COMMITS_T8"
make_gh_wrapper "$T8B_BIN/gh" "$T8B_BIN/gh-real"
set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG_B" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  RESOLVE_PR_THREADS_FORCE_NO_YQ=1 \
  PATH="$T8B_BIN:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots 2>&1
)
rc=$?
set -e
if [ "$rc" -eq 0 ] && tag_before_resolve "$GH_ARGV_LOG_B" \
   && grep -q 'INFO: routing class templated-render recorded as deferred-to-followup' <<<"$out" \
   && grep -q 'FIELD: body=\[mergepath-resolve: deferred-to-followup\]' "$GH_ARGV_LOG_B" \
   && ! grep -q 'FIELD: body=\[mergepath-resolve: templated-render\]' "$GH_ARGV_LOG_B"; then
  pass=$((pass + 1))
  echo "  PASS: no-yq awk fallback classifies consumers: all dest as templated-render (#521), recorded as deferred-to-followup"
else
  fail=$((fail + 1))
  echo "  FAIL: no-yq fallback did not classify templated-render for consumers: all dest, or wrong recorded tag (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG_B" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 9 (#564): post-resolve readback confirms isResolved:true. After a
# successful resolve, the script must re-read the thread via the top-level
# nodes(ids:) lookup and report the confirmation. Assert (a) the readback
# query was actually issued, (b) the confirmation line is printed, and
# (c) the script exits 0.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 9: post-resolve readback confirms isResolved:true (#564)"

# Non-manifest path → deferred-to-followup class; readback is independent
# of the class, so any resolvable bot thread on current HEAD exercises it.
THREADS_T9='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_9","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/readback.md","body":"Some finding","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Some finding","databaseId":9001}]}
  }
]}}}}}'
FILES_T9='[]'
COMMITS_T9='[]'

GH_ARGV_LOG="$SCRATCH/t9.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T9" "$FILES_T9" "$COMMITS_T9"
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

if [ "$rc" -eq 0 ] \
   && grep -q 'nodes(ids:' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: readback query issued and confirmed isResolved:true (rc=0)"
else
  fail=$((fail + 1))
  echo "  FAIL: post-resolve readback did not confirm as expected (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 10 (#564): post-resolve readback FAILS CLOSED. If the readback
# reports isResolved:false for a thread the mutation claimed to resolve
# (state drift / eventual-consistency lag / a write that did not stick),
# the script must NOT report success: it prints a READBACK FAILED line and
# exits 2. Drive this by forcing the stub's readback branch to return
# isResolved:false for the resolved thread id via GH_STUB_READBACK_UNRESOLVED.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 10: post-resolve readback fails closed on unconfirmed resolve (#564)"

THREADS_T10='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_10","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/readback.md","body":"Some finding","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Some finding","databaseId":10001}]}
  }
]}}}}}'
FILES_T10='[]'
COMMITS_T10='[]'

GH_ARGV_LOG="$SCRATCH/t10.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T10" "$FILES_T10" "$COMMITS_T10"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  GH_STUB_READBACK_UNRESOLVED="PRT_10" \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --auto-resolve-bots 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 2 ] \
   && grep -q 'READBACK FAILED \[PRT_10\]' <<<"$out" \
   && grep -q 'failing closed' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: unconfirmed readback → READBACK FAILED + exit 2 (fail closed)"
else
  fail=$((fail + 1))
  echo "  FAIL: readback did not fail closed on isResolved:false (rc=$rc, expected 2)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 11 (#564): --resolve-actioned RESOLVES a demonstrably-actioned
# thread. A ≥30-char agent reply classifies as rebuttal-recorded (an
# actioned skip-set class, manifest-independent), so --resolve-actioned
# must tag, resolve, and confirm it via the readback — exit 0.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 11: --resolve-actioned resolves an actioned-class thread (#564)"

THREADS_T11='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_11","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/notes.md","body":"Some non-canonical finding","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Some non-canonical finding","databaseId":11001},
     {"author":{"login":"nathanpayne-claude"},"body":"Disagree — this is intentional for the propagation path; see #200 for context.","databaseId":11002}
   ]}
  }
]}}}}}'
FILES_T11='[]'
COMMITS_T11='[]'

GH_ARGV_LOG="$SCRATCH/t11.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T11" "$FILES_T11" "$COMMITS_T11"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
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
   && grep -q 'FIELD: body=\[mergepath-resolve: rebuttal-recorded\]' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out" \
   && ! grep -q 'not demonstrably actioned' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: actioned (rebuttal-recorded) thread resolved + confirmed under --resolve-actioned"
else
  fail=$((fail + 1))
  echo "  FAIL: --resolve-actioned did not resolve the actioned thread (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 12 (#564): --resolve-actioned SKIPS a non-actioned thread. A bot
# finding with no badge, no fix commit, and no agent reply classifies as
# deferred-to-followup (a surface-set class). --resolve-actioned must LEAVE
# IT UNRESOLVED: no resolveReviewThread mutation, a "not demonstrably
# actioned" skip line, and exit 3 (work remains) so the sweep still sees it.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 12: --resolve-actioned skips a non-actioned (deferred) thread (#564)"

THREADS_T12='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_12","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/random.md","body":"Some opaque finding without a badge","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Some opaque finding without a badge","databaseId":12001}]}
  }
]}}}}}'
FILES_T12='[]'
COMMITS_T12='[]'

GH_ARGV_LOG="$SCRATCH/t12.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T12" "$FILES_T12" "$COMMITS_T12"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (not demonstrably actioned: deferred-to-followup)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: non-actioned thread left unresolved (no mutation), exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: --resolve-actioned did not skip the non-actioned thread (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 13 (#564, Codex P2 on #565): a deferred-marked thread with no real
# action evidence is left unresolved by --resolve-actioned. The GATE ignores
# recorded markers and re-derives fresh evidence (#565): the marker reply is
# ≥30 chars and agent-authored, but step 3's marker guard excludes it, so the
# ladder finds no fix/rebuttal and classifies deferred-to-followup → skipped
# (no mutation, exit 3). (It must NOT be mis-read as rebuttal-recorded.)
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 13: --resolve-actioned leaves a deferred-marked, unfixed thread unresolved (#564 / Codex #565)"

THREADS_T13='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_13","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/marked.md","body":"Some finding deferred earlier","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Some finding deferred earlier","databaseId":13001},
     {"author":{"login":"nathanpayne-claude"},"body":"[mergepath-resolve: deferred-to-followup] deferred to follow-up; resolving for branch-protection conversation gate.","databaseId":13002}
   ]}
  }
]}}}}}'
FILES_T13='[]'
COMMITS_T13='[]'

GH_ARGV_LOG="$SCRATCH/t13.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T13" "$FILES_T13" "$COMMITS_T13"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (not demonstrably actioned: deferred-to-followup)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: existing deferred marker honored — thread left unresolved (no mutation), exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: deferred marker not honored under --resolve-actioned (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 14 (#564, CodeRabbit Major on #565): a STALE actioned marker is NOT
# honored when the bot posts fresh feedback after it. Thread: finding →
# agent rebuttal → [mergepath-resolve: rebuttal-recorded] marker → bot
# RE-RAISES. The marker (and the rebuttal) predate the bot's last word, so
# --resolve-actioned must NOT resolve — it classifies deferred-to-followup
# and leaves the thread unresolved (no mutation, exit 3).
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 14: --resolve-actioned ignores a stale actioned marker after a bot re-raise (#565)"

THREADS_T14='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_14","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/stale.md","body":"Original finding","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Original finding","databaseId":14001},
     {"author":{"login":"nathanpayne-claude"},"body":"Disagree — intentional for the propagation path; see #200 for the rationale.","databaseId":14002},
     {"author":{"login":"nathanpayne-claude"},"body":"[mergepath-resolve: rebuttal-recorded] agent rebuttal posted on thread; resolving.","databaseId":14003},
     {"author":{"login":"coderabbitai"},"body":"Still a problem after your rebuttal — please reconsider.","databaseId":14004}
   ]}
  }
]}}}}}'
FILES_T14='[]'
COMMITS_T14='[]'

GH_ARGV_LOG="$SCRATCH/t14.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T14" "$FILES_T14" "$COMMITS_T14"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (not demonstrably actioned: deferred-to-followup)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: stale actioned marker after a bot re-raise is not honored — thread left unresolved, exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: stale actioned marker was honored under --resolve-actioned (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 15 (#564, CodeRabbit Major on #565): the same staleness rule on the
# rebuttal heuristic (no marker). Thread: finding → agent rebuttal → bot
# RE-RAISES. The rebuttal predates the bot's last word, so it must NOT count
# as rebuttal-recorded; --resolve-actioned leaves the thread unresolved.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 15: --resolve-actioned ignores a stale rebuttal after a bot re-raise (#565)"

THREADS_T15='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_15","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/stale2.md","body":"Original finding two","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Original finding two","databaseId":15001},
     {"author":{"login":"nathanpayne-claude"},"body":"Disagree — intentional for the propagation path; see #200 for the rationale.","databaseId":15002},
     {"author":{"login":"coderabbitai"},"body":"Still a problem after your rebuttal — please reconsider.","databaseId":15003}
   ]}
  }
]}}}}}'
FILES_T15='[]'
COMMITS_T15='[]'

GH_ARGV_LOG="$SCRATCH/t15.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T15" "$FILES_T15" "$COMMITS_T15"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (not demonstrably actioned: deferred-to-followup)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: stale rebuttal after a bot re-raise is not counted — thread left unresolved, exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: stale rebuttal was counted as actioned under --resolve-actioned (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 16 (#564, nathanpayne-codex CHANGES_REQUESTED on #565): the
# addressed-elsewhere staleness guard. A fix commit that post-dates the
# ORIGINAL finding but PRE-dates a later bot re-raise must NOT count as
# actioning the thread. Thread: finding @ T0 → fix commit @ T1 (T0<T1) →
# bot re-raise @ T2 (T1<T2). --resolve-actioned must classify
# deferred-to-followup (not addressed-elsewhere) and leave it unresolved.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 16: --resolve-actioned ignores a fix commit that predates a bot re-raise (#565)"

THREADS_T16='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_16","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"scripts/foo.sh","body":"Original finding on foo","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Original finding on foo","databaseId":16001,"createdAt":"2026-01-01T00:00:00Z"},
     {"author":{"login":"coderabbitai"},"body":"Your fix did not address this — still broken.","databaseId":16002,"createdAt":"2026-01-03T00:00:00Z"}
   ]}
  }
]}}}}}'
# Agent fix commit at 2026-01-02 — AFTER the finding (T0) but BEFORE the
# re-raise (T2=2026-01-03). Touches the anchored file.
FILES_T16='["scripts/foo.sh"]'
COMMITS_T16='[{"sha":"def4567890","login":"nathanpayne-claude","date":"2026-01-02T00:00:00Z"}]'

GH_ARGV_LOG="$SCRATCH/t16.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T16" "$FILES_T16" "$COMMITS_T16"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (not demonstrably actioned: deferred-to-followup)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: stale fix commit (predates bot re-raise) is not addressed-elsewhere — left unresolved, exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: stale fix commit was treated as addressed-elsewhere under --resolve-actioned (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 17 (#564, nathanpayne-codex CHANGES_REQUESTED on #565): a later
# agent commit on an UNRELATED file must NOT make addressed-elsewhere hold
# for a thread anchored on a different file. Thread on scripts/foo.sh; the
# PR's overall file list includes foo.sh (so the old PR-level check passed),
# but the only qualifying agent commit touched scripts/bar.sh — NOT foo.sh.
# Per-commit verification must reject it → --resolve-actioned leaves the
# thread unresolved (no mutation, exit 3).
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 17: --resolve-actioned rejects addressed-elsewhere when the commit touched another file (#565)"

THREADS_T17='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_17","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"scripts/foo.sh","body":"Finding on foo, never fixed","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Finding on foo, never fixed","databaseId":17001,"createdAt":"2026-01-01T00:00:00Z"}]}
  }
]}}}}}'
# PR overall touched BOTH files; the later agent commit touched only bar.sh.
FILES_T17='["scripts/foo.sh","scripts/bar.sh"]'
COMMITS_T17='[{"sha":"bar9999999","login":"nathanpayne-claude","date":"2026-01-02T00:00:00Z"}]'
# Per-commit map: bar9999999 touched scripts/bar.sh ONLY (not foo.sh).
CFILES_T17='{"bar9999999":["scripts/bar.sh"]}'

GH_ARGV_LOG="$SCRATCH/t17.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T17" "$FILES_T17" "$COMMITS_T17" "$CFILES_T17"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
  RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
  PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
    --repo test/repo --resolve-actioned 2>&1
)
rc=$?
set -e

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (not demonstrably actioned: deferred-to-followup)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: commit on an unrelated file is not addressed-elsewhere — thread left unresolved, exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: unrelated-file commit was treated as addressed-elsewhere (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 18 (#564, nathanpayne-codex P1 CHANGES_REQUESTED on #565): a fresh
# bot finding on a canonical manifest path with NO fix commit and NO
# rebuttal must be LEFT UNRESOLVED by --resolve-actioned. The GATE skips
# routing (skip_routing), so the thread no longer short-circuits to
# canonical-coverage; it falls through to a non-actioned class (here
# deferred-to-followup) and is skipped — routing alone never resolves.
# (The fixture manifest, rewritten by Test 8, marks
# scripts/resolve-pr-threads.sh canonical.)
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 18: --resolve-actioned does NOT resolve a fresh, unfixed canonical-path thread (#565)"

THREADS_T18='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_18","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"scripts/resolve-pr-threads.sh","body":"Fresh unfixed finding on a canonical path","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Fresh unfixed finding on a canonical path","databaseId":18001,"createdAt":"2026-01-01T00:00:00Z"}]}
  }
]}}}}}'
FILES_T18='["scripts/resolve-pr-threads.sh"]'
COMMITS_T18='[]'

GH_ARGV_LOG="$SCRATCH/t18.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T18" "$FILES_T18" "$COMMITS_T18"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
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
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: routing-only canonical thread left unresolved (no mutation), exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: routing-only canonical thread was treated as actioned (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 19 (#564, nathanpayne-codex P1 CHANGES_REQUESTED on #565): the
# counterpart to Test 18 — a canonical-path thread that WAS actually fixed
# MUST resolve. Before the skip_routing gate path, derive_tag_class returned
# canonical-coverage (routing, step 1) before checking the fix commit
# (step 2), so a real fix on a canonical path was masked and skipped. With
# routing skipped in the gate, the fix commit touching the anchored
# canonical file classifies as addressed-elsewhere → resolved + readback.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 19: --resolve-actioned DOES resolve a fixed canonical-path thread (#565)"

THREADS_T19='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_19","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"scripts/resolve-pr-threads.sh","body":"Finding on a canonical path that we then fixed","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Finding on a canonical path that we then fixed","databaseId":19001,"createdAt":"2026-01-01T00:00:00Z"}]}
  }
]}}}}}'
FILES_T19='["scripts/resolve-pr-threads.sh"]'
# Agent fix commit AFTER the finding, touching the anchored canonical file.
COMMITS_T19='[{"sha":"can1234567","login":"nathanpayne-claude","date":"2026-01-02T00:00:00Z"}]'
CFILES_T19='{"can1234567":["scripts/resolve-pr-threads.sh"]}'

GH_ARGV_LOG="$SCRATCH/t19.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T19" "$FILES_T19" "$COMMITS_T19" "$CFILES_T19"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(
  GH_ARGV_LOG="$GH_ARGV_LOG" \
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
   && grep -q 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\]' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: fixed canonical-path thread resolved as addressed-elsewhere + readback-confirmed"
else
  fail=$((fail + 1))
  echo "  FAIL: fixed canonical-path thread was NOT resolved under --resolve-actioned (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 20 (#565 Codex P2 "let later fixes override stale surface markers"):
# a thread with a stale [mergepath-resolve: deferred-to-followup] marker BUT
# a later fix commit touching the anchored file must RESOLVE — the GATE
# ignores the marker and re-derives addressed-elsewhere from the fix.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 20: --resolve-actioned lets a later fix override a stale deferred marker (#565)"

THREADS_T20='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_20","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/x.md","body":"Finding later fixed","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Finding later fixed","databaseId":20001,"createdAt":"2026-01-01T00:00:00Z"},
     {"author":{"login":"nathanpayne-claude"},"body":"[mergepath-resolve: deferred-to-followup] deferred earlier; resolving for the gate.","databaseId":20002,"createdAt":"2026-01-02T00:00:00Z"}
   ]}
  }
]}}}}}'
FILES_T20='["docs/x.md"]'
COMMITS_T20='[{"sha":"fix2020abc","login":"nathanpayne-claude","date":"2026-01-03T00:00:00Z"}]'
CFILES_T20='{"fix2020abc":["docs/x.md"]}'

GH_ARGV_LOG="$SCRATCH/t20.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T20" "$FILES_T20" "$COMMITS_T20" "$CFILES_T20"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(GH_ARGV_LOG="$GH_ARGV_LOG" RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 --repo test/repo --resolve-actioned 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ] \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\]' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: later fix overrides the stale deferred marker — resolved as addressed-elsewhere"
else
  fail=$((fail + 1))
  echo "  FAIL: stale deferred marker masked the later fix (rc=$rc)" >&2
  echo "$out" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 21 (#565 Codex P2 "re-verify actioned markers before resolving"): a
# thread carrying an [mergepath-resolve: addressed-elsewhere] marker but NO
# actual qualifying commit must NOT resolve — the GATE re-derives evidence
# and finds none.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 21: --resolve-actioned re-verifies a stale addressed-elsewhere marker, skips (#565)"

THREADS_T21='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_21","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/y.md","body":"Finding never actually fixed","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Finding never actually fixed","databaseId":21001,"createdAt":"2026-01-01T00:00:00Z"},
     {"author":{"login":"nathanpayne-claude"},"body":"[mergepath-resolve: addressed-elsewhere] addressed by commit deadbeef.","databaseId":21002,"createdAt":"2026-01-02T00:00:00Z"}
   ]}
  }
]}}}}}'
FILES_T21='[]'
COMMITS_T21='[]'

GH_ARGV_LOG="$SCRATCH/t21.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T21" "$FILES_T21" "$COMMITS_T21"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(GH_ARGV_LOG="$GH_ARGV_LOG" RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 --repo test/repo --resolve-actioned 2>&1)
rc=$?
set -e

if [ "$rc" -eq 3 ] && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: stale addressed-elsewhere marker without a real commit is re-verified and skipped"
else
  fail=$((fail + 1))
  echo "  FAIL: stale addressed-elsewhere marker resolved without re-verification (rc=$rc)" >&2
  echo "$out" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 22 (#565 Codex P2 "reject rationale overrides in actioned mode"):
# --resolve-actioned with --rationale is rejected (exit 1), never resolves.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 22: --resolve-actioned --rationale is rejected (#565)"

GH_ARGV_LOG="$SCRATCH/t22.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T4" "$FILES_T4" "$COMMITS_T4"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(GH_ARGV_LOG="$GH_ARGV_LOG" RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 --repo test/repo --resolve-actioned --rationale "manual note" 2>&1)
rc=$?
set -e

if [ "$rc" -eq 1 ] \
   && grep -q 'not valid with --resolve-actioned' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: --resolve-actioned --rationale rejected with exit 1, no mutation"
else
  fail=$((fail + 1))
  echo "  FAIL: --rationale not rejected under --resolve-actioned (rc=$rc)" >&2
  echo "$out" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 23 (#565 Codex P2 "allow later fix commits past the stale-thread
# gate"): a fixed-by-commit thread whose bot comment is on an OLDER commit
# (commit_oid != HEAD) must still RESOLVE under --resolve-actioned — the
# gate bypasses the current-HEAD stale skip and relies on the fix evidence.
# (--auto-resolve-bots would skip this thread as stale-HEAD.)
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 23: --resolve-actioned resolves a fixed thread whose bot comment is on an older commit (#565)"

THREADS_T23='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_23","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/z.md","body":"Finding fixed by a later commit","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"OLDCOMMIT0"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Finding fixed by a later commit","databaseId":23001,"createdAt":"2026-01-01T00:00:00Z"}]}
  }
]}}}}}'
FILES_T23='["docs/z.md"]'
COMMITS_T23='[{"sha":"fix2323abc","login":"nathanpayne-claude","date":"2026-01-02T00:00:00Z"}]'
CFILES_T23='{"fix2323abc":["docs/z.md"]}'

GH_ARGV_LOG="$SCRATCH/t23.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T23" "$FILES_T23" "$COMMITS_T23" "$CFILES_T23"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(GH_ARGV_LOG="$GH_ARGV_LOG" RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 --repo test/repo --resolve-actioned 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ] \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\]' "$GH_ARGV_LOG" \
   && ! grep -q 'SKIP (stale' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: stale-HEAD fixed thread resolved via evidence (current-HEAD gate bypassed)"
else
  fail=$((fail + 1))
  echo "  FAIL: stale-HEAD fixed thread not resolved under --resolve-actioned (rc=$rc)" >&2
  echo "$out" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 24 (#565 round-8 P1): commit-cache login normalization. GitHub
# returns author.login=null for commits whose author email is not linked to
# a GitHub account — THIS repo's normal case (commits are authored as
# nathanjohnpayne with a placeholder .example email). The commit-cache login
# projection must fall back to .commit.author.name (= nathanjohnpayne, an
# agent author) BEFORE the unlinked email, or fixed-by-commit feedback is
# never recognized as agent-authored and addressed-elsewhere never fires.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 24: commit-cache login falls back to .commit.author.name when author.login is null (#565)"

# (a) The exact projection both builders use must map a null-author commit to
#     the git author name (the #565-round-8 reviewer's live shape).
RAW_COMMITS_T24='[{"sha":"deadbeef","author":null,"commit":{"author":{"name":"nathanjohnpayne","email":"nathan@nathanjohnpayne.example","date":"2026-01-02T00:00:00Z"}}}]'
PROJECTED_LOGIN=$(printf '%s' "$RAW_COMMITS_T24" | jq -r '[.[] | {login: (.author.login // .commit.author.name // .commit.author.email // "")}][0].login')
if [ "$PROJECTED_LOGIN" = "nathanjohnpayne" ]; then
  pass=$((pass + 1))
  echo "  PASS: null author.login -> .commit.author.name (nathanjohnpayne)"
else
  fail=$((fail + 1))
  echo "  FAIL: projection gave [$PROJECTED_LOGIN], expected nathanjohnpayne" >&2
fi

# (b) BOTH commit-cache builders in the script carry the .commit.author.name
#     fallback (regression guard against either reverting).
BUILDER_HITS=$(grep -c '\.author\.login // \.commit\.author\.name // \.commit\.author\.email' "$SCRIPT")
if [ "$BUILDER_HITS" -ge 2 ]; then
  pass=$((pass + 1))
  echo "  PASS: both commit-cache builders include the .commit.author.name fallback ($BUILDER_HITS)"
else
  fail=$((fail + 1))
  echo "  FAIL: expected >=2 builders with .commit.author.name fallback, found $BUILDER_HITS" >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 25 (#575 guard, auto-derive path): --auto-resolve-bots on a
# demonstrably-ACTIONED thread must AUTO-UPGRADE the deferred tag to the
# truthful class. Thread: bot finding → stale recorded
# [mergepath-resolve: deferred-to-followup] marker → LATER agent fix commit
# touching the anchored file. The TAG ladder honors the surface marker
# (deferred-to-followup), but the guard re-derives with the GATE
# classification (skip-routing, marker-blind) which proves
# addressed-elsewhere — so the emitted tag is the truthful
# addressed-elsewhere, with an INFO line. (The negative case — a
# genuinely-deferred thread keeping deferred-to-followup — is locked by
# Tests 4 and 5 above, which run through the same guard and stay deferred.)
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 25: --auto-resolve-bots auto-upgrades a demonstrably-actioned deferred tag (#575)"

THREADS_T25='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_25","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/upgraded.md","body":"Finding deferred earlier, then fixed","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Finding deferred earlier, then fixed","databaseId":25001,"createdAt":"2026-01-01T00:00:00Z"},
     {"author":{"login":"nathanpayne-claude"},"body":"[mergepath-resolve: deferred-to-followup] deferred earlier; resolving for the gate.","databaseId":25002,"createdAt":"2026-01-02T00:00:00Z"}
   ]}
  }
]}}}}}'
FILES_T25='["docs/upgraded.md"]'
COMMITS_T25='[{"sha":"fix2525abc","login":"nathanpayne-claude","date":"2026-01-03T00:00:00Z"}]'
CFILES_T25='{"fix2525abc":["docs/upgraded.md"]}'

GH_ARGV_LOG="$SCRATCH/t25.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T25" "$FILES_T25" "$COMMITS_T25" "$CFILES_T25"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(GH_ARGV_LOG="$GH_ARGV_LOG" RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 --repo test/repo --auto-resolve-bots 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ] \
   && grep -q 'INFO: tag auto-upgraded deferred-to-followup → addressed-elsewhere' <<<"$out" \
   && grep -q 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\]' "$GH_ARGV_LOG" \
   && ! grep -q 'FIELD: body=\[mergepath-resolve: deferred-to-followup\]' "$GH_ARGV_LOG" \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: actioned thread auto-upgraded deferred-to-followup → addressed-elsewhere with INFO line"
else
  fail=$((fail + 1))
  echo "  FAIL: actioned thread was not auto-upgraded (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 26 (#575 guard, --rationale path): the explicit-deferral override is
# exactly how the #571 mis-marking happened, so the guard applies there
# too. A thread carrying a substantive agent rebuttal, resolved via
# `--auto-resolve-bots --rationale`, must emit the truthful
# rebuttal-recorded CLASS while keeping the operator's rationale TEXT.
# (Test 5 above locks the negative case: a non-actioned thread keeps
# deferred-to-followup with the custom text.)
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 26: --auto-resolve-bots --rationale auto-upgrades the class on an actioned thread (#575)"

THREADS_T26='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_26","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"docs/rebutted.md","body":"Finding that was rebutted on-thread","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[
     {"author":{"login":"coderabbitai"},"body":"Finding that was rebutted on-thread","databaseId":26001,"createdAt":"2026-01-01T00:00:00Z"},
     {"author":{"login":"nathanpayne-claude"},"body":"Disagree — this is intentional for the propagation path; see #200 for context.","databaseId":26002,"createdAt":"2026-01-02T00:00:00Z"}
   ]}
  }
]}}}}}'
FILES_T26='[]'
COMMITS_T26='[]'

GH_ARGV_LOG="$SCRATCH/t26.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T26" "$FILES_T26" "$COMMITS_T26"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

T26_RATIONALE="bulk pass over the sync backlog; see the follow-up issue"

set +e
out=$(GH_ARGV_LOG="$GH_ARGV_LOG" RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 --repo test/repo --auto-resolve-bots \
  --rationale "$T26_RATIONALE" 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ] \
   && grep -q 'INFO: tag auto-upgraded deferred-to-followup → rebuttal-recorded' <<<"$out" \
   && grep -qF "FIELD: body=[mergepath-resolve: rebuttal-recorded] $T26_RATIONALE" "$GH_ARGV_LOG" \
   && ! grep -q 'FIELD: body=\[mergepath-resolve: deferred-to-followup\]' "$GH_ARGV_LOG" \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: rationale override kept the operator text but upgraded the class to rebuttal-recorded"
else
  fail=$((fail + 1))
  echo "  FAIL: rationale-path guard did not upgrade the class (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 27 (#616 finding 3509930338, actioned side): a ROUTING-class
# thread that IS demonstrably actioned gets the truthful actioned tag,
# not deferred-to-followup and not the routing tag. The anchored path is
# canonical in the fixture manifest (Test 8 rewrote the manifest but kept
# the scripts/resolve-pr-threads.sh canonical entry) AND an agent fix
# commit touching it post-dates the finding → the #575 auto-upgrade now
# also runs for routing classes: INFO line `canonical-coverage →
# addressed-elsewhere`, tag addressed-elsewhere. (Tests 2/8/8b lock the
# NON-actioned side: routing class → deferred-to-followup.)
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 27: actioned canonical-path thread auto-upgrades routing → addressed-elsewhere (#616)"

THREADS_T27='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRT_27","isResolved":false,"isOutdated":false,
   "commentsFirst":{"nodes":[{"author":{"login":"coderabbitai"},"path":"scripts/resolve-pr-threads.sh","body":"Canonical-path finding that was then fixed","createdAt":"2026-01-01T00:00:00Z"}]},
   "commentsLast":{"nodes":[{"commit":{"oid":"HEADCURRENT"}}]},
   "allComments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"Canonical-path finding that was then fixed","databaseId":27001,"createdAt":"2026-01-01T00:00:00Z"}]}
  }
]}}}}}'
FILES_T27='["scripts/resolve-pr-threads.sh"]'
COMMITS_T27='[{"sha":"fix2727abc","login":"nathanpayne-claude","date":"2026-01-02T00:00:00Z"}]'
CFILES_T27='{"fix2727abc":["scripts/resolve-pr-threads.sh"]}'

GH_ARGV_LOG="$SCRATCH/t27.log"; : > "$GH_ARGV_LOG"
make_gh_stub "$SCRATCH/gh-real" "$THREADS_T27" "$FILES_T27" "$COMMITS_T27" "$CFILES_T27"
make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"

set +e
out=$(GH_ARGV_LOG="$GH_ARGV_LOG" RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 PATH="$SCRATCH:$PATH" \
  env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
  bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 --repo test/repo --auto-resolve-bots 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ] \
   && grep -q 'INFO: tag auto-upgraded canonical-coverage → addressed-elsewhere' <<<"$out" \
   && grep -q 'FIELD: body=\[mergepath-resolve: addressed-elsewhere\]' "$GH_ARGV_LOG" \
   && ! grep -q 'FIELD: body=\[mergepath-resolve: canonical-coverage\]' "$GH_ARGV_LOG" \
   && ! grep -q 'FIELD: body=\[mergepath-resolve: deferred-to-followup\]' "$GH_ARGV_LOG" \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: routing class auto-upgraded to addressed-elsewhere on fix-commit evidence"
else
  fail=$((fail + 1))
  echo "  FAIL: actioned canonical-path thread was not upgraded to addressed-elsewhere (rc=$rc)" >&2
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
