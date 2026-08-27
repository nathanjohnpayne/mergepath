#!/usr/bin/env bash
# worktree-cleanup.sh — Audit and clean up stale git worktrees left behind
# after PR sessions (closed/merged PRs, gone upstreams, orphaned dirs).
#
# Background. #77 added deploy guards to keep agents from deploying out of
# stale worktrees, but the companion cleanup utility was never landed and
# the cleanup rule in docs/agents/operating-rules.md was purely manual.
# Closed-issue audit (#288) flagged that stale worktrees still accumulate
# silently — detached review worktrees for already-closed PRs under
# /private/tmp/ and /Users/.../GitHub/, plus locked .claude/worktrees/*
# entries whose remotes are long gone. Stale worktrees are not just
# cosmetic; they confuse branch/HEAD reasoning, leave dead generated
# artifacts around, and increase the chance an agent runs commands from a
# dead branch.
#
# This helper provides a read-only audit by default and gates every
# destructive action behind an explicit opt-in flag.
#
# Usage:
#   scripts/worktree-cleanup.sh                       # dry-run (default)
#   scripts/worktree-cleanup.sh --dry-run             # explicit dry-run
#   scripts/worktree-cleanup.sh --apply               # remove safe candidates
#   scripts/worktree-cleanup.sh --apply --force-locked
#                                                     # also remove locked
#   scripts/worktree-cleanup.sh --apply --orphan-clean
#                                                     # also rm -rf orphans
#   scripts/worktree-cleanup.sh --apply --force-locked --orphan-clean
#                                                     # everything
#
# Flags:
#   --dry-run        Default. List candidates with branch/HEAD/state. No
#                    side effects.
#   --apply          Run `git worktree remove <path>` on safe candidates
#                    (gone-upstream worktrees + closed/merged-PR
#                    worktrees that are NOT locked; a branch-attached
#                    PR worktree must also have a clean working tree).
#                    Without further flags, locked worktrees and orphaned
#                    .claude/worktrees/* directories are listed but
#                    skipped.
#   --force-locked   With --apply, also `git worktree remove --force` on
#                    LOCKED worktrees. Locked worktrees may correspond to
#                    in-progress agent sessions, so this flag is opt-in.
#   --orphan-clean   With --apply, also `rm -rf` orphaned directories
#                    under .claude/worktrees/ that have no entry in
#                    `git worktree list --porcelain`. Opt-in because
#                    orphans may be partial work the user wants to keep.
#   --no-color       Disable ANSI colors (auto-disabled when stdout is
#                    not a TTY).
#   -h, --help       Show this help and exit 0.
#
# Detection rules:
#   1. Gone-upstream worktree. `git branch -vv` shows
#      `[origin/<branch>: gone]` for the branch checked out at the
#      worktree. Safe to remove (the remote tracking branch was deleted,
#      typically after a squash-merge + branch delete).
#   2. PR worktree. Worktree path carries a parseable PR number in one
#      of two recognized shapes:
#        a. legacy visible-sibling / temp-dir shape:
#           ^(/private/tmp|/tmp|/Users/.*/GitHub)/mergepath-pr-([0-9]+)$
#        b. the hidden-folder convention from
#           docs/agents/worktree-placement.md — any path whose parent
#           directory is `.mergepath-worktrees` and whose last component
#           is a PR-number-bearing slug `pr-<n>` or `pr-<n>-<desc>`
#           (e.g. ~/GitHub/.mergepath-worktrees/pr-123-fix-login).
#      Cross-check PR state via `gh pr view <num> --json state`; flag as
#      removable if state is CLOSED or MERGED. Worktrees for OPEN PRs
#      are listed but flagged as still-active. Hidden-folder worktrees
#      whose slug does NOT start with `pr-<n>` carry no PR number to
#      cross-check and are never auto-removed (detached ones are listed
#      as detached non-PR; branch-attached ones fall through to rule 1).
#      The slug check applies to BOTH detached and branch-ATTACHED
#      worktrees (#762): the documented `git worktree add <path>
#      <branch>` form creates a branch-attached worktree, so scoping the
#      check to detached HEADs left every convention-following checkout
#      unmatched whenever its remote branch outlived the PR. On the
#      branch-attached side the check is purely ADDITIVE — rule 1 is
#      evaluated first, so nothing that was removable before becomes
#      retained — and removal additionally requires a CLEAN working
#      tree: `git worktree remove` deletes the directory but never the
#      branch ref, so every COMMIT survives regardless, and an EMPTY
#      status is the positive proof that nothing else is lost. "Empty"
#      is measured by worktree_content_state() below, which passes
#      every listing flag EXPLICITLY (see its header): a bare `git
#      status --porcelain` silently omits gitignored paths, omits
#      untracked ones under `status.showUntrackedFiles=no`, and omits
#      dirty submodules under `diff.ignoreSubmodules` — each of which
#      makes a worktree holding real work read as clean while `git
#      worktree remove --force` deletes it all. Anything git reports
#      (tracked, untracked, ignored, or in a submodule), plus an
#      unreadable status, is surfaced for a human and kept.
#   3. Orphaned .claude/worktrees/ directory. Subdirectory under
#      .claude/worktrees/ that is NOT in `git worktree list --porcelain`
#      output. These are residue from a `--force` remove that didn't
#      clean the directory, or from a manual rm of git metadata.
#   4. Verified-merged local branch. A local branch whose upstream is
#      gone and for whose head NAME a MERGED PR exists per `gh pr list
#      --head <branch> --state merged`. The match is by branch head name,
#      NOT an exact tip==headRefOid comparison, so a branch carrying an
#      extra local commit on top of the merged head (e.g. a routine
#      `git merge main`) is still recognized as merged and logged as
#      "local tip diverged from PR head" rather than silently skipped
#      (#605). A branch with NO merged PR for its head name is examined
#      and kept (never deleted). In --apply mode, matched branches that are
#      not checked out in any worktree are deleted with `git branch -D`;
#      checked-out branches are listed but skipped. The worktree snapshot
#      used for the checked-out test is re-taken AFTER the worktree-removal
#      pass so a branch whose worktree was removed earlier in the same
#      --apply run becomes eligible for deletion in that run (#605).
#
#      "gone" per the `%(upstream:track)` atom requires `git fetch
#      --prune` to have already removed the stale
#      `refs/remotes/origin/<branch>` — nothing in this script ever ran
#      `fetch --prune`, so a branch whose remote was deleted on merge (the
#      normal `gh pr merge --delete-branch` shape) kept a live-looking
#      upstream, was never classified `gone`, and was retained
#      indefinitely with no trace in the summary (#822). This script now
#      DETECTS that condition instead of depending on a prior prune:
#      stale_unpruned_branches() probes each non-gone branch's upstream
#      against the remote with `git ls-remote` — a network READ, never a
#      ref mutation — and any branch whose remote-tracking ref is provably
#      stale is reported explicitly, tagged with a reason and counted
#      separately, rather than omitted.
#
#      The probe is dry-run only, and NOTHING here prunes. Making --apply
#      prune (so the class is removed rather than merely reported) is
#      tracked in #932: the `git fetch --prune` route attempted for that
#      was withdrawn because `git fetch` inherits operator configuration
#      (`remote.origin.fetch`, `fetch.pruneTags`, `fetch.recurseSubmodules`)
#      and three consecutive review rounds each found a new key that
#      defeated the namespace confinement it relied on. The replacement is
#      a direct `for-each-ref` / `update-ref -d` diff against the same
#      `ls-remote` snapshot this probe already takes. Until that lands,
#      `--apply` behaves as it always did: it acts only on branches the
#      operator's own prune has already marked gone.
#
#      NOTE this is a DIFFERENT hazard from the squash-merge one under
#      "Merged-state detection" below: an unpruned ref is a detection gap
#      on the "gone" SIGNAL; ancestry-vs-squash is a detection gap on the
#      "merged" SIGNAL. Fixing one does not touch the other, and both must
#      hold for a branch to be provably safe to delete.
#
# Locked detection. `git worktree list --porcelain` emits a `locked`
# line (possibly with a reason) for locked entries. We classify locked
# worktrees separately so --apply doesn't disrupt active sessions.
#
# Merged-state detection: a squash-merged branch is NOT an ancestor of
# main, so ancestry is not a merge test (#822). This repo squash-merges,
# which means a merged branch's own commits never enter main's history and
# `git rev-list --count origin/main..<branch>` stays permanently non-zero
# long after its PR demonstrably merged — observed at "3 commits not in
# main" for a branch whose PR was merged and whose remote branch had
# already been deleted. Every "is this merged?" decision in this script
# therefore comes from PR state via gh_branch_merged_pr_status() (`gh pr
# list --head <branch> --state merged`, comparing the merged PR's recorded
# headRefOid against the local tip), never from ancestry against main. An
# ancestry-against-main test is the natural thing to reach for and it is
# wrong here: it reads as a confident "unmerged, do not touch" and would
# retain every squash-merged branch forever. The ancestry check that DOES
# exist in gh_branch_merged_pr_status() is a different comparison — local
# tip vs the MERGED PR's head, not vs main — and it only distinguishes
# `exact` from `diverged` once PR state has already established that a
# merged PR exists. The same hazard, stated for anyone writing separate
# cleanup tooling, is in docs/agents/worktree-placement.md § Relocating
# and removing.
#
# Exit codes:
#   0  in a DRY RUN, the audit completed and found nothing actionable.
#      Under --apply it means only that no attempted removal FAILED — locked
#      entries, orphans, dirty closed-PR worktrees and diverged branches can
#      all still be present, because --apply deliberately never touches them
#      without their opt-in flags or a human decision. A successful apply is
#      NOT a clean audit; run the dry run to learn whether the tree is clean
#      (Codex P2 on #1105).
#   1  generic error (bad invocation, git failure, unsupported state)
#   2  a COMPLETE audit with actionable findings (dry-run). Lets callers
#      wire this into "audit fails CI" style checks even though we
#      explicitly do NOT wire this into PR CI per #288.
#      Note what 2 does NOT promise: that a plain --apply clears it. Several
#      buckets exit 2 and are deliberately never cleared by the default
#      apply mode — SUMMARY_DIVERGED_KEPT and SUMMARY_UNCLEAN_KEPT need a
#      HUMAN decision and --apply never touches them, and locked entries and
#      orphans need --force-locked / --orphan-clean. 2 means "everything
#      that could be checked was checked, and some of it wants attention";
#      the per-record lines say what kind (Codex P2 on #1105).
#   3  an INCOMPLETE audit: a step it depends on FAILED in a way that would
#      otherwise be INVISIBLE, so one of the report's silences is not
#      evidence (#992).
#      The 2-versus-3 axis is COMPLETENESS, not who can act. A 2 may still
#      need a human; a 3 says the run does not know what it is looking at.
#      Callers that only branch on 2 are unaffected; callers that treat any
#      non-zero as actionable still see it.
#      The qualifying steps are the ones by which stale_unpruned_branches()
#      EVALUATES — entering the main worktree, reading the local branch list,
#      allocating and writing the eligible-branch list, taking the
#      remote-heads snapshot, and allocating and writing that snapshot. It is
#      NOT only the network read: a full TMPDIR or an unreadable ref database
#      reaches the same arm, and the NOT MEASURED line names which. The probe
#      is dry-run only, so --apply never exits 3.
#      Persisting the probe's RESULT is deliberately outside this contract;
#      that write fails loudly rather than silently (#1115). The canonical
#      statement is specs/worktree_cleanup_audit.md — keep it, this block and
#      docs/agents/operating-rules.md in step.
#
# Notes:
#   - Always invoked from within a git repo (the main one or a worktree).
#     The helper resolves the common-dir so it discovers all worktrees
#     regardless of which worktree it was invoked from.
#   - Read-only by default. The `gh pr view` cross-check is also read-only
#     (a single GET per detached candidate); if `gh` is not available or
#     the call fails, the candidate is listed as "PR state unknown" rather
#     than removed.
#   - This is a local-audit helper. Worktree state is machine-local and
#     should not gate repository CI — see #288's acceptance criteria.

set -eo pipefail

# ── Flag parsing ──────────────────────────────────────────────────────
MODE="dry-run"
FORCE_LOCKED=0
ORPHAN_CLEAN=0
USE_COLOR=1

