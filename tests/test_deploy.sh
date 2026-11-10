#!/usr/bin/env bash
# tests/test_deploy.sh
#
# Unit tests for scripts/deploy.sh. Covers the two guards added /
# tightened by mergepath#286:
#
#   1. Strict-bash BUILD_CMD invocation.
#      The script must run BUILD_CMD under `bash -euo pipefail -c --`
#      rather than plain `bash -c --`. The regression case is a
#      compound command like `false; echo should-not-run`: the old
#      form returns 0 (last segment succeeds), masking the failure;
#      the strict form aborts on `false`. We assert non-zero exit AND
#      that the second segment never wrote its stdout.
#
#   2. Clean-working-tree guard.
#      With a dirty fixture worktree, the script must exit non-zero,
#      print the dirty-tree diagnostic, and list the modified path.
#      With DEPLOY_ALLOW_DIRTY=1, the same dirty fixture must allow
#      the deploy to proceed (we assert by reaching the shimmed
#      op-firebase-deploy step).
#
#   3. Exact-match origin/main guard (guard 2, #2704).
#      On `main` with a local bare `origin`, the script refuses without
#      --force when HEAD is behind, ahead of, or diverged from
#      origin/main (naming both counts), when origin/main is missing
#      after a successful fetch, and when the fetch fails. --force
#      warns and proceeds in each case; an exact match proceeds with no
#      flag; --force still does not bypass the dirty-tree guard.
#
# Strategy: build a self-contained fixture git repo per test, run
# scripts/deploy.sh inside it with --force (to bypass guards 1+2 —
# branch + freshness — which depend on `origin/main` we don't want
# to set up) and --skip-cf-purge. Where the test needs the script
# to reach the deploy step, PATH-shim `op-firebase-deploy` so the
# script's `op-firebase-deploy "${DEPLOY_ARGS[@]}"` succeeds. The
# guard-2 cases instead set up a local bare `origin` (no network).
#
# Bash 3.2 portable.

set -euo pipefail

# The fixtures run git against several repositories by path; an
# inherited GIT_DIR (e.g. from a git hook) would redirect them into the
# caller's real repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/deploy.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-deploy.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Build a PATH shim that supplies a stub `op-firebase-deploy` so the
# script can reach its deploy step in success cases. The shim records
# its invocation to a per-test log so we can assert reachability.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"

cat >"$STUB_DIR/op-firebase-deploy" <<'STUB'
#!/usr/bin/env bash
echo "stub-op-firebase-deploy: invoked with args: $*" >&2
: "${OFD_LOG:?OFD_LOG must be set by the test}"
{
  printf 'op-firebase-deploy'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >> "$OFD_LOG"
exit 0
STUB
chmod +x "$STUB_DIR/op-firebase-deploy"

# Helper: build a throwaway git repo on a non-main branch with one
# committed file. Caller sets the working dir's dirty/clean state.
# Every `git config` write names the fixture repo with `-C` rather than
# relying on the subshell's cwd. An unscoped `git config` resolves against
# whatever repository the process is standing in, so one bad `cd` — or one
# copy of these lines pasted outside the subshell — writes the identity into
# the real checkout's .git/config, where every worktree inherits it (#777).
init_fixture_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git init --quiet -b feature/deploy-test "$repo"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" config commit.gpgsign false
  echo "initial" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit --quiet -m "initial"
}

# Run scripts/deploy.sh inside a fixture repo with sensible defaults.
# Args after `--` are passed to the script.
run_deploy() {
  local repo="$1"; shift
  (
    cd "$repo"
    PATH="$STUB_DIR:$PATH" \
      OFD_LOG="$WORKDIR/ofd-calls.log" \
      bash "$SCRIPT" "$@"
  )
}

# ---------------------------------------------------------------------------
# Case 1: BUILD_CMD='false; echo should-not-run' fails closed under
# strict-bash invocation.
# ---------------------------------------------------------------------------
REPO1="$WORKDIR/case1-strict-bash"
init_fixture_repo "$REPO1"
OUT1="$WORKDIR/case1.out"
ERR1="$WORKDIR/case1.err"
: >"$WORKDIR/ofd-calls.log"

