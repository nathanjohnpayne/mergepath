#!/usr/bin/env bash
# tests/test_sync_to_downstream.sh
#
# Validates scripts/sync-to-downstream.sh against synthetic consumer
# fixtures. Builds a temp Mergepath worktree and a temp consumer
# worktree from scratch, points the script at them via the
# MERGEPATH_SIBLINGS_DIR env var, and checks that each manifest path
# type produces the expected status (ok / drift / missing) and the
# right exit code.
#
# Requires: yq (mikefarah/yq v4+), git. Run manually or from CI.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/sync-to-downstream.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed (brew install yq)" >&2
  exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: detected non-mikefarah yq" >&2
  exit 0
fi

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/sync-to-downstream-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a minimal "mergepath" with two canonical files and one kit dir
# ---------------------------------------------------------------------------
MP="$WORKDIR/mergepath"
mkdir -p "$MP/scripts/hooks" "$MP/scripts/ci" "$MP/scripts/sync" "$MP/scripts/lib" "$MP/.github/workflows"
echo "canonical-script-v1" >"$MP/scripts/keep-in-sync.sh"
echo "canonical-hook-v1"   >"$MP/scripts/hooks/the-hook.sh"
echo "kit-file-1" >"$MP/scripts/ci/check_one"
echo "kit-file-2" >"$MP/scripts/ci/check_two"

# sync-to-downstream.sh sources scripts/sync/apply-overrides.sh AND
# scripts/lib/manifest-fact-helpers.sh from its MERGEPATH_ROOT at
# startup (#199 / #323). Mirror both libs into the synthetic fixture
# so the source lines resolve instead of failing with "No such file
# or directory" — that regression would surface as the audit block
# tests above failing their existence check on the consumer-header line.
cp "$ROOT/scripts/sync/apply-overrides.sh" "$MP/scripts/sync/apply-overrides.sh"
cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$MP/scripts/lib/manifest-fact-helpers.sh"

cat >"$MP/.mergepath-sync.yml" <<'EOF'
version: 1
consumers:
  - {name: clean-consumer,  repo: x/clean-consumer}
  - {name: drifted,         repo: x/drifted}
  - {name: missing-everything, repo: x/missing-everything}
paths:
  - {path: scripts/keep-in-sync.sh,    type: canonical, consumers: all}
  - {path: scripts/hooks/the-hook.sh,  type: canonical, consumers: all}
  - {path: scripts/ci/,                type: kit,       consumers: all}
EOF

# git init each fake worktree — resolve_consumer_worktree() looks for .git/
git init -q "$MP"

SIBLINGS="$WORKDIR/siblings"
mkdir -p "$SIBLINGS"

# Consumer 1: clean (mirrors mergepath verbatim)
mkdir -p "$SIBLINGS/clean-consumer/scripts/hooks" "$SIBLINGS/clean-consumer/scripts/ci"
cp "$MP/scripts/keep-in-sync.sh"   "$SIBLINGS/clean-consumer/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$SIBLINGS/clean-consumer/scripts/hooks/the-hook.sh"
cp "$MP/scripts/ci/check_one"      "$SIBLINGS/clean-consumer/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$SIBLINGS/clean-consumer/scripts/ci/check_two"
# Add a consumer-only file in the kit dir to validate the allow-extras semantic
echo "consumer-extra" >"$SIBLINGS/clean-consumer/scripts/ci/check_consumer_only"
git init -q "$SIBLINGS/clean-consumer"

# Consumer 2: drifted (one canonical drifts, kit has one drifted file)
mkdir -p "$SIBLINGS/drifted/scripts/hooks" "$SIBLINGS/drifted/scripts/ci"
echo "MUTATED"                     >"$SIBLINGS/drifted/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$SIBLINGS/drifted/scripts/hooks/the-hook.sh"
echo "DRIFT"                       >"$SIBLINGS/drifted/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$SIBLINGS/drifted/scripts/ci/check_two"
git init -q "$SIBLINGS/drifted"

# Consumer 3: missing everything (no scripts/, no .github/, just a placeholder)
mkdir -p "$SIBLINGS/missing-everything"
echo "placeholder" >"$SIBLINGS/missing-everything/README.md"
git init -q "$SIBLINGS/missing-everything"

# ---------------------------------------------------------------------------
# Run the script against the fixture and capture output + exit code
# ---------------------------------------------------------------------------
cd "$MP"
set +e
output=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$SIBLINGS" \
  "$SCRIPT" --audit --no-clone 2>&1)
exit_code=$?
set -e

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
fail() { echo "FAIL: $*" >&2; echo "---output---" >&2; echo "$output" >&2; exit 1; }

# Exit 1 because at least one consumer drifts.
[[ "$exit_code" -eq 1 ]] || fail "expected exit 1 (drift), got $exit_code"

# Per-consumer header presence checks (#216). The awk block-parsers
# below use `/^<consumer-name>/` to extract a section, then grep for
# ✓/✗/⊘ markers and `&& fail` on a hit. If the header line ever changes
# shape (e.g., gains a leading prefix or a trailing suffix that breaks
# the literal awk regex), the awk filter produces an empty stream, the
# grep finds nothing, and the test silently passes — drift goes
# undetected. These three explicit header presence assertions turn that
# silent-pass into a loud failure.
echo "$output" | grep -q "^clean-consumer" \
  || fail "clean-consumer block missing from --audit output"
echo "$output" | grep -q "^drifted" \
  || fail "drifted block missing from --audit output"
echo "$output" | grep -q "^missing-everything" \
  || fail "missing-everything block missing from --audit output"

# Clean consumer: every line should be ✓ in sync (the consumer-only extra
# file under scripts/ci/ must NOT be flagged — kit type is allow-extras).
echo "$output" | awk '
  /^clean-consumer/ { in_block=1; next }
  /^[a-z]/ && in_block { exit }
  in_block && /^  / { print }
' | grep -q '✗\|⊘' \
  && fail "clean-consumer should report no drift; got non-✓ lines"

# Drifted consumer: must show drift for keep-in-sync.sh and for the kit dir
echo "$output" | grep -q "✗ scripts/keep-in-sync.sh" \
  || fail "expected drift line for scripts/keep-in-sync.sh on drifted consumer"
echo "$output" | grep -q "✗ scripts/ci/" \
  || fail "expected drift line for scripts/ci/ kit on drifted consumer"

# Missing-everything: every path must be ⊘
echo "$output" | awk '
  /^missing-everything/ { in_block=1; next }
  /^[a-z]/ && in_block { exit }
  in_block && /^  / { print }
' | grep -q '✓\|✗' \
  && fail "missing-everything should report only ⊘; got ✓ or ✗ lines"

# ---------------------------------------------------------------------------
# Filter test: --paths restriction must shrink the report
# ---------------------------------------------------------------------------
filtered=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$SIBLINGS" \
  "$SCRIPT" --audit --no-clone --paths "scripts/hooks/the-hook.sh" 2>&1 || true)
echo "$filtered" | grep -q "scripts/keep-in-sync.sh" \
  && fail "--paths filter should have excluded scripts/keep-in-sync.sh"

# Audit honors .sync-overrides.yml on templated dest paths (#336).
audit_override_workdir="$WORKDIR/audit-overrides"
AO_MP="$audit_override_workdir/mergepath"
AO_SIBLINGS="$audit_override_workdir/siblings"
mkdir -p "$AO_MP/examples" "$AO_MP/scripts/sync" "$AO_MP/scripts/lib" "$AO_SIBLINGS/alpha" "$AO_SIBLINGS/beta"
cp "$ROOT/scripts/sync/apply-overrides.sh" "$AO_MP/scripts/sync/apply-overrides.sh"
cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$AO_MP/scripts/lib/manifest-fact-helpers.sh"
cp "$ROOT/scripts/lib/template-substitution.sh" "$AO_MP/scripts/lib/template-substitution.sh"
cat >"$AO_MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: x/alpha}
  - {name: beta,  repo: x/beta}