show_help() {
  sed -n '2,/^set -eo pipefail$/p' "$0" | sed -e 's/^#\{0,1\} \{0,1\}//' -e '$d'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       MODE="dry-run" ;;
    --apply)         MODE="apply" ;;
    --force-locked)  FORCE_LOCKED=1 ;;
    --orphan-clean)  ORPHAN_CLEAN=1 ;;
    --no-color)      USE_COLOR=0 ;;
    -h|--help)       show_help; exit 0 ;;
    *)
      echo "worktree-cleanup.sh: unknown argument: $1" >&2
      echo "Run 'worktree-cleanup.sh --help' for usage." >&2
      exit 1
      ;;
  esac
  shift
done

if [ ! -t 1 ]; then
  USE_COLOR=0
fi

if [ "$USE_COLOR" = "1" ]; then
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED=""; C_YELLOW=""; C_GREEN=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

# ── Locate repo ───────────────────────────────────────────────────────
if ! git rev-parse --git-common-dir >/dev/null 2>&1; then
  echo "worktree-cleanup.sh: not inside a git repository" >&2
  exit 1
fi

GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
# Find the toplevel of the MAIN worktree (not the current worktree, which
# may itself be one of the candidates we want to clean up). The main
# worktree's gitdir is GIT_COMMON_DIR's parent.
MAIN_WORKTREE=$(cd "$GIT_COMMON_DIR/.." && pwd)

# ── Helpers ───────────────────────────────────────────────────────────
gh_pr_state() {
  # Print PR state (OPEN/CLOSED/MERGED) or "unknown" if gh is missing or
  # the call fails. Single-shot, no retries — dry-run is meant to be
  # cheap.
  local num="$1"
  if ! command -v gh >/dev/null 2>&1; then
    echo "unknown"
    return 0
  fi
  local state
  if state=$(gh pr view "$num" --repo nathanjohnpayne/mergepath --json state --jq .state 2>/dev/null); then
    if [ -n "$state" ]; then
      echo "$state"
      return 0
    fi
  fi
  echo "unknown"
}

