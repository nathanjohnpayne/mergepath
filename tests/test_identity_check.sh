#!/usr/bin/env bash
# tests/test_identity_check.sh
#
# Unit tests for scripts/identity-check.sh — the pre-action identity
# assertion helper that callers run at the top of every WRITE path to
# fail-close on identity drift. See #284.
#
# Strategy: PATH-shim `gh` with a stub that:
#   - returns a configurable string for `gh config get -h github.com user`
#     (the stored-account read used by --expect-author /
#     --expect-reviewer / --expect-external)
#   - returns a configurable string for `gh api user --jq .login` (the
#     PAT-identity read used by --expect-token-identity)
#
# Bash 3.2 portable. Runs from any test runner (e.g. scripts/ci/) and
# is a useful local debugging entry point.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/identity-check.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/identity-check-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
# The write mode reads these; an operator's own values must not leak in.
unset GH_HOST GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a PATH-shim `gh` stub.
#   STUB_ACTIVE_USER   what `gh config get -h github.com user` returns
#   STUB_TOKEN_LOGIN   what `gh api user --jq .login` returns
#   STUB_TOKEN_RC      exit code for `gh api user` (default 0)
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "config get")
    [ -n "${STUB_ACTIVE_USER:-}" ] && echo "$STUB_ACTIVE_USER"
    exit 0
    ;;
  "api user")
    [ -n "${STUB_API_LOG:-}" ] && echo "api user" >>"$STUB_API_LOG"
    rc="${STUB_TOKEN_RC:-0}"
    if [ "$rc" -ne 0 ]; then exit "$rc"; fi
    echo "${STUB_TOKEN_LOGIN:-}"
    exit 0
    ;;
  "api -i")
    # `gh api -i user`: the headers --expect-write-identity reads for a
    # legacy unprefixed token (#1057).
    [ -n "${STUB_API_LOG:-}" ] && echo "api -i" >>"$STUB_API_LOG"
    printf 'HTTP/2.0 200 OK\r\n'
    [ -n "${STUB_SCOPES:-}" ] && printf 'X-Oauth-Scopes: %s\r\n' "$STUB_SCOPES"
    printf '\r\n{"login":"%s"}\n' "${STUB_TOKEN_LOGIN:-}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

# Run the script with the stubbed PATH.
run_check() {
  PATH="$STUB_DIR:$PATH" "$SCRIPT" "$@"
}

