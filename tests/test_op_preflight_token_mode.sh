#!/usr/bin/env bash
# tests/test_op_preflight_token_mode.sh
#
# Unit tests for the explicit OP_SERVICE_ACCOUNT_TOKEN lane added for #353.
#
# The contract:
#   - token mode activates only when OP_SERVICE_ACCOUNT_TOKEN is set
#   - only claude/cursor/codex reviewer PAT items are readable
#   - author PAT, deploy secrets, SSH warming, and gh keyring repair are
#     outside this lane
#   - token-mode session files are chmod 600 and never persist/log the
#     service-account token itself
#   - --check remains probe-free and accepts a reviewer-only token-mode cache
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/op-preflight.sh"
LIB="$ROOT/scripts/lib/preflight-helpers.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }
[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/op-preflight-token-mode-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
OP_LOG="$WORKDIR/op.log"
SSH_LOG="$WORKDIR/ssh.log"
GH_LOG="$WORKDIR/gh.log"
SERVICE_TOKEN="stub-service-account-token"

cat > "$STUB_DIR/op" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$OP_LOG"
if [[ -z "\${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  echo "FATAL: OP_SERVICE_ACCOUNT_TOKEN missing" >&2
  exit 65
fi
case "\${1:-}" in
  read)
    case "\${2:-}" in
      op://Private/pvbq24vl2h6gl7yjclxy2hbote/token) printf '%s\n' "reviewer-pat-claude" ;;
      op://Private/bslrih4spwxgookzfy6zedz5g4/token) printf '%s\n' "reviewer-pat-cursor" ;;
      op://Private/o6ekjxjjl5gq6rmcneomrjahpu/token) printf '%s\n' "reviewer-pat-codex" ;;
      op://Private/sm5kopwk6t6p3xmu2igesndzhe/token)
        echo "FATAL: token mode attempted author PAT read" >&2
        exit 66
        ;;
      op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential|op://Private/4x6wslp3f6pal5t6h3jhhe63ie/credential)
        echo "FATAL: token mode attempted deploy secret read" >&2
        exit 67
        ;;
      *)
        echo "FATAL: unexpected op read target: \${2:-}" >&2
        exit 68
        ;;
    esac
    ;;
  inject)
    echo "FATAL: token mode invoked op inject" >&2
    exit 69
    ;;
  *)
    echo "FATAL: unexpected op command: \$*" >&2
    exit 70
    ;;
esac
EOF
chmod +x "$STUB_DIR/op"

cat > "$STUB_DIR/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSH_LOG"
echo "FATAL: token mode invoked ssh with args: \$*" >&2
exit 98
EOF
chmod +x "$STUB_DIR/ssh"

cat > "$STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
echo "FATAL: token mode invoked gh with args: \$*" >&2
exit 97
EOF
chmod +x "$STUB_DIR/gh"

reset_logs() {
  : > "$OP_LOG"
  : > "$SSH_LOG"
  : > "$GH_LOG"
}

