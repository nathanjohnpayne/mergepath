#!/usr/bin/env bash
# tests/test_bootstrap_template_mirror.sh
#
# Validates scripts/bootstrap/template-mirror.sh (sub-B / #204).
# Builds a synthetic mergepath worktree with the documented exclude
# patterns sprinkled around it, runs the wizard's stage B against a
# temp target dir, and asserts:
#
#   1. Every documented exclude path is absent from the target.
#   2. The orphan playground test is removed post-rsync.
#   3. Empty post-rsync dirs (e.g., bugs/) are tombstoned.
#   4. The 6 name-bearing files have their mergepath references
#      substituted to the new repo name in all three case forms
#      (lowercase / Titlecased / UPPERCASE) + URL.
#   5. .repo-template.yml has the playground spec_test_map entry
#      and extra_top_level_dirs dropped.
#   6. The target has a single initial git commit.
#   7. The cross-repo loop step exits cleanly (with a warning) when
#      the loop-doc anchors are absent. The current mergepath does
#      not carry anchors yet — that's a separate doc-refactor PR.
#
# Requires: rsync, yq, git, awk, sed. (rsync is preinstalled on macOS
# and most Linux distros; yq is checked via the same SKIP pattern as
# the sync test suite.)
#
# Run manually or via scripts/ci/check_bootstrap_template_mirror.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/bootstrap-new-repo.sh"

# --- skip guards ------------------------------------------------------------

if ! command -v rsync >/dev/null 2>&1; then
  echo "SKIP: rsync not installed" >&2
  exit 0
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "SKIP: yq not installed (brew install yq)" >&2
  exit 0
fi
if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  echo "SKIP: detected non-mikefarah yq" >&2
  exit 0
fi

[ -x "$SCRIPT" ] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

# --- fixture setup ---------------------------------------------------------

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-template-mirror.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_MP="$WORKDIR/fake-mergepath"
TARGET="$WORKDIR/new-repo"

# Build a synthetic mergepath worktree that mirrors the real repo's
# shape only as much as we need to exercise the stage. Each excluded
# path appears at least once so we can verify it doesn't propagate.
mkdir -p \
  "$FAKE_MP/scripts/bootstrap" \
  "$FAKE_MP/scripts/hooks" \
  "$FAKE_MP/scripts/ci" \
  "$FAKE_MP/scripts/sync" \
  "$FAKE_MP/.github/workflows" \
  "$FAKE_MP/.github/screenshots" \
  "$FAKE_MP/.claude/worktrees" \
  "$FAKE_MP/bugs/screenshots" \
  "$FAKE_MP/dist" \
  "$FAKE_MP/mergepath" \
  "$FAKE_MP/packaging" \
  "$FAKE_MP/tests" \
  "$FAKE_MP/specs" \
  "$FAKE_MP/plans" \
  "$FAKE_MP/docs/agents"

# --- name-bearing files (the substitution targets) ---
cat >"$FAKE_MP/README.md" <<'EOF'
# mergepath

A template repo. See https://github.com/nathanjohnpayne/mergepath for the source.

Set `MERGEPATH_ROOT=/path` then run scripts. Mergepath itself is the canonical source.
EOF

cat >"$FAKE_MP/BRAND.md" <<'EOF'
# Brand: Mergepath
mergepath, Mergepath, and MERGEPATH all appear here.
EOF

cat >"$FAKE_MP/.ai_context.md" <<'EOF'
Plain agent context with no template-name string (this file is in
the name-bearing list only so we can test the no-match path).
EOF

cat >"$FAKE_MP/docs/agents/repository-overview.md" <<'EOF'
# mergepath repository overview
This repo (mergepath) is the template. Authors clone from https://github.com/nathanjohnpayne/mergepath.
EOF

cat >"$FAKE_MP/.repo-template.yml" <<'EOF'
spec_test_map:
  mergepath_playground:
    - tests/test_mergepath_playground.sh
  some_other_spec:
    - tests/test_some_other.sh
test_globs:
  - "tests/**"
extra_top_level_dirs: [mergepath, packaging]
EOF

cat >"$FAKE_MP/SECURITY.md" <<'EOF'
# Security
Report issues to security@mergepath.example.
EOF