# -----------------------------------------------------------------------
# Test 1: --expect-author with matching stored account → exit 0
# -----------------------------------------------------------------------
set +e
out=$(STUB_ACTIVE_USER="nathanjohnpayne" run_check --expect-author 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass "--expect-author match: exit 0, silent"
else
  fail "--expect-author match: exit $rc, output: $out"
fi

# -----------------------------------------------------------------------
# Test 2: --expect-author with WRONG stored account → exit 2 + remediation
# -----------------------------------------------------------------------
set +e
out=$(STUB_ACTIVE_USER="nathanpayne-claude" run_check --expect-author 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "--expect-author mismatch: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "expected 'nathanjohnpayne'"; then
  fail "--expect-author mismatch: missing 'expected nathanjohnpayne' in output: $out"
elif ! echo "$out" | grep -qi "use the token wrapper for guarded writes"; then
  fail "--expect-author mismatch: missing remediation hint; output: $out"
else
  pass "--expect-author mismatch: exit 2 with remediation"
fi

# -----------------------------------------------------------------------
# Test 3: --expect-author with IDENTITY_CHECK_EXPECTED_AUTHOR override
# -----------------------------------------------------------------------
set +e
out=$(STUB_ACTIVE_USER="custom-author" IDENTITY_CHECK_EXPECTED_AUTHOR="custom-author" \
  run_check --expect-author 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "--expect-author with override: respects IDENTITY_CHECK_EXPECTED_AUTHOR"
else
  fail "--expect-author with override: exit $rc, output: $out"
fi

# -----------------------------------------------------------------------
# Test 4: --expect-reviewer with MERGEPATH_AGENT=claude + matching active
# -----------------------------------------------------------------------
set +e
out=$(STUB_ACTIVE_USER="nathanpayne-claude" MERGEPATH_AGENT="claude" \
  run_check --expect-reviewer 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "--expect-reviewer match (MERGEPATH_AGENT=claude): exit 0"
else
  fail "--expect-reviewer match: exit $rc, output: $out"
fi

# -----------------------------------------------------------------------
# Test 5: --expect-reviewer with MERGEPATH_AGENT=cursor but active=claude
# → mismatch, exit 2
# -----------------------------------------------------------------------
set +e
out=$(STUB_ACTIVE_USER="nathanpayne-claude" MERGEPATH_AGENT="cursor" \
  run_check --expect-reviewer 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "--expect-reviewer (cursor expected, claude active): exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "expected 'nathanpayne-cursor'"; then
  fail "--expect-reviewer (cursor expected, claude active): missing expected identity; output: $out"
else
  pass "--expect-reviewer cross-agent mismatch: exit 2"
fi

# -----------------------------------------------------------------------
# Test 6: --expect-reviewer with MERGEPATH_AGENT UNSET → warns + falls
# back to claude
# -----------------------------------------------------------------------
set +e
out=$(STUB_ACTIVE_USER="nathanpayne-claude" \
  env -u MERGEPATH_AGENT "$SCRIPT" --expect-reviewer 2>&1)
rc=$?
set -e
# Stub PATH wasn't passed here because we used `env -u` directly. Redo
# with both PATH and the unset.
set +e
out=$(PATH="$STUB_DIR:$PATH" STUB_ACTIVE_USER="nathanpayne-claude" \
  env -u MERGEPATH_AGENT bash -c 'PATH="'"$STUB_DIR"':$PATH" STUB_ACTIVE_USER="nathanpayne-claude" "'"$SCRIPT"'" --expect-reviewer' 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "--expect-reviewer missing MERGEPATH_AGENT: exit $rc, expected 0 (fallback to claude); output: $out"
elif ! echo "$out" | grep -qi "MERGEPATH_AGENT is unset"; then
  fail "--expect-reviewer missing MERGEPATH_AGENT: missing warning; output: $out"
else
  pass "--expect-reviewer missing MERGEPATH_AGENT: warns + falls back to claude"
fi

# -----------------------------------------------------------------------
# Test 7: --expect-external with explicit agent + matching active
# -----------------------------------------------------------------------
set +e
out=$(STUB_ACTIVE_USER="nathanpayne-codex" \
  run_check --expect-external codex 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "--expect-external codex (active=nathanpayne-codex): exit 0"
else
  fail "--expect-external codex match: exit $rc, output: $out"
fi

# -----------------------------------------------------------------------
# Test 8: --expect-external with mismatched agent → exit 2
# -----------------------------------------------------------------------
set +e
out=$(STUB_ACTIVE_USER="nathanpayne-claude" \
  run_check --expect-external codex 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "--expect-external codex (active=claude): exit $rc, expected 2"
elif ! echo "$out" | grep -qi "expected 'nathanpayne-codex'"; then
  fail "--expect-external codex (active=claude): missing expected identity; output: $out"
else
  pass "--expect-external codex mismatch: exit 2"
fi

# -----------------------------------------------------------------------
# Test 9: --expect-external with no agent argument → exit 1
# -----------------------------------------------------------------------
set +e
out=$(run_check --expect-external 2>&1)
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "--expect-external no arg: exit 1 (bad invocation)"
else
  fail "--expect-external no arg: exit $rc, expected 1"
fi

# -----------------------------------------------------------------------
# Test 10: --expect-token-identity match (token resolves to login)
# -----------------------------------------------------------------------
set +e
out=$(STUB_TOKEN_LOGIN="nathanpayne-claude" GH_TOKEN="fake-pat" \
  run_check --expect-token-identity nathanpayne-claude 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "--expect-token-identity match: exit 0"
else
  fail "--expect-token-identity match: exit $rc, output: $out"
fi

# -----------------------------------------------------------------------
# Test 11: --expect-token-identity mismatch (token resolves to wrong login)
# -----------------------------------------------------------------------
set +e
out=$(STUB_TOKEN_LOGIN="nathanjohnpayne" GH_TOKEN="fake-pat" \
  run_check --expect-token-identity nathanpayne-claude 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "--expect-token-identity mismatch: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "GH_TOKEN resolves to identity 'nathanjohnpayne'"; then
  fail "--expect-token-identity mismatch: missing actual identity; output: $out"
elif ! echo "$out" | grep -qi "graphql write — PAT-attributed"; then
  fail "--expect-token-identity mismatch: missing matrix pointer; output: $out"
else
  pass "--expect-token-identity mismatch: exit 2 with matrix pointer"
fi

# -----------------------------------------------------------------------
# Test 12: --expect-token-identity with NO GH_TOKEN set → exit 3
# (cannot verify, fail closed)
# -----------------------------------------------------------------------
set +e
out=$(env -u GH_TOKEN PATH="$STUB_DIR:$PATH" \
  "$SCRIPT" --expect-token-identity nathanpayne-claude 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "--expect-token-identity no GH_TOKEN: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -qi "GH_TOKEN is empty"; then
  fail "--expect-token-identity no GH_TOKEN: missing diagnostic; output: $out"
else
  pass "--expect-token-identity no GH_TOKEN: exit 3 (fail closed)"
fi

# -----------------------------------------------------------------------
# Test 13: --expect-token-identity with gh api user failure → exit 3
# -----------------------------------------------------------------------
set +e
out=$(STUB_TOKEN_RC=1 GH_TOKEN="bad-pat" \
  run_check --expect-token-identity nathanpayne-claude 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "--expect-token-identity api failure: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -qi "gh api user.*failed"; then
  fail "--expect-token-identity api failure: missing diagnostic; output: $out"
else
  pass "--expect-token-identity api failure: exit 3 (fail closed)"
fi

# -----------------------------------------------------------------------
# Test 14: keyring read failure (empty STUB_ACTIVE_USER) → exit 3
# -----------------------------------------------------------------------
set +e
out=$(STUB_ACTIVE_USER="" run_check --expect-author 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "keyring read failure: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -qi "returned empty"; then
  fail "keyring read failure: missing diagnostic; output: $out"
else
  pass "keyring read failure: exit 3 (fail closed)"
fi

# -----------------------------------------------------------------------
# Test 15: no mode → exit 1
# -----------------------------------------------------------------------
set +e
out=$(run_check 2>&1)
rc=$?
set -e
if [ "$rc" -eq 1 ] && echo "$out" | grep -qi "no mode specified"; then
  pass "no mode: exit 1"
else
  fail "no mode: exit $rc, output: $out"
fi

# -----------------------------------------------------------------------
# Test 16: conflicting modes → exit 1
# -----------------------------------------------------------------------
set +e
out=$(run_check --expect-author --expect-reviewer 2>&1)
rc=$?
set -e
if [ "$rc" -eq 1 ] && echo "$out" | grep -qi "conflicting modes"; then
  pass "conflicting modes: exit 1"
else
  fail "conflicting modes: exit $rc, output: $out"
fi

# -----------------------------------------------------------------------
# #1057: --expect-write-identity. A token must READ as the login AND be a
# user-held credential. The class is decided from the token before any API
# call, because GET /user is exactly what a broker answers truthfully for the
# wrong writer: the Claude cloud placeholder reads as the human.
# -----------------------------------------------------------------------
write_case() { # <label> <expected rc> <token> [env assignments...]
  local label="$1" want="$2" token="$3" out rc
  shift 3
  : >"$WORKDIR/api.log"
  set +e
  out=$(env "$@" STUB_API_LOG="$WORKDIR/api.log" GH_TOKEN="$token" \
    PATH="$STUB_DIR:$PATH" "$SCRIPT" --expect-write-identity nathanjohnpayne 2>&1)
  rc=$?
  set -e
  WRITE_OUT="$out"
  if [ "$rc" -eq "$want" ]; then
    pass "--expect-write-identity $label: exit $rc"
  else
    fail "--expect-write-identity $label: exit $rc, expected $want; output: $out"
  fi
}

write_case "ghp_ PAT reading as the login" 0 ghp_x STUB_TOKEN_LOGIN=nathanjohnpayne
write_case "fine-grained PAT reading as the login" 0 github_pat_x STUB_TOKEN_LOGIN=nathanjohnpayne
write_case "gh login token reading as the login" 0 gho_x STUB_TOKEN_LOGIN=nathanjohnpayne
write_case "user-held PAT reading as another login" 2 ghp_x STUB_TOKEN_LOGIN=nathanpayne-claude

write_case "cloud placeholder that reads as the login" 3 proxy-injected STUB_TOKEN_LOGIN=nathanjohnpayne
if [ -s "$WORKDIR/api.log" ]; then
  fail "--expect-write-identity placeholder: GET /user was called before the class refused it"
elif ! printf '%s' "$WRITE_OUT" | grep -q "credential class is 'brokered'"; then
  fail "--expect-write-identity placeholder: diagnostic does not name the class; output: $WRITE_OUT"
else
  pass "--expect-write-identity placeholder: refused on class, before any API call"
fi

write_case "app installation token that reads as the login" 3 ghs_x STUB_TOKEN_LOGIN=nathanjohnpayne

# Codex P1 on #1541: gh sends GH_TOKEN only to github.com, so a different
# Enterprise credential or a GH_HOST elsewhere would carry a write this check
# never classified. Refused before GET /user; the same token, or github.com in
# any case, is fine.
write_case "different GH_ENTERPRISE_TOKEN" 3 ghp_x STUB_TOKEN_LOGIN=nathanjohnpayne GH_ENTERPRISE_TOKEN=ghp_other
if [ -s "$WORKDIR/api.log" ] || ! printf '%s' "$WRITE_OUT" | grep -q "GH_ENTERPRISE_TOKEN holds a different credential"; then
  fail "--expect-write-identity enterprise token: not refused before GET /user; output: $WRITE_OUT"
else
  pass "--expect-write-identity enterprise token: refused before any API call"
fi
write_case "different GITHUB_ENTERPRISE_TOKEN" 3 ghp_x STUB_TOKEN_LOGIN=nathanjohnpayne GITHUB_ENTERPRISE_TOKEN=gho_other
write_case "Enterprise token equal to GH_TOKEN" 0 ghp_x STUB_TOKEN_LOGIN=nathanjohnpayne GH_ENTERPRISE_TOKEN=ghp_x GITHUB_ENTERPRISE_TOKEN=ghp_x
write_case "GH_HOST on an Enterprise Server" 3 ghp_x STUB_TOKEN_LOGIN=nathanjohnpayne GH_HOST=ghe.example.com
write_case "GH_HOST=GitHub.com" 0 ghp_x STUB_TOKEN_LOGIN=nathanjohnpayne GH_HOST=GitHub.com
write_case "opaque token that reads as the login" 3 some-token STUB_TOKEN_LOGIN=nathanjohnpayne
write_case "opaque token with the opt-in" 0 some-token STUB_TOKEN_LOGIN=nathanjohnpayne MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN=1
if printf '%s' "$WRITE_OUT" | grep -q "WARNING"; then
  pass "--expect-write-identity opt-in: accepted with a stderr warning"
else
  fail "--expect-write-identity opt-in: no warning; output: $WRITE_OUT"
fi
write_case "placeholder with the opt-in" 3 proxy-injected STUB_TOKEN_LOGIN=nathanjohnpayne MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN=1
write_case "app token with the opt-in" 3 ghs_x STUB_TOKEN_LOGIN=nathanjohnpayne MERGEPATH_ALLOW_UNIDENTIFIABLE_WRITE_TOKEN=1

HEX40=0123456789abcdef0123456789abcdef01234567
write_case "legacy hex token with X-OAuth-Scopes" 0 "$HEX40" STUB_TOKEN_LOGIN=nathanjohnpayne STUB_SCOPES=repo
write_case "legacy hex token without X-OAuth-Scopes" 3 "$HEX40" STUB_TOKEN_LOGIN=nathanjohnpayne

set +e
out=$(env -u GH_TOKEN PATH="$STUB_DIR:$PATH" "$SCRIPT" --expect-write-identity nathanjohnpayne 2>&1)
rc=$?
set -e
if [ "$rc" -eq 3 ]; then
  pass "--expect-write-identity with no GH_TOKEN: exit 3"
else
  fail "--expect-write-identity with no GH_TOKEN: exit $rc; output: $out"
fi

# The read-only mode is unchanged: the same placeholder still READS as the
# login, which is exactly why reads and writes need different modes.
set +e
out=$(STUB_TOKEN_LOGIN=nathanjohnpayne GH_TOKEN=proxy-injected run_check --expect-token-identity nathanjohnpayne 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "--expect-token-identity still answers the read question for the placeholder (exit 0)"
else
  fail "--expect-token-identity placeholder read: exit $rc; output: $out"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "test_identity_check: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
