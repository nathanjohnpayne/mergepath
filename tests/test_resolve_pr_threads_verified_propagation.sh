#!/usr/bin/env bash
# tests/test_resolve_pr_threads_verified_propagation.sh
#
# Tests the #572 `--resolve-verified-propagation` mode in
# scripts/resolve-pr-threads.sh.
#
# The mode drains the routing-class residual on consumer sync PRs
# (canonical-coverage / templated-render threads, the #562 backlog):
# routing alone (path membership) never resolves, but when the consumer's
# CURRENT default-branch content byte-matches mergepath's canonical source
# (or the re-rendered template with the consumer's facts), the propagation
# is PROVEN and the thread is resolved with the
# [mergepath-resolve: verified-propagation] tag. Any mismatch or
# verification error leaves the thread unresolved (fail closed).
#
# Strategy mirrors tests/test_resolve_pr_threads_staleness_pagination.sh:
# stub `gh` via PATH-prepend, capture argv to a side log, and assert on
# the mutations (or their absence). The fixture tree carries the REAL
# render libs (scripts/lib/template-substitution.sh +
# scripts/lib/manifest-fact-helpers.sh) so the templated arm exercises the
# exact render engine verify-propagation-pr.sh uses, driven by stub facts
# in the fixture manifest. Fully offline; requires yq (same bar as
# check_sync_manifest / the templated verifier).
#
# Cases:
#   1. Matched canonical content → resolved + verified-propagation tag +
#      readback confirmation (and the PR-HEAD staleness proxy is bypassed:
#      the thread anchors on an OLD commit).
#   2. Matched templated content (real render with stub facts) → resolved.
#   3. Drifted canonical content (one byte differs) → left unresolved,
#      exit 3, no mutations.
#   4. Surface-class thread (nitpick-noted, non-manifest path) → never
#      touched (skip not-propagation-routed), and no contents fetch.
#   5. Human-authored thread → never touched.
#   6. Consumer content fetch failure → skipped fail-closed, no mutations.
#   7. Template render failure (malformed template) → skipped fail-closed,
#      no mutations.
#   8. --dry-run on a matched thread → would-resolve preview with the
#      verified-propagation tag, exit 3, NO mutations.
#   9. A previously recorded [mergepath-resolve: deferred-to-followup]
#      marker on a canonical-path thread does NOT block the routing
#      classification (#616 finding 3509734391): routing is a pure path
#      predicate (derive_routing_class), so the previously-deferred
#      thread byte-verifies and resolves as verified-propagation.
#  10. A routed thread that ALSO carries action evidence (a substantive
#      agent rebuttal after the bot's last word) is auto-upgraded to its
#      truthful actioned tag (rebuttal-recorded) with an INFO line
#      instead of verified-propagation (#616 finding 3509734396); the
#      byte-compare is skipped (no contents fetch — resolves even over
#      drifted consumer content, on the action evidence).
# 10b. A consumer thread anchored at a TEMPLATED entry's SOURCE path
#      (which the manifest lists as `.path` but never propagates to the
#      consumer — the consumer receives `dest`) must NOT resolve as
#      verified propagation even when the consumer content byte-matches
#      the mergepath source: routing skips it as not-propagation-routed
#      (#616 finding 3509930343).
#  11. scripts/lib/ensure-yq.sh short-circuits when a mikefarah yq is
#      already on PATH (no installer calls).
#  12. scripts/lib/ensure-yq.sh --ci-only: no-op without
#      GITHUB_ACTIONS=true; with it, installs the PINNED release via
#      stubbed sudo/wget (no network) to ENSURE_YQ_DEST (#616 finding
#      3509734393) — INCLUDING when a wrong-implementation (non-mikefarah)
#      yq is already on PATH (#616 finding 3509930342).
#  13. check_resolve_pr_threads wires the CI-only bootstrap: structural
#      assertions that the check ALWAYS delegates to
#      scripts/lib/ensure-yq.sh --ci-only (no `command -v yq` gate — a
#      wrong-implementation yq on PATH must not skip the bootstrap,
#      #616 finding 3509930342) and the lib exists.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/resolve-pr-threads.sh"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }

