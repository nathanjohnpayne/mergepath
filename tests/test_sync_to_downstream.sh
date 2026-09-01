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
  "$SCRIPT" --audit --use-local-tree --no-clone 2>&1)
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
  "$SCRIPT" --audit --use-local-tree --no-clone --paths "scripts/hooks/the-hook.sh" 2>&1 || true)
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
  "$SCRIPT" --audit --use-local-tree --no-clone 2>&1)
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
  "$SCRIPT" --audit --use-local-tree --no-clone --repos clean-consumer 2>&1)
worktree_exit=$?
set -e
[[ "$worktree_exit" -eq 0 ]] \
  || fail "worktree (.git as file) should be accepted as a sibling; got exit $worktree_exit, output: $output"
echo "$output" | grep -q "no local worktree" \
  && fail "worktree (.git as file) misclassified as missing"

# ---------------------------------------------------------------------------
# #439: default audit baseline is the LIVE default branch via the cache
# clone — never the sibling working tree. A stale sibling (feature
# branch checked out, behind main) must not affect the default audit,
# and --use-local-tree must surface loud staleness warnings + the exact
# baseline ref@sha.
# ---------------------------------------------------------------------------
live_origin="$WORKDIR/live-origin/clean-consumer"
mkdir -p "$live_origin/scripts/hooks" "$live_origin/scripts/ci"
cp "$MP/scripts/keep-in-sync.sh"   "$live_origin/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$live_origin/scripts/hooks/the-hook.sh"
cp "$MP/scripts/ci/check_one"      "$live_origin/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$live_origin/scripts/ci/check_two"
git init -q -b main "$live_origin"
( cd "$live_origin" \
    && git add -A \
    && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "clean state" )

live_cache="$WORKDIR/live-cache"
mkdir -p "$live_cache"
# --depth=1 matches clone_consumer_to_cache and implies --single-branch,
# which is exactly the shape that broke the renamed-default refresh
# (Codex P2 on PR #443 r2): the clone's refspec only fetches the old
# default, so the rename test below exercises the explicit-ref fetch.
git clone -q --depth=1 "file://$live_origin" "$live_cache/clean-consumer"

stale_siblings="$WORKDIR/stale-siblings"
mkdir -p "$stale_siblings/clean-consumer/scripts/hooks" "$stale_siblings/clean-consumer/scripts/ci"
cp "$MP/scripts/keep-in-sync.sh"   "$stale_siblings/clean-consumer/scripts/keep-in-sync.sh"
cp "$MP/scripts/hooks/the-hook.sh" "$stale_siblings/clean-consumer/scripts/hooks/the-hook.sh"
cp "$MP/scripts/ci/check_one"      "$stale_siblings/clean-consumer/scripts/ci/check_one"
cp "$MP/scripts/ci/check_two"      "$stale_siblings/clean-consumer/scripts/ci/check_two"
git init -q -b main "$stale_siblings/clean-consumer"
( cd "$stale_siblings/clean-consumer" \
    && git add -A \
    && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "synced state" \
    && git checkout -q -b feature/stale-work \
    && echo "MUTATED" >scripts/keep-in-sync.sh \
    && git add -A \
    && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "stale feature work" \
    && git update-ref refs/remotes/origin/main "$(git rev-parse main)" \
    && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main )

# Default mode: the clean cache clone is the baseline; the stale sibling
# (which WOULD drift) must be ignored entirely.
set +e
live_output=$(MERGEPATH_ROOT_OVERRIDE="$MP" \
  MERGEPATH_SIBLINGS_DIR="$stale_siblings" \
  MERGEPATH_SYNC_CACHE="$live_cache" \
  "$SCRIPT" --audit --repos clean-consumer 2>&1)
live_exit=$?
set -e
[[ "$live_exit" -eq 0 ]] \
  || fail "default audit should read the clean cache clone (exit 0) and ignore the stale sibling; got exit $live_exit, output: $live_output"
echo "$live_output" | grep -q "baseline: .*cache clone, refreshed" \
  || fail "default audit should print the cache-clone baseline header; got: $live_output"
echo "$live_output" | grep -q "LOCAL SIBLING TREE" \
  && fail "default audit must not read the sibling tree; got: $live_output"

# --use-local-tree: the stale sibling IS the baseline; drift is reported
# and the baseline header + both staleness warnings make the basis loud.
set +e
stale_output=$(MERGEPATH_ROOT_OVERRIDE="$MP" \
  MERGEPATH_SIBLINGS_DIR="$stale_siblings" \
  MERGEPATH_SYNC_CACHE="$live_cache" \
  "$SCRIPT" --audit --use-local-tree --no-clone --repos clean-consumer 2>&1)
stale_exit=$?
set -e
[[ "$stale_exit" -eq 1 ]] \
  || fail "--use-local-tree audit should report the stale sibling's drift (exit 1); got exit $stale_exit, output: $stale_output"
echo "$stale_output" | grep -q "baseline: feature/stale-work@.*LOCAL SIBLING TREE" \
  || fail "--use-local-tree audit should print the sibling baseline ref@sha; got: $stale_output"
echo "$stale_output" | grep -q "⚠ sibling tree is on 'feature/stale-work', not the default branch 'main'" \
  || fail "--use-local-tree audit should warn about the non-default branch; got: $stale_output"
echo "$stale_output" | grep -q "⚠ sibling tree HEAD .* != last-fetched origin/main" \
  || fail "--use-local-tree audit should warn that HEAD differs from origin/main; got: $stale_output"

# Default mode + --no-clone with NO cache clone present: fail closed with
# a pointer at --use-local-tree rather than silently reading the sibling.
set +e
noclone_output=$(MERGEPATH_ROOT_OVERRIDE="$MP" \
  MERGEPATH_SIBLINGS_DIR="$stale_siblings" \
  MERGEPATH_SYNC_CACHE="$WORKDIR/empty-cache-nowhere" \
  "$SCRIPT" --audit --no-clone --repos clean-consumer 2>&1)
noclone_exit=$?
set -e
[[ "$noclone_exit" -eq 3 ]] \
  || fail "default audit --no-clone with no cache should exit 3; got $noclone_exit, output: $noclone_output"
echo "$noclone_output" | grep -q "no cached clone for clean-consumer" \
  || fail "default audit --no-clone should explain the missing cache clone; got: $noclone_output"
echo "$noclone_output" | grep -q -- "--use-local-tree" \
  || fail "default audit --no-clone should point at --use-local-tree; got: $noclone_output"