# --- excluded paths (must NOT propagate) ---
echo "playground spec" >"$FAKE_MP/specs/mergepath_playground.md"
echo "playground plan" >"$FAKE_MP/plans/mergepath-playground.md"
echo "playground test" >"$FAKE_MP/tests/test_mergepath_playground.sh"
echo "screenshot bug"  >"$FAKE_MP/bugs/screenshots/foo.png"
echo "workflow screen" >"$FAKE_MP/.github/screenshots/bar.png"
echo "claude worktree state" >"$FAKE_MP/.claude/worktrees/foo.json"
echo '{"local":true}' >"$FAKE_MP/.claude/settings.local.json"
echo '{"launch":true}' >"$FAKE_MP/.claude/launch.json"
echo "dist artifact" >"$FAKE_MP/dist/output.tgz"
echo "mergepath internal" >"$FAKE_MP/mergepath/internal.md"
echo "packaging metadata" >"$FAKE_MP/packaging/meta.json"
echo "policy sim" >"$FAKE_MP/scripts/policy-sim.sh"
# Sync-to-downstream orchestrator surface (engine + manifest + paired test +
# cron driver) - mergepath-only; the engine + manifest are also the
# consumer-vs-mergepath markers the propagated scripts/ci/check_* wrappers key
# off, and weekly-drift-audit.yml is the hub-only cron that runs the engine.
echo "version: 1" >"$FAKE_MP/.mergepath-sync.yml"
echo "sync engine" >"$FAKE_MP/scripts/sync-to-downstream.sh"
echo "sync engine test" >"$FAKE_MP/tests/test_sync_to_downstream.sh"
echo "name: weekly-drift-audit" >"$FAKE_MP/.github/workflows/weekly-drift-audit.yml"
# Project-doc orchestrator surface (docs/manifest from #509 + engine + test).
echo "version: 1" >"$FAKE_MP/.mergepath-project-docs.yml"
mkdir -p "$FAKE_MP/docs/projects/mergepath/prds"
echo "generated prd mirror" >"$FAKE_MP/docs/projects/mergepath/prds/mergepath.md"
echo "project-doc engine" >"$FAKE_MP/scripts/project-doc-sync.sh"
echo "project-doc test" >"$FAKE_MP/tests/test_project_doc_sync.sh"
# Load-bearing sync internals that MUST still propagate: kit-propagated
# scripts/ci/check_sync_overrides hard-requires tests/test_sync_overrides.sh
# (no consumer-skip path), which sources scripts/sync/. Present here so the
# test can assert they SURVIVE the mirror (excluding them would red lint).
mkdir -p "$FAKE_MP/scripts/sync"
echo "validate overrides" >"$FAKE_MP/scripts/sync/validate-overrides.sh"
echo "apply overrides" >"$FAKE_MP/scripts/sync/apply-overrides.sh"
echo "sync overrides test" >"$FAKE_MP/tests/test_sync_overrides.sh"
echo "old log" >"$FAKE_MP/.bootstrap-log"
echo "old state" >"$FAKE_MP/.bootstrap-state"

# Stash file the bootstrap state file recipe touches.
echo "" >"$FAKE_MP/.claude/.gitkeep"

# --- normal files that SHOULD propagate ---
echo "real script" >"$FAKE_MP/scripts/normal-helper.sh"
echo "real workflow" >"$FAKE_MP/.github/workflows/lint.yml"
# Hub policy with phase_4b_automation ENABLED (#628): the mirror must reset
# the parent switch to false in the target while leaving nested enabled
# keys (accounting) and sibling blocks untouched.
cat >"$FAKE_MP/.github/review-policy.yml" <<'YAML'
coderabbit:
  enabled: true
phase_4b_automation:
  enabled: true
  mode: local
  accounting:
    enabled: true
YAML
echo "real hook" >"$FAKE_MP/scripts/hooks/some-hook.sh"
echo "real ci check" >"$FAKE_MP/scripts/ci/check_thing"

# --- copy the real bootstrap stage files into the fake worktree ---
# Without these, the wizard fails to find its library at startup.
cp "$ROOT/scripts/bootstrap/_lib.sh"                "$FAKE_MP/scripts/bootstrap/_lib.sh"
cp "$ROOT/scripts/bootstrap/template-mirror.sh"     "$FAKE_MP/scripts/bootstrap/template-mirror.sh"
cp "$ROOT/scripts/bootstrap/substitute.sh"          "$FAKE_MP/scripts/bootstrap/substitute.sh"
cp "$ROOT/scripts/bootstrap/github-infra.sh"        "$FAKE_MP/scripts/bootstrap/github-infra.sh"
cp "$ROOT/scripts/bootstrap/firebase-and-codereview.sh" "$FAKE_MP/scripts/bootstrap/firebase-and-codereview.sh"
cp "$ROOT/scripts/bootstrap/board-and-summary.sh"   "$FAKE_MP/scripts/bootstrap/board-and-summary.sh"
cp "$ROOT/scripts/bootstrap-new-repo.sh"            "$FAKE_MP/scripts/bootstrap-new-repo.sh"

# Real consumer-detecting check wrappers - copied so the mirror carries them
# into TARGET (they ride the scripts/ci/ kit in a real bootstrap). The
# consumer-SKIP assertion below runs them FROM the generated TARGET to prove
# they take the skip path now that the orchestrator surface is excluded. They
# are NOT in BOOTSTRAP_NAME_BEARING_FILES, so substitution leaves their
# ".mergepath-sync.yml" / "scripts/sync-to-downstream.sh" detection intact.
cp "$ROOT/scripts/ci/check_sync_manifest"         "$FAKE_MP/scripts/ci/check_sync_manifest"
cp "$ROOT/scripts/ci/check_sync_to_downstream"    "$FAKE_MP/scripts/ci/check_sync_to_downstream"
cp "$ROOT/scripts/ci/check_export_consumer_facts" "$FAKE_MP/scripts/ci/check_export_consumer_facts"

# git init so preflight check 6 (clean mergepath) passes.
git -C "$FAKE_MP" init -q
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -A
git -C "$FAKE_MP" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "fixture: initial"
git -C "$FAKE_MP" branch -M main 2>/dev/null || true

