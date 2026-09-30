#!/usr/bin/env bash
set -euo pipefail

# tests/test_verify_propagation_pr.sh
#
# Fixture-driven tests for scripts/workflow/verify-propagation-pr.sh —
# the authoritative faithful-mirror check behind the propagation-PR
# review lane (REVIEW_POLICY.md § Propagation PR review lane).
#
# Each case builds a throwaway "mergepath" checkout and a throwaway
# "consumer" git repo with a base..head range, then asserts the
# verifier's exit code:
#   0 = faithful mirror (lane-eligible)
#   1 = not a faithful mirror (normal review)
#   2 = usage / environment error
#
# Bash 3.2 portable. Runs from scripts/ci/check_verify_propagation_pr.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/scripts/workflow/verify-propagation-pr.sh"
[ -x "$VERIFY" ] || { echo "missing or non-executable $VERIFY" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-prop-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

# --- Build a throwaway "mergepath" checkout -----------------------------
# A manifest with one canonical file, one kit dir, plus the canonical
# files themselves. This stands in for "mergepath at the sync sha".
MP="$WORKDIR/mergepath"
mkdir -p "$MP/scripts/workflow" "$MP/scripts/ci"
cp "$ROOT/scripts/workflow/parse_manifest_paths.sh" "$MP/scripts/workflow/parse_manifest_paths.sh"
cp "$ROOT/scripts/workflow/match_protected_paths.sh" "$MP/scripts/workflow/match_protected_paths.sh"
cat >"$MP/.mergepath-sync.yml" <<'YAML'
version: 1
consumers:
  - name: alpha
    repo: example/alpha
paths:
  - path: scripts/canonical-tool.sh
    type: canonical
    consumers: all
  - path: scripts/ci/
    type: kit
    consumers: all
exclusions: []
YAML
printf 'canonical body v1\n' >"$MP/scripts/canonical-tool.sh"
printf 'kit check v1\n'       >"$MP/scripts/ci/check_thing"
# The verifier requires mergepath_dir to be a git checkout whose HEAD is on
# the default branch recorded at refs/remotes/origin/HEAD (what a real
# `git clone` records). Publish the fixture that way.
git_quiet -C "$MP" init -q
git_quiet -C "$MP" add -A
git_quiet -C "$MP" commit -q -m "mergepath source"
git -C "$MP" update-ref refs/remotes/origin/main HEAD
git -C "$MP" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
MP_SHA=$(git -C "$MP" rev-parse HEAD)

# --- Helper: build a consumer repo with a base commit, then a head ------
# $1 = consumer dir, then the caller mutates the worktree and we commit
# the head. Returns base + head SHAs via globals BASE_SHA / HEAD_SHA.
new_consumer_base() {
  local dir="$1"
  mkdir -p "$dir"
  git_quiet -C "$dir" init -q
  # Base state: an unrelated consumer file + a STALE canonical file.
  mkdir -p "$dir/src" "$dir/scripts/ci"
  printf 'app code\n'          >"$dir/src/app.ts"
  printf 'canonical body v0\n' >"$dir/scripts/canonical-tool.sh"
  printf 'kit check v0\n'      >"$dir/scripts/ci/check_thing"
  git_quiet -C "$dir" add -A
  git_quiet -C "$dir" commit -q -m base
  BASE_SHA=$(git -C "$dir" rev-parse HEAD)
}
commit_head() {
  local dir="$1"
  git_quiet -C "$dir" add -A
  git_quiet -C "$dir" commit -q -m head
  HEAD_SHA=$(git -C "$dir" rev-parse HEAD)
}

run_verify() {  # echoes nothing; sets RC
  set +e
  "$VERIFY" "$MP" "$1" "$BASE_SHA" "$HEAD_SHA" >/dev/null 2>&1
  RC=$?
  set -e
}

# ---------------------------------------------------------------------------
# Case 1: faithful mirror — head brings canonical + kit files to exactly
# mergepath@<sha>'s content. Expect exit 0.
# ---------------------------------------------------------------------------
C1="$WORKDIR/c1"; new_consumer_base "$C1"
cp "$MP/scripts/canonical-tool.sh" "$C1/scripts/canonical-tool.sh"
cp "$MP/scripts/ci/check_thing"    "$C1/scripts/ci/check_thing"
commit_head "$C1"
run_verify "$C1"
[ "$RC" -eq 0 ] && pass "faithful mirror (canonical + kit byte-match) → exit 0" \
  || fail "faithful mirror expected exit 0, got $RC"

# ---------------------------------------------------------------------------
# Case 2: hand-edited canonical file — head sets canonical-tool.sh to
# something OTHER than mergepath@<sha>. This is the Codex P1 hole; the
# file IS under a manifest path, so a path-confinement-only check would
# wrongly pass. Byte-comparison must catch it. Expect exit 1.
# ---------------------------------------------------------------------------
C2="$WORKDIR/c2"; new_consumer_base "$C2"
printf 'canonical body v1 WITH A SNEAKY HAND EDIT\n' >"$C2/scripts/canonical-tool.sh"
commit_head "$C2"
run_verify "$C2"
[ "$RC" -eq 1 ] && pass "hand-edited canonical file (under a manifest path) → exit 1" \
  || fail "hand-edited canonical expected exit 1, got $RC"

# ---------------------------------------------------------------------------
# Case 3: off-manifest file changed — head edits src/app.ts, which is
# not propagation surface at all. Expect exit 1.
# ---------------------------------------------------------------------------
C3="$WORKDIR/c3"; new_consumer_base "$C3"
printf 'app code CHANGED\n' >"$C3/src/app.ts"
commit_head "$C3"
run_verify "$C3"
[ "$RC" -eq 1 ] && pass "off-manifest file changed (src/app.ts) → exit 1" \
  || fail "off-manifest change expected exit 1, got $RC"

# ---------------------------------------------------------------------------
# Case 4: faithful delete — a manifest path absent at mergepath@<sha>
# is removed in the PR. Expect exit 0.
# ---------------------------------------------------------------------------
C4="$WORKDIR/c4"; new_consumer_base "$C4"
# Base has an extra kit file mergepath does NOT have; the sync removes it
# only if mergepath also lacks it — here mergepath lacks it, so removing
# it is a faithful delete-propagation.
printf 'stale kit file\n' >"$C4/scripts/ci/check_stale"
git_quiet -C "$C4" add -A && git_quiet -C "$C4" commit -q --amend --no-edit
BASE_SHA=$(git -C "$C4" rev-parse HEAD)
rm "$C4/scripts/ci/check_stale"
# also bring the canonical/kit files up to date so the rest of the diff
# is itself faithful
cp "$MP/scripts/canonical-tool.sh" "$C4/scripts/canonical-tool.sh"
cp "$MP/scripts/ci/check_thing"    "$C4/scripts/ci/check_thing"
commit_head "$C4"
run_verify "$C4"
[ "$RC" -eq 0 ] && pass "faithful delete (manifest path absent at mergepath@<sha>) → exit 0" \
  || fail "faithful delete expected exit 0, got $RC"

# ---------------------------------------------------------------------------
# Case 5: unfaithful delete — PR removes a manifest file that mergepath
# @<sha> STILL has. Expect exit 1.
# ---------------------------------------------------------------------------
C5="$WORKDIR/c5"; new_consumer_base "$C5"
# bring canonical up to date so only the delete is in question
cp "$MP/scripts/canonical-tool.sh" "$C5/scripts/canonical-tool.sh"
rm "$C5/scripts/ci/check_thing"   # mergepath still HAS scripts/ci/check_thing
commit_head "$C5"
run_verify "$C5"
[ "$RC" -eq 1 ] && pass "unfaithful delete (file still present at mergepath@<sha>) → exit 1" \
  || fail "unfaithful delete expected exit 1, got $RC"

# ---------------------------------------------------------------------------
# Case 6: PR adds a file under a kit path that mergepath@<sha> does NOT
# have (a consumer-extra being introduced). A faithful --sync-all never
# does this. Expect exit 1.
# ---------------------------------------------------------------------------
C6="$WORKDIR/c6"; new_consumer_base "$C6"
cp "$MP/scripts/canonical-tool.sh" "$C6/scripts/canonical-tool.sh"
cp "$MP/scripts/ci/check_thing"    "$C6/scripts/ci/check_thing"
printf 'brand new consumer-extra\n' >"$C6/scripts/ci/check_brand_new"
commit_head "$C6"
run_verify "$C6"
[ "$RC" -eq 1 ] && pass "PR adds a kit-dir file absent at mergepath@<sha> → exit 1" \
  || fail "kit-extra-add expected exit 1, got $RC"

# ---------------------------------------------------------------------------
# Case 7: usage error — missing args. Expect exit 2.
# ---------------------------------------------------------------------------
set +e
"$VERIFY" "$MP" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] && pass "missing args → exit 2" || fail "missing args expected exit 2, got $rc"

