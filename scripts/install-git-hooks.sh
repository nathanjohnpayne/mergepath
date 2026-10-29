#!/usr/bin/env bash
# install-git-hooks.sh — point this clone's git hooks at scripts/git-hooks/
# (#2221), which enables the repo-lint pre-push hook. Propagated to every
# consumer with the hook and its runner (#2844); docs/agents/testing-
# requirements.md § Pre-push hook in the hub has the full reference.
#
# Idempotent and local: it writes exactly one key, `core.hooksPath`, to this
# repository's own config (`git config --local`); global and system config
# are never touched. The key is shared by every worktree of the clone, and
# the relative value resolves against each worktree's own top level, so a
# worktree whose branch predates the hook simply has no pre-push hook.
#
# Usage:
#   scripts/install-git-hooks.sh             install (no-op if already installed)
#   scripts/install-git-hooks.sh --check     exit 0 if installed, 1 if not
#
# --check also proves the hook is reachable from the worktree it runs in:
# `git rev-parse --git-path hooks` must resolve to an executable pre-push,
# and git must not see the checkout as bare (a shared `core.bare = true`
# makes the hook exit before it can check anything, #2578). It warns when a
# linked worktree inherits the relative value from the shared config, which
# resolves against that worktree's own checkout.
#   scripts/install-git-hooks.sh --uninstall remove the key if it is ours
#   scripts/install-git-hooks.sh --force     replace a different core.hooksPath
#
# Setting core.hooksPath stops git from running hooks in .git/hooks/. The
# installer lists any active hook there so nothing is disabled silently.

set -euo pipefail

HOOKS_PATH=scripts/git-hooks
ACTION=install
FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) ACTION=check ;;
    --uninstall) ACTION=uninstall ;;
    --force) FORCE=1 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "install-git-hooks: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# A shared `core.bare = true` (with extensions.worktreeConfig it reaches