# --- runners --------------------------------------------------------------

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Drive the wizard with stage B in scope. We use the real wizard
# binary so dispatch/preflight integration is exercised end-to-end;
# stages C/D/E remain stubs and run without side effect. The
# environment knobs:
#   BOOTSTRAP_MERGEPATH_ROOT — point source resolution at the fixture
#   BOOTSTRAP_SKIP_TOOL_CHECK=1 — bypass live gh/op probes
#   BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 — fixture is on main+clean by
#     construction but we set this so the test isn't sensitive to
#     the operator's actual mergepath state if the fixture init
#     somehow doesn't go through
#   BOOTSTRAP_AUTO_CONFIRM=1 — auto-yes the cross-repo loop prompt
#     (the function will still short-circuit because anchors absent)
#   BOOTSTRAP_AUTHOR_NAME / EMAIL — make the initial commit
#     reproducible across machines
#
# NOTE: rsync source-root is resolved INSIDE the stage from
# $BOOTSTRAP_MERGEPATH_ROOT, so we point that at the fixture.

set +e
out=$(BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
      BOOTSTRAP_SKIP_TOOL_CHECK=1 \
      BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
      BOOTSTRAP_AUTO_CONFIRM=1 \
      BOOTSTRAP_AUTO_PROMPT=skip \
      BOOTSTRAP_AUTHOR_NAME="test" \
      BOOTSTRAP_AUTHOR_EMAIL="t@t" \
      BOOTSTRAP_SKIP_AUTHOR_TOKEN=1 \
      BOOTSTRAP_SKIP_STAGES="github-infra,firebase-and-codereview,board-and-summary" \
      "$SCRIPT" my-new-repo \
        --target-dir "$TARGET" \
        --description "a test repo" --visibility private \
        --firebase none --codex-app n --project new 2>&1)
ec=$?
set -e

[ "$ec" -eq 0 ] \
  && pass "stage B live run completes (exit 0)" \
  || fail "stage B live run failed; rc=$ec; out: $out"

# --- assertion 1: excludes honored ---
for excluded in \
  '.git' \
  'dist' \
  'mergepath' \
  'packaging' \
  '.claude/worktrees' \
  '.claude/settings.local.json' \
  '.claude/launch.json' \
  'specs/mergepath_playground.md' \
  'plans/mergepath-playground.md' \
  'scripts/policy-sim.sh' \
  '.mergepath-sync.yml' \
  'scripts/sync-to-downstream.sh' \
  'tests/test_sync_to_downstream.sh' \
  '.github/workflows/weekly-drift-audit.yml' \
  '.mergepath-project-docs.yml' \
  'docs/projects' \
  'scripts/project-doc-sync.sh' \
  'tests/test_project_doc_sync.sh' \
  'bugs/screenshots' \
  '.github/screenshots' ; do
  # Skip .git — the stage init step creates a fresh .git/ in the target.
  if [ "$excluded" = ".git" ]; then continue; fi
  if [ -e "$TARGET/$excluded" ]; then
    fail "exclude not honored: $excluded ended up at $TARGET/$excluded"
  fi
done
[ "$FAIL" -eq 0 ] && pass "all documented exclude paths honored (incl. sync + project-doc orchestrator surface)"

# --- assertion 1b: load-bearing sync internals MUST survive the mirror ---
# scripts/ci/check_sync_overrides is kit-propagated and has NO consumer-skip
# path - it hard-errors without tests/test_sync_overrides.sh, which sources
# scripts/sync/{validate,apply}-overrides.sh. Excluding any of these would red
# a bootstrapped repo's repo_lint, so they must NOT be swept up with the
# orchestrator surface above.
for kept in \
  'scripts/sync/validate-overrides.sh' \
  'scripts/sync/apply-overrides.sh' \
  'tests/test_sync_overrides.sh' ; do
  [ -e "$TARGET/$kept" ] \
    && pass "load-bearing sync internal propagated: $kept" \
    || fail "$kept must propagate (check_sync_overrides hard-requires it)"
done

# --- assertion 1c: orchestrator checks take the consumer-SKIP path ---
# The point of excluding the surface: the kit-propagated check_* wrappers that
# disambiguate "consumer vs mergepath" must SKIP cleanly (exit 0) when run from
# the generated TARGET, exactly as on a real consumer checkout. Run the REAL
# wrappers (mirrored into TARGET) so this exercises the actual propagated
# detection logic, not a re-implementation:
#   - check_sync_manifest:         .mergepath-sync.yml absent + engine absent
#   - check_sync_to_downstream:    test_sync_to_downstream.sh absent + manifest absent
#   - check_export_consumer_facts: engine absent + manifest absent
for chk in check_sync_manifest check_sync_to_downstream check_export_consumer_facts; do
  if [ ! -f "$TARGET/scripts/ci/$chk" ]; then
    fail "$chk wrapper did not propagate into TARGET (scripts/ci/ kit)"
    continue
  fi
  set +e
  chk_out=$(bash "$TARGET/scripts/ci/$chk" 2>&1)
  chk_ec=$?
  set -e
  if [ "$chk_ec" -eq 0 ] && printf '%s' "$chk_out" | grep -q "SKIP"; then
    pass "$chk takes consumer-SKIP path on bootstrapped tree"
  else
    fail "$chk should SKIP on bootstrapped tree; rc=$chk_ec, out: $chk_out"
  fi
