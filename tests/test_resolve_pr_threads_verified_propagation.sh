#!/usr/bin/env bash
# tests/test_resolve_pr_threads_verified_propagation.sh
#
# Tests the #572 `--resolve-verified-propagation` mode in
# scripts/resolve-pr-threads.sh.
#
# The mode drains the routing-class residual on consumer sync PRs
# (canonical-coverage / templated-render threads, the #562 backlog):
# routing alone (path membership) never resolves, but when the consumer's
# content at the COMPARED REF (the PR head while the PR is open, the
# default branch pinned to its tip SHA once closed/merged — #616)
# byte-matches mergepath's canonical source (or the re-rendered template
# with the consumer's facts) AT THE COMMITTED HEAD (#616: uncommitted
# working-tree edits never count as propagation sources), the tree
# entry's mode/type matches the source, and the source
# carries an upstream fix commit newer than the finding, the propagation
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
#  14. OPEN-PR compare ref (#616 finding 3510170875): while the target PR
#      is open the byte-compare reads the PR HEAD (ref=<head sha>), not
#      the default branch. 14: head drift skips even when the default
#      branch byte-matches (pre-fix this resolved — REGRESSION, fails
#      pre-fix). 14b: a byte-matching head resolves even when the
#      default branch drifts (also fails pre-fix, locking that open PRs
#      are compared, not blanket-skipped).
#  15. Upstream-fix evidence gate (#616 finding 3510170879): a byte-match
#      whose mergepath source has NO commit strictly newer than the
#      finding's staleness floor skips fail-closed under the dedicated
#      no-upstream-evidence counter (pre-fix this resolved — REGRESSION,
#      fails pre-fix). The proceed direction (commit newer than the
#      floor) is locked by tests 1/2/8/9: the fixture repo's commit is
#      backdated to 2026-02-01, after their threads' 2026-01-01
#      createdAt.
#  16. Tree-entry mode/type gate (#616 finding 3510170883): byte-equal
#      content whose consumer tree entry is chmod-flipped (100755 blob
#      vs the committed 100644 source) skips as drift (pre-fix this
#      resolved — REGRESSION, fails pre-fix); 16b: a trees-API lookup
#      failure skips fail-closed (verification error).
#  17. Committed-source compare (#616 finding 3510442268) — REGRESSION,
#      fails pre-fix: an UNCOMMITTED working-tree edit to the canonical
#      source diverges from HEAD, and the consumer byte-matches the
#      EDIT. Pre-fix the compare read the working tree and resolved
#      even though the committed source that actually propagates
#      differs; post-fix the compare reads HEAD and skips as drift.
#      17b (also fails pre-fix): with the working tree still dirty, a
#      consumer byte-matching the COMMITTED HEAD resolves — a dirty
#      source never blocks (or fakes) a genuine committed match.
#  18. Default-branch SHA pinning (#616 finding 3510442271) —
#      REGRESSION, fails pre-fix: for a closed PR the compare ref must
#      be the default branch's tip commit SHA resolved ONCE
#      (git/ref/heads/<branch>, stub tip DEFAULTTIP0), and BOTH the
#      contents fetch and the git-trees fetch must carry that pinned
#      SHA — never the branch name, which each API would re-resolve
#      independently while the branch advances. 18b: a tip-resolution
#      failure skips fail-closed (verification error).
#  19. Committed-manifest render inputs (#616 finding 3510689518) —
#      REGRESSION, fails pre-fix: an UNCOMMITTED working-tree edit to a
#      consumer fact in .mergepath-sync.yml renders output the consumer
#      byte-matches. Pre-fix the facts (and templated-entry lookups)
#      came from the working-tree manifest while the template bytes
#      came from committed HEAD, so the thread resolved even though the
#      COMMITTED manifest renders different bytes; post-fix every
#      render input reads a committed manifest snapshot and the compare
#      skips as drift. 19b (also fails pre-fix): with the manifest
#      still dirty, a consumer matching the COMMITTED-manifest render
#      resolves — dirty facts neither fake a match nor block a genuine
#      committed one.
#  20. repo_lint.yml install_yq_for_sync_manifest reverse-skew fallback
#      (#616 finding 3510689523) — scripted execution of the extracted
#      run block, CANONICAL CHECKOUT ONLY (repo_lint.yml travels on the
#      template-mirror lane, not this test's manifest wave, so consumer
#      checkouts skip-pass; gate: scripts/sync-to-downstream.sh): the
#      fallback must REJECT a wrong-implementation yq with a loud
#      pointer at ensure-yq.sh (20a — fails pre-fix: the bare
#      `command -v yq` accepted any executable named yq), accept a
#      mikefarah yq (20b), and delegate to scripts/lib/ensure-yq.sh
#      when the lib is present (20c).
#  21. Commit→tree peel for the git-trees fetch (#616 finding
#      3510689525): CONSUMER_COMPARE_REF is a COMMIT sha, but the
#      git/trees endpoint's documented parameter is a TREE sha (or ref
#      name) — the trees call must receive the peeled tree
#      (commits/<sha> → .commit.tree.sha; stub: HEADCURRENT→TREEHEAD0,
#      DEFAULTTIP0→TREEDEFAULT0). Positive direction locked by the
#      updated 14b/18 trees-URL asserts (both fail pre-fix); 21: a
#      peel failure skips fail-closed (verification error) with no
#      trees fetch.

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