# ---------------------------------------------------------------------------
# Case 8: environment error — mergepath dir has no manifest. Expect exit 2.
# ---------------------------------------------------------------------------
EMPTY_MP="$WORKDIR/empty-mp"; mkdir -p "$EMPTY_MP"
C8="$WORKDIR/c8"; new_consumer_base "$C8"
cp "$MP/scripts/canonical-tool.sh" "$C8/scripts/canonical-tool.sh"
commit_head "$C8"
set +e
"$VERIFY" "$EMPTY_MP" "$C8" "$BASE_SHA" "$HEAD_SHA" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] && pass "mergepath checkout missing .mergepath-sync.yml → exit 2" \
  || fail "missing manifest expected exit 2, got $rc"

# ---------------------------------------------------------------------------
# Source-commit provenance. The <sha> in a sync branch name can name ANY
# commit in the public mergepath repository, including one on an unmerged
# branch. A byte-faithful mirror of such a commit mirrors unreviewed content,
# so mergepath_dir's HEAD must be on mergepath's default branch.
# ---------------------------------------------------------------------------
# A faithful consumer PR reused across the provenance cases: its content
# byte-matches whichever mergepath commit is checked out below.
CP="$WORKDIR/cp"; new_consumer_base "$CP"
cp "$MP/scripts/canonical-tool.sh" "$CP/scripts/canonical-tool.sh"
cp "$MP/scripts/ci/check_thing"    "$CP/scripts/ci/check_thing"
commit_head "$CP"

