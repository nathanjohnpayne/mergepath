#!/usr/bin/env bash
# tests/test_worktree_cleanup.sh
#
# Unit tests for scripts/worktree-cleanup.sh — the stale-worktree audit
# helper added in #288.
#
# Builds a self-contained git repo under a temp dir, creates worktrees
# in each of the states the helper classifies, and runs the helper in
# dry-run mode (the default) to verify each state is reported correctly.
#
# Categories exercised:
#   1. Active worktree on a branch with a healthy (NOT gone) upstream.
#      Must NOT appear in the helper output.
#   2. Worktree on a branch whose upstream is [gone]. Must be flagged
#      as STALE gone-upstream.
#   3. Detached worktree at /tmp/mergepath-pr-99999. PR is closed
#      according to the `gh` stub. Must be flagged as STALE detached.
#   4. Locked worktree. Must be listed AND flagged as locked (so
#      --apply skips it without --force-locked).
#   5. Orphaned .claude/worktrees/<dir> with no entry in
#      `git worktree list`. Must be flagged as ORPHAN.
#   6. Local branch with a gone upstream and a verified merged PR.
#      Must be flagged as MERGED local branch and deleted by --apply
#      when it is not checked out in any worktree.
#   7. Local branch with the same name as a merged PR but new local
#      commits after that merge. Must NOT be treated as safe to delete.
#
# `gh` is stubbed via a PATH shim that returns CLOSED for our test PR
# number and "unknown" for anything else, so the test does not touch
# the live GitHub API and remains hermetic.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/worktree-cleanup.sh"