paths:
  - path: examples/eslint.config.cjs.js
    source: examples/eslint.config.cjs.js
    dest: eslint.config.js
    type: templated
    consumers: all
YAML
echo "module.exports = ['canonical'];" >"$AO_MP/examples/eslint.config.cjs.js"
git init -q "$AO_MP"
echo "module.exports = ['local'];" >"$AO_SIBLINGS/alpha/eslint.config.js"
cat >"$AO_SIBLINGS/alpha/.sync-overrides.yml" <<'YAML'
skip_paths:
  - path: eslint.config.js
    reason: alpha keeps a local eslint override
YAML
git init -q "$AO_SIBLINGS/alpha"
echo "module.exports = ['local'];" >"$AO_SIBLINGS/beta/eslint.config.js"
git init -q "$AO_SIBLINGS/beta"

set +e
audit_override_out=$(MERGEPATH_ROOT_OVERRIDE="$AO_MP" MERGEPATH_SIBLINGS_DIR="$AO_SIBLINGS" \
  "$SCRIPT" --audit --no-clone 2>&1)
audit_override_rc=$?
set -e
[ "$audit_override_rc" -eq 1 ] \
  || fail "audit override fixture should still exit 1 because beta drifts; got $audit_override_rc ($audit_override_out)"
echo "$audit_override_out" | grep -q "↷ eslint.config.js.*skipped per .sync-overrides.yml" \
  || fail "audit should report alpha templated dest as override-skipped; output: $audit_override_out"
[ "$(echo "$audit_override_out" | grep -c "✗ eslint.config.js")" -eq 1 ] \
  || fail "audit should flag only beta's un-overridden templated drift; output: $audit_override_out"

# ---------------------------------------------------------------------------
# Missing-arg validation (CodeRabbit P-Minor on PR #215). Without the
# guard, --repos / --paths with no value crashes under set -u.
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" --audit --repos 2>/dev/null
arg_exit=$?
set -e
[[ "$arg_exit" -eq 2 ]] || fail "--repos with no arg should exit 2; got $arg_exit"

set +e
"$SCRIPT" --audit --paths 2>/dev/null
arg_exit=$?
set -e
[[ "$arg_exit" -eq 2 ]] || fail "--paths with no arg should exit 2; got $arg_exit"

# ---------------------------------------------------------------------------
# .git-as-file (worktree) detection (Codex P2 on PR #215). The script
# must accept consumer worktrees whose .git is a file, not a directory.
# ---------------------------------------------------------------------------
worktree_siblings="$WORKDIR/worktree-siblings"
mkdir -p "$worktree_siblings/clean-consumer/scripts/hooks" \
         "$worktree_siblings/clean-consumer/scripts/ci"
cp "$MP/scripts/keep-in-sync.sh"   "$worktree_siblings/clean-consumer/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$worktree_siblings/clean-consumer/scripts/hooks/the-hook.sh"
cp "$MP/scripts/ci/check_one"      "$worktree_siblings/clean-consumer/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$worktree_siblings/clean-consumer/scripts/ci/check_two"
# Real worktrees write a `gitdir: <path>` line into a `.git` file.
# A regular file with any content is enough for the existence-test;
# we don't need git's actual worktree machinery for this assertion.
echo "gitdir: $WORKDIR/fake.git" >"$worktree_siblings/clean-consumer/.git"

set +e
output=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$worktree_siblings" \
  "$SCRIPT" --audit --no-clone --repos clean-consumer 2>&1)
worktree_exit=$?
set -e
[[ "$worktree_exit" -eq 0 ]] \
  || fail "worktree (.git as file) should be accepted as a sibling; got exit $worktree_exit, output: $output"
echo "$output" | grep -q "no local worktree" \
  && fail "worktree (.git as file) misclassified as missing"

# ---------------------------------------------------------------------------
# Symlink guard on cache refresh (cursor CHANGES_REQUESTED on PR #215).
# If MERGEPATH_SYNC_CACHE/<consumer> resolves outside the cache dir
# (because it's symlinked at a sibling clone), refresh_cached_clone
# must refuse to `git reset --hard` and return error.
# ---------------------------------------------------------------------------
hostile_cache="$WORKDIR/hostile-cache"
hostile_user_tree="$WORKDIR/hostile-user-tree"
mkdir -p "$hostile_cache" "$hostile_user_tree/scripts/hooks" "$hostile_user_tree/scripts/ci"
git init -q "$hostile_user_tree"
# Set up a fake origin so git fetch / git reset have something to point at,
# and seed user-only content so a hard reset would clobber observable state.
( cd "$hostile_user_tree" \
    && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --allow-empty -q -m "user-only commit" )
# Symlink the cache entry at the user's tree.
ln -s "$hostile_user_tree" "$hostile_cache/clean-consumer"
echo "USER_LOCAL_EDIT" >"$hostile_user_tree/scripts/keep-in-sync.sh"

set +e
hostile_output=$(MERGEPATH_ROOT_OVERRIDE="$MP" \
  MERGEPATH_SIBLINGS_DIR="$WORKDIR/no-siblings-here" \
  MERGEPATH_SYNC_CACHE="$hostile_cache" \
  "$SCRIPT" --audit --repos clean-consumer 2>&1)
hostile_exit=$?
set -e
[[ "$hostile_exit" -eq 3 ]] \
  || fail "expected exit 3 (fetch error from refusing symlinked cache), got $hostile_exit"
echo "$hostile_output" | grep -qE "it is a symbolic link|resolves outside MERGEPATH_SYNC_CACHE" \
  || fail "expected symlink-guard error message; got: $hostile_output"
# The user's working tree must NOT have been touched — this is the
# load-bearing assertion. The exit code and error message are
# observable proxies; what actually matters is that the user's local
# edits survive.
[[ "$(cat "$hostile_user_tree/scripts/keep-in-sync.sh")" == "USER_LOCAL_EDIT" ]] \
  || fail "symlink-guarded cache path was reset, clobbering the user's working tree"

# ---------------------------------------------------------------------------
# Sync mode (Layer 3 first slice): dry-run end-to-end.
#
# Build a fresh Mergepath fixture with two canonical paths, one kit
# path, one templated path, three consumers. Make a commit at HEAD~1
# that touches one canonical and one kit and one templated path; HEAD
# touches the other canonical only. Then exercise --dry-run modes to
# assert the planning logic is sane.
# ---------------------------------------------------------------------------
sync_workdir="$WORKDIR/sync"
SYNC_MP="$sync_workdir/mergepath"
mkdir -p "$SYNC_MP/scripts/hooks" "$SYNC_MP/scripts/ci" "$SYNC_MP/scripts/sync" "$SYNC_MP/scripts/lib" "$SYNC_MP/.github"
cp "$ROOT/scripts/sync/apply-overrides.sh" "$SYNC_MP/scripts/sync/apply-overrides.sh"
cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$SYNC_MP/scripts/lib/manifest-fact-helpers.sh"
cat >"$SYNC_MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: example/alpha}
  - {name: beta,  repo: example/beta}
  - {name: gamma, repo: example/gamma}
paths:
  - {path: scripts/hooks/the-hook.sh,  type: canonical, consumers: all}
  - {path: scripts/coderabbit-wait.sh, type: canonical, consumers: all}
  - {path: scripts/ci/,                type: kit,       consumers: all}
  - {path: AGENTS.md,                  type: templated, consumers: all}
