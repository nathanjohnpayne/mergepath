#!/usr/bin/env bash
# install-git-hooks.sh — point this clone's git hooks at scripts/git-hooks/
# (#2221), which enables the repo-lint pre-push hook. Hub-only tooling.
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
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install-git-hooks: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "install-git-hooks: not inside a git work tree" >&2
  exit 2
}
if [ ! -f "$root/$HOOKS_PATH/pre-push" ]; then
  echo "install-git-hooks: $HOOKS_PATH/pre-push is not in this checkout" >&2
  exit 2
fi

current=$(git -C "$root" config --local --get core.hooksPath 2>/dev/null || true)

case "$ACTION" in
  check)
    if [ "$current" = "$HOOKS_PATH" ]; then
      echo "install-git-hooks: installed (core.hooksPath=$HOOKS_PATH)"
      exit 0
    fi
    echo "install-git-hooks: not installed (core.hooksPath=${current:-unset})"
    exit 1
    ;;
  uninstall)
    if [ "$current" = "$HOOKS_PATH" ]; then
      git -C "$root" config --local --unset core.hooksPath
      echo "install-git-hooks: removed core.hooksPath"
    else
      echo "install-git-hooks: nothing to remove (core.hooksPath=${current:-unset})"
    fi
    exit 0
    ;;
esac

if [ "$current" = "$HOOKS_PATH" ]; then
  echo "install-git-hooks: already installed (core.hooksPath=$HOOKS_PATH)"
  exit 0
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

git -C "$root" config --local core.hooksPath "$HOOKS_PATH"
if [ "$(git -C "$root" config --local --get core.hooksPath)" != "$HOOKS_PATH" ]; then
  echo "install-git-hooks: core.hooksPath did not read back as $HOOKS_PATH" >&2
  exit 1
fi
echo "install-git-hooks: installed (core.hooksPath=$HOOKS_PATH); git push now runs the repo-lint pre-push checks"
if [ -n "$active" ]; then
  echo "install-git-hooks: note: these hooks in $common/hooks no longer run:$active" >&2
fi
echo "install-git-hooks: bypass in an emergency with git push --no-verify or MERGEPATH_PREPUSH_SKIP=1; CI lint stays authoritative"
