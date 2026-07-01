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
#                    (gone-upstream worktrees + detached closed-PR
#                    worktrees that are NOT locked). Without further flags,
#                    locked worktrees and orphaned .claude/worktrees/*
#                    directories are listed but skipped.
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
#   2. Detached `mergepath-pr-*` worktree. Worktree path matches
#      ^(/private/tmp|/Users/.*/GitHub)/mergepath-pr-([0-9]+)$ AND HEAD
#      is detached. Cross-check PR state via `gh pr view <num> --json
#      state`; flag as removable if state is CLOSED or MERGED.
#      Worktrees for OPEN PRs are listed but flagged as still-active.
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
# Locked detection. `git worktree list --porcelain` emits a `locked`
# line (possibly with a reason) for locked entries. We classify locked
# worktrees separately so --apply doesn't disrupt active sessions.
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
  tip=$(git -C "$MAIN_WORKTREE" rev-parse "$branch" 2>/dev/null) || { echo "unknown"; return 1; }
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
  git branch -vv 2>/dev/null | awk '
    {
      # Strip leading whitespace and the current-branch marker.
      line = $0
      sub(/^[ *+]+/, "", line)
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

# Parse `git worktree list --porcelain` into pipe-delimited records:
#   PATH|BRANCH_OR_DETACHED|HEAD|LOCKED(0/1)|LOCK_REASON
# BRANCH is the short ref name (without refs/heads/) or empty for detached;
# DETACHED is "1" iff the entry was marked detached.
worktree_records() {
  cd "$MAIN_WORKTREE" || return 0
  git worktree list --porcelain 2>/dev/null | awk '
    function flush() {
      if (path != "") {
        printf "%s|%s|%s|%s|%d|%s\n", path, branch, detached, head, locked, lock_reason
      }
      path=""; branch=""; detached="0"; head=""; locked=0; lock_reason=""
    }
    /^worktree / { flush(); path = substr($0, 10); next }
    /^HEAD /     { head = substr($0, 6); next }
    /^branch /   {
      ref = substr($0, 8)
      sub(/^refs\/heads\//, "", ref)
      branch = ref
      next
    }
    /^detached/  { detached = "1"; next }
    /^locked/    {
      locked = 1
      if (length($0) > 6) {
        lock_reason = substr($0, 8)
      }
      next
    }
    END { flush() }
  '
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
trap 'rm -f "$GONE_FILE" "$REC_FILE"' EXIT

gone_branches >"$GONE_FILE"
worktree_records >"$REC_FILE"

is_gone_branch() {
  local b="$1"
  [ -z "$b" ] && return 1
  grep -Fxq -- "$b" "$GONE_FILE"
}

branch_checked_out() {
  local b="$1"
  awk -F'|' -v branch="$b" '$2 == branch { found = 1 } END { exit found ? 0 : 1 }' "$REC_FILE"
}

# ── Classify and act ──────────────────────────────────────────────────
SUMMARY_GONE=()
SUMMARY_DETACHED=()
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
  if (cd "$MAIN_WORKTREE" && git worktree remove --force "$path") >/dev/null 2>&1; then
    SUMMARY_REMOVED+=("$path")
    return 0
  fi
  SUMMARY_FAILED+=("$path")
  return 1
}

echo "${C_BOLD}worktree-cleanup.sh${C_RESET} — mode=${MODE} main=${MAIN_WORKTREE}"
echo ""

while IFS='|' read -r WT_PATH WT_BRANCH WT_DETACHED WT_HEAD WT_LOCKED WT_LOCK_REASON; do
  [ -z "$WT_PATH" ] && continue
  # Skip the main worktree itself.
  if [ "$WT_PATH" = "$MAIN_WORKTREE" ]; then
    continue
  fi

  if [ "$WT_DETACHED" = "1" ]; then
    # Detached. Check if path matches mergepath-pr-<num>.
    pr_num=""
    if [[ "$WT_PATH" =~ ^(/private/tmp|/tmp|/Users/[^/]+/GitHub)/mergepath-pr-([0-9]+)$ ]]; then
      pr_num="${BASH_REMATCH[2]}"
    fi
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
  if is_gone_branch "$WT_BRANCH"; then
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
  fi
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
while IFS= read -r LOCAL_BRANCH; do
  [ -n "$LOCAL_BRANCH" ] || continue
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
    echo "    reason:   could not verify merged state (gh missing, unauthenticated, or API error) — branch NOT evaluated"
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
    echo "    reason:   no merged PR found for head name (unpublished or unmerged work)"
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
    echo "    reason:   PR for this head name merged, but the local tip carries commit(s) beyond the merged head; not auto-deleted (may be unmerged follow-up work — delete by hand after review)"
    SUMMARY_DIVERGED_KEPT+=("$LOCAL_BRANCH")
    continue
  fi

  # exact: tip == merged head → provably fully merged, safe to delete.
  if branch_checked_out "$LOCAL_BRANCH"; then
    print_record "[MERGED local branch checked out — keeping]" "$C_YELLOW" \
      "$MAIN_WORKTREE" "$LOCAL_BRANCH" "$(git -C "$MAIN_WORKTREE" rev-parse "$LOCAL_BRANCH" 2>/dev/null || true)" "[gone]" "MERGED" ""
    SUMMARY_LOCAL_BRANCH+=("$LOCAL_BRANCH (checked out)")
    if [ "$MODE" = "apply" ]; then
      echo "    -> skipped (branch is checked out in a worktree)"
      SUMMARY_SKIPPED+=("$LOCAL_BRANCH (checked out)")
    fi
    continue
  fi

  print_record "[MERGED local branch]" "$C_RED" \
    "$MAIN_WORKTREE" "$LOCAL_BRANCH" "$(git -C "$MAIN_WORKTREE" rev-parse "$LOCAL_BRANCH" 2>/dev/null || true)" "[gone]" "MERGED" ""
  SUMMARY_LOCAL_BRANCH+=("$LOCAL_BRANCH")
  if [ "$MODE" = "apply" ]; then
    echo "    -> deleting local branch"
    if (cd "$MAIN_WORKTREE" && git branch -D "$LOCAL_BRANCH") >/dev/null 2>&1; then
      SUMMARY_REMOVED+=("$LOCAL_BRANCH (local branch)")
    else
      SUMMARY_FAILED+=("$LOCAL_BRANCH (local branch)")
    fi
  fi
done <"$GONE_FILE"

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
  # subdir against it.
  KNOWN_FILE=$(mktemp "${TMPDIR:-/tmp}/wcleanup-known.XXXXXX")
  awk -F'|' '{ print $1 }' "$REC_FILE" >"$KNOWN_FILE"
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
total_candidates=$(( ${#SUMMARY_GONE[@]} + ${#SUMMARY_DETACHED[@]} + ${#SUMMARY_LOCKED[@]} + ${#SUMMARY_LOCAL_BRANCH[@]} + ${#SUMMARY_ORPHAN[@]} + ${#SUMMARY_DIVERGED_KEPT[@]} ))
if [ "$total_candidates" -gt 0 ]; then
  echo ""
  echo "${C_DIM}Dry run. Re-run with --apply to remove safe candidates.${C_RESET}"
  echo "${C_DIM}  --force-locked   also remove LOCKED entries (#288)${C_RESET}"
  echo "${C_DIM}  --orphan-clean   also rm -rf orphans under .claude/worktrees/${C_RESET}"
  exit 2
fi
exit 0