[[ -x "$HELPER" ]] || { echo "missing or non-executable $HELPER" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/wcleanup-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ── Build fake remote ─────────────────────────────────────────────────
REMOTE="$WORKDIR/remote.git"
git init --bare -q "$REMOTE"

# On macOS, $TMPDIR resolves to /var/folders/... but git canonicalizes
# the path to /private/var/folders/... when it records the worktree.
# Resolve up-front so subsequent grep checks line up with `git worktree
# list` output. (cd + pwd is the portable equivalent of `realpath`.)
WORKDIR=$(cd "$WORKDIR" && pwd -P)

# ── Build main repo with an upstream ──────────────────────────────────
MAIN="$WORKDIR/main"
git init -q -b main "$MAIN"
cd "$MAIN"
git config user.email "test@example.com"
git config user.name "Test"
git remote add origin "$REMOTE"
echo "hello" > README.md
git add README.md
git commit -q -m "initial"
git push -q -u origin main

# ── Case 1: healthy worktree on a branch with live upstream ──────────
git branch healthy
git push -q -u origin healthy
HEALTHY_WT="$WORKDIR/healthy-wt"
git worktree add -q "$HEALTHY_WT" healthy

# ── Case 2: gone-upstream worktree ───────────────────────────────────
# Push a branch, set up a worktree tracking it, then delete the remote
# ref + fetch --prune so `git branch -vv` shows the [gone] marker.
git branch gone-branch
git push -q -u origin gone-branch
GONE_WT="$WORKDIR/gone-wt"
git worktree add -q "$GONE_WT" gone-branch
git push -q origin --delete gone-branch
git fetch -q --prune

# Sanity-check that the [gone] marker is actually present (otherwise
# the test is meaningless).
if ! git branch -vv | grep -q ': gone\]'; then
  fail "fixture setup: expected [gone] marker on gone-branch"
fi

# ── Case 3: detached mergepath-pr-<num> worktree (PR closed) ────────
# We need the worktree path to match the helper's regex
# /tmp|/private/tmp|/Users/.../GitHub|...mergepath-pr-<num>. On macOS,
# mktemp under TMPDIR usually returns /var/folders/..., which the
# helper does NOT match — so we use /tmp explicitly.
PR_NUM=99999
PR_WT="/tmp/wcleanup-test-$$/mergepath-pr-${PR_NUM}"
mkdir -p "$(dirname "$PR_WT")"
# Add a second commit so we have a SHA we can detach onto.
echo "v2" >> README.md
git commit -aq -m "v2"
DETACHED_SHA=$(git rev-parse HEAD)
git reset -q --hard HEAD~1
git worktree add -q --detach "$PR_WT" "$DETACHED_SHA"

# The helper's regex anchors on ^(/private/tmp|/tmp|/Users/[^/]+/GitHub)
# /mergepath-pr-([0-9]+)$ — i.e. mergepath-pr-<num> must be the LAST
# path component AND the parent must match one of the listed roots.
# Symlink /tmp/mergepath-pr-99999 → our nested path so the helper
# classifies it as a detached PR worktree. (Git records the literal
# path we passed to `git worktree add`, but the helper sees that
# literal path; we want it to match the documented prefix, so we
# create the worktree at the matching path directly.)
git worktree remove --force "$PR_WT" >/dev/null 2>&1
rm -rf "$(dirname "$PR_WT")"
PR_WT="/tmp/mergepath-pr-${PR_NUM}"
# Clean up any stale leftover from a previous failed test run.
rm -rf "$PR_WT"
git worktree add -q --detach "$PR_WT" "$DETACHED_SHA"

# ── Case 4: locked worktree (use a gone-upstream branch so it ALSO
#    falls into a removal-eligible bucket; the helper must skip it
#    in --apply without --force-locked).
git branch locked-gone
git push -q -u origin locked-gone
LOCKED_WT="$WORKDIR/locked-wt"
git worktree add -q "$LOCKED_WT" locked-gone
git push -q origin --delete locked-gone
git fetch -q --prune
git worktree lock --reason "pretend agent owns this" "$LOCKED_WT"

# ── Case 5: orphan under .claude/worktrees/ ───────────────────────────
ORPHAN_DIR="$MAIN/.claude/worktrees/agent-zzzz-orphan"
mkdir -p "$ORPHAN_DIR"
echo "leftover" > "$ORPHAN_DIR/marker.txt"

# ── Case 6: verified-merged local branch with no worktree ─────────────
MERGED_BRANCH="merged-local"
git branch "$MERGED_BRANCH"
git push -q -u origin "$MERGED_BRANCH"
MERGED_BRANCH_TIP=$(git rev-parse "$MERGED_BRANCH")
git push -q origin --delete "$MERGED_BRANCH"
git fetch -q --prune

# ── Case 7: same branch name has a merged PR, but local tip advanced ───
UNSAFE_BRANCH="merged-local-new-work"
git switch -q -c "$UNSAFE_BRANCH"
echo unsafe > unsafe.txt
git add unsafe.txt
git commit -q -m "unsafe branch initial"
git push -q -u origin "$UNSAFE_BRANCH"
UNSAFE_MERGED_TIP=$(git rev-parse HEAD)
git push -q origin --delete "$UNSAFE_BRANCH"
git fetch -q --prune
echo followup >> unsafe.txt
git commit -am "unsafe branch followup" -q
git switch -q main

# ── gh stub on PATH ───────────────────────────────────────────────────
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
# Minimal stub: respond only to the helper's call shape
#   gh pr view <num> --repo <r> --json state --jq .state
# Return CLOSED for our known PR number; everything else → empty.
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  num="\$3"
  if [ "\$num" = "$PR_NUM" ]; then
    echo "CLOSED"
    exit 0
  fi
fi
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  head=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --head) head="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "\$head" = "$MERGED_BRANCH" ]; then
    echo "$MERGED_BRANCH_TIP"
    exit 0
  fi
  if [ "\$head" = "$UNSAFE_BRANCH" ]; then
    echo "$UNSAFE_MERGED_TIP"
    exit 0
  fi
  exit 0
fi
exit 1
STUB
chmod +x "$STUB_DIR/gh"

# ── Run the helper (dry-run) and capture output ──────────────────────
set +e
OUT=$(PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1)
RC=$?
set -e

# Always show output on failure for debugging.
show_out_on_fail() {
  echo "----- helper output -----" >&2
  echo "$OUT" >&2
  echo "------------------------" >&2
}

# Exit code: dry-run with findings → 2.
if [ "$RC" -eq 2 ]; then
  pass "dry-run with findings exits 2"
else
  fail "dry-run exit code $RC, expected 2"
  show_out_on_fail
fi

# Case 1: healthy worktree must NOT appear in any classification.
if echo "$OUT" | grep -q -- "$HEALTHY_WT"; then
  fail "healthy worktree appeared in output (should be silent)"
  show_out_on_fail
else
  pass "healthy worktree (healthy upstream) NOT listed"
fi