YAML
echo "v1" >"$SYNC_MP/scripts/hooks/the-hook.sh"
echo "v1" >"$SYNC_MP/scripts/coderabbit-wait.sh"
echo "v1" >"$SYNC_MP/scripts/ci/check_one"
echo "v1" >"$SYNC_MP/AGENTS.md"
git -C "$SYNC_MP" init -q
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "initial"

# Commit A — multi-type touch (canonical + kit + templated)
echo "v2" >"$SYNC_MP/scripts/hooks/the-hook.sh"
echo "v2" >"$SYNC_MP/scripts/ci/check_one"
echo "v2" >"$SYNC_MP/AGENTS.md"
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "multi-type-touch"
sha_A=$(git -C "$SYNC_MP" rev-parse HEAD)

# Commit B — single canonical touch
echo "v3" >"$SYNC_MP/scripts/coderabbit-wait.sh"
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "single-canonical-touch"
sha_B=$(git -C "$SYNC_MP" rev-parse HEAD)

# Commit C — only an unrelated file (no manifest path touched)
echo "noise" >"$SYNC_MP/.github/UNRELATED"
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "unrelated-only"
sha_C=$(git -C "$SYNC_MP" rev-parse HEAD)

# 1) Multi-type touch: canonical lands, kit + templated are deferred with
#    a per-consumer note. All 3 consumers get a planned PR.
sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --dry-run 2>&1)
echo "$sync_out" | grep -q "would open PR on branch mergepath-sync/${sha_A:0:7}" \
  || fail "multi-type sync did not produce planned PRs; output: $sync_out"
[[ "$(echo "$sync_out" | grep -c 'would open PR')" -eq 3 ]] \
  || fail "expected 3 planned PRs (one per consumer); got: $sync_out"
echo "$sync_out" | grep -q "+ scripts/hooks/the-hook.sh" \
  || fail "canonical target scripts/hooks/the-hook.sh missing from plan"
echo "$sync_out" | grep -q "deferred this slice: kit=scripts/ci/" \
  || fail "kit deferred-note missing from plan"
echo "$sync_out" | grep -q "templated=AGENTS.md" \
  || fail "templated deferred-note missing from plan"

# 2) --repos filter restricts consumer set.
sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_B" --dry-run --repos beta 2>&1)
[[ "$(echo "$sync_out" | grep -c 'would open PR')" -eq 1 ]] \
  || fail "--repos filter did not restrict to one consumer; got: $sync_out"
echo "$sync_out" | grep -q "beta — would open PR" \
  || fail "expected beta in --repos filter output; got: $sync_out"
echo "$sync_out" | grep -q "alpha\|gamma" \
  && fail "non-filtered consumer leaked into output: $sync_out"

# 3) --paths filter restricts target set within the planned PR.
sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --dry-run --paths "scripts/hooks/the-hook.sh" 2>&1)
echo "$sync_out" | grep -q "+ scripts/hooks/the-hook.sh" \
  || fail "--paths filter excluded the requested path"
echo "$sync_out" | grep -q "+ scripts/coderabbit-wait.sh" \
  && fail "--paths filter did not exclude scripts/coderabbit-wait.sh"

# 4) Commit that only touches kit + templated → no canonical targets,
#    summary marks each consumer as ⊘ (skipped, deferred-only).
deferred_only_sha=$(git -C "$SYNC_MP" rev-list HEAD --reverse | sed -n '2p')  # commit A
# Re-derive: we want a commit that is kit-only or templated-only, not
# the multi-type one. Make a fresh commit just for this case.
echo "v4" >"$SYNC_MP/scripts/ci/check_one"
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SYNC_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "kit-only"
sha_D=$(git -C "$SYNC_MP" rev-parse HEAD)

sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_D" --dry-run 2>&1)
echo "$sync_out" | grep -q "no canonical targets" \
  || fail "kit-only commit should report 'no canonical targets' per consumer; got: $sync_out"
echo "$sync_out" | grep -q "would open PR" \
  && fail "kit-only commit should not plan any PRs (canonical-only slice)"

# 5) Commit that touches no manifest path at all → "no manifest paths touched".
sync_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_C" --dry-run 2>&1)
echo "$sync_out" | grep -q "no manifest paths touched" \
  || fail "unrelated-only commit should report 'no manifest paths touched'; got: $sync_out"

# 6) Resolution of an unknown commit-ish exits 2 cleanly.
set +e
"$SCRIPT" deadbeefdeadbeefdeadbeef --dry-run 2>/dev/null
unknown_exit=$?
set -e
[[ "$unknown_exit" -eq 2 ]] || fail "unknown commit-ish should exit 2; got $unknown_exit"

# ---------------------------------------------------------------------------
# Live-mode author-token guard (cursor CHANGES_REQUESTED on PR #217,
# migrated in #412). Without the guard, a careless live invocation could
# reach downstream writes without proving the author identity. The guard
# refuses to proceed unless the author wrapper can verify a token for
# author_identity.
# ---------------------------------------------------------------------------
guard_workdir="$WORKDIR/guard"
GUARD_MP="$guard_workdir/mergepath"
mkdir -p "$GUARD_MP/scripts" "$GUARD_MP/scripts/sync" "$GUARD_MP/scripts/lib" "$GUARD_MP/.github"
cp "$ROOT/scripts/sync/apply-overrides.sh" "$GUARD_MP/scripts/sync/apply-overrides.sh"
cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$GUARD_MP/scripts/lib/manifest-fact-helpers.sh"
cp "$ROOT/scripts/lib/preflight-helpers.sh" "$GUARD_MP/scripts/lib/preflight-helpers.sh"
cat >"$GUARD_MP/scripts/gh-as-author.sh" <<'SH'
#!/usr/bin/env bash
echo "stub gh-as-author: refusing $GH_AS_AUTHOR_IDENTITY" >&2
exit 2
SH
chmod +x "$GUARD_MP/scripts/gh-as-author.sh"
GUARD_FAKE_BIN="$guard_workdir/bin"
mkdir -p "$GUARD_FAKE_BIN"
cat >"$GUARD_FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "api "*)
    if [ -n "${MERGEPATH_EXPECT_READ_GH_TOKEN:-}" ] &&
       [ "${GH_TOKEN:-}" != "$MERGEPATH_EXPECT_READ_GH_TOKEN" ]; then
      echo "fake gh api missing expected read token" >&2
      exit 8
    fi
    exit 0
    ;;
  "repo clone")
    echo "fake gh repo clone reached" >&2
    exit 7
    ;;
  *)
    echo "unexpected fake gh invocation: $*" >&2
    exit 9
    ;;
esac
SH
chmod +x "$GUARD_FAKE_BIN/gh"
cat >"$GUARD_MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: example-bogus/alpha}
paths:
  - {path: scripts/the-script.sh, type: canonical, consumers: all}
YAML
cat >"$GUARD_MP/.github/review-policy.yml" <<'YAML'
author_identity: definitely-not-a-real-user-9999
YAML
echo "v1" >"$GUARD_MP/scripts/the-script.sh"
git -C "$GUARD_MP" init -q
git -C "$GUARD_MP" -c user.email=t@t -c user.name=t add -A
git -C "$GUARD_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m initial
echo "v2" >"$GUARD_MP/scripts/the-script.sh"
git -C "$GUARD_MP" -c user.email=t@t -c user.name=t add -A
git -C "$GUARD_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m bump
guard_sha=$(git -C "$GUARD_MP" rev-parse HEAD)

# Live mode (no --dry-run) with an unverified author token should
# refuse before any clone, so the failure is the guard's, not the
# clone's.
set +e
guard_out=$(MERGEPATH_ROOT_OVERRIDE="$GUARD_MP" "$SCRIPT" "$guard_sha" --repos alpha 2>&1)
guard_exit=$?
set -e
echo "$guard_out" | grep -q "refusing to run live sync" \
  || fail "author-token guard did not fire; got: $guard_out"
