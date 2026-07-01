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
#   6. Local branch with a gone upstream and a verified merged PR whose
#      tip EXACTLY matches the merged PR head. Must be flagged as MERGED
#      local branch and deleted by --apply when it is not checked out in
#      any worktree.
#   7. Local branch whose PR merged but whose local tip DIVERGED from the
#      merged PR head via an extra commit on top (e.g. a routine
#      `git merge main`). Under the #605 name-based detection this is now
#      SURFACED for manual review and KEPT — never auto-deleted, because the
#      extra commit(s) may be unmerged follow-up work (Codex P1) — under a
#      clear "review manually, keeping" record rather than a silent skip.
#   8. #605 same-run re-snapshot: a gone-upstream worktree removed by the
#      worktree-removal pass, whose branch ALSO has a merged PR, must become
#      eligible for `git branch -D` in the SAME --apply invocation (the
#      worktree snapshot is re-taken after removals, so branch_checked_out()
#      no longer reports the just-removed worktree's branch as checked out).
#   9. #605 examined-but-kept visibility: a gone-upstream local branch with
#      NO merged PR is EXAMINED and kept, emitting an explicit "no merged PR"
#      line + a "gone kept (unmerged)" summary counter, so a non-candidate is
#      never a silent omission.
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
# Disable commit/tag signing in the fixture repo so the test is portable — CI
# runners (and a machine whose signing key is not currently unlocked) have no
# signing key, and an inherited global commit.gpgsign=true would otherwise make
# every fixture `git commit` fail with "failed to write commit object".
git config commit.gpgsign false
git config tag.gpgsign false
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

# ── Case 7 (#605): merged PR, but local tip DIVERGED via an extra commit ─
# The PR merged at DIVERGED_MERGED_TIP; a `git merge main`-style housekeeping
# commit then landed on top locally. Under the old exact tip==headRefOid
# check this branch was invisible (silent `continue`). The name-based
# detection now treats it as safe to delete and logs the divergence.
DIVERGED_BRANCH="merged-local-diverged"
git switch -q -c "$DIVERGED_BRANCH"
echo diverged > diverged.txt
git add diverged.txt
git commit -q -m "diverged branch initial"
git push -q -u origin "$DIVERGED_BRANCH"
DIVERGED_MERGED_TIP=$(git rev-parse HEAD)
git push -q origin --delete "$DIVERGED_BRANCH"
git fetch -q --prune
echo followup >> diverged.txt
git commit -am "diverged branch housekeeping commit on top of merged head" -q
git switch -q main

# ── Case 8 (#605): gone-upstream worktree whose branch also has a merged ─
# PR. The worktree-removal pass removes the worktree; in the SAME --apply
# run, the merged-branch sweep must then delete the branch ref. This only
# works if the worktree records are re-snapshotted after removals — with the
# stale top-of-run snapshot, branch_checked_out() would still report the
# branch as checked out and skip the deletion.
SAMERUN_BRANCH="merged-local-samerun"
git branch "$SAMERUN_BRANCH"
git push -q -u origin "$SAMERUN_BRANCH"
SAMERUN_MERGED_TIP=$(git rev-parse "$SAMERUN_BRANCH")
SAMERUN_WT="$WORKDIR/samerun-wt"
git worktree add -q "$SAMERUN_WT" "$SAMERUN_BRANCH"
git push -q origin --delete "$SAMERUN_BRANCH"
git fetch -q --prune

# ── Case 9 (#605): gone-upstream local branch with NO merged PR. Examined ─
# by the sweep and kept (never deleted), but surfaced with an explicit
# "no merged PR" line and a "gone kept (unmerged)" summary counter so a
# non-candidate is not a silent omission.
NOPR_BRANCH="gone-no-merged-pr"
git branch "$NOPR_BRANCH"
git push -q -u origin "$NOPR_BRANCH"
git push -q origin --delete "$NOPR_BRANCH"
git fetch -q --prune