# --use-local-tree is audit-mode-only.
set +e
MERGEPATH_ROOT_OVERRIDE="$MP" "$SCRIPT" --sync-all --use-local-tree --dry-run >/dev/null 2>&1
ult_sync_exit=$?
set -e
[[ "$ult_sync_exit" -eq 2 ]] \
  || fail "--use-local-tree in sync mode should exit 2; got $ult_sync_exit"

# Default-branch rename: `git fetch` never moves refs/remotes/origin/HEAD,
# so the refresh must re-resolve the remote default (`remote set-head
# --auto`) or a renamed default branch silently audits the stale old one
# (Codex P2 on PR #443). Rename the origin's default to `trunk` with
# drifted content; the cached clone (cloned when default was `main`)
# must follow the rename and report the drift.
( cd "$live_origin" \
    && git branch -m main trunk \
    && git symbolic-ref HEAD refs/heads/trunk \
    && echo "MUTATED-ON-TRUNK" >scripts/keep-in-sync.sh \
    && git add -A \
    && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "drift on renamed default" )
set +e
rename_output=$(MERGEPATH_ROOT_OVERRIDE="$MP" \
  MERGEPATH_SIBLINGS_DIR="$stale_siblings" \
  MERGEPATH_SYNC_CACHE="$live_cache" \
  "$SCRIPT" --audit --repos clean-consumer 2>&1)
rename_exit=$?
set -e
[[ "$rename_exit" -eq 1 ]] \
  || fail "default audit should follow a renamed default branch and report its drift (exit 1); got exit $rename_exit, output: $rename_output"
echo "$rename_output" | grep -q "baseline: trunk@" \
  || fail "default audit baseline should show the renamed default branch 'trunk'; got: $rename_output"

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

# Templated render must additionally stage the dest mode in the git INDEX
# (not only the working-tree chmod): under core.filemode=false the blanket
# `git add -A` ignores the on-disk exec bit, so a mode-only flip would not be
# committed (Codex P2 on PR #475). Assert the index-staging is present.
grep -q 'update-index --chmod="$tpl_idx_chmod"' "$SCRIPT" \
  || fail "templated render is missing the 'git update-index --chmod' index-mode staging — mode flips would be lost under core.filemode=false (#475)"

# Canonical mirror arms (sync_open_pr AND sync_all_open_pr) must ALSO stage
# the dest mode in the git INDEX, exactly like the templated arm — under
# core.filemode=false the blanket `git add -A` drops a mode-only flip on an
# existing tracked file, so an executable canonical script (far more common
# than a templated executable) would propagate non-executable (#476). Both
# arms share the `$idx_chmod` var, so require the staging to appear twice
# (one per arm). `|| true`: grep -c exits 1 on zero matches under set -e —
# the real assertion is the count check below, this just captures the count.
canonical_idx_count=$(grep -c 'update-index --chmod="$idx_chmod"' "$SCRIPT" || true)
[ "${canonical_idx_count:-0}" -ge 2 ] \
  || fail "canonical mirror arms are missing 'git update-index --chmod=\$idx_chmod' index-mode staging in both sync_open_pr and sync_all_open_pr (found ${canonical_idx_count:-0}, need 2) — exec-mode flips would be lost under core.filemode=false (#476)"

# Kit mirror arm: mirror both the chmod-branch greps and the index-staging.
grep -q 'chmod -x "$consumer_kit_target"' "$SCRIPT" \
  || fail "kit mirror is missing the 'chmod -x' branch — mode drift would persist on 100644 kit sources (#476)"
grep -q 'chmod +x "$consumer_kit_target"' "$SCRIPT" \
  || fail "kit mirror is missing the 'chmod +x' branch (#476)"
grep -q 'update-index --chmod="$kit_idx_chmod"' "$SCRIPT" \
  || fail "kit mirror is missing the 'git update-index --chmod' index-mode staging — kit exec-mode flips would be lost under core.filemode=false (#476)"

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
# Capture once, then match via here-strings. The direct form
# `"$SCRIPT" --help | grep -q PATTERN` is fragile under `set -o pipefail`
# (line 13): grep -q closes the pipe on its first match, the script — still
# writing its long --help — takes SIGPIPE (exit 141), and pipefail propagates
# that 141 as the pipeline status, so `|| fail` fires even though PATTERN was
# present. macOS buffered the whole help before grep closed so it passed
# there; Linux CI did not (#488). A here-string has no producer process to
# SIGPIPE, so the match is reliable (and --help/--version run once, not 6x).
version_out=$("$SCRIPT" --version)
grep -q "sync-to-downstream.sh" <<<"$version_out" || fail "--version output unexpected"
help_out=$("$SCRIPT" --help)
grep -q "Usage:"            <<<"$help_out" || fail "--help output unexpected"
grep -q "no-pr"             <<<"$help_out" || fail "--help missing --no-pr documentation"
grep -q "recreate-existing" <<<"$help_out" || fail "--help missing --recreate-existing documentation"
grep -q "verbose"           <<<"$help_out" || fail "--help missing --verbose documentation"
grep -q "sync-all"          <<<"$help_out" || fail "--help missing --sync-all documentation"

# ---------------------------------------------------------------------------
# Commit-path requires-closure gate (#624 Codex P1; fails pre-fix). A commit
# touching ONLY a requires-bearing canonical (repo_lint.yml) must not open a
# consumer PR while the required kit is missing/stale on that consumer — the
# shipped workflow would run: kit checks the consumer does not have. The gate
# passes when the kit is byte-current, and honors consumer overrides for
# required files (documented divergence).
# ---------------------------------------------------------------------------
req_workdir="$WORKDIR/requires-gate"
REQ_MP="$req_workdir/mergepath"
REQ_FAKE_BIN="$req_workdir/bin"
REQ_CAPTURE="$req_workdir/capture"
mkdir -p "$REQ_MP/scripts/sync" "$REQ_MP/scripts/lib" "$REQ_MP/scripts/ci" \
         "$REQ_MP/scripts/runtime-kit" \
         "$REQ_MP/.github/workflows" "$REQ_MP/examples" "$REQ_FAKE_BIN" "$REQ_CAPTURE"
cp "$ROOT/scripts/sync/apply-overrides.sh" "$REQ_MP/scripts/sync/apply-overrides.sh"
cp "$ROOT/scripts/lib/manifest-fact-helpers.sh" "$REQ_MP/scripts/lib/manifest-fact-helpers.sh"
cp "$ROOT/scripts/lib/template-substitution.sh" "$REQ_MP/scripts/lib/template-substitution.sh"
cat >"$REQ_MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - name: alpha
    repo: example/alpha
    facts: {flavor: blue}
