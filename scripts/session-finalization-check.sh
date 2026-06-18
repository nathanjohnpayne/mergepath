#!/usr/bin/env bash
# Detect likely orphaned agent work before a session goes idle.
set -euo pipefail

ROOT=${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
FAIL=0
report(){ printf '%s\n' "$*"; }
flag(){ FAIL=1; report "ORPHANED-WORK: $*"; }

branch_tip_has_merged_pr() {
  local b=$1 tip merged_heads
  [ -n "$b" ] || return 1
  tip=$(git -C "$ROOT" rev-parse "$b" 2>/dev/null) || return 1
  command -v gh >/dev/null 2>&1 || return 1
  merged_heads=$(cd "$ROOT" && gh pr list --head "$b" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null) || return 1
  printf '%s\n' "$merged_heads" | grep -Fxq "$tip"
}

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not a git worktree: $ROOT" >&2; exit 2
fi

porcelain=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=normal)
if [ -n "$porcelain" ]; then
  flag "dirty current worktree at $ROOT"
  printf '%s\n' "$porcelain" | sed 's/^/  /'
fi

branch=$(git -C "$ROOT" branch --show-current || true)
if [ -n "$branch" ]; then
  upstream=$(git -C "$ROOT" for-each-ref --format='%(upstream:short)' "refs/heads/$branch" 2>/dev/null || true)
  merged_pr=0
  if branch_tip_has_merged_pr "$branch"; then
    merged_pr=1
  fi
  upstream_exists=0
  if [ -n "$upstream" ] && git -C "$ROOT" rev-parse --verify -q "$upstream" >/dev/null; then
    upstream_exists=1
  fi
  if [ -z "$upstream" ]; then
    if [ -n "$porcelain" ]; then flag "branch '$branch' has no upstream while local changes exist"; fi
  elif [ "$upstream_exists" -ne 1 ]; then
    if [ "$merged_pr" -ne 1 ]; then
      flag "branch '$branch' upstream '$upstream' is missing/gone"
    fi
  fi
  base_ref=origin/main
  if [ "$upstream_exists" -eq 1 ]; then
    base_ref=$upstream
  fi
  if git -C "$ROOT" rev-parse --verify -q "$base_ref" >/dev/null; then
    ahead=$(git -C "$ROOT" rev-list --count "$base_ref..HEAD" 2>/dev/null || echo 0)
    if [ "$ahead" != "0" ]; then
      if [ "$merged_pr" -eq 1 ]; then
        :
      elif git -C "$ROOT" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
        :
      else
        flag "branch '$branch' has $ahead commit(s) not reachable from $base_ref or origin/main; verify an open/merged PR before closing the session"
      fi
    fi
  fi
fi

stash_list=$(git -C "$ROOT" stash list || true)
if [ -n "$stash_list" ]; then
  while IFS= read -r stash; do
    ref=${stash%%:*}
    files=$(git -C "$ROOT" stash show --name-only "$ref" 2>/dev/null | sed '/^$/d' || true)
    if [ -n "$files" ]; then
      flag "non-empty stash present: $stash"
      printf '%s\n' "$files" | sed 's/^/  /'
    fi
  done <<< "$stash_list"
fi

# Report dirty linked worktrees, including common agent temp roots when they are registered git worktrees.
while IFS= read -r wt; do
  [ "$wt" = "$ROOT" ] && continue
  [ -d "$wt/.git" ] || [ -f "$wt/.git" ] || continue
  wt_status=$(git -C "$wt" status --porcelain=v1 --untracked-files=normal 2>/dev/null || true)
  if [ -n "$wt_status" ]; then
    flag "dirty auxiliary worktree at $wt"
    printf '%s\n' "$wt_status" | sed 's/^/  /'
  fi
done < <(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,""); print}')

if [ "$FAIL" -eq 0 ]; then
  report "session-finalization-check: clean"
fi
exit "$FAIL"