# Require the mikefarah implementation specifically, not just any `yq` on
# PATH — the Python wrapper answers `command -v yq` but rejects v4 syntax,
# which would surface here as opaque parser errors mid-suite (#616 finding
# 3509930342). The implementation sniff mirrors the canonical short-circuit
# in scripts/lib/ensure-yq.sh (which check_resolve_pr_threads delegates to
# unconditionally under CI, so runners self-heal before this guard runs).
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "test_resolve_pr_threads_verified_propagation: mikefarah/yq v4+ is required (missing or wrong yq implementation on PATH)" >&2
  exit 1
fi

pass=0
fail=0

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# Fixture repo tree (same pattern as the staleness-pagination test): copy
# the script so its $(dirname BASH_SOURCE)/.. manifest resolution lands on
# our fixture manifest, ship no-op preflight/identity stubs, and copy the
# REAL render libs so the templated byte-compare runs the same engine the
# propagation-lane verifier does.
FIXTURE_ROOT="$SCRATCH/repo"
mkdir -p "$FIXTURE_ROOT/scripts/lib" "$FIXTURE_ROOT/docs" "$FIXTURE_ROOT/examples"
cp "$SCRIPT" "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh"
cp "$ROOT/scripts/lib/template-substitution.sh" "$FIXTURE_ROOT/scripts/lib/template-substitution.sh"
cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$FIXTURE_ROOT/scripts/lib/manifest-fact-helpers.sh"
cat > "$FIXTURE_ROOT/scripts/lib/preflight-helpers.sh" <<'STUB'
auto_source_preflight() { :; }
STUB
cat > "$FIXTURE_ROOT/scripts/identity-check.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FIXTURE_ROOT/scripts/identity-check.sh"

# Fixture manifest: the CONSUMER under test is test/consumer (the --repo
# the script runs against), with the facts the templated render needs.
cat > "$FIXTURE_ROOT/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - name: test-consumer
    repo: test/consumer
    visibility: public
    facts:
      frameworks: [react]
      greeting: hola
paths:
  - path: docs/canonical.md
    type: canonical
    consumers: all
  - path: examples/tpl.txt
    source: examples/tpl.txt
    dest: rendered/out.txt
    type: templated
    consumers:
      - test-consumer
YAML

# Canonical source content in the mergepath working tree.
cat > "$FIXTURE_ROOT/docs/canonical.md" <<'MD'
# Canonical doc

Propagated verbatim to every consumer.
MD

# Templated source — comment-prefixed conditional + a fact substitution,
# exercising the real v1 template syntax.
cat > "$FIXTURE_ROOT/examples/tpl.txt" <<'TPL'
# >>> if frameworks contains react
react block enabled
# <<<
greeting is {{greeting}}
TPL

# Expected render for test-consumer (frameworks contains react → block
# kept, marker lines dropped; {{greeting}} → hola).
EXPECTED_RENDER="$SCRATCH/expected-render.txt"
cat > "$EXPECTED_RENDER" <<'OUT'
react block enabled
greeting is hola
OUT