set +e
PATH="$STUB_DIR:$PATH" \
OFD_LOG="$WORKDIR/ofd-calls.log" \
BUILD_CMD='false; echo should-not-run' \
  bash -c "cd '$REPO1' && bash '$SCRIPT' --force --skip-cf-purge" \
  >"$OUT1" 2>"$ERR1"
RC1=$?
set -e

if [[ $RC1 -eq 0 ]]; then
  fail "strict-bash: deploy.sh returned 0 with BUILD_CMD='false; echo should-not-run' — the OLD masking behavior is still live."
# Grep only for a LINE that is exactly 'should-not-run' (the
# `echo should-not-run` output), not any line containing the
# string — the script's own `>> Building: false; echo should-not-run`
# diagnostic echoes BUILD_CMD itself and would false-positive a
# substring match.
elif grep -qE '^should-not-run$' "$OUT1" "$ERR1" 2>/dev/null; then
  fail "strict-bash: deploy.sh ran the second segment of the compound command (output contains a bare 'should-not-run' line). Strict-bash should abort on 'false'."
elif grep -q 'op-firebase-deploy' "$WORKDIR/ofd-calls.log"; then
  fail "strict-bash: deploy.sh reached the op-firebase-deploy step despite the failing build — build failure was masked."
else
  pass "strict-bash: compound BUILD_CMD with leading false fails closed (rc=$RC1, no bare 'should-not-run' line, no deploy)."
fi

# ---------------------------------------------------------------------------
# Case 2: Clean-working-tree guard rejects a dirty fixture worktree.
# ---------------------------------------------------------------------------
REPO2="$WORKDIR/case2-dirty-tree"
init_fixture_repo "$REPO2"
# Introduce a dirty edit so git status --porcelain reports a modified path.
echo "uncommitted change" >> "$REPO2/README.md"

OUT2="$WORKDIR/case2.out"
ERR2="$WORKDIR/case2.err"
: >"$WORKDIR/ofd-calls.log"

set +e
PATH="$STUB_DIR:$PATH" \
OFD_LOG="$WORKDIR/ofd-calls.log" \
  bash -c "cd '$REPO2' && bash '$SCRIPT' --force --skip-cf-purge --skip-build" \
  >"$OUT2" 2>"$ERR2"
RC2=$?
set -e

if [[ $RC2 -eq 0 ]]; then
  fail "dirty-tree: deploy.sh returned 0 from a dirty worktree. Guard 3 missing or non-enforcing."
elif ! grep -q 'working tree is dirty' "$ERR2"; then
  fail "dirty-tree: deploy.sh exited non-zero (rc=$RC2) but did not print the 'working tree is dirty' diagnostic to stderr. stderr was:"
  cat "$ERR2" >&2
elif ! grep -q 'README.md' "$ERR2"; then
  fail "dirty-tree: deploy.sh did not list the modified path (README.md) in its diagnostic. stderr was:"
  cat "$ERR2" >&2
elif grep -q 'op-firebase-deploy' "$WORKDIR/ofd-calls.log"; then
  fail "dirty-tree: deploy.sh reached the op-firebase-deploy step from a dirty worktree."
else
  pass "dirty-tree: deploy.sh exits non-zero with a clear diagnostic and the dirty paths listed (rc=$RC2)."
fi

# ---------------------------------------------------------------------------
# Case 3: DEPLOY_ALLOW_DIRTY=1 break-glass override lets the dirty
# fixture worktree deploy. We use --skip-build so the test doesn't
# depend on `npm` being installed, and check that the shimmed
# op-firebase-deploy was reached.
# ---------------------------------------------------------------------------
REPO3="$WORKDIR/case3-allow-dirty"
init_fixture_repo "$REPO3"
echo "another uncommitted change" >> "$REPO3/README.md"

OUT3="$WORKDIR/case3.out"
ERR3="$WORKDIR/case3.err"
: >"$WORKDIR/ofd-calls.log"

set +e
# Pass trailing args through `--` (`--only hosting`) to exercise the
# non-empty DEPLOY_ARGS path. The empty-DEPLOY_ARGS path is exercised
# separately in Case 4 below (#286 r3 regression).
PATH="$STUB_DIR:$PATH" \
OFD_LOG="$WORKDIR/ofd-calls.log" \
DEPLOY_ALLOW_DIRTY=1 \
  bash -c "cd '$REPO3' && bash '$SCRIPT' --force --skip-build --skip-cf-purge -- --only hosting" \
  >"$OUT3" 2>"$ERR3"