echo "$guard_out" | grep -q "definitely-not-a-real-user-9999" \
  || fail "author-token guard did not name the expected actor"
[[ "$guard_exit" -ne 0 ]] \
  || fail "author-token guard should exit non-zero; got $guard_exit"

# Dry-run with the same missing token should still PASS — the
# guard only applies to live mode.
set +e
dr_out=$(MERGEPATH_ROOT_OVERRIDE="$GUARD_MP" "$SCRIPT" "$guard_sha" --dry-run --repos alpha 2>&1)
dr_exit=$?
set -e
[[ "$dr_exit" -eq 0 ]] \
  || fail "dry-run should not be blocked by author-token guard; got exit $dr_exit, output: $dr_out"
echo "$dr_out" | grep -q "would open PR" \
  || fail "dry-run should still plan a PR; got: $dr_out"

# Live --no-pr performs git clone/push work but does not create,
# close, or delete PRs through gh author writes, so it should not
# require an author token. Make the proof deterministic with a fake
# gh that allows read probes and fails only once clone is reached.
set +e
nopr_out=$(PATH="$GUARD_FAKE_BIN:$PATH" \
  MERGEPATH_ROOT_OVERRIDE="$GUARD_MP" \
  MERGEPATH_EXPECT_READ_GH_TOKEN=guard-read-token \
  OP_PREFLIGHT_AUTHOR_PAT=guard-read-token \
  "$SCRIPT" "$guard_sha" --repos alpha --no-pr 2>&1)
nopr_exit=$?
set -e
echo "$nopr_out" | grep -q "refusing to run live sync" \
  && fail "--no-pr should skip the author-token guard; got: $nopr_out"
echo "$nopr_out" | grep -q "fake gh repo clone reached" \
  || fail "--no-pr should reach clone after skipping author-token guard; got: $nopr_out"
[[ "$nopr_exit" -ne 0 ]] \
  || fail "--no-pr fixture should exit non-zero after fake clone failure; got $nopr_exit"

# Test-only bypass: fixture runs that stub gh directly can opt out of
# token verification. The failure mode should shift to "could not clone"
# rather than "refusing to run live sync."
set +e
override_out=$(MERGEPATH_ROOT_OVERRIDE="$GUARD_MP" \
  MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK=1 \
  "$SCRIPT" "$guard_sha" --repos alpha 2>&1)
set -e
echo "$override_out" | grep -q "refusing to run live sync" \
  && fail "test bypass should skip the author-token guard; got: $override_out"

# Agent-aware sync metadata (#392). Exercise the live path with a local
# bare remote and a stub `gh` so commit + PR bodies are inspected.
metadata_workdir="$WORKDIR/metadata"
META_MP="$metadata_workdir/mergepath"
META_FAKE_BIN="$metadata_workdir/bin"
META_CAPTURE="$metadata_workdir/capture"
mkdir -p "$META_MP/scripts/sync" "$META_MP/scripts/lib" "$META_MP/scripts" \
         "$META_MP/.github" "$META_FAKE_BIN" "$META_CAPTURE"
cp "$ROOT/scripts/sync/apply-overrides.sh" "$META_MP/scripts/sync/apply-overrides.sh"
cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$META_MP/scripts/lib/manifest-fact-helpers.sh"
cat >"$META_MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: example/alpha}
paths:
  - {path: scripts/the-script.sh, type: canonical, consumers: all}
YAML
cat >"$META_MP/.github/review-policy.yml" <<'YAML'
author_identity: nathanjohnpayne
YAML
echo "v1" >"$META_MP/scripts/the-script.sh"
git -C "$META_MP" init -q
git -C "$META_MP" -c user.email=t@t -c user.name=t add -A
git -C "$META_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m initial
echo "v2" >"$META_MP/scripts/the-script.sh"
git -C "$META_MP" -c user.email=t@t -c user.name=t add -A
git -C "$META_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "metadata bump"
meta_sha=$(git -C "$META_MP" rev-parse HEAD)
meta_branch="mergepath-sync/${meta_sha:0:7}"

cat >"$META_FAKE_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "config get")
    printf '%s\n' "nathanjohnpayne"
    ;;
  "api "*)
    # Existing-PR probe: no prior propagation PR.
    exit 0
    ;;
  "repo clone")
    dest=${4:?missing clone destination}
    git clone -q "$MERGEPATH_TEST_REMOTE_ALPHA" "$dest"
    git -C "$dest" config user.email t@t
    git -C "$dest" config user.name t
    git -C "$dest" config commit.gpgsign false
    ;;
  "pr create")
    title=""
    body=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) title=$2; shift 2 ;;
        --body) body=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$title" >"$MERGEPATH_TEST_CAPTURE_DIR/pr-title-${MERGEPATH_TEST_RUN}.txt"
    printf '%s\n' "$body" >"$MERGEPATH_TEST_CAPTURE_DIR/pr-body-${MERGEPATH_TEST_RUN}.md"
    printf 'https://github.com/example/alpha/pull/%s\n' "$MERGEPATH_TEST_RUN"
    ;;
  *)
    echo "unexpected fake gh invocation: $*" >&2
    exit 9
    ;;
esac
SH
chmod +x "$META_FAKE_BIN/gh"

setup_metadata_remote() {
  local remote=$1
  local seed=$2
  git init --bare -q "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  mkdir -p "$seed"
  git init -q "$seed"
  git -C "$seed" checkout -q -b main
  echo "consumer" >"$seed/README.md"
  git -C "$seed" -c user.email=t@t -c user.name=t add -A
  git -C "$seed" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m initial
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" push -q origin main
}

metadata_run_and_assert() {
  local run_id=$1
  local expected_agent=$2
  local expected_trailer=$3
  shift 3
  local remote="$metadata_workdir/${run_id}.git"
  local seed="$metadata_workdir/${run_id}-seed"
  setup_metadata_remote "$remote" "$seed"
  local out
  set +e
  out=$(env \
    PATH="$META_FAKE_BIN:$PATH" \
    MERGEPATH_ROOT_OVERRIDE="$META_MP" \
    MERGEPATH_TEST_REMOTE_ALPHA="$remote" \
    MERGEPATH_TEST_CAPTURE_DIR="$META_CAPTURE" \
    MERGEPATH_TEST_RUN="$run_id" \
    MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK=1 \
    "$@" \
    "$SCRIPT" "$meta_sha" --repos alpha 2>&1)
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "metadata sync $run_id failed with exit $rc; output: $out"
  local commit_body pr_body
  commit_body=$(git --git-dir="$remote" log -1 --format=%B "refs/heads/$meta_branch")
  pr_body=$(cat "$META_CAPTURE/pr-body-${run_id}.md")
  echo "$commit_body" | grep -q "Authoring-Agent: ${expected_agent}" \
    || fail "metadata sync $run_id commit body missing Authoring-Agent: ${expected_agent}; body: $commit_body"
  echo "$pr_body" | grep -q "Authoring-Agent: ${expected_agent}" \
    || fail "metadata sync $run_id PR body missing Authoring-Agent: ${expected_agent}; body: $pr_body"
  echo "$commit_body" | grep -qF "$expected_trailer" \
    || fail "metadata sync $run_id commit body missing trailer '$expected_trailer'; body: $commit_body"
}

metadata_run_and_assert \
  "claude" \
  "claude" \
  "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

metadata_run_and_assert \
  "codex" \
  "codex" \
  "Co-Authored-By: OpenAI Codex <noreply@openai.com>" \
  MERGEPATH_AGENT=codex

