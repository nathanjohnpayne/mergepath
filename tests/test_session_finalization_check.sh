#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/session-finalization-check.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/session-finalization.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
pass(){ echo "PASS: $*"; }
fail(){ echo "FAIL: $*" >&2; exit 1; }
mkrepo(){ local d=$1; mkdir -p "$d"; git -C "$d" init -q; git -C "$d" config user.email a@example.com; git -C "$d" config user.name A; echo base >"$d/file.txt"; git -C "$d" add .; git -C "$d" commit -qm init; git -C "$d" branch -M main; }

mkrepo "$TMP/clean"
out=$("$SCRIPT" "$TMP/clean") && [[ $out == *clean* ]] && pass clean || fail clean

echo change >>"$TMP/clean/file.txt"
if out=$("$SCRIPT" "$TMP/clean" 2>&1); then fail dirty-tracked; fi
[[ $out == *file.txt* ]] && pass dirty-tracked || fail "dirty output: $out"
git -C "$TMP/clean" checkout -- file.txt

echo new >"$TMP/clean/new.txt"
if out=$("$SCRIPT" "$TMP/clean" 2>&1); then fail untracked; fi
[[ $out == *new.txt* ]] && pass untracked || fail "untracked output: $out"
rm "$TMP/clean/new.txt"

echo stash >"$TMP/clean/file.txt"; git -C "$TMP/clean" stash push -qm wip
if out=$("$SCRIPT" "$TMP/clean" 2>&1); then fail stash; fi
[[ $out == *stash@* && $out == *file.txt* ]] && pass stash || fail "stash output: $out"
git -C "$TMP/clean" stash drop -q

mkrepo "$TMP/wt-main"
git -C "$TMP/wt-main" worktree add -q "$TMP/wt-aux" -b aux
echo dirty >>"$TMP/wt-aux/file.txt"
if out=$("$SCRIPT" "$TMP/wt-main" 2>&1); then fail aux; fi
[[ $out == *"dirty auxiliary worktree"* && $out == *"file.txt"* ]] && pass aux || fail "aux output: $out"