RC3=$?
set -e

if [[ $RC3 -ne 0 ]]; then
  fail "allow-dirty: deploy.sh returned $RC3 with DEPLOY_ALLOW_DIRTY=1 from a dirty worktree. Override is broken. stderr was:"
  cat "$ERR3" >&2
elif ! grep -q 'DEPLOY_ALLOW_DIRTY=1' "$ERR3"; then
  fail "allow-dirty: deploy.sh did not log the DEPLOY_ALLOW_DIRTY=1 override banner to stderr. stderr was:"
  cat "$ERR3" >&2
elif ! grep -q 'op-firebase-deploy' "$WORKDIR/ofd-calls.log"; then
  fail "allow-dirty: deploy.sh did not reach the op-firebase-deploy step despite the override."
else
  pass "allow-dirty: DEPLOY_ALLOW_DIRTY=1 override permits deploy, logs the banner, reaches the deploy step."
fi

# ---------------------------------------------------------------------------
# Case 4 (#286 r3 — nathanpayne-codex Phase 4b finding): empty
# DEPLOY_ARGS must NOT trip the bash 3.2 unbound-variable abort.
# Invoke `deploy.sh --force --skip-build --skip-cf-purge` with NO
# trailing `-- <args>`; the script reaches the op-firebase-deploy
# step with DEPLOY_ARGS=(). Pre-fix: aborts with `DEPLOY_ARGS[@]:
# unbound variable`. Post-fix: expansion is `${ARR[@]+"${ARR[@]}"}`
# which is empty-safe under `set -u`.
# ---------------------------------------------------------------------------
REPO4="$WORKDIR/case4-empty-args-repo"
mkdir -p "$REPO4"
git init -q -b main "$REPO4"
git -C "$REPO4" config user.email a@b.c
git -C "$REPO4" config user.name a
git -C "$REPO4" config commit.gpgsign false
echo init >"$REPO4/README.md"
git -C "$REPO4" add README.md
git -C "$REPO4" commit -q -m init

OUT4="$WORKDIR/case4.out"
ERR4="$WORKDIR/case4.err"
: >"$WORKDIR/ofd-calls-4.log"

set +e
PATH="$STUB_DIR:$PATH" \
OFD_LOG="$WORKDIR/ofd-calls-4.log" \
  bash -c "cd '$REPO4' && bash '$SCRIPT' --force --skip-build --skip-cf-purge" \
  >"$OUT4" 2>"$ERR4"
RC4=$?
set -e

if grep -q 'unbound variable' "$ERR4" 2>/dev/null; then
  fail "empty-args: deploy.sh aborted with 'unbound variable' (#286 r3 regression)."
  cat "$ERR4" >&2
elif [[ $RC4 -ne 0 ]]; then
  fail "empty-args: deploy.sh returned $RC4 (expected 0). stderr was:"
  cat "$ERR4" >&2
elif ! grep -q 'op-firebase-deploy' "$WORKDIR/ofd-calls-4.log"; then
  fail "empty-args: deploy.sh did not reach the op-firebase-deploy step."
  cat "$ERR4" >&2
else
  pass "empty-args: deploy.sh with no trailing DEPLOY_ARGS reaches op-firebase-deploy without unbound-variable abort"
fi

# ---------------------------------------------------------------------------
# Guard 2 (#2704): local HEAD must be exactly origin/main.
#
# Each case gets a `main` checkout at <base>/work whose `origin` is the
# local bare repo <base>/origin.git, so the script's real
# `git fetch origin main` runs offline. Commits reach the bare repo by
# fetching INTO it, so no client push hook runs.
# ---------------------------------------------------------------------------
init_main_with_origin() {
  local base="$1"
  local work="$base/work"
  mkdir -p "$work"
  git init --quiet -b main "$work"
  git -C "$work" config user.email "test@example.com"
  git -C "$work" config user.name "Test"
  git -C "$work" config commit.gpgsign false
  echo "initial" > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit --quiet -m "initial"
  git clone --quiet --bare "$work" "$base/origin.git"
  git -C "$work" remote add origin "$base/origin.git"
  git -C "$work" fetch --quiet origin
}