metadata_run_and_assert \
  "cursor" \
  "cursor" \
  "Co-Authored-By: Cursor <noreply@cursor.com>" \
  MERGEPATH_AGENT=cursor \

set +e
metadata_unknown_out=$(env \
  PATH="$META_FAKE_BIN:$PATH" \
  MERGEPATH_ROOT_OVERRIDE="$META_MP" \
  MERGEPATH_TEST_REMOTE_ALPHA="$metadata_workdir/unused.git" \
  MERGEPATH_TEST_CAPTURE_DIR="$META_CAPTURE" \
  MERGEPATH_TEST_RUN="unknown-missing-trailer" \
  MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK=1 \
  MERGEPATH_SYNC_AUTHORING_AGENT=other \
  "$SCRIPT" "$meta_sha" --repos alpha 2>&1)
metadata_unknown_rc=$?
set -e
[ "$metadata_unknown_rc" -ne 0 ] \
  || fail "unknown authoring agent without MERGEPATH_SYNC_COAUTHOR_TRAILER should fail closed"
echo "$metadata_unknown_out" | grep -q "no built-in coauthor trailer" \
  || fail "unknown authoring agent should explain missing trailer; got: $metadata_unknown_out"

# ---------------------------------------------------------------------------
# Mode-mirror correctness (cursor CHANGES_REQUESTED on PR #217).
# Live copy should NOT only add +x; it must also CLEAR +x when the
# Mergepath source is 100644. We can't easily exercise sync_open_pr's
# full path here without stubbing gh, but we can unit-check the mode
# logic by sourcing the script with a guard and calling the relevant
# git commands directly. Simpler: assert the script source contains
# both `chmod +x` and `chmod -x` branches.
# ---------------------------------------------------------------------------
grep -q 'chmod -x "$consumer_target"' "$SCRIPT" \
  || fail "sync_open_pr is missing the 'chmod -x' branch — mode drift would persist on 100644 sources"
grep -q 'chmod +x "$consumer_target"' "$SCRIPT" \
  || fail "sync_open_pr is missing the 'chmod +x' branch"

# ---------------------------------------------------------------------------
# Deletion propagation + tmpdir portability (cursor CHANGES_REQUESTED on
# PR #217). Two source-grep assertions because the live cycle isn't
# unit-testable without stubbing gh:
#
# 1. The materialization loop must check `git ls-tree` for a path
#    BEFORE trying `git show`, and if the path is absent at the sha,
#    rm the consumer copy instead of failing on a missing blob.
# 2. The mktemp invocation must use the explicit `$TMPDIR/<X-pattern>`
#    form (portable across BSD/macOS and GNU/Linux), not `mktemp -d -t
#    "literal-prefix"` (BSD-specific behavior).
# ---------------------------------------------------------------------------
grep -q 'ls-tree "$sha" -- "$target"' "$SCRIPT" \
  || fail "materialization loop is missing the ls-tree pre-check; deletes would fail on git show"
grep -q '\[ -z "\$src_mode" \]' "$SCRIPT" \
  || fail "materialization loop is missing the absent-at-sha branch (rm consumer copy on delete propagation)"
grep -q 'rm -f "\$consumer_target"' "$SCRIPT" \
  || fail "materialization loop is missing 'rm -f \$consumer_target' for delete propagation"
grep -q 'mktemp -d "\$tmp_root/mergepath-sync-' "$SCRIPT" \
  || fail "mktemp invocation is missing the portable \$TMPDIR/<prefix>.XXXXXX form"
grep -q 'mktemp -d -t "mergepath-sync' "$SCRIPT" \
  && fail "mktemp invocation still uses the BSD-specific '-t literal-prefix' form (not GNU portable)"

# ---------------------------------------------------------------------------
# --files alias for --paths (#199): both should normalize to FILTER_PATHS
# and produce equivalent filter behavior in dry-run sync.
# ---------------------------------------------------------------------------
files_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --dry-run --files "scripts/hooks/the-hook.sh" 2>&1)
paths_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --dry-run --paths "scripts/hooks/the-hook.sh" 2>&1)
[ "$files_out" = "$paths_out" ] \
  || fail "--files and --paths should produce identical output"
echo "$files_out" | grep -q "scripts/hooks/the-hook.sh" \
  || fail "--files did not honor the path filter"

# ---------------------------------------------------------------------------
# Sync-mode-only flags rejected in --audit (#199).
# ---------------------------------------------------------------------------
for flag in --no-pr --recreate-existing --verbose; do
  set +e
  out=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$SIBLINGS" \
    "$SCRIPT" --audit "$flag" 2>&1)
  ec=$?
  set -e
  [ "$ec" -eq 2 ] || fail "expected exit 2 when $flag combined with --audit; got $ec ($out)"
  echo "$out" | grep -q "sync-mode-only" \
    || fail "expected 'sync-mode-only' diagnostic for $flag; got: $out"
done

# ---------------------------------------------------------------------------
# Mutex: --no-pr + --recreate-existing rejected.
# ---------------------------------------------------------------------------
set +e
mutex_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --no-pr --recreate-existing 2>&1)
mutex_ec=$?
set -e
[ "$mutex_ec" -eq 2 ] || fail "expected exit 2 for --no-pr + --recreate-existing; got $mutex_ec"
echo "$mutex_out" | grep -q "incompatible" \
  || fail "expected 'incompatible' diagnostic; got: $mutex_out"

# ---------------------------------------------------------------------------
# Mutex: --skip-existing + --recreate-existing rejected (CodeRabbit #231
# round 2). Before the fix, --skip-existing was parsed as a true no-op,
# so this combo silently flipped to recreate.
# ---------------------------------------------------------------------------
set +e
skip_mutex_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --skip-existing --recreate-existing 2>&1)
skip_mutex_ec=$?
set -e
[ "$skip_mutex_ec" -eq 2 ] || fail "expected exit 2 for --skip-existing + --recreate-existing; got $skip_mutex_ec"
echo "$skip_mutex_out" | grep -q "incompatible" \
  || fail "expected 'incompatible' diagnostic for --skip-existing + --recreate-existing; got: $skip_mutex_out"

# ---------------------------------------------------------------------------
# Sync-mode-only: --skip-existing rejected in --audit.
# ---------------------------------------------------------------------------
set +e
skip_audit_out=$(MERGEPATH_ROOT_OVERRIDE="$MP" MERGEPATH_SIBLINGS_DIR="$SIBLINGS" \
  "$SCRIPT" --audit --skip-existing 2>&1)
skip_audit_ec=$?
set -e
[ "$skip_audit_ec" -eq 2 ] || fail "expected exit 2 when --skip-existing combined with --audit; got $skip_audit_ec"
echo "$skip_audit_out" | grep -q "sync-mode-only" \
  || fail "expected 'sync-mode-only' diagnostic for --skip-existing; got: $skip_audit_out"

# ---------------------------------------------------------------------------
# --verbose dry-run: emits per-file diff hunks for affected targets.
# ---------------------------------------------------------------------------
verbose_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --dry-run --verbose 2>&1)
echo "$verbose_out" | grep -q "+ scripts/hooks/the-hook.sh" \
  || fail "--verbose dry-run should still emit + path lines"
# A real diff hunk includes `@@` for context — that's the cheapest signal
# the verbose diff actually rendered. We don't pin to exact diff content
# (commit subjects/hashes vary) but the hunk header is deterministic.
echo "$verbose_out" | grep -qE "^\s+@@" \
  || fail "--verbose dry-run should include diff hunk headers; got: $verbose_out"

# Without --verbose the same dry-run should NOT include the diff hunks
# (just the summary path lines).
plain_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --dry-run 2>&1)
echo "$plain_out" | grep -qE "^\s+@@" \
  && fail "non-verbose dry-run should NOT include diff hunks"