# The #616 upstream-fix evidence gate requires REPO_ROOT_FOR_MANIFEST to
# be a git work tree whose latest commit touching the mergepath source is
# STRICTLY NEWER than the finding's staleness floor, and the tree-entry
# gate reads the source's COMMITTED mode via `git ls-tree HEAD`. Make the
# fixture tree a real git repo with one BACKDATED commit (2026-02-01):
# newer than the default thread createdAt (2026-01-01 → evidence present
# for the happy-path tests) and older than test 15's createdAt
# (2026-03-01 → no evidence, fail-closed skip). The byte-compare and the
# templated render ALSO read the COMMITTED HEAD (#616 finding
# 3510442268), so test 7 COMMITS its template corruption (an uncommitted
# one would be invisible to the verifier) and test 17 relies on an
# uncommitted edit being ignored.
git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" add -A
GIT_AUTHOR_DATE="2026-02-01T00:00:00Z" GIT_COMMITTER_DATE="2026-02-01T00:00:00Z" \
  git -C "$FIXTURE_ROOT" -c user.name=fixture -c user.email=fixture@example.com \
  -c commit.gpgsign=false commit -q -m "fixture tree (backdated for the #616 evidence gate)"

# make_gh_stub <stub-path> <threads-file>
# Routes graphql calls on the recorded lastcall body (same shape as the
# sibling resolve-pr-threads tests) plus the #572/#616 REST routes:
#   repos/*/contents/*  → consumer content: the DEFAULT-BRANCH fixture
#                         ($CONSUMER_CONTENT_FILE) normally, the PR-HEAD
#                         fixture ($CONSUMER_HEAD_CONTENT_FILE, falling
#                         back to the default-branch one) when the URL
#                         carries ref=HEADCURRENT (#616 3510170875), or a
#                         hard failure when GH_STUB_FAIL_CONTENTS=1
#   repos/*/git/trees/* → the consumer tree listing ($CONSUMER_TREE_FILE;
#                         #616 3510170883), or a hard failure when
#                         GH_STUB_FAIL_TREES=1
#   repos/*/commits/<sha> with --jq .commit.tree.sha → the commit→tree
#                         peel (#616 3510689525): HEADCURRENT →
#                         "TREEHEAD0", DEFAULTTIP0 → "TREEDEFAULT0"
#                         (anything else hard-fails — the peel must only
#                         ever see the pinned compare ref), or a hard
#                         failure when GH_STUB_FAIL_COMMIT_TREE=1; any
#                         other jq keeps the commit-files "[]" shape
#   repos/*/git/ref/heads/* → the default branch's tip commit SHA
#                         ("DEFAULTTIP0" — the pinned compare ref for
#                         closed PRs, #616 3510442271), or a hard
#                         failure when GH_STUB_FAIL_REF=1
#   repos/*/pulls/<n>   → --jq .head.sha → "HEADCURRENT"; --jq .state →
#                         $GH_STUB_PR_STATE (default "closed", the #562
#                         backlog shape; #616 3510170875)
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
        case "\$__url" in
          *"ref=HEADCURRENT"*)
            # Open-PR compare ref — serve the PR HEAD's content (#616).
            cat "\${CONSUMER_HEAD_CONTENT_FILE:-\$CONSUMER_CONTENT_FILE}"
            ;;
          *)
            cat "\$CONSUMER_CONTENT_FILE"
            ;;
        esac
        ;;
      "repos/"*"/git/trees/"*)
        if [ -n "\${GH_STUB_FAIL_TREES:-}" ]; then
          echo "simulated trees fetch failure" >&2
          exit 1
        fi
        cat "\$CONSUMER_TREE_FILE"
        ;;
      "repos/"*"/git/ref/heads/"*)
        if [ -n "\${GH_STUB_FAIL_REF:-}" ]; then
          echo "simulated ref resolution failure" >&2
          exit 1
        fi
        echo "DEFAULTTIP0"
        ;;
      "repos/"*"/pulls/"*"/files"*)
        echo '[]'
        ;;
      "repos/"*"/pulls/"*"/commits"*)
        echo '[]'
        ;;
      "repos/"*"/commits/"*)
        # Two readers hit this endpoint: the commit-files cache
        # (--jq '[.files[].filename]' → keep the "[]" shape) and the
        # #616 (finding 3510689525) commit→tree peel
        # (--jq .commit.tree.sha → the compare commit's TREE sha).
        # Route on the jq expression, like the pulls scalar route.
        if printf '%s\n' "\$@" | grep -qxF '.commit.tree.sha'; then
          if [ -n "\${GH_STUB_FAIL_COMMIT_TREE:-}" ]; then
            echo "simulated commit-to-tree resolution failure" >&2
            exit 1
          fi
          case "\$__url" in
            *"/commits/HEADCURRENT") echo "TREEHEAD0" ;;
            *"/commits/DEFAULTTIP0") echo "TREEDEFAULT0" ;;
            *)
              echo "commit-to-tree peel saw an unexpected commit sha: \$__url" >&2
              exit 1
              ;;
          esac
        else
          echo '[]'
        fi
        ;;
      "repos/"*"/pulls/"*)
        # Two scalars come off this endpoint: --jq .head.sha (HEAD oid)
        # and --jq .state (compare-ref selection, #616). Route on the jq
        # expression present in argv.
        if printf '%s\n' "\$@" | grep -qxF '.state'; then
          echo "\${GH_STUB_PR_STATE:-closed}"
        else
          echo "HEADCURRENT"
        fi
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