# fixture_commits <work> <n>: add n local commits.
fixture_commits() {
  local work="$1" n="$2" i=0
  while [[ $i -lt $n ]]; do
    i=$((i + 1))
    echo "change $i $RANDOM" >> "$work/README.md"
    git -C "$work" commit --quiet -am "change $i"
  done
}

# publish_main <base>: make origin's main the work checkout's HEAD.
publish_main() {
  git -C "$1/origin.git" fetch --quiet "$1/work" "+main:main"
}

# run_guard2 <tag> <work> [script args...]: run the script with
# --skip-build --skip-cf-purge; sets G2_RC and writes <tag>.{out,err,ofd}.
G2_RC=0
run_guard2() {
  local tag="$1" work="$2"; shift 2
  : >"$WORKDIR/$tag.ofd"
  set +e
  (
    cd "$work" || exit 99
    unset DEPLOY_ALLOW_DIRTY
    PATH="$STUB_DIR:$PATH" \
      OFD_LOG="$WORKDIR/$tag.ofd" \
      bash "$SCRIPT" --skip-build --skip-cf-purge "$@"
  ) >"$WORKDIR/$tag.out" 2>"$WORKDIR/$tag.err"
  G2_RC=$?
  set -e
}

# expect_g2 <refused|deployed> <tag> <label> [stderr substring...]
# A "!" prefix on a substring asserts its ABSENCE.
expect_g2() {
  local want="$1" tag="$2" label="$3"; shift 3
  local err="$WORKDIR/$tag.err" s
  if [[ "$want" == "refused" ]]; then
    if [[ $G2_RC -eq 0 ]]; then
      fail "$label: exited 0, expected a refusal. stderr was:"; cat "$err" >&2; return 0
    fi
    if grep -q 'op-firebase-deploy' "$WORKDIR/$tag.ofd"; then
      fail "$label: reached op-firebase-deploy despite refusing."; return 0
    fi
  else
    if [[ $G2_RC -ne 0 ]]; then
      fail "$label: exited $G2_RC, expected the deploy to proceed. stderr was:"; cat "$err" >&2; return 0
    fi
    if ! grep -q 'op-firebase-deploy' "$WORKDIR/$tag.ofd"; then
      fail "$label: did not reach op-firebase-deploy."; return 0
    fi
  fi
  for s in "$@"; do
    if [[ "$s" == '!'* ]]; then
      if grep -qF -- "${s#!}" "$err"; then
        fail "$label: stderr unexpectedly contains '${s#!}'. stderr was:"; cat "$err" >&2; return 0
      fi
    elif ! grep -qF -- "$s" "$err"; then
      fail "$label: stderr lacks '$s'. stderr was:"; cat "$err" >&2; return 0
    fi
  done
  pass "$label (rc=$G2_RC)"
}

# Case 5: exact match deploys with no flag and no warning.
B5="$WORKDIR/case5-exact"
init_main_with_origin "$B5"
run_guard2 case5 "$B5/work"
expect_g2 deployed case5 "guard2-exact: HEAD == origin/main deploys without --force" \
  '!Refusing' '!--force:'

# Case 6: behind origin/main refuses, naming both counts; --force proceeds.
B6="$WORKDIR/case6-behind"
init_main_with_origin "$B6"
fixture_commits "$B6/work" 1
publish_main "$B6"
git -C "$B6/work" reset --quiet --hard HEAD~1
run_guard2 case6 "$B6/work"
expect_g2 refused case6 "guard2-behind: 1 behind refuses without --force" \
  'does not exactly match origin/main' '0 commit(s) ahead, 1 commit(s) behind'
run_guard2 case6f "$B6/work" --force
expect_g2 deployed case6f "guard2-behind-force: --force warns and proceeds" \
  '--force: deploying although local HEAD differs from origin/main (0 commit(s) ahead, 1 commit(s) behind)'

# Case 7: ahead of origin/main (unpushed commits) refuses; --force proceeds.
B7="$WORKDIR/case7-ahead"
init_main_with_origin "$B7"
fixture_commits "$B7/work" 2
run_guard2 case7 "$B7/work"
expect_g2 refused case7 "guard2-ahead: 2 unpushed commits refuse without --force" \
  'does not exactly match origin/main' '2 commit(s) ahead, 0 commit(s) behind'