# make_gh_stub <stub-path> <threads-file>
# Routes graphql calls on the recorded lastcall body (same shape as the
# sibling resolve-pr-threads tests) plus the #572 REST routes:
#   repos/*/contents/*  → consumer CURRENT content ($CONSUMER_CONTENT_FILE),
#                         or a hard failure when GH_STUB_FAIL_CONTENTS=1
#   repos/{owner}/{repo} (bare) → default branch ("main"; the script reads
#                         --jq .default_branch, which stubs return bare)
make_gh_stub() {
  local stub_path="$1"
  local threads_file="$2"
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
    __url=""
    for __a in "\$@"; do
      case "\$__a" in
        graphql|repos/*) __url="\$__a"; break ;;
      esac
    done
    case "\$__url" in
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
        else
          cat "$threads_file"
        fi
        ;;
      "repos/"*"/contents/"*)
        if [ -n "\${GH_STUB_FAIL_CONTENTS:-}" ]; then
          echo "simulated contents fetch failure" >&2
          exit 1
        fi
        cat "\$CONSUMER_CONTENT_FILE"
        ;;
      "repos/"*"/pulls/"*"/files"*)
        echo '[]'
        ;;
      "repos/"*"/pulls/"*"/commits"*)
        echo '[]'
        ;;
      "repos/"*"/commits/"*)
        echo '[]'
        ;;
      "repos/"*"/pulls/"*)
        echo "HEADCURRENT"
        ;;
      "repos/"*)
        # Bare repos/{owner}/{repo} — default-branch fetch.
        echo "main"
        ;;
      *)
        echo "{}" ;;
    esac
    ;;
  repo)
    printf '{"nameWithOwner":"test/consumer"}\n'
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

# make_thread_fixture <thread-id> <path> <author> <body> <oid> <out-file>
# Single non-truncated bot (or human) thread — the enumeration shape the
# script projects.
make_thread_fixture() {
  local thread_id="$1" anchor_path="$2" author="$3" body="$4" oid="$5" out_file="$6"
  jq -nc --arg id "$thread_id" --arg p "$anchor_path" \
     --arg a "$author" --arg b "$body" --arg o "$oid" '
    {data:{repository:{pullRequest:{reviewThreads:{
      totalCount: 1,
      pageInfo: {hasNextPage: false, endCursor: null},
      nodes: [{
        id: $id, isResolved: false, isOutdated: false,
        commentsFirst: {nodes: [{
          author: {login: $a}, path: $p, body: $b,
          createdAt: "2026-01-01T00:00:00Z"
        }]},
        commentsLast: {nodes: [{commit: {oid: $o}}]},
        allComments: {
          totalCount: 1,
          pageInfo: {hasPreviousPage: false},
          nodes: [{author: {login: $a}, body: $b, databaseId: 1001,
                   createdAt: "2026-01-01T00:00:00Z"}]
        }
      }]
    }}}}}' > "$out_file"
}

# make_thread_fixture_with_reply <thread-id> <path> <author> <body> <oid> \
#     <reply-login> <reply-body> <out-file>
# Bot thread plus ONE later agent-authored reply (allComments totalCount
# 2, complete window — no pagination refetch). The shape of a
# previously-tagged (deferral marker) or rebutted thread (#616).
make_thread_fixture_with_reply() {
  local thread_id="$1" anchor_path="$2" author="$3" body="$4" oid="$5"
  local reply_login="$6" reply_body="$7" out_file="$8"
  jq -nc --arg id "$thread_id" --arg p "$anchor_path" \
     --arg a "$author" --arg b "$body" --arg o "$oid" \
     --arg rl "$reply_login" --arg rb "$reply_body" '
    {data:{repository:{pullRequest:{reviewThreads:{
      totalCount: 1,
      pageInfo: {hasNextPage: false, endCursor: null},
      nodes: [{
        id: $id, isResolved: false, isOutdated: false,
        commentsFirst: {nodes: [{
          author: {login: $a}, path: $p, body: $b,
          createdAt: "2026-01-01T00:00:00Z"
        }]},
        commentsLast: {nodes: [{commit: {oid: $o}}]},
        allComments: {
          totalCount: 2,
          pageInfo: {hasPreviousPage: false},
          nodes: [
            {author: {login: $a}, body: $b, databaseId: 1001,
             createdAt: "2026-01-01T00:00:00Z"},
            {author: {login: $rl}, body: $rb, databaseId: 1002,
             createdAt: "2026-01-02T00:00:00Z"}
          ]
        }
      }]
    }}}}}' > "$out_file"
}

# run_mode <threads-file> <content-file> [extra-flag ...] → runs the mode,
# sets $out and $rc. Extra env via the RUN_* variables.
run_mode() {
  local threads_file="$1" content_file="$2"
  shift 2
  make_gh_stub "$SCRATCH/gh-real" "$threads_file"
  make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"
  set +e
  out=$(
    GH_ARGV_LOG="$GH_ARGV_LOG" \
    CONSUMER_CONTENT_FILE="$content_file" \
    GH_STUB_FAIL_CONTENTS="${RUN_FAIL_CONTENTS:-}" \
    RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 \
    PATH="$SCRATCH:$PATH" \
    env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
    bash "$FIXTURE_ROOT/scripts/resolve-pr-threads.sh" 99999 \
      --repo test/consumer --resolve-verified-propagation "$@" 2>&1
  )
  rc=$?
  set -e
}

# ─────────────────────────────────────────────────────────────────────
# Test 1: matched canonical content → resolved with the
# verified-propagation tag + readback confirmation. The thread anchors on
# an OLD commit (OLDCOMMIT0 != HEADCURRENT), locking the PR-HEAD
# staleness-proxy bypass: the evidence is the consumer's CURRENT
# default-branch content, not the PR HEAD.
# ─────────────────────────────────────────────────────────────────────
echo "Test 1: matched canonical content → resolved + verified-propagation tag (#572)"

make_thread_fixture "PRT_VP1" "docs/canonical.md" "coderabbitai" \
  "Finding on propagated canonical content" "OLDCOMMIT0" "$SCRATCH/threads_vp1.json"
CONSUMER_MATCH_CANONICAL="$SCRATCH/consumer-canonical.md"
cp "$FIXTURE_ROOT/docs/canonical.md" "$CONSUMER_MATCH_CANONICAL"

GH_ARGV_LOG="$SCRATCH/t1.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 0 ] \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: verified-propagation\] consumer content at docs/canonical.md byte-matches the mergepath canonical source' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out" \
   && ! grep -q 'SKIP (stale' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: byte-matched canonical thread resolved + tagged + readback-confirmed (stale-HEAD proxy bypassed)"
else
  fail=$((fail + 1))
  echo "  FAIL: matched canonical thread was not resolved as expected (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 2: matched templated content — the fixture's REAL render libs
# re-render examples/tpl.txt with test-consumer's stub facts and the
# consumer's current content equals that render byte-for-byte → resolved.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 2: matched templated content (real render, stub facts) → resolved (#572)"

make_thread_fixture "PRT_VP2" "rendered/out.txt" "chatgpt-codex-connector" \
  "Finding on rendered templated output" "HEADCURRENT" "$SCRATCH/threads_vp2.json"

GH_ARGV_LOG="$SCRATCH/t2.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp2.json" "$EXPECTED_RENDER"

if [ "$rc" -eq 0 ] \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: verified-propagation\] consumer content at rendered/out.txt byte-matches the re-rendered template examples/tpl.txt (consumer=test-consumer)' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: byte-matched templated thread resolved via the shared render engine"
else
  fail=$((fail + 1))
  echo "  FAIL: matched templated thread was not resolved as expected (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 3: drifted canonical content — ONE byte differs → the thread is
# LEFT UNRESOLVED (exit 3), with no tag reply and no resolve mutation.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 3: drifted canonical content (one byte differs) → left unresolved (#572)"

CONSUMER_DRIFT_CANONICAL="$SCRATCH/consumer-canonical-drift.md"
# Flip a single byte relative to the mergepath source.
sed 's/^# Canonical doc$/# Canonical dot/' "$FIXTURE_ROOT/docs/canonical.md" > "$CONSUMER_DRIFT_CANONICAL"
if cmp -s "$FIXTURE_ROOT/docs/canonical.md" "$CONSUMER_DRIFT_CANONICAL"; then
  fail=$((fail + 1))
  echo "  FAIL: drift fixture precondition — files unexpectedly identical" >&2
fi

GH_ARGV_LOG="$SCRATCH/t3.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_DRIFT_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation NOT verified — content drift)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: drifted content left unresolved with a per-thread reason, exit 3, no mutations"
else
  fail=$((fail + 1))
  echo "  FAIL: drifted content was not left unresolved (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 4: surface-class thread (Nitpick badge on a NON-manifest path,
# not a templated dest → routing class not-routed) → never touched:
# skipped as not-propagation-routed, no mutations, and no
# consumer-content fetch is even attempted.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 4: non-routed (nitpick, non-manifest path) thread → never touched (#572)"

make_thread_fixture "PRT_VP4" "docs/unrelated.md" "coderabbitai" \
  "_🧹 Nitpick (assertive)_ minor wording issue" "HEADCURRENT" "$SCRATCH/threads_vp4.json"

GH_ARGV_LOG="$SCRATCH/t4.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp4.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (not propagation-routed)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG" \
   && ! grep -q '/contents/' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: surface-class thread skipped (no mutations, no contents fetch), exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: surface-class thread was touched (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 5: human-authored thread → never touched, even on a canonical path
# with byte-matching content.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 5: human-authored thread → never touched (#572)"

make_thread_fixture "PRT_VP5" "docs/canonical.md" "some-human" \
  "Human comment on the canonical doc" "HEADCURRENT" "$SCRATCH/threads_vp5.json"

GH_ARGV_LOG="$SCRATCH/t5.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp5.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (non-bot author some-human)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: human-authored thread skipped untouched, exit 3"
else
  fail=$((fail + 1))
  echo "  FAIL: human-authored thread was touched (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 6: consumer content fetch failure → skipped FAIL CLOSED (never
# resolve on partial evidence), exit 3, no mutations.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 6: consumer content fetch failure → skipped fail-closed (#572)"

GH_ARGV_LOG="$SCRATCH/t6.log"; : > "$GH_ARGV_LOG"
RUN_FAIL_CONTENTS=1 run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation verification failed — failing closed)' <<<"$out" \
   && grep -q 'could not fetch test/consumer:docs/canonical.md' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: fetch failure skipped fail-closed with reason, exit 3, no mutations"
else
  fail=$((fail + 1))
  echo "  FAIL: fetch failure did not fail closed (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 7: template render failure — the source template is malformed
# (unclosed conditional) → skipped FAIL CLOSED, exit 3, no mutations.
# NOTE: rewrites the fixture template, so any test needing the good
# template must run BEFORE this one.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 7: template render failure → skipped fail-closed (#572)"

cat > "$FIXTURE_ROOT/examples/tpl.txt" <<'TPL'
# >>> if frameworks contains react
react block enabled — but the conditional is never closed
TPL

GH_ARGV_LOG="$SCRATCH/t7.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp2.json" "$EXPECTED_RENDER"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation verification failed — failing closed)' <<<"$out" \
   && grep -q 'templated re-render failed for source examples/tpl.txt' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: render failure skipped fail-closed with reason, exit 3, no mutations"
else
  fail=$((fail + 1))
  echo "  FAIL: render failure did not fail closed (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 8: --dry-run on a matched canonical thread → would-resolve preview
# includes the verified-propagation tag + rationale; exit 3 (work
# remains); NO mutations of any kind. Dry-run-first is the operating
# contract for this mode.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 8: --dry-run previews the verified resolve without mutating (#572)"

GH_ARGV_LOG="$SCRATCH/t8.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL" --dry-run

if [ "$rc" -eq 3 ] \
   && grep -q 'WOULD RESOLVE \[coderabbitai\] docs/canonical.md' <<<"$out" \
   && grep -q '→ \[mergepath-resolve: verified-propagation\]' <<<"$out" \
   && grep -q 'would-resolve: 1' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: dry-run previewed the verified resolve (tag + rationale), exit 3, no mutations"
else
  fail=$((fail + 1))
  echo "  FAIL: dry-run behavior incorrect (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 9: a previously recorded [mergepath-resolve: deferred-to-followup]
# marker does NOT block the routing classification (#616 finding
# 3509734391). This is the mode's MAIN use case: a sync finding deferred
# on an earlier pass, whose consumer content NOW byte-matches, must
# byte-verify and resolve as verified-propagation — not resurface forever
# as "not propagation-routed" because the old surface tag wins the TAG
# ladder. NOTE: Test 7 corrupted the fixture template, but this test
# uses only the canonical arm.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 9: previously-deferred surface marker no longer blocks routing (#616)"

make_thread_fixture_with_reply "PRT_VP9" "docs/canonical.md" "coderabbitai" \
  "Finding on propagated canonical content" "OLDCOMMIT0" \
  "nathanpayne-claude" \
  "[mergepath-resolve: deferred-to-followup] canonical-coverage tracked in the follow-up issue mergepath#562" \
  "$SCRATCH/threads_vp9.json"

GH_ARGV_LOG="$SCRATCH/t9.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp9.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 0 ] \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: verified-propagation\] consumer content at docs/canonical.md byte-matches the mergepath canonical source' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out" \
   && ! grep -q 'SKIP (not propagation-routed)' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: deferred-marker thread routed on its path, byte-verified, resolved"
else
  fail=$((fail + 1))
  echo "  FAIL: previously-deferred thread was not resolved (rc=$rc) — stale marker blocked routing?" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 10: a routed thread that ALSO carries action evidence — a
# substantive (≥30 char, non-marker) agent rebuttal AFTER the bot's last
# word — is auto-upgraded to the truthful rebuttal-recorded tag with an
# INFO line, NOT blanket-tagged verified-propagation (#616 finding
# 3509734396). The action evidence is the resolution evidence, so the
# byte-compare is skipped entirely: the consumer content here is the
# DRIFTED fixture and no contents fetch may occur.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 10: actioned (rebutted) routed thread → truthful upgraded tag (#616)"

make_thread_fixture_with_reply "PRT_VP10" "docs/canonical.md" "coderabbitai" \
  "Finding on propagated canonical content" "OLDCOMMIT0" \
  "nathanpayne-claude" \
  "This finding is intentionally divergent upstream; the canonical source is correct as written. See mergepath#562." \
  "$SCRATCH/threads_vp10.json"

GH_ARGV_LOG="$SCRATCH/t10.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp10.json" "$CONSUMER_DRIFT_CANONICAL"

if [ "$rc" -eq 0 ] \
   && grep -q 'INFO: tag auto-upgraded verified-propagation → rebuttal-recorded' <<<"$out" \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: rebuttal-recorded\] agent rebuttal posted on thread; resolving.' "$GH_ARGV_LOG" \
   && ! grep -q 'FIELD: body=\[mergepath-resolve: verified-propagation\]' "$GH_ARGV_LOG" \
   && ! grep -q '/contents/' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: actioned thread upgraded to rebuttal-recorded (INFO logged, no byte-compare)"
else
  fail=$((fail + 1))
  echo "  FAIL: actioned thread was not upgraded (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 10b: a thread anchored at a TEMPLATED entry's SOURCE path must NOT
# resolve as verified propagation (#616 finding 3509930343). The fixture
# manifest's templated entry has path/source examples/tpl.txt with dest
# rendered/out.txt — the consumer only ever receives the DEST, so a
# consumer file that happens to sit at examples/tpl.txt with bytes equal
# to the mergepath source is a coincidence, not propagation. Pre-fix,
# the canonical routing predicate matched ANY manifest `.paths[].path`
# (templated sources included) and byte-verified → wrong resolve. Now the
# canonical branch matches canonical/kit entries only, the templated
# branch routes by dest, so this thread is skipped
# not-propagation-routed: exit 3, no mutations, no contents fetch.
# (Test 7 corrupted examples/tpl.txt in the fixture tree; irrelevant here
# — the consumer fixture copies whatever the current source bytes are, so
# the pre-fix byte-compare would still match.)
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 10b: templated SOURCE path coincidence never verifies as canonical (#616)"

make_thread_fixture "PRT_VP10B" "examples/tpl.txt" "coderabbitai" \
  "Finding on a file at the templated source path" "OLDCOMMIT0" \
  "$SCRATCH/threads_vp10b.json"
CONSUMER_TPL_SOURCE_COPY="$SCRATCH/consumer-tpl-source-copy.txt"
cp "$FIXTURE_ROOT/examples/tpl.txt" "$CONSUMER_TPL_SOURCE_COPY"
if ! cmp -s "$FIXTURE_ROOT/examples/tpl.txt" "$CONSUMER_TPL_SOURCE_COPY"; then
  fail=$((fail + 1))
  echo "  FAIL: precondition — consumer fixture must byte-match the templated source" >&2
fi

GH_ARGV_LOG="$SCRATCH/t10b.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp10b.json" "$CONSUMER_TPL_SOURCE_COPY"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (not propagation-routed)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG" \
   && ! grep -q '/contents/' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: templated-source-path thread skipped not-propagation-routed (no mutations, no contents fetch)"
else
  fail=$((fail + 1))
  echo "  FAIL: templated-source-path thread was treated as canonical coverage (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Tests 11–13: the #616 (finding 3509734393) CI-only yq bootstrap.
# scripts/lib/ensure-yq.sh is the single source for the pinned mikefarah
# yq install; check_resolve_pr_threads self-bootstraps through it under
# GITHUB_ACTIONS=true so the consumer-side skew window (scripts/ci kit
# via manifest sync vs repo_lint.yml via template-mirror, #601) cannot
# leave this suite red on a runner with no yq. All offline: sudo/wget
# are PATH shims, the install destination is a scratch dir.
# ─────────────────────────────────────────────────────────────────────
ENSURE_YQ="$ROOT/scripts/lib/ensure-yq.sh"
YQBOOT_LOG="$SCRATCH/yqboot-installer.log"

# Shim bin for the "yq missing" runs: sudo strips itself and execs the
# rest (so wget/chmod resolve to the stubs/symlinks here); wget records
# the URL and writes a fake mikefarah yq to the -O destination.
YQBOOT_BIN="$SCRATCH/yqboot-bin"
mkdir -p "$YQBOOT_BIN" "$SCRATCH/yqboot-dest"
ln -s "$(command -v chmod)" "$YQBOOT_BIN/chmod"
cat > "$YQBOOT_BIN/sudo" <<SUDO_STUB
#!/bin/sh
echo "SUDO: \$*" >> "$YQBOOT_LOG"
exec "\$@"
SUDO_STUB
chmod +x "$YQBOOT_BIN/sudo"
cat > "$YQBOOT_BIN/wget" <<WGET_STUB
#!/bin/sh
dest=""
url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -q) shift ;;
    -O) dest="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
  esac
done
echo "WGET: \$url" >> "$YQBOOT_LOG"
printf '%s\n%s\n' '#!/bin/sh' \
  'echo "yq (https://github.com/mikefarah/yq/) version v4.44.3"' > "\$dest"
chmod +x "\$dest"
WGET_STUB
chmod +x "$YQBOOT_BIN/wget"

# Shim bin for the "mikefarah yq present" run: fake yq + the grep the
# short-circuit's version sniff needs; same sudo/wget stubs so any
# (wrong) install attempt is visible in the log.
YQPRESENT_BIN="$SCRATCH/yqpresent-bin"
mkdir -p "$YQPRESENT_BIN"
ln -s "$(command -v grep)" "$YQPRESENT_BIN/grep"
ln -s "$YQBOOT_BIN/sudo" "$YQPRESENT_BIN/sudo"
ln -s "$YQBOOT_BIN/wget" "$YQPRESENT_BIN/wget"
cat > "$YQPRESENT_BIN/yq" <<'YQ_FAKE'
#!/bin/sh
echo "yq (https://github.com/mikefarah/yq/) version v4.44.3"
YQ_FAKE
chmod +x "$YQPRESENT_BIN/yq"

echo
echo "Test 11: ensure-yq.sh short-circuits on a present mikefarah yq (#616)"

: > "$YQBOOT_LOG"
set +e
out=$(env PATH="$YQPRESENT_BIN" "$BASH" "$ENSURE_YQ" 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ] \
   && grep -q 'yq already present' <<<"$out" \
   && [ ! -s "$YQBOOT_LOG" ]; then
  pass=$((pass + 1))
  echo "  PASS: present yq short-circuits with no installer calls"
else
  fail=$((fail + 1))
  echo "  FAIL: short-circuit broken (rc=$rc)" >&2
  echo "    output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    installer log:" >&2; sed 's/^/      /' "$YQBOOT_LOG" >&2 || true
fi

echo
echo "Test 12: ensure-yq.sh --ci-only gates on GITHUB_ACTIONS and installs pinned (#616)"

# 12a — NOT CI (GITHUB_ACTIONS explicitly unset; the suite itself may be
# running inside Actions): --ci-only must no-op successfully with no
# installer calls, leaving local runs to this suite's own hard yq error.
: > "$YQBOOT_LOG"
set +e
out_a=$(env -u GITHUB_ACTIONS PATH="$YQBOOT_BIN" "$BASH" "$ENSURE_YQ" --ci-only 2>&1)
rc_a=$?
set -e

# 12b — CI (GITHUB_ACTIONS=true), yq absent from the shim PATH: install
# the PINNED release via the stubbed sudo/wget (no network) into
# ENSURE_YQ_DEST, then verify the installed binary runs.
set +e
out_b=$(env GITHUB_ACTIONS=true PATH="$YQBOOT_BIN" \
  ENSURE_YQ_DEST="$SCRATCH/yqboot-dest/yq" \
  "$BASH" "$ENSURE_YQ" --ci-only 2>&1)
rc_b=$?
set -e

# 12c — CI, but a WRONG-implementation yq (the Python wrapper shape:
# `yq --version` with no mikefarah marker) is already on PATH (#616
# finding 3509930342). The short-circuit's implementation sniff must
# REJECT it and still install the pinned mikefarah release — the
# pre-#616 caller-side `command -v yq` gate skipped the bootstrap
# entirely in exactly this environment.
YQWRONG_BIN="$SCRATCH/yqwrong-bin"
mkdir -p "$YQWRONG_BIN" "$SCRATCH/yqboot-dest-c"
ln -s "$(command -v grep)" "$YQWRONG_BIN/grep"
ln -s "$YQBOOT_BIN/sudo" "$YQWRONG_BIN/sudo"
ln -s "$YQBOOT_BIN/wget" "$YQWRONG_BIN/wget"
ln -s "$(command -v chmod)" "$YQWRONG_BIN/chmod"
cat > "$YQWRONG_BIN/yq" <<'YQ_WRONG'
#!/bin/sh
echo "yq 3.4.3"
YQ_WRONG
chmod +x "$YQWRONG_BIN/yq"

set +e
out_c=$(env GITHUB_ACTIONS=true PATH="$YQWRONG_BIN" \
  ENSURE_YQ_DEST="$SCRATCH/yqboot-dest-c/yq" \
  "$BASH" "$ENSURE_YQ" --ci-only 2>&1)
rc_c=$?
set -e

if [ "$rc_a" -eq 0 ] \
   && grep -q 'not a CI run' <<<"$out_a" \
   && [ "$rc_b" -eq 0 ] \
   && grep -q 'WGET: https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64' "$YQBOOT_LOG" \
   && [ -x "$SCRATCH/yqboot-dest/yq" ] \
   && grep -q 'version v4.44.3' <<<"$out_b" \
   && [ "$rc_c" -eq 0 ] \
   && ! grep -q 'yq already present' <<<"$out_c" \
   && [ -x "$SCRATCH/yqboot-dest-c/yq" ] \
   && grep -q 'version v4.44.3' <<<"$out_c"; then
  pass=$((pass + 1))
  echo "  PASS: non-CI no-op; CI installs pinned when yq is missing AND when a wrong-implementation yq is on PATH"
else
  fail=$((fail + 1))
  echo "  FAIL: --ci-only gating, pinned install, or wrong-impl detection broken (rc_a=$rc_a rc_b=$rc_b rc_c=$rc_c)" >&2
  echo "    non-CI output:" >&2; echo "$out_a" | sed 's/^/      /' >&2
  echo "    CI output:" >&2; echo "$out_b" | sed 's/^/      /' >&2
  echo "    wrong-impl output:" >&2; echo "$out_c" | sed 's/^/      /' >&2
  echo "    installer log:" >&2; sed 's/^/      /' "$YQBOOT_LOG" >&2 || true
fi

echo
echo "Test 13: check_resolve_pr_threads wires the CI-only yq bootstrap (#616)"

CHECK_WRAPPER="$ROOT/scripts/ci/check_resolve_pr_threads"
# Structural: the wrapper must (a) exist alongside the lib, (b) delegate
# to the shared lib with --ci-only, and (c) delegate UNCONDITIONALLY —
# no `command -v yq` gate around the bootstrap. The pre-#616-round-3
# shape only invoked ensure-yq.sh when yq was MISSING, so a
# wrong-implementation yq on PATH (the Python wrapper) skipped the
# bootstrap and the delegated suite failed later with parser errors
# (finding 3509930342); implementation detection is single-sourced in
# ensure-yq.sh's short-circuit. The wrapper and this test travel in the
# same sync wave (scripts/ci kit + canonical tests/ entry), so asserting
# on its contents is skew-safe. The negative grep scans only the
# wrapper's CODE lines (comments stripped) so prose ABOUT the old gate
# does not trip it.
CHECK_WRAPPER_CODE=$(sed 's/[[:space:]]*#.*$//' "$CHECK_WRAPPER" 2>/dev/null || true)
if [ -f "$CHECK_WRAPPER" ] \
   && [ -f "$ENSURE_YQ" ] \
   && grep -q 'scripts/lib/ensure-yq.sh' "$CHECK_WRAPPER" \
   && grep -Eq 'ensure-yq\.sh[^#]*--ci-only|"\$ENSURE_YQ" --ci-only' "$CHECK_WRAPPER" \
   && ! grep -q 'command -v yq' <<<"$CHECK_WRAPPER_CODE"; then
  pass=$((pass + 1))
  echo "  PASS: wrapper delegates unconditionally to ensure-yq.sh --ci-only (no command -v yq gate)"
else
  fail=$((fail + 1))
  echo "  FAIL: check_resolve_pr_threads must delegate to ensure-yq.sh --ci-only WITHOUT a command -v yq gate (#616 finding 3509930342)" >&2
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "test_resolve_pr_threads_verified_propagation: PASS ($pass tests)"
  exit 0
else
  echo "test_resolve_pr_threads_verified_propagation: FAIL ($fail of $((pass + fail)) tests)" >&2
  exit 1
fi