paths:
  - path: .github/workflows/repo_lint.yml
    type: canonical
    consumers: all
    requires:
      - "scripts/ci/check_a"
      - "scripts/ci/check_b"
  - path: scripts/ci/
    type: kit
    consumers: all
    requires:
      - ".github/workflows/repo_lint.yml"
  - path: .github/workflows/templated_runtime.yml
    type: canonical
    consumers: all
    requires:
      - "examples/runtime-helper.in"
  - path: .github/workflows/slashless_kit.yml
    type: canonical
    consumers: all
    requires:
      - "scripts/runtime-kit"
  - {path: scripts/runtime-kit, type: kit, consumers: all}
  - path: examples/runtime-helper.in
    source: examples/runtime-helper.in
    dest: scripts/runtime/helper.sh
    type: templated
    consumers: all
    requires:
      - "scripts/ci/check_b"
YAML
cat >"$REQ_MP/.github/review-policy.yml" <<'YAML'
author_identity: nathanjohnpayne
YAML
printf 'lint v1\n' >"$REQ_MP/.github/workflows/repo_lint.yml"
printf 'runtime workflow v1\n' >"$REQ_MP/.github/workflows/templated_runtime.yml"
printf 'slashless kit workflow v1\n' >"$REQ_MP/.github/workflows/slashless_kit.yml"
printf 'check a v1\n' >"$REQ_MP/scripts/ci/check_a"
printf 'check b v1\n' >"$REQ_MP/scripts/ci/check_b"
printf 'runtime kit a v1\n' >"$REQ_MP/scripts/runtime-kit/check_a"
printf 'runtime kit b v1\n' >"$REQ_MP/scripts/runtime-kit/check_b"
printf 'runtime {{flavor}}\n' >"$REQ_MP/examples/runtime-helper.in"
chmod +x "$REQ_MP/scripts/ci/check_a"
chmod +x "$REQ_MP/scripts/runtime-kit/check_a"
chmod +x "$REQ_MP/examples/runtime-helper.in"
git -C "$REQ_MP" init -q
git -C "$REQ_MP" -c user.email=t@t -c user.name=t add -A
git -C "$REQ_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m initial
if ! req_manifest_validation=$(
  MERGEPATH_REPO_ROOT="$REQ_MP" \
  MERGEPATH_MANIFEST_PATH="$REQ_MP/.mergepath-sync.yml" \
    "$ROOT/scripts/ci/check_sync_manifest" 2>&1
); then
  fail "requires-closure fixture must satisfy the live manifest contract: $req_manifest_validation"
fi
printf 'lint v2\n' >"$REQ_MP/.github/workflows/repo_lint.yml"
git -C "$REQ_MP" -c user.email=t@t -c user.name=t add -A
git -C "$REQ_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "repo_lint bump only"
req_sha=$(git -C "$REQ_MP" rev-parse HEAD)

# Same stub gh as the metadata block: clone from the env remote, capture
# pr create bodies into the capture dir.
cp "$META_FAKE_BIN/gh" "$REQ_FAKE_BIN/gh"
chmod +x "$REQ_FAKE_BIN/gh"
REQ_REAL_GIT=$(command -v git)
cat >"$REQ_FAKE_BIN/git" <<'GITSTUB'
#!/usr/bin/env bash
case "${MERGEPATH_TEST_GIT_FAILURE:-}" in
  kit-ls-tree)
    case " $* " in
      *" ls-tree -r --name-only "*" scripts/runtime-kit "*) exit 42 ;;
    esac
    ;;
  source-blob)
    case " $* " in
      *" show "*":scripts/runtime-kit/check_a "*) printf 'runtime kit a v1\n'; exit 42 ;;
    esac
    ;;
  templated-consumer-blob)
    case " $* " in
      *" show :scripts/runtime/helper.sh "*) printf 'runtime blue\n'; exit 42 ;;
    esac
    ;;
esac
exec "$MERGEPATH_TEST_REAL_GIT" "$@"
GITSTUB
chmod +x "$REQ_FAKE_BIN/git"

req_setup_remote() {
  local remote=$1 seed=$2
  git init --bare -q "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  mkdir -p "$seed"
  git init -q "$seed"
  git -C "$seed" checkout -q -b main
  echo consumer >"$seed/README.md"
}
req_push_seed() {
  local remote=$1 seed=$2
  git -C "$seed" -c user.email=t@t -c user.name=t add -A
  git -C "$seed" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m initial
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" push -q origin main
}
req_run() {
  local run_id=$1 remote=$2
  env PATH="$REQ_FAKE_BIN:$PATH" \
    MERGEPATH_ROOT_OVERRIDE="$REQ_MP" \
    MERGEPATH_TEST_REMOTE_ALPHA="$remote" \
    MERGEPATH_TEST_CAPTURE_DIR="$REQ_CAPTURE" \
    MERGEPATH_TEST_RUN="$run_id" \
    MERGEPATH_TEST_REAL_GIT="$REQ_REAL_GIT" \
    MERGEPATH_TEST_GIT_FAILURE="${MERGEPATH_TEST_GIT_FAILURE:-}" \
    MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK=1 \
    "$SCRIPT" "$req_sha" --repos alpha 2>&1
}
req_run_sync_all() {
  local run_id=$1 remote=$2
  local path_filter=${3:-.github/workflows/repo_lint.yml}
  env PATH="$REQ_FAKE_BIN:$PATH" \
    MERGEPATH_ROOT_OVERRIDE="$REQ_MP" \
    MERGEPATH_TEST_REMOTE_ALPHA="$remote" \
    MERGEPATH_TEST_CAPTURE_DIR="$REQ_CAPTURE" \
    MERGEPATH_TEST_RUN="$run_id" \
    MERGEPATH_TEST_REAL_GIT="$REQ_REAL_GIT" \
    MERGEPATH_TEST_GIT_FAILURE="${MERGEPATH_TEST_GIT_FAILURE:-}" \
    MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK=1 \
    "$SCRIPT" --sync-all --repos alpha \
      --paths "$path_filter" 2>&1
}
req_run_full_sync_all() {
  local run_id=$1 remote=$2
  env PATH="$REQ_FAKE_BIN:$PATH" \
    MERGEPATH_ROOT_OVERRIDE="$REQ_MP" \
    MERGEPATH_TEST_REMOTE_ALPHA="$remote" \
    MERGEPATH_TEST_CAPTURE_DIR="$REQ_CAPTURE" \
    MERGEPATH_TEST_RUN="$run_id" \
    MERGEPATH_TEST_REAL_GIT="$REQ_REAL_GIT" \
    MERGEPATH_TEST_GIT_FAILURE="${MERGEPATH_TEST_GIT_FAILURE:-}" \
    MERGEPATH_SYNC_SKIP_AUTHOR_TOKEN_CHECK=1 \
    "$SCRIPT" --sync-all --repos alpha 2>&1
}