# Case 2: gone-upstream worktree listed as STALE gone-upstream.
if echo "$OUT" | grep -q "STALE gone-upstream" \
   && echo "$OUT" | grep -q -- "$GONE_WT"; then
  pass "gone-upstream worktree listed as STALE gone-upstream"
else
  fail "gone-upstream worktree not listed correctly"
  show_out_on_fail
fi

# Case 3: detached mergepath-pr-<num> with closed PR listed as STALE detached.
if echo "$OUT" | grep -q "STALE detached PR #${PR_NUM}" \
   && echo "$OUT" | grep -q -- "$PR_WT"; then
  pass "detached closed-PR worktree listed as STALE detached"
else
  fail "detached closed-PR worktree not listed correctly"
  show_out_on_fail
fi

# Case 4: locked worktree listed AND flagged as locked.
if echo "$OUT" | grep -q "LOCKED gone-upstream" \
   && echo "$OUT" | grep -q -- "$LOCKED_WT" \
   && echo "$OUT" | grep -q "pretend agent owns this"; then
  pass "locked worktree listed AND flagged with lock reason"
else
  fail "locked worktree not listed/flagged correctly"
  show_out_on_fail
fi

# Case 5: orphan listed as ORPHAN .claude/worktrees.
if echo "$OUT" | grep -q "ORPHAN .claude/worktrees" \
   && echo "$OUT" | grep -q -- "$ORPHAN_DIR"; then
  pass "orphan .claude/worktrees/ dir listed as ORPHAN"
else
  fail "orphan dir not listed correctly"
  show_out_on_fail
fi

# Case 6: verified-merged local branch listed as MERGED local branch.
if echo "$OUT" | grep -q "MERGED local branch" \
   && echo "$OUT" | grep -q -- "$MERGED_BRANCH"; then
  pass "verified-merged local branch listed"
else
  fail "verified-merged local branch not listed"
  show_out_on_fail
fi

# Case 7: local commits after the merged PR head must not be swept.
if echo "$OUT" | grep -q -- "$UNSAFE_BRANCH"; then
  fail "unsafe advanced local branch appeared as cleanup candidate"
  show_out_on_fail
else
  pass "advanced local branch with old merged PR is not listed"
fi

# Summary counts: at least 1 in each of gone/detached/locked/orphan.
if echo "$OUT" | grep -qE "gone-upstream: +[1-9]"; then
  pass "summary shows ≥1 gone-upstream"
else
  fail "summary gone-upstream count missing/zero"
  show_out_on_fail
fi
if echo "$OUT" | grep -qE "detached stale: +[1-9]"; then
  pass "summary shows ≥1 detached stale"
else
  fail "summary detached count missing/zero"
  show_out_on_fail
fi
if echo "$OUT" | grep -qE "locked: +[1-9]"; then
  pass "summary shows ≥1 locked"
else
  fail "summary locked count missing/zero"
  show_out_on_fail
fi
if echo "$OUT" | grep -qE "merged branches: +[1-9]"; then
  pass "summary shows ≥1 merged branch"
else
  fail "summary merged branch count missing/zero"
  show_out_on_fail
fi
if echo "$OUT" | grep -qE "orphan dirs: +[1-9]"; then
  pass "summary shows ≥1 orphan"
else
  fail "summary orphan count missing/zero"
  show_out_on_fail
fi

# ── Apply mode WITHOUT --force-locked / --orphan-clean: ────────────────
# - gone-upstream non-locked worktree removed
# - detached closed-PR removed
# - locked worktree SKIPPED (still present)
# - orphan SKIPPED (still present)
set +e
OUT2=$(PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply 2>&1)
RC2=$?
set -e

if [ "$RC2" -eq 0 ]; then
  pass "apply without escalation exits 0"
else
  fail "apply exit code $RC2, expected 0"
  echo "$OUT2" >&2
fi

# Re-run dry-run and re-check state.
set +e
OUT3=$(PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1)
RC3=$?
set -e

if echo "$OUT3" | grep -q -- "$GONE_WT"; then
  fail "gone-upstream worktree still present after --apply"
  echo "$OUT3" >&2
else
  pass "gone-upstream worktree removed by --apply"
fi
if echo "$OUT3" | grep -q -- "$PR_WT"; then
  fail "detached closed-PR worktree still present after --apply"
  echo "$OUT3" >&2
else
  pass "detached closed-PR worktree removed by --apply"