prov_verify() {  # <mp_dir> [source_sha]; sets RC, ERR
  set +e
  ERR=$("$VERIFY" "$1" "$CP" "$BASE_SHA" "$HEAD_SHA" ${2:+"$2"} 2>&1 >/dev/null)
  RC=$?
  set -e
}

# Case 9: source commit is on a side branch, NOT merged into the default
# branch. Identical bytes to the faithful case, so ONLY provenance can fail it.
SIDE="$WORKDIR/mp-side"
git clone -q "$MP" "$SIDE" 2>/dev/null
git -C "$SIDE" update-ref refs/remotes/origin/main "$MP_SHA"
git -C "$SIDE" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git_quiet -C "$SIDE" checkout -q -b unmerged-feature
git_quiet -C "$SIDE" commit -q --allow-empty -m "unreviewed side-branch commit"
prov_verify "$SIDE"
if [ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -q "is NOT on mergepath's default branch"; then
  pass "source commit not on the default branch → exit 1, even when bytes match"
else
  fail "side-branch source commit expected exit 1 + ancestry diagnostic, got $RC: $ERR"
fi

# Case 10: an OLDER default-branch commit (main has moved on) is still
# lane-eligible — ancestor, not only tip.
OLD="$WORKDIR/mp-old"
git clone -q "$MP" "$OLD" 2>/dev/null
git_quiet -C "$OLD" commit -q --allow-empty -m "later main commit"
git -C "$OLD" update-ref refs/remotes/origin/main HEAD
git -C "$OLD" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git_quiet -C "$OLD" checkout -q --detach "$MP_SHA"
prov_verify "$OLD" "$MP_SHA"
[ "$RC" -eq 0 ] && pass "source commit is an ancestor of the default-branch tip → exit 0" \
  || fail "ancestor source commit expected exit 0, got $RC: $ERR"

# Case 10b: a commit reachable only through the SECOND parent of a true merge
# on the default branch is an ancestor of the tip, but its tree never existed
# on the default branch — not lane-eligible. The merge commit itself (first
# parent) is.
MERGED="$WORKDIR/mp-merged"
git clone -q "$MP" "$MERGED" 2>/dev/null
git_quiet -C "$MERGED" checkout -q -b pr-branch
git_quiet -C "$MERGED" commit -q --allow-empty -m "intermediate PR-branch commit"
PR_BRANCH_SHA=$(git -C "$MERGED" rev-parse HEAD)
git_quiet -C "$MERGED" checkout -q main
git_quiet -C "$MERGED" commit -q --allow-empty -m "main moves on"
git_quiet -C "$MERGED" merge -q --no-ff -m "true merge of pr-branch" pr-branch
MERGE_SHA=$(git -C "$MERGED" rev-parse HEAD)
git -C "$MERGED" update-ref refs/remotes/origin/main "$MERGE_SHA"
git -C "$MERGED" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git_quiet -C "$MERGED" checkout -q --detach "$PR_BRANCH_SHA"
prov_verify "$MERGED" "$PR_BRANCH_SHA"
if [ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -q "first-parent history"; then
  pass "second-parent-only commit of a true merge → exit 1 (ancestor but never a default-branch state)"
else
  fail "second-parent-only commit expected exit 1 + first-parent diagnostic, got $RC: $ERR"
fi
git_quiet -C "$MERGED" checkout -q --detach "$MERGE_SHA"
prov_verify "$MERGED" "$MERGE_SHA"
[ "$RC" -eq 0 ] && pass "first-parent merge commit on the default branch → exit 0" \
  || fail "first-parent merge commit expected exit 0, got $RC: $ERR"

# Case 11: source_sha must be the FULL id of mergepath_dir's HEAD.
prov_verify "$MP" "$MP_SHA"
[ "$RC" -eq 0 ] && pass "full source_sha equal to HEAD → exit 0" \
  || fail "matching full source_sha expected exit 0, got $RC: $ERR"
prov_verify "$MP" "${MP_SHA:0:7}"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q "full 40-hex" \
  && pass "abbreviated source_sha → exit 2" \
  || fail "abbreviated source_sha expected exit 2, got $RC: $ERR"
prov_verify "$SIDE" "$MP_SHA"
[ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -q "is not the requested source commit" \
  && pass "source_sha differing from mergepath_dir HEAD → exit 1" \
  || fail "mismatched source_sha expected exit 1, got $RC: $ERR"

# Case 12: provenance cannot be evaluated → exit 2 (never lane-eligible).
PLAIN="$WORKDIR/mp-plain"; mkdir -p "$PLAIN"
cp -R "$MP/scripts" "$MP/.mergepath-sync.yml" "$PLAIN/"
prov_verify "$PLAIN"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q "not the top of a git checkout" \
  && pass "mergepath_dir that is not a git checkout → exit 2" \
  || fail "plain-dir mergepath expected exit 2, got $RC: $ERR"
NOHEAD="$WORKDIR/mp-nohead"
git clone -q "$MP" "$NOHEAD" 2>/dev/null
git -C "$NOHEAD" symbolic-ref --delete refs/remotes/origin/HEAD
prov_verify "$NOHEAD"
[ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q "records no default branch" \
  && pass "no recorded default branch (origin/HEAD) → exit 2" \
  || fail "missing origin/HEAD expected exit 2, got $RC: $ERR"

echo ""
echo "test_verify_propagation_pr: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