# (1) Required kit entirely MISSING on the consumer → the gate blocks this
#     consumer, names a missing kit file, points at the sync-all remedy, and
#     no PR is created (fails pre-fix: the PR shipped repo_lint.yml alone).
remote1="$req_workdir/nokit.git"; seed1="$req_workdir/nokit-seed"
req_setup_remote "$remote1" "$seed1"
req_push_seed "$remote1" "$seed1"
set +e
output=$(req_run reqgate1 "$remote1")
set -e
echo "$output" | grep -q "requires-closure gate" \
  || fail "requires gate did not fire for the kit-less consumer: $output"
echo "$output" | grep -q "scripts/ci/check_a" \
  || fail "gate message does not name a missing kit file: $output"
echo "$output" | grep -q -- "--sync-all" \
  || fail "gate message does not point at the sync-all remedy: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate1.txt" ] \
  || fail "PR was opened despite the missing required kit"
echo "PASS: requires-closure gate blocks a commit-path sync onto a kit-less consumer (#624)"

# (2) Required kit byte-current on the consumer → the gate passes and the
#     PR opens (kit content is unchanged between the two hub commits, so the
#     v1 seed matches the synced sha).
remote2="$req_workdir/kitok.git"; seed2="$req_workdir/kitok-seed"
req_setup_remote "$remote2" "$seed2"
mkdir -p "$seed2/scripts/ci"
printf 'check a v1\n' >"$seed2/scripts/ci/check_a"
printf 'check b v1\n' >"$seed2/scripts/ci/check_b"
chmod +x "$seed2/scripts/ci/check_a"
req_push_seed "$remote2" "$seed2"
set +e
output=$(req_run reqgate2 "$remote2")
set -e
echo "$output" | grep -q "requires-closure gate" \
  && fail "requires gate fired on a kit-current consumer: $output"
[ -f "$REQ_CAPTURE/pr-title-reqgate2.txt" ] \
  || fail "kit-current consumer did not get a PR: $output"
echo "PASS: requires-closure gate passes a kit-current consumer and the PR opens (#624)"

# (3) A required kit the consumer skips via .sync-overrides.yml is a
#     documented divergence, not a gate violation: check_b absent but the
#     manifest-level scripts/ci/ entry is override-skipped → PR opens.
remote3="$req_workdir/kitovr.git"; seed3="$req_workdir/kitovr-seed"
req_setup_remote "$remote3" "$seed3"
mkdir -p "$seed3/scripts/ci"
printf 'check a v1\n' >"$seed3/scripts/ci/check_a"
chmod +x "$seed3/scripts/ci/check_a"
cat >"$seed3/.sync-overrides.yml" <<'YAML'
version: 1
skip_paths:
  - path: scripts/ci/
    reason: |
      Consumer-local CI kit; tracked for convergence in alpha#1.
YAML
req_push_seed "$remote3" "$seed3"
set +e
output=$(req_run reqgate3 "$remote3")
set -e
echo "$output" | grep -q "requires-closure gate" \
  && fail "requires gate fired on an override-skipped required kit: $output"
[ -f "$REQ_CAPTURE/pr-title-reqgate3.txt" ] \
  || fail "override-skipped consumer did not get a PR: $output"
echo "PASS: requires-closure gate honors manifest-entry overrides for required kits (#624/#1058)"

# (4) Filtered sync-all has the same closure obligation. Selecting only the
#     requires-bearing workflow must fail closed when its kit is absent; the
#     unfiltered sync-all remedy can then carry both entries. Before this
#     regression, --sync-all --paths copied the workflow alone and opened a
#     consumer PR whose required lint failed at runtime.
remote4="$req_workdir/syncall-nokit.git"; seed4="$req_workdir/syncall-nokit-seed"
req_setup_remote "$remote4" "$seed4"
req_push_seed "$remote4" "$seed4"
set +e
output=$(req_run_sync_all reqgate4 "$remote4")
set -e
echo "$output" | grep -q "requires-closure gate" \
  || fail "filtered sync-all did not reject a missing required kit: $output"
echo "$output" | grep -q "scripts/ci/check_a" \
  || fail "filtered sync-all diagnostic did not name a missing required file: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate4.txt" ] \
  || fail "filtered sync-all opened a PR despite the missing required kit"
echo "PASS: requires-closure gate blocks filtered sync-all onto a kit-less consumer (#1058)"

# (5) Runtime closure includes executable helpers. Matching bytes with a stale
#     mode are not current: gh-token-resolver refuses a non-executable
#     identity-check helper. Model that with check_a (100755 at source, 100644
#     in the consumer) and require the closure gate to reject it before a PR.
remote5="$req_workdir/syncall-mode.git"; seed5="$req_workdir/syncall-mode-seed"
req_setup_remote "$remote5" "$seed5"
mkdir -p "$seed5/scripts/ci"
printf 'check a v1\n' >"$seed5/scripts/ci/check_a"
printf 'check b v1\n' >"$seed5/scripts/ci/check_b"
chmod -x "$seed5/scripts/ci/check_a"
req_push_seed "$remote5" "$seed5"
set +e
output=$(req_run_sync_all reqgate5 "$remote5")
set -e
echo "$output" | grep -q "requires-closure gate" \
  || fail "filtered sync-all accepted a required file with stale executable mode: $output"
echo "$output" | grep -q "scripts/ci/check_a" \
  || fail "mode-mismatch diagnostic did not name the required file: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate5.txt" ] \
  || fail "filtered sync-all opened a PR with a stale required-file mode"
echo "PASS: requires-closure gate compares required-file content and git mode (#1058)"

# (6) The prescribed unfiltered remedy carries the requiring workflow and its
#     covering kit in one slice. A kit-less consumer must therefore pass the
#     post-materialization closure check and receive a PR, rather than being
#     trapped by a gate that only looked at its pre-sync tree.
remote6="$req_workdir/syncall-full.git"; seed6="$req_workdir/syncall-full-seed"
req_setup_remote "$remote6" "$seed6"
req_push_seed "$remote6" "$seed6"
set +e
output=$(req_run_full_sync_all reqgate6 "$remote6")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "unfiltered sync-all closure remedy failed: $output"
echo "$output" | grep -q "requires-closure gate" \
  && fail "requires gate rejected a slice that carried its own complete kit: $output"