done

# .bootstrap-log from the source must NOT propagate as-is into the
# target. The wizard creates its OWN .bootstrap-log in the target
# (it's the run transcript), so we assert on CONTENT rather than
# absence: the target's log must not carry the fixture's marker.
if [ -f "$TARGET/.bootstrap-log" ] && grep -q "^old log$" "$TARGET/.bootstrap-log"; then
  fail "old .bootstrap-log content leaked into target (rsync exclude missed it)"
else
  pass "old .bootstrap-log content excluded (target has its own fresh transcript)"
fi
# Same idea for .bootstrap-state.
if [ -f "$TARGET/.bootstrap-state" ] && grep -q "^old state$" "$TARGET/.bootstrap-state"; then
  fail "old .bootstrap-state content leaked into target"
else
  pass "old .bootstrap-state content excluded"
fi

# --- assertion 2: orphan removed ---
[ ! -e "$TARGET/tests/test_mergepath_playground.sh" ] \
  && pass "orphan playground test removed" \
  || fail "tests/test_mergepath_playground.sh should be removed"

# --- assertion 3: empty post-rsync dirs tombstoned ---
[ ! -d "$TARGET/bugs" ] \
  && pass "empty bugs/ dir tombstoned" \
  || fail "bugs/ should be tombstoned after screenshot exclude"

# --- assertion 4: name substitutions ---
grep -q "^# my-new-repo$" "$TARGET/README.md" \
  && pass "README lowercase 'mergepath' substituted" \
  || fail "README didn't get lowercase substitution; got: $(head -1 "$TARGET/README.md")"

# Mergepath URL should become the new repo URL.
grep -q "https://github.com/nathanjohnpayne/my-new-repo" "$TARGET/README.md" \
  && pass "README URL rewritten to new repo" \
  || fail "README URL not rewritten; got: $(grep github "$TARGET/README.md")"

grep -q "^MERGEPATH" "$TARGET/README.md" \
  && fail "uppercase 'MERGEPATH_ROOT' not substituted in README" \
  || pass "uppercase 'MERGEPATH' → 'MY_NEW_REPO' substituted"
grep -q "MY_NEW_REPO_ROOT" "$TARGET/README.md" \
  && pass "uppercase env-var form 'MY_NEW_REPO_ROOT' present" \
  || fail "expected 'MY_NEW_REPO_ROOT' in README; got: $(grep _ROOT "$TARGET/README.md")"

# BRAND.md exercises all 3 forms.
grep -q "Brand: My-new-repo" "$TARGET/BRAND.md" \
  && pass "BRAND Titlecase 'Mergepath' → 'My-new-repo'" \
  || fail "BRAND Titlecase not substituted; got: $(grep -i brand "$TARGET/BRAND.md")"
grep -q "MY_NEW_REPO" "$TARGET/BRAND.md" \
  && pass "BRAND uppercase form present" \
  || fail "BRAND uppercase missing"
grep -q "my-new-repo" "$TARGET/BRAND.md" \
  && pass "BRAND lowercase form present" \
  || fail "BRAND lowercase missing"

# No remaining 'mergepath' references in name-bearing files.
remaining=$(grep -h -i "mergepath" "$TARGET/README.md" "$TARGET/BRAND.md" \
            "$TARGET/docs/agents/repository-overview.md" "$TARGET/SECURITY.md" \
            2>/dev/null || true)
[ -z "$remaining" ] \
  && pass "no residual 'mergepath' references in name-bearing files" \
  || fail "residual 'mergepath' references found: $remaining"

# .ai_context.md has no mergepath refs to begin with — substitution
# should produce a byte-identical file (warning logged but no error).
diff -q "$FAKE_MP/.ai_context.md" "$TARGET/.ai_context.md" >/dev/null \
  && pass ".ai_context.md (no mergepath refs) substituted as no-op" \
  || fail ".ai_context.md content drifted unexpectedly"

# --- assertion 5: .repo-template.yml cleanup ---
if yq '.spec_test_map.mergepath_playground' "$TARGET/.repo-template.yml" 2>/dev/null \
     | grep -q "tests/test_mergepath_playground"; then
  fail "playground spec_test_map entry not removed"
else
  pass "playground spec_test_map entry removed"
fi
# extra_top_level_dirs must be gone.
if yq 'has("extra_top_level_dirs")' "$TARGET/.repo-template.yml" 2>/dev/null \
     | grep -q true; then
  fail "extra_top_level_dirs not removed"
else
  pass "extra_top_level_dirs key removed"
fi
# But some_other_spec entry should remain (we only dropped the playground one).
yq '.spec_test_map.some_other_spec' "$TARGET/.repo-template.yml" 2>/dev/null \
  | grep -q "tests/test_some_other" \
  && pass "unrelated spec_test_map entries preserved" \
  || fail "unrelated spec_test_map entry was accidentally dropped"

# --- assertion 6: target has a single initial commit ---
[ -d "$TARGET/.git" ] \
  && pass "target has .git initialized" \
  || fail "target missing .git after stage B"