run_guard2 case7f "$B7/work" --force
expect_g2 deployed case7f "guard2-ahead-force: --force warns and proceeds" \
  '--force: deploying although local HEAD differs from origin/main (2 commit(s) ahead, 0 commit(s) behind)'

# Case 8: diverged (1 ahead, 2 behind) refuses and reports both counts.
B8="$WORKDIR/case8-diverged"
init_main_with_origin "$B8"
fixture_commits "$B8/work" 2
publish_main "$B8"
git -C "$B8/work" reset --quiet --hard HEAD~2
fixture_commits "$B8/work" 1
run_guard2 case8 "$B8/work"
expect_g2 refused case8 "guard2-diverged: 1 ahead / 2 behind refuses without --force" \
  'does not exactly match origin/main' '1 commit(s) ahead, 2 commit(s) behind'

# Case 9: the fetch succeeds but origin/main does not exist (no fetch
# refspec maps main to refs/remotes/origin/main). Refuses without
# --force; --force warns and proceeds. The fetch-failed diagnostic must
# be absent, proving this is the post-fetch branch.
B9="$WORKDIR/case9-missing"
init_main_with_origin "$B9"
git -C "$B9/work" config --unset-all remote.origin.fetch
git -C "$B9/work" update-ref -d refs/remotes/origin/main
run_guard2 case9 "$B9/work"
expect_g2 refused case9 "guard2-missing: origin/main unavailable after a successful fetch refuses without --force" \
  'origin/main is unavailable after fetch' "!'git fetch origin main' failed"
if git -C "$B9/work" rev-parse --verify --quiet origin/main >/dev/null; then
  fail "guard2-missing: fixture invalid, the script's fetch created origin/main."
fi
run_guard2 case9f "$B9/work" --force
expect_g2 deployed case9f "guard2-missing-force: --force warns and proceeds" \
  '--force: origin/main is unavailable after fetch' '!git fetch failed'

# Case 10: the fetch itself fails (origin points at a missing path).
# A stale origin/main equal to HEAD is still present, so only the
# fetch-failure branch can refuse. --force warns and proceeds.
B10="$WORKDIR/case10-fetch-fails"
init_main_with_origin "$B10"
git -C "$B10/work" remote set-url origin "$B10/no-such-origin.git"
run_guard2 case10 "$B10/work"
expect_g2 refused case10 "guard2-fetch-fails: failed fetch refuses without --force" \
  "'git fetch origin main' failed"
run_guard2 case10f "$B10/work" --force
expect_g2 deployed case10f "guard2-fetch-fails-force: --force warns and proceeds" \
  '--force: git fetch failed'

# Case 11: --force bypasses guard 2 but not the dirty-tree guard.
B11="$WORKDIR/case11-force-dirty"
init_main_with_origin "$B11"
fixture_commits "$B11/work" 1
echo "uncommitted" >> "$B11/work/README.md"
run_guard2 case11 "$B11/work" --force
expect_g2 refused case11 "guard2-force-dirty: --force on an ahead, dirty main still hits the dirty-tree guard" \
  '--force: deploying although local HEAD differs' 'working tree is dirty'

# Case 12: --help describes the stricter guard and still prints the
# whole Usage block (the header line range tracks the comment).
B12="$WORKDIR/case12-help"
init_fixture_repo "$B12"
run_guard2 case12 "$B12" --help
if [[ $G2_RC -ne 0 ]]; then
  fail "help: --help exited $G2_RC"
elif ! grep -qF 'ahead of it (unpushed commits)' "$WORKDIR/case12.out"; then
  fail "help: --help does not describe the exact-match guard. stdout was:"; cat "$WORKDIR/case12.out" >&2
elif ! grep -qF 'scripts/deploy.sh --skip-cf-purge' "$WORKDIR/case12.out"; then
  fail "help: --help truncates the Usage block. stdout was:"; cat "$WORKDIR/case12.out" >&2
elif grep -qF 'Environment:' "$WORKDIR/case12.out"; then
  fail "help: --help runs past the Usage block. stdout was:"; cat "$WORKDIR/case12.out" >&2
else
  pass "help: --help describes the exact-match guard and prints the full Usage block"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "test_deploy.sh: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