# ---------------------------------------------------------------------------
# --no-pr + --dry-run still works (just exercises the parser; dry-run
# means we never actually reach the push-or-create code).
# ---------------------------------------------------------------------------
nopr_out=$(MERGEPATH_ROOT_OVERRIDE="$SYNC_MP" "$SCRIPT" "$sha_A" --dry-run --no-pr 2>&1)
echo "$nopr_out" | grep -q "would open PR" \
  || fail "--no-pr in dry-run should still produce a plan; got: $nopr_out"

# ---------------------------------------------------------------------------
# Library source check: sync-to-downstream.sh must source
# scripts/sync/apply-overrides.sh (#199 integration). Source-grep
# assertion since the live integration path runs only in non-dry-run
# mode.
# ---------------------------------------------------------------------------
grep -q '\. "\$MERGEPATH_ROOT/scripts/sync/apply-overrides.sh"' "$SCRIPT" \
  || fail "sync-to-downstream.sh is missing the apply-overrides.sh source line"
grep -q 'override_should_skip_path "\$consumer_overrides"' "$SCRIPT" \
  || fail "sync_open_pr is missing the override_should_skip_path filter on canonical targets"

# ---------------------------------------------------------------------------
# --recreate-existing destructive step is properly ordered:
#
#   1. The local commit is built FIRST (clone + materialize + git commit)
#      inside sync_open_pr.
#   2. Only THEN does `gh pr close` + `gh api -X DELETE git/refs/heads/...`
#      fire, immediately before `git push -u origin <branch>`.
#
# That ordering closes both windows CodeRabbit #231 round 2 flagged:
#   - Destructive recreate before the replacement is ready (line 767).
#   - Insufficient HTTP status handling on the DELETE (line 765).
#
# Codex #231 round 1 P1 separately required the branch deletion at all
# (line 724) since the original code closed the PR but left the branch,
# guaranteeing a non-fast-forward push rejection.
#
# Source-grep assertion since the live integration path requires a real
# gh API + a downstream consumer worktree.
# ---------------------------------------------------------------------------
awk '
  # Track when we are inside sync_open_pr to anchor the destructive
  # step within the function that owns the local-commit build.
  /^sync_open_pr\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }

  # The commit step is the last "ready" boundary before push.
  in_fn && /git -C "\$workspace\/repo" commit/ { saw_commit = NR }

  # The destructive close + delete should land after the commit and
  # before the push.
  in_fn && /gh pr close "\$recreate_existing_pr_num"/ { saw_close = NR }
  in_fn && /gh api --include -X DELETE.*git\/refs\/heads/ { saw_delete = NR }
  in_fn && /git -C "\$workspace\/repo" push/ { saw_push = NR }

  # Strict HTTP status case must be present (CodeRabbit round 2 line 765).
  in_fn && /^[[:space:]]*204\)/ { saw_204 = NR }
  in_fn && /404\|422\)/ { saw_404_422 = NR }

  END {
    if (!saw_commit) { print "missing commit step in sync_open_pr"; exit 1 }
    if (!saw_close)  { print "missing gh pr close in sync_open_pr (#231 r2)"; exit 1 }
    if (!saw_delete) { print "missing gh api --include DELETE in sync_open_pr (Codex #231 r1 P1)"; exit 1 }
    if (!saw_push)   { print "missing push step in sync_open_pr"; exit 1 }
    if (!saw_204)    { print "missing 204 case in delete-status switch (CodeRabbit #231 r2 line 765)"; exit 1 }
    if (!saw_404_422){ print "missing 404|422 case in delete-status switch (CodeRabbit #231 r2 line 765)"; exit 1 }
    if (saw_commit > saw_close) { print "destructive close fires BEFORE commit — must be deferred (#231 r2 line 767)"; exit 1 }
    if (saw_close > saw_delete) { print "gh pr close must precede branch delete"; exit 1 }
    if (saw_delete > saw_push)  { print "branch delete must precede push"; exit 1 }
  }
' "$SCRIPT" || fail "destructive recreate ordering check failed; see awk diagnostic above"

# Bonus assertion: the OLD location in sync_one_consumer (between
# pr_state detection and sync_open_pr call) must NOT carry an inline
# `gh pr close`. Regression guard against accidentally re-introducing
# the upfront destructive step that #231 r2 line 767 flagged.
awk '
  /^sync_one_consumer\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /gh pr close/ { print "FAIL: sync_one_consumer should not call gh pr close — recreate is deferred to sync_open_pr"; exit 1 }
' "$SCRIPT" || fail "sync_one_consumer carries an inline gh pr close — recreate must be deferred to sync_open_pr"

# RETURN-trap unbound-variable guard. A bash `trap ... RETURN` set
# inside a function is NOT function-scoped: it stays installed and
# fires again on every PARENT function's return, where the function-
# local `workspace` is out of scope. Under `set -u` a bare
# `"$workspace"` reference there aborts the whole script with
# "unbound variable" (observed live on the first --sync-all wave,
# right after the matchline PR was opened). The trap body MUST use
# the `${workspace:-}` default form so the spurious parent-return
# firings are a harmless `rm -rf ""` no-op.
grep -q 'trap .rm -rf "\$workspace". RETURN' "$SCRIPT" \
  && fail "RETURN trap uses bare \$workspace — must be \${workspace:-} (unbound-variable abort under set -u; see --sync-all wave regression)"
[ "$(grep -c 'trap .rm -rf "${workspace:-}". RETURN' "$SCRIPT")" -eq 2 ] \
  || fail "expected exactly 2 RETURN traps using the \${workspace:-} safe form (sync_open_pr + sync_all_open_pr)"

# ---------------------------------------------------------------------------
# --sync-all mode (#168 Layer 3 steady-state reconcile).
#
# Build a fresh Mergepath fixture with two canonical paths, one kit
# path, one templated path, three consumers. The key fixture detail:
# one consumer (`gamma`) carries a `.sync-overrides.yml` registering an
# intentional skip of one canonical path. --sync-all MUST NOT clobber
# that divergence — proven below by asserting the skipped path is
# absent from gamma's plan while present in alpha's/beta's.
# ---------------------------------------------------------------------------
syncall_workdir="$WORKDIR/syncall"
SA_MP="$syncall_workdir/mergepath"
SA_SIBLINGS="$syncall_workdir/siblings"
mkdir -p "$SA_MP/scripts/hooks" "$SA_MP/scripts/ci" "$SA_MP/scripts/sync" "$SA_MP/scripts/lib" "$SA_MP/.github"
cp "$ROOT/scripts/sync/apply-overrides.sh" "$SA_MP/scripts/sync/apply-overrides.sh"
cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$SA_MP/scripts/lib/manifest-fact-helpers.sh"
cat >"$SA_MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - {name: alpha, repo: example/alpha}
  - {name: beta,  repo: example/beta}
  - {name: gamma, repo: example/gamma}
  - {name: delta, repo: example/delta}
  - {name: epsilon, repo: example/epsilon}
  - {name: zeta, repo: example/zeta}
paths:
  - {path: scripts/hooks/the-hook.sh,  type: canonical, consumers: all}
  - {path: scripts/coderabbit-wait.sh, type: canonical, consumers: all}
  - {path: scripts/ci/,                type: kit,       consumers: all}
  - {path: AGENTS.md,                  type: templated, consumers: [alpha, beta, gamma, epsilon, zeta]}