# ── Case 10 (#605 / CodeRabbit Major): REUSED branch name. A branch whose NAME
# matches an old merged PR but whose current tip does NOT descend from that
# merged head (the name was reused for unrelated, unmerged work) must be KEPT,
# not deleted. The stub returns DIVERGED_MERGED_TIP (a real commit that is NOT
# an ancestor of this off-main branch) as the "merged head", so the ancestry
# guard must fail safe to `none`.
git switch -q main
REUSED_BRANCH="reused-name-unrelated"
git switch -q -c "$REUSED_BRANCH"
echo reused-new > reused-new.txt
git add reused-new.txt
git commit -q -m "unrelated NEW work under a reused branch name"
git push -q -u origin "$REUSED_BRANCH"
git push -q origin --delete "$REUSED_BRANCH"
git switch -q main
git fetch -q --prune

# ── Case 11 (Codex P2): gone-upstream branch whose merged-PR LOOKUP FAILS ─
# (the stubbed `gh pr list` exits 1 for it, simulating an auth/API failure).
# Must surface as NOT EVALUATED ("lookup FAILED", counted under "gone
# unverified") — distinct from the verified "no merged PR" bucket — and kept.
UNKNOWN_BRANCH="gone-lookup-fails"
git branch "$UNKNOWN_BRANCH"
git push -q -u origin "$UNKNOWN_BRANCH"
git push -q origin --delete "$UNKNOWN_BRANCH"
git fetch -q --prune

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
  if [ "\$head" = "$DIVERGED_BRANCH" ]; then
    # Merged head is BEFORE the local housekeeping commit → the helper sees
    # the local tip diverge from this merged head.
    echo "$DIVERGED_MERGED_TIP"
    exit 0
  fi
  if [ "\$head" = "$REUSED_BRANCH" ]; then
    # A merged PR exists for this NAME, but its head ($DIVERGED_MERGED_TIP) is
    # NOT an ancestor of the reused branch tip → the ancestry guard must return
    # none and KEEP the branch.
    echo "$DIVERGED_MERGED_TIP"
    exit 0
  fi
  if [ "\$head" = "$SAMERUN_BRANCH" ]; then
    echo "$SAMERUN_MERGED_TIP"
    exit 0
  fi
  if [ "\$head" = "$UNKNOWN_BRANCH" ]; then
    # Simulated auth/API failure → the helper must classify this as
    # unknown (NOT evaluated), never as a verified "no merged PR".
    exit 1
  fi
  # $NOPR_BRANCH (and anything else) → no merged PR: empty stdout, exit 0.
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