# make_thread_fixture <thread-id> <path> <author> <body> <oid> <out-file> \
#     [created-at]
# Single non-truncated bot (or human) thread — the enumeration shape the
# script projects. The optional created-at (default 2026-01-01, BEFORE the
# fixture repo's backdated 2026-02-01 commit) is the finding's staleness
# floor for the #616 upstream-evidence gate; test 15 pushes it past the
# commit date.
make_thread_fixture() {
  local thread_id="$1" anchor_path="$2" author="$3" body="$4" oid="$5" out_file="$6"
  local created="${7:-2026-01-01T00:00:00Z}"
  jq -nc --arg id "$thread_id" --arg p "$anchor_path" \
     --arg a "$author" --arg b "$body" --arg o "$oid" --arg c "$created" '
    {data:{repository:{pullRequest:{reviewThreads:{
      totalCount: 1,
      pageInfo: {hasNextPage: false, endCursor: null},
      nodes: [{
        id: $id, isResolved: false, isOutdated: false,
        commentsFirst: {nodes: [{
          author: {login: $a}, path: $p, body: $b,
          createdAt: $c
        }]},
        commentsLast: {nodes: [{commit: {oid: $o}}]},
        allComments: {
          totalCount: 1,
          pageInfo: {hasPreviousPage: false},
          nodes: [{author: {login: $a}, body: $b, databaseId: 1001,
                   createdAt: $c}]
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
# sets $out and $rc. Extra env via the RUN_* variables:
#   RUN_FAIL_CONTENTS=1        contents fetch hard-fails
#   RUN_FAIL_TREES=1           git-trees fetch hard-fails (#616)
#   RUN_FAIL_REF=1             default-branch tip resolution hard-fails
#                              (#616 finding 3510442271)
#   RUN_FAIL_COMMIT_TREE=1     commit→tree peel hard-fails (#616 finding
#                              3510689525)
#   RUN_PR_STATE=open|closed   PR state served to --jq .state
#                              (default closed — the #562 backlog shape)
#   RUN_HEAD_CONTENT_FILE=...  content served at ref=HEADCURRENT (open-PR
#                              compare; default: same as <content-file>)
#   RUN_TREE_MODE=100755       mode reported for every consumer tree
#                              entry (default 100644, matching the
#                              fixture repo's committed modes)
#   RUN_TREE_FILE=...          full override of the tree listing
run_mode() {
  local threads_file="$1" content_file="$2"
  shift 2
  make_gh_stub "$SCRATCH/gh-real" "$threads_file"
  make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"
  local tree_file="${RUN_TREE_FILE:-$SCRATCH/consumer-tree.json}"
  if [ -z "${RUN_TREE_FILE:-}" ]; then
    jq -n --arg m "${RUN_TREE_MODE:-100644}" '{
      truncated: false,
      tree: [
        {path: "docs/canonical.md", mode: $m, type: "blob"},
        {path: "rendered/out.txt",  mode: $m, type: "blob"}
      ]
    }' > "$tree_file"
  fi
  set +e
  out=$(
    GH_ARGV_LOG="$GH_ARGV_LOG" \
    CONSUMER_CONTENT_FILE="$content_file" \
    CONSUMER_HEAD_CONTENT_FILE="${RUN_HEAD_CONTENT_FILE:-}" \
    CONSUMER_TREE_FILE="$tree_file" \
    GH_STUB_FAIL_CONTENTS="${RUN_FAIL_CONTENTS:-}" \
    GH_STUB_FAIL_TREES="${RUN_FAIL_TREES:-}" \
    GH_STUB_FAIL_REF="${RUN_FAIL_REF:-}" \
    GH_STUB_FAIL_COMMIT_TREE="${RUN_FAIL_COMMIT_TREE:-}" \
    GH_STUB_PR_STATE="${RUN_PR_STATE:-closed}" \
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
# NOTE: rewrites AND COMMITS the fixture template (the verifier renders
# the COMMITTED HEAD bytes, #616 finding 3510442268 — an uncommitted
# corruption would be invisible), so any test needing the good template
# must run BEFORE this one. Backdated like the fixture commit; the
# commit touches only examples/tpl.txt, so docs/canonical.md keeps its
# 2026-02-01 evidence timestamp for the later tests.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 7: template render failure → skipped fail-closed (#572)"

cat > "$FIXTURE_ROOT/examples/tpl.txt" <<'TPL'
# >>> if frameworks contains react
react block enabled — but the conditional is never closed
TPL
git -C "$FIXTURE_ROOT" add examples/tpl.txt
GIT_AUTHOR_DATE="2026-02-01T00:00:00Z" GIT_COMMITTER_DATE="2026-02-01T00:00:00Z" \
  git -C "$FIXTURE_ROOT" -c user.name=fixture -c user.email=fixture@example.com \
  -c commit.gpgsign=false commit -q -m "corrupt the template (test 7 — committed: the verifier reads HEAD)"

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

# ─────────────────────────────────────────────────────────────────────
# Test 14: OPEN-PR compare ref (#616 finding 3510170875) — REGRESSION,
# fails pre-fix. The target PR is OPEN and its HEAD drifts from the
# canonical source while the DEFAULT BRANCH byte-matches. Pre-fix the
# mode compared the default branch and RESOLVED the thread even though
# the content being merged still carried drift; post-fix the compare
# reads ref=HEADCURRENT (the PR head sha) and skips as drift. Reuses the
# canonical-arm thread fixture (threads_vp1).
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 14: open PR — head drift skips even when the default branch matches (#616)"

GH_ARGV_LOG="$SCRATCH/t14.log"; : > "$GH_ARGV_LOG"
RUN_PR_STATE=open RUN_HEAD_CONTENT_FILE="$CONSUMER_DRIFT_CANONICAL" \
  run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation NOT verified — content drift)' <<<"$out" \
   && grep -q 'contents/docs/canonical.md?ref=HEADCURRENT' "$GH_ARGV_LOG" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: open-PR compare read the PR head (ref=HEADCURRENT) and skipped the drift"
else
  fail=$((fail + 1))
  echo "  FAIL: open-PR head drift was not skipped (rc=$rc) — default-branch match resolved over PR-head drift?" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 14b: the other direction — the OPEN PR's head byte-matches while
# the default branch drifts → the thread RESOLVES on the head compare.
# Locks that open PRs are genuinely compared against their head, not
# blanket-skipped (also fails pre-fix: the default-branch compare saw
# drift and skipped).
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 14b: open PR — byte-matching head resolves even when the default branch drifts (#616)"

GH_ARGV_LOG="$SCRATCH/t14b.log"; : > "$GH_ARGV_LOG"
RUN_PR_STATE=open RUN_HEAD_CONTENT_FILE="$CONSUMER_MATCH_CANONICAL" \
  run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_DRIFT_CANONICAL"

if [ "$rc" -eq 0 ] \
   && grep -q 'contents/docs/canonical.md?ref=HEADCURRENT' "$GH_ARGV_LOG" \
   && grep -q 'git/trees/TREEHEAD0?recursive=1' "$GH_ARGV_LOG" \
   && ! grep -q 'git/trees/HEADCURRENT' "$GH_ARGV_LOG" \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: verified-propagation\] consumer content at docs/canonical.md byte-matches the mergepath canonical source' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: open-PR head byte-match resolved via the head compare (trees read the peeled TREE sha)"
else
  fail=$((fail + 1))
  echo "  FAIL: open-PR byte-matching head did not resolve (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 15: upstream-fix evidence gate (#616 finding 3510170879) —
# REGRESSION, fails pre-fix. The thread's createdAt (2026-03-01) is
# NEWER than the fixture repo's only commit touching docs/canonical.md
# (backdated 2026-02-01), so a byte-match proves only that the consumer
# mirrors the CURRENT — possibly still-problematic — source. Pre-fix the
# byte-match resolved and buried the finding; post-fix it skips
# fail-closed under the dedicated no-upstream-evidence counter. The
# proceed direction (commit strictly newer than the floor) is locked by
# tests 1/2/8/9/14b, whose threads pre-date the commit.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 15: byte-match without a newer upstream fix commit skips fail-closed (#616)"

make_thread_fixture "PRT_VP15" "docs/canonical.md" "coderabbitai" \
  "Finding newer than the last upstream commit" "OLDCOMMIT0" \
  "$SCRATCH/threads_vp15.json" "2026-03-01T00:00:00Z"

GH_ARGV_LOG="$SCRATCH/t15.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp15.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (no upstream-fix evidence — failing closed)' <<<"$out" \
   && grep -q 'byte-match without upstream-fix evidence' <<<"$out" \
   && grep -q 'Skipped (no-upstream-evidence): 1' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: no-newer-commit byte-match skipped fail-closed (dedicated counter), exit 3, no mutations"
else
  fail=$((fail + 1))
  echo "  FAIL: byte-match without upstream evidence was not skipped (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 16: tree-entry mode/type gate (#616 finding 3510170883) —
# REGRESSION, fails pre-fix. The consumer bytes equal the canonical
# source but the consumer tree entry is chmod-flipped (100755 blob vs
# the fixture repo's committed 100644 blob). The real propagation
# verifier (verify-propagation-pr.sh) rejects exactly this metadata
# drift; pre-fix the byte-only compare resolved it. Post-fix it skips
# as drift with the tree-entry reason.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 16: chmod-flipped consumer tree entry skips despite byte-equal content (#616)"

GH_ARGV_LOG="$SCRATCH/t16.log"; : > "$GH_ARGV_LOG"
RUN_TREE_MODE=100755 run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation NOT verified — content drift)' <<<"$out" \
   && grep -q 'consumer tree entry for docs/canonical.md is \[100755 blob\], expected \[100644 blob\]' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: mode-flipped tree entry skipped as drift (byte-equality was not sufficient)"
else
  fail=$((fail + 1))
  echo "  FAIL: chmod-flipped consumer entry was not rejected (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 16b: a git-trees lookup failure is a fail-closed VERIFICATION
# ERROR — an entry whose mode/type cannot be read never resolves.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 16b: trees-API lookup failure skips fail-closed (#616)"

GH_ARGV_LOG="$SCRATCH/t16b.log"; : > "$GH_ARGV_LOG"
RUN_FAIL_TREES=1 run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation verification failed — failing closed)' <<<"$out" \
   && grep -q 'could not read the consumer tree entry for docs/canonical.md' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: unreadable tree entry skipped fail-closed, exit 3, no mutations"
else
  fail=$((fail + 1))
  echo "  FAIL: trees lookup failure did not fail closed (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 17: committed-source compare (#616 finding 3510442268) —
# REGRESSION, fails pre-fix. The fixture repo's docs/canonical.md gets
# an UNCOMMITTED working-tree edit; the consumer byte-matches the EDIT,
# not the committed HEAD. Pre-fix the byte-compare read the working
# tree while the tree-entry gate (ls-tree HEAD) and the evidence gate
# (git log) read HEAD, so the divergent trio RESOLVED the thread even
# though the committed source that will actually propagate carries
# different bytes; post-fix the compare reads HEAD (git show) and skips
# as drift. Uncommitted local edits never count as propagation sources.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 17: consumer matching an UNCOMMITTED working-tree edit skips as drift (#616)"

cat > "$FIXTURE_ROOT/docs/canonical.md" <<'MD'
# Canonical doc

Uncommitted local edit that has not propagated anywhere.
MD
CONSUMER_MATCH_DIRTY="$SCRATCH/consumer-canonical-dirty.md"
cp "$FIXTURE_ROOT/docs/canonical.md" "$CONSUMER_MATCH_DIRTY"
if cmp -s <(git -C "$FIXTURE_ROOT" show HEAD:docs/canonical.md) "$CONSUMER_MATCH_DIRTY"; then
  fail=$((fail + 1))
  echo "  FAIL: precondition — the dirty edit must diverge from the committed HEAD" >&2
fi

GH_ARGV_LOG="$SCRATCH/t17.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_DIRTY"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation NOT verified — content drift)' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: working-tree-edit byte-match skipped as drift (compare reads the committed HEAD)"
else
  fail=$((fail + 1))
  echo "  FAIL: consumer matching an uncommitted edit was not skipped (rc=$rc) — compare read the working tree?" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 17b: the other direction (also fails pre-fix) — the working tree
# is STILL dirty, but the consumer byte-matches the COMMITTED HEAD →
# resolves. A dirty source file neither fakes a match (17) nor blocks a
# genuine committed one (17b); the compare is pinned to HEAD, the same
# state the tree-entry and evidence gates read. Restores the working
# tree afterwards.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 17b: consumer matching the COMMITTED HEAD resolves despite a dirty working tree (#616)"

GH_ARGV_LOG="$SCRATCH/t17b.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 0 ] \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: verified-propagation\] consumer content at docs/canonical.md byte-matches the mergepath canonical source' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: committed-HEAD byte-match resolved; the dirty working tree was ignored"
else
  fail=$((fail + 1))
  echo "  FAIL: committed-HEAD match did not resolve under a dirty working tree (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

git -C "$FIXTURE_ROOT" checkout -q -- docs/canonical.md

# ─────────────────────────────────────────────────────────────────────
# Test 18: default-branch SHA pinning (#616 finding 3510442271) —
# REGRESSION, fails pre-fix. For a closed PR the compare ref must be
# the default branch's tip commit SHA, resolved exactly ONCE via
# git/ref/heads/<branch> (stub tip: DEFAULTTIP0) and carried by BOTH
# the contents fetch and the git-trees fetch. Pre-fix the stored ref
# was the branch NAME ("main"), which the two APIs re-resolved
# independently — a branch advancing between the reads lets the
# byte-compare and the mode/type gate see different commits and still
# resolve. #616 finding 3510689525 layers the commit→tree peel on top
# (also fails pre-peel-fix): the git-trees fetch must receive the
# pinned commit's PEELED TREE sha (commits/DEFAULTTIP0 →
# .commit.tree.sha → TREEDEFAULT0, resolved exactly once), never the
# commit sha the endpoint's contract does not document.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 18: closed-PR compare pins both fetches to the default-branch tip SHA (#616)"

GH_ARGV_LOG="$SCRATCH/t18.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 0 ] \
   && [ "$(grep -c 'git/ref/heads/main' "$GH_ARGV_LOG")" -eq 1 ] \
   && grep -q 'contents/docs/canonical.md?ref=DEFAULTTIP0' "$GH_ARGV_LOG" \
   && [ "$(grep -c 'commits/DEFAULTTIP0' "$GH_ARGV_LOG")" -eq 1 ] \
   && grep -q 'git/trees/TREEDEFAULT0?recursive=1' "$GH_ARGV_LOG" \
   && ! grep -q 'git/trees/DEFAULTTIP0' "$GH_ARGV_LOG" \
   && ! grep -qF '?ref=main' "$GH_ARGV_LOG" \
   && ! grep -qF 'git/trees/main' "$GH_ARGV_LOG" \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: one tip resolution; contents reads ref=DEFAULTTIP0, trees reads the peeled TREEDEFAULT0 (one peel), never the branch name or the commit sha"
else
  fail=$((fail + 1))
  echo "  FAIL: compare fetches were not pinned to the tip SHA (rc=$rc) — branch-name ref leaked, or the trees fetch got the commit sha instead of the peeled tree?" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 18b: a default-branch tip resolution failure is a fail-closed
# VERIFICATION ERROR — with no pinned SHA the compare ref is
# unresolved, so the content fetch never runs and nothing resolves.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 18b: tip-resolution failure skips fail-closed (#616)"

GH_ARGV_LOG="$SCRATCH/t18b.log"; : > "$GH_ARGV_LOG"
RUN_FAIL_REF=1 run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation verification failed — failing closed)' <<<"$out" \
   && grep -q 'could not fetch test/consumer:docs/canonical.md' <<<"$out" \
   && ! grep -q '/contents/' "$GH_ARGV_LOG" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: unresolvable tip skipped fail-closed (no content fetch), exit 3, no mutations"
else
  fail=$((fail + 1))
  echo "  FAIL: tip-resolution failure did not fail closed (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 19: committed-manifest render inputs (#616 finding 3510689518) —
# REGRESSION, fails pre-fix. The fixture manifest gets an UNCOMMITTED
# working-tree edit to a consumer fact (greeting: hola → bonjour); the
# consumer's content byte-matches the DIRTY render. Pre-fix the facts
# (and the templated-entry lookup) were exported from the working-tree
# .mergepath-sync.yml while the template bytes came from committed
# HEAD, so the divergent pair RESOLVED the thread even though the
# committed manifest that could actually have propagated renders
# different bytes; post-fix every render input reads the committed
# manifest snapshot and the compare skips as drift. First restores the
# good template (test 7 corrupted AND committed it), backdated like the
# other fixture commits so the evidence gate still holds.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 19: consumer matching an UNCOMMITTED manifest fact edit skips as drift (#616)"

cat > "$FIXTURE_ROOT/examples/tpl.txt" <<'TPL'
# >>> if frameworks contains react
react block enabled
# <<<
greeting is {{greeting}}
TPL
git -C "$FIXTURE_ROOT" add examples/tpl.txt
GIT_AUTHOR_DATE="2026-02-01T00:00:00Z" GIT_COMMITTER_DATE="2026-02-01T00:00:00Z" \
  git -C "$FIXTURE_ROOT" -c user.name=fixture -c user.email=fixture@example.com \
  -c commit.gpgsign=false commit -q -m "restore the template (tests 19+ render the committed HEAD)"

# UNCOMMITTED manifest edit — flip the greeting fact in the working
# tree only (portable sed-to-tmp: -i differs between BSD and GNU).
sed 's/greeting: hola/greeting: bonjour/' "$FIXTURE_ROOT/.mergepath-sync.yml" \
  > "$FIXTURE_ROOT/.mergepath-sync.yml.tmp"
mv "$FIXTURE_ROOT/.mergepath-sync.yml.tmp" "$FIXTURE_ROOT/.mergepath-sync.yml"
if git -C "$FIXTURE_ROOT" diff --quiet -- .mergepath-sync.yml; then
  fail=$((fail + 1))
  echo "  FAIL: precondition — the manifest fact edit must leave the working tree dirty" >&2
fi

# The consumer content matches the DIRTY-facts render, not the
# committed one.
CONSUMER_DIRTY_FACTS_RENDER="$SCRATCH/consumer-dirty-facts-render.txt"
cat > "$CONSUMER_DIRTY_FACTS_RENDER" <<'OUT'
react block enabled
greeting is bonjour
OUT

GH_ARGV_LOG="$SCRATCH/t19.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp2.json" "$CONSUMER_DIRTY_FACTS_RENDER"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation NOT verified — content drift)' <<<"$out" \
   && grep -q 'does NOT byte-match the re-rendered template examples/tpl.txt' <<<"$out" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: dirty-manifest render match skipped as drift (facts read the committed manifest)"
else
  fail=$((fail + 1))
  echo "  FAIL: consumer matching a dirty-manifest render was not skipped (rc=$rc) — facts read the working-tree manifest?" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 19b: the other direction (also fails pre-fix) — the manifest is
# STILL dirty, but the consumer byte-matches the COMMITTED-manifest
# render (greeting is hola) → resolves. Dirty facts neither fake a
# match (19) nor block a genuine committed one (19b); the render inputs
# are pinned to HEAD, the same state the template bytes, tree-entry and
# evidence gates read. Restores the manifest afterwards.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 19b: consumer matching the COMMITTED-manifest render resolves despite dirty facts (#616)"

GH_ARGV_LOG="$SCRATCH/t19b.log"; : > "$GH_ARGV_LOG"
run_mode "$SCRATCH/threads_vp2.json" "$EXPECTED_RENDER"

if [ "$rc" -eq 0 ] \
   && grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && grep -q 'FIELD: body=\[mergepath-resolve: verified-propagation\] consumer content at rendered/out.txt byte-matches the re-rendered template examples/tpl.txt (consumer=test-consumer)' "$GH_ARGV_LOG" \
   && grep -q 'Readback: all 1 resolved thread(s) confirmed isResolved:true' <<<"$out"; then
  pass=$((pass + 1))
  echo "  PASS: committed-manifest render match resolved; the dirty fact edit was ignored"
else
  fail=$((fail + 1))
  echo "  FAIL: committed-manifest render match did not resolve under a dirty manifest (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

git -C "$FIXTURE_ROOT" checkout -q -- .mergepath-sync.yml

# ─────────────────────────────────────────────────────────────────────
# Test 20: repo_lint.yml install_yq_for_sync_manifest fallback (#616
# finding 3510689523). The reverse-skew branch (workflow arrives before
# scripts/lib/ensure-yq.sh) must apply the same mikefarah
# implementation sniff ensure-yq.sh applies — a bare `command -v yq`
# accepts the Python wrapper and defers the failure to opaque
# mikefarah-v4 parse errors in the later manifest checks. Scripted
# check: extract the step's run block via yq and execute it against the
# shim PATHs. 20a (wrong-impl rejected) FAILS PRE-FIX; 20b/20c lock the
# accept and delegate branches.
#
# CANONICAL CHECKOUT ONLY: repo_lint.yml travels on the template-mirror
# lane, NOT the manifest wave this test travels on (#601), so a
# consumer checkout may legitimately carry an older workflow while this
# test is already current. Gate on scripts/sync-to-downstream.sh — the
# established mergepath-vs-consumer discriminator (intentionally never
# propagated; see check_sync_manifest) — and skip-pass on consumers.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 20: repo_lint.yml yq fallback rejects a wrong-implementation yq (#616)"

WORKFLOW_FILE="$ROOT/.github/workflows/repo_lint.yml"
if [ ! -f "$ROOT/scripts/sync-to-downstream.sh" ] || [ ! -f "$WORKFLOW_FILE" ]; then
  pass=$((pass + 1))
  echo "  SKIP-PASS: consumer checkout — repo_lint.yml is template-mirror-laned (#601), so only the canonical mergepath checkout is authoritative for its step contents"
else
  YQ_STEP_RUN=$(yq -r '
    .jobs[].steps[]
    | select(.name == "install_yq_for_sync_manifest")
    | .run
  ' "$WORKFLOW_FILE" 2>/dev/null) || YQ_STEP_RUN=""

  W20_EMPTY_CWD="$SCRATCH/w20-empty-cwd"
  W20_LIB_CWD="$SCRATCH/w20-lib-cwd"
  W20_DELEGATE_LOG="$SCRATCH/w20-delegate.log"
  mkdir -p "$W20_EMPTY_CWD" "$W20_LIB_CWD/scripts/lib"
  : > "$W20_DELEGATE_LOG"
  cat > "$W20_LIB_CWD/scripts/lib/ensure-yq.sh" <<DELEGATE_STUB
#!/bin/sh
echo "delegated" >> "$W20_DELEGATE_LOG"
DELEGATE_STUB
  W20_BASH_BIN="$SCRATCH/w20-bash-bin"
  mkdir -p "$W20_BASH_BIN"
  ln -s "$(command -v bash)" "$W20_BASH_BIN/bash"

  # 20a — wrong-implementation yq, lib absent (the reverse-skew
  # fallback): must FAIL loudly, pointing at ensure-yq.sh as the
  # resolution. REGRESSION — fails pre-fix.
  set +e
  out_wa=$(cd "$W20_EMPTY_CWD" && env PATH="$YQWRONG_BIN" "$BASH" -c "$YQ_STEP_RUN" 2>&1)
  rc_wa=$?
  set -e
  # 20b — mikefarah yq, lib absent: the fallback accepts it.
  set +e
  out_wb=$(cd "$W20_EMPTY_CWD" && env PATH="$YQPRESENT_BIN" "$BASH" -c "$YQ_STEP_RUN" 2>&1)
  rc_wb=$?
  set -e
  # 20c — lib present: delegates to scripts/lib/ensure-yq.sh (the
  # implementation sniff is single-sourced there; even a wrong yq on
  # PATH must not divert the primary branch).
  set +e
  out_wc=$(cd "$W20_LIB_CWD" && env PATH="$W20_BASH_BIN:$YQWRONG_BIN" "$BASH" -c "$YQ_STEP_RUN" 2>&1)
  rc_wc=$?
  set -e

  if [ -n "$YQ_STEP_RUN" ] \
     && [ "$rc_wa" -ne 0 ] \
     && grep -q 'ensure-yq.sh' <<<"$out_wa" \
     && [ "$rc_wb" -eq 0 ] \
     && grep -q 'using preinstalled' <<<"$out_wb" \
     && [ "$rc_wc" -eq 0 ] \
     && grep -q 'delegated' "$W20_DELEGATE_LOG"; then
    pass=$((pass + 1))
    echo "  PASS: fallback rejects a non-mikefarah yq (fail-loud), accepts mikefarah, and delegates when the lib is present"
  else
    fail=$((fail + 1))
    echo "  FAIL: install_yq_for_sync_manifest fallback shape wrong (rc_wa=$rc_wa rc_wb=$rc_wb rc_wc=$rc_wc)" >&2
    echo "    wrong-impl output:" >&2; echo "$out_wa" | sed 's/^/      /' >&2
    echo "    mikefarah output:" >&2; echo "$out_wb" | sed 's/^/      /' >&2
    echo "    lib-present output:" >&2; echo "$out_wc" | sed 's/^/      /' >&2
  fi
fi

# ─────────────────────────────────────────────────────────────────────
# Test 21: a commit→tree peel failure (#616 finding 3510689525) is a
# fail-closed VERIFICATION ERROR — byte-equal content whose compare
# commit cannot be resolved to its tree never resolves, and the trees
# endpoint is never called with an unpeeled ref. The positive
# direction (trees receives the peeled TREE sha) is locked by the
# updated 14b (open PR → TREEHEAD0) and 18 (closed PR → TREEDEFAULT0)
# asserts, both of which fail pre-fix.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 21: commit-to-tree peel failure skips fail-closed (#616)"

GH_ARGV_LOG="$SCRATCH/t21.log"; : > "$GH_ARGV_LOG"
RUN_FAIL_COMMIT_TREE=1 run_mode "$SCRATCH/threads_vp1.json" "$CONSUMER_MATCH_CANONICAL"

if [ "$rc" -eq 3 ] \
   && grep -q 'SKIP (propagation verification failed — failing closed)' <<<"$out" \
   && grep -q 'could not read the consumer tree entry for docs/canonical.md' <<<"$out" \
   && ! grep -q 'git/trees/' "$GH_ARGV_LOG" \
   && ! grep -q 'resolveReviewThread' "$GH_ARGV_LOG" \
   && ! grep -q 'addPullRequestReviewThreadReply' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: unpeelable compare commit skipped fail-closed (no trees fetch), exit 3, no mutations"
else
  fail=$((fail + 1))
  echo "  FAIL: commit-to-tree peel failure did not fail closed (rc=$rc)" >&2
  echo "    script output:" >&2; echo "$out" | sed 's/^/      /' >&2
  echo "    captured argv (tail):" >&2; tail -20 "$GH_ARGV_LOG" | sed 's/^/      /' >&2
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "test_resolve_pr_threads_verified_propagation: PASS ($pass tests)"
  exit 0
else
  echo "test_resolve_pr_threads_verified_propagation: FAIL ($fail of $((pass + fail)) tests)" >&2
  exit 1
fi
