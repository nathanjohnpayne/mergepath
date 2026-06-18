#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/session-finalization-check.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/session-finalization.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
pass(){ echo "PASS: $*"; }
fail(){ echo "FAIL: $*" >&2; exit 1; }
mkrepo(){ local d=$1; mkdir -p "$d"; git -C "$d" init -q; git -C "$d" config user.email a@example.com; git -C "$d" config user.name A; echo base >"$d/file.txt"; git -C "$d" add .; git -C "$d" commit -qm init; git -C "$d" branch -M main; }
mkremote_repo(){ local d=$1 r=$2; git init --bare -q "$r"; mkrepo "$d"; git -C "$d" remote add origin "$r"; git -C "$d" push -q -u origin main; }

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

mkremote_repo "$TMP/merged" "$TMP/merged.git"
git -C "$TMP/merged" switch -q -c feature
echo feature >>"$TMP/merged/file.txt"
git -C "$TMP/merged" commit -am feature -q
merged_tip=$(git -C "$TMP/merged" rev-parse HEAD)
git -C "$TMP/merged" push -q -u origin feature
git -C "$TMP/merged" push -q origin --delete feature
git -C "$TMP/merged" fetch -q --prune
stub="$TMP/stub-bin"; mkdir -p "$stub"
cat >"$stub/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  head=""
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --head) head=\$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ "\$head" = "feature" ] && echo "$merged_tip" || true
  exit 0
fi
exit 1
STUB
chmod +x "$stub/gh"
out=$(PATH="$stub:$PATH" "$SCRIPT" "$TMP/merged") && [[ $out == *clean* ]] && pass merged-squash-branch || fail "merged branch output: $out"
echo followup >>"$TMP/merged/file.txt"
git -C "$TMP/merged" commit -am followup -q
if out=$(PATH="$stub:$PATH" "$SCRIPT" "$TMP/merged" 2>&1); then fail merged-branch-new-commit; fi
[[ $out == *"upstream 'origin/feature' is missing/gone"* && $out == *"not reachable"* ]] && pass merged-branch-new-commit || fail "merged branch new commit output: $out"

mkremote_repo "$TMP/unmerged" "$TMP/unmerged.git"
git -C "$TMP/unmerged" switch -q -c feature
echo feature >>"$TMP/unmerged/file.txt"
git -C "$TMP/unmerged" commit -am feature -q
git -C "$TMP/unmerged" push -q -u origin feature
git -C "$TMP/unmerged" push -q origin --delete feature
git -C "$TMP/unmerged" fetch -q --prune
if out=$("$SCRIPT" "$TMP/unmerged" 2>&1); then fail unmerged-ahead; fi
[[ $out == *"upstream 'origin/feature' is missing/gone"* && $out == *"not reachable"* ]] && pass unmerged-ahead || fail "unmerged output: $out"