[ -f "$REQ_CAPTURE/pr-title-reqgate6.txt" ] \
  || fail "unfiltered sync-all did not open a PR after carrying the complete kit: $output"
echo "PASS: unfiltered sync-all carries and clears the selected target's runtime closure (#1058)"

# (7) A templated manifest entry covers its rendered destination, not its
#     source-side `.path`. A filtered slice carrying only a workflow that
#     requires that entry must fail when the rendered destination is absent.
remote7="$req_workdir/template-missing.git"; seed7="$req_workdir/template-missing-seed"
req_setup_remote "$remote7" "$seed7"
req_push_seed "$remote7" "$seed7"
set +e
output=$(req_run_sync_all reqgate7 "$remote7" ".github/workflows/templated_runtime.yml")
set -e
echo "$output" | grep -q "requires-closure gate" \
  || fail "templated requirement did not reject a missing rendered destination: $output"
echo "$output" | grep -q "scripts/runtime/helper.sh" \
  || fail "templated requirement diagnostic did not name its rendered destination: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate7.txt" ] \
  || fail "filtered sync-all opened a PR without its required templated destination"
echo "PASS: requires-closure gate rejects a missing templated runtime destination (#1058)"

# (8) The same filtered slice passes when the consumer already has the exact
#     per-consumer render and source mode. Comparing the raw template path here
#     would false-block even though the runtime artifact is current.
remote8="$req_workdir/template-current.git"; seed8="$req_workdir/template-current-seed"
req_setup_remote "$remote8" "$seed8"
mkdir -p "$seed8/scripts/runtime"
printf 'runtime blue\n' >"$seed8/scripts/runtime/helper.sh"
chmod +x "$seed8/scripts/runtime/helper.sh"
req_push_seed "$remote8" "$seed8"
set +e
output=$(req_run_sync_all reqgate8 "$remote8" ".github/workflows/templated_runtime.yml")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "current templated requirement blocked its filtered sync: $output"
echo "$output" | grep -q "requires-closure gate" \
  && fail "requires gate compared a templated source instead of its current rendered destination: $output"
[ -f "$REQ_CAPTURE/pr-title-reqgate8.txt" ] \
  || fail "filtered sync-all did not open a PR with its templated runtime already current: $output"
echo "PASS: requires-closure gate accepts an exact consumer-specific templated render (#1058)"

# (9) Render equality alone is insufficient for executable templated runtime
#     dependencies. Preserve the source template's git mode in the comparison,
#     just as materialization does when it stages the destination.
remote9="$req_workdir/template-mode.git"; seed9="$req_workdir/template-mode-seed"
req_setup_remote "$remote9" "$seed9"
mkdir -p "$seed9/scripts/runtime"
printf 'runtime blue\n' >"$seed9/scripts/runtime/helper.sh"
chmod -x "$seed9/scripts/runtime/helper.sh"
req_push_seed "$remote9" "$seed9"
set +e
output=$(req_run_sync_all reqgate9 "$remote9" ".github/workflows/templated_runtime.yml")
set -e
echo "$output" | grep -q "requires-closure gate" \
  || fail "templated requirement accepted a rendered destination with stale executable mode: $output"
echo "$output" | grep -q "scripts/runtime/helper.sh" \
  || fail "templated mode-mismatch diagnostic did not name its destination: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate9.txt" ] \
  || fail "filtered sync-all opened a PR with a mode-stale templated runtime"
echo "PASS: requires-closure gate compares templated destination content and git mode (#1058)"

# (10) A templated target skipped through its consumer destination override is
#      not part of the outgoing slice. Its own requirements must therefore not
#      be checked: nothing that depends on them will ship. Before this fix the
#      materializer honored the override but the closure gate still received
#      the unfiltered manifest entry and falsely blocked the no-op sync.
remote10="$req_workdir/template-override.git"; seed10="$req_workdir/template-override-seed"
req_setup_remote "$remote10" "$seed10"
cat >"$seed10/.sync-overrides.yml" <<'YAML'
version: 1
skip_paths:
  - path: scripts/runtime/helper.sh
    reason: |
      Consumer owns this rendered helper; tracked for convergence in alpha#2.
YAML
if ! override_validation=$(
  "$ROOT/scripts/sync/validate-overrides.sh" \
    "$seed10/.sync-overrides.yml" "$REQ_MP/.mergepath-sync.yml" 2>&1
); then
  fail "templated destination override must satisfy the live override schema: $override_validation"
fi
req_push_seed "$remote10" "$seed10"
set +e
output=$(req_run_sync_all reqgate10 "$remote10" "examples/runtime-helper.in")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "override-skipped templated target failed its no-op sync: $output"
echo "$output" | grep -q "requires-closure gate" \
  && fail "closure gate checked requirements for an override-skipped templated target: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate10.txt" ] \
  || fail "override-skipped templated no-op unexpectedly opened a PR"
echo "PASS: requires-closure gate excludes override-skipped templated targets (#1058)"

# (11) Fact export is part of the templated comparison, not an advisory setup
#      step. Model a helper failure after it clears the fact environment. The
#      lenient renderer would otherwise substitute an empty flavor and accept a
#      consumer artifact rendered from no facts at all.
cp "$REQ_MP/scripts/lib/manifest-fact-helpers.sh" "$req_workdir/manifest-fact-helpers.backup"
cat >"$REQ_MP/scripts/lib/manifest-fact-helpers.sh" <<'SH'
export_consumer_facts() {
  local var
  for var in $(env | awk -F= '/^MERGEPATH_FACT_/ {print $1}'); do
    unset "$var"
  done
  return 42
}
SH
remote11="$req_workdir/template-facts-fail.git"; seed11="$req_workdir/template-facts-fail-seed"
req_setup_remote "$remote11" "$seed11"
mkdir -p "$seed11/scripts/runtime"
printf 'runtime \n' >"$seed11/scripts/runtime/helper.sh"
chmod +x "$seed11/scripts/runtime/helper.sh"
req_push_seed "$remote11" "$seed11"
set +e
output=$(req_run_sync_all reqgate11 "$remote11" ".github/workflows/templated_runtime.yml")
set -e
echo "$output" | grep -q "requires-closure gate" \
  || fail "templated comparison did not fail closed when fact export failed: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate11.txt" ] \
  || fail "fact-less rendered dependency was accepted and a PR opened"