commit_count=$(git -C "$TARGET" rev-list --count HEAD 2>/dev/null || echo 0)
[ "$commit_count" = "1" ] \
  && pass "target has exactly 1 initial commit" \
  || fail "expected 1 commit, got $commit_count"
git -C "$TARGET" log -1 --format=%s | grep -q "Initial commit (bootstrapped from mergepath)" \
  && pass "initial commit subject matches" \
  || fail "initial commit subject wrong: $(git -C "$TARGET" log -1 --format=%s)"

# --- assertion 7: cross-repo loop step skipped (no anchors) ---
# The fixture's DEPLOYMENT.md and REVIEW_POLICY.md don't even exist,
# so the step should warn and bail without modifying the source.
# After running, mergepath fixture's worktree should still be clean
# on main with only the initial fixture commit.
fixture_commits=$(git -C "$FAKE_MP" rev-list --count HEAD 2>/dev/null || echo 0)
[ "$fixture_commits" = "1" ] \
  && pass "cross-repo loop step did not touch mergepath fixture" \
  || fail "expected fixture to remain at 1 commit; got $fixture_commits"
fixture_dirty=$(git -C "$FAKE_MP" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
[ "$fixture_dirty" = "0" ] \
  && pass "mergepath fixture worktree is clean after stage B" \
  || fail "mergepath fixture is dirty: $(git -C "$FAKE_MP" status --porcelain)"
# No new branch should be left behind.
fixture_branches=$(git -C "$FAKE_MP" branch --format='%(refname:short)' | sort)
echo "$fixture_branches" | grep -q "^bootstrap/" \
  && fail "stray bootstrap/* branch left on fixture: $fixture_branches" \
  || pass "no stray bootstrap/* branch on fixture"

# --- assertion 8: state file recorded template-mirror ---
[ -f "$TARGET/.bootstrap-state" ] \
  && grep -q "^template-mirror$" "$TARGET/.bootstrap-state" \
  && pass "state file records template-mirror completion" \
  || fail "state file missing template-mirror entry"

# --- assertion 8b: phase_4b_automation.enabled reset to false in target (#628) ---
mirrored_policy="$TARGET/.github/review-policy.yml"
if [ -f "$mirrored_policy" ] \
   && awk '/^phase_4b_automation:/{b=1;next} b&&/^[^ #]/{b=0} b&&/^  enabled:/{print $2; exit}' "$mirrored_policy" | grep -qx "false" \
   && awk '/^  accounting:/{a=1;next} a&&/^    enabled:/{print $2; exit}' "$mirrored_policy" | grep -qx "true" \
   && awk '/^coderabbit:/{c=1;next} c&&/^[^ #]/{c=0} c&&/^  enabled:/{print $2; exit}' "$mirrored_policy" | grep -qx "true"; then
  pass "mirrored review-policy resets phase_4b_automation.enabled to false; accounting + coderabbit enables untouched (#628)"
else
  fail "phase-4b default reset wrong: $(grep -n 'enabled:' "$mirrored_policy" 2>/dev/null | head -5)"
fi

# --- assertion 9: --dry-run path produces no on-disk side effects ---
dry_target="$WORKDIR/dry-target"
set +e
dry_out=$(BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
          BOOTSTRAP_SKIP_TOOL_CHECK=1 \
          BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
          BOOTSTRAP_AUTO_CONFIRM=1 \
          BOOTSTRAP_AUTO_PROMPT=skip \
          BOOTSTRAP_SKIP_STAGES="github-infra,firebase-and-codereview,board-and-summary" \
          "$SCRIPT" my-new-repo \
            --target-dir "$dry_target" \
            --description "d" --visibility private \
            --firebase none --codex-app n --project new --dry-run 2>&1)
dry_ec=$?
set -e
[ "$dry_ec" -eq 0 ] \
  && pass "stage B --dry-run exits 0" \
  || fail "dry-run failed: rc=$dry_ec; out: $dry_out"
# Dry-run target should not have a populated tree — only the state
# file (which the bootstrap wrapper writes regardless of dry-run).
[ ! -e "$dry_target/README.md" ] \
  && pass "dry-run did not actually rsync into target" \
  || fail "dry-run materialized README.md unexpectedly"
echo "$dry_out" | grep -q "DRY-RUN" \
  && pass "dry-run output includes [DRY-RUN] tags" \
  || fail "dry-run output missing [DRY-RUN]: $dry_out"

# --- assertion 10: substitute.sh idempotent ---
# Re-substituting an already-substituted file should be a no-op.
cp "$TARGET/README.md" "$WORKDIR/readme-once.md"
# Source the substitute lib + invoke directly.
. "$ROOT/scripts/bootstrap/_lib.sh"
. "$ROOT/scripts/bootstrap/substitute.sh"
BOOTSTRAP_DRY_RUN=0 BOOTSTRAP_LOG_FILE="" \
  bootstrap::_substitute_one_file \
    "$WORKDIR/readme-once.md" \
    "my-new-repo" \
    "https://github.com/nathanjohnpayne/my-new-repo" \
    "a test repo" >/dev/null 2>&1
diff -q "$TARGET/README.md" "$WORKDIR/readme-once.md" >/dev/null \
  && pass "substitute_one_file is idempotent on already-substituted content" \
  || fail "substitute_one_file is not idempotent"

# --- assertion 11: step ordering — .repo-template.yml cleanup BEFORE
# substitution (CodeRabbit + Codex round 1 on #233). If substitution
# ran first, the `mergepath_playground` key would already have been
# renamed to e.g. `my-new-repo_playground` and yq's
# `del(.spec_test_map.mergepath_playground)` would silently miss.
# Pin the ordering via a source-grep so a future refactor that swaps
# the two calls back fails this test.
# ---------------------------------------------------------------------------
awk '
  /^bootstrap::stage_template_mirror\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /bootstrap::_clean_repo_template_yml/  { saw_clean = NR }
  in_fn && /bootstrap::apply_name_substitutions/  { saw_sub   = NR }
  END {
    if (!saw_clean) { print "missing _clean_repo_template_yml call in stage"; exit 1 }
    if (!saw_sub)   { print "missing apply_name_substitutions call in stage"; exit 1 }
    if (saw_clean > saw_sub) {
      print "ordering wrong: _clean_repo_template_yml must run BEFORE apply_name_substitutions"
      exit 1
    }
  }
' "$ROOT/scripts/bootstrap/template-mirror.sh" \
  && pass "stage runs .repo-template.yml cleanup BEFORE substitution" \
  || fail "stage ordering invariant violated — cleanup must precede substitution"

# --- assertion 12: stage propagates sub-step failures (Codex #233 P1).
# The dispatch in scripts/bootstrap-new-repo.sh invokes stages as
# `"$fn" || stage_rc=$?`, which disables `set -e` inside the stage
# under bash. Without explicit per-step rc capture + early return,
# a failing sub-step would still record the stage as completed and
# `--resume` would skip past it. Cover by simulating a failure in
# the substitution lib: invoke the stage with a non-writable target
# .repo-template.yml that yq can't edit (chmod 0444). The cleanup
# step should propagate the failure; the stage must return non-zero
# and the state file must NOT carry a "template-mirror" entry.
# ---------------------------------------------------------------------------
fail_target="$WORKDIR/fail-target"
rm -rf "$fail_target"
mkdir -p "$fail_target"
# Pre-create a .repo-template.yml at the target with read-only parent
# so the post-rsync yq -i edit fails. Easiest: lock the file itself.
# rsync writes to target after the mode mirror, so we need to lock
# the file AFTER rsync but BEFORE cleanup. Cheaper: lock the whole
# target dir so cleanup's `yq -i` can't open the file for write.
# But that breaks rsync too. So: simulate via a stub stage that calls
# the stage function directly with a pre-populated locked file.
#
# Simpler: shim the underlying yq via PATH override to always exit 1.
shim_dir="$WORKDIR/shim-bin"
mkdir -p "$shim_dir"
cat >"$shim_dir/yq" <<'SHIM_EOF'
#!/usr/bin/env bash
# Test shim — always exits 1 to simulate yq failure on the cleanup step.
echo "yq shim: deliberate failure for test_bootstrap_template_mirror" >&2
exit 1
SHIM_EOF
chmod +x "$shim_dir/yq"

set +e
fail_out=$(PATH="$shim_dir:$PATH" \
           BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
           BOOTSTRAP_SKIP_TOOL_CHECK=1 \
           BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
           BOOTSTRAP_AUTO_CONFIRM=1 \
           BOOTSTRAP_AUTO_PROMPT=skip \
           BOOTSTRAP_AUTHOR_NAME="test" \
           BOOTSTRAP_AUTHOR_EMAIL="t@t" \
      BOOTSTRAP_SKIP_STAGES="github-infra,firebase-and-codereview,board-and-summary" \
           "$SCRIPT" my-new-repo \
             --target-dir "$fail_target" \
             --description "test repo" --visibility private \
             --firebase none --codex-app n --project new 2>&1)
fail_ec=$?
set -e
# yq is also used in the wizard's preflight if .repo-template.yml
# parsing is exercised, but the wizard's own require_yq is skipped
# under BOOTSTRAP_SKIP_TOOL_CHECK. So the only place the shim's yq
# fires is bootstrap::_yq_clean_repo_template inside the stage —
# exactly the regression we're guarding.
[ "$fail_ec" -ne 0 ] \
  && pass "stage propagates yq failure on .repo-template.yml cleanup (rc=$fail_ec)" \
  || fail "stage should have returned non-zero when yq fails; got rc=$fail_ec, out: $fail_out"

# State file must NOT have a "template-mirror" entry — the failed
# stage should not be marked as completed.
if [ -f "$fail_target/.bootstrap-state" ] && grep -q "^template-mirror$" "$fail_target/.bootstrap-state"; then
  fail "failed stage was recorded as completed in state file"
else
  pass "failed stage NOT recorded in state file (resume can retry)"
fi

# --- assertion 13: stage fails closed when yq is unavailable
# (Codex round 3 P1 on #233). Before the fix the stage logged a
# warning and returned 0 + recorded completion — shipping a target
# repo whose .repo-template.yml still carried `mergepath_playground`
# (later renamed to `<new-repo>_playground` by substitution).
#
# Simulate by invoking the cleanup helper directly with yq absent
# from PATH. Use the stage's helper via source rather than going
# through the whole wizard, so the test is fast + isolated.
# ---------------------------------------------------------------------------
#
# CI guard: the hermetic PATH this assertion builds intentionally
# omits yq, then chains `/usr/bin:/bin` to resolve coreutils. On a
# GitHub Actions ubuntu-latest runner, `yq` is preinstalled at
# `/usr/bin/yq` (see repo_lint.yml's install_yq_for_sync_manifest
# comment: "The official ubuntu-latest runner ships yq 4.x
# preinstalled today"), which leaks yq back into the "no-yq" path
# and defeats the assertion: `_clean_repo_template_yml` resolves
# yq, returns 0, and modifies the file. Detect that case and SKIP;
# dev machines (where yq is brew-installed under /opt/homebrew/bin,
# NOT /usr/bin) still exercise this case. (nathanpayne-codex Phase
# 4b r2 on PR #289.)
if [ -x "/usr/bin/yq" ]; then
  echo "SKIP: /usr/bin/yq present (preinstalled on CI runner) — Test 13 (stage fails closed when yq missing) cannot construct a hermetic PATH that excludes yq while still resolving coreutils via /usr/bin"
else
  # Set up a target with a real .repo-template.yml so the missing-file
  # fast-path doesn't fire.
  no_yq_target="$WORKDIR/no-yq-target"
  mkdir -p "$no_yq_target"
  cat >"$no_yq_target/.repo-template.yml" <<'EOF'
spec_test_map:
  mergepath_playground:
    - tests/test_mergepath_playground.sh
extra_top_level_dirs: [mergepath, packaging]
EOF
  # Manufactured PATH with no yq.
  no_yq_path="$WORKDIR/no-yq-path"
  mkdir -p "$no_yq_path"
  for tool in bash sed awk mktemp; do
    src=$(command -v "$tool" || true)
    if [ -n "$src" ]; then ln -sf "$src" "$no_yq_path/$tool"; fi
  done
  set +e
  # Source the libs + invoke the helper directly under the stripped PATH.
  no_yq_out=$(PATH="$no_yq_path:/usr/bin:/bin" bash -c '
    ROOT="'"$ROOT"'"
    TARGET="'"$no_yq_target"'"
    . "$ROOT/scripts/bootstrap/_lib.sh"
    . "$ROOT/scripts/bootstrap/substitute.sh"
    . "$ROOT/scripts/bootstrap/template-mirror.sh"
    # The libs set `set -euo pipefail`; defeat -e here so we can
    # capture the helper rc into a variable and echo it. -u + pipefail
    # are still desirable safety nets but -e would exit the subshell
    # before reaching the echo on a non-zero rc.
    set +e
    BOOTSTRAP_DRY_RUN=0
    BOOTSTRAP_LOG_FILE=""
    bootstrap::_clean_repo_template_yml "$TARGET"
    echo "RC=$?"
  ' 2>&1)
  no_yq_ec=$?
  set -e
  # The helper should return non-zero (rc=2 per the impl) AND emit a
  # diagnostic mentioning yq.
  echo "$no_yq_out" | grep -q "yq is required" \
    && pass "_clean_repo_template_yml errors with 'yq is required' diagnostic when yq missing" \
    || fail "expected 'yq is required' diagnostic; got: $no_yq_out"
  echo "$no_yq_out" | grep -q "RC=2" \
    && pass "_clean_repo_template_yml returns rc=2 when yq missing (fails closed)" \
    || fail "expected RC=2 in subshell; got: $no_yq_out"
  # Verify the .repo-template.yml content is UNCHANGED (the helper
  # returned before yq -i could run; nothing got modified).
  grep -q "mergepath_playground" "$no_yq_target/.repo-template.yml" \
    && pass ".repo-template.yml left untouched when yq missing (no half-write)" \
    || fail ".repo-template.yml was modified despite missing yq"
fi

# --- assertion 14: wizard preflight rejects missing yq (Codex round 3
# P1 — the fail-closed defense is paired with a hard preflight gate
# so the operator gets a clear message at the top instead of mid-stage).
# Manufacture a PATH with all required tools EXCEPT yq, and verify
# the wizard exits non-zero with a clear yq error.
# ---------------------------------------------------------------------------
#
# CI guard: this assertion needs two preconditions to faithfully
# exercise the preflight's "missing yq" branch:
#
#   (a) `op` (1Password CLI) must be on the host — the symlink loop
#       below iterates {bash, gh, op, git, rsync}; on a GH Actions
#       runner `command -v op` returns empty, the symlink is skipped,
#       and the preflight then complains about missing `op` first
#       (the loop order in scripts/bootstrap-new-repo.sh is
#       `gh op git yq rsync` — `op` fires before `yq`).
#   (b) `/usr/bin/yq` must NOT exist — otherwise yq leaks into the
#       hermetic PATH via the `/usr/bin:/bin` chain and the preflight
#       has nothing to complain about (same root cause as Test 13).
#
# Both fail on ubuntu-latest GH runners. SKIP when either is true;
# dev machines (where op is on PATH and yq is at /opt/homebrew/bin/yq
# rather than /usr/bin/yq) still exercise the full case.
if ! command -v op >/dev/null 2>&1; then
  echo "SKIP: 'op' (1Password CLI) not on host PATH — Test 14 (preflight rejects missing yq) cannot construct a hermetic PATH that includes op on CI runners"
elif [ -x "/usr/bin/yq" ]; then
  echo "SKIP: /usr/bin/yq present (preinstalled on CI runner) — Test 14 cannot construct a hermetic PATH that excludes yq while still resolving coreutils via /usr/bin"
else
  preflight_target="$WORKDIR/preflight-noyq-target"
  mkdir -p "$preflight_target"
  preflight_path="$WORKDIR/preflight-noyq-path"
  mkdir -p "$preflight_path"
  for tool in bash gh op git rsync; do
    src=$(command -v "$tool" || true)
    if [ -n "$src" ]; then ln -sf "$src" "$preflight_path/$tool"; fi
  done
  set +e
  pf_out=$(PATH="$preflight_path:/usr/bin:/bin" \
           BOOTSTRAP_MERGEPATH_ROOT="$FAKE_MP" \
           BOOTSTRAP_SKIP_MERGEPATH_GUARD=1 \
           BOOTSTRAP_AUTO_CONFIRM=1 \
           BOOTSTRAP_AUTO_PROMPT=skip \
           "$SCRIPT" my-new-repo \
             --target-dir "$preflight_target" \
             --description d --visibility private \
             --firebase none --codex-app n --project new --dry-run 2>&1)
  pf_ec=$?
  set -e
  [ "$pf_ec" -ne 0 ] \
    && pass "wizard preflight rejects missing yq (rc=$pf_ec)" \
    || fail "wizard should reject missing yq; got rc=$pf_ec, out: $pf_out"
  echo "$pf_out" | grep -q "missing required dependency: yq" \
    && pass "wizard preflight emits 'missing required dependency: yq' diagnostic" \
    || fail "expected 'missing required dependency: yq'; got: $pf_out"
fi

# --- assertion 15: _cross_repo_loop_update propagates failures from
# every side-effect step. Codex round 4 P1 caught that bootstrap::run
# calls inside this helper weren't capturing rc; a mid-flight failure
# (push, gh pr create, etc.) could be masked by the success of the
# subsequent return-to-main checkout, leading the outer stage to
# record completion despite NOT actually opening the loop PR.
# ---------------------------------------------------------------------------
# Source-grep assertion: each bootstrap::run / direct side-effect call
# inside _cross_repo_loop_update must be followed by `|| step_rc=$?`
# OR a `|| pr_create_rc=$?` (the pr-create path uses a different
# variable because it must survive the auth-restore step).
awk '
  /^bootstrap::_cross_repo_loop_update\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  # Count bootstrap::run calls and how many capture rc.
  in_fn && /bootstrap::run / { runs++ }
  in_fn && /\|\| (step_rc|pr_create_rc)=\$\?/ { captures++ }
  END {
    if (runs == 0) { print "no bootstrap::run calls in _cross_repo_loop_update"; exit 1 }
    if (captures < runs) {
      printf "fewer rc captures (%d) than bootstrap::run calls (%d) in _cross_repo_loop_update\n", captures, runs
      exit 1
    }
  }
' "$ROOT/scripts/bootstrap/template-mirror.sh" \
  && pass "_cross_repo_loop_update captures rc from every bootstrap::run call (#233 round 4 P1)" \
  || fail "rc-capture discipline violated in _cross_repo_loop_update"

# --- assertion 16: _cross_repo_loop_update opens the PR through the
# author-token helper and never calls gh auth switch. Codex round 4 P1
# caught the missing author attribution; #412 moved the enforcement
# from keyring switch-around to scripts/gh-as-author.sh.
# ---------------------------------------------------------------------------
awk '
  /^bootstrap::_cross_repo_loop_update\(\)/ { in_fn = 1 }
  in_fn && /^}/ { in_fn = 0 }
  in_fn && /BOOTSTRAP_AUTHOR_IDENTITY|nathanjohnpayne/ { saw_author = 1 }
  in_fn && /bootstrap::run_author_gh / { saw_helper = NR }
  in_fn && /^[[:space:]]*pr create / { saw_pr = NR }
  in_fn && /gh auth switch/ { saw_switch = NR }
  END {
    if (!saw_author)  { print "missing author-identity reference in _cross_repo_loop_update"; exit 1 }
    if (!saw_helper)  { print "missing bootstrap::run_author_gh in _cross_repo_loop_update"; exit 1 }
    if (!saw_pr)      { print "missing pr create arguments under bootstrap::run_author_gh"; exit 1 }
    if (saw_helper > saw_pr) { print "bootstrap::run_author_gh must precede pr create arguments"; exit 1 }
    if (saw_switch)   { print "gh auth switch must not appear in _cross_repo_loop_update"; exit 1 }
  }
' "$ROOT/scripts/bootstrap/template-mirror.sh" \
  && pass "_cross_repo_loop_update routes gh pr create through author-token helper" \
  || fail "author-token helper invariant violated"

# --- summary --------------------------------------------------------------
echo
echo "test_bootstrap_template_mirror: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
