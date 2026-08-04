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
#      "gone" per `git branch -vv` requires `git fetch --prune` to have
#      already removed the stale `refs/remotes/origin/<branch>` — nothing
#      before this rule ran `fetch --prune`, so a branch whose remote was
#      deleted on merge (the normal `gh pr merge --delete-branch` shape)
#      kept a live-looking upstream, was never classified `gone`, and was
#      retained indefinitely with no trace in the summary (#822). Under
#      --apply (already destructive) this rule now runs `git fetch
#      --prune origin` FIRST so gone-upstream detection reflects current
#      remote state before classification. Under dry-run (read-only by
#      contract) it instead probes each non-gone branch's upstream against
#      the remote with `git ls-remote` — a network READ, not a ref
#      mutation — and reports any branch whose remote-tracking ref is
#      stale explicitly, tagged and counted separately, rather than
#      omitting it. NOTE this is a DIFFERENT hazard from the squash-merge
#      one under "Merged-state detection" below: an unpruned ref is a
#      detection gap on the "gone" SIGNAL; ancestry-vs-squash is a
#      detection gap on the "merged" SIGNAL. Fixing one does not touch the
#      other, and both must hold for a branch to be provably safe to
#      delete.
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
#   0  success (audit clean OR all requested removals succeeded)
#   1  generic error (bad invocation, git failure, unsupported state)
#   2  candidates listed but --apply was not passed (dry-run with findings).
#      Lets callers wire this into "audit fails CI" style checks even
#      though we explicitly do NOT wire this into PR CI per #288.
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

