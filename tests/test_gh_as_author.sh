#!/usr/bin/env bash
# Unit tests for scripts/gh-as-author.sh token-based attribution.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/scripts/gh-as-author.sh"

[[ -x "$WRAPPER" ]] || { echo "missing or non-executable $WRAPPER" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-as-author-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${GH_CALLS_LOG:-/dev/null}"
printf 'GH_TOKEN=%s GITHUB_TOKEN=%s gh' "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" >> "$LOG"
for a in "$@"; do
  printf '\t%s' "$a" >> "$LOG"
done
printf '\n' >> "$LOG"

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "switch" ]; then
  echo "gh auth switch must not be called" >&2
  exit 90
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "token" ]; then
  user=""
  shift 2
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--user" ]; then
      shift
      user="${1:-}"
      break
    fi
    shift
  done
  case "$user" in
    nathanjohnpayne) printf '%s\n' "fallback-author-token" ;;
    custom-author) printf '%s\n' "fallback-custom-author-token" ;;
    *) exit 3 ;;
  esac
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  case "${GH_TOKEN:-}" in
    author-token|fallback-author-token) printf '%s\n' "nathanjohnpayne" ;;
    fallback-custom-author-token) printf '%s\n' "custom-author" ;;
    reviewer-token) printf '%s\n' "nathanpayne-claude" ;;
    *) exit 4 ;;
  esac
  exit 0
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  echo "${GH_CREATE_PR_URL:-https://github.com/example/repo/pull/42}"
  exit "${GH_CREATE_PR_RC:-0}"
fi

if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  rc="${GH_VIEW_RC:-0}"
  if [ "$rc" -ne 0 ]; then exit "$rc"; fi
  printf '%s\n' "${GH_VIEW_AUTHOR:-nathanjohnpayne}"
  exit 0
fi

exit "${GH_GENERIC_RC:-0}"
STUB
chmod +x "$STUB_DIR/gh"

run_wrapper() {
  PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$WORKDIR/calls.log" "$WRAPPER" "$@"
}

reset_log() {
  : > "$WORKDIR/calls.log"
}

reset_log
OP_PREFLIGHT_AUTHOR_PAT="author-token" GITHUB_TOKEN="ambient-token" \
  run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "merge happy path: rc=$rc"
elif grep -q $'gh\tauth\tswitch' "$WORKDIR/calls.log"; then
  fail "merge happy path: called gh auth switch"
elif ! grep -q $'GH_TOKEN=author-token GITHUB_TOKEN= gh\tpr\tmerge\t123\t--squash' "$WORKDIR/calls.log"; then
  fail "merge happy path: wrapped command did not run with author token and GITHUB_TOKEN unset"
  cat "$WORKDIR/calls.log" >&2
else
  pass "merge happy path: verified author token, no keyring switch, ambient GITHUB_TOKEN cleared"
fi

reset_log
OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/77" GH_VIEW_AUTHOR="nathanjohnpayne" \
  run_wrapper -- gh pr create --title "t" --body "b" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "pr create verification: rc=$rc"
elif ! grep -q $'GH_TOKEN=author-token GITHUB_TOKEN= gh\tpr\tview\t77\t--repo\texample/repo\t--json\tauthor\t--jq\t.author.login' "$WORKDIR/calls.log"; then
  fail "pr create verification: did not verify author with same token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "pr create verification: post-create read uses same author token"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="author-token" GH_CREATE_PR_URL="https://github.com/example/repo/pull/88" GH_VIEW_AUTHOR="nathanpayne-claude" \
  run_wrapper -- gh pr create --title "t" --body "b" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 5 ]; then
  fail "pr create mismatch: rc=$rc expected 5"
elif ! echo "$stderr_capture" | grep -q "effective token"; then
  fail "pr create mismatch: missing effective-token diagnostic"
else
  pass "pr create mismatch: fail-closed with token diagnostic"
fi

reset_log
unset OP_PREFLIGHT_AUTHOR_PAT
run_wrapper -- gh pr merge 123 --squash >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "fallback token: rc=$rc"
elif ! grep -q $'GH_TOKEN=fallback-author-token GITHUB_TOKEN= gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  fail "fallback token: did not use gh auth token --user fallback"
  cat "$WORKDIR/calls.log" >&2
else
  pass "fallback token: uses gh auth token --user without switching"
fi

reset_log
set +e
stderr_capture=$(OP_PREFLIGHT_AUTHOR_PAT="reviewer-token" run_wrapper -- gh pr merge 123 --squash 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "wrong preferred token: expected non-zero"
elif grep -q $'gh\tpr\tmerge' "$WORKDIR/calls.log"; then
  fail "wrong preferred token: wrapped write ran despite failed verification"
  cat "$WORKDIR/calls.log" >&2
else
  pass "wrong preferred token: fails before wrapped write"
fi

reset_log
set +e
run_wrapper -- >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "empty command: exits 1"
else
  fail "empty command: rc=$rc expected 1"
fi

echo ""
echo "test_gh_as_author: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