echo "PASS: requires-closure gate fails closed when consumer fact export fails (#1058)"

# (12) The materializer follows the same fail-closed fact contract. Give the
#      target's direct requirement an exact consumer copy so only the failed
#      fact export can stop the PR; lenient empty-fact rendering must not turn
#      that setup failure into a plausible generated artifact.
remote12="$req_workdir/template-materialize-facts-fail.git"; seed12="$req_workdir/template-materialize-facts-fail-seed"
req_setup_remote "$remote12" "$seed12"
mkdir -p "$seed12/scripts/ci"
printf 'check b v1\n' >"$seed12/scripts/ci/check_b"
req_push_seed "$remote12" "$seed12"
set +e
output=$(req_run_sync_all reqgate12 "$remote12" "examples/runtime-helper.in")
set -e
mv "$req_workdir/manifest-fact-helpers.backup" "$REQ_MP/scripts/lib/manifest-fact-helpers.sh"
echo "$output" | grep -q "render failed for templated" \
  || fail "templated materialization did not fail closed when fact export failed: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate12.txt" ] \
  || fail "materializer opened a PR after consumer fact export failed"
echo "PASS: templated materialization fails closed when consumer fact export fails (#1058)"

# (13) Kit paths are valid with or without a trailing slash. A slashless exact
#      kit requirement must recurse through the tree just like `scripts/ci/`;
#      comparing the directory tree object to the consumer's first child blob
#      falsely blocks an otherwise exact consumer.
remote13="$req_workdir/slashless-kit.git"; seed13="$req_workdir/slashless-kit-seed"
req_setup_remote "$remote13" "$seed13"
mkdir -p "$seed13/scripts/runtime-kit"
printf 'runtime kit a v1\n' >"$seed13/scripts/runtime-kit/check_a"
printf 'runtime kit b v1\n' >"$seed13/scripts/runtime-kit/check_b"
chmod +x "$seed13/scripts/runtime-kit/check_a"
req_push_seed "$remote13" "$seed13"
set +e
output=$(req_run_sync_all reqgate13 "$remote13" ".github/workflows/slashless_kit.yml")
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "slashless exact kit blocked a current consumer: $output"
echo "$output" | grep -q "requires-closure gate" \
  && fail "requires gate treated a slashless kit as a single file: $output"
[ -f "$REQ_CAPTURE/pr-title-reqgate13.txt" ] \
  || fail "current slashless-kit consumer did not get the selected workflow PR: $output"
echo "PASS: requires-closure gate recursively compares slashless exact kits (#1058)"

# (14) Once a requirement is known to be a tree, enumeration is safety
#      evidence. A failed `ls-tree -r` must not collapse to an empty file list
#      and be accepted as current.
remote14="$req_workdir/slashless-kit-enumeration-fail.git"; seed14="$req_workdir/slashless-kit-enumeration-fail-seed"
req_setup_remote "$remote14" "$seed14"
mkdir -p "$seed14/scripts/runtime-kit"
printf 'runtime kit a v1\n' >"$seed14/scripts/runtime-kit/check_a"
printf 'runtime kit b v1\n' >"$seed14/scripts/runtime-kit/check_b"
chmod +x "$seed14/scripts/runtime-kit/check_a"
req_push_seed "$remote14" "$seed14"
set +e
output=$(MERGEPATH_TEST_GIT_FAILURE=kit-ls-tree \
  req_run_sync_all reqgate14 "$remote14" ".github/workflows/slashless_kit.yml")
set -e
echo "$output" | grep -q "requires-closure gate" \
  || fail "kit enumeration failure did not fail the closure gate: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate14.txt" ] \
  || fail "kit enumeration failure was accepted and a PR opened"
echo "PASS: requires-closure gate fails closed on kit enumeration failure (#1058)"

# (15) Metadata equality is insufficient when either blob cannot be read.
#      Fault the source read after the tree and index modes have matched; the
#      gate must reject instead of comparing two empty process substitutions.
remote15="$req_workdir/slashless-kit-blob-fail.git"; seed15="$req_workdir/slashless-kit-blob-fail-seed"
req_setup_remote "$remote15" "$seed15"
mkdir -p "$seed15/scripts/runtime-kit"
printf 'runtime kit a v1\n' >"$seed15/scripts/runtime-kit/check_a"
printf 'runtime kit b v1\n' >"$seed15/scripts/runtime-kit/check_b"
chmod +x "$seed15/scripts/runtime-kit/check_a"
req_push_seed "$remote15" "$seed15"
set +e
output=$(MERGEPATH_TEST_GIT_FAILURE=source-blob \
  req_run_sync_all reqgate15 "$remote15" ".github/workflows/slashless_kit.yml")
set -e
echo "$output" | grep -q "requires-closure gate" \
  || fail "required blob read failure did not fail the closure gate: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate15.txt" ] \
  || fail "required blob read failure was accepted and a PR opened"
echo "PASS: requires-closure gate fails closed on required blob read failure (#1058)"

# (16) Templated comparisons have the same read-status obligation. Emit the
#      exact expected bytes but fail the staged consumer `git show`; a process
#      substitution makes `cmp` report equality while hiding that non-zero
#      producer, whereas an explicit checked read must reject it.
remote16="$req_workdir/template-consumer-blob-fail.git"; seed16="$req_workdir/template-consumer-blob-fail-seed"
req_setup_remote "$remote16" "$seed16"
mkdir -p "$seed16/scripts/runtime"
printf 'runtime blue\n' >"$seed16/scripts/runtime/helper.sh"
chmod +x "$seed16/scripts/runtime/helper.sh"
req_push_seed "$remote16" "$seed16"
set +e
output=$(MERGEPATH_TEST_GIT_FAILURE=templated-consumer-blob \
  req_run_sync_all reqgate16 "$remote16" ".github/workflows/templated_runtime.yml")
set -e
echo "$output" | grep -q "requires-closure gate" \
  || fail "templated consumer blob read failure did not fail the closure gate: $output"
[ ! -f "$REQ_CAPTURE/pr-title-reqgate16.txt" ] \
  || fail "templated consumer blob read failure was accepted and a PR opened"
echo "PASS: templated closure comparison fails closed on staged blob read failure (#1058)"


