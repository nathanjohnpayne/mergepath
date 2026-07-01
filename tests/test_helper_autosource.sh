#!/usr/bin/env bash
# tests/test_helper_autosource.sh
#
# Verifies the #282 auto-source path on each of the five helper scripts
# (coderabbit-wait, codex-review-request, codex-review-check,
# resolve-pr-threads, request-label-removal). The contract:
#
#   * When GH_TOKEN is unset AND a fresh op-preflight cache exists in
#     OP_PREFLIGHT_CACHE_DIR for $MERGEPATH_AGENT, sourcing the helper
#     pulls OP_PREFLIGHT_REVIEWER_PAT / OP_PREFLIGHT_AUTHOR_PAT and (for
#     the GH_TOKEN-required helpers) exports GH_TOKEN.
#
#   * When neither GH_TOKEN nor a fresh cache is available, the helper
#     should NOT crash on source — the existing
#     `[ -z "${GH_TOKEN:-}" ] && exit 3` guard is what surfaces the
#     missing-token diagnostic.
#
# We don't actually invoke each helper end-to-end (each requires a real
# PR, real network, etc). Instead the tests source the shared library
# directly and verify the auto-source behavior, AND invoke each helper
# with `--help`-equivalent inputs that exercise the early-source block
# without reaching network calls.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/preflight-helpers.sh"