# ── Prune stale remote-tracking refs (--apply only) ────────────────────
# `git branch -vv`'s `[origin/<branch>: gone]` marker — the sole input to
# gone_branches() below — only appears once `git fetch --prune` has removed
# the stale `refs/remotes/origin/<branch>` for a branch whose remote was
# deleted (e.g. `gh pr merge --delete-branch`). Nothing else in this script
# ever pruned remote-tracking refs, so a merged branch could sit with a
# live-looking upstream indefinitely and never reach the merged-PR check
# (#822). --apply already performs destructive ref operations (`git branch
# -D`, `git worktree remove`), so running a `fetch --prune` here adds no new
# side-effect category — it is fetch-and-prune of REMOTE-TRACKING refs only,
# never a local branch. Dry-run must NOT do this (read-only-by-default
# contract); it instead reports the condition without mutating anything —
# see stale_unpruned_branches() below. Best-effort: a missing `origin`
# remote or a network failure here must not abort the whole run.
#
# "REMOTE-TRACKING refs only" is enforced, not assumed (Codex P1 on #892).
# A bare `git fetch --prune origin` inherits whatever refspec `origin` is
# configured with, and `--prune` deletes refs in that refspec's DESTINATION
# namespace. Under a mirror-style `remote.origin.fetch =
# +refs/heads/*:refs/heads/*`, the destination IS refs/heads/*, so the prune
# deletes LOCAL BRANCHES absent from the remote — including unpushed
# local-only work — before this script reaches a single merged-PR or
# exact-tip safety check. `fetch.pruneTags=true` widens it again to
# local-only tags. Both are ordinary operator configuration this script must
# not inherit, so the refmap is supplied explicitly (pinning the destination
# to refs/remotes/origin/*, the exact namespace gone_branches() reads via
# the full %(upstream) ref) and tag pruning/following is turned off for this one
# invocation. Nothing outside refs/remotes/origin/* can be deleted here.
#
# Preserve a safe configured source-to-destination mapping rather than replacing
# it with the conventional `heads/* → origin/*` mapping. A repository may map
# `refs/heads/release:refs/remotes/origin/stable`, for example; overwriting that
# mapping would prune `origin/stable` and mistake the live `release` branch for
# a deletion. Mappings outside the remote-tracking namespace remain excluded.
safe_fetch_refspecs() {
  local refspec safe_refspec
  local positive_refspecs=() negative_refspecs=()
  while IFS= read -r refspec; do
    safe_refspec=${refspec#+}
    case "$safe_refspec" in
      refs/heads/*:refs/remotes/origin/*)
        positive_refspecs+=("$refspec")
        ;;
      ^refs/heads/*)
        # A negative refspec is meaningful only alongside a positive mapping.
        # Do not hand `git fetch` a negatives-only list: it rejects it, which
        # makes --apply lose gone-upstream detection entirely. If no safe
        # configured positive mapping survives the filter below, use the
        # conventional safe mapping instead and do not inherit exclusions that
        # belonged to an unsafe or unrelated configured destination.
        negative_refspecs+=("$refspec")
        ;;
    esac
  done < <(git -C "$MAIN_WORKTREE" config --get-all remote.origin.fetch 2>/dev/null || true)

  if [ "${#positive_refspecs[@]}" -eq 0 ]; then
    printf '%s\n' '+refs/heads/*:refs/remotes/origin/*'
    return 0
  fi
  printf '%s\n' "${positive_refspecs[@]}"
  printf '%s\n' "${negative_refspecs[@]}"
}

if [ "$MODE" = "apply" ]; then
  if git -C "$MAIN_WORKTREE" remote get-url origin >/dev/null 2>&1; then
    SAFE_FETCH_REFSPECS=()
    while IFS= read -r refspec; do
      SAFE_FETCH_REFSPECS+=("$refspec")
    done < <(safe_fetch_refspecs)
    # Positional refspecs do NOT override remote.origin.fetch on their own.
    # Clear the configured refmap first: otherwise a mirror mapping such as
    # +refs/heads/*:refs/heads/* still updates local branches while this
    # supposedly-safe fetch runs. The positional safe mappings below are then
    # the complete fetch/prune destination set.
    if ! git -C "$MAIN_WORKTREE" -c fetch.pruneTags=false \
         fetch --prune --no-tags --refmap= origin "${SAFE_FETCH_REFSPECS[@]}" >/dev/null 2>&1; then
      echo "worktree-cleanup.sh: warning: \`git fetch --prune origin\` failed; gone-upstream detection may miss recently-merged branches this run" >&2
    fi
  fi
fi

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

# Read gone-upstream branches from `git branch -vv`. The format is:
#   [<spaces>]<branch> <sha> [origin/<branch>: gone] <subject>
# We grab the branch name when the third field carries `: gone]`.
gone_branches() {
  cd "$MAIN_WORKTREE" || return 0
  LC_ALL=C git branch -vv 2>/dev/null | awk '
    {
      # Strip leading whitespace and exactly ONE branch-list marker. Git uses
      # `* ` for the current branch and `+ ` for a branch checked out in
      # another worktree; a legal branch itself may begin with `+`, so removing
      # every leading plus turns `+ +foo` into the nonexistent `foo`.
      line = $0
      sub(/^[ \t]*/, "", line)
      sub(/^[*+][ \t]+/, "", line)
      # Branch name is the first whitespace-delimited token.
      n = split(line, parts, /[ \t]+/)
      branch = parts[1]
      # Search for the gone marker anywhere on the line.
      if (line ~ /\[[^]]*: gone\]/) {
        print branch
      }
    }
  '
}

