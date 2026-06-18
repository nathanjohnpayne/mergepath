#!/usr/bin/env bash
# Detect likely orphaned agent work before a session goes idle.
set -euo pipefail

ROOT=${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
FAIL=0
report(){ printf '%s\n' "$*"; }
flag(){ FAIL=1; report "ORPHANED-WORK: $*"; }

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not a git worktree: $ROOT" >&2; exit 2
fi

porcelain=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=normal)
if [ -n "$porcelain" ]; then
  flag "dirty current worktree at $ROOT"
  printf '%s\n' "$porcelain" | sed 's/^/  /'
fi

branch=$(git -C "$ROOT" branch --show-current || true)
upstream=$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
if [ -n "$branch" ]; then
  if [ -z "$upstream" ]; then
    if [ -n "$porcelain" ]; then flag "branch '$branch' has no upstream while local changes exist"; fi
  elif ! git -C "$ROOT" rev-parse --verify -q "$upstream" >/dev/null; then
    flag "branch '$branch' upstream '$upstream' is missing/gone"
  fi
  base_ref=${upstream:-origin/main}
  if git -C "$ROOT" rev-parse --verify -q "$base_ref" >/dev/null; then
    ahead=$(git -C "$ROOT" rev-list --count "$base_ref..HEAD" 2>/dev/null || echo 0)
    if [ "$ahead" != "0" ]; then
      if git -C "$ROOT" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
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