fi
if echo "$OUT3" | grep -q -- "$LOCKED_WT"; then
  pass "locked worktree retained after --apply (no --force-locked)"
else
  fail "locked worktree disappeared without --force-locked"
  echo "$OUT3" >&2
fi
if echo "$OUT3" | grep -q -- "$ORPHAN_DIR"; then
  pass "orphan retained after --apply (no --orphan-clean)"
else
  fail "orphan disappeared without --orphan-clean"
  echo "$OUT3" >&2
fi
if git branch --list "$MERGED_BRANCH" | grep -q "$MERGED_BRANCH"; then
  fail "verified-merged local branch still present after --apply"
  echo "$OUT3" >&2
else
  pass "verified-merged local branch deleted by --apply"
fi
if git branch --list "$UNSAFE_BRANCH" | grep -q "$UNSAFE_BRANCH"; then
  pass "advanced local branch retained after --apply"
else
  fail "advanced local branch was deleted despite tip mismatch"
  echo "$OUT3" >&2
fi

# ── Apply with both escalations: locked + orphan removed. ──────────────
set +e
OUT4=$(PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply --force-locked --orphan-clean 2>&1)
RC4=$?
set -e

if [ "$RC4" -eq 0 ]; then
  pass "apply --force-locked --orphan-clean exits 0"
else
  fail "apply with escalations exit code $RC4, expected 0"
  echo "$OUT4" >&2
fi

# Final dry-run should be clean.
set +e
OUT5=$(PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1)
RC5=$?
set -e

if [ "$RC5" -eq 0 ]; then
  pass "final dry-run audit clean (exit 0)"
else
  fail "final dry-run not clean (exit $RC5)"
  echo "$OUT5" >&2
fi

# Clean up the /tmp PR worktree path on success too, since we created it
# outside WORKDIR.
rm -rf "$PR_WT"

# ── Symlink-escape guard (#288 r2): orphan cleanup MUST refuse to ──────
# follow a symlink under .claude/worktrees/ that points outside the
# worktree root. nathanpayne-codex Phase 4b r1 caught that the prior
# implementation resolved with `pwd -P` and then `rm -rf`'d the target,
# which could traverse OUT of .claude/worktrees/ entirely.
#
# Test fixture: a symlink under .claude/worktrees/ pointing at a
# scratch dir OUTSIDE the worktree root. The scratch dir contains a
# canary file that must SURVIVE the cleanup. The helper's --apply
# --orphan-clean must (a) not delete the canary, (b) emit a SKIP
# diagnostic for the symlink.

# Set up the scratch external dir + canary.
EXT_DIR="$WORKDIR/external-canary"
mkdir -p "$EXT_DIR"
CANARY_FILE="$EXT_DIR/do-not-delete.txt"
echo "this file MUST survive symlink-escape attempts" > "$CANARY_FILE"

# Set up the symlink under .claude/worktrees/.
ln -s "$EXT_DIR" "$MAIN/.claude/worktrees/agent-symlink-escape"

# Run --apply --orphan-clean and capture output.
set +e
OUT_ESC=$(PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply --orphan-clean 2>&1)
RC_ESC=$?
set -e

# Canary file MUST still exist.
if [ -f "$CANARY_FILE" ]; then
  pass "symlink escape: external canary file survived --apply --orphan-clean"
else
  fail "SECURITY: symlink escape deleted external canary ($CANARY_FILE)"
  echo "$OUT_ESC" >&2
fi

# The helper must have emitted a SKIP diagnostic on the symlink.
if echo "$OUT_ESC" | grep -qE "SKIP.*symlink"; then
  pass "symlink escape: helper emitted SKIP diagnostic for symlinked orphan"
else
  fail "symlink escape: no SKIP diagnostic in helper output"
  echo "$OUT_ESC" >&2
fi

# The symlink itself should still exist (the helper refuses to touch
# symlinks rather than removing them, since the user may have placed
# them deliberately).
if [ -L "$MAIN/.claude/worktrees/agent-symlink-escape" ]; then
  pass "symlink escape: the symlink entry was not removed (helper is conservative)"
else
  fail "symlink escape: the symlink entry was removed unexpectedly"
fi

# Clean up the test symlink + external dir.
rm -f "$MAIN/.claude/worktrees/agent-symlink-escape"
rm -rf "$EXT_DIR"

echo ""
echo "RESULTS: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