# Return success when $1 (a remote source ref) is excluded by a configured
# negative fetch refspec. A negative refspec intentionally withholds both its
# fetch and its prune effects, so dry-run must treat its mapping as
# inconclusive rather than reporting a worktree that --apply will retain.
source_is_negatively_refspec_excluded() {
  local source="$1" refspec pattern prefix suffix
  while IFS= read -r refspec; do
    case "$refspec" in
      ^refs/heads/*)
        pattern=${refspec#^}
        case "$pattern" in
          *\*)
            prefix=${pattern%%\**}
            suffix=${pattern#*\*}
            case "$source" in
              "$prefix"*"$suffix") return 0 ;;
            esac
            ;;
          "$source") return 0 ;;
        esac
        ;;
    esac
  done < <(safe_fetch_refspecs)
  return 1
}

# Print the remote `refs/heads/...` ref that populates a full upstream ref such
# as `refs/remotes/origin/stable`, using only configured mappings whose destinations stay in
# `refs/remotes/origin/*`. The empty result is deliberately inconclusive: a
# branch with no safe configured mapping is never treated as stale.
origin_head_for_upstream() {
  local tracking_ref="$1" refspec source destination
  local dest_prefix dest_suffix source_prefix source_suffix wildcard
  case "$tracking_ref" in
    refs/remotes/origin/*) ;;
    *) return 1 ;;
  esac
  while IFS= read -r refspec; do
    refspec=${refspec#+}
    case "$refspec" in
      refs/heads/*:refs/remotes/origin/*) ;;
      *) continue ;;
    esac
    source=${refspec%%:*}
    destination=${refspec#*:}
    case "$destination" in
      *\*)
        dest_prefix=${destination%%\**}
        dest_suffix=${destination#*\*}
        case "$tracking_ref" in
          "$dest_prefix"*"$dest_suffix")
            wildcard=${tracking_ref#"$dest_prefix"}
            wildcard=${wildcard%"$dest_suffix"}
            source_prefix=${source%%\**}
            source_suffix=${source#*\*}
            source="$source_prefix$wildcard$source_suffix"
            source_is_negatively_refspec_excluded "$source" && return 1
            printf '%s\n' "$source"
            return 0
            ;;
        esac
        ;;
      "$tracking_ref")
        source_is_negatively_refspec_excluded "$source" && return 1
        printf '%s\n' "$source"
        return 0
        ;;
    esac
  done < <(safe_fetch_refspecs)
  return 1
}

# Detect local branches whose upstream tracks `origin/<name>` but which
# `git branch -vv` does NOT (yet) mark `gone` — because the remote-tracking
# ref refs/remotes/origin/<name> is stale, not because the remote branch
# still exists (#822). This is the dry-run counterpart to the `fetch
# --prune` above: a pure network READ (`git ls-remote`), never a local ref
# write, so it preserves the read-only-by-default contract while still
# surfacing the condition instead of silently omitting the branch.
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
#                        remote). Not evidence any branch was deleted: fail
#                        closed and report nothing.
stale_unpruned_branches() {
  cd "$MAIN_WORKTREE" || return 0
  local snapshot snapshot_rc=0 heads_file
  snapshot=$(git ls-remote --heads origin 2>/dev/null) || snapshot_rc=$?
  [ "$snapshot_rc" -eq 0 ] || return 0
  heads_file=$(mktemp "${TMPDIR:-/tmp}/wcleanup-remoteheads.XXXXXX") || return 0
  # `<sha>\t<refname>` per line; keep the refname column only.
  printf '%s\n' "$snapshot" | awk -F'\t' 'NF > 1 { print $2 }' >"$heads_file"
  local branch upstream remote_head
  # Git ref names may contain `|`, but cannot contain a tab. Use a tab record
  # separator so every branch/upstream pair round-trips losslessly.
  # `refname:short` expands an ambiguous local branch name to `heads/<name>`
  # when a tag shares its short name. The input is already constrained to
  # refs/heads, so strip that namespace directly and retain the canonical
  # branch name for the gone/PR lookups below.
  git for-each-ref --format='%(refname:lstrip=2)%09%(upstream)' refs/heads/ 2>/dev/null |
  while IFS=$'\t' read -r branch upstream; do
    [ -n "$branch" ] || continue
    case "$upstream" in
      refs/remotes/origin/*) ;;
      *) continue ;;
    esac
    is_gone_branch "$branch" && continue
    remote_head=$(origin_head_for_upstream "$upstream") || continue
    # Exact full-path match: `-Fx` so a branch named `feat` is never
    # satisfied by the remote having `feature`.
    grep -Fxq -- "$remote_head" "$heads_file" && continue
    echo "$branch"
  done
  rm -f "$heads_file"
}

# Parse `git worktree list --porcelain -z` into NUL-delimited six-field
# records: PATH, BRANCH_OR_DETACHED, DETACHED(0/1), HEAD, LOCKED(0/1),
# LOCK_REASON. Git ref names may contain `|`, and worktree paths and lock
# reasons may contain any printable delimiter, so pipe/tab records are not
# lossless. NUL is the one byte Git path/ref data cannot carry.
# BRANCH is the short ref name (without refs/heads/) or empty for detached;
# DETACHED is "1" iff the entry was marked detached.
worktree_records() {
  local line path branch detached head locked lock_reason ref records_file
  cd "$MAIN_WORKTREE" || return 1
  records_file=$(mktemp "${TMPDIR:-/tmp}/wcleanup-worktree-records.XXXXXX") || {
    echo "worktree-cleanup.sh: error: could not create a temporary worktree-record snapshot" >&2
    return 1
  }
  if ! git worktree list --porcelain -z >"$records_file" 2>/dev/null; then
    rm -f "$records_file"
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
  done <"$records_file"
  # Porcelain records normally end in a blank NUL field. Keep the flush for
  # older Git variants that omit the final separator.
  if [ -n "$path" ]; then
    printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
      "$path" "$branch" "$detached" "$head" "$locked" "$lock_reason"
  fi
  rm -f "$records_file"
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
trap 'rm -f "$GONE_FILE" "$REC_FILE" "$STALE_UNPRUNED_FILE"' EXIT

gone_branches >"$GONE_FILE"
worktree_records >"$REC_FILE"

is_gone_branch() {
  local b="$1"
  [ -z "$b" ] && return 1
  grep -Fxq -- "$b" "$GONE_FILE"
}

# #892: the authoritative "would --apply treat this branch as gone" test.
# is_gone_branch() alone answers only "has `git branch -vv` already marked
# this gone" — true after a `fetch --prune` (i.e. always true under --apply,
# since --apply prunes before computing GONE_FILE) but false under --dry-run
# whenever the local remote-tracking ref simply hasn't been pruned yet, even
# though the remote branch is provably deleted (stale_unpruned_branches()).
# Every consumer that decides whether a WORKTREE (not just a plain local
# branch) is stale MUST use this union, not is_gone_branch() alone — using
# is_gone_branch() alone made --dry-run silently omit a worktree that
# --apply went on to remove, because dry-run's STALE_UNPRUNED_FILE only fed
# the separate merged-branch sweep further down, never the worktree
# classification here (#892). STALE_UNPRUNED_FILE is empty under --apply
# (never populated there — see the dry-run-only guard below), so this union
# is a no-op under --apply and changes nothing there.
is_effectively_gone() {
  local b="$1"
  [ -z "$b" ] && return 1
  is_gone_branch "$b" && return 0
  grep -Fxq -- "$b" "$STALE_UNPRUNED_FILE"
}

# Dry-run only (#822): under --apply the `fetch --prune` above already
# converted every truly-gone branch into a `git branch -vv` gone marker, so
# GONE_FILE is already authoritative there and this probe would only spend
# network calls to rediscover nothing. Under dry-run, GONE_FILE reflects
# whatever was pruned before this invocation (possibly never), so probe the
# remote directly for anything it might be missing.
if [ "$MODE" = "dry-run" ]; then
  stale_unpruned_branches >"$STALE_UNPRUNED_FILE"
fi

branch_checked_out() {
  local b="$1" rec_path rec_branch rec_detached rec_head rec_locked rec_lock_reason
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
  # #892: uses is_effectively_gone(), not is_gone_branch() alone, so a
  # worktree whose branch has an unpruned-but-provably-deleted remote ref is
  # classified identically to how --apply (which prunes first) will treat
  # it. Without this, --dry-run silently omitted worktrees in exactly this
  # state — the WORKTREE never reached the gone-upstream branch at all,
  # while --apply's `fetch --prune` made the same branch `gone` and removed
  # the worktree. The two modes must agree on what counts as gone.
  if is_effectively_gone "$WT_BRANCH"; then
    WT_STALE_NOTE=""
    if ! is_gone_branch "$WT_BRANCH"; then
      WT_STALE_NOTE=" (remote-tracking ref is stale, not yet gone per \`git branch -vv\` — run \`git fetch --prune\` or re-run with --apply)"
    fi
    # EVERY branch-attached worktree must clear the comprehensive content gate
    # before ANY removal, including this gone-upstream fast path. Without this
    # the invariant is only half-real: rule 1 runs FIRST and `continue`s, so a
    # checkout whose upstream is already [gone] never reached
    # worktree_content_state and `--apply` deleted uncommitted, untracked,
    # gitignored or submodule content outright — the very loss the gate was
    # added to prevent (#762 r3 P1).
    #
    # The gate used to be scoped to PR-slug paths, on the reasoning that a
    # non-slug gone-upstream worktree was outside what this tool claims to own.
    # #822 invalidated that reasoning (Codex P1 on #892): before #822 a branch
    # only became `gone` when the OPERATOR had pruned, so the tool acted on a
    # set the operator had already curated. Now `--apply` prunes first and the
    # tool discovers gone branches itself, so worktrees that were never
    # eligible for unattended removal are now reached — and a free-form path
    # (`~/GitHub/.mergepath-worktrees/spike-foo`) is exactly the shape holding
    # a `.env` or `node_modules/` that exists nowhere else. Widening the
    # detection without widening the gate would have made this fix a
    # data-destroying one. The gate is cheap (one `git status`) and refuses
    # only removals that were never provably safe.
    wt_state=$(worktree_content_state "$WT_PATH") || true
    if [ "$wt_state" != "clean" ] && [ "$wt_state" != "missing" ]; then
      if [ -n "$pr_num" ]; then
        wt_gate_label="PR #${pr_num} gone-upstream"
      else
        wt_gate_label="gone-upstream"
      fi
      print_record "[${wt_gate_label} but working tree is ${wt_state} — review manually, keeping]" "$C_YELLOW" \
        "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[gone]" "" "$WT_LOCK_REASON"
      if [ "$wt_state" = "ignored" ]; then
        echo "    reason:   gitignored content only (e.g. .env, *.key, node_modules/) — \`git worktree remove\` deletes it with or without --force, and it exists nowhere else; move or delete it by hand first${WT_STALE_NOTE}"
      else
        echo "    reason:   uncommitted or untracked content (or an unreadable status) — removing the worktree would destroy work that exists nowhere else; commit, stash, or discard it by hand first${WT_STALE_NOTE}"
      fi
      SUMMARY_UNCLEAN_KEPT+=("$WT_PATH ($WT_BRANCH [gone], $wt_state)")
      if [ -n "$WT_STALE_NOTE" ]; then
        SUMMARY_STALE_UNPRUNED+=("$WT_BRANCH")
      fi
      continue
    fi
    if [ "$WT_LOCKED" = "1" ]; then
      print_record "[LOCKED gone-upstream]" "$C_YELLOW" \
        "$WT_PATH" "$WT_BRANCH" "$WT_HEAD" "[gone]" "" "$WT_LOCK_REASON"
      SUMMARY_LOCKED+=("$WT_PATH ($WT_BRANCH [gone])")
      if [ -n "$WT_STALE_NOTE" ]; then
        echo "    reason:   locked worktree on a gone-upstream branch${WT_STALE_NOTE}"
        SUMMARY_STALE_UNPRUNED+=("$WT_BRANCH")
      fi
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
      if [ -n "$WT_STALE_NOTE" ]; then
        echo "    reason:   gone-upstream branch${WT_STALE_NOTE}"
        SUMMARY_STALE_UNPRUNED+=("$WT_BRANCH")
      fi
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
# The sweep set is GONE_FILE (branches `git branch -vv` already marks gone)
# UNION STALE_UNPRUNED_FILE (dry-run only: branches whose remote-tracking ref
# is stale but not yet pruned, per stale_unpruned_branches() — #822). Tagging
# each branch by source lets the stale-unpruned case get its own summary
# counter and an explicit reason note, without a second copy of this loop.
# STALE_UNPRUNED_FILE is empty under --apply (that mode already ran `fetch
# --prune` before GONE_FILE was computed, so the branch is already tagged
# `gone` there), so this union changes nothing under --apply.
MERGE_SWEEP_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-mergesweep.XXXXXX")
{
  awk '{ printf "%s\t%s\n", $0, "gone" }' "$GONE_FILE"
  awk '{ printf "%s\t%s\n", $0, "stale-unpruned" }' "$STALE_UNPRUNED_FILE"
} >"$MERGE_SWEEP_FILE"

while IFS=$'\t' read -r LOCAL_BRANCH SWEEP_SRC; do
  [ -n "$LOCAL_BRANCH" ] || continue
  STALE_NOTE=""
  if [ "$SWEEP_SRC" = "stale-unpruned" ]; then
    STALE_NOTE=" (remote-tracking ref is stale, not yet gone per \`git branch -vv\` — run \`git fetch --prune\` or re-run with --apply)"
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
    # #892: this path never appended STALE_NOTE, so a checked-out branch
    # with an unpruned remote-tracking ref printed no hint that --apply's
    # `fetch --prune` would reclassify it (this branch also drives the
    # worktree itself via the is_effectively_gone() rule above — the two
    # must read consistently rather than one going silent).
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

  # Collect known worktree paths into a set (one per line) and check each
  # subdir against it. REC_FILE is NUL-delimited: parsing it with awk or grep
  # treats it as binary on some platforms and silently drops registered paths,
  # which can turn an active .claude/worktrees checkout into an orphan-clean
  # deletion candidate. Consume all six fields so the next record stays
  # aligned, and emit only the first (the worktree path).
  KNOWN_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-known.XXXXXX")
  while IFS= read -r -d '' known_path \
    && IFS= read -r -d '' known_branch \
    && IFS= read -r -d '' known_detached \
    && IFS= read -r -d '' known_head \
    && IFS= read -r -d '' known_locked \
    && IFS= read -r -d '' known_lock_reason; do
    printf '%s\n' "$known_path"
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
    abs=$(cd "$d" 2>/dev/null && pwd -P) || continue

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

    if ! grep -Fxq -- "$abs" "$KNOWN_FILE"; then
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
# Branches whose remote-tracking ref is stale rather than genuinely gone —
# a `git branch -vv` false-negative this run would otherwise retain silently
# (#822). Dry-run only; --apply prunes before classification so this is
# always 0 there. Each of these ALSO appears in exactly one bucket above
# (merged branches / gone kept / merged+extra / gone unverified) by its
# actual merged-PR status — this counter exists so the unpruned-ref CLASS
# itself is never invisible, even though it is not a distinct disposition.
#
# Counted by DISTINCT BRANCH, not by append (Codex P2 on #892). One branch
# can legitimately reach two appenders: the worktree classification records
# it, and the merged-branch sweep — which runs over every stale-unpruned
# branch regardless of whether a worktree is attached — records it again. The
# raw array length therefore reported three for two branches in exactly the
# worktree case this PR added. The array is kept as-is so each append site
# stays a plain, order-independent statement; the de-duplication happens once,
# here, where the CLASS (not the appends) is what is being reported.
stale_unpruned_distinct_count() {
  if [ "${#SUMMARY_STALE_UNPRUNED[@]}" -eq 0 ]; then
    echo 0
    return 0
  fi
  printf '%s\n' "${SUMMARY_STALE_UNPRUNED[@]}" | sort -u | wc -l | tr -d '[:space:]'
}
printf "  gone (stale remote ref, unpruned): %s\n" "$(stale_unpruned_distinct_count)"
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
  exit 2
fi
exit 0