# Print the PR number carried by a worktree PATH, or nothing when the path
# carries none. Recognizes both shapes named in Detection rule 2: the legacy
# `<root>/mergepath-pr-<n>` sibling/temp shape, and the hidden-folder
# `.mergepath-worktrees/pr-<n>[-<desc>]` convention. The hidden folder is
# matched by its directory NAME rather than a hardcoded ~/GitHub prefix so
# the matcher follows the folder wherever the operator keeps repos.
# Shared by the detached and branch-attached paths so the two cannot drift.
worktree_pr_num() {
  local path="$1"
  if [[ "$path" =~ ^(/private/tmp|/tmp|/Users/[^/]+/GitHub)/mergepath-pr-([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  elif [[ "$path" =~ /\.mergepath-worktrees/pr-([0-9]+)(-[A-Za-z0-9._-]+)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Positive-evidence gate for removing a BRANCH-ATTACHED worktree. Prints one
# of four states and exits 0 ONLY for `clean`:
#
#   clean    git reports NOTHING for the directory — no tracked modifications,
#            no untracked files, and no gitignored content.
#   dirty    git reports something: tracked modifications, untracked files,
#            and/or gitignored content. Also covers an unreadable status (a
#            path git will not report on) — fail closed.
#   ignored  git reports ONLY gitignored entries (`!!`). Split out from
#            `dirty` purely so the operator gets a TRUE remediation: you
#            cannot commit or stash a gitignored file.
#   missing  the registered directory does not exist. Nothing to preserve —
#            this is a PRUNABLE administrative entry, not lost work. Split
#            out so it never inherits `dirty`'s "commit, stash, or discard
#            it by hand" advice, which would be nonsense for a path that is
#            not there (#762 r2 P3).
#
# `git worktree remove` deletes the directory but never the branch ref, so
# every COMMIT the branch holds survives the removal whether or not it is
# merged; the only content that would be destroyed is what lives solely in
# the working tree. An EMPTY status is therefore the proof that removal loses
# nothing — but only when the status includes IGNORED paths. Plain `git status
# --porcelain` omits them, so a worktree whose only content is `.env`,
# `*.key`, `.claude/settings.local.json` or `node_modules/` reads as clean and
# `git worktree remove` destroys it (verified: this happens with AND without
# `--force`, so git's own dirty check is no backstop) — #762 r2 P2.
#
# All THREE listing flags are passed EXPLICITLY so operator configuration
# cannot weaken a safety check. They are mutually independent — none implies
# any other — and each closes a distinct "reports empty, is not empty" hole:
#
#   --ignored                 gitignored content, per the paragraph above.
#   --untracked-files=all     `status.showUntrackedFiles=no` (repo or global)
#                             suppresses `??` records, so a worktree full of
#                             untracked work reports an EMPTY status and this
#                             helper would call it `clean` — `--apply` then
#                             deletes it. The `all` form additionally expands
#                             directories, so an untracked directory cannot
#                             hide its contents behind one summary entry
#                             (#762 r3 P1).
#   --ignore-submodules=none  `diff.ignoreSubmodules=all` (or `=dirty`, or a
#                             per-submodule `submodule.<name>.ignore=all`)
#                             suppresses the ` M <sub>` record for an
#                             INITIALIZED submodule holding untracked or
#                             uncommitted work, so the same empty-status
#                             false-clean applies. Verified end to end: with
#                             `diff.ignoreSubmodules=all` the probe returned
#                             empty, and `git worktree remove --force` — the
#                             exact form try_remove() runs — deleted the
#                             worktree and the submodule's untracked files
#                             with it. git's own "working trees containing
#                             submodules cannot be moved or removed" refusal
#                             is NOT a backstop: it only fires WITHOUT
#                             `--force` (#762 r3 P2).
#
# `--ignore-submodules=none` costs nothing on a submodule-free checkout (this
# repo has none) and does not manufacture false positives: a genuinely clean
# worktree with an initialized submodule still reports empty with the flag.
worktree_content_state() {
  local path="$1" status
  if [ ! -d "$path" ]; then
    echo "missing"
    return 1
  fi
  if ! status=$(git -C "$path" status --porcelain --ignored --untracked-files=all --ignore-submodules=none 2>/dev/null); then
    echo "dirty"
    return 1
  fi

  # Index flags defeat porcelain entirely (#762 r4 P1). A tracked file marked
  # `assume-unchanged` (ls-files -v tag: any LOWERCASE letter) or
  # `skip-worktree` (tag `S`) is skipped by the status walk, so an edited file
  # reports nothing and `git worktree remove` deletes it — verified directly,
  # including without --force, because git consults the same flags. There is no
  # status flag that overrides this, so the flags themselves are the signal:
  # any flagged path means the comprehensive status CANNOT be trusted as proof.
  #
  # The scan uses a HERE-STRING, not `printf … | grep -q`. Under this script's
  # `pipefail`, `grep -q` exits on its first match, `printf` then dies of
  # SIGPIPE (141), and the pipeline reports failure — so the `if` reads FALSE
  # exactly when a flag WAS found. The inversion needs the listing to exceed a
  # pipe buffer, which a large worktree easily does. Measured: with a flagged
  # entry first in a ~3.5 MB listing, the pipeline form returns 141 and misses
  # it while the here-string form detects it.
  local flagged
  if flagged=$(git -C "$path" ls-files -v 2>/dev/null); then
    if grep -qE '^([a-z]|S) ' <<<"$flagged"; then
      echo "dirty"
      return 1
    fi
  else
    # Unreadable index — no proof available, so do not claim clean.
    echo "dirty"
    return 1
  fi

  # A submodule's OWN .gitignore hides its ignored files from the superproject
  # walk even with --ignored --ignore-submodules=none, so probe inside each
  # initialized submodule with the same comprehensive flags (#762 r4 P1).
  # `submodule foreach` is a no-op (exit 0, no output) on the submodule-free
  # checkouts this tool actually runs against, so this costs nothing here.
  # The submodule probe mirrors the TOP-LEVEL one exactly, index flags
  # included. A file inside a submodule marked `assume-unchanged` /
  # `skip-worktree` and then edited is invisible to both the outer status walk
  # AND the recursive one, so the worktree read as clean; with
  # `--apply --force-locked` the non-force attempt refuses (submodules), the
  # force fallback then deletes the worktree and the hidden edit with it, and
  # the run exits successfully. Same blind spot as the top level, one level
  # down (#762 post-merge P1).
  #
  # It also fails CLOSED now: a submodule whose status or index cannot be read
  # exits non-zero from `foreach`, which is treated as dirty rather than
  # skipped. The inner `grep` deliberately omits `-q` so it consumes all input
  # — the same SIGPIPE trap as above, and `foreach` runs under `sh`, where
  # pipefail is not inherited, so a silent miss there would be even harder to
  # spot.
  local sub_probe sub_rc
  set +e
  # shellcheck disable=SC2016  # intentional: $st/$fl are expanded by the `sh` that `submodule foreach` runs, not here
  sub_probe=$(git -C "$path" submodule foreach --recursive --quiet '
    st=$(git status --porcelain --ignored --untracked-files=all) || exit 1
    fl=$(git ls-files -v) || exit 1
    printf %s "$st"
    printf %s "$fl" | grep -E "^([a-z]|S) "
    exit 0
  ' 2>/dev/null)
  sub_rc=$?
  set -e
  if [ "$sub_rc" -ne 0 ] || [ -n "$sub_probe" ]; then
    echo "dirty"
    return 1
  fi
  if [ -z "$status" ]; then
    echo "clean"
    return 0
  fi
  # Only `!!` records → gitignored content and nothing else. Here-string for
  # the same SIGPIPE reason as the index-flag scan: `grep -qv` stops at the
  # first non-`!!` line, and under pipefail the resulting 141 would flip this
  # negated test, reporting `ignored` for a genuinely dirty worktree. Both
  # states are retained, so this is a wrong REMEDIATION rather than data loss —
  # it would tell an operator "gitignored content only, move it by hand" about
  # a worktree holding uncommitted work.
  if ! grep -qv '^!! ' <<<"$status"; then
    echo "ignored"
    return 1
  fi
  echo "dirty"
  return 1
}

# Classify a local branch against its merged PRs by HEAD *name* (not by an
# exact tip==headRefOid match). Prints one of:
#   exact     — a merged PR exists for this branch name AND its recorded
#               headRefOid equals the branch tip (clean squash-merge, no
#               local commits on top).
#   diverged  — a merged PR exists for this branch name AND the merged head is
#               an ANCESTOR of the tip, but the tip carries EXTRA commit(s) on
#               top (e.g. a `git merge main` housekeeping commit, OR unmerged
#               follow-up work). The caller SURFACES these for manual review and
#               NEVER auto-deletes them: descending from the old PR head only
#               proves the old PR is in history, not that the extra commits are
#               already merged/safe (Codex P1). The ancestry requirement also
#               guards against a REUSED branch name whose old PR merged but
#               whose current tip is unrelated new work.
#   none      — the lookup SUCCEEDED and either no merged PR exists for this
#               branch name, or no merged head is an ancestor of the tip
#               (reused name). NEVER treat as merged.
#   unknown   — the lookup FAILED (gh missing, ref unresolvable, or `gh pr
#               list` errored). Not a verified "no merged PR" — the caller
#               surfaces it as NOT EVALUATED rather than examined-not-merged
#               (Codex P2: auth/API failures must stay visible).
# Exit status: 0 for exact|diverged, 1 for none|unknown. Only `exact` is
# auto-deleted; `diverged` is surfaced-and-kept; `none`/`unknown` are kept.
#
# Rationale (#605 root cause 2): the prior `grep -Fxq "$tip"` required an
# exact tip==headRefOid match, so any branch carrying a commit beyond the PR
# head silently failed the check and the caller `continue`d with NO output —
# invisible in both the listing and the summary. Falling back to a name-based
# existence check keeps the fail-safe contract (a merged PR for this head name
# must actually exist) while surfacing the diverged case with a CLEAR log line
# instead of a silent skip.
gh_branch_merged_pr_status() {
  local branch="$1" tip merged_heads
  # `unknown` ≠ `none`: a missing gh, an unresolvable ref, or a failed
  # `gh pr list` call is a VERIFICATION FAILURE, not a verified "no merged
  # PR". Collapsing the two would report gone branches on a gh-less /
  # unauthenticated machine as "examined, not merged" when they were never
  # actually evaluated — the exact evaluated-vs-not-evaluated distinction
  # #605 requires (Codex P2). Both keep the branch; only the label differs.
  if ! command -v gh >/dev/null 2>&1; then
    echo "unknown"
    return 1
  fi
  # A local tag may legally share this branch's short name. Resolve the
  # branch ref explicitly: a bare revision name can prefer the tag, which
  # would make an unmerged commit on the branch look like the merged tag tip
  # and permit a destructive `git branch -D`.
  tip=$(git -C "$MAIN_WORKTREE" rev-parse --verify "refs/heads/$branch" 2>/dev/null) || { echo "unknown"; return 1; }
  merged_heads=$(cd "$MAIN_WORKTREE" && gh pr list --head "$branch" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null) || { echo "unknown"; return 1; }
  # Successful lookup, no merged PR for this head name → not safe to delete.
  if [ -z "$merged_heads" ]; then
    echo "none"
    return 1
  fi
  if printf '%s\n' "$merged_heads" | grep -Fxq "$tip"; then
    echo "exact"
    return 0
  fi
  # diverged: a merged PR exists for this head NAME but the tip is not one of
  # the merged heads. Only safe to delete when the tip actually DESCENDS from a
  # merged head — confirm with `git merge-base --is-ancestor`. Without this, a
  # REUSED branch name (its old PR merged, but the current local tip is
  # UNRELATED new work that was never merged) would be classified diverged and
  # deleted, losing unmerged work (CodeRabbit Major). If no merged head is an
  # ancestor of the tip, treat as `none` (keep — fail-safe).
  local mh
  while IFS= read -r mh; do
    [ -n "$mh" ] || continue
    if git -C "$MAIN_WORKTREE" merge-base --is-ancestor "$mh" "$tip" 2>/dev/null; then
      echo "diverged"
      return 0
    fi
  done <<EOF
$merged_heads
EOF
  echo "none"
  return 1
}

# Read gone-upstream branches.
#
# This reads `for-each-ref`'s plumbing output, NOT `git branch -vv`. The
# porcelain listing is a human-facing rendering and parsing it is wrong twice
# over (both measured on git 2.50.1, Phase 4b review on #892):
#
#   * Color. Under `color.branch=always` — a legal user setting, and one that
#     survives into non-tty output by design — every line carries ANSI escapes:
#     `  gonebr<ESC>[m 845fcdb [<ESC>[34morigin/gonebr<ESC>[m: gone] seed`. The
#     first whitespace token is then `gonebr<ESC>[m`, not `gonebr`, so --apply
#     silently operates on a branch name that does not exist while dry-run,
#     which reaches the same branches through `ls-remote`, still finds them.
#   * `]` in a branch name. `]` is NOT forbidden by check-ref-format (only `[`
#     is), so `topic]` is a legal branch, and it renders as
#     `[origin/topic]: gone]`. A `\[[^]]*: gone\]` marker test cannot match
#     that, so the branch is dropped from the sweep in apply mode right after
#     the prune removed its tracking ref.
#
# `%(upstream:track)` emits exactly `[gone]` for a gone upstream and is
# unaffected by both: verified emitting bare `topic] [gone]` under
# `color.branch=always`. It also carries no `* ` / `+ ` list marker, so the
# leading-plus ambiguity that the porcelain parser had to special-case does
# not arise. A branch name cannot contain a space (check-ref-format), so the
# trailing tracking atom is unambiguous to strip.
#
# The name comes from `%(refname:lstrip=2)`, NOT `%(refname:short)`: `:short`
# shortens only as far as stays unambiguous, so when a TAG shares the branch's
# name it yields `heads/<branch>` instead of `<branch>` — which is exactly the
# branch/tag short-name collision Case 26 guards against. `lstrip=2` drops the
# literal `refs/heads/` prefix and nothing else.
#
# An unreadable inventory is NOT an empty one (#920 finding 1).
# `%(upstream:track)` makes git resolve every branch's upstream through
# `remote.origin.fetch`, and `git config` stores refspecs it never validates:
# a stored `refs/heads/main:refs/remotes/origin/*` — wildcard DESTINATION, no
# wildcard in the source — is a pair git rejects, so for-each-ref exits 128
# with `fatal: invalid refspec` for the repository as a whole. Before this
# guard that 128 travelled the pipeline through `pipefail` into `set -e` and
# killed the audit with NO output and no diagnostic; the operator saw an empty
# terminal and a bare exit 128. Fail closed the way worktree_records() already
# does for its porcelain read — name the failure and return non-zero, so the
# caller aborts instead of reading an empty $GONE_FILE as "nothing is gone".
gone_branches() {
  cd "$MAIN_WORKTREE" || {
    echo "worktree-cleanup.sh: error: could not enter the main worktree to enumerate branch tracking state" >&2
    return 1
  }
  local branch_state branch_state_rc=0
  branch_state=$(LC_ALL=C git for-each-ref \
    --format='%(refname:lstrip=2) %(upstream:track)' refs/heads/ 2>/dev/null) \
    || branch_state_rc=$?
  if [ "$branch_state_rc" -ne 0 ]; then
    echo "worktree-cleanup.sh: error: could not read local branch tracking state (git for-each-ref exit ${branch_state_rc}) — check \`git config --get-all remote.origin.fetch\` for a refspec git rejects" >&2
    return 1
  fi
  printf '%s\n' "$branch_state" | awk '
    {
      # Trailing field is the tracking atom; the name is everything before it.
      if ($NF == "[gone]") {
        name = $0
        sub(/[ \t]+\[gone\][ \t]*$/, "", name)
        if (name != "") { print name }
      }
    }
  '
}

# Return success when origin's configured fetch refspecs are exactly the
# conventional default, `[+]refs/heads/*:refs/remotes/origin/*`.
#
# stale_unpruned_branches() below has to answer "which remote head populates
# refs/remotes/origin/<name>?", and only `remote.origin.fetch` knows. A
# repository may map `refs/heads/release:refs/remotes/origin/stable`, may
# exclude heads with a negative `^refs/heads/<pat>` refspec, or may map into
# refs/heads/* entirely. Under any of those, a tracking ref's absence from
# `git ls-remote --heads origin` under the conventional name is NOT evidence
# that the remote branch was deleted.
#
# Rather than reimplement git's refspec matching to cover those cases, the
# probe declines to evaluate them: a non-default configuration reports
# nothing and the audit behaves exactly as it did before #822. That is the
# fail-closed direction — the cost is a missed report, never a wrong one.
# #932 revisits whether the restriction can lift once the prune mechanism it
# was written against is replaced.
origin_fetch_is_conventional() {
  local refspec count=0
  while IFS= read -r refspec; do
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    case "${refspec#+}" in
      'refs/heads/*:refs/remotes/origin/*') ;;
      *) return 1 ;;
    esac
  done < <(git -C "$MAIN_WORKTREE" config --get-all remote.origin.fetch 2>/dev/null || true)
  [ "$count" -eq 1 ]
}

# Detect local branches whose upstream tracks `origin/<name>` but which
# `%(upstream:track)` does NOT (yet) mark `gone` — because the remote-tracking
# ref refs/remotes/origin/<name> is stale, not because the remote branch
# still exists (#822). Nothing in this script prunes (see the rule-4 header
# and #932), so this probe is the whole of the fix: a pure network READ
# (`git ls-remote`), never a local ref write, so it preserves the
# read-only-by-default contract while still surfacing the condition instead
# of silently omitting the branch.
#
# Requires $GONE_FILE (is_gone_branch()) to already be populated, so callers
# must invoke this AFTER `gone_branches >"$GONE_FILE"`.
#
# ONE remote round-trip per run, not one per branch (Codex P2 on #892). The
# remote's head refs are snapshotted with a single `git ls-remote --heads
# origin` and every membership question is then answered locally. Querying
# per branch made a plain dry-run an N-round-trip operation — 36 connections
# on this repo's own checkout — which against an SSH or high-latency remote
# turns a local audit into a minutes-long, possibly repeatedly-authenticating
# one.
#
# Failure semantics, mirroring gh_branch_merged_pr_status()'s unknown/none
# distinction:
#   ls-remote exit 0   → the query SUCCEEDED; the printed refs are the whole
#                        truth about the remote's heads. A branch absent from
#                        that set is confirmed deleted → report it. Exit 0
#                        with EMPTY output is a successful query against a
#                        remote with no heads at all — unusual but real, and
#                        it correctly makes every tracking branch stale.
#   any other exit     → the query FAILED (no network, auth failure, unknown
#                        remote). Not evidence any branch was deleted: report
#                        nothing, AND record the state as `unknown` (#992).
#
# Reporting nothing is fail-closed for CLASSIFICATION but fail-OPEN for the
# AUDIT, and the second half is what #992 is about. With the failure
# unrecorded, an unreachable remote rendered identically to a clean tree:
# `gone (stale remote ref, unpruned): 0`, nothing on stderr, exit 0. The
# preview then claimed an agreement with --apply that it had never been able
# to model — and --apply, run later with working network, acts on a
# classification the preview never showed. That is the same class as the
# gone_branches() defect #991 fixed for the LOCAL branch inventory (an
# unreadable read reported as an empty one), applied to the remote read.
#
# $STALE_SNAPSHOT_STATE tells the caller which of three things happened:
#   ok        the snapshot was taken; the reported set is authoritative
#   declined  a non-conventional remote.origin.fetch — deliberately not
#             evaluated, a documented limitation with a stable answer
#   unknown   the read failed; nothing is known either way
#
# `declined` is deliberately NOT `unknown`. It is a standing, documented
# limitation rather than a transient failure, and collapsing the two would
# put every non-conventional checkout at a permanent exit 3 — repeating the
# mistake the SUMMARY_LOOKUP_UNKNOWN carve-out below exists to avoid.
stale_unpruned_branches() {
  cd "$MAIN_WORKTREE" || {
    STALE_SNAPSHOT_STATE="unknown"
    STALE_SNAPSHOT_CAUSE="refs"
    STALE_SNAPSHOT_REASON="cannot enter the main worktree"
    return 0
  }
  # A non-default refspec makes the tracking-ref → remote-head mapping
  # unknowable here; decline rather than guess (origin_fetch_is_conventional).
  origin_fetch_is_conventional || { STALE_SNAPSHOT_STATE="declined"; return 0; }
  # Decide ELIGIBILITY before touching the network (Codex P2 on #1105).
  #
  # A repository can have a conventional refspec and an `origin` while no
  # local branch tracks `refs/remotes/origin/*` at all — an origin added to a
  # local-only checkout is the ordinary case. The stale set is then provably
  # empty from local reads alone, and consulting the remote can only fail for
  # a question nobody asked. Taking the snapshot first made an unreachable
  # origin turn such a run into an incomplete audit (exit 3) on the strength
  # of an irrelevant read.
  #
  # So: build the eligible list from `for-each-ref` and $GONE_FILE, both
  # purely local, and consult the remote only if that list is non-empty. An
  # empty list is `ok` and not `unknown` — the answer IS known, and it is
  # "nothing", established without the remote having any say.
  ELIGIBLE_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-eligible.XXXXXX") || {
    STALE_SNAPSHOT_STATE="unknown"
    STALE_SNAPSHOT_CAUSE="storage"
    STALE_SNAPSHOT_REASON="could not create the eligible-branch list (temporary storage unavailable)"
    return 0
  }
  local branch upstream
  # Tab-separated: a git ref name may contain `|` but never a tab, so the
  # pair round-trips losslessly (the same reasoning as the merged-branch
  # sweep records).
  #
  # `refname:lstrip=2` expands an ambiguous local branch name to
  # `heads/<name>` when a tag shares its short name. The input is already
  # constrained to refs/heads, so strip that namespace directly and retain
  # the canonical branch name for the gone/PR lookups downstream.
  #
  # Derive the remote head from the FULL %(upstream) ref, never from
  # %(upstream:short) — when a local branch literally named `origin/foo`
  # exists, `:short` renders foo's upstream as `remotes/origin/foo` and the
  # derived head name comes out wrong.
  # Checked for the same reason the snapshot write below is (Codex P2 on
  # #1105, the direct twin of that one): `mktemp` created the file, it did
  # not promise the write will land. Unchecked, a full TMPDIR trips
  # `set -eo pipefail` here and the run dies with a bare `printf: write
  # error` and exit 1 — before any summary, so the documented local
  # NOT MEASURED / exit 3 path never runs.
  #
  # The redirect is owned by a trailing `cat`, NOT by the brace group, and
  # that detail is load-bearing. Measured on bash 3.2 and 5.x:
  #
  #   if ! { ...; } >BAD          -> status 0   (the failure is MISSED)
  #   if ! { ...; } | cat >BAD    -> status 1   (caught)
  #   if ! printf | awk >BAD      -> status 1   (caught — the snapshot shape)
  #
  # A redirection failure on a COMPOUND command does not make the `if`
  # condition false: bash reports the error, skips the group, and the
  # condition evaluates as success. The first draft of this guard was written
  # that way and never fired — the run printed a clean summary and exit 0
  # while its own eligible list had gone nowhere. Routing the write through a
  # simple command makes the status reflect it.
  # The git READ is taken first, on its own, so its failure is attributable
  # (Codex P2 on #1105). Folding it into the write pipeline made `pipefail`
  # surface an unreadable local ref database as `temporary storage
  # unavailable`, which sent the operator to check TMPDIR for a problem in
  # the repository. That is the cause-specific-remedy rule this PR added,
  # broken inside the guard that introduced it: a wrong remedy is worse than
  # a vague one because it looks actionable.
  local branch_pairs
  if ! branch_pairs=$(git for-each-ref \
       --format='%(refname:lstrip=2)%09%(upstream)' refs/heads/ 2>/dev/null); then
    STALE_SNAPSHOT_STATE="unknown"
    STALE_SNAPSHOT_CAUSE="refs"
    STALE_SNAPSHOT_REASON="could not read the local branch list (git for-each-ref failed)"
    rm -f "$ELIGIBLE_FILE"
    ELIGIBLE_FILE=""
    return 0
  fi
  # Now only the WRITE can fail here, so the temp-storage reason is accurate.
  #
  # The redirect is owned by a trailing `cat`, NOT by the brace group, and
  # that detail is load-bearing. Measured on bash 3.2 and 5.x:
  #
  #   if ! { ...; } >BAD          -> status 0   (the failure is MISSED)
  #   if ! { ...; } | cat >BAD    -> status 1   (caught)
  #   if ! printf | awk >BAD      -> status 1   (caught — the snapshot shape)
  #
  # A redirection failure on a COMPOUND command does not make the `if`
  # condition false: bash reports the error, skips the group, and the
  # condition evaluates as success. An earlier draft of this guard was
  # written that way and never fired — the run printed a clean summary and
  # exit 0 while its own eligible list had gone nowhere. Routing the write
  # through a simple command makes the status reflect it.
  if ! {
    printf '%s\n' "$branch_pairs" |
    while IFS=$'\t' read -r branch upstream; do
      [ -n "$branch" ] || continue
      case "$upstream" in
        refs/remotes/origin/*) ;;
        *) continue ;;
      esac
      is_gone_branch "$branch" && continue
      printf '%s\t%s\n' "$branch" "refs/heads/${upstream#refs/remotes/origin/}"
    done
  } | cat >"$ELIGIBLE_FILE"; then
    STALE_SNAPSHOT_STATE="unknown"
    STALE_SNAPSHOT_CAUSE="storage"
    STALE_SNAPSHOT_REASON="could not write the eligible-branch list (temporary storage unavailable)"
    rm -f "$ELIGIBLE_FILE"
    ELIGIBLE_FILE=""
    return 0
  fi
  if [ ! -s "$ELIGIBLE_FILE" ]; then
    STALE_SNAPSHOT_STATE="ok"
    rm -f "$ELIGIBLE_FILE"
    ELIGIBLE_FILE=""
    return 0
  fi

  local snapshot snapshot_rc=0
  snapshot=$(git ls-remote --heads origin 2>/dev/null) || snapshot_rc=$?
  if [ "$snapshot_rc" -ne 0 ]; then
    STALE_SNAPSHOT_STATE="unknown"
    STALE_SNAPSHOT_CAUSE="remote"
    STALE_SNAPSHOT_REASON="git ls-remote --heads origin exited $snapshot_rc"
    rm -f "$ELIGIBLE_FILE"
    ELIGIBLE_FILE=""
    return 0
  fi
  STALE_SNAPSHOT_STATE="ok"
  # Trap-visible global, not a `local` (#920 finding 2): under `set -e` any
  # failure between mktemp and the inline `rm -f` below — a broken pipe, a
  # SIGINT — exits without ever reaching the removal and leaks the file.
  HEADS_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-remoteheads.XXXXXX") || {
    # The snapshot was taken but cannot be held, and the observable result is
    # the same as a failed query: nothing reported. It must therefore carry
    # the same state, or it becomes this issue's silent-clean case one level
    # further down.
    STALE_SNAPSHOT_STATE="unknown"
    STALE_SNAPSHOT_CAUSE="storage"
    STALE_SNAPSHOT_REASON="could not create the remote-heads snapshot file (temporary storage unavailable)"
    return 0
  }
  # `<sha>\t<refname>` per line; keep the refname column only.
  # Checked, not bare (Codex P2 on #1105). mktemp succeeding says the file
  # was CREATED, not that it can be written: TMPDIR can fill, or a quota can
  # be exhausted, between the two. Left unchecked this pipeline trips
  # `set -eo pipefail` and kills the run with exit 1 BEFORE the summary is
  # printed — no records, no NOT MEASURED line, no exit 3, which is precisely
  # the silent-failure shape this PR exists to remove, reappearing one line
  # further down.
  if ! printf '%s\n' "$snapshot" | awk -F'\t' 'NF > 1 { print $2 }' >"$HEADS_FILE"; then
    STALE_SNAPSHOT_STATE="unknown"
    STALE_SNAPSHOT_CAUSE="storage"
    STALE_SNAPSHOT_REASON="could not write the remote-heads snapshot (temporary storage unavailable)"
    rm -f "$HEADS_FILE"
    HEADS_FILE=""
    rm -f "$ELIGIBLE_FILE"
    ELIGIBLE_FILE=""
    return 0
  fi
  # The eligible list was already resolved above; each record carries the
  # branch and the remote head that populates its tracking ref, so this pass
  # is a pure membership test against the snapshot.
  local remote_head
  while IFS=$'\t' read -r branch remote_head; do
    # Exact full-path match: `-Fx` so a branch named `feat` is never
    # satisfied by the remote having `feature`.
    grep -Fxq -- "$remote_head" "$HEADS_FILE" && continue
    echo "$branch"
  done <"$ELIGIBLE_FILE"
  rm -f "$ELIGIBLE_FILE"
  ELIGIBLE_FILE=""
  rm -f "$HEADS_FILE"
  HEADS_FILE=""
}

# Parse `git worktree list --porcelain -z` into NUL-delimited six-field
# records: PATH, BRANCH_OR_DETACHED, DETACHED(0/1), HEAD, LOCKED(0/1),
# LOCK_REASON. Git ref names may contain `|`, and worktree paths and lock
# reasons may contain any printable delimiter, so pipe/tab records are not
# lossless. NUL is the one byte Git path/ref data cannot carry.
# BRANCH is the short ref name (without refs/heads/) or empty for detached;
# DETACHED is "1" iff the entry was marked detached.
worktree_records() {
  local line path branch detached head locked lock_reason ref
  cd "$MAIN_WORKTREE" || return 1
  # Trap-visible global, not a `local` (#920 finding 2): see HEADS_FILE above.
  RECORDS_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-worktree-records.XXXXXX") || {
    echo "worktree-cleanup.sh: error: could not create a temporary worktree-record snapshot" >&2
    return 1
  }
  if ! git worktree list --porcelain -z >"$RECORDS_FILE" 2>/dev/null; then
    rm -f "$RECORDS_FILE"
    RECORDS_FILE=""
    echo "worktree-cleanup.sh: error: could not read git worktree porcelain records" >&2
    return 1
  fi
  path=""; branch=""; detached="0"; head=""; locked="0"; lock_reason=""
  while IFS= read -r -d '' line; do
    case "$line" in
      "")
        if [ -n "$path" ]; then
          printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
            "$path" "$branch" "$detached" "$head" "$locked" "$lock_reason"
        fi
        path=""; branch=""; detached="0"; head=""; locked="0"; lock_reason=""
        ;;
      worktree\ *) path=${line#worktree } ;;
      HEAD\ *) head=${line#HEAD } ;;
      branch\ *)
        ref=${line#branch }
        branch=${ref#refs/heads/}
        ;;
      detached) detached="1" ;;
      locked*)
        locked="1"
        lock_reason=${line#locked}
        lock_reason=${lock_reason# }
        ;;
    esac
  done <"$RECORDS_FILE"
  # Porcelain records normally end in a blank NUL field. Keep the flush for
  # older Git variants that omit the final separator.
  if [ -n "$path" ]; then
    printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
      "$path" "$branch" "$detached" "$head" "$locked" "$lock_reason"
  fi
  rm -f "$RECORDS_FILE"
  RECORDS_FILE=""
}

# ── Gather state ──────────────────────────────────────────────────────
# Portable mktemp template (#286 r5): BSD-only `mktemp -t <prefix>`
# fails closed on GNU coreutils because the template lacks `XXXXXX`
# placeholders in the right position. The portable form below works
# on both. Caught by check_mktemp_portability once that check landed
# from #286 — this fix closes the cross-PR gap (#298 merged the
# bad form before #286's check was wired into CI).
GONE_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-gone.XXXXXX")
REC_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-rec.XXXXXX")
STALE_UNPRUNED_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-staleunpruned.XXXXXX")
# WRITE failures to these files are a separate concern from their creation,
# and only the ones inside stale_unpruned_branches() that the probe EVALUATES
# through are guarded (Codex P2 on #1105, twice). Six writes are not:
# GONE_FILE, REC_FILE (x2), MERGE_SWEEP_FILE, KNOWN_FILE, and the probe's own
# result write `stale_unpruned_branches >"$STALE_UNPRUNED_FILE"`. All six die
# on a full TMPDIR with a bare `printf: write error` and exit 1, before any
# summary. That is LOUD rather than silent — nobody reads it as a clean audit,
# which is the property exit 3 protects — so they carry no exit-3 contract and
# are left as pre-existing behaviour rather than widened here. The spec says
# the same thing, deliberately: the contract covers evaluation, not
# persistence. Tracked together in #1115.
#
# EVERY mktemp site in this script is registered here (#920 finding 2). The
# five later ones — HEADS_FILE, ELIGIBLE_FILE and RECORDS_FILE inside the
# helpers above, MERGE_SWEEP_FILE and KNOWN_FILE further down — used to rely
# solely on an
# inline `rm -f` placed after their work. Under `set -e` any failure in
# between (a failed `git` call, a closed pipe, SIGINT) exits before that line
# and leaks the file into TMPDIR. The inline removals stay — they keep TMPDIR
# tidy during a long run and they blank the variable so this trap has nothing
# left to do — and the `${VAR:-}` expansions make the trap safe to fire before
# any of them has been assigned. `rm -f ''` is a silent no-op on both GNU
# and BSD rm, so the empty slots cost nothing.
#
# The five names are initialised to the empty string FIRST, and that line is
# load-bearing rather than defensive tidiness. This script runs under
# `set -eo pipefail` with NO `set -u`, so `${HEADS_FILE:-}` does not mean
# "unset unless this script assigned it" — it means "whatever is in scope",
# and an exported variable of the same name inherited from the caller's
# environment expands verbatim. Without these assignments the trap would
# `rm -f` a path this script never created: `KNOWN_FILE` is only assigned
# inside the `[ -d "$ORPHAN_ROOT" ]` branch, so a repository with no
# `.claude/worktrees` directory deletes an inherited `KNOWN_FILE` on a plain
# `--dry-run`, and `stale_unpruned_branches()` is dry-run-only, so every
# successful `--apply` deletes an inherited `HEADS_FILE`. That turns a
# read-only audit into a destructive one on nothing more than a name
# collision in the environment. Assigning here shadows any inherited value
# before the trap is installed and keeps the trap's reach to this script's
# own `mktemp` files.
# Whether the one remote read this audit performs actually happened. Empty
# until stale_unpruned_branches() runs, which is dry-run only: under --apply
# the probe never runs, the state stays empty, and the exit-3 arm at the
# bottom is unreachable there by construction.
STALE_SNAPSHOT_STATE=""
STALE_SNAPSHOT_REASON=""
# WHERE the failed read was, so the remedy printed with it is the right one:
# `remote` (the network read) or `local` (this machine's temporary storage).
# Only two of the four unknown paths involve the remote at all, and one of
# them fails AFTER a successful remote read (Codex P2 on #1105).
STALE_SNAPSHOT_CAUSE=""
HEADS_FILE=""
ELIGIBLE_FILE=""
RECORDS_FILE=""
MERGE_SWEEP_FILE=""
KNOWN_FILE=""
trap 'rm -f "$GONE_FILE" "$REC_FILE" "$STALE_UNPRUNED_FILE" "${HEADS_FILE:-}" "${ELIGIBLE_FILE:-}" "${RECORDS_FILE:-}" "${MERGE_SWEEP_FILE:-}" "${KNOWN_FILE:-}"' EXIT

gone_branches >"$GONE_FILE"
worktree_records >"$REC_FILE"

is_gone_branch() {
  local b="$1"
  [ -z "$b" ] && return 1
  grep -Fxq -- "$b" "$GONE_FILE"
}

# Dry-run only (#822). The probe exists to make a stale-unpruned merged
# branch VISIBLE in the read-only audit; it deliberately does not widen what
# --apply deletes. --apply still acts only on branches already marked gone by
# a prune the operator ran, exactly as before #822 — teaching --apply to prune
# for itself is #932. Keeping STALE_UNPRUNED_FILE empty under --apply is what
# holds that line: every consumer below unions it into its input, so populating
# it in apply mode would silently make this a removal change too.
if [ "$MODE" = "dry-run" ]; then
  stale_unpruned_branches >"$STALE_UNPRUNED_FILE"
fi

branch_checked_out() {
  local b="$1" rec_path rec_branch rec_detached rec_head rec_locked rec_lock_reason
  # Every field must be CONSUMED to keep the next record aligned, but only
  # rec_branch is read. The rest are deliberate discards, not oversights.
  # shellcheck disable=SC2034
  while IFS= read -r -d '' rec_path \
    && IFS= read -r -d '' rec_branch \
    && IFS= read -r -d '' rec_detached \
    && IFS= read -r -d '' rec_head \
    && IFS= read -r -d '' rec_locked \
    && IFS= read -r -d '' rec_lock_reason; do
    [ "$rec_branch" = "$b" ] && return 0
  done <"$REC_FILE"
  return 1
}

# ── Classify and act ──────────────────────────────────────────────────
SUMMARY_GONE=()
SUMMARY_DETACHED=()
# Branch-ATTACHED worktrees whose path carries a `pr-<n>` slug for a
# CLOSED/MERGED PR while the remote branch is still alive — the case the
# detached-only slug check missed entirely (#762).
SUMMARY_PR_BRANCH=()
# Branch-attached closed/merged-PR worktrees retained because their working
# tree is NOT clean — uncommitted edits, untracked files, gitignored content
# (`.env`, `node_modules/`, …), or an unreadable status. Removing them would
# destroy content that exists nowhere else. Surfaced for a human, never
# auto-removed.
SUMMARY_UNCLEAN_KEPT=()
# Branch-attached closed/merged-PR worktrees whose registered DIRECTORY no
# longer exists. Nothing to preserve; the stale administrative entry is
# cleared by `git worktree prune` (which --apply runs unconditionally).
# UNLOCKED entries only — prune skips locked ones, so a locked+missing entry
# is NOT self-clearing and goes to SUMMARY_LOCKED instead (#762 r3 P2).
SUMMARY_PRUNABLE=()
SUMMARY_LOCKED=()
SUMMARY_LOCAL_BRANCH=()
SUMMARY_OPEN_PR=()
SUMMARY_ORPHAN=()
SUMMARY_REMOVED=()
SUMMARY_SKIPPED=()
SUMMARY_FAILED=()
# Gone-upstream branches that were EXAMINED in the merged-branch sweep but
# were NOT flagged as deletion candidates (no merged PR for the head name).
# Tracked separately from "not evaluated" so silent omissions are visible in
# the dry-run summary going forward (#605 acceptance: distinguish "evaluated,
# not a candidate" from "not evaluated").
SUMMARY_EXAMINED_NOT_MERGED=()
# Gone-upstream branches whose PR merged for the head name but whose local tip
# carries EXTRA commit(s) on top of the merged head. Surfaced for manual review
# and NEVER auto-deleted (the extra commits may be unmerged follow-up work).
SUMMARY_DIVERGED_KEPT=()
# Gone-upstream branches whose merged-PR lookup FAILED (gh missing /
# unauthenticated / API error) — NOT evaluated, distinct from both "examined,
# not merged" and the deletion candidates (Codex P2 on #610).
SUMMARY_LOOKUP_UNKNOWN=()
# Branches detected by stale_unpruned_branches() (#822): a `gone`-marker
# false-negative because the local refs/remotes/origin/<branch> ref hasn't
# been pruned yet, dry-run only. These ALSO land in whichever of the buckets
# above their merged-PR status resolves to; this counter exists purely so
# the class itself — "retained only because of an unpruned ref" — is never
# invisible in the summary, per #822's acceptance criteria.
SUMMARY_STALE_UNPRUNED=()

print_record() {
  local label="$1" color="$2" path="$3" branch="$4" head="$5" upstream="$6" pr_state="$7" lock_reason="$8"
  printf "  %s%s%s\n" "$color" "$label" "$C_RESET"
  printf "    path:     %s\n" "$path"
  printf "    branch:   %s\n" "${branch:-<detached>}"
  printf "    HEAD:     %s\n" "${head:0:12}"
  printf "    upstream: %s\n" "$upstream"
  if [ -n "$pr_state" ]; then
    printf "    PR state: %s\n" "$pr_state"
  fi
  if [ -n "$lock_reason" ]; then
    printf "    locked:   %s\n" "$lock_reason"
  fi
}

try_remove() {
  local path="$1" locked="$2"
  # Locked worktrees need `git worktree remove -f -f` (double force) per
  # git's docs — a single --force is not sufficient. We unlock first
  # for a cleaner error path and then call remove without --force, which
  # mirrors how an operator would do it manually.
  if [ "$locked" = "1" ]; then
    (cd "$MAIN_WORKTREE" && git worktree unlock "$path") >/dev/null 2>&1 || true
  fi
  # Try the NON-force removal first. git refuses to remove a worktree it
  # considers dirty, or one containing submodules — an INDEPENDENT second
  # opinion that does not share our status probe's blind spots.
  #
  # Scope of that backstop, measured rather than assumed: it catches the
  # SUBMODULE case (git refuses "working trees containing submodules cannot be
  # moved or removed" unless forced). It does NOT catch index-flag blindness —
  # verified directly: a tracked file marked `assume-unchanged` and then
  # edited leaves `git status --porcelain --ignored --untracked-files=all
  # --ignore-submodules=none` EMPTY, and a plain `git worktree remove` deletes
  # the edit anyway, because git consults the same flags our probe does. So
  # this is a second line of defence, not a general one; the index-flag and
  # submodule-internal cases are detected explicitly in
  # worktree_content_state() instead.
  #
  # --force is now reached ONLY on the locked path the operator explicitly
  # opted into with --force-locked, which is the one case where "remove it
  # anyway" is the stated intent. A non-force refusal elsewhere surfaces as
  # FAILED rather than deleting: the conservative direction for a tool whose
  # mistakes are unrecoverable.
  if (cd "$MAIN_WORKTREE" && git worktree remove "$path") >/dev/null 2>&1; then
    SUMMARY_REMOVED+=("$path")
    return 0
  fi
  if [ "$locked" = "1" ] && [ "$FORCE_LOCKED" = "1" ]; then
    if (cd "$MAIN_WORKTREE" && git worktree remove --force "$path") >/dev/null 2>&1; then
      SUMMARY_REMOVED+=("$path")
      return 0
    fi
  fi
  SUMMARY_FAILED+=("$path")
  return 1
}

echo "${C_BOLD}worktree-cleanup.sh${C_RESET} — mode=${MODE} main=${MAIN_WORKTREE}"
echo ""

while IFS= read -r -d '' WT_PATH \
  && IFS= read -r -d '' WT_BRANCH \
  && IFS= read -r -d '' WT_DETACHED \
  && IFS= read -r -d '' WT_HEAD \
  && IFS= read -r -d '' WT_LOCKED \
  && IFS= read -r -d '' WT_LOCK_REASON; do
  [ -z "$WT_PATH" ] && continue
  # Skip the main worktree itself.
  if [ "$WT_PATH" = "$MAIN_WORKTREE" ]; then
    continue
  fi

  # Path-carried PR number, parsed for BOTH the detached and the
  # branch-attached case (#762).
  pr_num=$(worktree_pr_num "$WT_PATH")

  if [ "$WT_DETACHED" = "1" ]; then
    if [ -n "$pr_num" ]; then
      pr_state=$(gh_pr_state "$pr_num")
      case "$pr_state" in
        CLOSED|MERGED)
          if [ "$WT_LOCKED" = "1" ]; then
            print_record "[LOCKED detached PR #${pr_num} (${pr_state})]" "$C_YELLOW" \
              "$WT_PATH" "" "$WT_HEAD" "[detached]" "$pr_state" "$WT_LOCK_REASON"
            SUMMARY_LOCKED+=("$WT_PATH (PR #${pr_num} ${pr_state})")
            if [ "$MODE" = "apply" ] && [ "$FORCE_LOCKED" = "1" ]; then
              echo "    -> removing (forced)"
              try_remove "$WT_PATH" "1"
            elif [ "$MODE" = "apply" ]; then
              echo "    -> skipped (locked; pass --force-locked to remove)"
              SUMMARY_SKIPPED+=("$WT_PATH (locked)")
            fi
          else
            print_record "[STALE detached PR #${pr_num} (${pr_state})]" "$C_RED" \
              "$WT_PATH" "" "$WT_HEAD" "[detached]" "$pr_state" ""
            SUMMARY_DETACHED+=("$WT_PATH (PR #${pr_num} ${pr_state})")
            if [ "$MODE" = "apply" ]; then
              echo "    -> removing"
              try_remove "$WT_PATH" "0"
            fi
          fi
          ;;
        OPEN)
          print_record "[OPEN PR #${pr_num} — keeping]" "$C_GREEN" \
            "$WT_PATH" "" "$WT_HEAD" "[detached]" "OPEN" ""
          SUMMARY_OPEN_PR+=("$WT_PATH (PR #${pr_num})")
          ;;
        *)
          print_record "[detached PR #${pr_num} state unknown]" "$C_YELLOW" \
            "$WT_PATH" "" "$WT_HEAD" "[detached]" "$pr_state" ""
          SUMMARY_DETACHED+=("$WT_PATH (PR #${pr_num} unknown)")
          if [ "$MODE" = "apply" ]; then
            echo "    -> skipped (PR state unknown; rerun after \`gh auth\` setup)"
            SUMMARY_SKIPPED+=("$WT_PATH (PR state unknown)")
          fi
          ;;
      esac
    else
      # Detached but not a known mergepath-pr-<num> path. List for awareness;
      # never auto-remove (could be a custom checkout-by-sha).
      print_record "[detached non-PR]" "$C_DIM" \
        "$WT_PATH" "" "$WT_HEAD" "[detached]" "" "$WT_LOCK_REASON"
    fi
    continue
  fi

  # Branch-attached worktree.
  #
  # Keyed on is_gone_branch() alone, deliberately. The stale-unpruned probe
  # feeds the merged-branch SWEEP further down (a report), not this
  # classification, because this classification drives removal under --apply
  # and --apply's removal set is unchanged by #822. Unioning the probe in here
  # would make dry-run advertise `[STALE gone-upstream]` — which reads as
  # "--apply will remove this" — for a worktree --apply will not touch. #932
  # (teaching --apply to prune) is where the two would converge again.
  if is_gone_branch "$WT_BRANCH"; then
    # A PR-slug worktree must clear the comprehensive content gate before ANY
    # removal, including this gone-upstream fast path. Without this the
    # invariant is only half-real: rule 1 runs FIRST and `continue`s, so a
    # `.mergepath-worktrees/pr-N-*` checkout whose upstream is already [gone]
    # never reached worktree_content_state and `--apply` deleted uncommitted,
    # untracked, gitignored or submodule content outright — the very loss the
    # gate below was added to prevent (#762 r3 P1).
    #
    # Scoped to PR-slug paths on purpose: those are the ones this tool's
    # convention says it owns and may delete unattended. A non-slug
    # gone-upstream worktree keeps its long-standing behaviour.
    if [ -n "$pr_num" ]; then
      wt_state=$(worktree_content_state "$WT_PATH") || true
      if [ "$wt_state" != "clean" ] && [ "$wt_state" != "missing" ]; then
        print_record "[PR #${pr_num} gone-upstream but working tree is ${wt_state} — review manually, keeping]" "$C_YELLOW" \
          "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[gone]" "" "$WT_LOCK_REASON"
        if [ "$wt_state" = "ignored" ]; then
          echo "    reason:   gitignored content only (e.g. .env, *.key, node_modules/) — \`git worktree remove\` deletes it with or without --force, and it exists nowhere else; move or delete it by hand first"
        else
          echo "    reason:   uncommitted or untracked content (or an unreadable status) — removing the worktree would destroy work that exists nowhere else; commit, stash, or discard it by hand first"
        fi
        SUMMARY_UNCLEAN_KEPT+=("$WT_PATH ($WT_BRANCH [gone], $wt_state)")
        continue
      fi
    fi
    if [ "$WT_LOCKED" = "1" ]; then
      print_record "[LOCKED gone-upstream]" "$C_YELLOW" \
        "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[gone]" "" "$WT_LOCK_REASON"
      SUMMARY_LOCKED+=("$WT_PATH ($WT_BRANCH [gone])")
      if [ "$MODE" = "apply" ] && [ "$FORCE_LOCKED" = "1" ]; then
        echo "    -> removing (forced)"
        try_remove "$WT_PATH" "1"
      elif [ "$MODE" = "apply" ]; then
        echo "    -> skipped (locked; pass --force-locked to remove)"
        SUMMARY_SKIPPED+=("$WT_PATH (locked)")
      fi
    else
      print_record "[STALE gone-upstream]" "$C_RED" \
        "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[gone]" "" ""
      SUMMARY_GONE+=("$WT_PATH ($WT_BRANCH)")
      if [ "$MODE" = "apply" ]; then
        echo "    -> removing"
        try_remove "$WT_PATH" "0"
      fi
    fi
    continue
  fi

  # Branch-attached, upstream still ALIVE. This is where the documented
  # `git worktree add <path> <branch>` form lands, so it is where a
  # convention-slugged checkout for a closed/merged PR has to be caught —
  # the gone-upstream rule above misses it whenever the remote branch
  # outlives the PR, and the slug check used to live only in the detached
  # arm (#762). Strictly additive: rule 1 already `continue`d above, so no
  # previously-removable worktree becomes retained here.
  [ -n "$pr_num" ] || continue
  pr_state=$(gh_pr_state "$pr_num")
  case "$pr_state" in
    CLOSED|MERGED)
      # Removal requires positive proof that nothing is lost: an EMPTY
      # status per worktree_content_state() (which forces the ignored,
      # untracked and submodule listings on so operator config cannot turn
      # the proof into a lie). The branch ref survives `git
      # worktree remove`, so commits are safe either way; working-tree-only
      # content is not. Anything git reports → surface and keep. This runs
      # BEFORE the locked check on purpose: a locked AND unclean worktree
      # must stay put even under --force-locked. `|| true` because the
      # helper returns non-zero for every non-clean verdict and `set -e`
      # would otherwise abort on the assignment.
      wt_state=$(worktree_content_state "$WT_PATH") || true
      if [ "$wt_state" = "missing" ]; then
        # The registered directory is gone: nothing to preserve, only git's
        # administrative entry is stale. Never route it through the unclean
        # bucket, whose "commit, stash, or discard it by hand" remediation is
        # nonsense for a path that does not exist (#762 r2 P3).
        #
        # But "stale entry" does NOT imply "prunable": `git worktree prune`
        # SKIPS locked entries. Verified — with the directory deleted and the
        # entry locked, `git worktree prune -v` printed nothing and the entry
        # stayed registered; `git worktree remove --force` also refused
        # ("cannot remove a locked working tree ... use 'remove -f -f' to
        # override or unlock first"). Claiming self-clearing prunability for a
        # LOCKED entry therefore produced a candidate that reappeared in every
        # subsequent audit forever while --apply kept exiting 0. It belongs in
        # the locked bucket instead, behind the same explicit --force-locked
        # gate as every other locked entry — a lock is an operator statement
        # that this entry is not to be touched, and a vanished directory is no
        # reason to override it silently. try_remove() unlocks first and then
        # removes, which does clear a locked+missing entry (verified rc=0,
        # entry gone) (#762 r3 P2).
        if [ "$WT_LOCKED" = "1" ]; then
          print_record "[LOCKED PR #${pr_num} (${pr_state}) worktree directory is MISSING]" "$C_YELLOW" \
            "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[alive]" "$pr_state" "$WT_LOCK_REASON"
          echo "    reason:   the registered directory does not exist, so there is nothing to preserve — but the entry is LOCKED and \`git worktree prune\` skips locked entries, so this does NOT clear itself; pass --force-locked to unlock and drop it"
          SUMMARY_LOCKED+=("$WT_PATH ($WT_BRANCH, PR #${pr_num} ${pr_state}, directory missing)")
          if [ "$MODE" = "apply" ] && [ "$FORCE_LOCKED" = "1" ]; then
            echo "    -> removing (forced)"
            try_remove "$WT_PATH" "1"
          elif [ "$MODE" = "apply" ]; then
            echo "    -> skipped (locked; pass --force-locked to remove)"
            SUMMARY_SKIPPED+=("$WT_PATH (locked)")
          fi
          continue
        fi
        print_record "[PR #${pr_num} (${pr_state}) worktree directory is MISSING — prunable]" "$C_YELLOW" \
          "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[alive]" "$pr_state" "$WT_LOCK_REASON"
        echo "    reason:   the registered directory does not exist, so there is nothing to preserve — only git's administrative entry is stale; \`git worktree prune\` clears it (--apply runs prune unconditionally)"
        SUMMARY_PRUNABLE+=("$WT_PATH ($WT_BRANCH, PR #${pr_num} ${pr_state})")
        continue
      fi
      if [ "$wt_state" != "clean" ]; then
        print_record "[PR #${pr_num} (${pr_state}) but the working tree is not clean — review manually, keeping]" "$C_YELLOW" \
          "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[alive]" "$pr_state" "$WT_LOCK_REASON"
        if [ "$wt_state" = "ignored" ]; then
          echo "    reason:   gitignored content only (e.g. .env, *.key, node_modules/) — \`git worktree remove\` deletes it with or without --force, and it exists nowhere else; move or delete it by hand first"
        else
          echo "    reason:   uncommitted or untracked content (or an unreadable status) — removing the worktree would destroy work that exists nowhere else; commit, stash, or discard it by hand first"
        fi
        SUMMARY_UNCLEAN_KEPT+=("$WT_PATH ($WT_BRANCH, PR #${pr_num} ${pr_state}, ${wt_state})")
        continue
      fi
      if [ "$WT_LOCKED" = "1" ]; then
        print_record "[LOCKED PR #${pr_num} (${pr_state}) branch worktree]" "$C_YELLOW" \
          "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[alive]" "$pr_state" "$WT_LOCK_REASON"
        SUMMARY_LOCKED+=("$WT_PATH ($WT_BRANCH, PR #${pr_num} ${pr_state})")
        if [ "$MODE" = "apply" ] && [ "$FORCE_LOCKED" = "1" ]; then
          echo "    -> removing (forced)"
          try_remove "$WT_PATH" "1"
        elif [ "$MODE" = "apply" ]; then
          echo "    -> skipped (locked; pass --force-locked to remove)"
          SUMMARY_SKIPPED+=("$WT_PATH (locked)")
        fi
      else
        print_record "[STALE PR #${pr_num} (${pr_state}) branch worktree]" "$C_RED" \
          "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[alive]" "$pr_state" ""
        SUMMARY_PR_BRANCH+=("$WT_PATH ($WT_BRANCH, PR #${pr_num} ${pr_state})")
        if [ "$MODE" = "apply" ]; then
          echo "    -> removing (working tree clean; branch ref $WT_BRANCH is kept)"
          try_remove "$WT_PATH" "0"
        fi
      fi
      ;;
    OPEN)
      print_record "[OPEN PR #${pr_num} — keeping]" "$C_GREEN" \
        "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[alive]" "OPEN" ""
      SUMMARY_OPEN_PR+=("$WT_PATH ($WT_BRANCH, PR #${pr_num})")
      ;;
    *)
      print_record "[PR #${pr_num} state unknown — branch worktree]" "$C_YELLOW" \
        "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[alive]" "$pr_state" ""
      SUMMARY_PR_BRANCH+=("$WT_PATH ($WT_BRANCH, PR #${pr_num} unknown)")
      if [ "$MODE" = "apply" ]; then
        echo "    -> skipped (PR state unknown; rerun after \`gh auth\` setup)"
        SUMMARY_SKIPPED+=("$WT_PATH (PR state unknown)")
      fi
      ;;
  esac
done <"$REC_FILE"

# ── Re-snapshot worktree records (#605 root cause 1) ───────────────────
# $REC_FILE was captured once at the top, BEFORE the worktree-removal loop
# above ran. In --apply mode that loop can remove worktrees, so the stale
# snapshot would still report a just-removed worktree's branch as "checked
# out" and the merged-branch sweep below would skip deleting its ref in the
# SAME run. Re-snapshot now so branch_checked_out() reflects worktree state
# as of AFTER removals. Harmless in dry-run (nothing was removed, so the
# re-read is identical). The orphan scan below also reads $REC_FILE, so it
# benefits from the fresh snapshot too.
if [ "$MODE" = "apply" ]; then
  worktree_records >"$REC_FILE"
fi

# ── Verified-merged local branch sweep ─────────────────────────────────
# Worktree cleanup removes stale worktrees, but a squash-merged branch can
# remain as a standalone local ref after the remote branch is deleted. Verify
# the PR's merged state before listing/deleting so ordinary unpublished work is
# not swept up just because its upstream is gone.
#
# The sweep set is GONE_FILE (branches `%(upstream:track)` already marks gone)
# UNION STALE_UNPRUNED_FILE (dry-run only: branches whose remote-tracking ref
# is stale but not yet pruned, per stale_unpruned_branches() — #822). Tagging
# each branch by source lets the stale-unpruned case get its own summary
# counter and an explicit reason note, without a second copy of this loop.
# STALE_UNPRUNED_FILE is empty under --apply, so under --apply this union is a
# no-op and the branch-deletion set is exactly what it was before #822: this
# sweep DELETES what it classifies, so the stale-unpruned class reaching it in
# apply mode would be a removal change, not a reporting one (#932).
MERGE_SWEEP_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-mergesweep.XXXXXX")
{
  awk '{ printf "%s\t%s\n", $0, "gone" }' "$GONE_FILE"
  awk '{ printf "%s\t%s\n", $0, "stale-unpruned" }' "$STALE_UNPRUNED_FILE"
} >"$MERGE_SWEEP_FILE"

while IFS=$'\t' read -r LOCAL_BRANCH SWEEP_SRC; do
  [ -n "$LOCAL_BRANCH" ] || continue
  STALE_NOTE=""
  if [ "$SWEEP_SRC" = "stale-unpruned" ]; then
    STALE_NOTE=" (remote-tracking ref is stale, not yet marked gone — run \`git fetch --prune origin\`, then re-run this audit)"
    SUMMARY_STALE_UNPRUNED+=("$LOCAL_BRANCH")
  fi
  # `|| true`: the helper returns 1 for the "none" verdict, and under
  # `set -e` a `VAR=$(func)` assignment inherits that non-zero status and
  # would abort the script. The verdict string is already on stdout, so we
  # only need to neutralize the exit status here.
  MERGED_STATUS=$(gh_branch_merged_pr_status "$LOCAL_BRANCH") || true
  if [ "$MERGED_STATUS" = "unknown" ]; then
    # Lookup FAILED (gh missing / unauthenticated / API error): the branch was
    # NOT evaluated. Say so explicitly — do not let a verification failure
    # masquerade as a verified "no merged PR" (Codex P2). Kept, never deleted.
    LOCAL_BRANCH_TIP=$(git -C "$MAIN_WORKTREE" rev-parse "$LOCAL_BRANCH" 2>/dev/null || true)
    print_record "[gone-upstream local branch — merged-PR lookup FAILED, keeping]" "$C_YELLOW" \
      "$MAIN_WORKTREE" "$LOCAL_BRANCH" "$LOCAL_BRANCH_TIP" "[gone]" "" ""
    echo "    reason:   could not verify merged state (gh missing, unauthenticated, or API error) — branch NOT evaluated${STALE_NOTE}"
    SUMMARY_LOOKUP_UNKNOWN+=("$LOCAL_BRANCH")
    continue
  fi
  if [ "$MERGED_STATUS" = "none" ]; then
    # Evaluated but NOT a deletion candidate: no merged PR for this head
    # name. Emit a CLEAR line (rather than a silent `continue`) so the
    # dry-run summary distinguishes "examined, not merged" from branches we
    # never evaluated. Keeps the fail-safe contract — nothing is deleted.
    LOCAL_BRANCH_TIP=$(git -C "$MAIN_WORKTREE" rev-parse "$LOCAL_BRANCH" 2>/dev/null || true)
    print_record "[gone-upstream local branch — no merged PR, keeping]" "$C_DIM" \
      "$MAIN_WORKTREE" "$LOCAL_BRANCH" "$LOCAL_BRANCH_TIP" "[gone]" "" ""
    echo "    reason:   no merged PR found for head name (unpublished or unmerged work)${STALE_NOTE}"
    SUMMARY_EXAMINED_NOT_MERGED+=("$LOCAL_BRANCH")
    continue
  fi

  # A merged PR exists for this head name. Split by how the local tip relates
  # to the merged head:
  #
  #   diverged → the tip DESCENDS from the merged head but carries EXTRA local
  #     commit(s). Those commits are NOT proven merged — "kept working on the
  #     same branch after the PR merged/was deleted" is a common shape — so
  #     auto-deleting would lose real unpushed follow-up work (Codex P1 on
  #     #608's sibling). SURFACE it clearly for manual review (this satisfies
  #     #605's actual complaint — the branch is no longer a SILENT omission) but
  #     do NOT auto-delete. Only an EXACT tip==merged-head match is provably
  #     fully merged and safe to `git branch -D`.
  if [ "$MERGED_STATUS" = "diverged" ]; then
    DIVERGED_TIP=$(git -C "$MAIN_WORKTREE" rev-parse "$LOCAL_BRANCH" 2>/dev/null || true)
    print_record "[MERGED PR, local tip has unmerged commit(s) on top — review manually, keeping]" "$C_YELLOW" \
      "$MAIN_WORKTREE" "$LOCAL_BRANCH" "$DIVERGED_TIP" "[gone]" "MERGED+extra" ""
    echo "    reason:   PR for this head name merged, but the local tip carries commit(s) beyond the merged head; not auto-deleted (may be unmerged follow-up work — delete by hand after review)${STALE_NOTE}"
    SUMMARY_DIVERGED_KEPT+=("$LOCAL_BRANCH")
    continue
  fi

  # exact: tip == merged head → provably fully merged, safe to delete.
  if branch_checked_out "$LOCAL_BRANCH"; then
    print_record "[MERGED local branch checked out — keeping]" "$C_YELLOW" \
      "$MAIN_WORKTREE" "$LOCAL_BRANCH" "$(git -C "$MAIN_WORKTREE" rev-parse "$LOCAL_BRANCH" 2>/dev/null || true)" "[gone]" "MERGED" ""
    # This path appends STALE_NOTE like every other: a checked-out branch is
    # exactly where the operator would otherwise get no hint that a prune is
    # what stands between this report and a `gone` classification.
    echo "    reason:   PR for this head name merged and the local tip is an exact match, but the branch is checked out in a worktree${STALE_NOTE}"
    SUMMARY_LOCAL_BRANCH+=("$LOCAL_BRANCH (checked out)")
    if [ "$MODE" = "apply" ]; then
      echo "    -> skipped (branch is checked out in a worktree)"
      SUMMARY_SKIPPED+=("$LOCAL_BRANCH (checked out)")
    fi
    continue
  fi

  print_record "[MERGED local branch]" "$C_RED" \
    "$MAIN_WORKTREE" "$LOCAL_BRANCH" "$(git -C "$MAIN_WORKTREE" rev-parse "$LOCAL_BRANCH" 2>/dev/null || true)" "[gone]" "MERGED" ""
  if [ -n "$STALE_NOTE" ]; then
    echo "    reason:   PR for this head name merged and the local tip is an exact match${STALE_NOTE}"
  fi
  SUMMARY_LOCAL_BRANCH+=("$LOCAL_BRANCH")
  if [ "$MODE" = "apply" ]; then
    echo "    -> deleting local branch"
    if (cd "$MAIN_WORKTREE" && git branch -D "$LOCAL_BRANCH") >/dev/null 2>&1; then
      SUMMARY_REMOVED+=("$LOCAL_BRANCH (local branch)")
    else
      SUMMARY_FAILED+=("$LOCAL_BRANCH (local branch)")
    fi
  fi
done <"$MERGE_SWEEP_FILE"
rm -f "$MERGE_SWEEP_FILE"
MERGE_SWEEP_FILE=""

# Is $1 one of the worktree paths git currently has registered?
#
# The membership set ($KNOWN_FILE) is NUL-delimited, and this comparison is
# what keeps it that way end to end (#992). The previous spelling
# re-serialised the set with `printf %s\\n` and tested it with `grep -Fxq`,
# which silently undid the reason worktree_records() emits NUL at all: a
# worktree path may contain any byte git allows, INCLUDING a literal newline,
# and such a path landed in the set as two independent LINE records.
#
# Both directions of that break are wrong, in opposite ways:
#
#   ineffective  a genuine orphan whose name equals one of the split
#                fragments matches the fragment, is read as registered, and
#                is never reported or cleaned. Reproduced on #991 head with
#                registered `<root>/foo\nbar` beside orphan `<root>/foo`.
#   DESTRUCTIVE  a registered worktree whose own path contains a newline
#                fails its own membership test, is classified an orphan, and
#                under --orphan-clean is `rm -rf`d. This is the direction
#                that loses data, and it is why the fix is a whole-record
#                comparison rather than a better pattern.
#
# A shell-level loop, not `grep -z -Fxq`: `grep -z` is a GNU extension and
# BSD/macOS grep has no equivalent, so a pattern-based NUL comparison would
# be portable only where the audit is least likely to run. The path counts
# here are worktree counts — tens, not thousands — so the quadratic shape is
# irrelevant next to the `pwd -P` and `git` calls surrounding it.
#
# Reads $KNOWN_FILE from the caller rather than taking it as an argument, to
# match is_gone_branch()/branch_checked_out() above, which read $GONE_FILE
# and $REC_FILE the same way.
known_path_registered() {
  local target="$1" known
  [ -n "${KNOWN_FILE:-}" ] || return 1
  while IFS= read -r -d '' known; do
    [ "$known" = "$target" ] && return 0
  done <"$KNOWN_FILE"
  return 1
}

# ── Orphan scan ───────────────────────────────────────────────────────
ORPHAN_ROOT="$MAIN_WORKTREE/.claude/worktrees"
if [ -d "$ORPHAN_ROOT" ]; then
  # Resolve ORPHAN_ROOT itself to its physical path so the per-entry
  # `pwd -P` boundary check below compares against the SAME canonical
  # form. Without this, a check like `[[ $abs == $ORPHAN_ROOT/* ]]`
  # would false-negative when ORPHAN_ROOT contains a symlink in its
  # ancestor path. (nathanpayne-codex Phase 4b r1 on PR #298.)
  ORPHAN_ROOT_PHYS=$(cd "$ORPHAN_ROOT" 2>/dev/null && pwd -P) || ORPHAN_ROOT_PHYS=""
  # Trailing slash so the prefix match below is bounded — `/foo` must
  # not match a sibling path `/foobar`.
  ORPHAN_ROOT_PHYS_TS="${ORPHAN_ROOT_PHYS%/}/"

  # Collect known worktree paths into a NUL-delimited set and check each
  # subdir against it with known_path_registered() above. REC_FILE is NUL-delimited: parsing it with awk or grep
  # treats it as binary on some platforms and silently drops registered paths,
  # which can turn an active .claude/worktrees checkout into an orphan-clean
  # deletion candidate. Consume all six fields so the next record stays
  # aligned, and emit only the first (the worktree path).
  KNOWN_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-known.XXXXXX")
  # Same deliberate-discard shape as branch_checked_out(): all six fields are
  # consumed for alignment, only known_path is used.
  # shellcheck disable=SC2034
  while IFS= read -r -d '' known_path \
    && IFS= read -r -d '' known_branch \
    && IFS= read -r -d '' known_detached \
    && IFS= read -r -d '' known_head \
    && IFS= read -r -d '' known_locked \
    && IFS= read -r -d '' known_lock_reason; do
    printf '%s\0' "$known_path"
  done <"$REC_FILE" >"$KNOWN_FILE"
  for d in "$ORPHAN_ROOT"/*; do
    [ -d "$d" ] || continue

    # Defense in depth #1: refuse to operate on a symlink entry. A
    # symlinked sub-entry of .claude/worktrees/ could point ANYWHERE
    # (including outside the worktree root), and resolving + rm-rf'ing
    # the target would delete data the user didn't intend. (codex
    # Phase 4b r1 on #298: orphan cleanup with `pwd -P` followed by
    # `rm -rf` could traverse OUT of .claude/worktrees/ when the
    # entry was a symlink to an external dir.)
    if [ -L "$d" ]; then
      echo "  SKIP (symlink, refusing to follow): $d" >&2
      continue
    fi

    # Resolve to physical path so the orphan comparison aligns with how
    # git records worktree paths in `git worktree list` (it canonicalizes
    # symlinked roots like /var/folders → /private/var/folders on macOS).
    #
    # The `printf X` sentinel is load-bearing, not a flourish. Command
    # substitution strips EVERY trailing newline from its output, so a plain
    # `abs=$(cd "$d" && pwd -P)` silently truncates a path whose own final
    # component ends in a newline — a name git and the filesystem both allow.
    # The membership set is NUL-delimited and keeps that byte, so the
    # truncated value would fail to match its own registered record, and the
    # registered checkout would be classified an ORPHAN. Under
    # --orphan-clean the `rm -rf` below then targets the TRUNCATED path:
    # either a no-op recorded as a successful removal, so every later audit
    # repeats the false finding, or — if a sibling happens to occupy that
    # exact name — the deletion of an unrelated directory.
    #
    # `pwd -P` emits `<path>\n`, so with the sentinel the substitution sees
    # `<path>\nX`, has no trailing newline to strip, and both removals below
    # are exact: strip the sentinel, then strip the single newline `pwd`
    # itself added. Whatever trailing newlines belong to the PATH survive.
    #
    # Found by Codex on #1103. It is a regression this PR would otherwise
    # have introduced: with the previous line-delimited set, `grep -Fxq`
    # matched the truncated value against the record`s first line and the
    # entry was (accidentally) treated as registered.
    abs=$(cd "$d" 2>/dev/null && pwd -P && printf X) || continue
    abs="${abs%X}"
    abs="${abs%$'\n'}"

    # Defense in depth #2: even though $d itself isn't a symlink, its
    # physical path MIGHT be outside ORPHAN_ROOT_PHYS if a parent in
    # the ORPHAN_ROOT chain was itself a symlink. Verify the resolved
    # path is bounded under the resolved ORPHAN_ROOT before any
    # destructive operation. Empty ORPHAN_ROOT_PHYS (cd failure on
    # ORPHAN_ROOT) also short-circuits to refuse.
    if [ -z "$ORPHAN_ROOT_PHYS" ]; then
      echo "  SKIP (could not resolve ORPHAN_ROOT physical path '$ORPHAN_ROOT'): refusing rm -rf" >&2
      continue
    fi
    case "${abs}/" in
      "${ORPHAN_ROOT_PHYS_TS}"*) ;;  # bounded under ORPHAN_ROOT_PHYS — OK
      *)
        echo "  SKIP (resolved path '$abs' is OUTSIDE '$ORPHAN_ROOT_PHYS'): refusing rm -rf" >&2
        continue
        ;;
    esac

    if ! known_path_registered "$abs"; then
      print_record "[ORPHAN .claude/worktrees]" "$C_RED" \
        "$abs" "" "" "[orphan]" "" ""
      SUMMARY_ORPHAN+=("$abs")
      if [ "$MODE" = "apply" ] && [ "$ORPHAN_CLEAN" = "1" ]; then
        echo "    -> rm -rf"
        if rm -rf "$abs"; then
          SUMMARY_REMOVED+=("$abs (orphan)")
        else
          SUMMARY_FAILED+=("$abs (orphan)")
        fi
      elif [ "$MODE" = "apply" ]; then
        echo "    -> skipped (orphan; pass --orphan-clean to remove)"
        SUMMARY_SKIPPED+=("$abs (orphan)")
      fi
    fi
  done
  rm -f "$KNOWN_FILE"
  KNOWN_FILE=""
fi

# ── Summary + exit ────────────────────────────────────────────────────
echo ""
echo "${C_BOLD}Summary${C_RESET}"
printf "  gone-upstream:    %d\n" "${#SUMMARY_GONE[@]}"
printf "  detached stale:   %d\n" "${#SUMMARY_DETACHED[@]}"
# Branch-attached worktrees whose PR-slug path names a CLOSED/MERGED (or
# unverifiable) PR while the remote branch is still alive (#762).
printf "  PR-slug branch stale: %d\n" "${#SUMMARY_PR_BRANCH[@]}"
# Closed/merged-PR branch worktrees kept because their working tree is not
# clean — the removal would destroy content that exists nowhere else.
printf "  unclean PR worktrees (review): %d\n" "${#SUMMARY_UNCLEAN_KEPT[@]}"
# Closed/merged-PR branch worktrees whose directory is already gone and whose
# entry is UNLOCKED — only git's administrative entry is stale, and the
# trailing `git worktree prune` clears it. Locked+missing entries are counted
# under `locked` instead: prune skips them (#762 r3 P2).
printf "  prunable PR worktrees: %d\n" "${#SUMMARY_PRUNABLE[@]}"
printf "  locked:           %d\n" "${#SUMMARY_LOCKED[@]}"
printf "  merged branches:  %d\n" "${#SUMMARY_LOCAL_BRANCH[@]}"
# Gone-upstream branches examined by the merged-branch sweep but kept because
# no merged PR backs them. Reported so a silent omission (the #605 failure
# mode) is visible: a branch that WAS evaluated but is not a candidate shows
# up here rather than vanishing without a trace.
printf "  gone kept (unmerged): %d\n" "${#SUMMARY_EXAMINED_NOT_MERGED[@]}"
# Merged-PR branches whose local tip has extra commit(s) on top — surfaced for
# manual review, never auto-deleted (may hold unmerged follow-up work).
printf "  merged+extra (review): %d\n" "${#SUMMARY_DIVERGED_KEPT[@]}"
# Branches whose merged-PR lookup FAILED — not evaluated (gh missing /
# unauthenticated / API error). Distinct from "gone kept (unmerged)".
printf "  gone unverified (lookup failed): %d\n" "${#SUMMARY_LOOKUP_UNKNOWN[@]}"
if [ "${#SUMMARY_LOOKUP_UNKNOWN[@]}" -gt 0 ]; then
  # Deliberately does NOT name gh as the cause (Codex P2 on #1105).
  # gh_branch_merged_pr_status() returns `unknown` for an unresolvable local
  # ref as well — from its `rev-parse --verify` check, BEFORE gh is invoked —
  # so "restore gh" is the wrong remedy for a branch that vanished during the
  # sweep. Its own docstring says as much: unknown covers a missing gh, an
  # unresolvable ref, or a failed API call. Name the possibilities and let the
  # operator pick, rather than asserting one.
  printf "    ^ NOT MEASURED: the merged-PR lookup did not complete for these\n"
  printf "      branches — gh missing or unauthenticated, an API error, or a\n"
  printf "      local ref that could not be resolved. They are not known to be\n"
  printf "      unmerged; they were not evaluated. Resolve the cause and re-run\n"
  printf "      before treating them as examined. This class does not change\n"
  printf "      the exit status: it is reported rather than silent, and a\n"
  printf "      gh-less machine would otherwise never exit anything else.\n"
fi
# Branches whose remote-tracking ref is stale rather than genuinely gone —
# a `git branch -vv` false-negative this run would otherwise retain silently
# (#822). Dry-run only, so this counter is always 0 under --apply — but the
# reason is that the PROBE is dry-run-gated, NOT that --apply pruned the
# class away before classification. NOTHING in this script prunes: see the
# rule-4 header block and the `if [ "$MODE" = "dry-run" ]` guard on
# stale_unpruned_branches(). Teaching --apply to act on this class is #932.
# An earlier revision of this comment asserted the prune, describing
# apply-mode behaviour that has never existed and that a future author could
# have built on (#934). Each of these ALSO appears in exactly one bucket above
# (merged branches / gone kept / merged+extra / gone unverified) by its
# actual merged-PR status — this counter exists so the unpruned-ref CLASS
# itself is never invisible, even though it is not a distinct disposition.
#
# One append site (the merged-branch sweep), and its input — GONE_FILE UNION
# STALE_UNPRUNED_FILE — carries each branch once, because
# stale_unpruned_branches() skips anything already in GONE_FILE. So the array
# length IS the branch count; nothing here needs de-duplicating.
printf "  gone (stale remote ref, unpruned): %d\n" "${#SUMMARY_STALE_UNPRUNED[@]}"
# ...and, when that counter is not a measurement at all, say so on the line
# after it (#992). Without this the number 0 carries two incompatible
# meanings — "no branch is in this state" and "this could not be checked" —
# and only the first is what a reader takes from it.
if [ "$STALE_SNAPSHOT_STATE" = "unknown" ]; then
  printf "    ^ NOT MEASURED: %s\n" "$STALE_SNAPSHOT_REASON"
  printf "      The count above is 0 because nothing was checked — not because\n"
  printf "      nothing is stale.\n"
  # The remedy has to match the failure. Three of the four unknown paths are
  # LOCAL (an unenterable worktree, or a `mktemp` that failed because TMPDIR
  # is unwritable or full), and one of those fails AFTER the remote has been
  # read successfully. Printing "re-run once the remote is reachable" for a
  # full /tmp sends the operator to fix a network that was never broken
  # (Codex P2 on #1105).
  case "$STALE_SNAPSHOT_CAUSE" in
    remote)
      printf "      The REMOTE could not be read. Re-run once it is reachable\n"
      printf "      before trusting this audit (exit 3).\n" ;;
    storage)
      printf "      This is a LOCAL failure, not a remote one — the audit could\n"
      printf "      not allocate or write its own working state. Check that\n"
      printf "      TMPDIR (%s) is writable and has free\n" "${TMPDIR:-/tmp}"
      printf "      space, then re-run before trusting this audit (exit 3).\n" ;;
    refs)
      printf "      This is a LOCAL failure, not a remote one, and NOT a\n"
      printf "      temporary-storage one — this repository's own refs could\n"
      printf "      not be read. Check the repository (git for-each-ref\n"
      printf "      refs/heads/) rather than TMPDIR or the network, then\n"
      printf "      re-run before trusting this audit (exit 3).\n" ;;
    *)
      printf "      The audit could not complete this check. Resolve the cause\n"
      printf "      named above, then re-run before trusting it (exit 3).\n" ;;
  esac
fi
printf "  open-PR retained: %d\n" "${#SUMMARY_OPEN_PR[@]}"
printf "  orphan dirs:      %d\n" "${#SUMMARY_ORPHAN[@]}"

if [ "$MODE" = "apply" ]; then
  printf "  removed:          %d\n" "${#SUMMARY_REMOVED[@]}"
  printf "  skipped:          %d\n" "${#SUMMARY_SKIPPED[@]}"
  printf "  failed:           %d\n" "${#SUMMARY_FAILED[@]}"
  echo ""
  if [ "${#SUMMARY_FAILED[@]}" -gt 0 ]; then
    echo "${C_RED}One or more removals failed.${C_RESET}" >&2
    exit 1
  fi
  # `git worktree prune` cleans up administrative bits for paths that
  # have already been removed manually. Safe to run after either
  # --apply or no-op.
  (cd "$MAIN_WORKTREE" && git worktree prune) || true
  exit 0
fi

# dry-run: exit 2 if there is anything actionable, 0 otherwise. This lets
# callers wire it into "audit fails locally" checks while we explicitly
# keep it OUT of PR CI per #288.
#
# SUMMARY_DIVERGED_KEPT counts as actionable (Codex P2 on #610): a merged-PR
# branch with extra local commits needs a HUMAN decision (rebase/extract or
# hand-delete), and it is exactly the newly surfaced #605 class — a dry-run
# that reports it but exits 0 would defeat the audit signal. --apply never
# touches these, so the exit-2 persists until the human resolves the branch.
# SUMMARY_LOOKUP_UNKNOWN is deliberately NOT in the exit code: on a gh-less or
# unauthenticated machine EVERY gone branch is unknown, and hard-failing the
# audit there would make it unusable exactly where it can verify least; the
# summary line + per-branch records carry the visibility instead.
#
# SUMMARY_UNCLEAN_KEPT counts as actionable for the same reason as
# SUMMARY_DIVERGED_KEPT: a closed/merged-PR worktree holding working-tree-only
# content needs a HUMAN decision (commit, stash, discard, or move), and --apply
# deliberately never touches it, so the exit-2 persists until the human
# resolves it.
#
# SUMMARY_PRUNABLE counts too, but it is the one bucket here that --apply
# genuinely CLEARS on its own: the trailing `git worktree prune` drops the
# stale administrative entry, so the next dry-run is quiet. It is reported
# rather than silently swallowed because a registered worktree whose directory
# vanished is worth one line of visibility. That self-clearing claim is only
# true because the bucket is now UNLOCKED-only — prune skips locked entries,
# so a locked+missing worktree routed here would have re-reported forever
# while --apply exited 0 (#762 r3 P2).
#
# SUMMARY_PR_BRANCH IS counted even for its PR-state-unknown entries, matching
# how the detached arm counts its own unknown entries under SUMMARY_DETACHED.
# That is not in tension with the SUMMARY_LOOKUP_UNKNOWN carve-out above: that
# carve-out exists because the merged-branch sweep evaluates EVERY gone-upstream
# branch, so on a gh-less machine it would turn dozens of unverifiable branches
# into a permanent exit 2. This bucket only ever holds worktrees the operator
# deliberately slugged `pr-<n>` — a small, hand-created population where an
# unverifiable PR state really is something to go look at.
total_candidates=$(( ${#SUMMARY_GONE[@]} + ${#SUMMARY_DETACHED[@]} + ${#SUMMARY_PR_BRANCH[@]} + ${#SUMMARY_UNCLEAN_KEPT[@]} + ${#SUMMARY_PRUNABLE[@]} + ${#SUMMARY_LOCKED[@]} + ${#SUMMARY_LOCAL_BRANCH[@]} + ${#SUMMARY_ORPHAN[@]} + ${#SUMMARY_DIVERGED_KEPT[@]} ))
if [ "$total_candidates" -gt 0 ]; then
  echo ""
  echo "${C_DIM}Dry run. Re-run with --apply to remove safe candidates.${C_RESET}"
  echo "${C_DIM}  --force-locked   also remove LOCKED entries (#288)${C_RESET}"
  echo "${C_DIM}  --orphan-clean   also rm -rf orphans under .claude/worktrees/${C_RESET}"
fi
# An incomplete audit outranks a complete one with findings (#992). Both the
# hint above and the candidate list stay exactly as they were — the operator
# still gets everything the run DID establish — but the status says the
# report has a hole in it, because the alternative is a preview that reports
# clean and an --apply that then acts on branches the preview never listed.
#
# Ordering: 3 wins over 2 when both hold. 2 asserts the audit was COMPLETE,
# and that assertion is the one thing an unreadable remote makes false; the
# findings themselves are equally real either way.
#
# Only `unknown` reaches here, never `declined`: see stale_unpruned_branches().
#
# SUMMARY_LOOKUP_UNKNOWN deliberately does NOT reach exit 3 either, and the
# reason is the distinction this whole change turns on (Codex P2 on #1105
# raised the apparent inconsistency; this is the answer).
#
# #992 is about SILENCE, not about incompleteness as such. The snapshot
# failure was silent: the counter read `0`, which is byte-identical to a
# genuinely clean tree, so the report asserted something it had not measured.
# A failed merged-PR lookup is the opposite — it has its own counter, its own
# per-branch records, and now its own NOT MEASURED annotation. It announces
# itself. Nothing about it is mistakable for a clean result.
#
# Folding it in would also silently reverse the deliberate carve-out argued
# one block up: on a gh-less or unauthenticated machine EVERY gone branch is
# unknown, and that machine would then never see anything but exit 3 — the
# same unusability the carve-out exists to prevent, re-entered through a
# different code. Reversing a recorded decision as a side effect of a PR
# about a different read is not something to do quietly.
#
# Whether an announced-but-unevaluated branch DESERVES its own status is a
# real question, and it is tracked separately rather than settled here.
if [ "$STALE_SNAPSHOT_STATE" = "unknown" ]; then
  exit 3
fi
if [ "$total_candidates" -gt 0 ]; then
  exit 2
fi
exit 0