YAML
echo "hook-v9"      >"$SA_MP/scripts/hooks/the-hook.sh"
echo "wait-v9"      >"$SA_MP/scripts/coderabbit-wait.sh"
echo "ci-one-v9"    >"$SA_MP/scripts/ci/check_one"
echo "ci-two-v9"    >"$SA_MP/scripts/ci/check_two"
echo "agents-v9"    >"$SA_MP/AGENTS.md"
git -C "$SA_MP" init -q
git -C "$SA_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SA_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "initial"
# A second commit so HEAD has a non-root short-sha; --sync-all keys the
# branch name on HEAD, and we want a realistic 7-char sha.
echo "hook-v10" >"$SA_MP/scripts/hooks/the-hook.sh"
git -C "$SA_MP" -c user.email=t@t -c user.name=t add -A
git -C "$SA_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "bump hook"
sa_head=$(git -C "$SA_MP" rev-parse HEAD)
sa_short=${sa_head:0:7}

# Sibling consumers on disk so the dry-run override probe (which reads
# the LOCAL consumer worktree's .sync-overrides.yml) has something to
# read. alpha + beta carry no overrides; gamma registers a skip.
mkdir -p "$SA_SIBLINGS/alpha" "$SA_SIBLINGS/beta" "$SA_SIBLINGS/gamma" "$SA_SIBLINGS/delta" "$SA_SIBLINGS/epsilon" "$SA_SIBLINGS/zeta"
git init -q "$SA_SIBLINGS/alpha"
git init -q "$SA_SIBLINGS/beta"
git init -q "$SA_SIBLINGS/gamma"
git init -q "$SA_SIBLINGS/delta"
git init -q "$SA_SIBLINGS/epsilon"
git init -q "$SA_SIBLINGS/zeta"
cat >"$SA_SIBLINGS/gamma/.sync-overrides.yml" <<'YAML'
skip_paths:
  - path: scripts/coderabbit-wait.sh
    reason: gamma maintains a bespoke coderabbit-wait wrapper
YAML
# delta overrides EVERY canonical + kit path — a fully-diverged
# consumer. --sync-all must report it as skipped, not as a planned PR
# (the dry-run path must mirror sync_all_open_pr's zero-target guard).
cat >"$SA_SIBLINGS/delta/.sync-overrides.yml" <<'YAML'
skip_paths:
  - path: scripts/hooks/the-hook.sh
    reason: delta vendors its own hook
  - path: scripts/coderabbit-wait.sh
    reason: delta vendors its own coderabbit-wait wrapper
  - path: scripts/ci/
    reason: delta maintains a bespoke CI kit
YAML
# epsilon overrides every canonical + kit path too, but it still has a
# templated target. Dry-run must mirror live mode and plan that PR
# rather than treating the consumer as zero-target.
cat >"$SA_SIBLINGS/epsilon/.sync-overrides.yml" <<'YAML'
skip_paths:
  - path: scripts/hooks/the-hook.sh
    reason: epsilon vendors its own hook
  - path: scripts/coderabbit-wait.sh
    reason: epsilon vendors its own coderabbit-wait wrapper
  - path: scripts/ci/
    reason: epsilon maintains a bespoke CI kit
YAML
# zeta overrides every canonical + kit path and its templated dest, so
# dry-run should skip it exactly like live mode would after rendering
# nothing.
cat >"$SA_SIBLINGS/zeta/.sync-overrides.yml" <<'YAML'
skip_paths:
  - path: scripts/hooks/the-hook.sh
    reason: zeta vendors its own hook
  - path: scripts/coderabbit-wait.sh
    reason: zeta vendors its own coderabbit-wait wrapper
  - path: scripts/ci/
    reason: zeta maintains a bespoke CI kit
  - path: AGENTS.md
    reason: zeta owns its agent instructions locally
YAML

# 1) --sync-all --dry-run lists ALL canonical + kit paths for EVERY
#    consumer (not just changed-at-a-commit ones). All 4 planned consumers
#    appear; both canonical paths + the kit path are planned.
sa_out=$(MERGEPATH_ROOT_OVERRIDE="$SA_MP" MERGEPATH_SIBLINGS_DIR="$SA_SIBLINGS" \
  "$SCRIPT" --sync-all --dry-run 2>&1)
[[ "$(echo "$sa_out" | grep -c 'would open PR')" -eq 4 ]] \
  || fail "--sync-all --dry-run should plan one PR per non-zero-target consumer (4); got: $sa_out"
echo "$sa_out" | grep -q "scripts/hooks/the-hook.sh (canonical)" \
  || fail "--sync-all plan missing canonical path scripts/hooks/the-hook.sh"
echo "$sa_out" | grep -q "scripts/coderabbit-wait.sh (canonical)" \
  || fail "--sync-all plan missing canonical path scripts/coderabbit-wait.sh"
echo "$sa_out" | grep -q "scripts/ci/ (kit, allow-extras)" \
  || fail "--sync-all plan missing kit path scripts/ci/"
echo "$sa_out" | grep -q "templated, rendered per consumer facts" \
  || fail "--sync-all plan should note templated paths are rendered per consumer facts"

