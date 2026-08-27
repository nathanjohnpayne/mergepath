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
#  12. #739 hidden-folder convention: a detached worktree under
#      .mergepath-worktrees/ with a PR-number-bearing slug pr-<n>-<desc>
#      (docs/agents/worktree-placement.md § Slug naming) is PR-state
#      checked like the legacy mergepath-pr-<n> shape and removed by
#      --apply when the PR is CLOSED/MERGED.
#  13. #739: a detached hidden-folder worktree with a free-form (non
#      pr-<n>) slug carries no parseable PR number — listed as detached
#      non-PR and never auto-removed.
#  14. #762: a BRANCH-ATTACHED hidden-folder pr-<n>-<desc> worktree whose
#      remote branch is still alive (so the gone-upstream rule never
#      fires) but whose PR is MERGED is PR-state checked and removed by
#      --apply. This is the documented `git worktree add <path> <branch>`
#      shape, which the detached-only slug check missed entirely.
#  15. #762: the same shape with a DIRTY working tree (an untracked file)
#      is surfaced for manual review and KEPT — `git worktree remove`
#      would destroy content that exists nowhere else, so a clean status
#      is the required positive evidence for removal.
#  16. #762: a branch-attached pr-<n> worktree whose PR is OPEN is
#      reported as still-active and never removed.
#  17. #762 r2 P2: the same shape whose ONLY content is GITIGNORED
#      (`.env` + `node_modules/`) is likewise kept. Plain `git status
#      --porcelain` reports nothing for it, so the pre-fix cleanliness
#      gate called it clean and `--apply` deleted the secrets — and
#      that happens with AND without `--force`, so git's own dirty
#      check is no backstop. The gate must read
#      `--porcelain --ignored`.
#  18. #762 r2 P3: the same shape whose registered DIRECTORY no longer
#      exists is a PRUNABLE administrative entry, not lost work. It
#      must NOT be reported as "dirty ... commit, stash, or discard it
#      by hand" (there is nothing there to commit), and `--apply`'s
#      trailing `git worktree prune` must clear it.
#  18c. #762 r3 P2: the same shape holding an INITIALIZED SUBMODULE with
#      untracked work inside it, under `diff.ignoreSubmodules=all`. That
#      config (repo- or user-global, and inherited by every worktree)
#      suppresses the ` M <sub>` record, so the probe reported EMPTY and
#      --apply removed the worktree — `git worktree remove --force` is
#      what the helper runs, and --force bypasses git's own "working
#      trees containing submodules cannot be moved or removed" refusal.
#      The gate must pass `--ignore-submodules=none`.
#  19. #762 r2 P3: a LOCKED, clean, closed-PR branch-attached worktree
#      is listed as locked and SKIPPED by a bare `--apply`, then
#      removed by `--apply --force-locked`. (The pre-existing
#      --force-locked fixture is a gone-upstream DETACHED-arm case and
#      never reaches this code.)
#  19b. #762 r3 P2: LOCKED *and* directory-MISSING. `git worktree prune`
#      SKIPS locked entries, so calling this "prunable — --apply's prune
#      clears it" was false: the entry survived every --apply and the
#      audit re-reported the same self-clearing candidate forever while
#      --apply exited 0. It must route to the LOCKED bucket (skipped by
#      a bare --apply, cleared by `--apply --force-locked`).
#  20. #762 r2 P3: a branch-attached pr-<n> worktree whose PR state is
#      UNVERIFIABLE is never removed, and DOES count toward the dry-run
#      exit 2 — the deliberate difference from the SUMMARY_LOOKUP_UNKNOWN
#      carve-out, which only exists because that sweep evaluates every
#      gone-upstream branch.
#
# `gh` is stubbed via a PATH shim that returns CLOSED for our test PR
# number and "unknown" for anything else, so the test does not touch
# the live GitHub API and remains hermetic.
#
# ── Assertion convention (#916) ────────────────────────────────────────
# Almost every assertion here compares against literal report text — record
# labels, reason strings, summary lines, worktree paths, branch names. Those
# use `grep -Fq` (plus `--` wherever the pattern is interpolated and could
# begin with `-`, and `-Fqx` where the whole line is the claim). They are NOT
# regular expressions, and were never meant to be: written as `grep -q` the
# metacharacters inside them were live, so `ORPHAN .claude/worktrees` matched
# a malformed `ORPHAN Xclaude/worktrees` label and the assertion guarding
# against exactly that misclassification passed on it.
#
# The handful of assertions that genuinely need a pattern — the summary
# counters, which have to tolerate variable column padding — use `grep -qE`.
# That spelling is the marker: `-Fq` means "this string, exactly", `-qE`
# means "a pattern, deliberately". Adding a new assertion in either form is
# fine; adding one as bare `grep -q` is what leaves the next reader guessing.

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
# Each identity/signing write names "$MAIN" with `-C` even though the cwd is
# already there. An unscoped `git config` resolves against whichever repository
# the process is standing in, so if the `cd` above ever fails or moves, these
# four lines write the fixture identity into the REAL checkout's .git/config —
# which every worktree of that repo then inherits, silently reattributing and
# unsigning every later commit (#777).
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
# Disable commit/tag signing in the fixture repo so the test is portable — CI
# runners (and a machine whose signing key is not currently unlocked) have no
# signing key, and an inherited global commit.gpgsign=true would otherwise make
# every fixture `git commit` fail with "failed to write commit object".
git -C "$MAIN" config commit.gpgsign false
git -C "$MAIN" config tag.gpgsign false
git remote add origin "$REMOTE"
echo "hello" > README.md
# A committed .gitignore so case 17 can exercise the IGNORED-content class.
# It has to land in the INITIAL commit so every branch/worktree the fixture
# creates below inherits it.
printf '.env\nnode_modules/\n' > .gitignore
git add README.md .gitignore
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
if ! git branch -vv | grep -Fq ': gone]'; then
  fail "fixture setup: expected [gone] marker on gone-branch"
fi

# ── Case 2b (#762 r3 P1): PR-slug worktree, upstream GONE, dirty ─────
# The gone-upstream rule runs FIRST and `continue`s, so before this fix a
# .mergepath-worktrees/pr-N-* checkout whose upstream had been pruned was
# force-removed without ever reaching the content gate — deleting uncommitted
# work that the tool's own documented invariant says it protects.
GONE_PR_NUM=88888
GONE_PR_BRANCH="pr-branch-gone-dirty"
git branch "$GONE_PR_BRANCH"
git push -q -u origin "$GONE_PR_BRANCH"
GONE_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${GONE_PR_NUM}-gone-dirty"
git worktree add -q "$GONE_PR_WT" "$GONE_PR_BRANCH"
GONE_PR_CANARY="$GONE_PR_WT/unsaved.md"
echo "work that exists nowhere else" > "$GONE_PR_CANARY"
git push -q origin --delete "$GONE_PR_BRANCH"
git fetch -q --prune
# Two fixed-string stages rather than one `<branch>.*: gone]` regex (#916):
# the branch name is interpolated, so a metacharacter in it would have been
# live in the pattern, and `.*` was doing nothing a per-line `grep -F` filter
# does not do more precisely — it cannot cross a line either way.
if ! git branch -vv | grep -F -- "$GONE_PR_BRANCH" | grep -Fq ': gone]'; then
  fail "fixture setup: expected [gone] marker on $GONE_PR_BRANCH"
fi

# ── Case 2c (#762 r4 P1): PR-slug worktree hidden by an index flag ───
# `assume-unchanged` makes git skip the file in the status walk, so an edited
# tracked file reports NOTHING even with the comprehensive flags — and plain
# `git worktree remove` deletes it too, because git consults the same flag.
# Verified by hand before writing this: porcelain is empty, `ls-files -v`
# reports `h f.txt`. The index flags themselves are the only signal.
FLAG_PR_NUM=99111
FLAG_PR_BRANCH="pr-branch-index-flag"
git branch "$FLAG_PR_BRANCH"
git push -q -u origin "$FLAG_PR_BRANCH"
FLAG_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${FLAG_PR_NUM}-index-flag"
git worktree add -q "$FLAG_PR_WT" "$FLAG_PR_BRANCH"
FLAG_CANARY="$FLAG_PR_WT/seed.txt"
echo "seed" > "$FLAG_CANARY"
git -C "$FLAG_PR_WT" add seed.txt
git -C "$FLAG_PR_WT" -c user.email=t@t -c user.name=t commit -qm "seed for index-flag fixture"
git -C "$FLAG_PR_WT" update-index --assume-unchanged seed.txt
echo "edited behind an index flag" > "$FLAG_CANARY"
if [ -n "$(git -C "$FLAG_PR_WT" status --porcelain --ignored --untracked-files=all --ignore-submodules=none)" ]; then
  fail "fixture setup: expected comprehensive porcelain to be EMPTY under assume-unchanged"
fi

# ── Case 2d (#762 post-merge P1): index-flag scan must not SIGPIPE ────
# `printf … | grep -q` under pipefail can lose the match when grep exits at the
# first hit and printf then writes to the closed pipe. Listing size alone does
# not force that schedule, so this fixture also injects a printf wrapper into
# helper child shells: it writes the first matching line, then keeps filling
# the pipe until grep exits and the writer receives SIGPIPE. The vulnerable
# pipeline therefore returns 141 without a scheduler-timing assumption, while
# the fixed here-string never calls that wrapper.
SIGPIPE_PR_NUM=77222
SIGPIPE_PR_BRANCH="pr-branch-sigpipe"
git branch "$SIGPIPE_PR_BRANCH"
git push -q -u origin "$SIGPIPE_PR_BRANCH"
SIGPIPE_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${SIGPIPE_PR_NUM}-sigpipe"
git worktree add -q "$SIGPIPE_PR_WT" "$SIGPIPE_PR_BRANCH"
PAD="padding-to-exceed-one-pipe-buffer-so-grep-q-exits-before-printf-finishes-and-pipefail-turns-the-sigpipe-into-a-false-negative"
( cd "$SIGPIPE_PR_WT"
  echo "hidden edit" > "0000-flagged.txt"
  i=0; while [ "$i" -lt 600 ]; do echo x > "zz-${PAD}-${i}.txt"; i=$((i + 1)); done
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm "sigpipe fixture" >/dev/null 2>&1
  git update-index --assume-unchanged "0000-flagged.txt"
  echo "EDITED BEHIND THE FLAG" > "0000-flagged.txt" )
SIGPIPE_CANARY="$SIGPIPE_PR_WT/0000-flagged.txt"
# Assert the premise both ways, or the fixture proves nothing.
if [ -n "$(git -C "$SIGPIPE_PR_WT" status --porcelain --ignored --untracked-files=all --ignore-submodules=none)" ]; then
  fail "fixture setup: expected comprehensive porcelain to be EMPTY under assume-unchanged (sigpipe fixture)"
fi
SIGPIPE_BYTES=$(git -C "$SIGPIPE_PR_WT" ls-files -v | wc -c | tr -d ' ')
if [ "$SIGPIPE_BYTES" -lt 65536 ]; then
  fail "fixture setup: ls-files -v is only ${SIGPIPE_BYTES}B — too small to trigger SIGPIPE; increase the padding"