# Case 7 (#605): a merged branch whose local tip diverged from the PR head
# via an extra commit is now listed under a MERGED record (not silently
# skipped, and not miscategorized as an unmerged "kept" branch), and the
# divergence is called out with a CLEAR log line. Tie the record to THIS
# branch via awk so the assertion fails if exact-match logic pushes it into
# the "no merged PR" bucket instead.
DIVERGED_LABEL=$(echo "$OUT" | awk -v b="$DIVERGED_BRANCH" '
  /^  \[/            { label = $0 }
  $1 == "branch:" && $2 == b { print label; exit }
')
if echo "$DIVERGED_LABEL" | grep -q "MERGED PR.*review manually, keeping"; then
  pass "diverged merged branch (extra commit on top) is surfaced under a review-manually record"
else
  fail "diverged merged branch not surfaced for review (label='$DIVERGED_LABEL')"
  show_out_on_fail
fi
if echo "$OUT" | grep -q "beyond the merged head"; then
  pass "diverged merged branch surfaced with a CLEAR 'beyond the merged head' reason line"
else
  fail "no 'beyond the merged head' reason line for the diverged branch (silent-skip risk)"
  show_out_on_fail
fi

# Case 9 (#605): a gone-upstream branch with NO merged PR is EXAMINED and
# kept, with an explicit "no merged PR" line — distinguishing "evaluated,
# not a candidate" from "not evaluated".
if echo "$OUT" | grep -q -- "$NOPR_BRANCH" \
   && echo "$OUT" | grep -q "no merged PR"; then
  pass "gone-upstream branch with no merged PR is examined + kept with a clear reason"
else
  fail "gone-upstream unmerged branch not surfaced as examined-but-kept"
  show_out_on_fail
fi
if echo "$OUT" | grep -qE "gone kept \(unmerged\): +[1-9]"; then
  pass "summary shows ≥1 gone-kept-unmerged (examined-not-candidate visibility)"
else
  fail "summary gone-kept-unmerged count missing/zero"
  show_out_on_fail
fi
# The unmerged branch must NOT be counted as a MERGED candidate. print_record
# emits the label and the `branch:` field on SEPARATE lines, so a single-line
# `grep "MERGED local branch.*$NOPR_BRANCH"` can never match (. does not cross
# newlines) and would tautologically pass (CodeRabbit Major). Correlate the
# branch field back to its label line via awk, as elsewhere in this file.
NOPR_LABEL=$(echo "$OUT" | awk -v b="$NOPR_BRANCH" '
  /^  \[/            { label = $0 }
  $1 == "branch:" && $2 == b { print label; exit }
')
if echo "$NOPR_LABEL" | grep -q "MERGED local branch"; then
  fail "unmerged branch wrongly flagged as MERGED candidate (label=$NOPR_LABEL)"
  show_out_on_fail
else
  pass "unmerged branch is NOT flagged as a MERGED deletion candidate"
fi

# Case 11 (Codex P2): the lookup-failure branch is surfaced as NOT EVALUATED
# ("lookup FAILED" + the "gone unverified" counter) — never mislabeled as the
# verified "no merged PR" bucket, never a deletion candidate.
UNKNOWN_LABEL=$(echo "$OUT" | awk -v b="$UNKNOWN_BRANCH" '
  /^  \[/            { label = $0 }
  $1 == "branch:" && $2 == b { print label; exit }
')
if echo "$UNKNOWN_LABEL" | grep -q "lookup FAILED"; then
  pass "lookup-failure branch surfaced as NOT EVALUATED (lookup FAILED label)"
else
  fail "lookup-failure branch mislabeled (label=$UNKNOWN_LABEL)"
  show_out_on_fail
fi
if echo "$OUT" | grep -qE "gone unverified \(lookup failed\): +[1-9]"; then
  pass "summary shows ≥1 gone-unverified (lookup-failure visibility)"
else
  fail "summary gone-unverified count missing/zero"
  show_out_on_fail
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
# The prior --apply ran WITHOUT --force-locked/--orphan-clean, so the locked
# worktree and orphan dir remain actionable — a dry-run reports them and exits
# 2 (dry-run: exit 2 iff anything is actionable, else 0).
if [ "$RC3" -eq 2 ]; then
  pass "post-apply dry-run still flags the retained locked/orphan entries (exit 2)"
else
  fail "post-apply dry-run expected exit 2 (locked+orphan remain), got $RC3"
  echo "$OUT3" >&2
fi

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

# Case 7 (#605 + Codex P1): the diverged branch (extra commit on top of the
# merged head) is NOT auto-deleted by --apply — the extra commit(s) may be
# unmerged follow-up work, so it is surfaced for manual review and KEPT.
if git branch --list "$DIVERGED_BRANCH" | grep -q "$DIVERGED_BRANCH"; then
  pass "diverged merged branch is NOT auto-deleted (surfaced for manual review, kept)"
else
  fail "diverged merged branch was auto-deleted — could lose unmerged follow-up work"
  echo "$OUT3" >&2
fi

# Case 10 (#605 / CodeRabbit Major): the reused-name branch — whose tip does NOT
# descend from the name-matched merged head — must survive --apply. The ancestry
# guard fails safe to `none`, preserving unmerged work.
if git rev-parse --verify -q "refs/heads/$REUSED_BRANCH" >/dev/null; then
  pass "reused-name branch (tip not descended from merged head) is NOT deleted (ancestry guard)"
else
  fail "reused-name branch was deleted despite its tip not descending from the merged head"
fi

# Case 11 (Codex P2): the lookup-failure branch must also survive --apply — an
# unverified branch is never a deletion candidate.
if git rev-parse --verify -q "refs/heads/$UNKNOWN_BRANCH" >/dev/null; then
  pass "lookup-failure branch is NOT deleted (unverified, kept)"
else
  fail "lookup-failure branch was deleted despite the merged-PR lookup failing"
fi

# Case 8 (#605): the same --apply that removed SAMERUN_WT must ALSO delete
# its branch ref in the SAME run (re-snapshot after removals). Assert both
# the worktree is gone AND the branch ref is gone AND the removal+deletion
# were both driven by the single OUT2 invocation.
if echo "$OUT3" | grep -q -- "$SAMERUN_WT"; then
  fail "same-run: gone-upstream worktree $SAMERUN_WT still present after --apply"
  echo "$OUT2" >&2
else
  pass "same-run: gone-upstream worktree removed by --apply"
fi
if git branch --list "$SAMERUN_BRANCH" | grep -q "$SAMERUN_BRANCH"; then
  fail "same-run: branch $SAMERUN_BRANCH NOT deleted in the same --apply (stale snapshot regression)"
  echo "$OUT2" >&2
else
  pass "same-run: branch whose worktree was removed earlier is deleted in the SAME --apply run"
fi
# The single OUT2 run must classify the samerun branch under a deletable
# "[MERGED local branch]" record — NOT under "checked out — keeping". This
# proves the re-snapshot took effect (without it, the stale snapshot labels
# the branch "checked out — keeping" and the record is skipped, as verified
# by the regression proof in the commit body). We associate each print_record
# label with the nearest following `branch:` line via awk so the assertion is
# tied to THIS branch, not to unrelated records elsewhere in the output.
# The samerun branch appears twice in OUT2 — once as the [STALE gone-upstream]
# WORKTREE record in the removal loop, and once in the merged-branch SWEEP.
# We only care about the sweep classification, so restrict the label tracker
# to the merged-branch-sweep labels ([MERGED local branch] / [MERGED local
# branch checked out — keeping]) and read the branch line that follows.
SAMERUN_LABEL=$(echo "$OUT2" | awk -v b="$SAMERUN_BRANCH" '
  /^  \[MERGED local branch/ { label = $0; want = 1; next }
  want && $1 == "branch:" { if ($2 == b) { print label; exit } want = 0 }
')
if echo "$SAMERUN_LABEL" | grep -q "checked out — keeping"; then
  fail "same-run: OUT2 labeled $SAMERUN_BRANCH 'checked out — keeping' (stale snapshot regression)"
  echo "$OUT2" >&2
elif echo "$SAMERUN_LABEL" | grep -q "MERGED local branch"; then
  pass "same-run: OUT2 classified the just-un-worktree'd branch as a deletable MERGED record"
else
  fail "same-run: could not find a MERGED-sweep record for $SAMERUN_BRANCH in OUT2 (label='$SAMERUN_LABEL')"
  echo "$OUT2" >&2
fi

# Case 9 (#605): unmerged gone-upstream branch is retained by --apply.
if git branch --list "$NOPR_BRANCH" | grep -q "$NOPR_BRANCH"; then
  pass "unmerged gone-upstream branch retained after --apply (never deleted)"
else
  fail "unmerged gone-upstream branch was deleted despite having no merged PR"
  echo "$OUT2" >&2
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

# Final dry-run: the diverged merged branch is still present (kept for manual
# review — --apply never touches it), and a review-needed branch counts as
# actionable, so the audit stays exit 2 until a human resolves it (Codex P2:
# a dry-run that reports "review manually" but exits 0 defeats the signal).
set +e
OUT5=$(PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1)
RC5=$?
set -e

if [ "$RC5" -eq 2 ] && echo "$OUT5" | grep -qE "merged\+extra \(review\): +[1-9]"; then
  pass "final dry-run stays exit 2 while the diverged branch awaits manual review"
else
  fail "final dry-run expected exit 2 with merged+extra >=1, got exit $RC5"
  echo "$OUT5" >&2
fi

# Hand-resolve the diverged branch (the human decision the audit is asking
# for), then the audit is genuinely clean.
git branch -D "$DIVERGED_BRANCH" >/dev/null 2>&1 || true
set +e
OUT6=$(PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1)
RC6=$?
set -e
if [ "$RC6" -eq 0 ]; then
  pass "final dry-run audit clean (exit 0) after the diverged branch is hand-resolved"
else
  fail "final dry-run not clean after hand-resolving diverged branch (exit $RC6)"
  echo "$OUT6" >&2
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
if [ "$RC_ESC" -eq 0 ]; then
  pass "symlink escape: --apply --orphan-clean exits 0"
else
  fail "symlink escape: --apply --orphan-clean exited $RC_ESC"
  echo "$OUT_ESC" >&2
fi

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
