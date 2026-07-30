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
if ! git branch -vv | grep -q ': gone\]'; then
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
if ! git branch -vv | grep -q "$GONE_PR_BRANCH.*: gone\]"; then
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

# Case 12 (#739): hidden-folder pr-<n>-<desc> worktree is PR-state checked
# and flagged STALE detached (the stub reports the PR MERGED).
if echo "$OUT" | grep -q "STALE detached PR #${HIDDEN_PR_NUM}" \
   && echo "$OUT" | grep -q -- "$HIDDEN_PR_WT"; then
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
if echo "$NONPR_WT_LABEL" | grep -q "detached non-PR"; then
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
if echo "$BRANCH_PR_LABEL" | grep -q "STALE PR #${BRANCH_PR_NUM} (MERGED) branch worktree"; then
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
if echo "$DIRTY_PR_LABEL" | grep -q "working tree is not clean — review manually, keeping"; then
  pass "dirty closed-PR branch worktree surfaced under a review-manually record"
else
  fail "dirty closed-PR branch worktree not surfaced for review (label='$DIRTY_PR_LABEL')"
  show_out_on_fail
fi
if echo "$DIRTY_PR_LABEL" | grep -q "STALE PR"; then
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
if echo "$OUT" | grep -q "uncommitted or untracked content"; then
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
if echo "$OPEN_PR_LABEL" | grep -q "OPEN PR #${OPEN_PR_NUM} — keeping"; then
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
if echo "$IGNORED_PR_LABEL" | grep -q "working tree is not clean — review manually, keeping"; then
  pass "gitignored-only closed-PR branch worktree surfaced under a review-manually record"
else
  fail "gitignored-only worktree not surfaced for review (label='$IGNORED_PR_LABEL')"
  show_out_on_fail
fi
if echo "$IGNORED_PR_LABEL" | grep -q "STALE PR"; then
  fail "gitignored-only worktree wrongly flagged as a removal candidate"
  show_out_on_fail
else
  pass "gitignored-only worktree is NOT a removal candidate"
fi
# The remediation must be TRUE for ignored content: you cannot commit or
# stash a gitignored file, so the dirty-path wording would be wrong advice.
if echo "$OUT" | grep -q "gitignored content only"; then
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
if echo "$SUBMOD_PR_LABEL" | grep -q "working tree is not clean"; then
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
if echo "$PRUNE_PR_LABEL" | grep -q "worktree directory is MISSING — prunable"; then
  pass "missing-directory branch worktree classified prunable"
else
  fail "missing-directory branch worktree mislabeled (label='$PRUNE_PR_LABEL')"
  show_out_on_fail
fi
if echo "$PRUNE_PR_LABEL" | grep -q "not clean"; then
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
if echo "$LOCKMISS_PR_LABEL" | grep -q "LOCKED PR #${LOCKMISS_PR_NUM} (MERGED) worktree directory is MISSING"; then
  pass "locked+missing branch worktree listed under the LOCKED record"
else
  fail "locked+missing branch worktree mislabeled (label='$LOCKMISS_PR_LABEL')"
  show_out_on_fail
fi
if echo "$LOCKMISS_PR_LABEL" | grep -q "prunable"; then
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
if echo "$LOCKED_PR_LABEL" | grep -q "LOCKED PR #${LOCKED_PR_NUM} (CLOSED) branch worktree"; then
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
if echo "$UNKNOWN_PR_LABEL" | grep -q "PR #${UNKNOWN_PR_NUM} state unknown — branch worktree"; then
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
# Case 12 (#739): the hidden-folder merged-PR worktree is removed by the
# same --apply pass as the legacy shape.
if [ -d "$HIDDEN_PR_WT" ] || echo "$OUT3" | grep -q -- "$HIDDEN_PR_WT"; then
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
if [ -d "$BRANCH_PR_WT" ] || echo "$OUT3" | grep -q -- "$BRANCH_PR_WT"; then
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
if [ -f "$IGNORED_CANARY" ] && grep -q "hunter2" "$IGNORED_CANARY"; then
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
if [ -f "$UNTRACKED_CANARY" ] && grep -q "uncommitted analysis" "$UNTRACKED_CANARY"; then
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
if [ -f "$SIGPIPE_CANARY" ] && grep -q "EDITED BEHIND THE FLAG" "$SIGPIPE_CANARY"; then
  pass "index-flag edit survived --apply in a worktree whose ls-files -v exceeds a pipe buffer (${SIGPIPE_BYTES}B)"
else
  fail "DATA LOSS: --apply deleted an index-flag-hidden edit that the SIGPIPE-prone scan missed"
  echo "$OUT2" >&2
fi
if [ -f "$FLAG_CANARY" ] && grep -q "behind an index flag" "$FLAG_CANARY"; then
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
  pass "retained gone-upstream PR-slug worktree is counted in the unclean bucket"
else
  fail "unclean-bucket count is ${UNCLEAN_N:-unset}, expected $EXPECTED_UNCLEAN (seven required retained-unclean fixtures plus the optional submodule index-flag fixture when available) — a retained worktree is landing in an uncounted bucket"
  echo "$OUT3" | grep -E "unclean PR worktrees" >&2
fi
if [ -f "$GONE_PR_CANARY" ] && grep -q "nowhere else" "$GONE_PR_CANARY"; then
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
if [ -f "$SUBMOD_CANARY" ] && grep -q "uncommitted vendor patching" "$SUBMOD_CANARY"; then
  pass "submodule canary survived --apply under diff.ignoreSubmodules=all"
else
  fail "DATA LOSS: --apply deleted untracked submodule content in $SUBMOD_PR_WT"
  echo "$OUT2" >&2
fi

# Case 18 (#762 r2 P3): --apply's trailing `git worktree prune` clears the
# stale administrative entry, so the missing-directory worktree is gone from
# the follow-up dry-run. This is what makes the prunable bucket self-clearing
# (unlike the unclean bucket, which waits on a human).
if echo "$OUT3" | grep -q -- "$PRUNE_PR_WT"; then
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
if echo "$LOCKMISS_APPLY_BLOCK" | grep -q "skipped (locked; pass --force-locked to remove)"; then
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

# Case 20 (#762 r2 P3): the PR-state-unknown branch worktree is never removed.
if [ -d "$UNKNOWN_PR_WT" ]; then
  pass "PR-state-unknown branch worktree retained by --apply"
else
  fail "PR-state-unknown branch worktree was removed despite an unverifiable PR state"
  echo "$OUT2" >&2
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

# Case 2e (#762 post-merge P1): a LOCKED submodule worktree whose only dirt is
# hidden behind a submodule-internal index flag must survive even the force
# fallback. This is the one path where the probe's verdict is decisive: without
# --force-locked, git's own refusal to remove a submodule worktree retains it
# regardless, so the assertion would prove nothing.
if [ "${SUB_OK:-0}" = "1" ]; then
  if [ -f "$SUB_CANARY" ] && grep -q "SUBMODULE EDIT HIDDEN BY INDEX FLAG" "$SUB_CANARY"; then
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