# 2) --sync-all honors .sync-overrides.yml. gamma registered a skip of
#    scripts/coderabbit-wait.sh — that path MUST be absent from gamma's
#    sync set and MUST be marked SKIPPED in gamma's plan. This is the
#    single most important correctness property of --sync-all: a bulk
#    reconcile that clobbers an intentional divergence is worse than no
#    --sync-all at all.
gamma_block=$(echo "$sa_out" | awk '
  /^gamma \(/ { in_block=1; next }
  /^[a-z].* \(/ && in_block { exit }
  in_block { print }
')
echo "$gamma_block" | grep -q "scripts/coderabbit-wait.sh (SKIPPED per .sync-overrides.yml" \
  || fail "--sync-all did not honor gamma's .sync-overrides.yml skip; gamma block: $gamma_block"
echo "$gamma_block" | grep -q "+ scripts/coderabbit-wait.sh (canonical)" \
  && fail "--sync-all listed an override-skipped path as a sync target for gamma; gamma block: $gamma_block"
# alpha has no overrides — the same path MUST still be a target for it.
alpha_block=$(echo "$sa_out" | awk '
  /^alpha \(/ { in_block=1; next }
  /^[a-z].* \(/ && in_block { exit }
  in_block { print }
')
echo "$alpha_block" | grep -q "+ scripts/coderabbit-wait.sh (canonical)" \
  || fail "--sync-all should still sync scripts/coderabbit-wait.sh to alpha (no overrides); alpha block: $alpha_block"
echo "$alpha_block" | grep -q "SKIPPED per .sync-overrides.yml" \
  && fail "--sync-all marked a path skipped for alpha, which has no overrides; alpha block: $alpha_block"

# 2b) Zero-target guard: delta overrides EVERY canonical + kit path and
#     has no templated target, so the dry-run plan MUST report it as
#     skipped (⊘) rather than as a
#     planned PR. A "would open PR" line for delta would overstate the
#     planned PR count vs. live behavior (sync_all_open_pr skips a
#     fully-overridden consumer without opening a PR).
echo "$sa_out" | grep -q "⊘ delta — all effective sync targets skipped per .sync-overrides.yml" \
  || fail "--sync-all dry-run should report fully-overridden delta as skipped; got: $sa_out"
echo "$sa_out" | grep -qE "⤷ delta — would open PR" \
  && fail "--sync-all dry-run planned a PR for fully-overridden delta; should be skipped; got: $sa_out"
# delta's overridden paths must still be surfaced as SKIPPED lines.
echo "$sa_out" | grep -q "scripts/hooks/the-hook.sh (SKIPPED per .sync-overrides.yml" \
  || fail "--sync-all dry-run should surface delta's override-skipped paths; got: $sa_out"
# The "would open PR" count is still 4 — delta is skipped, not planned.
[[ "$(echo "$sa_out" | grep -c 'would open PR')" -eq 4 ]] \
  || fail "--sync-all dry-run should still plan exactly 4 PRs (delta skipped); got: $sa_out"

# 2c) Templated-only guard: epsilon also overrides every canonical +
#     kit path, but it still has a templated target. Live mode opens a
#     PR in that case, so dry-run must not take the zero-target skip.
epsilon_block=$(echo "$sa_out" | awk '
  /^epsilon \(/ { in_block=1; next }
  /^[a-z].* \(/ && in_block { exit }
  in_block { print }
')
echo "$epsilon_block" | grep -q "would open PR" \
  || fail "--sync-all dry-run should plan a PR for templated-only epsilon; epsilon block: $epsilon_block"
echo "$epsilon_block" | grep -q "0 canonical + 0 kit path(s)" \
  || fail "--sync-all dry-run should show epsilon as templated-only; epsilon block: $epsilon_block"
echo "$epsilon_block" | grep -q "templated, rendered per consumer facts: AGENTS.md" \
  || fail "--sync-all dry-run should list epsilon's templated render; epsilon block: $epsilon_block"
echo "$epsilon_block" | grep -q "scripts/hooks/the-hook.sh (SKIPPED per .sync-overrides.yml" \
  || fail "--sync-all dry-run should still surface epsilon override-skipped paths; epsilon block: $epsilon_block"

# 2d) Templated override guard: zeta's templated dest is also skipped,
#     so a pre-override templated_list must not force a planned PR.
zeta_block=$(echo "$sa_out" | awk '
  /^zeta \(/ { in_block=1; next }
  /^[a-z].* \(/ && in_block { exit }
  in_block { print }
')
echo "$zeta_block" | grep -q "all effective sync targets skipped per .sync-overrides.yml" \
  || fail "--sync-all dry-run should skip zeta when templated dest is overridden; zeta block: $zeta_block"
echo "$zeta_block" | grep -q "AGENTS.md (templated, SKIPPED per .sync-overrides.yml" \
  || fail "--sync-all dry-run should surface zeta's templated override; zeta block: $zeta_block"
echo "$zeta_block" | grep -q "would open PR" \
  && fail "--sync-all dry-run planned a PR for zeta despite all targets being overridden; zeta block: $zeta_block"

# 3) --sync-all + --audit → exit 2 (mutex).
set +e
sa_audit_out=$(MERGEPATH_ROOT_OVERRIDE="$SA_MP" "$SCRIPT" --sync-all --audit 2>&1)
sa_audit_ec=$?
set -e
[[ "$sa_audit_ec" -eq 2 ]] || fail "--sync-all + --audit should exit 2; got $sa_audit_ec"
echo "$sa_audit_out" | grep -q "mutually exclusive" \
  || fail "--sync-all + --audit should emit a 'mutually exclusive' diagnostic; got: $sa_audit_out"
# Order independence: --audit first should also be rejected.
set +e
MERGEPATH_ROOT_OVERRIDE="$SA_MP" "$SCRIPT" --audit --sync-all 2>/dev/null
sa_audit_ec2=$?
set -e
[[ "$sa_audit_ec2" -eq 2 ]] || fail "--audit + --sync-all (order swapped) should exit 2; got $sa_audit_ec2"

# 4) --sync-all + positional <commit-ish> → exit 2 (mutex).
set +e
sa_commit_out=$(MERGEPATH_ROOT_OVERRIDE="$SA_MP" "$SCRIPT" --sync-all "$sa_head" 2>&1)
sa_commit_ec=$?
set -e
[[ "$sa_commit_ec" -eq 2 ]] || fail "--sync-all + positional commit-ish should exit 2; got $sa_commit_ec"
echo "$sa_commit_out" | grep -q "mutually exclusive" \
  || fail "--sync-all + commit-ish should emit a 'mutually exclusive' diagnostic; got: $sa_commit_out"
# Order independence: commit-ish first then --sync-all.
set +e
MERGEPATH_ROOT_OVERRIDE="$SA_MP" "$SCRIPT" "$sa_head" --sync-all 2>/dev/null
sa_commit_ec2=$?
set -e
[[ "$sa_commit_ec2" -eq 2 ]] || fail "commit-ish + --sync-all (order swapped) should exit 2; got $sa_commit_ec2"

# 4b) --audit + positional <commit-ish> → exit 2 (mixed-mode guard).
#     --audit is a read-only drift scan and takes no commit-ish; before
#     the SAW_* trackers, the commit-ish was silently dropped and audit
#     ran anyway. Reject both arg orders with a usage error.
set +e
sa_audit_commit_out=$(MERGEPATH_ROOT_OVERRIDE="$SA_MP" "$SCRIPT" --audit "$sa_head" 2>&1)
sa_audit_commit_ec=$?
set -e
[[ "$sa_audit_commit_ec" -eq 2 ]] \
  || fail "--audit + positional commit-ish should exit 2; got $sa_audit_commit_ec"
echo "$sa_audit_commit_out" | grep -q "takes no positional" \
  || fail "--audit + commit-ish should emit a 'takes no positional' diagnostic; got: $sa_audit_commit_out"
set +e
MERGEPATH_ROOT_OVERRIDE="$SA_MP" "$SCRIPT" "$sa_head" --audit 2>/dev/null
sa_audit_commit_ec2=$?
set -e
[[ "$sa_audit_commit_ec2" -eq 2 ]] \
  || fail "commit-ish + --audit (order swapped) should exit 2; got $sa_audit_commit_ec2"

# 5) --sync-all --repos <one> restricts to the named consumer.
sa_repos_out=$(MERGEPATH_ROOT_OVERRIDE="$SA_MP" MERGEPATH_SIBLINGS_DIR="$SA_SIBLINGS" \
  "$SCRIPT" --sync-all --dry-run --repos beta 2>&1)
[[ "$(echo "$sa_repos_out" | grep -c 'would open PR')" -eq 1 ]] \
  || fail "--sync-all --repos beta should plan exactly one PR; got: $sa_repos_out"
echo "$sa_repos_out" | grep -q "^beta (" \
  || fail "--sync-all --repos beta should include beta; got: $sa_repos_out"
echo "$sa_repos_out" | grep -qE "^(alpha|gamma|delta) \(" \
  && fail "--sync-all --repos beta leaked a non-filtered consumer; got: $sa_repos_out"

# 6) Branch-name scheme for --sync-all is distinct from per-commit: it
#    carries the `sync-all-` infix. Per-commit branches are
#    `mergepath-sync/<sha>`; sync-all is `mergepath-sync/sync-all-<sha>`.
echo "$sa_out" | grep -q "mergepath-sync/sync-all-${sa_short}" \
  || fail "--sync-all branch name missing the 'sync-all-' prefix scheme; got: $sa_out"
echo "$sa_out" | grep -qE "branch mergepath-sync/${sa_short} " \
  && fail "--sync-all used the bare per-commit branch scheme (mergepath-sync/<sha>); must use sync-all- infix"

# ---------------------------------------------------------------------------
# --version / --help smoke
# ---------------------------------------------------------------------------
"$SCRIPT" --version | grep -q "sync-to-downstream.sh" || fail "--version output unexpected"
"$SCRIPT" --help    | grep -q "Usage:"                || fail "--help output unexpected"
"$SCRIPT" --help    | grep -q "no-pr"                 || fail "--help missing --no-pr documentation"
"$SCRIPT" --help    | grep -q "recreate-existing"     || fail "--help missing --recreate-existing documentation"
"$SCRIPT" --help    | grep -q "verbose"               || fail "--help missing --verbose documentation"
"$SCRIPT" --help    | grep -q "sync-all"              || fail "--help missing --sync-all documentation"

echo "test_sync_to_downstream: PASS"