mode_for_file() {
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

make_interactive_cache() {
  local dir="$1" agent="$2"
  mkdir -p "$dir"
  chmod 700 "$dir"
  local epoch
  epoch=$(date +%s)
  cat > "$dir/op-preflight-$agent.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=$agent
OP_PREFLIGHT_MODE=review
OP_PREFLIGHT_DONE=1
OP_PREFLIGHT_REVIEWER_PAT=interactive-reviewer
OP_PREFLIGHT_AUTHOR_PAT=interactive-author
EOF
  chmod 600 "$dir/op-preflight-$agent.env"
}

assert_no_service_token_leak() {
  local label="$1"; shift
  local file
  for file in "$@"; do
    if [[ -f "$file" ]] && grep -q "$SERVICE_TOKEN" "$file"; then
      fail "$label: service account token leaked into $file"
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Test 1: token mode loads only each configured agent's reviewer PAT.
# ---------------------------------------------------------------------------
test_token_mode_agents() {
  local agent expected cache_dir session out err perms
  for agent in claude cursor codex; do
    reset_logs
    cache_dir="$WORKDIR/agent-$agent-cache"
    mkdir -p "$cache_dir"
    out="$WORKDIR/agent-$agent.out"
    err="$WORKDIR/agent-$agent.err"
    local rc=0
    PATH="$STUB_DIR:$PATH" \
      OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
      OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_TOKEN" \
      "$SCRIPT" --agent "$agent" --mode review >"$out" 2>"$err" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      fail "test_token_mode_agents($agent): expected rc=0, got rc=$rc; stderr=$(cat "$err")"
      return
    fi
    expected="reviewer-pat-$agent"
    session="$cache_dir/op-preflight-$agent.env"
    if ! grep -q "export OP_PREFLIGHT_REVIEWER_PAT=$expected" "$out"; then
      fail "test_token_mode_agents($agent): stdout missing reviewer PAT export"
      return
    fi
    if grep -q "OP_PREFLIGHT_AUTHOR_PAT" "$out" "$session"; then
      fail "test_token_mode_agents($agent): token mode exported or cached author PAT"
      return
    fi
    if ! grep -q "OP_PREFLIGHT_TOKEN_MODE=1" "$out" || ! grep -q "^OP_PREFLIGHT_TOKEN_MODE=1$" "$session"; then
      fail "test_token_mode_agents($agent): token mode marker missing"
      return
    fi
    perms="$(mode_for_file "$session")"
    if [[ "$perms" != "600" ]]; then
      fail "test_token_mode_agents($agent): session permissions expected 600, got $perms"
      return
    fi
    if [[ -s "$SSH_LOG" || -s "$GH_LOG" ]]; then
      fail "test_token_mode_agents($agent): token mode invoked ssh/gh"
      return
    fi
    if grep -q "inject" "$OP_LOG"; then
      fail "test_token_mode_agents($agent): token mode used op inject"
      return
    fi
    if grep -q "sm5kopwk6t6p3xmu2igesndzhe\\|c2v6emkwppjzjjaq2bdqk3wnlm\\|4x6wslp3f6pal5t6h3jhhe63ie" "$OP_LOG"; then
      fail "test_token_mode_agents($agent): token mode attempted out-of-scope op item"
      return
    fi
    if [[ -f "$cache_dir/biometric-log" ]]; then
      fail "test_token_mode_agents($agent): token mode wrote biometric log"
      return
    fi
    if ! assert_no_service_token_leak "test_token_mode_agents($agent)" "$out" "$err" "$session" "$OP_LOG" "$SSH_LOG" "$GH_LOG"; then
      return
    fi
  done
  pass "test_token_mode_agents: reviewer-only token mode works for claude/cursor/codex"
}

# ---------------------------------------------------------------------------
# Test 2: token-mode cache hits and --check do not invoke op/ssh/gh.
# ---------------------------------------------------------------------------
test_token_mode_cache_and_check() {
  local cache_dir="$WORKDIR/cache-hit"
  mkdir -p "$cache_dir"
  reset_logs
  PATH="$STUB_DIR:$PATH" \
    OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_TOKEN" \
    "$SCRIPT" --agent codex --mode review >"$WORKDIR/cache-fill.out" 2>"$WORKDIR/cache-fill.err"

  reset_logs
  local rc=0
  PATH="$STUB_DIR:$PATH" \
    OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    "$SCRIPT" --agent codex --mode review >"$WORKDIR/cache-hit.out" 2>"$WORKDIR/cache-hit.err" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail "test_token_mode_cache_and_check: cache hit expected rc=0, got rc=$rc; stderr=$(cat "$WORKDIR/cache-hit.err")"
    return
  fi
  if [[ -s "$OP_LOG" || -s "$SSH_LOG" || -s "$GH_LOG" ]]; then
    fail "test_token_mode_cache_and_check: cache hit invoked op/ssh/gh"
    return
  fi
  if grep -q "OP_PREFLIGHT_AUTHOR_PAT" "$WORKDIR/cache-hit.out"; then
    fail "test_token_mode_cache_and_check: cache hit emitted author PAT"
    return
  fi

  reset_logs
  rc=0
  PATH="$STUB_DIR:$PATH" \
    OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    "$SCRIPT" --agent codex --check >"$WORKDIR/check.out" 2>"$WORKDIR/check.err" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail "test_token_mode_cache_and_check: --check expected rc=0, got rc=$rc; stderr=$(cat "$WORKDIR/check.err")"
    return
  fi
  if [[ -s "$OP_LOG" || -s "$SSH_LOG" || -s "$GH_LOG" ]]; then
    fail "test_token_mode_cache_and_check: --check invoked op/ssh/gh"
    return
  fi
  if ! grep -q "export OP_PREFLIGHT_REVIEWER_PAT=reviewer-pat-codex" "$WORKDIR/check.out"; then
    fail "test_token_mode_cache_and_check: --check missing reviewer PAT export"
    return
  fi
  if grep -q "OP_PREFLIGHT_AUTHOR_PAT" "$WORKDIR/check.out"; then
    fail "test_token_mode_cache_and_check: --check emitted author PAT"
    return
  fi
  pass "test_token_mode_cache_and_check: token cache and --check remain probe-free"
}

# ---------------------------------------------------------------------------
# Test 3: OP_SERVICE_ACCOUNT_TOKEN does not reuse an interactive cache.
# ---------------------------------------------------------------------------
test_token_mode_replaces_interactive_cache() {
  local cache_dir="$WORKDIR/interactive-cache"
  make_interactive_cache "$cache_dir" codex
  reset_logs
  local rc=0
  PATH="$STUB_DIR:$PATH" \
    OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_TOKEN" \
    "$SCRIPT" --agent codex --mode review >"$WORKDIR/interactive-refresh.out" 2>"$WORKDIR/interactive-refresh.err" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail "test_token_mode_replaces_interactive_cache: expected refresh rc=0, got rc=$rc; stderr=$(cat "$WORKDIR/interactive-refresh.err")"
    return
  fi
  if ! grep -q "export OP_PREFLIGHT_REVIEWER_PAT=reviewer-pat-codex" "$WORKDIR/interactive-refresh.out"; then
    fail "test_token_mode_replaces_interactive_cache: did not emit token-mode reviewer PAT"
    return
  fi
  if grep -q "interactive-reviewer\\|interactive-author\\|OP_PREFLIGHT_AUTHOR_PAT" "$WORKDIR/interactive-refresh.out" "$cache_dir/op-preflight-codex.env"; then
    fail "test_token_mode_replaces_interactive_cache: reused interactive cache or retained author PAT"
    return
  fi
  if ! grep -q "^OP_PREFLIGHT_TOKEN_MODE=1$" "$cache_dir/op-preflight-codex.env"; then
    fail "test_token_mode_replaces_interactive_cache: refreshed cache missing token marker"
    return
  fi
  if [[ -s "$SSH_LOG" || -s "$GH_LOG" ]]; then
    fail "test_token_mode_replaces_interactive_cache: token refresh invoked ssh/gh"
    return
  fi

  local check_cache="$WORKDIR/interactive-check-cache"
  make_interactive_cache "$check_cache" codex
  reset_logs
  rc=0
  PATH="$STUB_DIR:$PATH" \
    OP_PREFLIGHT_CACHE_DIR="$check_cache" \
    OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_TOKEN" \
    "$SCRIPT" --agent codex --check >"$WORKDIR/interactive-check.out" 2>"$WORKDIR/interactive-check.err" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    fail "test_token_mode_replaces_interactive_cache: --check accepted interactive cache under token env"
    return
  fi
  if [[ -s "$OP_LOG" || -s "$SSH_LOG" || -s "$GH_LOG" ]]; then
    fail "test_token_mode_replaces_interactive_cache: --check invoked op/ssh/gh"
    return
  fi
  pass "test_token_mode_replaces_interactive_cache: explicit token env replaces interactive cache"
}

# ---------------------------------------------------------------------------
# Test 4: unknown agents and out-of-scope modes fail before op is invoked.
# ---------------------------------------------------------------------------
test_token_mode_fail_closed_scope() {
  reset_logs
  local rc=0
  PATH="$STUB_DIR:$PATH" \
    OP_PREFLIGHT_CACHE_DIR="$WORKDIR/unknown-cache" \
    OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_TOKEN" \
    "$SCRIPT" --agent unknown --mode review >"$WORKDIR/unknown.out" 2>"$WORKDIR/unknown.err" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    fail "test_token_mode_fail_closed_scope: unknown agent unexpectedly succeeded"
    return
  fi
  if ! grep -q "unknown agent" "$WORKDIR/unknown.err"; then
    fail "test_token_mode_fail_closed_scope: unknown agent missing diagnostic"
    return
  fi
  if [[ -s "$OP_LOG" ]]; then
    fail "test_token_mode_fail_closed_scope: unknown agent invoked op"
    return
  fi

  local mode
  for mode in deploy all; do
    reset_logs
    rc=0
    PATH="$STUB_DIR:$PATH" \
      OP_PREFLIGHT_CACHE_DIR="$WORKDIR/out-of-scope-$mode-cache" \
      OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_TOKEN" \
      "$SCRIPT" --agent codex --mode "$mode" >"$WORKDIR/out-of-scope-$mode.out" 2>"$WORKDIR/out-of-scope-$mode.err" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      fail "test_token_mode_fail_closed_scope: mode $mode unexpectedly succeeded"
      return
    fi
    if ! grep -q "out of scope" "$WORKDIR/out-of-scope-$mode.err"; then
      fail "test_token_mode_fail_closed_scope: mode $mode missing out-of-scope diagnostic"
      return
    fi
    if [[ -s "$OP_LOG" || -s "$SSH_LOG" || -s "$GH_LOG" ]]; then
      fail "test_token_mode_fail_closed_scope: mode $mode invoked op/ssh/gh"
      return
    fi
  done
  pass "test_token_mode_fail_closed_scope: unknown agents and deploy/all fail closed"
}

# ---------------------------------------------------------------------------
# Test 5: helper auto-source accepts reviewer scope but not author scope.
# ---------------------------------------------------------------------------
test_token_mode_helper_scope() {
  local cache_dir="$WORKDIR/helper-cache"
  mkdir -p "$cache_dir"
  reset_logs
  PATH="$STUB_DIR:$PATH" \
    OP_PREFLIGHT_CACHE_DIR="$cache_dir" \
    OP_SERVICE_ACCOUNT_TOKEN="$SERVICE_TOKEN" \
    "$SCRIPT" --agent codex --mode review >"$WORKDIR/helper-fill.out" 2>"$WORKDIR/helper-fill.err"

  (
    export OP_PREFLIGHT_CACHE_DIR="$cache_dir"
    export MERGEPATH_AGENT=codex
    unset GH_TOKEN OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
    # shellcheck source=../scripts/lib/preflight-helpers.sh
    . "$LIB"
    if ! preflight_require_token reviewer; then
      echo "reviewer scope did not load from token-mode cache" >&2
      exit 1
    fi
    if [[ "${GH_TOKEN:-}" != "reviewer-pat-codex" ]]; then
      echo "reviewer scope loaded wrong token: '${GH_TOKEN:-}'" >&2
      exit 1
    fi
    unset GH_TOKEN
    if preflight_require_token author; then
      echo "author scope unexpectedly loaded from token-mode cache" >&2
      exit 1
    fi
  ) >"$WORKDIR/helper-scope.out" 2>"$WORKDIR/helper-scope.err"
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail "test_token_mode_helper_scope: rc=$rc stderr=$(cat "$WORKDIR/helper-scope.err")"
    return
  fi
  pass "test_token_mode_helper_scope: helper reviewer scope works and author scope fails"
}

test_token_mode_agents
test_token_mode_cache_and_check
test_token_mode_replaces_interactive_cache
test_token_mode_fail_closed_scope
test_token_mode_helper_scope

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