# every linked worktree) leaves no top level to resolve; name the setting
# instead of reporting "not inside a git work tree" (#2578).
if [ "$(git rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
  origin=$(git config --show-origin --get core.bare 2>/dev/null | cut -f1)
  origin=${origin#file:}
  echo "install-git-hooks: git reports this checkout as bare (core.bare = true in ${origin:-the repository config}), so the pre-push hook cannot check anything here; restore it with: git config --file \"${origin:-<that file>}\" core.bare false" >&2
  [ "$ACTION" = check ] && exit 1
  exit 2
fi
root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "install-git-hooks: not inside a git work tree" >&2
  exit 2
}
if [ ! -f "$root/$HOOKS_PATH/pre-push" ]; then
  echo "install-git-hooks: $HOOKS_PATH/pre-push is not in this checkout" >&2
  exit 2
fi

# All values, not the last one: a duplicated key is ambiguous to git and is
# normalized (--force) rather than reported as installed.
values=$(git -C "$root" config --local --get-all core.hooksPath 2>/dev/null || true)
count=$(printf '%s' "$values" | grep -c '' || true)
current=$(printf '%s\n' "$values" | tail -n 1)
[ "$count" -le 1 ] || current="$(printf '%s' "$values" | tr '\n' ',') ($count values)"
hook_executable=0
[ -x "$root/$HOOKS_PATH/pre-push" ] && hook_executable=1

case "$ACTION" in
  check)
    if [ "$current" = "$HOOKS_PATH" ] && [ "$hook_executable" -eq 1 ]; then
      # The key being ours is not proof that git finds the hook from here: a
      # per-worktree value (config.worktree) overrides it, and a relative
      # value resolves against this worktree's checkout.
      effective=$(git -C "$root" rev-parse --git-path hooks)
      case "$effective" in /*) ;; *) effective="$root/$effective" ;; esac
      if [ ! -f "$effective/pre-push" ] || [ ! -x "$effective/pre-push" ]; then
        echo "install-git-hooks: core.hooksPath resolves to $effective from this worktree, and there is no executable pre-push there, so git runs no hook for a push from here"
        exit 1
      fi
      scoped=$(git -C "$root" config --show-scope --get core.hooksPath 2>/dev/null || true)
      git_dir=$(git -C "$root" rev-parse --absolute-git-dir)
      # --git-common-dir may be relative (`.git`), and relative to $root,
      # not to the directory --check was started from.
      common_dir=$(cd "$root" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
      if [ "$(cd "$git_dir" && pwd -P)" != "$common_dir" ] && [ "${scoped%%$'\t'*}" = local ]; then
        case "${scoped#*$'\t'}" in
          /*) ;;
          *) echo "install-git-hooks: warning: this linked worktree inherits the relative core.hooksPath=${scoped#*$'\t'} from the shared config ($common_dir/config); git resolves it against this worktree's own checkout, so a branch here without that directory's pre-push pushes with no hook and no output. To pin one hook directory for this worktree: git config --worktree core.hooksPath <absolute path> (needs extensions.worktreeConfig)" >&2 ;;
        esac
      fi
      echo "install-git-hooks: installed (core.hooksPath=$HOOKS_PATH; this worktree runs $effective/pre-push)"
      exit 0
    fi
    if [ "$current" = "$HOOKS_PATH" ]; then
      echo "install-git-hooks: core.hooksPath is set but $HOOKS_PATH/pre-push is not executable, so git skips it (restore its mode with git checkout)"
    else
      echo "install-git-hooks: not installed (core.hooksPath=${current:-unset})"
    fi
    exit 1
    ;;
  uninstall)
    if [ -n "$values" ] && [ -z "$(printf '%s\n' "$values" | grep -v -x -F "$HOOKS_PATH" || true)" ]; then
      git -C "$root" config --local --unset-all core.hooksPath
      echo "install-git-hooks: removed core.hooksPath"
    else
      echo "install-git-hooks: nothing to remove (core.hooksPath=${current:-unset} is not only ours)"
    fi
    exit 0
    ;;
esac

if [ "$current" = "$HOOKS_PATH" ] && [ "$hook_executable" -eq 1 ]; then
  echo "install-git-hooks: already installed (core.hooksPath=$HOOKS_PATH)"
  exit 0
fi
if [ "$current" = "$HOOKS_PATH" ]; then
  current=''   # ours, but the hook is not executable: fall through to the mode check
fi
if [ -n "$current" ] && [ "$FORCE" -ne 1 ]; then
  echo "install-git-hooks: core.hooksPath is already set to '$current'; rerun with --force to replace it" >&2
  exit 1
fi

if [ ! -x "$root/$HOOKS_PATH/pre-push" ]; then
  echo "install-git-hooks: $HOOKS_PATH/pre-push is not executable (git skips it); restore its mode with git checkout" >&2
  exit 1
fi

common=$(git -C "$root" rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$root/$common" ;; esac
active=''
if [ -d "$common/hooks" ]; then
  for hook in "$common"/hooks/*; do
    [ -f "$hook" ] && [ -x "$hook" ] || continue
    case "$hook" in *.sample) continue ;; esac
    active="$active $(basename "$hook")"
  done
fi

git -C "$root" config --local --replace-all core.hooksPath "$HOOKS_PATH"
if [ "$(git -C "$root" config --local --get-all core.hooksPath)" != "$HOOKS_PATH" ]; then
  echo "install-git-hooks: core.hooksPath did not read back as $HOOKS_PATH" >&2
  exit 1
fi
echo "install-git-hooks: installed (core.hooksPath=$HOOKS_PATH); git push now runs the repo-lint pre-push checks"
if [ -n "$active" ]; then
  echo "install-git-hooks: note: these hooks in $common/hooks no longer run:$active" >&2
fi
echo "install-git-hooks: bypass in an emergency with git push --no-verify or MERGEPATH_PREPUSH_SKIP=1; CI lint stays authoritative"