# ===========================================================================
# .github/workflows/weekly-drift-audit.yml — bounded tracking-issue body (#988)
# ===========================================================================
#
# The scheduled caller of `--audit` lives in that workflow, and its report
# path is where the audit's output actually becomes visible. It inlined the
# whole audit stream into a GitHub issue body unbounded, so from 2026-07-13
# every weekly run detected drift and then failed to file it: `createIssue`
# rejects a body over 65536 characters outright. The failure was
# self-reinforcing — the more drift accumulated, the larger the report and
# the more certain the rejection — so the lane went quiet exactly when it
# had the most to say, and six weeks of drift went unreported behind a red
# cron nobody read.
#
# These assertions live in this suite rather than in a suite of their own
# because the workflow is `scripts/sync-to-downstream.sh --audit`'s only
# scheduled caller, this file is already the hub-only home for that
# script's contract, and `scripts/ci/check_sync_to_downstream` already
# wires it into CI.
#
# The workflow's OWN bash is extracted with yq and executed against stubs
# rather than re-implemented or grepped for: a text assertion over the YAML
# could only say the budgeting code is present, never that a 130 KB audit
# stream comes out the other side as a body GitHub accepts.

WF_DRIFT="$ROOT/.github/workflows/weekly-drift-audit.yml"
[[ -f "$WF_DRIFT" ]] || { echo "FAIL: missing $WF_DRIFT" >&2; exit 1; }

wf_fail() { echo "FAIL: $*" >&2; exit 1; }

wf_step() {  # <step name> — print that step's `run:` body
  MP_STEP_NAME="$1" yq -r \
    '.jobs.audit.steps[] | select(.name == strenv(MP_STEP_NAME)) | .run' "$WF_DRIFT"
}

WFDIR="$WORKDIR/drift-workflow"
mkdir -p "$WFDIR/stub-bin"
wf_step 'Summarise the audit per consumer'      > "$WFDIR/summarise-step.sh"
wf_step 'Open or update the drift tracking issue' > "$WFDIR/issue-step.sh"
[ -s "$WFDIR/summarise-step.sh" ] \
  || wf_fail "could not extract the 'Summarise the audit per consumer' step from $WF_DRIFT"
[ -s "$WFDIR/issue-step.sh" ] \
  || wf_fail "could not extract the 'Open or update the drift tracking issue' step from $WF_DRIFT"

# `gh` stub modelling the slice this step uses INCLUDING the server-side
# validation GitHub applies. The body cap is the whole point: a permissive
# stub would accept the very payload that has been failing in production
# every week since 2026-07-13.
cat >"$WFDIR/stub-bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "$GH_CALL_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  printf '%s' "${GH_STUB_EXISTING:-}"
  exit 0
fi
if [ "${1:-}" = "issue" ] && { [ "${2:-}" = "create" ] || [ "${2:-}" = "edit" ]; }; then
  body_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --body-file) body_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$body_file" ] || { echo "stub: no --body-file" >&2; exit 1; }
  n="$(wc -c < "$body_file" | tr -d '[:space:]')"
  printf '%s\n' "$n" > "$GH_BODY_BYTES"
  # GitHub rejects the whole call past 65536 characters; it does not
  # truncate. Model that, plus an unconditional-failure switch for the
  # "the write failed anyway" path.
  if [ -n "${GH_STUB_WRITE_FAIL:-}" ]; then
    echo "GraphQL: Something went wrong (createIssue)" >&2
    exit 1
  fi
  if [ "$n" -gt 65536 ]; then
    echo "GraphQL: Body is too long (maximum is 65536 characters) (createIssue)" >&2
    exit 1
  fi
  echo "stub: issue written ($n characters)"
  exit 0
fi
exit 0
GHSTUB
chmod +x "$WFDIR/stub-bin/gh"

# One consumer section per consumer, each with a header line, a baseline
# line and a run of status lines — the exact shape emit_status_line() and
# emit_skip_line() produce above.
wf_make_audit_output() {  # <file> <drift-lines-per-consumer>
  local out=$1 n=$2 c i
  : > "$out"
  for c in alpha bravo charlie delta epsilon; do
    printf '%s (x/%s)\n' "$c" "$c" >> "$out"
    printf '  baseline: main@abc1234 (cache clone, refreshed from origin default branch)\n' >> "$out"
    printf '  ✓ %-50s in sync\n' "scripts/in-sync.sh" >> "$out"
    i=1
    while [ "$i" -le "$n" ]; do
      printf '  ✗ %-50s drift: %d diff line(s)\n' "scripts/deeply/nested/path/file-$i.sh" "$i" >> "$out"
      i=$((i + 1))
    done
    printf '  ⊘ %-50s missing entirely\n' "scripts/absent.sh" >> "$out"
    printf '  ↷ %-50s skipped per .sync-overrides.yml: local fork\n' "scripts/override.sh" >> "$out"
    printf '\n' >> "$out"
  done
}

wf_run_steps() {  # runs both steps in a clean dir; sets WF_RC / WF_TEXT
  local dir=$1
  WF_RC=0
  WF_TEXT="$(
    cd "$dir" && \
    PATH="$WFDIR/stub-bin:$PATH" \
    GH_CALL_LOG="$dir/gh-calls.log" \
    GH_BODY_BYTES="$dir/body-bytes.txt" \
    GITHUB_STEP_SUMMARY="$dir/step-summary.md" \
    TRACKING_LABEL="propagation-drift" \
    ISSUE_TITLE="Cross-repo propagation drift detected" \
    REPO="nathanjohnpayne/mergepath" \
    RUN_URL="https://github.com/nathanjohnpayne/mergepath/actions/runs/1" \
      bash "$WFDIR/summarise-step.sh" > /dev/null && \
    cd "$dir" && \
    PATH="$WFDIR/stub-bin:$PATH" \
    GH_CALL_LOG="$dir/gh-calls.log" \
    GH_BODY_BYTES="$dir/body-bytes.txt" \
    GITHUB_STEP_SUMMARY="$dir/step-summary.md" \
    GH_STUB_EXISTING="${GH_STUB_EXISTING:-}" \
    GH_STUB_WRITE_FAIL="${GH_STUB_WRITE_FAIL:-}" \
    TRACKING_LABEL="propagation-drift" \
    ISSUE_TITLE="Cross-repo propagation drift detected" \
    REPO="nathanjohnpayne/mergepath" \
    RUN_URL="https://github.com/nathanjohnpayne/mergepath/actions/runs/1" \
      bash "$WFDIR/issue-step.sh" 2>&1
  )" || WF_RC=$?
}