[[ -r "$LIB" ]] || { echo "missing $LIB" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/helper-autosource-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

make_fresh_cache() {
  local dir="$1" agent="$2" reviewer_pat="$3" author_pat="$4"
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
OP_PREFLIGHT_REVIEWER_PAT=$reviewer_pat
OP_PREFLIGHT_AUTHOR_PAT=$author_pat
EOF
  chmod 600 "$dir/op-preflight-$agent.env"
}

make_stale_cache() {
  local dir="$1" agent="$2"
  mkdir -p "$dir"
  chmod 700 "$dir"
  local epoch
  epoch=$(( $(date +%s) - 18000 ))
  cat > "$dir/op-preflight-$agent.env" <<EOF
OP_PREFLIGHT_CREATED_AT_EPOCH=$epoch
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=$agent
OP_PREFLIGHT_MODE=review
OP_PREFLIGHT_DONE=1
OP_PREFLIGHT_REVIEWER_PAT=stale-rev
OP_PREFLIGHT_AUTHOR_PAT=stale-auth
EOF
  chmod 600 "$dir/op-preflight-$agent.env"
}

# A fresh cache whose PATs are computed FROM the ambient GH_TOKEN / GITHUB_TOKEN
# at source time. If the sourcing path fails to scrub the ambient tokens first,
# the resolved PATs capture the leaked ambient value; with the #573 scrub in
# place they resolve to the fixed sentinel (the parameter default), proving the
# ambient token never reached the sourced result.
make_ambient_derived_cache() {
  local dir="$1" agent="$2"
  mkdir -p "$dir"
  chmod 700 "$dir"
  local epoch
  epoch=$(date +%s)
  cat > "$dir/op-preflight-$agent.env" <<'EOF'
OP_PREFLIGHT_CREATED_AT_EPOCH=__EPOCH__
OP_PREFLIGHT_TTL_SECONDS=14400
OP_PREFLIGHT_AGENT=__AGENT__
OP_PREFLIGHT_MODE=review
OP_PREFLIGHT_DONE=1
OP_PREFLIGHT_REVIEWER_PAT="${GH_TOKEN:-cache-rev}"
OP_PREFLIGHT_AUTHOR_PAT="${GITHUB_TOKEN:-cache-auth}"
EOF
  # Fill the placeholders without disturbing the deliberate $GH_TOKEN /
  # $GITHUB_TOKEN references that must survive verbatim into the file.
  sed -i.bak "s/__EPOCH__/$epoch/; s/__AGENT__/$agent/" "$dir/op-preflight-$agent.env"
  rm -f "$dir/op-preflight-$agent.env.bak"
  chmod 600 "$dir/op-preflight-$agent.env"
}

# ---------------------------------------------------------------------------
# Test 1: auto_source_preflight loads a fresh cache when GH_TOKEN is
# unset, and is silent when GH_TOKEN is already set.
# ---------------------------------------------------------------------------
test_lib_auto_source_basic() {
  (
    local case_dir="$WORKDIR/lib1"
    make_fresh_cache "$case_dir" claude "rev-1" "auth-1"
    unset GH_TOKEN OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
    export OP_PREFLIGHT_CACHE_DIR="$case_dir"
    export MERGEPATH_AGENT=claude
    # shellcheck source=../scripts/lib/preflight-helpers.sh
    . "$LIB"
    auto_source_preflight
    if [ "${OP_PREFLIGHT_REVIEWER_PAT:-}" != "rev-1" ]; then
      echo "auto_source did not populate REVIEWER_PAT (got '${OP_PREFLIGHT_REVIEWER_PAT:-}')" >&2
      exit 1
    fi
    if [ "${OP_PREFLIGHT_AUTHOR_PAT:-}" != "auth-1" ]; then
      echo "auto_source did not populate AUTHOR_PAT (got '${OP_PREFLIGHT_AUTHOR_PAT:-}')" >&2
      exit 1
    fi
  ) >"$WORKDIR/lib1.out" 2>"$WORKDIR/lib1.err"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_lib_auto_source_basic: rc=$rc stderr=$(cat "$WORKDIR/lib1.err")"
    return
  fi
  pass "test_lib_auto_source_basic: fresh cache loads via auto_source_preflight"
}

# ---------------------------------------------------------------------------
# Test 2: auto_source_preflight is a no-op when GH_TOKEN is already set.
# ---------------------------------------------------------------------------
test_lib_gh_token_passthrough() {
  (
    local case_dir="$WORKDIR/lib2"
    make_fresh_cache "$case_dir" claude "rev-2" "auth-2"
    export OP_PREFLIGHT_CACHE_DIR="$case_dir"
    export MERGEPATH_AGENT=claude
    export GH_TOKEN="caller-supplied"
    unset OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
    # shellcheck source=../scripts/lib/preflight-helpers.sh
    . "$LIB"
    auto_source_preflight
    if [ "$GH_TOKEN" != "caller-supplied" ]; then
      echo "auto_source clobbered caller GH_TOKEN" >&2
      exit 1
    fi
    if [ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]; then
      echo "auto_source loaded cache even though GH_TOKEN was set" >&2
      exit 1
    fi
  ) >"$WORKDIR/lib2.out" 2>"$WORKDIR/lib2.err"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_lib_gh_token_passthrough: rc=$rc stderr=$(cat "$WORKDIR/lib2.err")"
    return
  fi
  pass "test_lib_gh_token_passthrough: GH_TOKEN preserved, cache untouched"
}

# ---------------------------------------------------------------------------
# Test 3: auto_source_preflight is silent on a STALE cache.
# ---------------------------------------------------------------------------
test_lib_stale_cache_noop() {
  (
    local case_dir="$WORKDIR/lib3"
    make_stale_cache "$case_dir" claude
    export OP_PREFLIGHT_CACHE_DIR="$case_dir"
    export MERGEPATH_AGENT=claude
    unset GH_TOKEN OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
    # shellcheck source=../scripts/lib/preflight-helpers.sh
    . "$LIB"
    auto_source_preflight
    if [ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]; then
      echo "auto_source loaded a STALE cache" >&2
      exit 1
    fi
  ) >"$WORKDIR/lib3.out" 2>"$WORKDIR/lib3.err"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_lib_stale_cache_noop: rc=$rc stderr=$(cat "$WORKDIR/lib3.err")"
    return
  fi
  pass "test_lib_stale_cache_noop: stale cache is not loaded"
}

# ---------------------------------------------------------------------------
# Test 3b (#573): auto_source_preflight scrubs a stray ambient GITHUB_TOKEN
# before sourcing, so it cannot survive to shadow the cache's GH_TOKEN (gh
# prefers GITHUB_TOKEN over GH_TOKEN). GH_TOKEN is unset here (auto-source
# only runs on an unset GH_TOKEN), and the ambient GITHUB_TOKEN must be gone
# after the source.
# ---------------------------------------------------------------------------
test_lib_auto_source_scrubs_ambient_github_token() {
  (
    local case_dir="$WORKDIR/lib3b"
    make_fresh_cache "$case_dir" claude "rev-3b" "auth-3b"
    unset GH_TOKEN OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
    export OP_PREFLIGHT_CACHE_DIR="$case_dir"
    export MERGEPATH_AGENT=claude
    export GITHUB_TOKEN="ambient-leaked-github-token"
    # shellcheck source=../scripts/lib/preflight-helpers.sh
    . "$LIB"
    auto_source_preflight
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      echo "auto_source left ambient GITHUB_TOKEN in place (got '${GITHUB_TOKEN:-}')" >&2
      exit 1
    fi
    if [ "${OP_PREFLIGHT_REVIEWER_PAT:-}" != "rev-3b" ]; then
      echo "auto_source did not load the cache (REVIEWER_PAT='${OP_PREFLIGHT_REVIEWER_PAT:-}')" >&2
      exit 1
    fi
  ) >"$WORKDIR/lib3b.out" 2>"$WORKDIR/lib3b.err" && local rc=0 || local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_lib_auto_source_scrubs_ambient_github_token: rc=$rc stderr=$(cat "$WORKDIR/lib3b.err")"
    return
  fi
  pass "test_lib_auto_source_scrubs_ambient_github_token: ambient GITHUB_TOKEN scrubbed before cache source (#573)"
}

# ---------------------------------------------------------------------------
# Test 3c (#573): load_preflight_env_vars scrubs ambient GH_TOKEN /
# GITHUB_TOKEN inside the sourcing subshells, so a stray ambient token cannot
# leak into the resolved PATs. The cache derives its PATs from $GH_TOKEN /
# $GITHUB_TOKEN at source time; with the scrub the resolved PATs fall back to
# the fixed cache sentinels, NOT the ambient values. The caller's ambient
# GH_TOKEN is restored afterward (documented behavior).
# ---------------------------------------------------------------------------
test_lib_load_env_vars_scrubs_ambient_token() {
  (
    local case_dir="$WORKDIR/lib3c"
    make_ambient_derived_cache "$case_dir" claude
    export OP_PREFLIGHT_CACHE_DIR="$case_dir"
    export MERGEPATH_AGENT=claude
    export GH_TOKEN="ambient-leaked-gh-token"
    export GITHUB_TOKEN="ambient-leaked-github-token"
    unset OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
    # shellcheck source=../scripts/lib/preflight-helpers.sh
    . "$LIB"
    load_preflight_env_vars
    if [ "${OP_PREFLIGHT_REVIEWER_PAT:-}" = "ambient-leaked-gh-token" ]; then
      echo "ambient GH_TOKEN leaked into REVIEWER_PAT" >&2
      exit 1
    fi
    if [ "${OP_PREFLIGHT_AUTHOR_PAT:-}" = "ambient-leaked-github-token" ]; then
      echo "ambient GITHUB_TOKEN leaked into AUTHOR_PAT" >&2
      exit 1
    fi
    if [ "${OP_PREFLIGHT_REVIEWER_PAT:-}" != "cache-rev" ]; then
      echo "REVIEWER_PAT did not resolve to the scrubbed cache sentinel (got '${OP_PREFLIGHT_REVIEWER_PAT:-}')" >&2
      exit 1
    fi
    if [ "${OP_PREFLIGHT_AUTHOR_PAT:-}" != "cache-auth" ]; then
      echo "AUTHOR_PAT did not resolve to the scrubbed cache sentinel (got '${OP_PREFLIGHT_AUTHOR_PAT:-}')" >&2
      exit 1
    fi
    # The caller's ambient GH_TOKEN must be restored (not scrubbed in the
    # caller's own process).
    if [ "${GH_TOKEN:-}" != "ambient-leaked-gh-token" ]; then
      echo "caller GH_TOKEN not restored after load_preflight_env_vars (got '${GH_TOKEN:-}')" >&2
      exit 1
    fi
  ) >"$WORKDIR/lib3c.out" 2>"$WORKDIR/lib3c.err" && local rc=0 || local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_lib_load_env_vars_scrubs_ambient_token: rc=$rc stderr=$(cat "$WORKDIR/lib3c.err")"
    return
  fi
  pass "test_lib_load_env_vars_scrubs_ambient_token: ambient token scrubbed inside cache-source subshells (#573)"
}

# ---------------------------------------------------------------------------
# Test 4: preflight_require_token reviewer exports GH_TOKEN from cache.
# ---------------------------------------------------------------------------
test_lib_require_token_reviewer() {
  (
    local case_dir="$WORKDIR/lib4"
    make_fresh_cache "$case_dir" claude "rev-4" "auth-4"
    export OP_PREFLIGHT_CACHE_DIR="$case_dir"
    export MERGEPATH_AGENT=claude
    unset GH_TOKEN OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
    # shellcheck source=../scripts/lib/preflight-helpers.sh
    . "$LIB"
    if ! preflight_require_token reviewer; then
      echo "preflight_require_token reviewer returned non-zero" >&2
      exit 1
    fi
    if [ "${GH_TOKEN:-}" != "rev-4" ]; then
      echo "GH_TOKEN not exported with reviewer PAT (got '${GH_TOKEN:-}')" >&2
      exit 1
    fi
  ) >"$WORKDIR/lib4.out" 2>"$WORKDIR/lib4.err"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_lib_require_token_reviewer: rc=$rc stderr=$(cat "$WORKDIR/lib4.err")"
    return
  fi
  pass "test_lib_require_token_reviewer: GH_TOKEN exported from cache (reviewer)"
}

# ---------------------------------------------------------------------------
# Test 5: preflight_require_token author exports GH_TOKEN from cache.
# ---------------------------------------------------------------------------
test_lib_require_token_author() {
  (
    local case_dir="$WORKDIR/lib5"
    make_fresh_cache "$case_dir" claude "rev-5" "auth-5"
    export OP_PREFLIGHT_CACHE_DIR="$case_dir"
    export MERGEPATH_AGENT=claude
    unset GH_TOKEN OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
    # shellcheck source=../scripts/lib/preflight-helpers.sh
    . "$LIB"
    if ! preflight_require_token author; then
      echo "preflight_require_token author returned non-zero" >&2
      exit 1
    fi
    if [ "${GH_TOKEN:-}" != "auth-5" ]; then
      echo "GH_TOKEN not exported with author PAT (got '${GH_TOKEN:-}')" >&2
      exit 1
    fi
  ) >"$WORKDIR/lib5.out" 2>"$WORKDIR/lib5.err"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "test_lib_require_token_author: rc=$rc stderr=$(cat "$WORKDIR/lib5.err")"
    return
  fi
  pass "test_lib_require_token_author: GH_TOKEN exported from cache (author)"
}

# ---------------------------------------------------------------------------
# Test 6: Each helper script sources the shared library on startup. We
# can't easily test the end-to-end path without network, but we CAN
# verify each script has the source line and that running it with no
# args + no GH_TOKEN + no cache emits a useful error message — i.e.
# the early-source block didn't break the bare invocation.
# ---------------------------------------------------------------------------
test_helpers_source_lib() {
  local helpers=(
    coderabbit-wait.sh
    codex-review-request.sh
    codex-review-check.sh
    resolve-pr-threads.sh
    request-label-removal.sh
  )
  local h missing=0
  for h in "${helpers[@]}"; do
    if ! grep -q 'lib/preflight-helpers.sh' "$ROOT/scripts/$h"; then
      fail "test_helpers_source_lib: $h does not source lib/preflight-helpers.sh"
      missing=1
    fi
  done
  if [ "$missing" -eq 0 ]; then
    pass "test_helpers_source_lib: all 5 helpers source the shared library"
  fi
}

# ---------------------------------------------------------------------------
# Test 7: GH_TOKEN-required helpers (coderabbit-wait, codex-review-request,
# codex-review-check) auto-source GH_TOKEN from a fresh cache and proceed
# past the early `[ -z "${GH_TOKEN:-}" ] && exit 3` guard.
#
# We can't reach the network in a test, so we use bash -n + a focused
# check: invoke the helper with a synthetic cache and an invalid PR
# number (which is parsed BEFORE GH_TOKEN check in some scripts).
# Strategy: confirm the helper does NOT exit with the old
# "GH_TOKEN is required" message when the cache is fresh.
# ---------------------------------------------------------------------------
test_helpers_no_gh_token_error_with_fresh_cache() {
  local case_dir="$WORKDIR/lib7"
  make_fresh_cache "$case_dir" claude "rev-7" "auth-7"

  # We stub `gh` and `jq` to short-circuit each helper before it
  # makes real API calls. Specifically: `gh repo view` returns a fake
  # repo, then any subsequent `gh api ...` exits non-zero so the
  # script's existing error path fires (we just want to verify the
  # GH_TOKEN guard didn't fire first).
  local stub_dir="$WORKDIR/stub-bin-7"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/gh" <<'EOF'
#!/usr/bin/env bash
# Print a minimal expected response for `gh repo view`; everything
# else exits 99 so the helper bails before any network.
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  echo "owner/repo"
  exit 0
fi
echo "stub-gh: bailing on '$*'" >&2
exit 99
EOF
  chmod +x "$stub_dir/gh"

  # Test each GH_TOKEN-required helper. The new behavior: with a fresh
  # cache, the helper auto-sources GH_TOKEN and proceeds. The old
  # error "GH_TOKEN is required" should NOT appear in stderr.
  local helpers=(
    coderabbit-wait.sh
    codex-review-request.sh
    codex-review-check.sh
  )
  local h failed=0
  for h in "${helpers[@]}"; do
    local rc=0
    PATH="$stub_dir:$PATH" \
      OP_PREFLIGHT_CACHE_DIR="$case_dir" \
      MERGEPATH_AGENT=claude \
      env -u GH_TOKEN "$ROOT/scripts/$h" 999999 owner/repo \
      >"$WORKDIR/h.out" 2>"$WORKDIR/h.err" || rc=$?
    if grep -q "GH_TOKEN is required" "$WORKDIR/h.err"; then
      fail "test_helpers_no_gh_token_error_with_fresh_cache: $h still emits 'GH_TOKEN is required' with a fresh cache; stderr=$(cat "$WORKDIR/h.err")"
      failed=1
    fi
  done
  if [ "$failed" -eq 0 ]; then
    pass "test_helpers_no_gh_token_error_with_fresh_cache: 3 helpers auto-source GH_TOKEN from cache"
  fi
}

test_lib_auto_source_basic
test_lib_gh_token_passthrough
test_lib_stale_cache_noop
test_lib_auto_source_scrubs_ambient_github_token
test_lib_load_env_vars_scrubs_ambient_token
test_lib_require_token_reviewer
test_lib_require_token_author
test_helpers_source_lib
test_helpers_no_gh_token_error_with_fresh_cache

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