fi
SIGPIPE_BASH_ENV="$WORKDIR/sigpipe-bash-env"
cat >"$SIGPIPE_BASH_ENV" <<'EOF'
printf() {
  if [ "$#" -eq 2 ] && [ "$1" = '%s\n' ] && [ "${#2}" -ge 65536 ]; then
    first=${2%%$'\n'*}
    rest=${2#*$'\n'}
    builtin printf '%s\n' "$first"
    while :; do
      builtin printf '%s\n' "$rest"
    done
  fi
  builtin printf "$@"
}
EOF
set +e
BASH_ENV="$SIGPIPE_BASH_ENV" bash -o pipefail -c '
  flagged=$(git -C "$1" ls-files -v) || exit 2
  printf "%s\n" "$flagged" | grep -qE "^([a-z]|S) "
' _ "$SIGPIPE_PR_WT"
SIGPIPE_PROBE_RC=$?
set -e
if [ "$SIGPIPE_PROBE_RC" -eq 141 ]; then
  pass "fixture premise: instrumented vulnerable printf|grep -q pipeline returns SIGPIPE (141)"
else
  fail "fixture setup: instrumented vulnerable pipeline returned $SIGPIPE_PROBE_RC, expected 141"
fi
# Non-interactive helper shells source this instrumentation. It is inert for
# every normal printf call and for the fixed here-string index probe.
export BASH_ENV="$SIGPIPE_BASH_ENV"

# ── Case 2e (#762 post-merge P1): index flags INSIDE a submodule ──────
# A submodule file marked assume-unchanged and then edited is invisible to the
# outer status walk AND to the recursive one, so the worktree read as clean and
# --apply deleted it.
SUB_PR_NUM=77333
SUB_PR_BRANCH="pr-branch-submodule-flag"
SUBREPO="$WORKDIR/subrepo"
git init -q "$SUBREPO"
( cd "$SUBREPO"; echo "sub seed" > sub.txt; git add sub.txt
  git -c user.email=t@t -c user.name=t commit -qm "sub init" >/dev/null 2>&1 )
git branch "$SUB_PR_BRANCH"
git push -q -u origin "$SUB_PR_BRANCH"
SUB_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${SUB_PR_NUM}-submodule-flag"
git worktree add -q "$SUB_PR_WT" "$SUB_PR_BRANCH"
SUB_OK=1
( cd "$SUB_PR_WT"
  git -c protocol.file.allow=always submodule add -q "$SUBREPO" vendor/sub >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm "add submodule" >/dev/null 2>&1 ) || SUB_OK=0
SUB_CANARY="$SUB_PR_WT/vendor/sub/sub.txt"
if [ "$SUB_OK" = "1" ] && [ -f "$SUB_CANARY" ]; then
  ( cd "$SUB_PR_WT/vendor/sub"
    git update-index --assume-unchanged sub.txt
    echo "SUBMODULE EDIT HIDDEN BY INDEX FLAG" > sub.txt )
  if [ -n "$(git -C "$SUB_PR_WT" status --porcelain --ignored --untracked-files=all --ignore-submodules=none)" ]; then
    fail "fixture setup: expected outer porcelain to be EMPTY for the submodule index-flag case"
  fi
  # LOCKED on purpose. Plain `git worktree remove` refuses a worktree
  # containing submodules, which would retain this fixture no matter what the
  # probe said — the assertion would pass vacuously. Locking it routes the
  # --force-locked run into the force fallback, which is the exact path the
  # reviewer described, and the only one where the probe's verdict decides.
  if ! git worktree lock "$SUB_PR_WT" >/dev/null 2>&1; then
    fail "fixture setup: could not lock the submodule worktree required for the force-fallback path"
    SUB_OK=0
  elif ! git worktree list --porcelain | awk -v p="$SUB_PR_WT" '
    /^worktree / { hit = (substr($0, 10) == p); next }
    hit && /^locked/ { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    fail "fixture setup: git worktree lock returned success but the submodule worktree does not read back locked"
    SUB_OK=0
  fi
else
  echo "NOTE: submodule fixture unavailable (git submodule add failed); Case 2e assertions will be skipped" >&2
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

# ── Case 12 (#739): detached hidden-folder PR worktree ────────────────
# The worktree-placement convention (~/GitHub/.<repo>-worktrees/<slug>)
# with a PR-number-bearing slug pr-<n>-<desc>. The helper matches the
# hidden folder by its directory NAME (.mergepath-worktrees), not a
# hardcoded ~/GitHub prefix, so the fixture can live under WORKDIR.
HIDDEN_PR_NUM=88888
HIDDEN_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${HIDDEN_PR_NUM}-review-slug"
mkdir -p "$WORKDIR/.mergepath-worktrees"
git worktree add -q --detach "$HIDDEN_PR_WT" "$DETACHED_SHA"

# ── Case 13 (#739): detached hidden-folder worktree, free-form slug ───
# No parseable pr-<n> prefix → no PR number to cross-check; must be
# listed as detached non-PR and never auto-removed.
HIDDEN_NONPR_WT="$WORKDIR/.mergepath-worktrees/charming-freeform-slug"
git worktree add -q --detach "$HIDDEN_NONPR_WT" "$DETACHED_SHA"

# ── Case 14 (#762): BRANCH-ATTACHED hidden-folder PR worktree ─────────
# The documented `git worktree add <path> <branch>` form. Its upstream
# stays ALIVE (we never delete the remote ref), so the gone-upstream rule
# cannot fire and the PR-slug check is the only thing that can catch it.
# The stub reports PR 77777 MERGED, and the working tree is clean, so
# --apply must remove it.
BRANCH_PR_NUM=77777
BRANCH_PR_BRANCH="pr-branch-merged"
git branch "$BRANCH_PR_BRANCH"
git push -q -u origin "$BRANCH_PR_BRANCH"
BRANCH_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${BRANCH_PR_NUM}-branch-attached"
git worktree add -q "$BRANCH_PR_WT" "$BRANCH_PR_BRANCH"

# ── Case 15 (#762): same shape, DIRTY working tree ────────────────────
# An untracked file that exists nowhere else. `git worktree remove
# --force` would delete it, so the helper must retain the worktree and
# surface it for a human instead.
DIRTY_PR_NUM=66666
DIRTY_PR_BRANCH="pr-branch-dirty"
git branch "$DIRTY_PR_BRANCH"
git push -q -u origin "$DIRTY_PR_BRANCH"
DIRTY_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${DIRTY_PR_NUM}-dirty"
git worktree add -q "$DIRTY_PR_WT" "$DIRTY_PR_BRANCH"
DIRTY_CANARY="$DIRTY_PR_WT/precious-untracked.txt"
echo "uncommitted work that MUST survive --apply" > "$DIRTY_CANARY"

# ── Case 16 (#762): branch-attached pr-<n> worktree, PR still OPEN ────
OPEN_PR_NUM=55555
OPEN_PR_BRANCH="pr-branch-open"
git branch "$OPEN_PR_BRANCH"
git push -q -u origin "$OPEN_PR_BRANCH"
OPEN_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${OPEN_PR_NUM}-still-open"
git worktree add -q "$OPEN_PR_WT" "$OPEN_PR_BRANCH"

# ── Case 17 (#762 r2 P2): same shape, GITIGNORED-ONLY content ─────────
# `git status --porcelain` reports NOTHING here — `.env` and node_modules/
# are both matched by the committed .gitignore — so the pre-fix gate saw a
# "clean" worktree and `--apply` deleted the lot. Verified out-of-band that
# `git worktree remove` destroys ignored content with AND without --force,
# so the helper's own check is the only defense.
IGNORED_PR_NUM=44444
IGNORED_PR_BRANCH="pr-branch-ignored"
git branch "$IGNORED_PR_BRANCH"
git push -q -u origin "$IGNORED_PR_BRANCH"
IGNORED_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${IGNORED_PR_NUM}-ignored"
git worktree add -q "$IGNORED_PR_WT" "$IGNORED_PR_BRANCH"
IGNORED_CANARY="$IGNORED_PR_WT/.env"
echo "SECRET=hunter2" > "$IGNORED_CANARY"
mkdir -p "$IGNORED_PR_WT/node_modules/pkg"
echo "module.exports = {}" > "$IGNORED_PR_WT/node_modules/pkg/index.js"
# Sanity-check the premise: plain --porcelain must be silent here, otherwise
# the fixture proves nothing.
if [ -n "$(git -C "$IGNORED_PR_WT" status --porcelain)" ]; then
  fail "fixture setup: expected plain --porcelain to be EMPTY for the ignored-only worktree"
fi

# ── Case 18b (#762 r3 P1): UNTRACKED-only worktree, `status.showUntrackedFiles=no`
# A safety check must not be defeatable by operator configuration. With that
# setting (repo- or user-global), `git status --porcelain` suppresses `??`
# records entirely, so a worktree full of untracked work reports an EMPTY
# status and reads as `clean` — and `--apply` deletes it. `--ignored` does NOT
# restore them; only an explicit `--untracked-files=all` overrides the config.
UNTRACKED_PR_NUM=77777
UNTRACKED_PR_BRANCH="pr-branch-untracked"
git branch "$UNTRACKED_PR_BRANCH"
git push -q -u origin "$UNTRACKED_PR_BRANCH"
UNTRACKED_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${UNTRACKED_PR_NUM}-untracked"
git worktree add -q "$UNTRACKED_PR_WT" "$UNTRACKED_PR_BRANCH"
git -C "$UNTRACKED_PR_WT" config status.showUntrackedFiles no
UNTRACKED_CANARY="$UNTRACKED_PR_WT/draft-notes.md"
echo "hours of uncommitted analysis" > "$UNTRACKED_CANARY"
mkdir -p "$UNTRACKED_PR_WT/scratch"
echo "more unsaved work" > "$UNTRACKED_PR_WT/scratch/wip.txt"
# Sanity-check the premise the same way the ignored fixture does: BOTH the
# plain form and the `--ignored` form must be silent here, or this fixture
# proves nothing about the new flag.
if [ -n "$(git -C "$UNTRACKED_PR_WT" status --porcelain)" ]; then
  fail "fixture setup: expected plain --porcelain to be EMPTY under status.showUntrackedFiles=no"
fi
if [ -n "$(git -C "$UNTRACKED_PR_WT" status --porcelain --ignored)" ]; then
  fail "fixture setup: expected --ignored alone to be EMPTY under status.showUntrackedFiles=no"
fi

# ── Case 18c (#762 r3 P2): SUBMODULE content, `diff.ignoreSubmodules=all`
# Third independent way an operator setting turns the safety probe into a
# lie. With `diff.ignoreSubmodules=all` (repo or user-global — and worktrees
# inherit repo config), git omits the ` M <sub>` record for an initialized
# submodule carrying untracked or uncommitted work, so a worktree with real
# work in it reports an EMPTY status. Only `--ignore-submodules=none`
# overrides it; neither `--ignored` nor `--untracked-files=all` does.
#
# The submodule is added FROM INSIDE the PR worktree so no other fixture in
# this suite ever sees a gitlink. `-c protocol.file.allow=always` is required
# because git refuses `file://` submodule clones by default (CVE-2022-39253).
SUBMOD_PR_NUM=66666
SUBMOD_PR_BRANCH="pr-branch-submodule"
SUBMOD_SRC="$WORKDIR/submodule-src"
git init -q -b main "$SUBMOD_SRC"
git -C "$SUBMOD_SRC" config user.email "test@example.com"
git -C "$SUBMOD_SRC" config user.name "Test"
git -C "$SUBMOD_SRC" config commit.gpgsign false
echo "vendored library" > "$SUBMOD_SRC/lib.txt"
git -C "$SUBMOD_SRC" add -A
git -C "$SUBMOD_SRC" commit -q -m "initial"
git branch "$SUBMOD_PR_BRANCH"
git push -q -u origin "$SUBMOD_PR_BRANCH"
SUBMOD_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${SUBMOD_PR_NUM}-submodule"
git worktree add -q "$SUBMOD_PR_WT" "$SUBMOD_PR_BRANCH"
git -c protocol.file.allow=always -C "$SUBMOD_PR_WT" submodule add -q "$SUBMOD_SRC" vendor/sub
git -C "$SUBMOD_PR_WT" commit -q -m "add submodule"
git -C "$SUBMOD_PR_WT" config diff.ignoreSubmodules all
SUBMOD_CANARY="$SUBMOD_PR_WT/vendor/sub/precious.md"
echo "hours of uncommitted vendor patching" > "$SUBMOD_CANARY"
# Assert the fixture's own premise: with the two flags the helper already
# passed BEFORE this fix, the status is still empty. Without this the case
# could pass while testing nothing.
if [ -n "$(git -C "$SUBMOD_PR_WT" status --porcelain --ignored --untracked-files=all)" ]; then
  fail "fixture setup: expected --ignored --untracked-files=all to be EMPTY under diff.ignoreSubmodules=all"
fi
if [ -z "$(git -C "$SUBMOD_PR_WT" status --porcelain --ignored --untracked-files=all --ignore-submodules=none)" ]; then
  fail "fixture setup: expected --ignore-submodules=none to REPORT the dirty submodule"
fi

# ── Case 18 (#762 r2 P3): same shape, registered dir DELETED ──────────
# `git worktree list --porcelain` still carries the entry (with a `prunable`
# line the record parser ignores), and the branch/HEAD fields make it look
# like an ordinary branch-attached worktree. There is nothing to preserve,
# so it must be reported as prunable — never as dirty-with-work-to-save.
PRUNE_PR_NUM=33333
PRUNE_PR_BRANCH="pr-branch-prunable"
git branch "$PRUNE_PR_BRANCH"
git push -q -u origin "$PRUNE_PR_BRANCH"
PRUNE_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${PRUNE_PR_NUM}-prunable"
git worktree add -q "$PRUNE_PR_WT" "$PRUNE_PR_BRANCH"
rm -rf "$PRUNE_PR_WT"

# ── Case 19 (#762 r2 P3): LOCKED, clean, closed-PR branch worktree ────
# The destructive branch-attached path under --force-locked. The existing
# LOCKED_WT fixture is a gone-upstream case and never reaches this code.
LOCKED_PR_NUM=22222
LOCKED_PR_BRANCH="pr-branch-locked"
git branch "$LOCKED_PR_BRANCH"
git push -q -u origin "$LOCKED_PR_BRANCH"
LOCKED_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${LOCKED_PR_NUM}-locked"
git worktree add -q "$LOCKED_PR_WT" "$LOCKED_PR_BRANCH"
git worktree lock --reason "branch-attached lock" "$LOCKED_PR_WT"

# ── Case 19b (#762 r3 P2): LOCKED *and* directory MISSING ─────────────
# Case 18's "prunable, --apply clears it" claim is only true for UNLOCKED
# entries: `git worktree prune` skips locked ones outright (verified —
# `prune -v` prints nothing and the entry stays registered), and `git
# worktree remove --force` refuses too ("use 'remove -f -f' to override or
# unlock first"). Routing this shape to the prunable bucket therefore
# produced a candidate that reappeared in every audit forever while --apply
# kept exiting 0. It belongs in the LOCKED bucket, behind --force-locked.
LOCKMISS_PR_NUM=44444
LOCKMISS_PR_BRANCH="pr-branch-locked-missing"
git branch "$LOCKMISS_PR_BRANCH"
git push -q -u origin "$LOCKMISS_PR_BRANCH"
LOCKMISS_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${LOCKMISS_PR_NUM}-locked-missing"
git worktree add -q "$LOCKMISS_PR_WT" "$LOCKMISS_PR_BRANCH"
git worktree lock --reason "locked then vanished" "$LOCKMISS_PR_WT"
rm -rf "$LOCKMISS_PR_WT"
# Premise: git still registers the entry, and it is still marked locked.
if ! git worktree list --porcelain | grep -Fq -- "$LOCKMISS_PR_WT"; then
  fail "fixture setup: expected the locked+missing worktree to stay registered"
fi

# ── Case 20 (#762 r2 P3): branch-attached pr-<n>, PR state UNKNOWN ────
# The stub does not know this PR number, so `gh pr view` fails and the
# helper cannot verify the state. Must be kept AND counted toward the
# dry-run exit 2 (see the exit-code rationale in the helper).
UNKNOWN_PR_NUM=11111
UNKNOWN_PR_BRANCH="pr-branch-unknown-state"
git branch "$UNKNOWN_PR_BRANCH"
git push -q -u origin "$UNKNOWN_PR_BRANCH"
UNKNOWN_PR_WT="$WORKDIR/.mergepath-worktrees/pr-${UNKNOWN_PR_NUM}-unknown"
git worktree add -q "$UNKNOWN_PR_WT" "$UNKNOWN_PR_BRANCH"

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

# The orphan root can also legitimately contain a registered worktree. It is
# deliberately adjacent to the orphan fixture so --apply --orphan-clean proves
# that the NUL worktree-record parser never drops an active path from KNOWN_FILE.
REGISTERED_CLAUDE_BRANCH="registered-claude-worktree"
REGISTERED_CLAUDE_WT="$MAIN/.claude/worktrees/agent-registered"
git branch "$REGISTERED_CLAUDE_BRANCH"
git worktree add -q "$REGISTERED_CLAUDE_WT" "$REGISTERED_CLAUDE_BRANCH"

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

# ── Case 21 (#822): merged branch, remote deleted, ref NOT pruned ─────
# The actual bug: a squash-merged branch whose remote was deleted (the
# `gh pr merge --delete-branch` shape) but whose LOCAL refs/remotes/
# origin/<branch> tracking ref was never pruned. `git branch -vv` does not
# mark it `gone` (nothing ran `git fetch --prune` for it — deliberately, no
# such call follows below), so the pre-fix gone_branches() sweep skipped it
# entirely and it was retained silently forever. This fixture MUST be the
# last branch created before the `gh` stub, and no `git fetch --prune`
# may run afterward in this script, or it would launder the very
# condition being tested.
STALE_UNPRUNED_BRANCH="merged-local-stale-unpruned-ref"
git branch "$STALE_UNPRUNED_BRANCH"
git push -q -u origin "$STALE_UNPRUNED_BRANCH"
STALE_UNPRUNED_TIP=$(git rev-parse "$STALE_UNPRUNED_BRANCH")
# Delete the branch directly in the bare "remote" repo, bypassing this
# clone's own `git push --delete`. Since Git 1.8.5, a delete-push
# auto-removes the LOCAL refs/remotes/origin/<branch> tracking ref as a
# push side effect — which would launder the very condition under test.
# Deleting server-side instead (mirroring `gh pr merge --delete-branch` via
# the API, exactly the #822 scenario) leaves this clone's tracking ref
# genuinely stale: it still exists locally, but the bare repo no longer has
# the branch.
git --git-dir="$REMOTE" branch -D "$STALE_UNPRUNED_BRANCH"
# Deliberately NO `git fetch --prune` here — that omission is the bug.
# Sanity-check the fixture's own premise: `git branch -vv` must NOT report
# this branch as gone, or the fixture proves nothing about the unpruned-ref
# case.
if git branch -vv | grep -F -- "$STALE_UNPRUNED_BRANCH" | grep -Fq ': gone]'; then
  fail "fixture setup: expected $STALE_UNPRUNED_BRANCH to NOT be marked gone yet"
fi

# ── Case 22 (#822): a stale-unpruned branch that has a WORKTREE on it ───
# Case 21's branch has no worktree. This one does, and the two must not
# diverge: the branch is still surfaced by the merged-branch sweep with the
# stale-ref reason, and NOTHING about the worktree is acted on, because this
# audit does not prune and so never reclassifies the branch as gone (#932).
# Its only content is gitignored, which makes the "--apply left it alone"
# assertion a data-loss canary rather than a bare directory check. Same
# "no fetch --prune afterward" constraint as case 21 — the branch must stay
# in the deleted-server-side-only shape.
STALE_WT_BRANCH="stale-unpruned-worktree-branch"
git branch "$STALE_WT_BRANCH"
git push -q -u origin "$STALE_WT_BRANCH"
STALE_WT="$WORKDIR/stale-unpruned-wt"
git worktree add -q "$STALE_WT" "$STALE_WT_BRANCH"
STALE_WT_CANARY="$STALE_WT/.env"
echo "SECRET=nowhere-else" > "$STALE_WT_CANARY"
git --git-dir="$REMOTE" branch -D "$STALE_WT_BRANCH"
# Deliberately NO `git fetch --prune` here — that omission is the bug.
if git branch -vv | grep -F -- "$STALE_WT_BRANCH" | grep -Fq ': gone]'; then
  fail "fixture setup: expected $STALE_WT_BRANCH to NOT be marked gone yet"
fi
# Sanity-check the ignored-content premise (mirrors case 17): plain
# --porcelain must be silent, otherwise the fixture proves nothing about
# gitignored content surviving a removal this helper must refuse.
if [ -n "$(git -C "$STALE_WT" status --porcelain)" ]; then
  fail "fixture setup: expected plain --porcelain to be EMPTY for the ignored-only stale-unpruned worktree"
fi
# Pin the premise the case's NEGATIVE assertion rests on (#920 finding 3).
# That assertion says the report carries no record for $STALE_WT; a fixture in
# which the worktree was never registered satisfies it for free, so the case
# would report the absence of a problem it never created. Assert registration
# here, where a failure names the fixture rather than the behaviour.
if ! git worktree list --porcelain | grep -Fqx -- "worktree $STALE_WT"; then
  fail "fixture setup: expected $STALE_WT to be a registered worktree (the case's negative record assertion would be vacuous)"
fi

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
  if [ "\$num" = "$HIDDEN_PR_NUM" ]; then
    echo "MERGED"
    exit 0
  fi
  if [ "\$num" = "$BRANCH_PR_NUM" ]; then
    echo "MERGED"
    exit 0
  fi
  if [ "\$num" = "$DIRTY_PR_NUM" ]; then
    echo "CLOSED"
    exit 0
  fi
  if [ "\$num" = "$OPEN_PR_NUM" ]; then
    echo "OPEN"
    exit 0
  fi
  if [ "\$num" = "$UNTRACKED_PR_NUM" ]; then
    echo "CLOSED"
    exit 0
  fi
  if [ "\$num" = "$FLAG_PR_NUM" ]; then
    echo "CLOSED"
    exit 0
  fi
  if [ "\$num" = "$SIGPIPE_PR_NUM" ]; then
    echo "CLOSED"
    exit 0
  fi
  if [ "\$num" = "$SUB_PR_NUM" ]; then
    echo "CLOSED"
    exit 0
  fi
  if [ "\$num" = "$IGNORED_PR_NUM" ]; then
    echo "MERGED"
    exit 0
  fi
  if [ "\$num" = "$SUBMOD_PR_NUM" ]; then
    echo "CLOSED"
    exit 0
  fi
  if [ "\$num" = "$PRUNE_PR_NUM" ]; then
    echo "MERGED"
    exit 0
  fi
  if [ "\$num" = "$LOCKED_PR_NUM" ]; then
    echo "CLOSED"
    exit 0
  fi
  if [ "\$num" = "$LOCKMISS_PR_NUM" ]; then
    echo "MERGED"
    exit 0
  fi
  # $UNKNOWN_PR_NUM is deliberately absent: the call falls through to the
  # trailing \`exit 1\`, so gh_pr_state yields "unknown" (case 20).
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
  if [ "\$head" = "$STALE_UNPRUNED_BRANCH" ]; then
    echo "$STALE_UNPRUNED_TIP"
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
if echo "$OUT" | grep -Fq -- "$HEALTHY_WT"; then
  fail "healthy worktree appeared in output (should be silent)"
  show_out_on_fail
else
  pass "healthy worktree (healthy upstream) NOT listed"
fi

# Case 2: gone-upstream worktree listed as STALE gone-upstream.
if echo "$OUT" | grep -Fq "STALE gone-upstream" \
   && echo "$OUT" | grep -Fq -- "$GONE_WT"; then
  pass "gone-upstream worktree listed as STALE gone-upstream"
else
  fail "gone-upstream worktree not listed correctly"
  show_out_on_fail
fi

# Case 3: detached mergepath-pr-<num> with closed PR listed as STALE detached.
if echo "$OUT" | grep -Fq "STALE detached PR #${PR_NUM}" \
   && echo "$OUT" | grep -Fq -- "$PR_WT"; then
  pass "detached closed-PR worktree listed as STALE detached"
else
  fail "detached closed-PR worktree not listed correctly"
  show_out_on_fail
fi

# Case 12 (#739): hidden-folder pr-<n>-<desc> worktree is PR-state checked
# and flagged STALE detached (the stub reports the PR MERGED).
if echo "$OUT" | grep -Fq "STALE detached PR #${HIDDEN_PR_NUM}" \
   && echo "$OUT" | grep -Fq -- "$HIDDEN_PR_WT"; then
  pass "hidden-folder pr-<n>-<desc> detached worktree PR-state checked + flagged STALE"
else
  fail "hidden-folder detached PR worktree not recognized by the matcher"
  show_out_on_fail
fi

# Case 13 (#739): free-form hidden-folder slug carries no parseable PR
# number → listed as detached non-PR (correlate path→label via awk, as
# elsewhere in this file).
NONPR_WT_LABEL=$(echo "$OUT" | awk -v p="$HIDDEN_NONPR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$NONPR_WT_LABEL" | grep -Fq "detached non-PR"; then
  pass "free-form hidden-folder slug listed as detached non-PR (no PR number parsed)"
else
  fail "free-form hidden-folder slug mislabeled (label='$NONPR_WT_LABEL')"
  show_out_on_fail
fi

# Case 14 (#762): the branch-ATTACHED pr-<n>-<desc> worktree with a live
# upstream is PR-state checked and flagged stale. Correlate path→label via
# awk so this cannot pass on some unrelated record.
BRANCH_PR_LABEL=$(echo "$OUT" | awk -v p="$BRANCH_PR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$BRANCH_PR_LABEL" | grep -Fq "STALE PR #${BRANCH_PR_NUM} (MERGED) branch worktree"; then
  pass "branch-attached pr-<n> worktree (live upstream, MERGED PR) flagged stale"
else
  fail "branch-attached pr-<n> worktree not PR-state checked (label='$BRANCH_PR_LABEL')"
  show_out_on_fail
fi
if echo "$OUT" | grep -qE "PR-slug branch stale: +[1-9]"; then
  pass "summary shows ≥1 PR-slug branch stale"
else
  fail "summary PR-slug-branch-stale count missing/zero"
  show_out_on_fail
fi

# Case 15 (#762): the DIRTY one is surfaced for review, not as a removal
# candidate.
DIRTY_PR_LABEL=$(echo "$OUT" | awk -v p="$DIRTY_PR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$DIRTY_PR_LABEL" | grep -Fq "working tree is not clean — review manually, keeping"; then
  pass "dirty closed-PR branch worktree surfaced under a review-manually record"
else
  fail "dirty closed-PR branch worktree not surfaced for review (label='$DIRTY_PR_LABEL')"
  show_out_on_fail
fi
if echo "$DIRTY_PR_LABEL" | grep -Fq "STALE PR"; then
  fail "dirty closed-PR branch worktree wrongly flagged as a removal candidate"
  show_out_on_fail
else
  pass "dirty closed-PR branch worktree is NOT a removal candidate"
fi
if echo "$OUT" | grep -qE "unclean PR worktrees \(review\): +[1-9]"; then
  pass "summary shows ≥1 unclean PR worktree awaiting review"
else
  fail "summary unclean-PR-worktree count missing/zero"
  show_out_on_fail
fi
if echo "$OUT" | grep -Fq "uncommitted or untracked content"; then
  pass "dirty worktree carries the uncommitted/untracked remediation line"
else
  fail "dirty worktree missing its uncommitted/untracked remediation line"
  show_out_on_fail
fi

# Case 16 (#762): the OPEN-PR branch worktree is reported still-active.
OPEN_PR_LABEL=$(echo "$OUT" | awk -v p="$OPEN_PR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$OPEN_PR_LABEL" | grep -Fq "OPEN PR #${OPEN_PR_NUM} — keeping"; then
  pass "branch-attached worktree for an OPEN PR reported still-active"
else
  fail "branch-attached OPEN-PR worktree mislabeled (label='$OPEN_PR_LABEL')"
  show_out_on_fail
fi

# Case 17 (#762 r2 P2): the GITIGNORED-ONLY worktree is retained, NOT
# classified as a removal candidate. This is the assertion the pre-fix
# `git status --porcelain` gate fails: it reports nothing for `.env` /
# node_modules/, so the worktree was labeled STALE and removed.
IGNORED_PR_LABEL=$(echo "$OUT" | awk -v p="$IGNORED_PR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$IGNORED_PR_LABEL" | grep -Fq "working tree is not clean — review manually, keeping"; then
  pass "gitignored-only closed-PR branch worktree surfaced under a review-manually record"
else
  fail "gitignored-only worktree not surfaced for review (label='$IGNORED_PR_LABEL')"
  show_out_on_fail
fi
if echo "$IGNORED_PR_LABEL" | grep -Fq "STALE PR"; then
  fail "gitignored-only worktree wrongly flagged as a removal candidate"
  show_out_on_fail
else
  pass "gitignored-only worktree is NOT a removal candidate"
fi
# The remediation must be TRUE for ignored content: you cannot commit or
# stash a gitignored file, so the dirty-path wording would be wrong advice.
if echo "$OUT" | grep -Fq "gitignored content only"; then
  pass "gitignored-only worktree carries an ignored-specific remediation line"
else
  fail "gitignored-only worktree missing its ignored-specific remediation line"
  show_out_on_fail
fi

# Case 18c (#762 r3 P2): the submodule-carrying worktree under
# `diff.ignoreSubmodules=all` is reported NOT CLEAN. Pre-fix the probe saw an
# empty status and this record read `[STALE PR #66666 (CLOSED) branch
# worktree] -> removing`.
SUBMOD_PR_LABEL=$(echo "$OUT" | awk -v p="$SUBMOD_PR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$SUBMOD_PR_LABEL" | grep -Fq "working tree is not clean"; then
  pass "submodule-dirty worktree reported not-clean despite diff.ignoreSubmodules=all"
else
  fail "submodule-dirty worktree mislabeled (label='$SUBMOD_PR_LABEL')"
  show_out_on_fail
fi

# Case 18 (#762 r2 P3): the missing-directory worktree is PRUNABLE, not
# dirty. Assert BOTH the label and the absence of the false remediation.
PRUNE_PR_LABEL=$(echo "$OUT" | awk -v p="$PRUNE_PR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$PRUNE_PR_LABEL" | grep -Fq "worktree directory is MISSING — prunable"; then
  pass "missing-directory branch worktree classified prunable"
else
  fail "missing-directory branch worktree mislabeled (label='$PRUNE_PR_LABEL')"
  show_out_on_fail
fi
if echo "$PRUNE_PR_LABEL" | grep -Fq "not clean"; then
  fail "missing-directory worktree wrongly reported as unclean (nothing exists to commit/stash)"
  show_out_on_fail
else
  pass "missing-directory worktree does NOT claim there is work to preserve"
fi
# Exactly ONE prunable entry — the unlocked Case 18 fixture. Case 19b is
# locked, and prune cannot clear a locked entry, so counting it here would
# advertise a self-clearing candidate that never clears (#762 r3 P2).
if echo "$OUT" | grep -qE "prunable PR worktrees: +1$"; then
  pass "summary counts exactly 1 prunable PR worktree (the UNLOCKED one)"
else
  fail "summary prunable-PR-worktree count wrong: $(echo "$OUT" | grep -E 'prunable PR worktrees:')"
  show_out_on_fail
fi

# Case 19b (#762 r3 P2): the LOCKED + directory-MISSING worktree is reported
# as LOCKED, never as prunable.
LOCKMISS_PR_LABEL=$(echo "$OUT" | awk -v p="$LOCKMISS_PR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$LOCKMISS_PR_LABEL" | grep -Fq "LOCKED PR #${LOCKMISS_PR_NUM} (MERGED) worktree directory is MISSING"; then
  pass "locked+missing branch worktree listed under the LOCKED record"
else
  fail "locked+missing branch worktree mislabeled (label='$LOCKMISS_PR_LABEL')"
  show_out_on_fail
fi
if echo "$LOCKMISS_PR_LABEL" | grep -Fq "prunable"; then
  fail "locked+missing worktree wrongly advertised as prunable (git worktree prune skips locked entries)"
  show_out_on_fail
else
  pass "locked+missing worktree does NOT claim prune will clear it"
fi

# Case 19 (#762 r2 P3): the LOCKED clean closed-PR branch worktree is
# listed as locked (destructive branch-attached path, previously untested).
LOCKED_PR_LABEL=$(echo "$OUT" | awk -v p="$LOCKED_PR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$LOCKED_PR_LABEL" | grep -Fq "LOCKED PR #${LOCKED_PR_NUM} (CLOSED) branch worktree"; then
  pass "locked clean closed-PR branch worktree listed under the LOCKED record"
else
  fail "locked closed-PR branch worktree mislabeled (label='$LOCKED_PR_LABEL')"
  show_out_on_fail
fi

# Case 20 (#762 r2 P3): the PR-state-UNKNOWN branch worktree is surfaced
# and — per the helper's documented rationale — counted toward the
# actionable total, unlike the gone-branch lookup-unknown carve-out.
UNKNOWN_PR_LABEL=$(echo "$OUT" | awk -v p="$UNKNOWN_PR_WT" '
  /^  \[/            { label = $0 }
  $1 == "path:" && $2 == p { print label; exit }
')
if echo "$UNKNOWN_PR_LABEL" | grep -Fq "PR #${UNKNOWN_PR_NUM} state unknown — branch worktree"; then
  pass "PR-state-unknown branch worktree surfaced under its own record"
else
  fail "PR-state-unknown branch worktree mislabeled (label='$UNKNOWN_PR_LABEL')"
  show_out_on_fail
fi
# Pin the counting rule itself: two PR-slug-branch entries (the MERGED
# case-14 worktree and this unknown one) must both land in the bucket that
# feeds the dry-run exit 2. A refactor that moves unknowns out of the
# bucket drops this to 1 and fails here.
if echo "$OUT" | grep -qE "PR-slug branch stale: +2$"; then
  pass "PR-state-unknown branch worktree IS counted in the exit-2 bucket (count is 2)"
else
  fail "PR-slug-branch bucket does not hold both the MERGED and the unknown entry"
  show_out_on_fail
fi

# Case 4: locked worktree listed AND flagged as locked.
if echo "$OUT" | grep -Fq "LOCKED gone-upstream" \
   && echo "$OUT" | grep -Fq -- "$LOCKED_WT" \
   && echo "$OUT" | grep -Fq "pretend agent owns this"; then
  pass "locked worktree listed AND flagged with lock reason"
else
  fail "locked worktree not listed/flagged correctly"
  show_out_on_fail
fi

# Case 5: orphan listed as ORPHAN .claude/worktrees.
if echo "$OUT" | grep -Fq "ORPHAN .claude/worktrees" \
   && echo "$OUT" | grep -Fq -- "$ORPHAN_DIR"; then
  pass "orphan .claude/worktrees/ dir listed as ORPHAN"
else
  fail "orphan dir not listed correctly"
  show_out_on_fail
fi

# Resolve the report record label that a given worktree path was filed under.
report_label_for() {
  echo "$OUT" | awk -v p="$1" '
    /^  \[/            { label = $0 }
    $1 == "path:" && $2 == p { print label; exit }
  '
}

# Positive control for the extractor itself. The registered-worktree assertion
# below is a NEGATIVE one, so an empty capture satisfies it for free: if the
# report format drifts, or this awk stops matching paths, the assertion would
# pass while proving nothing (CodeRabbit 🟡 on #892). Pinning the extractor
# against a path whose label IS known makes that failure mode loud instead.
ORPHAN_CONTROL_LABEL=$(report_label_for "$ORPHAN_DIR")
if echo "$ORPHAN_CONTROL_LABEL" | grep -Fq "ORPHAN .claude/worktrees"; then
  pass "report label extractor resolves a known path to its record label"
else
  fail "report label extractor did not resolve the orphan fixture (negative assertions below would be vacuous)"
  show_out_on_fail
fi

# A healthy registered worktree is reported under a non-ORPHAN label, or — the
# normal case, since the report lists only entries needing attention — is not
# reported at all. Either is correct. What it must never be is swept into the
# orphan bucket merely for living under .claude/worktrees/.
REGISTERED_CLAUDE_LABEL=$(report_label_for "$REGISTERED_CLAUDE_WT")
if ! echo "$REGISTERED_CLAUDE_LABEL" | grep -Fq "ORPHAN .claude/worktrees"; then
  pass "registered .claude/worktrees/ worktree is not misclassified as an orphan"
else
  fail "registered .claude/worktrees/ worktree was misclassified as an orphan"
  show_out_on_fail
fi

# Case 6: verified-merged local branch listed as MERGED local branch.
if echo "$OUT" | grep -Fq "MERGED local branch" \
   && echo "$OUT" | grep -Fq -- "$MERGED_BRANCH"; then
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
# The whole label, fixed-string (#916). The former `MERGED PR.*review
# manually, keeping` regex also matched the wrong record: `.*` spans the
# entire middle of the label, so any future record beginning "MERGED PR" and
# ending "review manually, keeping" satisfied it regardless of the reason text
# in between — which is the only part that distinguishes this class.
if echo "$DIVERGED_LABEL" | grep -Fq -- "[MERGED PR, local tip has unmerged commit(s) on top — review manually, keeping]"; then
  pass "diverged merged branch (extra commit on top) is surfaced under a review-manually record"
else
  fail "diverged merged branch not surfaced for review (label='$DIVERGED_LABEL')"
  show_out_on_fail
fi
if echo "$OUT" | grep -Fq "beyond the merged head"; then
  pass "diverged merged branch surfaced with a CLEAR 'beyond the merged head' reason line"
else
  fail "no 'beyond the merged head' reason line for the diverged branch (silent-skip risk)"
  show_out_on_fail
fi

# Case 9 (#605): a gone-upstream branch with NO merged PR is EXAMINED and
# kept, with an explicit "no merged PR" line — distinguishing "evaluated,
# not a candidate" from "not evaluated".
if echo "$OUT" | grep -Fq -- "$NOPR_BRANCH" \
   && echo "$OUT" | grep -Fq "no merged PR"; then
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
if echo "$NOPR_LABEL" | grep -Fq "MERGED local branch"; then
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
if echo "$UNKNOWN_LABEL" | grep -Fq "lookup FAILED"; then
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

# Case 21 (#822): the merged branch whose remote-tracking ref is stale
# (remote deleted, but no `fetch --prune` has run for it) must be surfaced
# explicitly in dry-run — never silently retained — and its own summary
# counter must be non-zero.
STALE_LABEL=$(echo "$OUT" | awk -v b="$STALE_UNPRUNED_BRANCH" '
  /^  \[/            { label = $0 }
  $1 == "branch:" && $2 == b { print label; exit }
')
if [ -n "$STALE_LABEL" ]; then
  pass "#822 stale-unpruned merged branch is reported in dry-run (never silently retained)"
else
  fail "#822 stale-unpruned merged branch missing from dry-run output entirely (silent retention regression)"
  show_out_on_fail
fi
if echo "$STALE_LABEL" | grep -Fq "MERGED local branch"; then
  pass "#822 stale-unpruned merged branch classified as a MERGED local branch"
else
  fail "#822 stale-unpruned merged branch misclassified (label=$STALE_LABEL)"
  show_out_on_fail
fi
if echo "$OUT" | grep -Fq -- "$STALE_UNPRUNED_BRANCH" \
   && echo "$OUT" | grep -Fq "remote-tracking ref is stale"; then
  pass "#822 dry-run explains the stale-remote-tracking-ref reason"
else
  fail "#822 no stale-remote-tracking-ref reason line found"
  show_out_on_fail
fi
if echo "$OUT" | grep -qE "gone \(stale remote ref, unpruned\): +[1-9]"; then
  pass "#822 summary shows ≥1 stale-unpruned gone branch"
else
  fail "#822 summary stale-unpruned count missing/zero"
  show_out_on_fail
fi
# The counter must report the exact number of stale-unpruned branches, not
# merely a non-zero one. Two fixture branches are in that state: the bare
# local branch (case 21) and the worktree-attached one (case 22). An
# inequality assertion would pass on an over-count, and over-counting is the
# specific way this counter has gone wrong before — it is fed from an array
# that a second append site would silently inflate.
STALE_UNPRUNED_N=$(echo "$OUT" | sed -n 's/.*gone (stale remote ref, unpruned): *\([0-9][0-9]*\).*/\1/p' | head -1)
if [ "${STALE_UNPRUNED_N:-0}" -eq 2 ]; then
  pass "#822 stale-unpruned counter reports exactly the 2 stale-unpruned branches"
else
  fail "#822 stale-unpruned counter is ${STALE_UNPRUNED_N:-unset}, expected 2"
  show_out_on_fail
fi
# Read-only contract: dry-run must perform NO ref mutation. The remote-
# tracking ref for this branch must still be present after the dry-run
# above (an actual `git fetch --prune` would have removed it).
if git rev-parse --verify -q "refs/remotes/origin/$STALE_UNPRUNED_BRANCH" >/dev/null; then
  pass "#822 dry-run performed no ref mutation (stale remote-tracking ref still present)"
else
  fail "#822 dry-run mutated refs: stale remote-tracking ref for $STALE_UNPRUNED_BRANCH is gone"
fi

# Case 22 (#822): a stale-unpruned branch that HAS a worktree is surfaced by
# the same merged-branch sweep, carrying the same stale-ref reason. Pair the
# label with its record so this cannot be satisfied by some other fixture's
# line: print_record emits the label, then "    branch:   <name>".
STALE_WT_LABEL=$(echo "$OUT" | awk -v b="$STALE_WT_BRANCH" '
  /^  \[/            { label = $0 }
  $1 == "branch:" && $2 == b { print label; exit }
')
if [ -n "$STALE_WT_LABEL" ]; then
  pass "#822 stale-unpruned branch with a worktree is reported in dry-run"
else
  fail "#822 stale-unpruned branch with a worktree missing from dry-run output entirely"
  show_out_on_fail
fi
# The reason line follows its own record, so require the two adjacent rather
# than merely both present somewhere in the output.
if echo "$OUT" | awk -v b="$STALE_WT_BRANCH" '
  $1 == "branch:" && $2 == b { seen = 1; next }
  seen && /remote-tracking ref is stale/ { found = 1 }
  seen && /^  \[/ { seen = 0 }
  END { exit(found ? 0 : 1) }
'; then
  pass "#822 dry-run explains the stale-remote-tracking-ref reason for that branch"
else
  fail "#822 no stale-remote-tracking-ref reason line attached to $STALE_WT_BRANCH"
  show_out_on_fail
fi
# The worktree itself is NOT reclassified: nothing pruned, so the branch is
# not `gone` and the worktree keeps whatever disposition it had. Asserting the
# absence of a gone-upstream record for it is what pins the reduced scope —
# it fails the moment a prune (or a stale-unpruned union) reaches this
# classification, which is #932's change to make deliberately.
# Resolved through report_label_for(), not a substring grep (#920 finding 3).
# Two things are wrong with `! grep -Fq -- "$STALE_WT"` over the whole report.
# It is a SUBSTRING test, so it answers about any path merely PREFIXED by
# $STALE_WT rather than about this worktree — the collision the case's own
# label assertions are already written around. And it is a NEGATIVE test with
# no control, so report-format drift would satisfy it for free. The extractor
# compares the `path:` field for equality, and it was positively controlled
# against $ORPHAN_DIR on this same $OUT above, so an empty capture here means
# "no record for this worktree" rather than "the extractor stopped working".
STALE_WT_RECORD_LABEL=$(report_label_for "$STALE_WT")
if [ -z "$STALE_WT_RECORD_LABEL" ]; then
  pass "#822 dry-run does not advertise the worktree as gone-upstream (no prune ran)"
else
  fail "#822 dry-run classified a worktree on an unpruned branch that --apply will not touch"
  show_out_on_fail
fi
# Read-only contract: dry-run must perform NO ref mutation for this branch
# either, and the gitignored canary must still exist untouched.
if git rev-parse --verify -q "refs/remotes/origin/$STALE_WT_BRANCH" >/dev/null; then
  pass "#892 dry-run performed no ref mutation for the worktree's branch"
else
  fail "#892 dry-run mutated refs: stale remote-tracking ref for $STALE_WT_BRANCH is gone"
fi
if [ -f "$STALE_WT_CANARY" ]; then
  pass "#892 dry-run left the gitignored canary untouched"
else
  fail "#892 dry-run destroyed the gitignored canary (should never mutate anything)"
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

if echo "$OUT3" | grep -Fq -- "$GONE_WT"; then
  fail "gone-upstream worktree still present after --apply"
  echo "$OUT3" >&2
else
  pass "gone-upstream worktree removed by --apply"
fi

# Case 21 (#822): --apply does NOT prune, so it does not reclassify this
# branch and does not delete it. That is the deliberate scope of this change:
# #822's detection half lands read-only, and teaching --apply to prune (with a
# primitive that cannot inherit operator refspec configuration) is #932.
#
# This is a live boundary assertion, not a placeholder. --apply runs against a
# repo where refs/remotes/origin/<branch> is stale and a MERGED PR exists for
# the head name with an exactly-matching tip: every gate downstream of `gone`
# would pass. Only the absence of a prune keeps the branch. Reintroducing one
# fails here first, which is the intent — a prune must arrive with #932's
# tests, not as a side effect.
if git rev-parse --verify -q "refs/heads/$STALE_UNPRUNED_BRANCH" >/dev/null 2>&1; then
  pass "#822 --apply leaves the stale-unpruned merged branch alone (no prune; tracked in #932)"
else
  fail "#822 --apply deleted a branch whose remote-tracking ref was never pruned"
  echo "$OUT2" >&2
fi
# The read-only contract now holds in BOTH modes: --apply must not have
# mutated the stale remote-tracking ref either.
if git rev-parse --verify -q "refs/remotes/origin/$STALE_UNPRUNED_BRANCH" >/dev/null; then
  pass "#822 --apply performed no remote-tracking-ref mutation (nothing prunes)"
else
  fail "#822 --apply pruned refs/remotes/origin/$STALE_UNPRUNED_BRANCH"
  echo "$OUT2" >&2
fi

# Case 22 (#822): the worktree on a stale-unpruned branch is untouched by
# --apply, and its gitignored canary — content that exists nowhere else —
# survives. The canary is what makes this a data-loss guard rather than a
# restatement of the assertion above.
if [ -d "$STALE_WT" ] && [ -f "$STALE_WT_CANARY" ] \
   && grep -Fq "SECRET=nowhere-else" "$STALE_WT_CANARY"; then
  pass "#822 --apply left the stale-unpruned worktree and its gitignored canary intact"
else
  fail "DATA LOSS: --apply deleted the gitignored canary in the stale-unpruned worktree $STALE_WT"
  echo "$OUT3" >&2
fi
if echo "$OUT3" | grep -Fq -- "$PR_WT"; then
  fail "detached closed-PR worktree still present after --apply"
  echo "$OUT3" >&2
else
  pass "detached closed-PR worktree removed by --apply"
fi
# Case 12 (#739): the hidden-folder merged-PR worktree is removed by the
# same --apply pass as the legacy shape.
if [ -d "$HIDDEN_PR_WT" ] || echo "$OUT3" | grep -Fq -- "$HIDDEN_PR_WT"; then
  fail "hidden-folder detached merged-PR worktree still present after --apply"
  echo "$OUT3" >&2
else
  pass "hidden-folder detached merged-PR worktree removed by --apply"
fi
# Case 13 (#739): the free-form-slug detached worktree is never
# auto-removed (no PR number to verify against).
if [ -d "$HIDDEN_NONPR_WT" ]; then
  pass "free-form hidden-folder detached worktree retained by --apply (never auto-removed)"
else
  fail "free-form hidden-folder detached worktree was removed by --apply"
  echo "$OUT2" >&2
fi
# Case 14 (#762): the clean branch-attached merged-PR worktree is removed —
# and the BRANCH REF it was attached to survives (worktree removal never
# deletes a ref, which is exactly why a clean working tree is sufficient
# evidence that nothing is lost).
if [ -d "$BRANCH_PR_WT" ] || echo "$OUT3" | grep -Fq -- "$BRANCH_PR_WT"; then
  fail "branch-attached merged-PR worktree still present after --apply"
  echo "$OUT2" >&2
else
  pass "branch-attached merged-PR worktree removed by --apply"
fi
if git rev-parse --verify -q "refs/heads/$BRANCH_PR_BRANCH" >/dev/null; then
  pass "branch ref survived the branch-attached worktree removal"
else
  fail "branch ref $BRANCH_PR_BRANCH was destroyed by the worktree removal"
  echo "$OUT2" >&2
fi

# Case 15 (#762): the DIRTY worktree and its untracked canary both survive.
if [ -d "$DIRTY_PR_WT" ]; then
  pass "dirty closed-PR branch worktree retained by --apply"
else
  fail "dirty closed-PR branch worktree was removed by --apply"
  echo "$OUT2" >&2
fi
if [ -f "$DIRTY_CANARY" ]; then
  pass "untracked canary in the dirty worktree survived --apply"
else
  fail "DATA LOSS: --apply deleted uncommitted work in $DIRTY_PR_WT"
  echo "$OUT2" >&2
fi

# Case 16 (#762): the OPEN-PR branch worktree survives.
if [ -d "$OPEN_PR_WT" ]; then
  pass "branch-attached OPEN-PR worktree retained by --apply"
else
  fail "branch-attached OPEN-PR worktree was removed by --apply"
  echo "$OUT2" >&2
fi

# Case 17 (#762 r2 P2): the GITIGNORED-ONLY worktree and its secrets both
# survive --apply. This is the data-loss regression: pre-fix, `--apply`
# deleted $IGNORED_PR_WT outright and $IGNORED_CANARY with it.
if [ -d "$IGNORED_PR_WT" ]; then
  pass "gitignored-only closed-PR branch worktree retained by --apply"
else
  fail "gitignored-only closed-PR branch worktree was removed by --apply"
  echo "$OUT2" >&2
fi
if [ -f "$IGNORED_CANARY" ] && grep -Fq "hunter2" "$IGNORED_CANARY"; then
  pass "gitignored .env canary survived --apply"
else
  fail "DATA LOSS: --apply deleted gitignored content in $IGNORED_PR_WT"
  echo "$OUT2" >&2
fi
if [ -f "$IGNORED_PR_WT/node_modules/pkg/index.js" ]; then
  pass "gitignored node_modules/ survived --apply"
else
  fail "DATA LOSS: --apply deleted node_modules/ in $IGNORED_PR_WT"
  echo "$OUT2" >&2
fi

# Case 18b (#762 r3 P1): the UNTRACKED-only worktree under
# `status.showUntrackedFiles=no` survives --apply. Pre-fix the status probe
# returned empty for it, the helper reported `clean`, and --apply removed the
# directory with every untracked file in it — a safety check silently disabled
# by a config setting the operator may not even know is inherited.
if [ -d "$UNTRACKED_PR_WT" ]; then
  pass "untracked-only worktree retained by --apply under status.showUntrackedFiles=no"
else
  fail "untracked-only worktree was removed by --apply despite untracked content"
  echo "$OUT2" >&2
fi
if [ -f "$UNTRACKED_CANARY" ] && grep -Fq "uncommitted analysis" "$UNTRACKED_CANARY"; then
  pass "untracked canary survived --apply under status.showUntrackedFiles=no"
else
  fail "DATA LOSS: --apply deleted untracked content in $UNTRACKED_PR_WT"
  echo "$OUT2" >&2
fi
if [ -f "$UNTRACKED_PR_WT/scratch/wip.txt" ]; then
  pass "untracked scratch/ directory survived --apply"
else
  fail "DATA LOSS: --apply deleted untracked scratch/ in $UNTRACKED_PR_WT"
  echo "$OUT2" >&2
fi

# Case 2b (#762 r3 P1): the gone-upstream fast path must not bypass the
# content gate for a PR-slug worktree.
if [ -d "$GONE_PR_WT" ]; then
  pass "gone-upstream PR-slug worktree with dirty content retained by --apply"
else
  fail "gone-upstream PR-slug worktree was removed by --apply despite dirty content"
  echo "$OUT2" >&2
fi
if [ -f "$SIGPIPE_CANARY" ] && grep -Fq "EDITED BEHIND THE FLAG" "$SIGPIPE_CANARY"; then
  pass "index-flag edit survived --apply in a worktree whose ls-files -v exceeds a pipe buffer (${SIGPIPE_BYTES}B)"
else
  fail "DATA LOSS: --apply deleted an index-flag-hidden edit that the SIGPIPE-prone scan missed"
  echo "$OUT2" >&2
fi
if [ -f "$FLAG_CANARY" ] && grep -Fq "behind an index flag" "$FLAG_CANARY"; then
  pass "index-flag-hidden edit survived --apply (assume-unchanged)"
else
  fail "DATA LOSS: --apply deleted an edit hidden by assume-unchanged in $FLAG_PR_WT"
  echo "$OUT2" >&2
fi
# The retained gone-upstream worktree must also be COUNTED. It previously
# appended to an undeclared SUMMARY_DIRTY_KEPT while the summary and
# total_candidates accounting read SUMMARY_UNCLEAN_KEPT, so the record was
# printed but the audit exited as if nothing needed a human (Phase 4b P1).
UNCLEAN_N=$(echo "$OUT3" | sed -n 's/.*unclean PR worktrees (review): *\([0-9][0-9]*\).*/\1/p' | head -1)
EXPECTED_UNCLEAN=$((7 + SUB_OK))
if [ "${UNCLEAN_N:-0}" -eq "$EXPECTED_UNCLEAN" ]; then
  pass "retained gone-upstream worktrees are counted in the unclean bucket"
else
  fail "unclean-bucket count is ${UNCLEAN_N:-unset}, expected $EXPECTED_UNCLEAN (seven required retained-unclean fixtures plus the optional submodule index-flag fixture when available) — a retained worktree is landing in an uncounted bucket"
  echo "$OUT3" | grep -E "unclean PR worktrees" >&2
fi
if [ -f "$GONE_PR_CANARY" ] && grep -Fq "nowhere else" "$GONE_PR_CANARY"; then
  pass "gone-upstream PR-slug canary survived --apply"
else
  fail "DATA LOSS: --apply deleted uncommitted work in $GONE_PR_WT via the gone-upstream fast path"
  echo "$OUT2" >&2
fi

# Case 18c (#762 r3 P2): the SUBMODULE-carrying worktree survives --apply
# under `diff.ignoreSubmodules=all`. Pre-fix the status probe returned empty,
# the helper reported `clean`, and try_remove()'s `git worktree remove
# --force` deleted the worktree together with the submodule's untracked work.
# The --force is load-bearing in that failure: without it git refuses outright
# ("working trees containing submodules cannot be moved or removed"), so git's
# own guard is no backstop for the form this helper actually runs.
if [ -d "$SUBMOD_PR_WT" ]; then
  pass "submodule-carrying worktree retained by --apply under diff.ignoreSubmodules=all"
else
  fail "submodule-carrying worktree was removed by --apply despite dirty submodule content"
  echo "$OUT2" >&2
fi
if [ -f "$SUBMOD_CANARY" ] && grep -Fq "uncommitted vendor patching" "$SUBMOD_CANARY"; then
  pass "submodule canary survived --apply under diff.ignoreSubmodules=all"
else
  fail "DATA LOSS: --apply deleted untracked submodule content in $SUBMOD_PR_WT"
  echo "$OUT2" >&2
fi

# Case 18 (#762 r2 P3): --apply's trailing `git worktree prune` clears the
# stale administrative entry, so the missing-directory worktree is gone from
# the follow-up dry-run. This is what makes the prunable bucket self-clearing
# (unlike the unclean bucket, which waits on a human).
if echo "$OUT3" | grep -Fq -- "$PRUNE_PR_WT"; then
  fail "prunable branch worktree entry still registered after --apply"
  echo "$OUT3" >&2
else
  pass "prunable branch worktree entry cleared by --apply's git worktree prune"
fi

# Case 19 (#762 r2 P3): a bare --apply must SKIP the locked branch worktree.
if [ -d "$LOCKED_PR_WT" ]; then
  pass "locked closed-PR branch worktree retained by bare --apply"
else
  fail "locked closed-PR branch worktree removed without --force-locked"
  echo "$OUT2" >&2
fi

# Case 19b (#762 r3 P2): a bare --apply SKIPS the locked+missing entry and
# says so. Pre-fix it claimed the trailing prune would clear the entry — which
# prune silently declines to do for a locked worktree, so the very next audit
# reported the identical "self-clearing" candidate again.
#
# Scope the grep to THIS record's own block: two other locked fixtures emit
# the same "skipped (locked...)" line, so an unscoped `grep -q` over all of
# OUT2 would pass against the pre-fix code and assert nothing. Accumulate
# lines from the record label that precedes `path: $LOCKMISS_PR_WT` up to the
# next record label.
LOCKMISS_APPLY_BLOCK=$(echo "$OUT2" | awk -v p="$LOCKMISS_PR_WT" '
  /^  \[/ { if (want) exit; buf = $0; next }
           { buf = buf "\n" $0 }
  $1 == "path:" && $2 == p { want = 1 }
  END      { if (want) print buf }
')
if echo "$LOCKMISS_APPLY_BLOCK" | grep -Fq "skipped (locked; pass --force-locked to remove)"; then
  pass "locked+missing entry reported as skipped-locked by bare --apply"
else
  fail "locked+missing entry not reported as skipped-locked by bare --apply (block='$LOCKMISS_APPLY_BLOCK')"
  echo "$OUT2" >&2
fi
# Premise pin, not a regression assertion: this holds before AND after the
# fix, and it is the git behavior the whole fix rests on. `git worktree prune`
# — which --apply just ran unconditionally — leaves a LOCKED entry registered,
# so the pre-fix "prune clears it" remediation was simply false. If a future
# git ever makes prune drop locked entries, this fails and the routing above
# should be revisited.
if git worktree list --porcelain | grep -Fq -- "$LOCKMISS_PR_WT"; then
  pass "premise: --apply's git worktree prune does NOT clear a LOCKED entry"
else
  fail "premise broken: git worktree prune cleared a locked entry — revisit the locked+missing routing"
  echo "$OUT2" >&2
fi

# #892: REC_FILE is NUL-delimited. The orphan scan must consume its complete
# six-field records rather than parsing it as pipe text, or --orphan-clean can
# delete this still-registered worktree.
if [ -d "$REGISTERED_CLAUDE_WT" ] \
   && git worktree list --porcelain | grep -Fq -- "$REGISTERED_CLAUDE_WT"; then
  pass "--orphan-clean preserves a registered .claude/worktrees/ worktree"
else
  fail "DATA LOSS: --orphan-clean removed a registered .claude/worktrees/ worktree"
  echo "$OUT4" >&2
fi

# Case 20 (#762 r2 P3): the PR-state-unknown branch worktree is never removed.
if [ -d "$UNKNOWN_PR_WT" ]; then
  pass "PR-state-unknown branch worktree retained by --apply"
else
  fail "PR-state-unknown branch worktree was removed despite an unverifiable PR state"
  echo "$OUT2" >&2
fi

if echo "$OUT3" | grep -Fq -- "$LOCKED_WT"; then
  pass "locked worktree retained after --apply (no --force-locked)"
else
  fail "locked worktree disappeared without --force-locked"
  echo "$OUT3" >&2
fi
if echo "$OUT3" | grep -Fq -- "$ORPHAN_DIR"; then
  pass "orphan retained after --apply (no --orphan-clean)"
else
  fail "orphan disappeared without --orphan-clean"
  echo "$OUT3" >&2
fi
if git branch --list "$MERGED_BRANCH" | grep -Fq -- "$MERGED_BRANCH"; then
  fail "verified-merged local branch still present after --apply"
  echo "$OUT3" >&2
else
  pass "verified-merged local branch deleted by --apply"
fi

# Case 7 (#605 + Codex P1): the diverged branch (extra commit on top of the
# merged head) is NOT auto-deleted by --apply — the extra commit(s) may be
# unmerged follow-up work, so it is surfaced for manual review and KEPT.
if git branch --list "$DIVERGED_BRANCH" | grep -Fq -- "$DIVERGED_BRANCH"; then
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
if echo "$OUT3" | grep -Fq -- "$SAMERUN_WT"; then
  fail "same-run: gone-upstream worktree $SAMERUN_WT still present after --apply"
  echo "$OUT2" >&2
else
  pass "same-run: gone-upstream worktree removed by --apply"
fi
if git branch --list "$SAMERUN_BRANCH" | grep -Fq -- "$SAMERUN_BRANCH"; then
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
if echo "$SAMERUN_LABEL" | grep -Fq "checked out — keeping"; then
  fail "same-run: OUT2 labeled $SAMERUN_BRANCH 'checked out — keeping' (stale snapshot regression)"
  echo "$OUT2" >&2
elif echo "$SAMERUN_LABEL" | grep -Fq "MERGED local branch"; then
  pass "same-run: OUT2 classified the just-un-worktree'd branch as a deletable MERGED record"
else
  fail "same-run: could not find a MERGED-sweep record for $SAMERUN_BRANCH in OUT2 (label='$SAMERUN_LABEL')"
  echo "$OUT2" >&2
fi

# Case 9 (#605): unmerged gone-upstream branch is retained by --apply.
if git branch --list "$NOPR_BRANCH" | grep -Fq -- "$NOPR_BRANCH"; then
  pass "unmerged gone-upstream branch retained after --apply (never deleted)"
else
  fail "unmerged gone-upstream branch was deleted despite having no merged PR"
  echo "$OUT2" >&2
fi

# ── Apply with both escalations: locked + orphan removed. ──────────────
set +e
OUT4=$(PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply --force-locked --orphan-clean 2>&1)
RC4=$?

# Case 2e (#762 post-merge P1): a LOCKED submodule worktree whose only dirt is
# hidden behind a submodule-internal index flag must survive even the force
# fallback. This is the one path where the probe's verdict is decisive: without
# --force-locked, git's own refusal to remove a submodule worktree retains it
# regardless, so the assertion would prove nothing.
if [ "${SUB_OK:-0}" = "1" ]; then
  if [ -f "$SUB_CANARY" ] && grep -Fq "SUBMODULE EDIT HIDDEN BY INDEX FLAG" "$SUB_CANARY"; then
    pass "submodule index-flag edit survived --apply --force-locked"
  else
    fail "DATA LOSS: --apply --force-locked deleted an index-flag-hidden edit inside a submodule"
    echo "$OUT4" >&2
  fi
fi
set -e

if [ "$RC4" -eq 0 ]; then
  pass "apply --force-locked --orphan-clean exits 0"
else
  fail "apply with escalations exit code $RC4, expected 0"
  echo "$OUT4" >&2
fi

# Case 19 (#762 r2 P3): --force-locked reaches the branch-attached locked
# path (try_remove "$WT_PATH" "1") and removes it — while the branch ref it
# was attached to survives, same contract as the unlocked case.
if [ -d "$LOCKED_PR_WT" ]; then
  fail "locked closed-PR branch worktree survived --apply --force-locked"
  echo "$OUT4" >&2
else
  pass "locked closed-PR branch worktree removed by --apply --force-locked"
fi
if git rev-parse --verify -q "refs/heads/$LOCKED_PR_BRANCH" >/dev/null; then
  pass "branch ref survived the forced locked branch-worktree removal"
else
  fail "branch ref $LOCKED_PR_BRANCH was destroyed by the forced removal"
  echo "$OUT4" >&2
fi

# Case 19b (#762 r3 P2): --force-locked is the ONLY thing that clears a
# locked+missing entry — try_remove() unlocks first, then removes. This is the
# assertion the pre-fix code cannot satisfy: routed to the prunable bucket it
# was never handed to try_remove at all, and the trailing `git worktree prune`
# skips locked entries, so the stale registration outlived every --apply.
if git worktree list --porcelain | grep -Fq -- "$LOCKMISS_PR_WT"; then
  fail "locked+missing entry survived --apply --force-locked (still registered)"
  echo "$OUT4" >&2
else
  pass "locked+missing entry cleared by --apply --force-locked"
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

# Hand-resolve everything the audit asked a HUMAN to decide — the diverged
# branch, the two retained-not-clean worktrees, and the unverifiable-PR one —
# then the audit is genuinely clean. Each of these is deliberately untouched
# by --apply, which is why the exit 2 persists until this point.
git branch -D "$DIVERGED_BRANCH" >/dev/null 2>&1 || true
git worktree remove --force "$DIRTY_PR_WT" >/dev/null 2>&1 || true
git worktree remove --force "$IGNORED_PR_WT" >/dev/null 2>&1 || true
git worktree remove --force "$UNTRACKED_PR_WT" >/dev/null 2>&1 || true
git worktree remove --force "$GONE_PR_WT" >/dev/null 2>&1 || true
git worktree remove --force "$FLAG_PR_WT" >/dev/null 2>&1 || true
git worktree remove --force "$SIGPIPE_PR_WT" >/dev/null 2>&1 || true
git worktree unlock "$SUB_PR_WT" >/dev/null 2>&1 || true
git worktree remove --force "$SUB_PR_WT" >/dev/null 2>&1 || true
git worktree remove --force "$SUBMOD_PR_WT" >/dev/null 2>&1 || true
git worktree remove --force "$UNKNOWN_PR_WT" >/dev/null 2>&1 || true
git worktree remove --force "$REGISTERED_CLAUDE_WT" >/dev/null 2>&1 || true
git worktree remove --force "$STALE_WT" >/dev/null 2>&1 || true
# #822: the stale-unpruned branches are reported, never removed, so resolving
# them is the operator action the report's own reason line prescribes — prune,
# then delete what that reclassifies. Doing exactly what the message says and
# reaching a clean audit is the assertion: it proves the advice is actionable
# and that the report clears once followed, rather than being a permanent
# exit-2 nag.
#
# Both commands must SUCCEED. Suppressing their status would let the clean-audit
# assertion below evaluate a state the remediation never reached, and report the
# audit as broken when the fixture is what failed.
git fetch -q --prune origin >/dev/null 2>&1 \
  || fail "fixture: prune failed, so the prescribed remediation was never applied"
git branch -D "$STALE_UNPRUNED_BRANCH" >/dev/null 2>&1 \
  || fail "fixture: could not delete $STALE_UNPRUNED_BRANCH after the prune"
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

# ── Case 24 (#892, Codex P2): a renamed fetch mapping is not misread ─────
# A configured mapping need not retain the remote branch name. Repositories
# commonly map a remote `release` head to a local `origin/stable` tracking ref.
# The stale-ref probe answers "which remote head populates
# refs/remotes/origin/<name>?" from `remote.origin.fetch`, so under a renamed
# mapping the conventional answer is simply wrong: it would find no remote
# `stable` and report a perfectly live branch as a deleted one.
#
# The probe handles this by declining — origin_fetch_is_conventional() gates it
# to the default refspec and anything else reports nothing at all. That is the
# fail-closed direction (a missed report, never a false one) and it is the
# whole of the behaviour under a non-default refspec now that nothing prunes;
# #932 revisits it against the replacement prune primitive.
MAPPED_ROOT="$WORKDIR/renamed-refspec"
MAPPED_REMOTE="$MAPPED_ROOT/remote.git"
MAPPED_MAIN="$MAPPED_ROOT/main"
MAPPED_WT="$MAPPED_ROOT/stable-worktree"
mkdir -p "$MAPPED_ROOT"
git init -q --bare "$MAPPED_REMOTE"
git init -q "$MAPPED_MAIN"
(
  cd "$MAPPED_MAIN"
  git -C "$MAPPED_MAIN" config user.email "test@example.com"
  git -C "$MAPPED_MAIN" config user.name "Test"
  git -C "$MAPPED_MAIN" config commit.gpgsign false
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  git remote add origin "$MAPPED_REMOTE"
  git push -q -u origin main
  git checkout -q -b release
  git push -q -u origin release
  git checkout -q main
  git config --unset-all remote.origin.fetch
  git config --add remote.origin.fetch '+refs/heads/release:refs/remotes/origin/stable'
  git fetch -q origin '+refs/heads/release:refs/remotes/origin/stable'
  git branch --track stable origin/stable
  git worktree add -q "$MAPPED_WT" stable
) >/dev/null 2>&1
# Pin the fixture premise before asserting on the behaviour (#920 finding 5's
# class, which survives this case even though the case it was raised against
# did not). The subshell above discards output and its status is unchecked, so
# a `git worktree add` or `--track` that failed under a different git version
# leaves a repo with no `stable` branch at all — and BOTH assertions below are
# negative (`stable` absent from the report, counter reads 0), so they would
# pass on that repo while proving nothing about the renamed mapping. Three
# things have to be true for the case to mean anything: the mapping is stored,
# the local branch exists tracking it, and the remote genuinely has no
# `refs/heads/stable` for a conventional-mapping probe to find.
if ! git -C "$MAPPED_MAIN" config --get-all remote.origin.fetch \
     | grep -Fqx -- '+refs/heads/release:refs/remotes/origin/stable'; then
  fail "fixture setup: expected the renamed release→origin/stable refspec to be the only remote.origin.fetch entry"
fi
if ! git -C "$MAPPED_MAIN" rev-parse --verify -q 'refs/heads/stable' >/dev/null; then
  fail "fixture setup: expected a local 'stable' branch tracking origin/stable (both assertions below would be vacuous)"
fi
if git --git-dir="$MAPPED_REMOTE" rev-parse --verify -q 'refs/heads/stable' >/dev/null; then
  fail "fixture setup: the remote must NOT carry refs/heads/stable — that absence is what the probe would misread"
fi

set +e
OUT_MAPPED_DRY=$( cd "$MAPPED_MAIN" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1 )
RC_MAPPED_DRY=$?
set -e
# `stable` is the discriminating branch: it tracks refs/remotes/origin/stable,
# and the remote has no `refs/heads/stable` at all — only `release`. A probe
# that assumed the conventional mapping would therefore call this live branch
# stale. The fail-closed gate declines to evaluate the repo instead, so the
# branch is absent and the class counter reads 0.
if [ "$RC_MAPPED_DRY" -eq 0 ] \
   && ! echo "$OUT_MAPPED_DRY" | grep -Fq -- "branch:   stable"; then
  pass "#892 a renamed release→origin/stable mapping is not misread as a stale ref"
else
  fail "#892 dry-run misclassified a live renamed remote mapping as stale"
  echo "$OUT_MAPPED_DRY" >&2
fi
MAPPED_STALE_N=$(echo "$OUT_MAPPED_DRY" | sed -n 's/.*gone (stale remote ref, unpruned): *\([0-9][0-9]*\).*/\1/p' | head -1)
if [ "${MAPPED_STALE_N:-x}" = "0" ]; then
  pass "#892 the stale-ref probe declines a non-conventional remote.origin.fetch (fail closed)"
else
  fail "#892 stale-unpruned counter is ${MAPPED_STALE_N:-unset} under a renamed refspec, expected 0"
  echo "$OUT_MAPPED_DRY" >&2
fi

# ── Case 25 (#892, Codex P2): branch names may contain a pipe ──────────
# Git forbids tabs in ref names but permits `|`. The stale-branch snapshot and
# its merged-sweep transport must therefore use a tab record separator; the
# former pipe format split `pipe|branch` into two unrelated fields and omitted
# the confirmed-deleted remote branch completely.
PIPE_ROOT="$WORKDIR/pipe-refname"
PIPE_REMOTE="$PIPE_ROOT/remote.git"
PIPE_MAIN="$PIPE_ROOT/main"
PIPE_BRANCH='pipe|branch'
PIPE_WT="$PIPE_ROOT/pipe-worktree"
mkdir -p "$PIPE_ROOT"
git init -q --bare "$PIPE_REMOTE"
git init -q "$PIPE_MAIN"
(
  cd "$PIPE_MAIN"
  git -C "$PIPE_MAIN" config user.email "test@example.com"
  git -C "$PIPE_MAIN" config user.name "Test"
  git -C "$PIPE_MAIN" config commit.gpgsign false
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  git remote add origin "$PIPE_REMOTE"
  git push -q -u origin main
  git branch "$PIPE_BRANCH"
  git push -q -u origin "$PIPE_BRANCH"
  git worktree add -q "$PIPE_WT" "$PIPE_BRANCH"
  git --git-dir="$PIPE_REMOTE" branch -D "$PIPE_BRANCH"
) >/dev/null 2>&1

set +e
OUT_PIPE=$( cd "$PIPE_MAIN" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1 )
RC_PIPE=$?
set -e
# Assert on the BRANCH record, which is what the tab-separated snapshot carries.
# Under the old pipe-delimited format `pipe|branch` split into two unrelated
# fields and the branch vanished from the sweep entirely — no record, and the
# stale-ref counter reads 0 rather than 1.
# Exit 0, not 2: with no merged PR for the head name the branch lands in the
# advisory "gone kept (unmerged)" bucket, which is deliberately not a removal
# candidate. The record and the counter are the observable, not the exit code.
if [ "$RC_PIPE" -eq 0 ] \
   && echo "$OUT_PIPE" | grep -Fq -- "branch:   $PIPE_BRANCH" \
   && echo "$OUT_PIPE" | grep -qE "gone \(stale remote ref, unpruned\): +1"; then
  pass "#892 a stale branch whose legal name contains | survives the snapshot round-trip"
else
  fail "#892 a stale branch containing | was lost while serializing records"
  echo "$OUT_PIPE" >&2
fi

# The dry-run assertion above needed the tracking ref STALE, which is what the
# stale-ref probe reads. The apply assertion below needs it GONE, which is what
# gone_branches() reads — and this audit never prunes (#932), so the fixture
# performs the prune itself between the two runs. Both parsers see a `|` in the
# branch name; only their inputs differ.
git -C "$PIPE_MAIN" fetch -q --prune origin
set +e
OUT_PIPE_APPLY=$( cd "$PIPE_MAIN" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply 2>&1 )
RC_PIPE_APPLY=$?
set -e
if [ "$RC_PIPE_APPLY" -eq 0 ] && [ ! -d "$PIPE_WT" ]; then
  pass "#892 --apply removes the clean stale worktree whose branch contains |"
else
  fail "#892 --apply did not reach the stale worktree whose branch contains |"
  echo "$OUT_PIPE_APPLY" >&2
fi

# ── Case 26 (#892, Codex P1): branch/tag name collisions stay fail-safe ─
# A tag and a branch may share a short name. Git resolves a bare revision
# name through its disambiguation rules, where the tag can win. The cleanup
# decision must instead compare the merged PR head to refs/heads/<name>, or a
# local follow-up commit on the branch can be mistaken for the tag's old,
# merged tip and deleted by --apply.
COLLIDE_ROOT="$WORKDIR/branch-tag-collision"
COLLIDE_REMOTE="$COLLIDE_ROOT/remote.git"
COLLIDE_MAIN="$COLLIDE_ROOT/main"
COLLIDE_BRANCH='same-short-name'
COLLIDE_STUB="$COLLIDE_ROOT/stub-bin"
mkdir -p "$COLLIDE_ROOT" "$COLLIDE_STUB"
git init -q --bare "$COLLIDE_REMOTE"
git init -q "$COLLIDE_MAIN"
(
  cd "$COLLIDE_MAIN"
  git -C "$COLLIDE_MAIN" config user.email "test@example.com"
  git -C "$COLLIDE_MAIN" config user.name "Test"
  git -C "$COLLIDE_MAIN" config commit.gpgsign false
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  git remote add origin "$COLLIDE_REMOTE"
  git push -q -u origin main
  git checkout -q -b "$COLLIDE_BRANCH"
  git push -q -u origin "$COLLIDE_BRANCH"
  # Both refs point at the simulated merged PR head before the branch gains
  # an unpushed follow-up commit.
  git tag "$COLLIDE_BRANCH"
  echo follow-up > follow-up.txt
  git add follow-up.txt
  git commit -q -m "local follow-up after PR merge"
  git checkout -q main
  git push -q origin --delete "$COLLIDE_BRANCH"
) >/dev/null 2>&1
COLLIDE_MERGED_TIP=$(git -C "$COLLIDE_MAIN" rev-parse "refs/heads/$COLLIDE_BRANCH^")
cat >"$COLLIDE_STUB/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  head=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --head) head="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "\$head" = "$COLLIDE_BRANCH" ]; then
    echo "$COLLIDE_MERGED_TIP"
    exit 0
  fi
fi
exec "$STUB_DIR/gh" "\$@"
EOF
chmod +x "$COLLIDE_STUB/gh"

set +e
OUT_COLLIDE=$( cd "$COLLIDE_MAIN" && PATH="$COLLIDE_STUB:$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply 2>&1 )
RC_COLLIDE=$?
set -e
if [ "$RC_COLLIDE" -eq 0 ] \
   && git -C "$COLLIDE_MAIN" rev-parse --verify -q "refs/heads/$COLLIDE_BRANCH" >/dev/null \
   && echo "$OUT_COLLIDE" | grep -Fq -- "local tip has unmerged commit(s) on top"; then
  pass "#892 --apply preserves a diverged branch when a tag has the same short name"
else
  fail "DATA LOSS: a branch/tag short-name collision made --apply delete local follow-up work"
  echo "$OUT_COLLIDE" >&2
fi

# ── Case 27 (#892, Codex P2): apply-side parser pins English locale ────
# Model a localized gone marker by translating it only when LC_ALL is absent.
# The helper must pin LC_ALL=C for this parser so --apply reaches the same gone
# branch it would see in an English environment.
#
# The stub intercepts `for-each-ref`, which is what gone_branches() reads. It
# used to intercept `git branch -vv`; when the parser moved to for-each-ref
# (Phase 4b P2 on #892 — color and `]` in branch names both corrupt the
# porcelain listing) that stub became inert and this case passed without
# exercising anything. Localization is still the risk being guarded: the
# `[gone]` tracking atom comes from the same translated message catalog.
LOCALE_ROOT="$WORKDIR/localized-gone"
LOCALE_REMOTE="$LOCALE_ROOT/remote.git"
LOCALE_MAIN="$LOCALE_ROOT/main"
LOCALE_BRANCH='localized-gone'
LOCALE_WT="$LOCALE_ROOT/gone-worktree"
LOCALE_STUB="$LOCALE_ROOT/git-stub"
mkdir -p "$LOCALE_ROOT"
git init -q --bare "$LOCALE_REMOTE"
git init -q "$LOCALE_MAIN"
(
  cd "$LOCALE_MAIN"
  git -C "$LOCALE_MAIN" config user.email "test@example.com"
  git -C "$LOCALE_MAIN" config user.name "Test"
  git -C "$LOCALE_MAIN" config commit.gpgsign false
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  git remote add origin "$LOCALE_REMOTE"
  git push -q -u origin main
  git branch "$LOCALE_BRANCH"
  git push -q -u origin "$LOCALE_BRANCH"
  git worktree add -q "$LOCALE_WT" "$LOCALE_BRANCH"
  git --git-dir="$LOCALE_REMOTE" branch -D "$LOCALE_BRANCH"
  git fetch -q --prune origin
) >/dev/null 2>&1
mkdir -p "$LOCALE_STUB"
cat >"$LOCALE_STUB/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = for-each-ref ] && [ "${LC_ALL:-}" != C ]; then
  "$REAL_GIT" "$@" | sed 's/\[gone\]/[verschwunden]/'
  exit "${PIPESTATUS[0]}"
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$LOCALE_STUB/git"

set +e
OUT_LOCALE=$( cd "$LOCALE_MAIN" && REAL_GIT="$(command -v git)" PATH="$LOCALE_STUB:$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply 2>&1 )
RC_LOCALE=$?
set -e
if [ "$RC_LOCALE" -eq 0 ] && [ ! -d "$LOCALE_WT" ]; then
  pass "#892 --apply parses gone-upstream state with LC_ALL=C"
else
  fail "#892 localized gone marker made --apply retain the stale worktree"
  echo "$OUT_LOCALE" >&2
fi

# ── Case 30 (#892, Codex P2): upstreams use their full ref name ───────────
# When refs/heads/origin/foo exists, Git renders foo's upstream as
# remotes/origin/foo under %(upstream:short). The full %(upstream) value stays
# canonical, so dry-run and apply agree that a deleted foo worktree is stale.
UPSTREAM_ROOT="$WORKDIR/ambiguous-upstream"
UPSTREAM_REMOTE="$UPSTREAM_ROOT/remote.git"
UPSTREAM_MAIN="$UPSTREAM_ROOT/main"
UPSTREAM_BRANCH='foo'
UPSTREAM_WT="$UPSTREAM_ROOT/foo-worktree"
mkdir -p "$UPSTREAM_ROOT"
git init -q --bare "$UPSTREAM_REMOTE"
git init -q "$UPSTREAM_MAIN"
(
  cd "$UPSTREAM_MAIN"
  git -C "$UPSTREAM_MAIN" config user.email "test@example.com"
  git -C "$UPSTREAM_MAIN" config user.name "Test"
  git -C "$UPSTREAM_MAIN" config commit.gpgsign false
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  git remote add origin "$UPSTREAM_REMOTE"
  git push -q -u origin main
  git checkout -q -b "$UPSTREAM_BRANCH"
  git push -q -u origin "$UPSTREAM_BRANCH"
  git checkout -q main
  git branch -D "$UPSTREAM_BRANCH"
  git branch --track "$UPSTREAM_BRANCH" "origin/$UPSTREAM_BRANCH"
  git branch "origin/$UPSTREAM_BRANCH"
  git worktree add -q "$UPSTREAM_WT" "$UPSTREAM_BRANCH"
  git --git-dir="$UPSTREAM_REMOTE" branch -D "$UPSTREAM_BRANCH"
) >/dev/null 2>&1
set +e
OUT_UPSTREAM_DRY=$( cd "$UPSTREAM_MAIN" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1 )
RC_UPSTREAM_DRY=$?
set -e
# The probe derives the remote head from the FULL %(upstream) ref. Under
# %(upstream:short) this fixture renders foo's upstream as `remotes/origin/foo`
# — because a local branch literally named `origin/foo` makes the short form
# ambiguous — which no longer starts with `refs/remotes/origin/`, so the branch
# is skipped and the stale-ref counter reads 0 instead of 1.
# Exit 0 for the same reason as case 25: no merged PR, so the branch is
# reported and counted but is not a removal candidate.
if [ "$RC_UPSTREAM_DRY" -eq 0 ] \
   && echo "$OUT_UPSTREAM_DRY" | grep -Fq -- "branch:   $UPSTREAM_BRANCH" \
   && echo "$OUT_UPSTREAM_DRY" | grep -qE "gone \(stale remote ref, unpruned\): +1"; then
  pass "#892 dry-run finds the stale branch when %(upstream:short) is ambiguous"
else
  fail "#892 ambiguous short upstream caused dry-run to omit a stale branch"
  echo "$OUT_UPSTREAM_DRY" >&2
fi
# Same split as case 25: dry-run reads the STALE ref via the probe, --apply
# reads the GONE marker via gone_branches(), and nothing here prunes (#932),
# so the fixture prunes between the two runs. The ambiguity under test —
# a local branch literally named `origin/foo` — is present for both parsers.
git -C "$UPSTREAM_MAIN" fetch -q --prune origin
set +e
OUT_UPSTREAM_APPLY=$( cd "$UPSTREAM_MAIN" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply 2>&1 )
RC_UPSTREAM_APPLY=$?
set -e
if [ "$RC_UPSTREAM_APPLY" -eq 0 ] && [ ! -d "$UPSTREAM_WT" ]; then
  pass "#892 --apply reaches the stale worktree behind an ambiguous short upstream"
else
  fail "#892 ambiguous short upstream made --apply retain the stale worktree"
  echo "$OUT_UPSTREAM_APPLY" >&2
fi

# ── Case 31 (#892, Codex P2): a branch itself may begin with plus ─────────
PLUS_ROOT="$WORKDIR/leading-plus"
PLUS_REMOTE="$PLUS_ROOT/remote.git"
PLUS_MAIN="$PLUS_ROOT/main"
PLUS_BRANCH='+foo'
PLUS_WT="$PLUS_ROOT/plus-worktree"
mkdir -p "$PLUS_ROOT"
git init -q --bare "$PLUS_REMOTE"
git init -q "$PLUS_MAIN"
(
  cd "$PLUS_MAIN"
  git -C "$PLUS_MAIN" config user.email "test@example.com"
  git -C "$PLUS_MAIN" config user.name "Test"
  git -C "$PLUS_MAIN" config commit.gpgsign false
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  git remote add origin "$PLUS_REMOTE"
  git push -q -u origin main
  git branch "$PLUS_BRANCH"
  # `git push` parses a plus in a refspec as its force marker even when the
  # plus belongs to the branch name. Install the remote and tracking refs
  # directly so this fixture exercises Git's legal refname, not refspec
  # shorthand parsing.
  PLUS_TIP=$(git rev-parse "refs/heads/$PLUS_BRANCH")
  git --git-dir="$PLUS_REMOTE" update-ref "refs/heads/$PLUS_BRANCH" "$PLUS_TIP"
  git update-ref "refs/remotes/origin/$PLUS_BRANCH" "$PLUS_TIP"
  git branch --set-upstream-to="origin/$PLUS_BRANCH" "$PLUS_BRANCH"
  git worktree add -q "$PLUS_WT" "$PLUS_BRANCH"
  git --git-dir="$PLUS_REMOTE" branch -D "$PLUS_BRANCH"
  # This audit never prunes (#932), and the parser under test — gone_branches()
  # — reads the gone marker, so the fixture establishes it.
  git fetch -q --prune origin
) >/dev/null 2>&1
set +e
OUT_PLUS=$( cd "$PLUS_MAIN" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply 2>&1 )
RC_PLUS=$?
set -e
if [ "$RC_PLUS" -eq 0 ] && [ ! -d "$PLUS_WT" ]; then
  pass "#892 --apply preserves a leading plus in a stale branch name"
else
  fail "#892 branch-list marker parsing dropped a branch's leading plus"
  echo "$OUT_PLUS" >&2
fi

# ── Case 34 (#892, CodeRabbit): porcelain failure cannot mean no worktrees ─
# A process substitution hides the producer status. Simulate an old or broken
# Git that rejects `worktree list --porcelain -z`: the audit must terminate
# before an empty REC_FILE can be interpreted as a clean worktree inventory.
PORCELAIN_FAIL_STUB="$WORKDIR/porcelain-fail-git"
mkdir -p "$PORCELAIN_FAIL_STUB"
cat >"$PORCELAIN_FAIL_STUB/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "worktree" ] && [ "$2" = "list" ] && [ "$3" = "--porcelain" ] && [ "$4" = "-z" ]; then
  exit 129
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$PORCELAIN_FAIL_STUB/git"
set +e
OUT_PORCELAIN_FAIL=$( cd "$MAIN" && REAL_GIT="$(command -v git)" PATH="$PORCELAIN_FAIL_STUB:$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1 )
RC_PORCELAIN_FAIL=$?
set -e
if [ "$RC_PORCELAIN_FAIL" -ne 0 ] \
   && echo "$OUT_PORCELAIN_FAIL" | grep -Fq "could not read git worktree porcelain records"; then
  pass "#892 unreadable NUL porcelain inventory fails closed instead of looking empty"
else
  fail "#892 an unreadable NUL porcelain inventory did not fail closed"
  echo "$OUT_PORCELAIN_FAIL" >&2
fi

# Build a fixture holding one gone-upstream branch (remote deleted server-side,
# then pruned so `%(upstream:track)` really reads `[gone]`) with a clean
# worktree on it, so `--apply` should classify and remove that worktree. Used
# by the cases below, each of which changes ONE knob and asserts the removal
# still happens — they exercise gone_branches()'s PARSER, so the fixture has to
# supply the gone marker itself; this audit never prunes (#932).
# $1 destination root, $2 branch name; echoes nothing, sets no globals.
make_gone_worktree_fixture() {
  local root="$1" branch="$2"
  local remote="$root/remote.git" main="$root/main" wt="$root/gone-worktree"
  mkdir -p "$root"
  git init -q --bare "$remote"
  git init -q "$main"
  (
    cd "$main" || exit 1
    # Identity writes target the fixture repo explicitly rather than relying on
    # the subshell cwd — bare `git config` here is what check_git_identity_hygiene
    # rejects, and a cwd-dependent write is one stray `cd` away from editing the
    # real repo's config.
    git -C "$main" config user.email "test@example.com"
    git -C "$main" config user.name "Test"
    git -C "$main" config commit.gpgsign false
    git checkout -q -b main
    echo seed > seed.txt
    git add seed.txt
    git commit -q -m "seed"
    git remote add origin "$remote"
    git push -q -u origin main
    git branch "$branch"
    git push -q -u origin "$branch"
    git worktree add -q "$wt" "$branch"
    # Server-side deletion, then prune: the gone marker is the fixture's
    # precondition, not something the helper under test produces.
    git --git-dir="$remote" branch -D "$branch"
    git fetch -q --prune origin
  ) >/dev/null 2>&1
}

# ── Case 36 (#892, Phase 4b P2): gone parsing survives forced color ─────
# `color.branch=always` is a legal user setting and it colors non-tty output by
# design. Parsing `git branch -vv` under it yields a branch token with ANSI
# escapes glued on (`gonebr<ESC>[m`), so --apply looks up a branch that does not
# exist and silently retains everything it just pruned. The parser must read a
# plumbing surface that carries no color.
COLOR_ROOT="$WORKDIR/forced-color"
COLOR_BRANCH='color-forced-gone'
make_gone_worktree_fixture "$COLOR_ROOT" "$COLOR_BRANCH"
git -C "$COLOR_ROOT/main" config color.branch always
git -C "$COLOR_ROOT/main" config color.ui always
set +e
OUT_COLOR=$( cd "$COLOR_ROOT/main" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply 2>&1 )
RC_COLOR=$?
set -e
if [ "$RC_COLOR" -eq 0 ] && [ ! -d "$COLOR_ROOT/gone-worktree" ]; then
  pass "#892 --apply reaches a gone branch under color.branch=always"
else
  fail "#892 forced branch color made --apply retain the stale worktree"
  echo "$OUT_COLOR" >&2
fi

# ── Case 37 (#892, Phase 4b P2): ']' is legal in a branch name ──────────
# check-ref-format forbids `[` but NOT `]`, so `topic]` is a legal branch. It
# renders as `[origin/topic]: gone]`, which a `\[[^]]*: gone\]` marker test
# cannot match — the branch is dropped from the sweep in apply mode right after
# the prune removed its tracking ref.
BRACKET_ROOT="$WORKDIR/bracket-branch"
BRACKET_BRANCH='bracket-gone]'
make_gone_worktree_fixture "$BRACKET_ROOT" "$BRACKET_BRANCH"
set +e
OUT_BRACKET=$( cd "$BRACKET_ROOT/main" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --apply 2>&1 )
RC_BRACKET=$?
set -e
if [ "$RC_BRACKET" -eq 0 ] && [ ! -d "$BRACKET_ROOT/gone-worktree" ]; then
  pass "#892 --apply reaches a gone branch whose name contains ']'"
else
  fail "#892 a ']' in the branch name hid it from the apply-side gone sweep"
  echo "$OUT_BRACKET" >&2
fi

# ── Case 40 (#920 finding 1): a refspec git rejects fails closed, loudly ──
# `git config` stores refspecs it never validates. A wildcard DESTINATION with
# no wildcard in the source — `refs/heads/main:refs/remotes/origin/*` — is a
# pair git refuses, and `%(upstream:track)` has to resolve every branch's
# upstream THROUGH remote.origin.fetch, so `for-each-ref` goes fatal for the
# repository as a whole rather than for one ref. Before the guard that 128
# rode `pipefail` into `set -e` and killed the run with an empty terminal: no
# records, no summary, no message, exit 128. The audit must instead say what
# it could not read, and must not emit classification records built on an
# inventory it never obtained.
BADSPEC_ROOT="$WORKDIR/invalid-refspec"
BADSPEC_REMOTE="$BADSPEC_ROOT/remote.git"
BADSPEC_MAIN="$BADSPEC_ROOT/main"
mkdir -p "$BADSPEC_ROOT"
git init -q --bare "$BADSPEC_REMOTE"
git init -q "$BADSPEC_MAIN"
(
  cd "$BADSPEC_MAIN"
  git -C "$BADSPEC_MAIN" config user.email "test@example.com"
  git -C "$BADSPEC_MAIN" config user.name "Test"
  git -C "$BADSPEC_MAIN" config commit.gpgsign false
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  git remote add origin "$BADSPEC_REMOTE"
  git push -q -u origin main
  git checkout -q -b topic
  git push -q -u origin topic
  git checkout -q main
  git config --unset-all remote.origin.fetch
  git config --add remote.origin.fetch 'refs/heads/main:refs/remotes/origin/*'
) >/dev/null 2>&1
# Premise: the refspec really is stored, and git really does reject it. Both
# halves matter — a git version that accepted the pair would make the case
# assert a failure mode that no longer exists, and it must say so rather than
# quietly testing nothing.
if ! git -C "$BADSPEC_MAIN" config --get-all remote.origin.fetch \
     | grep -Fqx -- 'refs/heads/main:refs/remotes/origin/*'; then
  fail "fixture setup: expected the mismatched-wildcard refspec to be stored in remote.origin.fetch"
fi
if git -C "$BADSPEC_MAIN" for-each-ref \
     --format='%(refname:lstrip=2) %(upstream:track)' refs/heads/ >/dev/null 2>&1; then
  fail "fixture setup: this git accepts refs/heads/main:refs/remotes/origin/* — the case's premise no longer holds"
fi
set +e
OUT_BADSPEC=$( cd "$BADSPEC_MAIN" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1 )
RC_BADSPEC=$?
set -e
if [ "$RC_BADSPEC" -ne 0 ] \
   && echo "$OUT_BADSPEC" | grep -Fq -- "could not read local branch tracking state"; then
  pass "#920 an unreadable branch inventory names the failure instead of dying silently"
else
  fail "#920 a git-rejected remote.origin.fetch aborted the audit with no diagnostic (rc=$RC_BADSPEC)"
  echo "$OUT_BADSPEC" >&2
fi
# The other half of the acceptance criterion: failing closed must not mean
# failing loudly-and-wrongly. No branch may be classified off an inventory the
# run never read, so the report must carry no records at all.
if ! echo "$OUT_BADSPEC" | grep -Fq -- "    path:     " \
   && ! echo "$OUT_BADSPEC" | grep -Fq -- "    branch:   "; then
  pass "#920 no classification records are emitted from an inventory that could not be read"
else
  fail "#920 the audit classified branches despite an unreadable branch inventory"
  echo "$OUT_BADSPEC" >&2
fi

# ── Case 41 (#920 finding 2): the EXIT trap reclaims every mktemp site ──
# stale_unpruned_branches() creates its remote-heads snapshot, then reads
# `git for-each-ref … %(upstream)` in a pipeline. Under `set -eo pipefail` a
# failure of that producer aborts the run BEFORE the function's inline
# `rm -f`, which is precisely the window the inline removals cannot cover.
# The stub below fails only that call — it is keyed on `%(upstream)` WITHOUT
# `:track`, so gone_branches()'s own for-each-ref still succeeds and the run
# reaches the snapshot before dying. A private TMPDIR makes the leak
# observable without depending on what else is in the shared one.
TRAP_ROOT="$WORKDIR/trap-cleanup"
TRAP_TMPDIR="$TRAP_ROOT/tmp"
TRAP_STUB="$TRAP_ROOT/stub"
mkdir -p "$TRAP_TMPDIR" "$TRAP_STUB"
cat >"$TRAP_STUB/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "for-each-ref" ] && [[ "$*" == *'%(upstream)'* ]] && [[ "$*" != *'%(upstream:track)'* ]]; then
  exit 129
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TRAP_STUB/git"
git init -q --bare "$TRAP_ROOT/remote.git"
git init -q "$TRAP_ROOT/main"
(
  cd "$TRAP_ROOT/main"
  git -C "$TRAP_ROOT/main" config user.email "test@example.com"
  git -C "$TRAP_ROOT/main" config user.name "Test"
  git -C "$TRAP_ROOT/main" config commit.gpgsign false
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  git remote add origin "$TRAP_ROOT/remote.git"
  git push -q -u origin main
) >/dev/null 2>&1
if [ -n "$(find "$TRAP_TMPDIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
  fail "fixture setup: the private TMPDIR for the trap case is not empty before the run"
fi
set +e
OUT_TRAP=$( cd "$TRAP_ROOT/main" \
  && TMPDIR="$TRAP_TMPDIR" REAL_GIT="$(command -v git)" PATH="$TRAP_STUB:$STUB_DIR:$PATH" \
     bash "$HELPER" --no-color --dry-run 2>&1 )
RC_TRAP=$?
set -e
# Premise: the run really did abort mid-flight. A run that completed normally
# would leave the TMPDIR clean via the inline removals alone, and the leak
# assertion below would pass without ever exercising the trap.
if [ "$RC_TRAP" -eq 0 ]; then
  fail "fixture setup: the instrumented run exited 0 — it never reached the abort the trap has to cover"
  echo "$OUT_TRAP" >&2
fi
TRAP_LEAKS=$(find "$TRAP_TMPDIR" -mindepth 1 -maxdepth 1 2>/dev/null | tr '\n' ' ')
if [ -z "${TRAP_LEAKS// /}" ]; then
  pass "#920 the EXIT trap reclaims the remote-heads snapshot when the run aborts mid-flight"
else
  fail "#920 aborted run leaked temp files into TMPDIR: $TRAP_LEAKS"
  echo "$OUT_TRAP" >&2
fi

# ── Case 42 (#920 finding 2, r1): the EXIT trap deletes nothing it did not create ──
# Widening the trap to cover HEADS_FILE / RECORDS_FILE / MERGE_SWEEP_FILE /
# KNOWN_FILE gave it four names it does not own outright. The script runs
# under `set -eo pipefail` with no `set -u`, so `${KNOWN_FILE:-}` expands an
# INHERITED exported value verbatim, and the trap then `rm -f`s a path the
# script never created. Two of the four are reachable on an ordinary run:
# KNOWN_FILE is assigned only inside `[ -d "$ORPHAN_ROOT" ]`, so a repo with
# no .claude/worktrees loses it on a plain --dry-run; stale_unpruned_branches()
# is dry-run-only, so every successful --apply loses HEADS_FILE. The other two
# go with any abort before their assignment. A read-only audit must not delete
# a caller's file on nothing more than a name collision, so all three runs
# below — success under --dry-run, success under --apply, and the mid-flight
# abort from Case 40's fixture — are asserted against the same four sentinels.
TRAPENV_ROOT="$WORKDIR/trap-inherited-env"
TRAPENV_SENTINELS="$TRAPENV_ROOT/sentinels"
mkdir -p "$TRAPENV_ROOT" "$TRAPENV_SENTINELS"
git init -q --bare "$TRAPENV_ROOT/remote.git"
git init -q "$TRAPENV_ROOT/main"
(
  cd "$TRAPENV_ROOT/main"
  git -C "$TRAPENV_ROOT/main" config user.email "test@example.com"
  git -C "$TRAPENV_ROOT/main" config user.name "Test"
  git -C "$TRAPENV_ROOT/main" config commit.gpgsign false
  git checkout -q -b main
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m "seed"
  git remote add origin "$TRAPENV_ROOT/remote.git"
  git push -q -u origin main
) >/dev/null 2>&1
# Premise: the --dry-run and --apply legs only exercise the KNOWN_FILE window
# while this repo has no .claude/worktrees directory. A fixture that grew one
# would move KNOWN_FILE into its assigned branch and the leg would pass for
# the wrong reason.
if [ -e "$TRAPENV_ROOT/main/.claude/worktrees" ]; then
  fail "fixture setup: expected no .claude/worktrees in the inherited-env fixture (the KNOWN_FILE window would not open)"
fi
# Seeds the four sentinels and runs the helper with each one exported under the
# matching variable name; echoes the names that did not survive.
trapenv_run() {
  local label="$1"
  local dir="$2"
  shift 2
  local n missing=""
  for n in HEADS RECORDS MERGE_SWEEP KNOWN; do
    printf '%s\n' "do-not-delete-$n" > "$TRAPENV_SENTINELS/$n"
  done
  set +e
  ( cd "$dir" \
    && HEADS_FILE="$TRAPENV_SENTINELS/HEADS" \
       RECORDS_FILE="$TRAPENV_SENTINELS/RECORDS" \
       MERGE_SWEEP_FILE="$TRAPENV_SENTINELS/MERGE_SWEEP" \
       KNOWN_FILE="$TRAPENV_SENTINELS/KNOWN" \
       PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color "$@" ) >/dev/null 2>&1
  TRAPENV_RC=$?
  set -e
  for n in HEADS RECORDS MERGE_SWEEP KNOWN; do
    [ -e "$TRAPENV_SENTINELS/$n" ] || missing="$missing ${n}_FILE"
  done
  TRAPENV_MISSING="${missing# }"
  TRAPENV_LABEL="$label"
}
trapenv_assert() {
  if [ -z "$TRAPENV_MISSING" ]; then
    pass "#920 the EXIT trap leaves inherited temp-file variables alone ($TRAPENV_LABEL)"
  else
    fail "#920 the EXIT trap deleted inherited paths it never created ($TRAPENV_LABEL, rc=$TRAPENV_RC): $TRAPENV_MISSING"
  fi
}
trapenv_run "successful --dry-run" "$TRAPENV_ROOT/main" --dry-run
# Premise: a run that died early would leave most of the trap unreached and
# the survival assertion would say nothing about the successful path.
if [ "$TRAPENV_RC" -ne 0 ]; then
  fail "fixture setup: the inherited-env --dry-run exited $TRAPENV_RC — it never completed the run the assertion describes"
fi
trapenv_assert
trapenv_run "successful --apply" "$TRAPENV_ROOT/main" --apply
if [ "$TRAPENV_RC" -ne 0 ]; then
  fail "fixture setup: the inherited-env --apply exited $TRAPENV_RC — it never completed the run the assertion describes"
fi
trapenv_assert
# Third leg: the abort this PR's own gone_branches() guard introduces, which
# fires before ANY of the four is assigned. Reuses Case 40's rejected-refspec
# repo, whose premises are pinned there.
trapenv_run "aborted run (rejected remote.origin.fetch)" "$BADSPEC_MAIN" --dry-run
if [ "$TRAPENV_RC" -eq 0 ]; then
  fail "fixture setup: the rejected-refspec run exited 0 — the pre-assignment abort window never opened"
fi
trapenv_assert

# ── Case 44 (#992 crit 1): an unreadable remote is not a clean audit ─────
# stale_unpruned_branches() takes exactly one remote read. When that read
# failed it returned silently, leaving STALE_UNPRUNED_FILE empty — and the
# audit then printed `gone (stale remote ref, unpruned): 0`, wrote nothing to
# stderr, and exited 0. A failed snapshot was byte-identical to a clean tree.
#
# That is the dangerous direction rather than the merely noisy one: the
# preview claims agreement with an --apply it was never able to model, and a
# later --apply with working network reclassifies branches as gone and
# removes worktrees the preview never listed.
#
# The remote is broken by pointing origin at a path that does not exist, so
# the case needs no network and cannot flake on one.
UNK_ROOT="$WORKDIR/unreachable-remote"
UNK_REMOTE="$UNK_ROOT/remote.git"
UNK_MAIN="$UNK_ROOT/main"
mkdir -p "$UNK_ROOT"
git init -q --bare "$UNK_REMOTE"
git init -q -b main "$UNK_MAIN"
(
  cd "$UNK_MAIN"
  git -C "$UNK_MAIN" config user.email "test@example.com"
  git -C "$UNK_MAIN" config user.name "Test"
  git -C "$UNK_MAIN" config commit.gpgsign false
  git -C "$UNK_MAIN" config tag.gpgsign false
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m seed
  git remote add origin "$UNK_REMOTE"
  git push -q -u origin main
  git checkout -q -b topic
  git push -q -u origin topic
  git checkout -q main
) >/dev/null 2>&1
git -C "$UNK_MAIN" remote set-url origin "$UNK_ROOT/vanished.git"

# Premise 1: the refspec is still the conventional one, so the probe REACHES
# the remote read rather than declining before it. Without this the case
# would assert exit 3 on a path that never runs — and `declined` must not
# exit 3, which is the distinction the whole change rests on.
if ! git -C "$UNK_MAIN" config --get-all remote.origin.fetch \
     | grep -Fqx -- '+refs/heads/*:refs/remotes/origin/*'; then
  fail "fixture setup: remote.origin.fetch is not conventional — case 44 would exercise the declined path, not the unknown one"
fi
# Premise 2: the read really does fail.
if git -C "$UNK_MAIN" ls-remote --heads origin >/dev/null 2>&1; then
  fail "fixture setup: ls-remote still succeeds against the vanished remote — case 44 has no failure to detect"
fi
# Premise 3: there is a branch the probe WOULD have evaluated, so the count
# of 0 is genuinely an absence of measurement and not an absence of subjects.
if [ "$(git -C "$UNK_MAIN" for-each-ref --format='%(upstream)' refs/heads/topic)" \
     != "refs/remotes/origin/topic" ]; then
  fail "fixture setup: topic does not track origin/topic — the probe would have had nothing to evaluate anyway"
fi

set +e
OUT_UNK=$( cd "$UNK_MAIN" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1 )
RC_UNK=$?
set -e
if [ "$RC_UNK" -eq 3 ]; then
  pass "#992 an unreadable remote snapshot exits 3 rather than reporting a clean audit"
else
  fail "#992 an unreadable remote snapshot exited $RC_UNK (expected 3)"
  echo "$OUT_UNK" >&2
fi
if echo "$OUT_UNK" | grep -Fq -- "NOT MEASURED"; then
  pass "#992 the zero count is annotated as not-measured rather than left to read as clean"
else
  fail "#992 the summary presented an unmeasured count as a measurement"
  echo "$OUT_UNK" >&2
fi
# The count itself must still be 0 — the fix adds a qualifier, it does not
# invent a number the run could not obtain.
if echo "$OUT_UNK" | grep -qE "gone \(stale remote ref, unpruned\): +0$"; then
  pass "#992 the unmeasured counter still reports 0 rather than a fabricated figure"
else
  fail "#992 the stale-unpruned counter changed value on an unreadable remote"
  echo "$OUT_UNK" >&2
fi

# Precedence: an incomplete audit outranks a complete one with findings. Add
# an orphan so total_candidates is non-zero, which without the ordering rule
# would exit 2 and hide the hole behind an ordinary findings status.
mkdir -p "$UNK_MAIN/.claude/worktrees/leftover"
echo residue > "$UNK_MAIN/.claude/worktrees/leftover/residue.txt"
set +e
OUT_UNK2=$( cd "$UNK_MAIN" && PATH="$STUB_DIR:$PATH" bash "$HELPER" --no-color --dry-run 2>&1 )
RC_UNK2=$?
set -e
if echo "$OUT_UNK2" | grep -qE "orphan dirs: +1$"; then
  pass "#992 precedence fixture: the run really did find a candidate"
else
  fail "fixture setup: the orphan was not detected, so the precedence assertion below is vacuous"
  echo "$OUT_UNK2" >&2
fi
if [ "$RC_UNK2" -eq 3 ]; then
  pass "#992 an incomplete audit outranks findings — exit 3, not 2"
else
  fail "#992 an incomplete audit with findings exited $RC_UNK2 (expected 3)"
  echo "$OUT_UNK2" >&2
fi
# Raising the status must not cost the operator the hint or the findings.
if echo "$OUT_UNK2" | grep -Fq -- "Re-run with --apply"; then
  pass "#992 the --apply hint survives the raised exit status"
else
  fail "#992 raising the exit status suppressed the dry-run hint"
  echo "$OUT_UNK2" >&2
fi

# The other half of the distinction: `declined` is NOT `unknown`. Case 24's
# renamed-refspec repo reaches origin_fetch_is_conventional() and stops
# there, and must keep exiting 0 — folding a standing, documented limitation
# into the unknown state would put every non-conventional checkout at a
# permanent exit 3.
if [ "$RC_MAPPED_DRY" -eq 0 ]; then
  pass "#992 a declined (non-conventional refspec) probe does not exit 3"
else
  fail "#992 the declined path was conflated with the unknown one (rc=$RC_MAPPED_DRY)"
fi
if ! echo "$OUT_MAPPED_DRY" | grep -Fq -- "NOT MEASURED"; then
  pass "#992 a declined probe is not annotated as an unmeasured failure"
else
  fail "#992 a documented limitation was reported as a failed read"
  echo "$OUT_MAPPED_DRY" >&2
fi

echo ""
echo "RESULTS: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