# --- (1) An oversized audit stream still produces a body GitHub accepts ---
#
# 400 drift lines x 5 consumers is ~130 KB — twice the cap, and the shape
# every failing production run had.
BIG="$WFDIR/big"; mkdir -p "$BIG"; : > "$BIG/gh-calls.log"
wf_make_audit_output "$BIG/audit-output.txt" 400
big_bytes="$(wc -c < "$BIG/audit-output.txt" | tr -d '[:space:]')"
[ "$big_bytes" -gt 65536 ] \
  || wf_fail "fixture is not oversized ($big_bytes bytes) — the assertion below would be vacuous"

GH_STUB_EXISTING="" GH_STUB_WRITE_FAIL="" wf_run_steps "$BIG"
[ "$WF_RC" -eq 0 ] || wf_fail "oversized audit output must still file the issue; step exited $WF_RC: $WF_TEXT"
body_bytes="$(cat "$BIG/body-bytes.txt")"
[ "$body_bytes" -le 65536 ] \
  || wf_fail "issue body was $body_bytes characters — GitHub rejects anything over 65536"
grep -q 'gh issue create' "$BIG/gh-calls.log" \
  || wf_fail "no issue was created from an oversized audit run: $(cat "$BIG/gh-calls.log")"
echo "PASS: a 130 KB audit stream still files a tracking issue under GitHub's 65536-char body cap (#988)"

# --- (2) Truncation is announced, and says how much was dropped ----------
grep -q 'truncated:' "$BIG/issue-body.txt" \
  || wf_fail "truncated body does not say it was truncated"
grep -Eq 'truncated: [0-9]+ of [0-9]+ audit output line\(s\) omitted' "$BIG/issue-body.txt" \
  || wf_fail "truncation notice must count the omitted lines: $(grep -n 'truncated' "$BIG/issue-body.txt")"
grep -q 'actions/runs/1' "$BIG/issue-body.txt" \
  || wf_fail "truncation notice must point at the run log holding the full stream"
# The raw-block budget has to be what bounds the body. The step also carries
# a whole-body emergency clamp, and a clamped body is a DEGRADED report — it
# loses the truncation notice, the closing fence and the footer. Pinning the
# footer's survival is what stops a regression in the budget from hiding
# behind the backstop and still passing the size assertion above.
grep -q 'cc @nathanjohnpayne' "$BIG/issue-body.txt" \
  || wf_fail "budgeted body lost its footer — it was cut by the emergency clamp, not bounded by the raw-block budget"
if grep -q 'hard-clamped' "$BIG/issue-body.txt"; then
  wf_fail "the raw-block budget must bound the body on its own; the whole-body clamp is a backstop, not the mechanism"
fi
echo "PASS: a truncated drift report says so, counts the omitted lines, and points at the run log (#988)"

# --- (3) Truncation never costs the report a consumer -------------------
#
# The regression this closes is not only "the body was too long" — it is
# "a report that has to shrink loses whole consumers off the alphabetical
# tail". The per-consumer roll-up is carried whole for exactly that reason.
for c in alpha bravo charlie delta epsilon; do
  grep -q "^${c} (x/${c}) — in sync 1, drifted 400, missing 1, skipped 1$" "$BIG/issue-body.txt" \
    || wf_fail "consumer '$c' is missing (or miscounted) in the truncated report: $(grep -n ' — in sync ' "$BIG/issue-body.txt")"
done
echo "PASS: every consumer is still named with its drift counts in a truncated report (#988)"

# --- (4) A small audit is NOT truncated ---------------------------------
#
# Guards the other direction: a step that always truncates would pass every
# assertion above while throwing away findings that fit.
SMALL="$WFDIR/small"; mkdir -p "$SMALL"; : > "$SMALL/gh-calls.log"
wf_make_audit_output "$SMALL/audit-output.txt" 3
GH_STUB_EXISTING="" GH_STUB_WRITE_FAIL="" wf_run_steps "$SMALL"
[ "$WF_RC" -eq 0 ] || wf_fail "small audit output must file the issue; step exited $WF_RC: $WF_TEXT"
if grep -q 'truncated:' "$SMALL/issue-body.txt"; then
  wf_fail "a small audit output must not be truncated"
fi
grep -q 'scripts/deeply/nested/path/file-3.sh' "$SMALL/issue-body.txt" \
  || wf_fail "a small audit output must be carried in full"
echo "PASS: an audit output that fits is carried whole, not truncated anyway (#988)"

# --- (5) A failed write names what was lost -----------------------------
#
# The six weeks of silence were a red cron and a raw GraphQL line. If the
# write fails for any other reason the run must still say, in an ::error::
# annotation, that drift WAS detected and where to read it.
FAILW="$WFDIR/failed-write"; mkdir -p "$FAILW"; : > "$FAILW/gh-calls.log"
wf_make_audit_output "$FAILW/audit-output.txt" 3
GH_STUB_EXISTING="" GH_STUB_WRITE_FAIL="1" wf_run_steps "$FAILW"
[ "$WF_RC" -ne 0 ] || wf_fail "a failed issue write must fail the step"
echo "$WF_TEXT" | grep -q '::error::' \
  || wf_fail "a failed issue write must emit an ::error:: annotation: $WF_TEXT"
echo "$WF_TEXT" | grep -q 'Drift WAS detected' \
  || wf_fail "a failed issue write must say drift was detected but unfiled: $WF_TEXT"
echo "$WF_TEXT" | grep -q 'actions/runs/1' \
  || wf_fail "a failed issue write must point at the run holding the findings: $WF_TEXT"
echo "PASS: a tracking-issue write failure reports that drift was detected and unfiled (#988)"

# --- (6) The update path is bounded too ---------------------------------
#
# Once a tracking issue exists the workflow edits it in place, and
# `updateIssue` enforces the same 65536 cap — so a fix that only bounded
# the create path would move the failure rather than remove it.
UPD="$WFDIR/update"; mkdir -p "$UPD"; : > "$UPD/gh-calls.log"
wf_make_audit_output "$UPD/audit-output.txt" 400
GH_STUB_EXISTING="4242" GH_STUB_WRITE_FAIL="" wf_run_steps "$UPD"
[ "$WF_RC" -eq 0 ] || wf_fail "oversized audit output must still update the issue; step exited $WF_RC: $WF_TEXT"
grep -q 'gh issue edit 4242' "$UPD/gh-calls.log" \
  || wf_fail "the update path did not run: $(cat "$UPD/gh-calls.log")"
upd_bytes="$(cat "$UPD/body-bytes.txt")"
[ "$upd_bytes" -le 65536 ] \
  || wf_fail "update-path body was $upd_bytes characters — over GitHub's cap"
echo "PASS: the edit-in-place path is bounded by the same budget as the create path (#988)"

echo "test_sync_to_downstream: PASS"
