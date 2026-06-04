#!/usr/bin/env bash
# Unit tests for scripts/gh-as-reviewer.sh token-based attribution.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/scripts/gh-as-reviewer.sh"

[[ -x "$WRAPPER" ]] || { echo "missing or non-executable $WRAPPER" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-as-reviewer-test.XXXXXX")"
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
    nathanpayne-claude) printf '%s\n' "fallback-claude-token" ;;
    nathanpayne-codex) printf '%s\n' "fallback-codex-token" ;;
    *) exit 3 ;;
  esac
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  case "${GH_TOKEN:-}" in
    reviewer-token|fallback-claude-token) printf '%s\n' "nathanpayne-claude" ;;
    codex-token|fallback-codex-token) printf '%s\n' "nathanpayne-codex" ;;
    author-token) printf '%s\n' "nathanjohnpayne" ;;
    *) exit 4 ;;
  esac
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
OP_PREFLIGHT_REVIEWER_PAT="reviewer-token" GITHUB_TOKEN="ambient-token" \
  run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "review happy path: rc=$rc"
elif grep -q $'gh\tauth\tswitch' "$WORKDIR/calls.log"; then
  fail "review happy path: called gh auth switch"
elif ! grep -q $'GH_TOKEN=reviewer-token GITHUB_TOKEN= gh\tpr\treview\t123\t--comment' "$WORKDIR/calls.log"; then
  fail "review happy path: wrapped command did not run with reviewer token and GITHUB_TOKEN unset"
  cat "$WORKDIR/calls.log" >&2
else
  pass "review happy path: verified reviewer token, no keyring switch"
fi

reset_log
MERGEPATH_AGENT=codex OP_PREFLIGHT_REVIEWER_PAT="codex-token" \
  run_wrapper -- gh issue comment 7 --body "thanks" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "MERGEPATH_AGENT fallback: rc=$rc"
elif ! grep -q $'GH_TOKEN=codex-token GITHUB_TOKEN= gh\tissue\tcomment\t7' "$WORKDIR/calls.log"; then
  fail "MERGEPATH_AGENT fallback: did not use codex token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "MERGEPATH_AGENT fallback: resolves nathanpayne-codex"
fi

reset_log
OP_PREFLIGHT_AGENT=codex OP_PREFLIGHT_REVIEWER_PAT="codex-token" \
  run_wrapper -- gh issue comment 8 --body "thanks" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "OP_PREFLIGHT_AGENT fallback: rc=$rc"
elif ! grep -q $'GH_TOKEN=codex-token GITHUB_TOKEN= gh\tissue\tcomment\t8' "$WORKDIR/calls.log"; then
  fail "OP_PREFLIGHT_AGENT fallback: did not use codex token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "OP_PREFLIGHT_AGENT fallback: resolves nathanpayne-codex"
fi

reset_log
GH_AS_REVIEWER_IDENTITY=nathanpayne-codex OP_PREFLIGHT_REVIEWER_PAT="codex-token" \
  run_wrapper -- gh pr comment 123 --body "ping" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "explicit identity: rc=$rc"
elif ! grep -q $'GH_TOKEN=codex-token GITHUB_TOKEN= gh\tpr\tcomment\t123' "$WORKDIR/calls.log"; then
  fail "explicit identity: did not use codex token"
  cat "$WORKDIR/calls.log" >&2
else
  pass "explicit identity: GH_AS_REVIEWER_IDENTITY wins"
fi

reset_log
unset OP_PREFLIGHT_REVIEWER_PAT
run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "fallback token: rc=$rc"
elif ! grep -q $'GH_TOKEN=fallback-claude-token GITHUB_TOKEN= gh\tpr\treview' "$WORKDIR/calls.log"; then
  fail "fallback token: did not use gh auth token --user"
  cat "$WORKDIR/calls.log" >&2
else
  pass "fallback token: uses gh auth token --user without switching"
fi

reset_log
set +e
OP_PREFLIGHT_REVIEWER_PAT="author-token" run_wrapper -- gh pr review 123 --comment --body "ok" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "wrong preferred token: expected non-zero"
elif grep -q $'gh\tpr\treview' "$WORKDIR/calls.log"; then
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
echo "test_gh_as_reviewer: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
